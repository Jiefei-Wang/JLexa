import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
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
  Future<void> updateTranscriptStatus(String id, TranscriptStatus status);
  Future<void> deleteLesson(String id);
  Future<List<AudioSegment>> getSegmentsForLesson(String lessonId);
  Future<void> saveSegments(String lessonId, List<AudioSegment> segments);
  Future<void> updateSegment(AudioSegment segment);
  Future<void> commitCutSet(
    String lessonId,
    Map<String, int> expectedRevisions,
    List<AudioSegment> cuts,
  );
  Future<void> setCutsInitialized(String lessonId, bool initialized);
  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);
}

class LessonRepository extends ChangeNotifier implements ILessonRepository {
  final _uuid = const Uuid();

  Future<String> audioFingerprint(String path) async =>
      (await sha256.bind(File(path).openRead()).first).toString();

  Future<void> setAudioFingerprint(String id, String hash) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      'audio_lessons',
      {'source_hash': hash},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Recognizes identical bytes even when the picker copied/renamed the file.
  /// Old lessons are fingerprinted lazily, without replacing their cut rows.
  Future<AudioLesson?> findByAudioFingerprint(String hash) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'audio_lessons',
      orderBy: 'last_opened_at DESC',
    );
    for (final row in rows) {
      var stored = row['source_hash'] as String?;
      if (stored == null) {
        final file = File(row['local_path'] as String);
        if (!await file.exists()) continue;
        stored = await audioFingerprint(file.path);
        await setAudioFingerprint(row['id'] as String, stored);
      }
      if (stored == hash && await File(row['local_path'] as String).exists()) {
        return AudioLesson.fromMap(row);
      }
    }
    return null;
  }

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
    // Intentionally do NOT call notifyListeners() here.
    // Position-only updates during playback should not trigger Home DB reloads.
    // Home refreshes on structural changes (save/delete/import/status).
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
  Future<void> updateTranscriptStatus(
    String id,
    TranscriptStatus status,
  ) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      'audio_lessons',
      {'transcript_status': status.toDbString()},
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  @override
  Future<void> deleteLesson(String id) async {
    final db = await AppDatabase.instance.database;
    final lesson = await getLesson(id);

    await db.delete('audio_lessons', where: 'id = ?', whereArgs: [id]);
    await db.delete('audio_segments', where: 'lesson_id = ?', whereArgs: [id]);
    await db.delete(
      'app_settings',
      where: 'key = ?',
      whereArgs: ['whisper_windows_$id'],
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

    return results.map((e) => AudioSegment.fromMap(e)).toList();
  }

  @override
  Future<void> saveSegments(
    String lessonId,
    List<AudioSegment> segments,
  ) async {
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

    batch.update(
      'audio_lessons',
      {'cuts_initialized': 1},
      where: 'id = ?',
      whereArgs: [lessonId],
    );

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

  @override
  Future<void> setCutsInitialized(String lessonId, bool initialized) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      'audio_lessons',
      {'cuts_initialized': initialized ? 1 : 0},
      where: 'id = ?',
      whereArgs: [lessonId],
    );
  }

  /// Atomically replaces the cut set after verifying the gesture/request
  /// snapshot. A failed or stale commit changes nothing.
  @override
  Future<void> commitCutSet(
    String lessonId,
    Map<String, int> expectedRevisions,
    List<AudioSegment> cuts,
  ) => _commitCuts(lessonId, expectedRevisions, cuts);

  /// Window completion and its cuts must survive (or roll back) together.
  Future<void> commitWhisperWindow(
    String lessonId,
    Map<String, int> expectedRevisions,
    List<AudioSegment> cuts,
    String windowState,
  ) => _commitCuts(lessonId, expectedRevisions, cuts, windowState: windowState);

  Future<void> _commitCuts(
    String lessonId,
    Map<String, int> expectedRevisions,
    List<AudioSegment> cuts, {
    String? windowState,
  }) async {
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final current = await txn.query(
        'audio_segments',
        columns: ['id', 'revision'],
        where: 'lesson_id = ?',
        whereArgs: [lessonId],
      );
      final revisions = <String, int>{
        for (final row in current)
          row['id'] as String: row['revision'] as int? ?? 0,
      };
      if (revisions.length != expectedRevisions.length ||
          expectedRevisions.entries.any((e) => revisions[e.key] != e.value)) {
        throw StateError('Cuts changed before the edit could be saved.');
      }
      await txn.delete(
        'audio_segments',
        where: 'lesson_id = ?',
        whereArgs: [lessonId],
      );
      for (final cut in cuts) {
        await txn.insert('audio_segments', cut.toMap());
      }
      await txn.update(
        'audio_lessons',
        {'cuts_initialized': 1},
        where: 'id = ?',
        whereArgs: [lessonId],
      );
      if (windowState != null) {
        await txn.insert('app_settings', {
          'key': 'whisper_windows_$lessonId',
          'value': windowState,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    notifyListeners();
  }

  @override
  Future<String?> getSetting(String key) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  @override
  Future<void> setSetting(String key, String value) async {
    final db = await AppDatabase.instance.database;
    await db.insert('app_settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
