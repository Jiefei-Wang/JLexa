import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/backend_plugins.dart';

import 'backend_plugins_test.dart' show TestPlugins;
import 'llama_runtime_settings_test.dart'
    show MockTestAiEngine, MockTestSpeechEngine;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('speech catalog uses its independent platform channel', () async {
    const channel = MethodChannel('com.jlexa.app/whisper');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {
            'engine': 'whisper.cpp',
            'name': 'Speech CPU',
            'status': 'Loaded',
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final plugins = BackendPlugins(speech: true, supported: true);
    expect((await plugins.status()).engine, 'whisper.cpp');
    await plugins.select('speech-a');
    expect(calls.last.arguments, {'id': 'speech-a'});
  });

  for (final outcome in ['valid', 'failed', 'cancelled']) {
    test(
      'speech import $outcome preserves both engines and LLM selection',
      () async {
        final llm = MockTestAiEngine();
        final speech = MockTestSpeechEngine();
        final plugins = TestPlugins()
          ..selected = 'a'
          ..fail = outcome == 'failed'
          ..cancelled = outcome == 'cancelled';
        final llmPlugins = TestPlugins()..selected = 'b';
        final service = AiService(
          llm: llm,
          speech: speech,
          plugins: llmPlugins,
          speechPlugins: plugins,
        );
        addTearDown(service.dispose);
        await llm.loadModel('llm.gguf');
        await speech.loadModel('speech.bin');
        await service.refreshSpeechPluginInfo();
        if (outcome == 'failed') {
          await expectLater(service.importSpeechBackend(), throwsStateError);
        } else {
          await service.importSpeechBackend();
        }
        expect(speech.loadedModelPath, 'speech.bin');
        expect(llm.loadedModelPath, 'llm.gguf');
        expect(plugins.selected, 'a');
        expect(llmPlugins.calls, isEmpty);
        expect(plugins.entries.length, outcome == 'valid' ? 3 : 2);
        expect(service.isUpdatingBackend, isFalse);
      },
    );
  }

  for (final active in [false, true]) {
    test(
      'delete speech backend active=$active restores built-in only when needed',
      () async {
        final speech = MockTestSpeechEngine();
        final llm = MockTestAiEngine();
        final plugins = TestPlugins()..selected = 'a';
        final service = AiService(
          llm: llm,
          speech: speech,
          speechPlugins: plugins,
        );
        addTearDown(service.dispose);
        await speech.loadModel('speech.bin');
        await llm.loadModel('llm.gguf');
        await service.refreshSpeechPluginInfo();
        await service.deleteSpeechBackend(active ? 'a' : 'b');
        expect(plugins.calls, active ? ['builtin', 'delete:a'] : ['delete:b']);
        expect(speech.loadedModelPath, 'speech.bin');
        expect(llm.loadedModelPath, 'llm.gguf');
        expect(plugins.selected, active ? '' : 'a');
      },
    );
  }

  test('failed speech selection restores prior backend and model', () async {
    final speech = MockTestSpeechEngine();
    final plugins = TestPlugins()
      ..selected = 'a'
      ..failSelection = 'b';
    final service = AiService(speech: speech, speechPlugins: plugins);
    addTearDown(service.dispose);
    await speech.loadModel('speech.bin');
    await service.refreshSpeechPluginInfo();
    await expectLater(service.selectSpeechBackend('b'), throwsStateError);
    expect(plugins.selected, 'a');
    expect(speech.loadedModelPath, 'speech.bin');
    expect(service.isUpdatingBackend, isFalse);
  });
}
