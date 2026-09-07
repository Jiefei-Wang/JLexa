import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../audio/audio_models.dart';
import '../database/app_database.dart';
import 'audio_clip_exporter.dart';
import 'collection_models.dart';

class CollectionRepository extends ChangeNotifier {
  final AudioClipExporter _exporter;
  final Future<Database> Function() _database;
  final Future<Directory> Function() _documents;
  final Map<String, Future<CollectionClip>> _saves = {};
  final Map<String, Future<void>> _deletions = {};
  Future<void> _writes = Future.value();
  Future<void>? _recovery;
  bool _disposed = false;

  CollectionRepository({
    AudioClipExporter? exporter,
    Future<Database> Function()? database,
    Future<Directory> Function()? documentsDirectory,
  }) : _exporter = exporter ?? NativeAudioClipExporter(),
       _database = database ?? (() => AppDatabase.instance.database),
       _documents = documentsDirectory ?? getApplicationDocumentsDirectory;

  static String snapshotKey(AudioLesson lesson, AudioSegment segment) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            lesson.id,
            segment.id,
            segment.revision,
            segment.startMs,
            segment.endMs,
            segment.text.trim(),
          ]),
        ),
      )
      .toString();

  Future<Directory> _directory() async {
    final documents = await _documents();
    return Directory(p.join(documents.path, 'collection', 'clips'));
  }

  Future<File> audioFile(CollectionClip clip) async {
    await _ensureRecovered();
    final name = clip.audioFileName;
    if (p.basename(name) != name || !name.endsWith('.wav')) {
      throw StateError('Invalid collection audio filename.');
    }
    return File(p.join((await _directory()).path, name));
  }

  Future<List<CollectionClip>> getClips() async {
    await _writes;
    await _ensureRecovered();
    final db = await _database();
    final rows = await db.query(
      'collection_clips',
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(CollectionClip.fromMap).toList();
  }

  Future<CollectionClip> saveSegment({
    required AudioLesson lesson,
    required AudioSegment segment,
  }) {
    if (segment.lessonId != lesson.id ||
        !segment.hasValidTranscript ||
        segment.startMs < 0 ||
        segment.endMs <= segment.startMs ||
        segment.endMs > lesson.durationMs) {
      return Future.error(
        StateError('Transcribe this segment before saving it.'),
      );
    }
    final key = snapshotKey(lesson, segment);
    return _saves.putIfAbsent(
      key,
      () => _write(() => _save(lesson, segment, key)).whenComplete(() {
        _saves.remove(key);
      }),
    );
  }

  Future<T> _write<T>(Future<T> Function() action) {
    final operation = _writes.then((_) async {
      await _ensureRecovered();
      return action();
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _ensureRecovered() async {
    final recovery = _recovery ??= _recoverFiles();
    try {
      await recovery;
    } catch (_) {
      if (identical(recovery, _recovery)) _recovery = null;
      rethrow;
    }
  }

  Future<void> _recoverFiles() async {
    final db = await _database();
    final rows = await db.query(
      'collection_clips',
      columns: ['audio_file_name'],
    );
    final referenced = rows
        .map((row) => row['audio_file_name'] as String)
        .toSet();
    final directory = await _directory();
    if (!await directory.exists()) return;
    final ownedName = RegExp(r'^[0-9a-fA-F-]{36}\.wav$');
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.deleted')) {
        final original = name.substring(0, name.length - '.deleted'.length);
        if (!ownedName.hasMatch(original)) continue;
        final target = File(p.join(directory.path, original));
        if (referenced.contains(original) && !await target.exists()) {
          await entity.rename(target.path);
        } else {
          await entity.delete();
        }
      } else if ((ownedName.hasMatch(name) && !referenced.contains(name)) ||
          (name.startsWith('.jlexa-clip-') && name.endsWith('.wav.part'))) {
        // A process exit between export and the database commit can leave an orphan.
        await entity.delete();
      }
    }
  }

  Future<CollectionClip> _save(
    AudioLesson lesson,
    AudioSegment segment,
    String key,
  ) async {
    final db = await _database();
    final existing = await db.query(
      'collection_clips',
      where: 'source_key = ?',
      whereArgs: [key],
    );
    if (existing.isNotEmpty) {
      final clip = CollectionClip.fromMap(existing.single);
      final file = await audioFile(clip);
      if (await file.exists() && await file.length() > 44) return clip;
    }
    final directory = await _directory();
    await directory.create(recursive: true);
    final id = const Uuid().v4();
    final file = File(p.join(directory.path, '$id.wav'));
    try {
      final duration = await _exporter.exportClip(
        audioPath: lesson.localPath,
        startMs: segment.startMs,
        endMs: segment.endMs,
        outputPath: file.path,
      );
      if (duration <= 0 || !await file.exists() || await file.length() <= 44) {
        throw StateError('Could not create the collection audio clip.');
      }
      final clip = CollectionClip(
        id: id,
        sourceTitle: lesson.title,
        sourceStartMs: segment.startMs,
        sourceEndMs: segment.endMs,
        durationMs: duration,
        transcript: segment.text.trim(),
        audioFileName: '$id.wav',
        sourceKey: key,
        createdAt: DateTime.now(),
      );
      await db.insert(
        'collection_clips',
        clip.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (!_disposed) notifyListeners();
      return clip;
    } catch (_) {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException catch (_) {
        // Startup recovery removes an uncommitted export if immediate cleanup fails.
      }
      rethrow;
    }
  }

  Future<void> deleteClip(CollectionClip clip) => _deletions.putIfAbsent(
    clip.id,
    () => _write(() => _delete(clip)).whenComplete(() {
      _deletions.remove(clip.id);
    }),
  );

  Future<void> _delete(CollectionClip clip) async {
    final db = await _database();
    final file = await audioFile(clip);
    final removedFile = File('${file.path}.deleted');
    final hadFile = await file.exists();
    if (hadFile) await file.rename(removedFile.path);
    try {
      await db.delete(
        'collection_clips',
        where: 'id = ?',
        whereArgs: [clip.id],
      );
    } catch (_) {
      if (hadFile) await removedFile.rename(file.path);
      rethrow;
    }
    if (!_disposed) notifyListeners();
    if (hadFile) {
      try {
        await removedFile.delete();
      } on FileSystemException catch (_) {
        // The deletion committed; startup recovery will finish file cleanup.
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
