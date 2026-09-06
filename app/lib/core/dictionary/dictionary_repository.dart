import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import 'dictionary_models.dart';
import 'offline_dictionary_data.dart';

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
    for (final entry in kOfflineDictionaryEntries) {
      _memoryCache[entry.word.toLowerCase()] = entry;
    }
  }

  @override
  Future<DictionaryEntry?> lookupWord(String word) async {
    final cleanWord = word.trim().toLowerCase();
    if (cleanWord.isEmpty) return null;

    // Save to recent search history
    await addRecentSearch(cleanWord);

    // 1. Check in-memory repository
    if (_memoryCache.containsKey(cleanWord)) {
      return _memoryCache[cleanWord];
    }

    // 2. Query SQLite offline_dictionary table
    try {
      final db = await AppDatabase.instance.database;
      final results = await db.query(
        'offline_dictionary',
        where: 'word = ?',
        whereArgs: [cleanWord],
        limit: 1,
      );

      if (results.isNotEmpty) {
        final row = results.first;
        final entry = _entryFromDbRow(row);
        _memoryCache[cleanWord] = entry;
        return entry;
      }

      // Check prefix query in DB
      final prefixResults = await db.query(
        'offline_dictionary',
        where: 'word LIKE ?',
        whereArgs: ['$cleanWord%'],
        limit: 1,
      );

      if (prefixResults.isNotEmpty) {
        final row = prefixResults.first;
        final entry = _entryFromDbRow(row);
        _memoryCache[cleanWord] = entry;
        return entry;
      }
    } catch (_) {}

    return null;
  }

  DictionaryEntry _entryFromDbRow(Map<String, dynamic> row) {
    return DictionaryEntry(
      word: row['word'] as String,
      phonetic: row['phonetic'] as String? ?? '',
      partOfSpeech: row['part_of_speech'] as String? ?? '',
      definitions: (jsonDecode(row['definitions_json'] as String) as List)
          .map((e) => e.toString())
          .toList(),
      chineseDefinitions: (jsonDecode(
        row['chinese_definitions_json'] as String,
      ) as List).map((e) => e.toString()).toList(),
      examples: (jsonDecode(row['examples_json'] as String) as List)
          .map((e) => ExampleSentence.fromMap(e as Map<String, dynamic>))
          .toList(),
      synonyms: (jsonDecode(row['synonyms_json'] as String) as List)
          .map((e) => e.toString())
          .toList(),
      isHighFrequency: row['is_high_frequency'] == 1,
    );
  }

  @override
  Future<List<String>> searchSuggestions(String query) async {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty) return [];

    final suggestions = <String>{};

    for (final k in _memoryCache.keys) {
      if (k.startsWith(clean)) suggestions.add(k);
      if (suggestions.length >= 6) break;
    }

    if (suggestions.length < 6) {
      try {
        final db = await AppDatabase.instance.database;
        final results = await db.query(
          'offline_dictionary',
          columns: ['word'],
          where: 'word LIKE ?',
          whereArgs: ['$clean%'],
          limit: 6,
        );
        for (final r in results) {
          suggestions.add(r['word'] as String);
        }
      } catch (_) {}
    }

    return suggestions.take(6).toList();
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
      await db.insert('recent_searches', {
        'word': clean,
        'searched_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
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
