import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/audio_service.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/audio/waveform_service.dart';
import 'package:jlexa/features/repeater/repeater_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  test('RepeaterController updateSegmentBounds clamps within lesson duration and preserves min length', () async {
    final lessonRepo = LessonRepository();
    final audioService = AudioService();
    final waveformService = WaveformService();
    final aiService = AiService();

    final lesson = AudioLesson(
      id: 'bounds_test_lesson',
      title: 'Bounds Test',
      originalFileName: 'test.mp3',
      localPath: 'asset:test.mp3',
      durationMs: 10000,
      createdAt: DateTime.now(),
      lastOpenedAt: DateTime.now(),
    );

    final seg1 = AudioSegment(
      id: 'seg_b_1',
      lessonId: 'bounds_test_lesson',
      startMs: 1000,
      endMs: 4000,
      text: 'First segment',
    );

    final seg2 = AudioSegment(
      id: 'seg_b_2',
      lessonId: 'bounds_test_lesson',
      startMs: 4000,
      endMs: 8000,
      text: 'Second segment',
    );

    await lessonRepo.saveLesson(lesson);
    await lessonRepo.saveSegments('bounds_test_lesson', [seg1, seg2]);

    final controller = RepeaterController(
      lessonRepo: lessonRepo,
      audioService: audioService,
      waveformService: waveformService,
      aiService: aiService,
      initialLesson: lesson,
    );

    // Wait for initial load
    await Future.delayed(const Duration(milliseconds: 200));

    // Try to update seg1 to invalid bounds past duration or too short
    await controller.updateSegmentBounds(
      segmentId: 'seg_b_1',
      newStartMs: 2000,
      newEndMs: 2100, // < 500ms
    );

    final updatedSeg1 = controller.segments.firstWhere(
      (s) => s.id == 'seg_b_1',
    );
    expect(updatedSeg1.endMs - updatedSeg1.startMs, greaterThanOrEqualTo(500));
    expect(updatedSeg1.endMs, lessThanOrEqualTo(seg2.startMs));

    controller.dispose();
  });
}
