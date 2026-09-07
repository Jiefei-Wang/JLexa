import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v3 upgrade creates Collection while preserving existing lessons and settings', () async {
    final originalPath = await databaseFactoryFfi.getDatabasesPath();
    final directory = await Directory.systemTemp.createTemp(
      'jlexa-v3-upgrade-',
    );
    await databaseFactoryFfi.setDatabasesPath(directory.path);
    await AppDatabase.instance.close();
    addTearDown(() async {
      await AppDatabase.instance.close();
      await databaseFactoryFfi.setDatabasesPath(originalPath);
      await directory.delete(recursive: true);
    });

    // Version 4 only adds collection_clips; removing it reconstructs v3's
    // actual schema while retaining the other tables and their constraints.
    final old = await AppDatabase.instance.database;
    await old.execute('DROP TABLE collection_clips');
    await old.setVersion(3);
    final lesson = AudioLesson(
      id: 'existing',
      title: 'Existing lesson',
      originalFileName: 'lesson.mp3',
      localPath: '/saved/lesson.mp3',
      durationMs: 9000,
      createdAt: DateTime(2026, 9, 6),
      lastOpenedAt: DateTime(2026, 9, 7),
    );
    await old.insert('audio_lessons', lesson.toMap());
    await old.insert('app_settings', {
      'key': 'migration_marker',
      'value': 'preserved',
    });
    await AppDatabase.instance.close();

    final upgraded = await AppDatabase.instance.database;
    expect(await upgraded.getVersion(), 4);
    expect(await upgraded.query('collection_clips'), isEmpty);
    expect(
      (await upgraded.query('audio_lessons')).single['title'],
      'Existing lesson',
    );
    expect(
      (await upgraded.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['migration_marker'],
      )).single['value'],
      'preserved',
    );
    await AppDatabase.instance.close();
    final reopened = await AppDatabase.instance.database;
    expect(await reopened.getVersion(), 4);
    expect(await reopened.query('collection_clips'), isEmpty);
    expect(await reopened.query('audio_lessons'), hasLength(1));
  });
}
