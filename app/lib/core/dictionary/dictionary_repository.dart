import 'package:sqflite/sqflite.dart';
import '../database/app_database.dart';
import 'demo_dictionary_data.dart';
import 'dictionary_models.dart';

abstract class IDictionaryRepository {
  Future<DictionaryEntry?> lookupWord(String word);
  Future<List<String>> searchSuggestions(String query);
  Future<List<String>> getRecentSearches({int limit = 10});
  Future<void> addRecentSearch(String word);
  Future<void> clearRecentSearches();
}

class DictionaryRepository implements IDictionaryRepository {
  final Map<String, DictionaryEntry> _memoryCache = {};

  DictionaryRepository() {
    for (final entry in kDemoDictionaryEntries) {
      _memoryCache[entry.word.toLowerCase()] = entry;
    }
  }

  @override
  Future<DictionaryEntry?> lookupWord(String word) async {
    final cleanWord = word.trim().toLowerCase();
    if (cleanWord.isEmpty) return null;

    // Save to recent search history
    await addRecentSearch(cleanWord);

    // 1. Check in-memory/demo repository
    if (_memoryCache.containsKey(cleanWord)) {
      return _memoryCache[cleanWord];
    }

    // Check stemming / prefix matches if simple
    for (final entry in _memoryCache.values) {
      if (cleanWord.startsWith(entry.word.toLowerCase()) || entry.word.toLowerCase().startsWith(cleanWord)) {
        return entry;
      }
    }

    return null;
  }

  @override
  Future<List<String>> searchSuggestions(String query) async {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty) return [];

    return _memoryCache.keys
        .where((w) => w.contains(clean))
        .take(6)
        .toList();
  }

  @override
  Future<List<String>> getRecentSearches({int limit = 10}) async {
    try {
      final db = await AppDatabase.instance.database;
      final results = await db.query(
        'recent_searches',
        orderBy: 'searched_at DESC',
        limit: limit,
      );

      final words = results.map((r) => r['word'] as String).toList();
      if (words.isEmpty) {
        // Fallback default seeds from mockup
        return ['resilient', 'meticulous', 'endeavor'];
      }
      return words;
    } catch (_) {
      return ['resilient', 'meticulous', 'endeavor'];
    }
  }

  @override
  Future<void> addRecentSearch(String word) async {
    final clean = word.trim().toLowerCase();
    if (clean.isEmpty) return;

    try {
      final db = await AppDatabase.instance.database;
      await db.insert(
        'recent_searches',
        {
          'word': clean,
          'searched_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  @override
  Future<void> clearRecentSearches() async {
    try {
      final db = await AppDatabase.instance.database;
      await db.delete('recent_searches');
    } catch (_) {}
  }
}
