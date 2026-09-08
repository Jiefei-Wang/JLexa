import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/ai/ai_models.dart';
import '../../core/ai/backend_benchmark.dart';

class BackendBenchmarkController extends ChangeNotifier {
  final BenchmarkEngine engine;
  final BenchmarkStore store;
  final List<LlamaBackendInfo> backends;
  final LlamaRuntimeSettings runtime;
  final String modelName, storageKey;
  final Future<void> Function()? onFinished;
  final Set<String> selected = {};
  final Map<String, BackendBenchmarkResult> results = {};
  final Map<String, String> rowStates = {};
  final Map<String, String> _outputs = {};
  final Map<String, String> _sources = {};
  bool loading = true, supported = false, running = false, stopping = false;
  String stage = '', activeBackend = '', source = '', output = '', error = '';
  int promptTokens = 0;
  double? livePrefill;
  String? _requestId;
  bool _disposed = false;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Future<void> _saves = Future.value();
  Future<void>? _initialization;

  BackendBenchmarkController({
    required this.engine,
    required this.store,
    required this.backends,
    required this.runtime,
    required this.modelName,
    required String modelPath,
    required String pluginKey,
    this.onFinished,
  }) : storageKey =
           'backend_benchmark_v1:${jsonEncode([modelPath, pluginKey])}' {
    selected.addAll(backends.where((b) => b.available).map((b) => b.backend));
  }
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    try {
      results.addAll(await store.read(storageKey));
    } catch (e) {
      error = 'Could not read previous results: $e';
    }
    try {
      supported = await engine.supportsBenchmark();
      if (!supported) error = 'This plugin does not support benchmark timing. Import an updated plugin.';
      if (!_disposed) {
        _subscription = engine.benchmarkEvents.listen(_onEvent);
      }
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      _notify();
    }
  }

  void toggle(String backend, bool value) {
    if (running || !backends.any((b) => b.backend == backend && b.available)) {
      return;
    }
    if (value) {
      selected.add(backend);
    } else {
      selected.remove(backend);
    }
    _notify();
  }

  void _persist() {
    final snapshot = Map<String, BackendBenchmarkResult>.of(results);
    _saves = _saves.then((_) => store.write(storageKey, snapshot)).catchError((
      Object e,
    ) {
      error = 'Could not save benchmark results: $e';
      _notify();
    });
  }

  void _record(Map<dynamic, dynamic> raw) {
    final backend = raw['backend'] as String;
    final result = BackendBenchmarkResult.fromMap({
      ...raw,
      'time': DateTime.now().toIso8601String(),
      'source': _sources[backend] ?? '',
      'output': _outputs[backend] ?? '',
    });
    results[backend] = result;
    rowStates[backend] = result.status;
    _persist();
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!running || event['requestId'] != _requestId) return;
    stage = event['stage'] as String? ?? '';
    final backend = event['backend'] as String? ?? '';
    if (backend.isNotEmpty) activeBackend = backend;
    switch (stage) {
      case 'loading':
        output = '';
        source = '';
        promptTokens = 0;
        livePrefill = null;
        _outputs[backend] = '';
        rowStates[backend] = 'loading';
      case 'input':
        source = event['text'] as String? ?? '';
        _sources[backend] = source;
      case 'prefill':
        rowStates[backend] = 'prefill';
      case 'decode':
        promptTokens = (event['promptTokens'] as num?)?.toInt() ?? 0;
        final micros = (event['prefillUs'] as num?)?.toInt() ?? 0;
        livePrefill = micros > 0 ? promptTokens * 1000000 / micros : null;
        rowStates[backend] = 'decode';
      case 'token':
        output += event['text'] as String? ?? '';
        _outputs[backend] = output;
      case 'row':
        _record(event['result'] as Map);
      case 'restoring':
        break;
    }
    _notify();
  }

  Future<void> run() async {
    await initialize();
    if (running || _disposed || !supported || selected.isEmpty) return;
    running = true;
    stopping = false;
    error = '';
    source = '';
    output = '';
    _sources.clear();
    _outputs.clear();
    final chosen = backends
        .where((b) => selected.contains(b.backend))
        .map((b) => b.backend)
        .toList();
    for (final b in chosen) {
      rowStates[b] = 'queued';
    }
    final id = const Uuid().v4();
    _requestId = id;
    _notify();
    try {
      final finalResult = await engine.runBenchmark(
        requestId: id,
        backends: chosen,
        runtime: runtime,
      );
      // The terminal method result is authoritative, even if a final event was delayed.
      for (final row in finalResult['rows'] as List? ?? []) {
        final raw = row as Map;
        if (rowStates[raw['backend']] != raw['status']) _record(raw);
      }
      for (final b in chosen) {
        if (const [
          'queued',
          'loading',
          'prefill',
          'decode',
        ].contains(rowStates[b])) {
          rowStates[b] = finalResult['cancelled'] == true
              ? 'cancelled'
              : 'failed';
        }
      }
      if ((finalResult['error'] as String? ?? '').isNotEmpty) {
        error = finalResult['error'] as String;
      }
      stage = finalResult['cancelled'] == true ? 'cancelled' : 'finished';
    } catch (e) {
      error = '$e';
      stage = 'failed';
      for (final b in chosen) {
        if (!const [
          'completed',
          'cancelled',
          'failed',
        ].contains(rowStates[b])) {
          rowStates[b] = 'failed';
        }
      }
    } finally {
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
    if (!running || id == null || stopping) return;
    stopping = true;
    _notify();
    try {
      await engine.stopBenchmark(id);
    } catch (e) {
      error = 'Could not stop: $e';
      stopping = false;
      _notify();
    }
  }

  @override
  void dispose() {
    if (running) unawaited(stop());
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
