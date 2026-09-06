import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'dictionary_models.dart';

/// Immutable, separately versioned data; never migrates or replaces user data.
class BundledDictionary {
  static Future<Database>? _opening;

  static Future<Database> _open() =>
      _opening ??= _copyAndOpen().catchError((Object error) {
        _opening = null;
        throw error;
      });

  static Future<Database> _copyAndOpen() async {
    final path = p.join(await getDatabasesPath(), 'ecdict-v1.db');
    final file = File(path);
    if (!await file.exists()) {
      final data = await rootBundle.load('assets/dictionary/ecdict-v1.db');
      await file.parent.create(recursive: true);
      final partial = File('$path.part');
      await partial.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await partial.rename(path);
    }
    return openDatabase(path, readOnly: true);
  }

  static Future<DictionaryEntry?> lookup(String word) async {
    final db = await _open();
    final rows = await db.query(
      'entries',
      where: 'word = ?',
      whereArgs: [word],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return DictionaryEntry(
      word: row['word'] as String,
      phonetic: row['phonetic'] as String? ?? '',
      partOfSpeech: row['pos'] as String? ?? '',
      definitions: (row['definition'] as String)
          .split('\n')
          .where((s) => s.isNotEmpty)
          .toList(),
      chineseDefinitions: (row['translation'] as String)
          .split('\n')
          .where((s) => s.isNotEmpty)
          .toList(),
      examples: const [],
      synonyms: const [],
    );
  }

  static Future<List<String>> suggestions(String prefix) async {
    final db = await _open();
    final rows = await db.query(
      'entries',
      columns: ['word'],
      where: 'word >= ? AND word < ?',
      whereArgs: [prefix, '$prefix\uffff'],
      orderBy: 'word',
      limit: 6,
    );
    return rows.map((r) => r['word'] as String).toList();
  }
}
