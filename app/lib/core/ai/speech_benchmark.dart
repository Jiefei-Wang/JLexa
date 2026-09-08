import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';

abstract interface class SpeechBenchmarkEngine {
  Stream<Map<String, dynamic>> get speechBenchmarkEvents;
  Future<Map<String, dynamic>> runSpeechBenchmark({
    required String requestId,
    required List<String> backends,
  });
  Future<void> stopSpeechBenchmark(String requestId);
}

class SpeechBenchmarkResult {
  final String backend, status, error, shortText, longText, time;
  final int shortUs, longUs;
  const SpeechBenchmarkResult({
    required this.backend,
    this.status = 'completed',
    this.error = '',
    this.shortText = '',
    this.longText = '',
    this.time = '',
    this.shortUs = 0,
    this.longUs = 0,
  });
  factory SpeechBenchmarkResult.fromMap(Map<dynamic, dynamic> m) =>
      SpeechBenchmarkResult(
        backend: m['backend'] as String,
        status: m['status'] as String? ?? 'failed',
        error: m['error'] as String? ?? '',
        shortText: m['shortText'] as String? ?? '',
        longText: m['longText'] as String? ?? '',
        time: m['time'] as String? ?? '',
        shortUs: (m['shortUs'] as num?)?.toInt() ?? 0,
        longUs: (m['longUs'] as num?)?.toInt() ?? 0,
      );
  Map<String, dynamic> toMap() => {
    'backend': backend,
    'status': status,
    'error': error,
    'shortText': shortText,
    'longText': longText,
    'time': time,
    'shortUs': shortUs,
    'longUs': longUs,
  };
}

abstract interface class SpeechBenchmarkStore {
  Future<Map<String, SpeechBenchmarkResult>> read(String key);
  Future<void> write(String key, Map<String, SpeechBenchmarkResult> results);
}

class DatabaseSpeechBenchmarkStore implements SpeechBenchmarkStore {
  @override
  Future<Map<String, SpeechBenchmarkResult>> read(String key) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return {};
    final data =
        jsonDecode(rows.single['value'] as String) as Map<String, dynamic>;
    return data.map(
      (k, v) => MapEntry(k, SpeechBenchmarkResult.fromMap(v as Map)),
    );
  }

  @override
  Future<void> write(
    String key,
    Map<String, SpeechBenchmarkResult> results,
  ) async {
    final db = await AppDatabase.instance.database;
    await db.insert('app_settings', {
      'key': key,
      'value': jsonEncode(results.map((k, v) => MapEntry(k, v.toMap()))),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
