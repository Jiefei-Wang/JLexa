import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/native_ai_bridge.dart';
import 'package:jlexa/core/ai/speech_benchmark.dart';
import 'package:jlexa/features/settings/speech_benchmark_controller.dart';
import 'package:jlexa/features/settings/speech_benchmark_screen.dart';

class FakeSpeechBenchmark implements SpeechBenchmarkEngine {
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final done = Completer<Map<String, dynamic>>();
  String? id, stopped;
  List<String>? chosen;
  @override
  Stream<Map<String, dynamic>> get speechBenchmarkEvents => events.stream;
  @override
  Future<Map<String, dynamic>> runSpeechBenchmark({
    required String requestId,
    required List<String> backends,
  }) {
    id = requestId;
    chosen = backends;
    return done.future;
  }

  @override
  Future<void> stopSpeechBenchmark(String requestId) async {
    stopped = requestId;
  }
}

class MemorySpeechStore implements SpeechBenchmarkStore {
  Map<String, SpeechBenchmarkResult> rows = {};
  @override
  Future<Map<String, SpeechBenchmarkResult>> read(String key) async =>
      Map.of(rows);
  @override
  Future<void> write(
    String key,
    Map<String, SpeechBenchmarkResult> results,
  ) async {
    rows = Map.of(results);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeSpeechBenchmark engine;
  late MemorySpeechStore store;
  late SpeechBenchmarkController controller;
  var restored = 0;
  setUp(() {
    engine = FakeSpeechBenchmark();
    store = MemorySpeechStore();
    restored = 0;
    controller = SpeechBenchmarkController(
      engine: engine,
      store: store,
      backends: {'cpu': 'CPU', 'plugin:test': 'Optimized'},
      modelName: 'Tiny',
      modelPath: '/tiny.bin',
      onFinished: () async {
        restored++;
      },
    );
  });
  tearDown(() {
    controller.dispose();
    unawaited(engine.events.close());
  });

  test(
    'selected backends, progress, final measurements and persistence',
    () async {
      await controller.initialize();
      expect(controller.selected, {'cpu', 'plugin:test'});
      controller.toggle('plugin:test', false);
      final running = controller.run();
      await Future<void>.delayed(Duration.zero);
      expect(engine.chosen, ['cpu']);
      engine.events.add({
        'requestId': 'old',
        'stage': 'sample',
        'text': 'stale',
      });
      expect(controller.output, '');
      engine.events.add({
        'requestId': engine.id,
        'stage': 'progress',
        'backend': 'cpu',
        'sample': 'short',
        'progress': 50,
      });
      expect(controller.progress, 50);
      engine.events.add({
        'requestId': engine.id,
        'stage': 'sample',
        'backend': 'cpu',
        'text': 'Please open the window.',
      });
      expect(controller.output, 'Please open the window.');
      engine.done.complete({
        'rows': [
          {
            'backend': 'cpu',
            'status': 'completed',
            'shortUs': 500000,
            'longUs': 1500000,
          },
        ],
        'cancelled': false,
      });
      await running;
      expect(restored, 1);
      expect(store.rows['cpu']?.shortUs, 500000);
      expect(store.rows['cpu']?.longUs, 1500000);
      expect(controller.running, false);
    },
  );

  test(
    'stop waits for native restoration and preserves prior untested results',
    () async {
      store.rows['plugin:test'] = const SpeechBenchmarkResult(
        backend: 'plugin:test',
        shortUs: 1234,
      );
      await controller.initialize();
      final running = controller.run();
      await Future<void>.delayed(Duration.zero);
      await controller.stop();
      expect(engine.stopped, engine.id);
      expect(controller.running, true);
      expect(controller.stopping, true);
      engine.done.complete({
        'rows': [
          {'backend': 'cpu', 'status': 'cancelled'},
        ],
        'cancelled': true,
      });
      await running;
      expect(controller.states['plugin:test'], 'cancelled');
      expect(controller.results['plugin:test']?.shortUs, 1234);
      expect(restored, 1);
    },
  );

  testWidgets('minimal table shows saved durations and test button', (
    tester,
  ) async {
    store.rows['cpu'] = const SpeechBenchmarkResult(
      backend: 'cpu',
      shortUs: 500000,
      longUs: 1500000,
    );
    await tester.pumpWidget(
      MaterialApp(home: SpeechBenchmarkScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Short (s)'), findsOneWidget);
    expect(find.text('Long (s)'), findsOneWidget);
    expect(find.text('0.50'), findsOneWidget);
    expect(find.text('1.50'), findsOneWidget);
    expect(find.text('Test'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    // Screen owns and disposes its controller.
    controller = SpeechBenchmarkController(
      engine: engine,
      store: store,
      backends: const {},
      modelName: '',
      modelPath: '',
    );
  });

  testWidgets('narrow table supports large text and long plugin names', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    controller.backends['plugin:test'] =
        'JLexa Whisper Snapdragon Optimized CPU';
    controller.states['plugin:test'] = 'failed';
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: SpeechBenchmarkScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Test'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller = SpeechBenchmarkController(
      engine: engine,
      store: store,
      backends: const {},
      modelName: '',
      modelPath: '',
    );
  });

  test('native benchmark owns speech slot until terminal result', () async {
    const channel = MethodChannel('com.jlexa.app/whisper');
    const stream = MethodChannel('com.jlexa.app/whisper_stream');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final done = Completer<Map<String, dynamic>>();
    messenger.setMockMethodCallHandler(stream, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'loadModel') return true;
      if (call.method == 'runBenchmark') return done.future;
      return null;
    });
    final native = NativeWhisperEngine.forTesting();
    await native.loadModel('/tiny.bin');
    final running = native.runSpeechBenchmark(
      requestId: 'bench',
      backends: ['cpu'],
    );
    expect(native.isBusy, true);
    await expectLater(
      native.loadModel('/other.bin'),
      throwsA(isA<AiBusyException>()),
    );
    await expectLater(
      native.transcribeAudio(audioPath: '/speech.wav', lessonId: 'lesson'),
      throwsA(isA<AiBusyException>()),
    );
    await native.stopSpeechBenchmark('bench');
    expect(native.isBusy, true);
    done.complete({'rows': [], 'cancelled': true, 'modelLoaded': true});
    await running;
    expect(native.isBusy, false);
    expect(native.loadedModelPath, '/tiny.bin');
    native.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(stream, null);
  });
}
