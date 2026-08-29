import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/audio/waveform_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../test_helper.dart';

class FakePathProviderPlatform extends PathProviderPlatform {
  final String path;
  FakePathProviderPlatform(this.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jlexa_test_');
    PathProviderPlatform.instance = FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('LessonRepository deleteLesson removes database records, audio file, and waveform cache', () async {
    final lessonRepo = LessonRepository();
    final waveformService = WaveformService();

    final audioFile = File('${tempDir.path}/test_audio.wav');
    await audioFile.writeAsBytes(List.filled(100, 0));

    final lessonId = 'test_del_lesson_1';
    final lesson = AudioLesson(
      id: lessonId,
      title: 'Deletion Test Lesson',
      originalFileName: 'test_audio.wav',
      localPath: audioFile.path,
      durationMs: 5000,
      createdAt: DateTime.now(),
      lastOpenedAt: DateTime.now(),
    );

    await lessonRepo.saveLesson(lesson);
    await lessonRepo.saveSegments(lessonId, [
      AudioSegment(
        id: 'seg_1',
        lessonId: lessonId,
        startMs: 0,
        endMs: 2500,
        text: 'Segment 1',
      ),
      AudioSegment(
        id: 'seg_2',
        lessonId: lessonId,
        startMs: 2500,
        endMs: 5000,
        text: 'Segment 2',
      ),
    ]);

    // Create fake cached peaks file in waveforms directory
    final waveformsDir = Directory('${tempDir.path}/waveforms');
    await waveformsDir.create(recursive: true);
    final peaksFile = File('${waveformsDir.path}/v2_${lessonId}.peaks');
    await peaksFile.writeAsString('0.1,0.5,0.8');

    expect(await audioFile.exists(), isTrue);
    expect(await peaksFile.exists(), isTrue);

    // Delete lesson
    await lessonRepo.deleteLesson(lessonId);

    // Verify database entries removed
    final lessons = await lessonRepo.getAllLessons();
    expect(lessons.any((l) => l.id == lessonId), isFalse);

    final segments = await lessonRepo.getSegmentsForLesson(lessonId);
    expect(segments, isEmpty);

    // Verify local audio and waveform cache files removed
    expect(await audioFile.exists(), isFalse);
    expect(await peaksFile.exists(), isFalse);
  });
}
