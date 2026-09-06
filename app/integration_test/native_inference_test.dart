import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/model_catalog.dart';
import 'package:jlexa/core/ai/model_storage.dart';
import 'package:jlexa/core/ai/native_ai_bridge.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Native Inference & llama.cpp Hardware Acceleration Integration Tests', () {
    testWidgets('NativeLlamaEngine enumerates hardware backends and reports active status', (tester) async {
      final engine = NativeLlamaEngine();

      // Query available backends from native llama.cpp ggml device registry
      final backends = await engine.getAvailableBackends();
      expect(backends, isNotEmpty);

      // CPU backend is always available on all supported platforms
      final cpuBackend = backends.firstWhere(
        (b) => b.backend.toLowerCase() == 'cpu',
        orElse:
            () => const LlamaBackendInfo(
              backend: 'none',
              compiled: false,
              available: false,
            ),
      );
      expect(cpuBackend.backend, 'cpu');
      expect(cpuBackend.compiled, isTrue);
      expect(cpuBackend.available, isTrue);

      // Initial active backend info prior to model loading
      final initialActive = await engine.getActiveBackendInfo();
      expect(initialActive, isNotNull);
    });

    testWidgets('LlamaRuntimeSettings handles auto, cpu, and gpu layer configuration', (tester) async {
      const defaultSettings = LlamaRuntimeSettings();
      expect(defaultSettings.backend, LlamaBackendPreference.auto);
      expect(defaultSettings.resolvedThreads, 4);

      const customSettings = LlamaRuntimeSettings(
        backend: LlamaBackendPreference.cpu,
        threads: 4,
        contextLength: 1024,
        batchSize: 256,
        microBatchSize: 256,
        flashAttention: LlamaFlashAttention.off,
      );

      final map = customSettings.toMap();
      final restored = LlamaRuntimeSettings.fromMap(map);
      expect(restored.backend, LlamaBackendPreference.cpu);
      expect(restored.contextLength, 1024);
      expect(restored.batchSize, 256);
      expect(restored.microBatchSize, 256);
      expect(restored.flashAttention, LlamaFlashAttention.off);
    });

    testWidgets('NativeLlamaEngine loads installed model and executes real inference without crashing', (tester) async {
      final storage = ModelStorage();
      final dir = await storage.getModelTypeDirectory(ModelType.llm);
      if (!dir.existsSync()) {
        return;
      }
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.gguf'))
          .toList();

      if (files.isEmpty) {
        return;
      }

      final modelPath = files.first.path;
      final engine = NativeLlamaEngine();

      // Load model
      await engine.loadModel(
        modelPath,
        settings: const AiGenerationSettings(
          maxTokens: 16,
          temperature: 0.7,
        ),
      );
      expect(engine.isLoaded, isTrue);

      // Verify first inference request runs and produces tokens
      final tokens = <String>[];
      await for (final tok in engine.generate('Say hello in one word.')) {
        tokens.add(tok);
      }
      expect(tokens, isNotEmpty);
      expect(engine.state, AiModelState.ready);

      // Verify second inference request with the same model succeeds cleanly (testing lifecycle / stability)
      final secondTokens = <String>[];
      await for (final tok in engine.generate('What is 2+2? Answer with a single digit.')) {
        secondTokens.add(tok);
      }
      expect(secondTokens, isNotEmpty);
      expect(engine.state, AiModelState.ready);
    });
  });
}
