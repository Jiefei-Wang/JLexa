import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/backend_plugins.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/ai_models.dart';

import 'llama_runtime_settings_test.dart'
    show MockTestAiEngine, MockTestSpeechEngine;

class TestPlugins extends BackendPlugins {
  BackendPluginInfo info = const BackendPluginInfo();
  Completer<void>? gate;
  bool fail = false;
  TestPlugins() : super(supported: true);
  @override
  Future<BackendPluginInfo> status() async => info;
  @override
  Future<BackendPluginInfo> importPlugin() async {
    if (gate != null) await gate!.future;
    if (fail) throw StateError('Picker failure');
    return info;
  }

  @override
  Future<BackendPluginInfo> useBuiltin() async =>
      info = const BackendPluginInfo();
}

class CpuOnlyPluginEngine extends MockTestAiEngine {
  @override
  Future<List<LlamaBackendInfo>> getAvailableBackends() async => const [
    LlamaBackendInfo(backend: 'cpu', compiled: true, available: true),
    LlamaBackendInfo(backend: 'vulkan', compiled: false, available: false),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'importing CPU-only plugin replaces obsolete GPU preference with Auto',
    () async {
      final engine = CpuOnlyPluginEngine();
      final plugins = TestPlugins()
        ..info = const BackendPluginInfo(name: 'Snapdragon', external: true);
      final service = AiService(
        llm: engine,
        speech: MockTestSpeechEngine(),
        plugins: plugins,
      );
      await service.updateLlamaRuntimeSettings(
        const LlamaRuntimeSettings(
          backend: LlamaBackendPreference.vulkan,
          threads: 6,
        ),
        autoReload: false,
      );
      await engine.loadModel('content://saved-model');
      await service.changeBackendPlugin(import: true);
      expect(engine.lastRuntimeSettings!.backend, LlamaBackendPreference.auto);
      expect(service.llamaRuntimeSettings.backend, LlamaBackendPreference.auto);
      expect(service.llamaRuntimeSettings.threads, 6);
      expect(service.pluginInfo.external, true);
      service.dispose();
    },
  );
  test(
    'channel reports import incompatibility and built-in fallback accurately',
    () async {
      const channel = MethodChannel('com.jlexa.app/llama');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return {
              'name': 'Built-in',
              'status': 'Incompatible',
              'external': false,
              'error': 'Expected API version 1',
              'fileName': 'wrong.so',
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final plugins = BackendPlugins(supported: true);
      final info = await plugins.importPlugin();
      expect(info.status, 'Incompatible');
      expect(info.external, false);
      expect(info.fileName, 'wrong.so');
      expect(info.error, contains('version 1'));
      await plugins.status();
      await plugins.useBuiltin();
      expect(calls, ['importPlugin', 'pluginStatus', 'useBuiltinPlugin']);
    },
  );

  for (final outcome in ['valid', 'cancel', 'incompatible', 'picker error']) {
    test(
      'plugin $outcome restores the loaded model and keeps speech untouched',
      () async {
        final engine = MockTestAiEngine();
        final speech = MockTestSpeechEngine();
        final plugins = TestPlugins();
        if (outcome == 'valid') {
          plugins.info = const BackendPluginInfo(
            name: 'Custom',
            external: true,
          );
        }
        if (outcome == 'incompatible') {
          plugins.info = const BackendPluginInfo(
            status: 'Incompatible',
            error: 'Wrong ABI',
          );
        }
        plugins.fail = outcome == 'picker error';
        final service = AiService(
          llm: engine,
          speech: speech,
          plugins: plugins,
        );
        await engine.loadModel('content://saved-model');
        await speech.loadModel('speech-model');
        if (plugins.fail) {
          await expectLater(
            service.changeBackendPlugin(import: true),
            throwsStateError,
          );
        } else {
          await service.changeBackendPlugin(import: true);
        }
        expect(engine.loadedModelPath, 'content://saved-model');
        expect(engine.isLoaded, true);
        expect(speech.loadedModelPath, 'speech-model');
        expect(service.pluginInfo.status, plugins.info.status);
        service.dispose();
      },
    );
  }

  test(
    'generation and concurrent settings changes cannot switch the backend',
    () async {
      final engine = MockTestAiEngine();
      final plugins = TestPlugins();
      final service = AiService(
        llm: engine,
        speech: MockTestSpeechEngine(),
        plugins: plugins,
      );
      engine.generating = true;
      await expectLater(
        service.changeBackendPlugin(import: true),
        throwsA(isA<AiBusyException>()),
      );
      engine.generating = false;
      plugins.gate = Completer<void>();
      final switching = service.changeBackendPlugin(import: true);
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        service.changeBackendPlugin(import: false),
        throwsA(isA<AiBusyException>()),
      );
      await expectLater(
        service.updateLlamaRuntimeSettings(const LlamaRuntimeSettings()),
        throwsA(isA<AiBusyException>()),
      );
      plugins.gate!.complete();
      await switching;
      service.dispose();
    },
  );
}
