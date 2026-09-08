import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import 'ai_models.dart';

abstract interface class BenchmarkEngine {
  Stream<Map<String, dynamic>> get benchmarkEvents;
  Future<bool> supportsBenchmark();
  Future<Map<String, dynamic>> runBenchmark({
    required String requestId,
    required List<String> backends,
    required LlamaRuntimeSettings runtime,
  });
  Future<void> stopBenchmark(String requestId);
}

class BackendBenchmarkResult {
  final String backend, status, error, output, source, time;
  final int sourceTokens, promptTokens, generatedTokens, decodedTokens;
  final int prefillUs, decodeUs;
  final Map<String, dynamic> runtime;
  const BackendBenchmarkResult({
    required this.backend,
    this.status = 'completed',
    this.error = '',
    this.output = '',
    this.source = '',
    this.time = '',
    this.sourceTokens = 0,
    this.promptTokens = 0,
    this.generatedTokens = 0,
    this.decodedTokens = 0,
    this.prefillUs = 0,
    this.decodeUs = 0,
    this.runtime = const {},
  });
  double? get prefillSpeed =>
      status == 'completed' && prefillUs > 0 && promptTokens > 0
      ? promptTokens * 1000000 / prefillUs
      : null;
  double? get decodeSpeed =>
      status == 'completed' && decodeUs > 0 && decodedTokens > 0
      ? decodedTokens * 1000000 / decodeUs
      : null;
  factory BackendBenchmarkResult.fromMap(Map<dynamic, dynamic> m) =>
      BackendBenchmarkResult(
        backend: m['backend'] as String,
        status: m['status'] as String? ?? 'failed',
        error: m['error'] as String? ?? '',
        output: m['output'] as String? ?? '',
        source: m['source'] as String? ?? '',
        time: m['time'] as String? ?? '',
        sourceTokens: (m['sourceTokens'] as num?)?.toInt() ?? 0,
        promptTokens: (m['promptTokens'] as num?)?.toInt() ?? 0,
        generatedTokens: (m['generatedTokens'] as num?)?.toInt() ?? 0,
        decodedTokens: (m['decodedTokens'] as num?)?.toInt() ?? 0,
        prefillUs: (m['prefillUs'] as num?)?.toInt() ?? 0,
        decodeUs: (m['decodeUs'] as num?)?.toInt() ?? 0,
        runtime: Map<String, dynamic>.from(m['runtime'] as Map? ?? {}),
      );
  Map<String, dynamic> toMap() => {
    'backend': backend,
    'status': status,
    'error': error,
    'output': output,
    'source': source,
    'time': time,
    'sourceTokens': sourceTokens,
    'promptTokens': promptTokens,
    'generatedTokens': generatedTokens,
    'decodedTokens': decodedTokens,
    'prefillUs': prefillUs,
    'decodeUs': decodeUs,
    'runtime': runtime,
  };
}

abstract interface class BenchmarkStore {
  Future<Map<String, BackendBenchmarkResult>> read(String key);
  Future<void> write(String key, Map<String, BackendBenchmarkResult> results);
}

class DatabaseBenchmarkStore implements BenchmarkStore {
  @override
  Future<Map<String, BackendBenchmarkResult>> read(String key) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return {};
    final value =
        jsonDecode(rows.single['value'] as String) as Map<String, dynamic>;
    return value.map(
      (k, v) => MapEntry(k, BackendBenchmarkResult.fromMap(v as Map)),
    );
  }

  @override
  Future<void> write(
    String key,
    Map<String, BackendBenchmarkResult> results,
  ) async {
    final db = await AppDatabase.instance.database;
    await db.insert('app_settings', {
      'key': key,
      'value': jsonEncode(results.map((k, v) => MapEntry(k, v.toMap()))),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
