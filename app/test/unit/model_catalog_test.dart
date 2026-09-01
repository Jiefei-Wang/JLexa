import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/model_catalog.dart';

void main() {
  group('ModelCatalog Tests', () {
    test('Curated LLM catalog has valid metadata', () {
      expect(ModelCatalog.curatedLlmModels, isNotEmpty);

      final ids = <String>{};
      final filenames = <String>{};
      final urls = <String>{};

      for (final model in ModelCatalog.curatedLlmModels) {
        expect(model.id, isNotEmpty);
        expect(model.displayName, isNotEmpty);
        expect(model.modelType, ModelType.llm);
        expect(model.repository, isNotEmpty);
        expect(model.filename, endsWith('.gguf'));
        expect(model.downloadUrl.startsWith('https://huggingface.co/'), isTrue);
        expect(model.expectedSizeBytes, greaterThan(0));
        expect(model.parameterCount, isNotEmpty);
        expect(model.quantization, isNotEmpty);
        expect(model.memoryHint, isNotEmpty);
        expect(model.speedHint, isNotEmpty);
        expect(model.description, isNotEmpty);

        expect(ids.add(model.id), isTrue, reason: 'Duplicate ID: ${model.id}');
        expect(
          filenames.add(model.filename),
          isTrue,
          reason: 'Duplicate filename: ${model.filename}',
        );
        expect(
          urls.add(model.downloadUrl),
          isTrue,
          reason: 'Duplicate URL: ${model.downloadUrl}',
        );
      }

      // Exactly one recommended LLM model
      final recommended =
          ModelCatalog.curatedLlmModels.where((m) => m.isRecommended).toList();
      expect(recommended.length, 1);
      expect(recommended.first.id, 'qwen2.5-1.5b-instruct');
    });

    test('Curated Whisper catalog has valid metadata', () {
      expect(ModelCatalog.curatedWhisperModels, isNotEmpty);

      final ids = <String>{};
      final filenames = <String>{};
      final urls = <String>{};

      for (final model in ModelCatalog.curatedWhisperModels) {
        expect(model.id, isNotEmpty);
        expect(model.displayName, isNotEmpty);
        expect(model.modelType, ModelType.whisper);
        expect(model.repository, isNotEmpty);
        expect(
          model.filename.endsWith('.bin') ||
              model.filename.endsWith('.ggml') ||
              model.filename.endsWith('.gguf'),
          isTrue,
        );
        expect(model.downloadUrl.startsWith('https://huggingface.co/'), isTrue);
        expect(model.expectedSizeBytes, greaterThan(0));
        expect(model.parameterCount, isNotEmpty);
        expect(model.memoryHint, isNotEmpty);
        expect(model.speedHint, isNotEmpty);
        expect(model.description, isNotEmpty);

        expect(ids.add(model.id), isTrue, reason: 'Duplicate ID: ${model.id}');
        expect(
          filenames.add(model.filename),
          isTrue,
          reason: 'Duplicate filename: ${model.filename}',
        );
        expect(
          urls.add(model.downloadUrl),
          isTrue,
          reason: 'Duplicate URL: ${model.downloadUrl}',
        );
      }

      // Exactly one recommended Whisper model
      final recommended = ModelCatalog.curatedWhisperModels
          .where((m) => m.isRecommended)
          .toList();
      expect(recommended.length, 1);
      expect(recommended.first.id, 'whisper-base-en');
    });

    test('findById locates models correctly', () {
      final qwen15 = ModelCatalog.findById('qwen2.5-1.5b-instruct');
      expect(qwen15, isNotNull);
      expect(qwen15!.displayName, 'Qwen2.5 1.5B Instruct');

      final whisperBase = ModelCatalog.findById('whisper-base-en');
      expect(whisperBase, isNotNull);
      expect(whisperBase!.displayName, 'Whisper Base (English)');

      final nonexistent = ModelCatalog.findById('nonexistent-model');
      expect(nonexistent, isNull);
    });

    test('findCuratedByPath and filename locate models', () {
      final model = ModelCatalog.findCuratedByPath(
        '/data/user/0/com.example/app_flutter/models/llm/qwen2.5-1.5b-instruct-q4_k_m.gguf',
      );
      expect(model, isNotNull);
      expect(model!.id, 'qwen2.5-1.5b-instruct');

      final whisper = ModelCatalog.findCuratedByFilename('ggml-base.en.bin');
      expect(whisper, isNotNull);
      expect(whisper!.id, 'whisper-base-en');
    });

    test('formatBytes produces readable string representations', () {
      expect(ModelCatalog.formatBytes(0), '0 B');
      expect(ModelCatalog.formatBytes(512), '512 B');
      expect(ModelCatalog.formatBytes(1024), '1 KB');
      expect(ModelCatalog.formatBytes(77704715), '74.1 MB');
      expect(ModelCatalog.formatBytes(1117320736), '1.04 GB');
      expect(ModelCatalog.formatBytes(2104932768), '1.96 GB');
    });
  });
}
