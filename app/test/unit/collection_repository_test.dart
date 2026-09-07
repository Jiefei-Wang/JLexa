import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/collection/audio_clip_exporter.dart';
import 'package:jlexa/core/collection/collection_repository.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Exporter implements AudioClipExporter {
  int calls = 0;
  String? source;
  int? start;
  int? end;
  bool fail = false;
  Completer<void>? gate;

  @override
  Future<int> exportClip({
    required String audioPath,
    required int startMs,
    required int endMs,
    required String outputPath,
  }) async {
    calls++;
    source = audioPath;
    start = startMs;
    end = endMs;
    await File(outputPath).writeAsBytes(List.filled(100, 1));
    await gate?.future;
    if (fail) throw StateError('export failed');
    return endMs - startMs;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late Directory directory;
  late _Exporter exporter;
  late CollectionRepository repo;
  late AudioLesson lesson;
  const segment = AudioSegment(
    id: 'cut',
    lessonId: 'lesson',
    startMs: 1500,
    endMs: 4200,
    text: 'A complete sentence.',
    transcriptCutRevision: 0,
  );

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createCollectionTables(db);
    directory = await Directory.systemTemp.createTemp('collection-test-');
    final source = await File('${directory.path}/source.mp3')
        .writeAsBytes([1, 2, 3]);
    lesson = AudioLesson(
      id: 'lesson',
      title: 'Original lesson',
      originalFileName: 'source.mp3',
      localPath: source.path,
      durationMs: 9000,
      createdAt: DateTime.now(),
      lastOpenedAt: DateTime.now(),
    );
    exporter = _Exporter();
    repo = CollectionRepository(
      exporter: exporter,
      database: () async => db,
      documentsDirectory: () async => directory,
    );
  });
  tearDown(() async {
    repo.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'saved subtitle and cropped audio survive removing the original source',
    () async {
      final clip = await repo.saveSegment(lesson: lesson, segment: segment);
      expect(exporter.source, lesson.localPath);
      expect([exporter.start, exporter.end], [1500, 4200]);
      expect(clip.durationMs, 2700);
      expect(clip.transcript, 'A complete sentence.');
      await File(lesson.localPath).delete();
      expect(await (await repo.audioFile(clip)).exists(), isTrue);
      expect((await repo.getClips()).single.toMap(), clip.toMap());
    },
  );

  test('concurrent saves and repeated taps reuse one snapshot', () async {
    exporter.gate = Completer<void>();
    final a = repo.saveSegment(lesson: lesson, segment: segment);
    final b = repo.saveSegment(lesson: lesson, segment: segment);
    exporter.gate!.complete();
    final clips = await Future.wait([a, b]);
    final again = await repo.saveSegment(lesson: lesson, segment: segment);
    expect(exporter.calls, 1);
    expect(clips[0].id, clips[1].id);
    expect(again.id, clips[0].id);
    expect(await repo.getClips(), hasLength(1));
  });

  test(
    'edited and retranscribed segment becomes an independent collection clip',
    () async {
      final original = await repo.saveSegment(lesson: lesson, segment: segment);
      final edited = segment.copyWith(
        startMs: 1800,
        revision: 1,
        transcriptCutRevision: 1,
        text: 'Edited sentence.',
      );
      final second = await repo.saveSegment(lesson: lesson, segment: edited);
      expect(second.id, isNot(original.id));
      expect(second.sourceStartMs, 1800);
      expect(await repo.getClips(), hasLength(2));
      await repo.deleteClip(second);
      expect((await repo.getClips()).single.transcript, original.transcript);
      expect(await (await repo.audioFile(original)).exists(), isTrue);
      expect(await (await repo.audioFile(second)).exists(), isFalse);
    },
  );

  test('export failure removes partial file and does not add a row', () async {
    exporter.fail = true;
    await expectLater(
      repo.saveSegment(lesson: lesson, segment: segment),
      throwsStateError,
    );
    expect(await repo.getClips(), isEmpty);
    expect(
      await Directory('${directory.path}/collection/clips').list().toList(),
      isEmpty,
    );
    exporter.fail = false;
    await repo.saveSegment(lesson: lesson, segment: segment);
    expect(await repo.getClips(), hasLength(1));
  });

  test('database failure restores a deleted clip file', () async {
    final clip = await repo.saveSegment(lesson: lesson, segment: segment);
    await db.execute(
      "CREATE TRIGGER reject_delete BEFORE DELETE ON collection_clips BEGIN SELECT RAISE(ABORT, 'test failure'); END",
    );
    await expectLater(repo.deleteClip(clip), throwsA(isA<DatabaseException>()));
    expect(await (await repo.audioFile(clip)).exists(), isTrue);
    expect(await repo.getClips(), hasLength(1));
  });

  test('missing clip can be recreated from the source', () async {
    final old = await repo.saveSegment(lesson: lesson, segment: segment);
    await (await repo.audioFile(old)).delete();
    final restored = await repo.saveSegment(lesson: lesson, segment: segment);
    expect(restored.id, isNot(old.id));
    expect(await repo.getClips(), hasLength(1));
    expect(await (await repo.audioFile(restored)).exists(), isTrue);
  });

  test(
    'restart repairs interrupted deletion and removes uncommitted exports',
    () async {
      final clip = await repo.saveSegment(lesson: lesson, segment: segment);
      final file = await repo.audioFile(clip);
      await file.rename('${file.path}.deleted');
      final orphan = File(
        '${file.parent.path}/00000000-0000-0000-0000-000000000000.wav',
      );
      await orphan.writeAsBytes([1]);
      repo.dispose();
      repo = CollectionRepository(
        exporter: exporter,
        database: () async => db,
        documentsDirectory: () async => directory,
      );
      expect(await repo.getClips(), hasLength(1));
      expect(await file.exists(), isTrue);
      expect(await File('${file.path}.deleted').exists(), isFalse);
      expect(await orphan.exists(), isFalse);
    },
  );

  test(
    'save during deletion creates a durable replacement after deletion commits',
    () async {
      final clip = await repo.saveSegment(lesson: lesson, segment: segment);
      final deleting = repo.deleteClip(clip);
      final saving = repo.saveSegment(lesson: lesson, segment: segment);
      await deleting;
      final replacement = await saving;
      expect(replacement.id, isNot(clip.id));
      expect((await repo.getClips()).single.id, replacement.id);
      expect(await (await repo.audioFile(replacement)).exists(), isTrue);
    },
  );

  test('invalid or stale segment does not export', () async {
    for (final invalid in [
      segment.copyWith(text: ''),
      segment.copyWith(revision: 1),
      segment.copyWith(lessonId: 'other'),
      segment.copyWith(endMs: 10000),
      segment.copyWith(startMs: -1),
    ]) {
      await expectLater(
        repo.saveSegment(lesson: lesson, segment: invalid),
        throwsStateError,
      );
    }
    expect(exporter.calls, 0);
  });
}
