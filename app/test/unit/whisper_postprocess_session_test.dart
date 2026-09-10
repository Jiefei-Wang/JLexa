import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/audio/whisper_cut_postprocessor.dart';
import 'package:jlexa/core/audio/whisper_window_session.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'whisper_window_session_test.dart' show ControlledWindowSpeech, until;

AudioSegment saved(String id, int start, int end, {bool manual = false}) =>
    AudioSegment(
      id: id,
      lessonId: 'lesson',
      startMs: start,
      endMs: end,
      text: '$id.',
      isUserEdited: manual,
      transcriptCutRevision: 0,
      transcriptModelId: 'tiny.en',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late LessonRepository repo;
  late ControlledWindowSpeech engine;
  late AiService ai;
  late AudioLesson lesson;
  final sessions = <WhisperWindowSession>[];
  final energyCalls =
      <({int start, int end, Completer<AudioEnergyEnvelope> done})>[];

  AudioEnergyEnvelope envelope({int minimum = 2135}) {
    final values = List<double>.filled(12000, 1);
    values[minimum ~/ 10] = 0;
    return AudioEnergyEnvelope(startMs: 0, stepMs: 10, values: values);
  }

  Future<AudioEnergyEnvelope> loadEnergy(int start, int end) {
    final done = Completer<AudioEnergyEnvelope>();
    energyCalls.add((start: start, end: end, done: done));
    return done.future;
  }

  Future<Map<String, dynamic>> state() async =>
      jsonDecode((await repo.getSetting('whisper_windows_lesson'))!)
          as Map<String, dynamic>;

  Future<WhisperWindowSession> open(int position) async {
    final session = WhisperWindowSession(
      lesson: lesson,
      repository: repo,
      ai: ai,
      cuts: await repo.getSegmentsForLesson('lesson'),
      loadEnergy: loadEnergy,
    );
    sessions.add(session);
    await session.initialize(position);
    return session;
  }

  Future<void> seed(
    List<AudioSegment> cuts, {
    List<int> completed = const [0, 1],
  }) async {
    for (final cut in cuts) {
      await db.insert('audio_segments', cut.toMap());
    }
    await repo.setSetting(
      'whisper_windows_lesson',
      jsonEncode({
        'version': 1,
        'path': lesson.localPath,
        'duration': lesson.durationMs,
        'windows': [
          [0, 0, 60000, 0, 75000],
          [1, 60000, 120000, 45000, 120000],
        ],
        'completed': completed,
      }),
    );
  }

  setUp(() async {
    sessions.clear();
    energyCalls.clear();
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
    engine = ControlledWindowSpeech()..loaded = false;
    ai = AiService(speech: engine);
    lesson = AudioLesson(
      id: 'lesson',
      title: 'Test',
      originalFileName: 'test.wav',
      localPath: '/test.wav',
      durationMs: 120000,
      createdAt: DateTime(2026),
      lastOpenedAt: DateTime(2026),
    );
  });

  tearDown(() async {
    final stopping = sessions.map((s) => s.pause()).toList();
    for (final call in engine.calls) {
      if (!call.done.isCompleted) {
        call.done.completeError(const AiCancelledException());
      }
    }
    for (final call in energyCalls) {
      if (!call.done.isCompleted) call.done.complete(envelope());
    }
    await Future.wait(stopping);
    for (final s in sessions) {
      s.dispose();
    }
    repo.dispose();
    await db.close();
    AppDatabase.setDatabaseForTesting(null);
  });

  test('version one cache splits long sentence once while preserving manual neighbors', () async {
    final fixture = jsonDecode(
      File('test/fixtures/whisper_small_long_sentence.json').readAsStringSync(),
    );
    final long = AudioSegment.fromMap(Map<String, dynamic>.from(fixture['cut']))
        .copyWith(lessonId: 'lesson');
    final manual = saved('manual', 113000, 119000, manual: true);
    await seed([long, manual]);
    final old = await state();
    old['polishVersion'] = 1;
    old['polished'] = [0, 1];
    old['adjustedPairs'] = [WhisperCutPostprocessor.pairKey(long, manual)];
    await repo.setSetting('whisper_windows_lesson', jsonEncode(old));
    final s = await open(95000);
    s.resume();
    await until(() => energyCalls.isNotEmpty);
    energyCalls.first.done.complete(
      AudioEnergyEnvelope(
        startMs: fixture['startMs'],
        stepMs: 10,
        values: (fixture['values'] as List)
            .cast<num>()
            .map((v) => v.toDouble())
            .toList(),
      ),
    );
    await until(() => s.cuts.length == 4);
    await until(() => energyCalls.length == 2);
    energyCalls.last.done.complete(envelope());
    await until(() => !s.pending);
    await s.pause();
    expect(s.cuts.take(3).every((c) => c.durationMs <= 10000), isTrue);
    expect(s.cuts.last.toMap(), manual.toMap());
    expect(engine.calls, isEmpty);
    final snapshot = s.cuts.map((c) => c.toMap()).toList();
    final restored = await open(95000);
    restored.resume();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(energyCalls.length, 2);
    expect(restored.cuts.map((c) => c.toMap()), snapshot);
  });

  test('old completed cache polishes without model; restart and resume do not drift', () async {
    await seed([
      saved('a', 0, 2000),
      saved('b', 2200, 6000),
      saved('short', 8000, 9000),
      saved('c', 11000, 13000),
      saved('manual', 65000, 66000, manual: true),
    ]);
    final s = await open(1000);
    expect(s.pending, isTrue);
    s.resume();
    await until(() => energyCalls.length == 1);
    energyCalls[0].done.complete(envelope());
    await until(() => s.cuts.first.endMs == 2135);
    await until(() => energyCalls.length == 2);
    // A stronger new minimum must not move the already adjusted shared boundary again.
    s.updatePosition(65000);
    energyCalls[1].done.complete(envelope(minimum: 2305));
    await until(() => !s.pending);
    await until(() => s.cuts.length == 4);
    await s.pause();
    final persisted = await repo.getSegmentsForLesson('lesson');
    expect(persisted.map((c) => (c.startMs, c.endMs)), [
      (0, 2135),
      (2135, 6000),
      (8000, 13000),
      (65000, 66000),
    ]);
    expect(persisted[2].text, 'short. c.');
    expect(persisted.every((c) => c.hasValidTranscript), isTrue);
    final metadata = await state();
    expect(metadata['completed'], unorderedEquals([0, 1]));
    expect(metadata['polished'], unorderedEquals([0, 1]));
    expect(metadata['polishVersion'], 2);
    expect(
      metadata['adjustedPairs'],
      contains(WhisperCutPostprocessor.pairKey(persisted[0], persisted[1])),
    );
    expect(engine.calls, isEmpty);
    final restored = await open(1000);
    restored.resume();
    restored.resume();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(energyCalls, hasLength(2));
    expect(restored.pending, isFalse);
    expect(
      restored.cuts.map((c) => c.toMap()),
      persisted.map((c) => c.toMap()),
    );
  });

  test(
    'pause rejects pending migration result and retry persists later result',
    () async {
      await seed([saved('a', 0, 2000), saved('b', 2200, 6000)]);
      final s = await open(1000);
      s.resume();
      await until(() => energyCalls.length == 1);
      final stopped = s.pause();
      energyCalls[0].done.complete(envelope());
      await stopped;
      expect((await repo.getSegmentsForLesson('lesson')).first.endMs, 2000);
      expect((await state())['polished'], isNull);
      s.retry();
      await until(() => energyCalls.length == 2);
      energyCalls[1].done.complete(envelope());
      await until(() => s.cuts.first.endMs == 2135);
      final stopping = s.pause();
      for (final call in energyCalls.skip(2)) {
        if (!call.done.isCompleted) call.done.complete(envelope());
      }
      await stopping;
      expect((await state())['polished'], contains(0));
      expect(engine.calls, isEmpty);
    },
  );

  test(
    'seek invalidates migration energy before starting newly selected window',
    () async {
      await seed([
        saved('a', 0, 2000),
        saved('b', 2200, 6000),
        saved('c', 61000, 64000),
      ]);
      final s = await open(1000);
      s.resume();
      await until(() => energyCalls.length == 1);
      s.updatePosition(65000);
      energyCalls[0].done.complete(envelope());
      await until(() => energyCalls.length == 2);
      expect(energyCalls[1].start, 45000);
      expect((await repo.getSegmentsForLesson('lesson')).first.endMs, 2000);
      expect((await state())['polished'], isNull);
      final stopping = s.pause();
      energyCalls[1].done.complete(envelope());
      await stopping;
      s.retry();
      await until(() => energyCalls.length == 3);
      expect(energyCalls[2].start, 45000);
      energyCalls[2].done.complete(envelope());
      await until(() => !s.pending);
      expect((await state())['polished'], contains(1));
      expect(engine.calls, isEmpty);
    },
  );

  test('reverse windows adjust a shared automatic boundary once and preserve manual cuts', () async {
    await seed([
      saved('left', 56000, 59900),
      saved('right', 60100, 64000),
      saved('manual', 64200, 65200, manual: true),
    ]);
    final s = await open(62000);
    s.resume();
    await until(() => energyCalls.length == 1);
    expect(energyCalls[0].start, 45000);
    energyCalls[0].done.complete(envelope(minimum: 60035));
    await until(() => s.cuts.first.endMs == 60035);
    expect(s.cuts[1].startMs, 60035);
    await until(() => energyCalls.length == 2);
    expect(energyCalls[1].start, 0);
    s.updatePosition(1000);
    energyCalls[1].done.complete(envelope(minimum: 60135));
    await until(() => !s.pending);
    await s.pause();
    final persisted = await repo.getSegmentsForLesson('lesson');
    expect(persisted.map((c) => (c.startMs, c.endMs, c.revision)), [
      (56000, 60035, 1),
      (60035, 64000, 1),
      (64200, 65200, 0),
    ]);
    expect(persisted.last.isUserEdited, isTrue);
    expect((await state())['polished'], unorderedEquals([0, 1]));
  });

  test('reverse recognition defers a short boundary cut until both neighbors are ready', () async {
    engine.loaded = true;
    await seed([
      saved('acousticLeft', 58000, 59500).copyWith(clearTranscript: true),
      saved('acousticRight', 61000, 66000).copyWith(clearTranscript: true),
      saved('manual', 68000, 69000, manual: true),
    ], completed: []);
    final s = await open(62000);
    s.resume();
    await until(() => engine.calls.length == 1);
    expect(engine.calls[0].start, 45000);
    engine.calls[0].done.complete([
      saved('short', 61000, 62000),
      saved('long', 64000, 66000),
    ]);
    await until(() => energyCalls.length == 1);
    energyCalls[0].done.complete(envelope());
    await until(() => s.completed.contains(1));
    expect(
      s.cuts.any((c) => c.text == 'short.' && c.durationMs == 1000),
      isTrue,
    );
    expect(s.cuts.any((c) => c.text == 'long.'), isTrue);
    await until(() => engine.calls.length == 2);
    expect(engine.calls[1].start, 0);
    engine.calls[1].done.complete([saved('left', 58000, 59500)]);
    await until(() => energyCalls.length == 2);
    energyCalls[1].done.complete(envelope());
    await until(() => s.completed.length == 2);
    await s.pause();
    final persisted = await repo.getSegmentsForLesson('lesson');
    expect(persisted.map((c) => (c.startMs, c.endMs, c.text)), [
      (58000, 62000, 'left. short.'),
      (64000, 66000, 'long.'),
      (68000, 69000, 'manual.'),
    ]);
    expect(persisted.last.isUserEdited, isTrue);
    expect(persisted.every((c) => c.hasValidTranscript), isTrue);
  });
}
