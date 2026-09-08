import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/ai/speech_benchmark.dart';

class SpeechBenchmarkController extends ChangeNotifier {
  final SpeechBenchmarkEngine engine;
  final SpeechBenchmarkStore store;
  final Map<String, String> backends;
  final String modelName, storageKey;
  final Future<void> Function()? onFinished;
  final Set<String> selected = {};
  final Map<String, SpeechBenchmarkResult> results = {};
  final Map<String, String> states = {};
  bool loading = true, running = false, stopping = false;
  String error = '', stage = '', activeBackend = '', sample = '', output = '';
  int progress = 0;
  String? _requestId;
  bool _disposed = false;
  Future<void>? _initialization;
  Future<void> _saves = Future.value();
  StreamSubscription<Map<String, dynamic>>? _subscription;

  SpeechBenchmarkController({
    required this.engine,
    required this.store,
    required this.backends,
    required this.modelName,
    required String modelPath,
    this.onFinished,
  }) : storageKey = 'speech_benchmark_v1:${jsonEncode(modelPath)}' {
    selected.addAll(backends.keys);
  }
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    try {
      results.addAll(await store.read(storageKey));
    } catch (e) {
      error = 'Could not read results: $e';
    }
    if (!_disposed) {
      _subscription = engine.speechBenchmarkEvents.listen(_onEvent);
    }
    loading = false;
    _notify();
  }

  void toggle(String backend, bool value) {
    if (running || !backends.containsKey(backend)) return;
    if (value) {
      selected.add(backend);
    } else {
      selected.remove(backend);
    }
    _notify();
  }

  void _record(Map<dynamic, dynamic> raw) {
    final row = SpeechBenchmarkResult.fromMap({
      ...raw,
      'time': DateTime.now().toIso8601String(),
    });
    results[row.backend] = row;
    states[row.backend] = row.status;
    final snapshot = Map<String, SpeechBenchmarkResult>.of(results);
    _saves = _saves.then((_) => store.write(storageKey, snapshot)).catchError((
      Object e,
    ) {
      error = 'Could not save results: $e';
      _notify();
    });
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!running || event['requestId'] != _requestId) return;
    stage = event['stage'] as String? ?? '';
    activeBackend = event['backend'] as String? ?? activeBackend;
    sample = event['sample'] as String? ?? sample;
    if (stage == 'loading') {
      output = '';
      progress = 0;
      sample = '';
    }
    if (stage == 'progress') {
      progress = (event['progress'] as num?)?.toInt() ?? 0;
    }
    if (stage == 'sample') output = event['text'] as String? ?? '';
    if (stage == 'row') {
      _record(event['result'] as Map);
    } else if (stage != 'restoring') {
      states[activeBackend] = stage;
    }
    _notify();
  }

  Future<void> run() async {
    await initialize();
    if (running || _disposed || selected.isEmpty) return;
    running = true;
    stopping = false;
    error = '';
    output = '';
    stage = 'loading';
    final chosen = backends.keys.where(selected.contains).toList();
    for (final b in chosen) {
      states[b] = 'queued';
    }
    final id = const Uuid().v4();
    _requestId = id;
    _notify();
    try {
      final result = await engine.runSpeechBenchmark(
        requestId: id,
        backends: chosen,
      );
      for (final row in result['rows'] as List? ?? []) {
        _record(row as Map);
      }
      stage = result['cancelled'] == true ? 'cancelled' : 'finished';
      final nativeError = result['error'] as String? ?? '';
      if (nativeError.isNotEmpty) error = nativeError;
    } catch (e) {
      error = '$e';
      stage = 'failed';
    } finally {
      for (final b in chosen) {
        if (!const ['completed', 'cancelled', 'failed'].contains(states[b])) {
          states[b] = stage == 'cancelled' ? 'cancelled' : 'failed';
        }
      }
      await _saves;
      try {
        await onFinished?.call();
      } catch (e) {
        error = '$e';
      }
      running = false;
      stopping = false;
      _requestId = null;
      _notify();
    }
  }

  Future<void> stop() async {
    final id = _requestId;
    if (!running || stopping || id == null) return;
    stopping = true;
    _notify();
    try {
      await engine.stopSpeechBenchmark(id);
    } catch (e) {
      error = '$e';
      stopping = false;
      _notify();
    }
  }

  @override
  void dispose() {
    unawaited(stop());
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
