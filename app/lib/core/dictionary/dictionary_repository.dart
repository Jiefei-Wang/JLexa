import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import 'dictionary_models.dart';
import 'offline_dictionary_data.dart';
import 'bundled_dictionary.dart';
import 'dictionary_store.dart';

abstract class IDictionaryRepository {
  Future<DictionaryEntry?> lookupWord(String word);
  Future<List<String>> searchSuggestions(String query);
  Future<List<String>> getRecentSearches({int limit = 10});
  Future<void> addRecentSearch(String word);
  Future<void> clearRecentSearches();
}

class DictionaryRepository extends ChangeNotifier
    implements IDictionaryRepository {
  final Map<String, DictionaryEntry> _memoryCache = {};
  final DictionaryStore dictionaries;

  DictionaryRepository({DictionaryStore? store})
    : dictionaries = store ?? DictionaryStore.instance {
    for (final entry in kOfflineDictionaryEntries) {
      _memoryCache[entry.word.toLowerCase()] = entry;
    }
  }

  Future<List<ManagedDictionary>> managedDictionaries() => dictionaries.list();
  Future<void> setDictionaryEnabled(String id, bool enabled) async {
    await dictionaries.setEnabled(id, enabled);
    notifyListeners();
  }

  Future<void> deleteDictionary(String id) async {
    await dictionaries.delete(id);
    notifyListeners();
  }

  Future<ManagedDictionary> importDictionary(String path) async {
    final result = await dictionaries.importFile(path);
    notifyListeners();
    return result;
  }

  Future<Set<String>> _enabledBuiltins() async {
    try {
      return (await dictionaries.list())
          .where((d) => d.builtIn && d.enabled)
          .map((d) => d.id)
          .toSet();
    } catch (_) {
      return {'builtin-core', 'builtin-ecdict'};
    }
  }

  @override
  Future<DictionaryEntry?> lookupWord(String word) async {
    final cleanWord = word.trim().toLowerCase();
    if (cleanWord.isEmpty) return null;

    // Save to recent search history
    await addRecentSearch(cleanWord);

    DictionaryEntry? imported;
    try {
      imported = await dictionaries.lookup(cleanWord);
    } catch (_) {}
    final builtIn = await _lookupBuiltIn(cleanWord, await _enabledBuiltins());
    if (imported == null) return builtIn;
    if (builtIn == null) return imported;
    return DictionaryEntry(
      word: builtIn.word,
      phonetic: builtIn.phonetic,
      partOfSpeech: builtIn.partOfSpeech,
      definitions: [...imported.definitions, ...builtIn.definitions],
      chineseDefinitions: builtIn.chineseDefinitions,
      examples: builtIn.examples,
      synonyms: builtIn.synonyms,
      isHighFrequency: builtIn.isHighFrequency,
    );
  }

  Future<DictionaryEntry?> _lookupBuiltIn(
    String cleanWord,
    Set<String> enabled,
  ) async {
    // 1. Check in-memory repository
    if (enabled.contains('builtin-core') &&
        _memoryCache.containsKey(cleanWord)) {
      return _memoryCache[cleanWord];
    }

    // 2. Query SQLite offline_dictionary table
    if (enabled.contains('builtin-core')) {
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
          return entry;
        }
      } catch (_) {}
    }

    if (enabled.contains('builtin-ecdict')) {
      try {
        final entry = await BundledDictionary.lookup(cleanWord);
        if (entry != null) {
          return entry;
        }
      } catch (_) {}
    }

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
    final enabled = await _enabledBuiltins();
    try {
      suggestions.addAll(await dictionaries.suggestions(clean));
    } catch (_) {}

    for (final k
        in enabled.contains('builtin-core') ? _memoryCache.keys : <String>[]) {
      if (k.startsWith(clean)) suggestions.add(k);
      if (suggestions.length >= 6) break;
    }

    if (suggestions.length < 6 && enabled.contains('builtin-core')) {
      try {
        final db = await AppDatabase.instance.database;
        final results = await db.query(
          'offline_dictionary',
          columns: ['word'],
          where: 'word >= ? AND word < ?',
          whereArgs: [clean, '$clean\uffff'],
          orderBy: 'word',
          limit: 6,
        );
        for (final r in results) {
          suggestions.add(r['word'] as String);
        }
      } catch (_) {}
    }

    if (suggestions.length < 6 && enabled.contains('builtin-ecdict')) {
      try {
        suggestions.addAll(await BundledDictionary.suggestions(clean));
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
      return words;
    } catch (_) {
      return [];
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
