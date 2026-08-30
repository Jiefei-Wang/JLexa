import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:jlexa/core/vocabulary/vocabulary_models.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';

void main() {
  late Directory tempDir;
  Database? db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jlexa_vocab_test_');
    final dbPath =
        '${tempDir.path}/test_${DateTime.now().microsecondsSinceEpoch}.db';
    db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE vocabulary (
            id TEXT PRIMARY KEY,
            word TEXT NOT NULL UNIQUE,
            phonetic TEXT,
            part_of_speech TEXT,
            definition_snapshot TEXT,
            translation_snapshot TEXT,
            source TEXT,
            source_sentence TEXT,
            state TEXT NOT NULL DEFAULT 'newWord',
            date_added INTEGER NOT NULL,
            last_reviewed INTEGER,
            next_review INTEGER,
            review_count INTEGER NOT NULL DEFAULT 0,
            interval_days INTEGER NOT NULL DEFAULT 0,
            ease_factor REAL NOT NULL DEFAULT 2.5
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

  test(
    'VocabularyRepository notifies listeners on save, review, and delete',
    () async {
      final repo = VocabularyRepository();
      int notificationCount = 0;
      repo.addListener(() {
        notificationCount++;
      });

      final word = VocabularyWord(
        id: 'voc_test_notifier_1',
        word: '  Serendipity!  ',
        definitionSnapshot: 'Finding good things without looking',
        dateAdded: DateTime.now(),
      );

      // Save word
      await repo.saveWord(word);
      expect(notificationCount, equals(1));

      // Verify word was normalized
      final saved = await repo.getWord('serendipity');
      expect(saved, isNotNull);
      expect(saved!.word, equals('serendipity'));

      // Review word
      await repo.reviewWord('voc_test_notifier_1', ReviewRating.good);
      expect(notificationCount, equals(2));

      // Delete word
      await repo.deleteWord('voc_test_notifier_1');
      expect(notificationCount, equals(3));

      final deleted = await repo.getWord('serendipity');
      expect(deleted, isNull);
    },
  );
}
