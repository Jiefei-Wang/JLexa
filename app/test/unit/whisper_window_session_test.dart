import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/native_ai_bridge.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/audio/whisper_window_session.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ControlledWindowSpeech extends NativeWhisperEngine {
  bool loaded = true;
  final calls =
      <({int start, int end, String id, Completer<List<AudioSegment>> done})>[];
  final cancelled = <String>[];
  @override
  bool get isLoaded => loaded;
  @override
  String? get loadedModelPath => loaded ? 'tiny.en' : null;
  @override
  Future<List<AudioSegment>> transcribeCut({
    required String audioPath,
    required String lessonId,
    required String cutId,
    required int cutRevision,
    required int startMs,
    required int endMs,
    required String modelId,
    String? requestId,
    int nThreads = 4,
    void Function(double)? onProgress,
  }) {
    final done = Completer<List<AudioSegment>>();
    calls.add((start: startMs, end: endMs, id: requestId!, done: done));
    return done.future;
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    cancelled.add(requestId);
    // Native acknowledgement precedes terminal completion.
  }
}

Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late LessonRepository repo;
  late ControlledWindowSpeech engine;
  late AiService ai;
  late AudioLesson lesson;
  late WhisperWindowSession session;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    AppDatabase.setDatabaseForTesting(db);
    await db.execute(
      'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT)',
    );
    await db.execute(
      'CREATE TABLE audio_lessons (id TEXT PRIMARY KEY, cuts_initialized INTEGER)',
    );
    await db.execute('''CREATE TABLE audio_segments (id TEXT PRIMARY KEY,
      lesson_id TEXT, start_ms INTEGER, end_ms INTEGER, text TEXT,
      confidence REAL, is_user_edited INTEGER, tokens_json TEXT, revision INTEGER,
      transcript_cut_revision INTEGER, transcript_model_id TEXT)''');
    await db.insert('audio_lessons', {'id': 'lesson', 'cuts_initialized': 1});
    repo = LessonRepository();
    engine = ControlledWindowSpeech();
    ai = AiService(speech: engine);
    lesson = AudioLesson(
      id: 'lesson',
      title: 'Test',
      originalFileName: 'test.wav',
      localPath: '/test.wav',
      durationMs: 180000,
      createdAt: DateTime(2026),
      lastOpenedAt: DateTime(2026),
    );
    final cuts = [
      for (var i = 0; i < 3; i++)
        AudioSegment(
          id: 'acoustic$i',
          lessonId: 'lesson',
          startMs: i * 60000 + 1000,
          endMs: i * 60000 + 8000,
          text: '',
        ),
    ];
    for (final cut in cuts) {
      await db.insert('audio_segments', cut.toMap());
    }
    session = WhisperWindowSession(
      lesson: lesson,
      repository: repo,
      ai: ai,
      cuts: cuts,
    );
  });
  tearDown(() async {
    final stopped = session.pause();
    for (final call in engine.calls) {
      if (!call.done.isCompleted) {
        call.done.completeError(const AiCancelledException());
      }
    }
    await stopped;
    session.dispose();
    repo.dispose();
    await db.close();
    AppDatabase.setDatabaseForTesting(null);
  });

  test('current window first; cache and completion persist atomically across restart', () async {
    await session.initialize(65000);
    expect(session.pending, isTrue);
    expect(session.cuts.where(session.isCutVisible), isEmpty);
    session.resume();
    await until(() => engine.calls.length == 1);
    expect(engine.calls.single.start, 45000);
    expect(engine.calls.single.end, 135000);
    engine.calls.single.done.complete([
      const AudioSegment(
        id: 'result',
        lessonId: 'lesson',
        startMs: 61000,
        endMs: 68000,
        text: 'A whole sentence.',
      ),
    ]);
    await until(() => session.completed.contains(1));
    await session.pause();
    expect(session.pending, isFalse);
    expect(
      session.cuts.where(session.isCutVisible).single.text,
      'A whole sentence.',
    );
    final restored = WhisperWindowSession(
      lesson: lesson,
      repository: repo,
      ai: ai,
      cuts: await repo.getSegmentsForLesson('lesson'),
    );
    await restored.initialize(65000);
    expect(restored.completed, {1});
    expect(restored.pending, isFalse);
    expect(restored.cuts.any((c) => c.text == 'A whole sentence.'), isTrue);
    restored.dispose();
  });

  test('seek preempts background only after native terminal; stale result never commits', () async {
    await session.initialize(1000);
    session.resume();
    await until(() => engine.calls.length == 1);
    session.updatePosition(130000);
    expect(engine.cancelled, [engine.calls.first.id]);
    expect(engine.calls.length, 1);
    engine.calls.first.done.complete([
      const AudioSegment(
        id: 'stale',
        lessonId: 'lesson',
        startMs: 1000,
        endMs: 8000,
        text: 'Stale.',
      ),
    ]);
    await until(() => engine.calls.length == 2);
    expect(engine.calls.last.start, 105000);
    expect(session.completed, isEmpty);
    expect(
      (await repo.getSegmentsForLesson('lesson'))
          .any((c) => c.text == 'Stale.'),
      isFalse,
    );
  });

  test('failure exposes acoustic cuts; retry clears failure and successful silence is cached', () async {
    await session.initialize(1000);
    session.resume();
    await until(() => engine.calls.length == 1);
    engine.calls.first.done.completeError(StateError('decoder failed'));
    await until(() => session.error != null);
    final pause = session.pause();
    for (final call in engine.calls.skip(1)) {
      if (!call.done.isCompleted) {
        call.done.completeError(const AiCancelledException());
      }
    }
    await pause;
    expect(session.pending, isFalse);
    expect(session.cuts.where(session.isCutVisible).first.id, 'acoustic0');
    session.retry();
    await until(() => engine.calls.length >= 2);
    engine.calls.last.done.complete([]);
    await until(() => session.completed.contains(0));
    expect(session.error, isNull);
    expect(session.cuts.any((c) => c.id == 'acoustic0'), isFalse);
  });

  test('no model fails clearly and does not consume cuts', () async {
    engine.loaded = false;
    await session.initialize(1000);
    session.resume();
    await until(() => session.error != null);
    expect(session.error, contains('Load a Whisper model'));
    expect(session.pending, isFalse);
    expect(session.cuts.where(session.isCutVisible).length, 3);
    expect(engine.calls, isEmpty);
  });

  test('revision conflict rolls back completed marker and replacement cuts together', () async {
    await session.initialize(1000);
    session.resume();
    await until(() => engine.calls.length == 1);
    await db.update(
      'audio_segments',
      {'revision': 1},
      where: 'id = ?',
      whereArgs: ['acoustic0'],
    );
    engine.calls.first.done.complete([]);
    await until(() => session.error != null);
    expect(session.completed, isEmpty);
    final current = await repo.getSegmentsForLesson('lesson');
    expect(current.length, 3);
    expect(current.first.revision, 1);
    final stored = await repo.getSetting('whisper_windows_lesson');
    expect(stored, contains('"completed":[]'));
  });
}
