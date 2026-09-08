import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/backend_benchmark.dart';
import 'package:jlexa/features/settings/backend_benchmark_controller.dart';
import 'package:jlexa/features/settings/backend_benchmark_screen.dart';

class FakeBenchmarkEngine implements BenchmarkEngine {
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final done = Completer<Map<String, dynamic>>();
  bool supported = true;
  String? id, stopped;
  List<String>? chosen;
  @override
  Stream<Map<String, dynamic>> get benchmarkEvents => events.stream;
  @override
  Future<bool> supportsBenchmark() async => supported;
  @override
  Future<Map<String, dynamic>> runBenchmark({
    required String requestId,
    required List<String> backends,
    required LlamaRuntimeSettings runtime,
  }) {
    id = requestId;
    chosen = backends;
    return done.future;
  }

  @override
  Future<void> stopBenchmark(String requestId) async {
    stopped = requestId;
  }

  void emit(
    String stage, {
    String backend = 'cpu',
    Map<String, dynamic> extra = const {},
  }) {
    events.add({'requestId': id, 'stage': stage, 'backend': backend, ...extra});
  }
}

class MemoryBenchmarkStore implements BenchmarkStore {
  Map<String, BackendBenchmarkResult> rows = {};
  bool failRead = false;
  @override
  Future<Map<String, BackendBenchmarkResult>> read(String key) async {
    if (failRead) throw const FormatException('bad JSON');
    return Map.of(rows);
  }

  @override
  Future<void> write(
    String key,
    Map<String, BackendBenchmarkResult> results,
  ) async {
    rows = Map.of(results);
  }
}

const backends = [
  LlamaBackendInfo(backend: 'cpu', compiled: true, available: true),
  LlamaBackendInfo(backend: 'vulkan', compiled: true, available: true),
  LlamaBackendInfo(
    backend: 'opencl',
    compiled: false,
    available: false,
    reasonUnavailable: 'Not compiled',
  ),
];
Map<String, dynamic> row(String backend) => {
  'backend': backend,
  'status': 'completed',
  'sourceTokens': 100,
  'promptTokens': 121,
  'generatedTokens': 100,
  'decodedTokens': 100,
  'prefillUs': 1000000,
  'decodeUs': 2000000,
};

