import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:jlexa/features/repeater/repeater_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';
import 'third_pass_correctness_test.dart'
    show ControllableAudioService, FixedSpeechWaveform, TestMockAiEngine;
import 'whisper_window_session_test.dart' show ControlledWindowSpeech;

Future<void> _until(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!ready() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), true);
}

class DelayedWindowWaveform extends FixedSpeechWaveform {
  final result = Completer<List<double>>();
  @override
  Future<List<double>> extractAndCacheWaveform(
    String path,
    String id,
    int duration,
  ) => result.future;
}

class DurationReportingAudio extends ControllableAudioService {
  int? reportedDurationMs;

  @override
  int get durationMs => reportedDurationMs ?? super.durationMs;
}

void main() {
  late Database db;
  late LessonRepository repo;
  late ControlledWindowSpeech speech;
  late AiService ai;
  late DurationReportingAudio audio;
  late RepeaterController controller;
  late AudioLesson lesson;
  setUpAll(() {
    sqfliteFfiInit();
    setupMockPlatformChannels();
  });
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    AppDatabase.setDatabaseForTesting(db);
    await db.execute(
      'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT)',
    );
    await db.execute('''CREATE TABLE audio_lessons (
      id TEXT PRIMARY KEY, title TEXT, original_file_name TEXT, local_path TEXT,
      duration_ms INTEGER, current_position_ms INTEGER, created_at INTEGER,
      last_opened_at INTEGER, transcript_status TEXT, waveform_cache_path TEXT,
      cuts_initialized INTEGER)''');
    await db.execute('''CREATE TABLE audio_segments (id TEXT PRIMARY KEY,
      lesson_id TEXT, start_ms INTEGER, end_ms INTEGER, text TEXT,
      confidence REAL, is_user_edited INTEGER, tokens_json TEXT, revision INTEGER,
      transcript_cut_revision INTEGER, transcript_model_id TEXT)''');
    repo = LessonRepository();
    speech = ControlledWindowSpeech();
    ai = AiService(llm: TestMockAiEngine(), speech: speech);
    audio = DurationReportingAudio();
    lesson = AudioLesson(
      id: 'lesson',
      title: 'Window test',
      originalFileName: 'test.wav',
      localPath: '/fixture.wav',
      durationMs: 180000,
      currentPositionMs: 65000,
      cutsInitialized: true,
      createdAt: DateTime(2026),
      lastOpenedAt: DateTime(2026),
    );
    await repo.saveLesson(lesson);
    await repo.saveSegments(lesson.id, [
      for (var i = 0; i < 3; i++)
        AudioSegment(
          id: 'acoustic$i',
          lessonId: lesson.id,
          startMs: i * 60000 + 1000,
          endMs: i * 60000 + 8000,
          text: '',
        ),
    ]);
    controller = RepeaterController(
      lessonRepo: repo,
      audioService: audio,
      waveformService: FixedSpeechWaveform(),
      aiService: ai,
    );
    await controller.loadLesson(lesson);
  });
  tearDown(() async {
    // Cancellation acknowledgement alone is insufficient. Release all fake
    // terminals before closing SQLite so stale workers can finish rejecting.
    await ai.setWhisperSegmentationEnabled(false);
    for (final call in speech.calls) {
      if (!call.done.isCompleted) {
        call.done.completeError(const AiCancelledException());
      }
    }
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    audio.dispose();
    ai.dispose();
    repo.dispose();
    AppDatabase.setDatabaseForTesting(null);
    await db.close();
  });
  void finish(int call, int window) => speech.calls[call].done.complete([
    AudioSegment(
      id: 'result$window',
      lessonId: lesson.id,
      startMs: window * 60000 + 1000,
      endMs: window * 60000 + 8000,
      text: 'Sentence $window.',
    ),
  ]);

  test('pending waveform preparation never exposes acoustic cuts or enables editing', () async {
    controller.dispose();
    await ai.setWhisperSegmentationEnabled(true);
    final waveform = DelayedWindowWaveform();
    controller = RepeaterController(
      lessonRepo: repo,
      audioService: audio,
      waveformService: waveform,
      aiService: ai,
    );
    final loading = controller.loadLesson(lesson);
    await _until(() => controller.isWaveformLoading);
    expect(controller.isWindowProcessing, true);
    expect(controller.segments, isEmpty);
    expect(controller.canEditCuts, false);
    expect(controller.canAddCut, false);
    waveform.result.complete([]);
    await loading;
    await _until(() => speech.calls.length == 1);
  });

  test('enable hides pending window and prevents editing; background work caches with Auto off', () async {
    expect(speech.calls, isEmpty);
    expect(controller.canEditCuts, true);
    expect(controller.currentSegment?.id, 'acoustic1');
    await ai.setWhisperSegmentationEnabled(true);
    await _until(() => speech.calls.length == 1);
    expect((speech.calls[0].start, speech.calls[0].end), (45000, 135000));
    expect(controller.isWindowProcessing, true);
    expect(controller.currentSegment, null);
    expect(controller.segments, isEmpty);
    expect(controller.canAddCut, false);
    expect(controller.canDeleteCut, false);
    final before = (await repo.getSegmentsForLesson(lesson.id))
        .map((s) => s.toMap())
        .toList();
    await controller.addCutAtPlayhead();
    await controller.deleteCurrentCut();
    await controller.updateSegmentBounds(
      segmentId: 'acoustic1',
      expectedRevision: 0,
      newStartMs: 62000,
      newEndMs: 67000,
    );
    expect(
      (await repo.getSegmentsForLesson(lesson.id))
          .map((s) => s.toMap())
          .toList(),
      before,
    );
    finish(0, 1);
    await _until(() => speech.calls.length == 2);
    expect(
      controller.isWindowProcessing,
      false,
      reason: 'Other-window work must not lock the ready current window.',
    );
    expect(controller.canEditCuts, true);
    expect(controller.currentSegment?.text, 'Sentence 1.');
    expect(controller.visibleTranscriptSegment, null);
    expect(
      (await repo.getSegmentsForLesson(lesson.id))
          .any((s) => s.text == 'Sentence 1.'),
      true,
    );
    await controller.setAutoTranscribe(true);
    expect(controller.visibleTranscriptSegment?.text, 'Sentence 1.');
    await controller.setAutoTranscribe(false);
    expect(controller.visibleTranscriptSegment, null);
    expect(speech.calls, hasLength(2));
    expect(speech.cancelled, isEmpty);
  });

  test('disable cancels background and ignores its late result, preserving completed cache', () async {
    await ai.setWhisperSegmentationEnabled(true);
    await _until(() => speech.calls.length == 1);
    finish(0, 1);
    await _until(() => speech.calls.length == 2);
    final backgroundId = speech.calls[1].id;
    await ai.setWhisperSegmentationEnabled(false);
    expect(speech.cancelled, contains(backgroundId));
    expect(controller.isWindowProcessing, false);
    expect(controller.segments, hasLength(3));
    finish(1, 0);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(speech.calls, hasLength(2));
    final persisted = await repo.getSegmentsForLesson(lesson.id);
    expect(persisted.where((s) => s.hasValidTranscript).map((s) => s.text), [
      'Sentence 1.',
    ]);
    await ai.setWhisperSegmentationEnabled(true);
    await _until(() => speech.calls.length == 3);
    expect(controller.isWindowProcessing, false);
    expect(controller.currentSegment?.text, 'Sentence 1.');
    expect(
      speech.calls[2].start,
      0,
      reason: 'Resume skips completed current window.',
    );
  });

  test('completed windows and current cached selection survive controller recreation', () async {
    await ai.setWhisperSegmentationEnabled(true);
    await _until(() => speech.calls.length == 1);
    finish(0, 1);
    await _until(() => speech.calls.length == 2);
    expect(speech.calls[1].start, 0);
    finish(1, 0);
    await _until(() => speech.calls.length == 3);
    expect(speech.calls[2].start, 105000);
    finish(2, 2);
    await _until(
      () =>
          controller.segments.length == 3 &&
          controller.segments.every((s) => s.hasValidTranscript),
    );
    final saved =
        jsonDecode((await repo.getSetting('whisper_windows_lesson'))!) as Map;
    expect(saved['completed'], unorderedEquals([0, 1, 2]));
    await controller.setAutoTranscribe(true);
    await controller.seekTo(125000);
    expect(controller.visibleTranscriptSegment?.text, 'Sentence 2.');
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    controller = RepeaterController(
      lessonRepo: repo,
      audioService: audio,
      waveformService: FixedSpeechWaveform(),
      aiService: ai,
    );
    await controller.loadLesson((await repo.getLesson(lesson.id))!);
    await _until(
      () =>
          !controller.isWindowProcessing &&
          controller.currentSegment?.text == 'Sentence 2.',
    );
    expect(controller.autoTranscribe, true);
    expect(controller.visibleTranscriptSegment?.text, 'Sentence 2.');
    expect(speech.calls, hasLength(3));
    await controller.setAutoTranscribe(false);
    expect(controller.visibleTranscriptSegment, null);
    expect(controller.canEditCuts, true);
  });

  test('deleting a completed cut atomically protects its neighbors across restart', () async {
    await ai.setWhisperSegmentationEnabled(true);
    for (var i = 0; i < 3; i++) {
      await _until(() => speech.calls.length == i + 1);
      final window = [1, 0, 2][i];
      speech.calls[i].done.complete([
        AudioSegment(
          id: 'result$window',
          lessonId: lesson.id,
          startMs: window * 60000 + 1000,
          endMs: window * 60000 + 8000,
          text: 'Sentence $window.',
          tokens: [
            TranscriptToken(
              text: 'Sentence $window.',
              startMs: window * 60000 + 1000,
              endMs: window * 60000 + 8000,
            ),
          ],
        ),
      ]);
    }
    await _until(
      () =>
          controller.segments.length == 3 &&
          controller.segments.every((c) => c.hasValidTranscript),
    );
    final before = await repo.getSegmentsForLesson(lesson.id);
    expect(before.every((c) => c.tokens.isNotEmpty), true);
    expect(controller.currentSegment?.id, before[1].id);
    final originalRows = before.map((c) => c.toMap()).toList();

    // Fail on the second retained neighbor after the transaction has already
    // deleted the old list and inserted the first. No partial edit may escape.
    await db.execute('''CREATE TRIGGER reject_protected_neighbor
      BEFORE INSERT ON audio_segments
      WHEN NEW.is_user_edited = 1 AND NEW.start_ms > 120000
      BEGIN SELECT RAISE(ABORT, 'injected neighbor save failure'); END''');
    await controller.deleteCurrentCut();
    expect(
      (await repo.getSegmentsForLesson(lesson.id))
          .map((c) => c.toMap())
          .toList(),
      originalRows,
    );
    expect(controller.segments.map((c) => c.toMap()).toList(), originalRows);
    await db.execute('DROP TRIGGER reject_protected_neighbor');

    await controller.deleteCurrentCut();
    final saved = await repo.getSegmentsForLesson(lesson.id);
    expect(saved.map((c) => c.id), [before[0].id, before[2].id]);
    for (var i = 0; i < saved.length; i++) {
      final original = before[i == 0 ? 0 : 2];
      expect(saved[i].isUserEdited, true);
      expect(
        (saved[i].startMs, saved[i].endMs),
        (original.startMs, original.endMs),
      );
      expect(saved[i].text, original.text);
      expect(
        saved[i].tokens.map((t) => t.toMap()).toList(),
        original.tokens.map((t) => t.toMap()).toList(),
      );
      expect(saved[i].revision, original.revision + 1);
      expect(saved[i].transcriptCutRevision, saved[i].revision);
      expect(saved[i].transcriptModelId, original.transcriptModelId);
      expect(saved[i].hasValidTranscript, true);
    }

    controller.dispose();
    controller = RepeaterController(
      lessonRepo: repo,
      audioService: audio,
      waveformService: FixedSpeechWaveform(),
      aiService: ai,
    );
    await controller.loadLesson((await repo.getLesson(lesson.id))!);
    await _until(() => !controller.isWindowProcessing);
    expect(
      controller.segments.map((c) => c.toMap()).toList(),
      saved.map((c) => c.toMap()).toList(),
    );
    expect(speech.calls, hasLength(3));
  });

  test('decoder padding duration difference preserves completed cache after toggling', () async {
    await ai.setWhisperSegmentationEnabled(true);
    await _until(() => speech.calls.length == 1);
    finish(0, 1);
    await _until(() => speech.calls.length == 2);
    finish(1, 0);
    await _until(() => speech.calls.length == 3);
    finish(2, 2);
    await _until(() => controller.segments.every((s) => s.hasValidTranscript));
    final originalCache = await repo.getSetting('whisper_windows_lesson');
    expect((jsonDecode(originalCache!) as Map)['duration'], lesson.durationMs);

    await ai.setWhisperSegmentationEnabled(false);
    audio.reportedDurationMs = lesson.durationMs - 47;
    await audio.seekTo(65000);
    expect(controller.durationMs, lesson.durationMs - 47);
    expect((await repo.getLesson(lesson.id))!.durationMs, lesson.durationMs);
    await ai.setWhisperSegmentationEnabled(true);
    await _until(() => !controller.isWindowProcessing);

    expect(controller.currentSegment?.text, 'Sentence 1.');
    expect(controller.canEditCuts, true);
    expect(speech.calls, hasLength(3));
    expect(await repo.getSetting('whisper_windows_lesson'), originalCache);
  });

  test(
    'zero stored duration is corrected before starting a window session',
    () async {
      lesson = lesson.copyWith(durationMs: 0);
      await repo.saveLesson(lesson);
      audio.reportedDurationMs = 180000;
      await controller.loadLesson(lesson);
      expect((await repo.getLesson(lesson.id))!.durationMs, 180000);
      await ai.setWhisperSegmentationEnabled(true);
      await _until(() => speech.calls.length == 1);
      expect((speech.calls[0].start, speech.calls[0].end), (45000, 135000));
    },
  );

  test('missing model releases pending state with error and Retry starts native window', () async {
    speech.loaded = false;
    await ai.setWhisperSegmentationEnabled(true);
    await _until(() => controller.segmentationError != null);
    expect(controller.isWindowProcessing, false);
    expect(controller.segmentationError, contains('Load a Whisper model'));
    expect(controller.currentSegment?.id, 'acoustic1');
    expect(controller.canEditCuts, true);
    expect(speech.calls, isEmpty);
    speech.loaded = true;
    controller.retryWhisperSegmentation();
    await _until(() => speech.calls.length == 1);
    expect(controller.segmentationError, null);
    expect(controller.isWindowProcessing, true);
    finish(0, 1);
    await _until(() => !controller.isWindowProcessing);
    expect(controller.currentSegment?.text, 'Sentence 1.');
  });

  test('rapid disable-enable waits for previous native terminal before replacing session', () async {
    await ai.setWhisperSegmentationEnabled(true);
    await _until(() => speech.calls.length == 1);
    await ai.setWhisperSegmentationEnabled(false);
    await ai.setWhisperSegmentationEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      speech.calls,
      hasLength(1),
      reason:
          'Old cancellation acknowledgement must not release native ownership.',
    );
    speech.calls.first.done.completeError(const AiCancelledException());
    await _until(() => speech.calls.length == 2);
    expect(controller.isWindowProcessing, true);
  });
}
