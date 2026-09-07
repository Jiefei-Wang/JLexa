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

      // Lookup normalizes the key; the saved text remains readable as entered.
      final saved = await repo.getWord('serendipity');
      expect(saved, isNotNull);
      expect(saved!.word, equals('Serendipity!'));

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

  test(
    'Sentences and Unicode text preserve display and match lookup variants',
    () async {
      final repo = VocabularyRepository();
      final examples = {
        'I will meet Alice tomorrow.': 'i will meet alice tomorrow',
        '明天见！': '明天见',
        '“École française”': 'ÉCOLE FRANÇAISE',
        'Will Alice visit 北京 tomorrow?': 'will alice visit 北京 tomorrow',
        '日本語': '日本語',
        'தமிழ்': 'தமிழ்',
      };
      for (final entry in examples.entries) {
        await repo.saveWord(
          VocabularyWord(
            id: entry.key,
            word: '  ${entry.key}  ',
            definitionSnapshot: 'Explanation',
            dateAdded: DateTime.now(),
          ),
        );
        expect((await repo.getWord(entry.value))?.word, entry.key);
      }
      expect(await repo.getAllWords(), hasLength(examples.length));
      expect(
        await repo.getWord('தமிழ'),
        isNull,
        reason: 'Combining marks belong to non-Latin letters.',
      );
    },
  );

  test(
    'Legacy entries keep their ID and review progress when saved again',
    () async {
      final repo = VocabularyRepository();
      final legacy = VocabularyWord(
        id: 'legacy-sentence',
        word: 'i will meet alice tomorrow',
        definitionSnapshot: 'Old explanation',
        dateAdded: DateTime(2025, 1, 2),
        state: VocabularyState.review,
        reviewCount: 7,
        intervalDays: 20,
        easeFactor: 2.7,
        lastReviewed: DateTime(2026, 9, 1),
        nextReview: DateTime(2026, 9, 21),
      );
      await db!.insert('vocabulary', legacy.toMap());
      expect(
        (await repo.getWord('I will meet Alice tomorrow.'))?.id,
        legacy.id,
      );

      await Future.wait(
        List.generate(
          2,
          (index) => repo.saveWord(
            VocabularyWord(
              id: 'duplicate-$index',
              word: 'I will meet Alice tomorrow.',
              definitionSnapshot: 'Updated explanation',
              dateAdded: DateTime.now(),
            ),
          ),
        ),
      );
      final words = await repo.getAllWords();
      expect(words, hasLength(1));
      final saved = words.single;
      expect(saved.id, legacy.id);
      expect(saved.word, 'I will meet Alice tomorrow.');
      expect(saved.definitionSnapshot, 'Updated explanation');
      expect(saved.state, legacy.state);
      expect(saved.dateAdded, legacy.dateAdded);
      expect(saved.reviewCount, legacy.reviewCount);
      expect(saved.intervalDays, legacy.intervalDays);
      expect(saved.easeFactor, legacy.easeFactor);
      expect(saved.lastReviewed, legacy.lastReviewed);
      expect(saved.nextReview, legacy.nextReview);
    },
  );

  test(
    'Empty and punctuation-only saves cannot create inaccessible cards',
    () async {
      final repo = VocabularyRepository();
      for (final text in ['', '   ', '...', '！？']) {
        await expectLater(
          repo.saveWord(
            VocabularyWord(
              id: 'invalid',
              word: text,
              definitionSnapshot: '',
              dateAdded: DateTime.now(),
            ),
          ),
          throwsArgumentError,
        );
      }
      expect(await repo.getAllWords(), isEmpty);
    },
  );
}
