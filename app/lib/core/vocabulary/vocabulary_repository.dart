import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import 'srs_scheduler.dart';
import 'vocabulary_models.dart';

abstract class IVocabularyRepository {
  Future<List<VocabularyWord>> getAllWords();
  Future<List<VocabularyWord>> getDueWords();
  Future<VocabularyWord?> getWord(String word);
  Future<bool> isWordSaved(String word);
  Future<void> saveWord(VocabularyWord word);
  Future<void> reviewWord(String wordId, ReviewRating rating);
  Future<void> deleteWord(String id);
}

class VocabularyRepository extends ChangeNotifier
    implements IVocabularyRepository {
  final ISrsScheduler _scheduler;
  final _uuid = const Uuid();
  static final _whitespace = RegExp(r'\s+');
  static final _surroundingPunctuation = RegExp(
    r'^[^\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+$',
    unicode: true,
  );

  VocabularyRepository({ISrsScheduler? scheduler})
    : _scheduler = scheduler ?? SimpleSrsScheduler();

  @override
  Future<List<VocabularyWord>> getAllWords() async {
    final db = await AppDatabase.instance.database;
    final results = await db.query('vocabulary', orderBy: 'date_added DESC');
    return results.map((e) => VocabularyWord.fromMap(e)).toList();
  }

  @override
  Future<List<VocabularyWord>> getDueWords() async {
    final words = await getAllWords();
    return words.where((w) => w.isDue).toList();
  }

  @override
  Future<VocabularyWord?> getWord(String word) async {
    final db = await AppDatabase.instance.database;
    return _getWord(db, word);
  }

  // Vocabulary contains sentences and non-English text as well as word tokens.
  // Keep their display text intact, using this key only for duplicate matching.
  // It also matches English entries normalized by earlier app versions.
  static String _lookupKey(String text) => text
      .trim()
      .replaceAll(_whitespace, ' ')
      .replaceAll(_surroundingPunctuation, '')
      .toLowerCase();

  Future<VocabularyWord?> _getWord(DatabaseExecutor db, String word) async {
    final key = _lookupKey(word);
    if (key.isEmpty) return null;

    // SQLite LOWER only folds ASCII. Match in Dart for consistent Unicode
    // behavior without rewriting saved data or requiring a schema migration.
    final candidates = await db.query('vocabulary', columns: ['id', 'word']);
    String? id;
    for (final row in candidates) {
      if (_lookupKey(row['word'] as String) == key) {
        id = row['id'] as String;
        break;
      }
    }
    if (id == null) return null;

    final results = await db.query(
      'vocabulary',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return VocabularyWord.fromMap(results.first);
  }

  @override
  Future<bool> isWordSaved(String word) async {
    final item = await getWord(word);
    return item != null;
  }

  @override
  Future<void> saveWord(VocabularyWord word) async {
    final displayText = word.word.trim();
    if (_lookupKey(displayText).isEmpty) {
      throw ArgumentError.value(word.word, 'word', 'Enter a word or sentence.');
    }
    final db = await AppDatabase.instance.database;
    await db.transaction((txn) async {
      final existing = await _getWord(txn, displayText);
      final finalWord = word.copyWith(
        id: existing?.id ?? (word.id.isEmpty ? _uuid.v4() : word.id),
        word: displayText,
        state: existing?.state,
        dateAdded: existing?.dateAdded,
        lastReviewed: existing?.lastReviewed,
        nextReview: existing?.nextReview,
        reviewCount: existing?.reviewCount,
        intervalDays: existing?.intervalDays,
        easeFactor: existing?.easeFactor,
      );
      await txn.insert(
        'vocabulary',
        finalWord.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    notifyListeners();
  }

  @override
  Future<void> reviewWord(String wordId, ReviewRating rating) async {
    final db = await AppDatabase.instance.database;
    final results = await db.query(
      'vocabulary',
      where: 'id = ?',
      whereArgs: [wordId],
      limit: 1,
    );

    if (results.isEmpty) return;
    final currentWord = VocabularyWord.fromMap(results.first);
    final updatedWord = previewReview(currentWord, rating);

    await db.update(
      'vocabulary',
      updatedWord.toMap(),
      where: 'id = ?',
      whereArgs: [wordId],
    );
    notifyListeners();
  }

  /// Uses the same scheduler as a committed review without changing storage.
  VocabularyWord previewReview(
    VocabularyWord word,
    ReviewRating rating, {
    DateTime? now,
  }) => _scheduler.scheduleReview(word, rating, now: now);

  @override
  Future<void> deleteWord(String id) async {
    final db = await AppDatabase.instance.database;
    await db.delete('vocabulary', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }
}
