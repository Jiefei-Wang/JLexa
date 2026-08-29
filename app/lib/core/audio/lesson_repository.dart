import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../database/app_database.dart';
import 'audio_models.dart';
import 'waveform_service.dart';

abstract class ILessonRepository implements Listenable {
  Future<List<AudioLesson>> getAllLessons();
  Future<AudioLesson?> getLesson(String id);
  Future<void> saveLesson(AudioLesson lesson);
  Future<void> updateLessonPosition(String id, int positionMs);
  Future<void> updateLessonDuration(String id, int durationMs);
  Future<void> updateTranscriptStatus(String id, String status);
  Future<void> deleteLesson(String id);
  Future<List<AudioSegment>> getSegmentsForLesson(String lessonId);
  Future<void> saveSegments(String lessonId, List<AudioSegment> segments);
  Future<void> updateSegment(AudioSegment segment);
}

class LessonRepository extends ChangeNotifier implements ILessonRepository {
  final _uuid = const Uuid();

  @override
  Future<List<AudioLesson>> getAllLessons() async {
    final db = await AppDatabase.instance.database;
    final results = await db.query(
      'audio_lessons',
      orderBy: 'last_opened_at DESC',
    );

    return results.map((e) => AudioLesson.fromMap(e)).toList();
  }

  @override
  Future<AudioLesson?> getLesson(String id) async {
    final db = await AppDatabase.instance.database;
    final results = await db.query(
      'audio_lessons',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return AudioLesson.fromMap(results.first);
  }

  @override
  Future<void> saveLesson(AudioLesson lesson) async {
    final db = await AppDatabase.instance.database;
    final finalLesson = lesson.id.isEmpty
        ? lesson.copyWith(id: _uuid.v4())
        : lesson;

    await db.insert(
      'audio_lessons',
      finalLesson.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyListeners();
  }

  @override
  Future<void> updateLessonPosition(String id, int positionMs) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      'audio_lessons',
      {
        'current_position_ms': positionMs,
        'last_opened_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  @override
  Future<void> updateLessonDuration(String id, int durationMs) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      'audio_lessons',
      {'duration_ms': durationMs},
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  @override
  Future<void> updateTranscriptStatus(String id, String status) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      'audio_lessons',
      {'transcript_status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  @override
  Future<void> deleteLesson(String id) async {
    final db = await AppDatabase.instance.database;
    final lesson = await getLesson(id);

    await db.delete(
      'audio_lessons',
      where: 'id = ?',
      whereArgs: [id],
    );
    await db.delete(
      'audio_segments',
      where: 'lesson_id = ?',
      whereArgs: [id],
    );

    // Clean up local audio file if it is an app-owned file
    if (lesson != null && !lesson.localPath.startsWith('asset:')) {
      try {
        final audioFile = File(lesson.localPath);
        if (await audioFile.exists()) {
          await audioFile.delete();
        }
      } catch (_) {}
    }

    // Clean up waveform cache
    try {
      final waveformService = WaveformService();
      await waveformService.deleteCachedWaveform(id);
    } catch (_) {}

    notifyListeners();
  }

  @override
  Future<List<AudioSegment>> getSegmentsForLesson(String lessonId) async {
    final db = await AppDatabase.instance.database;
    final results = await db.query(
      'audio_segments',
      where: 'lesson_id = ?',
      whereArgs: [lessonId],
      orderBy: 'start_ms ASC',
    );

    if (results.isEmpty && lessonId == 'lesson_ted_power_of_habit') {
      // Seed sample segments matching the mockup
      final seedSegments = _createSeedSegmentsForTedTalk(lessonId);
      await saveSegments(lessonId, seedSegments);
      return seedSegments;
    }

    return results.map((e) => AudioSegment.fromMap(e)).toList();
  }

  List<AudioSegment> _createSeedSegmentsForTedTalk(String lessonId) {
    return [
      AudioSegment(
        id: 'seg_1',
        lessonId: lessonId,
        startMs: 490000, // 08:10.000
        endMs: 501300,   // 08:21.300
        text: 'Most people think they never have enough time to finish their daily work.',
        confidence: 0.95,
        tokens: const [
          TranscriptToken(text: 'Most', confidence: 0.98),
          TranscriptToken(text: 'people', confidence: 0.99),
          TranscriptToken(text: 'think', confidence: 0.96),
          TranscriptToken(text: 'they', confidence: 0.97),
          TranscriptToken(text: 'never', confidence: 0.95),
          TranscriptToken(text: 'have', confidence: 0.98),
          TranscriptToken(text: 'enough', confidence: 0.92),
          TranscriptToken(text: 'time', confidence: 0.99),
          TranscriptToken(text: 'to', confidence: 0.98),
          TranscriptToken(text: 'finish', confidence: 0.95),
          TranscriptToken(text: 'their', confidence: 0.97),
          TranscriptToken(text: 'daily', confidence: 0.94),
          TranscriptToken(text: 'work.', confidence: 0.96),
        ],
      ),
      AudioSegment(
        id: 'seg_2',
        lessonId: lessonId,
        startMs: 501300, // 08:21.300
        endMs: 511300,   // 08:31.300 (10s)
        text: 'The key is not to prioritize what\'s on your schedule , but to schedule your priorities .',
        confidence: 0.78,
        tokens: const [
          TranscriptToken(text: 'The', confidence: 0.98),
          TranscriptToken(text: 'key', confidence: 0.95),
          TranscriptToken(text: 'is', confidence: 0.99),
          TranscriptToken(text: 'not', confidence: 0.97),
          TranscriptToken(text: 'to', confidence: 0.98),
          TranscriptToken(text: 'prioritize', confidence: 0.88),
          TranscriptToken(text: "what's", confidence: 0.91),
          TranscriptToken(text: 'on', confidence: 0.72),
          TranscriptToken(text: 'your', confidence: 0.70),
          TranscriptToken(text: 'schedule', confidence: 0.68),
          TranscriptToken(text: ',', confidence: 0.99),
          TranscriptToken(text: 'but', confidence: 0.96),
          TranscriptToken(text: 'to', confidence: 0.98),
          TranscriptToken(text: 'schedule', confidence: 0.94),
          TranscriptToken(text: 'your', confidence: 0.96),
          TranscriptToken(text: 'priorities', confidence: 0.74),
          TranscriptToken(text: '.', confidence: 0.99),
        ],
      ),
      AudioSegment(
        id: 'seg_3',
        lessonId: lessonId,
        startMs: 511300, // 08:31.300
        endMs: 524000,   // 08:44.000
        text: 'When you build a resilient mindset, you focus completely on high-impact endeavors.',
        confidence: 0.92,
        tokens: const [
          TranscriptToken(text: 'When', confidence: 0.98),
          TranscriptToken(text: 'you', confidence: 0.97),
          TranscriptToken(text: 'build', confidence: 0.95),
          TranscriptToken(text: 'a', confidence: 0.99),
          TranscriptToken(text: 'resilient', confidence: 0.94),
          TranscriptToken(text: 'mindset,', confidence: 0.93),
          TranscriptToken(text: 'you', confidence: 0.97),
          TranscriptToken(text: 'focus', confidence: 0.96),
          TranscriptToken(text: 'completely', confidence: 0.91),
          TranscriptToken(text: 'on', confidence: 0.98),
          TranscriptToken(text: 'high-impact', confidence: 0.89),
          TranscriptToken(text: 'endeavors.', confidence: 0.92),
        ],
      ),
    ];
  }

  @override
  Future<void> saveSegments(String lessonId, List<AudioSegment> segments) async {
    final db = await AppDatabase.instance.database;
    final batch = db.batch();

    // Clear old segments for this lesson
    batch.delete(
      'audio_segments',
      where: 'lesson_id = ?',
      whereArgs: [lessonId],
    );

    for (final seg in segments) {
      batch.insert(
        'audio_segments',
        seg.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit(noResult: true);
    notifyListeners();
  }

  @override
  Future<void> updateSegment(AudioSegment segment) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      'audio_segments',
      segment.toMap(),
      where: 'id = ?',
      whereArgs: [segment.id],
    );
    notifyListeners();
  }
}
