import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/database/app_database.dart';
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
  Database? db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jlexa_test_');
    PathProviderPlatform.instance = FakePathProviderPlatform(tempDir.path);
    final dbPath =
        '${tempDir.path}/test_${DateTime.now().microsecondsSinceEpoch}.db';
    db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE audio_lessons (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            original_file_name TEXT NOT NULL,
            local_path TEXT NOT NULL,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            current_position_ms INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            last_opened_at INTEGER NOT NULL,
            transcript_status TEXT NOT NULL DEFAULT 'none',
            waveform_cache_path TEXT
          )
        ''');
        await d.execute('''
          CREATE TABLE audio_segments (
            id TEXT PRIMARY KEY,
            lesson_id TEXT NOT NULL,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            text TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 1.0,
            is_user_edited INTEGER NOT NULL DEFAULT 0,
            tokens_json TEXT,
            FOREIGN KEY (lesson_id) REFERENCES audio_lessons (id) ON DELETE CASCADE
          )
        ''');
      },
    );
    AppDatabase.setDatabaseForTesting(db);
  });

  tearDown(() async {
    await db?.close();
    AppDatabase.setDatabaseForTesting(null);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('LessonRepository deleteLesson removes database records, audio file, and waveform cache', () async {
    final lessonRepo = LessonRepository();

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
    final peaksFile = File('${waveformsDir.path}/v2_$lessonId.peaks');
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
