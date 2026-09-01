import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/model_catalog.dart';
import 'package:jlexa/core/ai/model_storage.dart';
import 'package:path/path.dart' as p;

void main() {
  group('ModelStorage Tests', () {
    late Directory tempDir;
    late ModelStorage storage;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('jlexa_storage_test_');
      storage = ModelStorage(baseDirProvider: () async => tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Directory creation and paths are correct', () async {
      final llmDir = await storage.getModelTypeDirectory(ModelType.llm);
      expect(await llmDir.exists(), isTrue);
      expect(p.basename(llmDir.path), 'llm');

      final whisperDir = await storage.getModelTypeDirectory(ModelType.whisper);
      expect(await whisperDir.exists(), isTrue);
      expect(p.basename(whisperDir.path), 'whisper');

      final finalPath = await storage.getFinalModelPath(
        ModelType.llm,
        'model.gguf',
      );
      expect(finalPath, p.join(llmDir.path, 'model.gguf'));

      final partPath = await storage.getPartModelPath(
        ModelType.llm,
        'model.gguf',
      );
      expect(partPath, p.join(llmDir.path, 'model.gguf.part'));
    });

    test('cleanStalePartFiles deletes only .part files', () async {
      final llmDir = await storage.getModelTypeDirectory(ModelType.llm);
      final validModel = File(p.join(llmDir.path, 'valid.gguf'));
      final stalePart = File(p.join(llmDir.path, 'incomplete.gguf.part'));

      await validModel.writeAsString('valid content');
      await stalePart.writeAsString('partial content');

      expect(await validModel.exists(), isTrue);
      expect(await stalePart.exists(), isTrue);

      await storage.cleanStalePartFiles();

      expect(await validModel.exists(), isTrue);
      expect(await stalePart.exists(), isFalse);
    });

    test('atomicFinalizeDownload successfully renames valid partial file', () async {
      final partPath = await storage.getPartModelPath(
        ModelType.llm,
        'test.gguf',
      );
      final finalPath = await storage.getFinalModelPath(
        ModelType.llm,
        'test.gguf',
      );

      final partFile = File(partPath);
      await partFile.writeAsBytes(List<int>.filled(1024, 0x01));

      final result = await storage.atomicFinalizeDownload(
        partPath,
        finalPath,
        expectedSizeBytes: 1024,
      );

      expect(result, finalPath);
      expect(await File(finalPath).exists(), isTrue);
      expect(await File(partPath).exists(), isFalse);
      expect(await File(finalPath).length(), 1024);
    });

    test('atomicFinalizeDownload throws on empty or missing part file', () async {
      final partPath = await storage.getPartModelPath(
        ModelType.llm,
        'test_empty.gguf',
      );
      final finalPath = await storage.getFinalModelPath(
        ModelType.llm,
        'test_empty.gguf',
      );

      // 1. Missing file
      expect(
        () => storage.atomicFinalizeDownload(partPath, finalPath),
        throwsA(isA<ModelValidationException>()),
      );

      // 2. Empty file
      final partFile = File(partPath);
      await partFile.writeAsBytes([]);
      expect(
        () => storage.atomicFinalizeDownload(partPath, finalPath),
        throwsA(isA<ModelValidationException>()),
      );
    });

    test('validateModelFile checks extension and non-empty file', () async {
      final llmDir = await storage.getModelTypeDirectory(ModelType.llm);
      final ggufFile = File(p.join(llmDir.path, 'valid.gguf'));
      final txtFile = File(p.join(llmDir.path, 'invalid.txt'));

      await ggufFile.writeAsString('valid');
      await txtFile.writeAsString('invalid');

      // Valid GGUF
      await expectLater(
        storage.validateModelFile(ggufFile.path, type: ModelType.llm),
        completes,
      );

      // Invalid extension for LLM
      await expectLater(
        storage.validateModelFile(txtFile.path, type: ModelType.llm),
        throwsA(isA<ModelValidationException>()),
      );
    });

    test('importLocalFile copies external file into managed storage', () async {
      final externalDir = await Directory.systemTemp.createTemp('ext_');
      final externalFile = File(p.join(externalDir.path, 'custom_model.gguf'));
      await externalFile.writeAsBytes(List<int>.filled(512, 0x55));

      final importedPath = await storage.importLocalFile(
        externalFile.path,
        ModelType.llm,
      );

      expect(await File(importedPath).exists(), isTrue);
      expect(await File(importedPath).length(), 512);

      // Clean up external temp
      await externalDir.delete(recursive: true);
    });

    test('deleteModelFile deletes target file', () async {
      final finalPath = await storage.getFinalModelPath(
        ModelType.llm,
        'to_delete.gguf',
      );
      final file = File(finalPath);
      await file.writeAsString('content');

      expect(await file.exists(), isTrue);
      final deleted = await storage.deleteModelFile(finalPath);
      expect(deleted, isTrue);
      expect(await file.exists(), isFalse);
    });
  });
}