void main() {
  late FakeBenchmarkEngine engine;
  late MemoryBenchmarkStore store;
  BackendBenchmarkController controller({
    Future<void> Function()? onFinished,
    String model = 'model.gguf',
    String plugin = 'builtin',
  }) => BackendBenchmarkController(
    engine: engine,
    store: store,
    backends: backends,
    runtime: const LlamaRuntimeSettings(),
    modelName: 'Qwen',
    modelPath: model,
    pluginKey: plugin,
    onFinished: onFinished,
  );
  setUp(() {
    engine = FakeBenchmarkEngine();
    store = MemoryBenchmarkStore();
  });
  tearDown(() async {
    await engine.events.close();
  });

  test('real token counts and native microseconds determine rates', () {
    final r = BackendBenchmarkResult.fromMap(row('cpu'));
    expect(r.sourceTokens, 100);
    expect(r.prefillSpeed, 121);
    expect(r.decodeSpeed, 50);
    expect(BackendBenchmarkResult.fromMap(r.toMap()).decodeSpeed, 50);
    expect(
      BackendBenchmarkResult.fromMap({...row('cpu'), 'status': 'cancelled'})
          .decodeSpeed,
      isNull,
    );
    expect(
      BackendBenchmarkResult.fromMap({...row('cpu'), 'decodeUs': 0})
          .decodeSpeed,
      isNull,
    );
  });

  test('defaults all available, retains previous results, isolates model/plugin history', () async {
    store.rows['cpu'] = BackendBenchmarkResult.fromMap(row('cpu'));
    final c = controller();
    await c.initialize();
    expect(c.selected, {'cpu', 'vulkan'});
    c.toggle('opencl', true);
    expect(c.selected, {'cpu', 'vulkan'});
    expect(c.results['cpu']!.decodeSpeed, 50);
    final otherModel = controller(model: 'other.gguf');
    final otherPlugin = controller(plugin: 'external');
    expect(c.storageKey, isNot(otherModel.storageKey));
    expect(c.storageKey, isNot(otherPlugin.storageKey));
    c.dispose();
    otherModel.dispose();
    otherPlugin.dispose();
  });

  test('selected rows only, live text, persisted results and original-state refresh', () async {
    var refreshed = 0;
    final c = controller(
      onFinished: () async {
        refreshed++;
      },
    );
    await c.initialize();
    c.toggle('vulkan', false);
    final run = c.run();
    await Future<void>.delayed(Duration.zero);
    expect(engine.chosen, ['cpu']);
    c.toggle('cpu', false);
    expect(c.selected, {'cpu'});
    engine.emit('loading');
    engine.emit('input', extra: {'text': 'English passage'});
    engine.emit('decode', extra: {'promptTokens': 121, 'prefillUs': 1000000});
    engine.emit('token', extra: {'text': '中文'});
    expect(c.source, 'English passage');
    expect(c.output, '中文');
    expect(c.livePrefill, 121);
    engine.emit('row', extra: {'result': row('cpu')});
    engine.done.complete({
      'rows': [row('cpu')],
      'restored': true,
    });
    await run;
    expect(refreshed, 1);
    expect(c.running, false);
    expect(store.rows['cpu']!.output, '中文');
    expect(store.rows['cpu']!.source, 'English passage');
    expect(store.rows['cpu']!.time, isNotEmpty);
    final reopened = controller();
    await reopened.initialize();
    expect(reopened.results['cpu']!.decodeSpeed, 50);
    c.dispose();
    reopened.dispose();
  });

  test(
    'cancel stays busy until restoration finishes and ignores stale events',
    () async {
      final c = controller();
      await c.initialize();
      final run = c.run();
      await Future<void>.delayed(Duration.zero);
      engine.emit('loading');
      engine.events.add({
        'requestId': 'old',
        'stage': 'token',
        'text': 'stale',
      });
      expect(c.output, isEmpty);
      await c.stop();
      expect(engine.stopped, engine.id);
      expect(c.running, true);
      expect(c.stopping, true);
      engine.emit('restoring', backend: '');
      engine.done.complete({'rows': [], 'cancelled': true, 'restored': true});
      await run;
      expect(c.running, false);
      expect(c.rowStates.values, everyElement('cancelled'));
      engine.emit('token', extra: {'text': 'too late'});
      expect(c.output, isEmpty);
      c.dispose();
    },
  );

  test(
    'terminal rows survive missing events and restore failure is explicit',
    () async {
      final c = controller();
      await c.initialize();
      final run = c.run();
      await Future<void>.delayed(Duration.zero);
      engine.done.complete({
        'rows': [
          row('cpu'),
          {'backend': 'vulkan', 'status': 'failed', 'error': 'driver'},
        ],
        'restored': false,
        'error': 'Could not restore the previous model/backend',
      });
      await run;
      expect(c.results['cpu']!.prefillSpeed, 121);
      expect(c.results['vulkan']!.error, 'driver');
      expect(c.error, contains('Could not restore'));
      c.dispose();
    },
  );

  test(
    'old plugin has a clear unsupported message without starting a run',
    () async {
      engine.supported = false;
      final c = controller();
      await c.run();
      expect(c.error, contains('does not support'));
      expect(engine.chosen, isNull);
      c.dispose();
    },
  );

  test('corrupt prior history does not disable benchmarking; method failure clears busy', () async {
    store.failRead = true;
    final c = controller();
    await c.initialize();
    expect(c.supported, true);
    final run = c.run();
    await Future<void>.delayed(Duration.zero);
    engine.done.completeError(StateError('load failed'));
    await run;
    expect(c.running, false);
    expect(c.rowStates.values, everyElement('failed'));
    expect(c.error, contains('load failed'));
    c.dispose();
  });

  testWidgets(
    'narrow screen with large text shows table and persistent stop control',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      store.rows['cpu'] = BackendBenchmarkResult.fromMap(row('cpu'));
      final c = controller();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: BackendBenchmarkScreen(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('121.0'), findsOneWidget);
      expect(find.textContaining('Translate 100 English'), findsNothing);
      expect(find.textContaining('Speeds are native'), findsNothing);
      expect(
        tester.widgetList<Checkbox>(find.byType(Checkbox)).map((b) => b.value),
        [true, true, false],
      );
      await tester.tap(find.text('Test'));
      await tester.pump();
      engine.emit('loading');
      engine.emit('input', extra: {'text': 'An English source passage.'});
      engine.emit('token', extra: {'text': '实时翻译'});
      await tester.pump();
      expect(find.text('Stop'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Stop'));
      await tester.pump();
      expect(engine.stopped, engine.id);
      await tester.runAsync(() async {
        engine.done.complete({'rows': [], 'cancelled': true, 'restored': true});
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(c.running, false);
      await tester.pumpAndSettle();
      expect(find.text('Test'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
