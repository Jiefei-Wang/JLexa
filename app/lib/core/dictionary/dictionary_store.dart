import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'dictionary_import.dart';
import 'dictionary_models.dart';
import 'offline_dictionary_data.dart';

class ManagedDictionary {
  final String id, name, format;
  final int count;
  final bool enabled, builtIn;
  const ManagedDictionary({
    required this.id,
    required this.name,
    required this.format,
    required this.count,
    required this.enabled,
    required this.builtIn,
  });
  factory ManagedDictionary.fromRow(Map<String, Object?> row) =>
      ManagedDictionary(
        id: row['id'] as String,
        name: row['name'] as String,
        format: row['format'] as String,
        count: row['entry_count'] as int,
        enabled: row['enabled'] == 1,
        builtIn: row['builtin'] == 1,
      );
}

/// Separate catalog and index keep dictionary imports independent of app data.
/// Only a successfully parsed, fully indexed dictionary becomes visible.
class DictionaryStore {
  static final instance = DictionaryStore();
  final Database? testingDatabase;
  Future<Database>? _opening;
  DictionaryStore({this.testingDatabase});

  Future<Database> get database => _opening ??= _open().catchError((Object e) {
    _opening = null;
    throw e;
  });

  Future<Database> _open() async {
    final db =
        testingDatabase ??
        await openDatabase(
          p.join(await getDatabasesPath(), 'dictionary-catalog-v1.db'),
          version: 1,
        );
    await db.transaction((txn) async {
      await txn.execute(
        'CREATE TABLE IF NOT EXISTS dictionaries ('
        'id TEXT PRIMARY KEY, name TEXT NOT NULL, format TEXT NOT NULL, '
        'entry_count INTEGER NOT NULL, enabled INTEGER NOT NULL, builtin INTEGER NOT NULL)',
      );
      await txn.execute(
        'CREATE TABLE IF NOT EXISTS dictionary_entries ('
        'dictionary_id TEXT NOT NULL, word TEXT NOT NULL, display_word TEXT NOT NULL, '
        'definition TEXT NOT NULL, redirect TEXT)',
      );
      await txn.execute(
        'CREATE INDEX IF NOT EXISTS dictionary_word ON dictionary_entries(word, dictionary_id)',
      );
      for (final row in [
        {'id': 'builtin-ecdict', 'name': 'ECDICT', 'entry_count': 57961},
        {
          'id': 'builtin-core',
          'name': 'JLexa Core',
          'entry_count': kOfflineDictionaryEntries.length,
        },
      ]) {
        await txn.insert('dictionaries', {
          ...row,
          'format': 'Built-in',
          'enabled': 1,
          'builtin': 1,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
    return db;
  }

  Future<List<ManagedDictionary>> list() async => (await (await database).query(
    'dictionaries',
    orderBy: 'builtin DESC, rowid DESC',
  )).map(ManagedDictionary.fromRow).toList();

  Future<void> setEnabled(String id, bool value) async {
    final changed = await (await database).update(
      'dictionaries',
      {'enabled': value ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (changed != 1) throw StateError('Dictionary no longer exists.');
  }

  Future<void> delete(String id) async {
    await (await database).transaction((txn) async {
      final rows = await txn.query(
        'dictionaries',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (rows.isEmpty) return;
      if (rows.single['builtin'] == 1) {
        throw StateError('Built-in dictionaries can be disabled.');
      }
      await txn.delete(
        'dictionary_entries',
        where: 'dictionary_id = ?',
        whereArgs: [id],
      );
      await txn.delete('dictionaries', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<ManagedDictionary> importFile(
    String path, {
    Directory? temporaryDirectory,
  }) async {
    final root = temporaryDirectory ?? await getTemporaryDirectory();
    final stagingRoot = await Directory(p.join(root.path, 'dictionary-import'))
        .create(recursive: true);
    final staging = await stagingRoot.createTemp('job-');
    try {
      final source = File(path);
      if (await source.length() > dictionaryImportLimit) {
        throw const FormatException(
          'Dictionary exceeds the 256 MB import limit.',
        );
      }
      // Own a stable private copy before handing it to a background parser.
      final copied = await source.copy(p.join(staging.path, p.basename(path)));
      final output = p.join(staging.path, 'entries.jsonl');
      final sourcePath = copied.path;
      final metadata = await Isolate.run(
        () => prepareDictionaryImport(sourcePath, output),
      );
      final id = const Uuid().v4();
      final db = await database;
      await db.transaction((txn) async {
        var batch = txn.batch();
        var pending = 0;
        await for (final line in File(
          output,
        ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
          final record = jsonDecode(line) as List;
          batch.insert('dictionary_entries', {
            'dictionary_id': id,
            'word': (record[0] as String).toLowerCase(),
            'display_word': record[0],
            'definition': record[1],
            'redirect': record[2],
          });
          if (++pending == 500) {
            await batch.commit(noResult: true);
            batch = txn.batch();
            pending = 0;
          }
        }
        if (pending > 0) await batch.commit(noResult: true);
        await txn.insert('dictionaries', {
          'id': id,
          'name': metadata['name'],
          'format': metadata['format'],
          'entry_count': metadata['count'],
          'enabled': 1,
          'builtin': 0,
        });
      });
      return (await list()).singleWhere((d) => d.id == id);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<DictionaryEntry?> lookup(String word) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT e.*, d.name FROM dictionary_entries e '
      'JOIN dictionaries d ON d.id = e.dictionary_id '
      'WHERE d.enabled = 1 AND e.word = ? ORDER BY d.rowid DESC, e.rowid',
      [word],
    );
    if (rows.isEmpty) return null;
    final definitions = <String>[];
    for (final row in rows) {
      var current = row;
      final visited = <String>{word};
      for (var hops = 0; current['redirect'] != null && hops < 16; hops++) {
        final target = current['redirect'] as String;
        if (!visited.add(target)) break;
        final resolved = await db.query(
          'dictionary_entries',
          where: 'dictionary_id = ? AND word = ?',
          whereArgs: [row['dictionary_id'], target],
          limit: 1,
        );
        if (resolved.isEmpty) break;
        current = resolved.single;
      }
      if (current['redirect'] != null) continue;
      final text = '${row['name']}\n${current['definition']}';
      if (!definitions.contains(text)) definitions.add(text);
    }
    if (definitions.isEmpty) return null;
    return DictionaryEntry(
      word: rows.first['display_word'] as String,
      phonetic: '',
      partOfSpeech: '',
      definitions: definitions,
    );
  }

  Future<List<String>> suggestions(String prefix) async =>
      (await (await database).rawQuery(
        'SELECT DISTINCT e.word FROM dictionary_entries e '
        'JOIN dictionaries d ON d.id = e.dictionary_id WHERE d.enabled = 1 '
        'AND e.word >= ? AND e.word < ? ORDER BY e.word LIMIT 6',
        [prefix, '$prefix\uffff'],
      )).map((r) => r['word'] as String).toList();
}
