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

  test('RepeaterController rejects a zero-length cut and preserves positive precision', () async {
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

    await lessonRepo.deleteLesson('bounds_test_lesson');
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
    while (controller.isLoading) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    // Try to update seg1 to invalid bounds past duration or too short
    await controller.updateSegmentBounds(
      segmentId: 'seg_b_1',
      newStartMs: 2000,
      newEndMs: 2100,
    );

    final updatedSeg1 = controller.segments.firstWhere(
      (s) => s.id == 'seg_b_1',
    );
    expect(updatedSeg1.endMs - updatedSeg1.startMs, equals(100));
    expect(updatedSeg1.endMs, lessThanOrEqualTo(seg2.startMs));

    await controller.setBoundaryEditing(true);
    await controller.updateSegmentBounds(
      segmentId: seg1.id,
      newStartMs: 2000,
      newEndMs: 6000,
    );
    expect(controller.segments[1].startMs, 6000);
    expect((await lessonRepo.getSegmentsForLesson(lesson.id))[1].startMs, 4000);
    await controller.updateSegmentBounds(
      segmentId: seg1.id,
      newStartMs: 2000,
      newEndMs: 5000,
    );
    expect(controller.segments[1].startMs, 5000);
    await controller.setBoundaryEditing(false);
    expect((await lessonRepo.getSegmentsForLesson(lesson.id))[1].startMs, 5000);
    await controller.setBoundaryEditing(true);
    await controller.updateSegmentBounds(
      segmentId: seg1.id,
      newStartMs: 2000,
      newEndMs: 3000,
    );
    expect(controller.segments[1].startMs, 5000);
    await controller.setBoundaryEditing(false);
    await controller.setBoundaryEditing(true);
    await controller.mergeSegments({
      for (final c in controller.segments) c.id: c.revision,
    });
    expect(controller.segments, hasLength(1));
    expect(controller.segments.single.startMs, 2000);
    expect(controller.segments.single.endMs, 8000);
    expect(controller.segments.single.id, seg1.id);
    expect(controller.segments.single.isUserEdited, isTrue);
    expect(controller.segments.single.hasValidTranscript, isFalse);
    expect(await lessonRepo.getSegmentsForLesson(lesson.id), hasLength(1));
    controller.dispose();
  });
}
