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

class VocabularyRepository implements IVocabularyRepository {
  final ISrsScheduler _scheduler;
  final _uuid = const Uuid();

  VocabularyRepository({ISrsScheduler? scheduler})
      : _scheduler = scheduler ?? SimpleSrsScheduler();

  @override
  Future<List<VocabularyWord>> getAllWords() async {
    final db = await AppDatabase.instance.database;
    final results = await db.query(
      'vocabulary',
      orderBy: 'date_added DESC',
    );
    return results.map((e) => VocabularyWord.fromMap(e)).toList();
  }

  @override
  Future<List<VocabularyWord>> getDueWords() async {
    final words = await getAllWords();
    return words.where((w) => w.isDue).toList();
  }

  @override
  Future<VocabularyWord?> getWord(String word) async {
    final clean = word.trim().toLowerCase();
    final db = await AppDatabase.instance.database;
    final results = await db.query(
      'vocabulary',
      where: 'LOWER(word) = ?',
      whereArgs: [clean],
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
    final db = await AppDatabase.instance.database;
    final existing = await getWord(word.word);

    final finalWord = word.id.isEmpty
        ? word.copyWith(id: existing?.id ?? _uuid.v4())
        : word;

    await db.insert(
      'vocabulary',
      finalWord.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
    final updatedWord = _scheduler.scheduleReview(currentWord, rating);

    await db.update(
      'vocabulary',
      updatedWord.toMap(),
      where: 'id = ?',
      whereArgs: [wordId],
    );
  }

  @override
  Future<void> deleteWord(String id) async {
    final db = await AppDatabase.instance.database;
    await db.delete(
      'vocabulary',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
