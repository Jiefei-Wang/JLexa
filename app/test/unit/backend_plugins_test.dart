import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/backend_plugins.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/ai_models.dart';

import 'llama_runtime_settings_test.dart'
    show MockTestAiEngine, MockTestSpeechEngine;

class TestPlugins extends BackendPlugins {
  String selected = '';
  final calls = <String>[];
  final entries = <InstalledBackend>[
    const InstalledBackend(id: 'a', name: 'Snapdragon', backendType: 'CPU'),
    const InstalledBackend(id: 'b', name: 'Other engine'),
  ];
  Completer<void>? gate;
  bool fail = false, cancelled = false;
  String? failSelection;
  TestPlugins() : super(supported: true);
  BackendPluginInfo get info => BackendPluginInfo(
    id: selected,
    external: selected.isNotEmpty,
    name: selected.isEmpty
        ? 'Built-in'
        : entries.firstWhere((p) => p.id == selected).name,
    installed: List.of(entries),
  );
  @override
  Future<BackendPluginInfo> status() async => info;
  @override
  Future<BackendPluginInfo> importPlugin() async {
    calls.add('import');
    if (gate != null) await gate!.future;
    if (fail) throw StateError('Incompatible: expected arm64-v8a');
    if (!cancelled) {
      entries.add(const InstalledBackend(id: 'c', name: 'New backend'));
    }
    return info;
  }

  @override
  Future<BackendPluginInfo> useBuiltin() async {
    calls.add('builtin');
    selected = '';
    return info;
  }

  @override
  Future<BackendPluginInfo> select(String id) async {
    calls.add('select:$id');
    if (id == failSelection) throw StateError('Plugin load failure');
    selected = id;
    return info;
  }

  @override
  Future<BackendPluginInfo> delete(String id) async {
    calls.add('delete:$id');
    if (id == selected) {
      throw StateError('Active backend must be switched first');
    }
    entries.removeWhere((p) => p.id == id);
    return info;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('channel returns catalog and passes selection/deletion IDs', () async {
    const channel = MethodChannel('com.jlexa.app/llama');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'importPlugin') {
            throw PlatformException(code: 'PLUGIN_ERROR', message: 'Wrong ABI');
          }
          return {
            'id': 'a',
            'external': true,
            'name': 'Snapdragon',
            'installed': [
              {
                'id': 'a',
                'name': 'Snapdragon',
                'version': '1.0',
                'backendType': 'CPU',
              },
            ],
            'builtinBackends': [
              {'backend': 'cpu', 'compiled': true, 'available': true},
            ],
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final plugins = BackendPlugins(supported: true);
    final info = await plugins.status();
    expect(info.installed.single.id, 'a');
    expect(info.builtinBackends.single.available, true);
    await plugins.select('a');
    await plugins.delete('a');
    expect(calls[1].arguments, {'id': 'a'});
    expect(calls[2].method, 'deletePlugin');
    await expectLater(
      plugins.importPlugin(),
      throwsA(isA<PlatformException>()),
    );
  });

  for (final outcome in ['valid', 'cancel', 'failure']) {
    test(
      'import $outcome keeps the selected backend and loaded models',
      () async {
        final engine = MockTestAiEngine();
        final speech = MockTestSpeechEngine();
        final plugins = TestPlugins()
          ..selected = 'a'
          ..cancelled = outcome == 'cancel'
          ..fail = outcome == 'failure';
        final service = AiService(
          llm: engine,
          speech: speech,
          plugins: plugins,
        );
        await engine.loadModel('content://saved-model');
        await speech.loadModel('speech-model');
        await service.refreshPluginInfo();
        final runtime = engine.lastRuntimeSettings;
        if (plugins.fail) {
          await expectLater(
            service.changeBackendPlugin(import: true),
            throwsStateError,
          );
        } else {
          await service.changeBackendPlugin(import: true);
        }
        expect(engine.isLoaded, true);
        expect(engine.loadedModelPath, 'content://saved-model');
        expect(engine.lastRuntimeSettings, same(runtime));
        expect(speech.loadedModelPath, 'speech-model');
        expect(plugins.selected, 'a');
        expect(plugins.calls, ['import']);
        expect(service.pluginInfo.installed.length, outcome == 'valid' ? 3 : 2);
        service.dispose();
      },
    );
  }

  test(
    'selecting imported CPU backend uses Auto and retains settings/catalog',
    () async {
      final engine = MockTestAiEngine();
      final plugins = TestPlugins();
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
      await engine.loadModel('model');
      await service.refreshPluginInfo();
      await service.selectBackend('a');
      expect(engine.lastRuntimeSettings!.backend, LlamaBackendPreference.auto);
      expect(service.llamaRuntimeSettings.threads, 6);
      expect(service.pluginInfo.id, 'a');
      await service.selectBackend('', preference: LlamaBackendPreference.cpu);
      expect(service.pluginInfo.external, false);
      expect(service.pluginInfo.installed.length, 2);
      expect(service.llamaRuntimeSettings.backend, LlamaBackendPreference.cpu);
      service.dispose();
    },
  );

  for (final active in [false, true]) {
    test(
      'delete ${active ? 'active' : 'inactive'} backend preserves model and other entries',
      () async {
        final engine = MockTestAiEngine();
        final plugins = TestPlugins()..selected = active ? 'a' : 'b';
        final service = AiService(
          llm: engine,
          speech: MockTestSpeechEngine(),
          plugins: plugins,
        );
        await engine.loadModel('model');
        await service.refreshPluginInfo();
        await service.deleteBackend('a');
        expect(plugins.calls, active ? ['builtin', 'delete:a'] : ['delete:a']);
        expect(plugins.entries.single.id, 'b');
        expect(engine.loadedModelPath, 'model');
        expect(service.pluginInfo.id, active ? '' : 'b');
        service.dispose();
      },
    );
  }

  test(
    'selection failure restores previous plugin/model and retains failed entry',
    () async {
      final engine = MockTestAiEngine();
      final plugins = TestPlugins()
        ..selected = 'a'
        ..failSelection = 'b';
      final service = AiService(
        llm: engine,
        speech: MockTestSpeechEngine(),
        plugins: plugins,
      );
      await engine.loadModel('model');
      await service.refreshPluginInfo();
      await expectLater(service.selectBackend('b'), throwsStateError);
      expect(plugins.calls, ['select:b', 'select:a']);
      expect(service.pluginInfo.id, 'a');
      expect(engine.isLoaded, true);
      expect(plugins.entries.length, 2);
      service.dispose();
    },
  );

  test('generation and concurrent imports block backend mutations', () async {
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
    final importing = service.changeBackendPlugin(import: true);
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      service.selectBackend('a'),
      throwsA(isA<AiBusyException>()),
    );
    await expectLater(
      service.deleteBackend('b'),
      throwsA(isA<AiBusyException>()),
    );
    plugins.gate!.complete();
    await importing;
    service.dispose();
  });
}
