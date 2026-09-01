import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_engine.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/model_catalog.dart';
import 'package:jlexa/core/ai/model_downloader.dart';
import 'package:jlexa/core/ai/model_manager.dart';
import 'package:jlexa/core/ai/model_storage.dart';
import 'package:jlexa/core/ai/prompt_builder.dart';
import 'package:jlexa/core/ai/speech_engine.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';

class MockAiEngine implements AiEngine {
  bool _isLoaded = false;
  String? _loadedPath;

  @override
  bool get isLoaded => _isLoaded;

  @override
  String? get loadedModelPath => _loadedPath;

  @override
  AiModelState get state => _isLoaded ? AiModelState.ready : AiModelState.noModel;

  @override
  Future<void> loadModel(String modelPath, {AiGenerationSettings? settings}) async {
    _isLoaded = true;
    _loadedPath = modelPath;
  }

  @override
  Future<void> unload() async {
    _isLoaded = false;
    _loadedPath = null;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> cancelRequest(String requestId) async {}

  @override
  Stream<String> generate(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
  }) => Stream.value('test response');

  @override
  AiGenerationHandle startGeneration(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    return AiGenerationHandle(
      requestId: 'mock_req',
      stream: Stream.value('test response'),
      onCancel: () async {},
    );
  }
}

class MockSpeechEngine implements SpeechRecognitionEngine {
  bool _isLoaded = false;
  String? _loadedPath;

  @override
  bool get isLoaded => _isLoaded;

  @override
  String? get loadedModelPath => _loadedPath;

  @override
  Future<void> loadModel(String modelPath) async {
    _isLoaded = true;
    _loadedPath = modelPath;
  }

  @override
  Future<void> unload() async {
    _isLoaded = false;
    _loadedPath = null;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> cancelRequest(String requestId) async {}

  @override
  Future<Map<String, dynamic>?> getAudioMetadata(String audioPath) async => null;

  @override
  Future<List<AudioSegment>> transcribeAudio({
    required String audioPath,
    required String lessonId,
    String? requestId,
    int nThreads = 4,
    void Function(double progress)? onProgress,
  }) async => [];
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  group('ModelManager Tests', () {
    late Directory tempDir;
    late ModelStorage storage;
    late FakeModelDownloader downloader;
    late MockAiEngine mockLlm;
    late MockSpeechEngine mockSpeech;
    late AiService aiService;
    late ModelManager manager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('jlexa_manager_test_');
      storage = ModelStorage(baseDirProvider: () async => tempDir);
      downloader = FakeModelDownloader(stepDelay: const Duration(milliseconds: 5));
      mockLlm = MockAiEngine();
      mockSpeech = MockSpeechEngine();
      aiService = AiService(llm: mockLlm, speech: mockSpeech);

      manager = ModelManager(
        storage: storage,
        downloader: downloader,
        aiService: aiService,
      );
      await manager.initialize();
    });

    tearDown(() async {
      manager.dispose();
      aiService.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Initializes with curated models in notDownloaded state', () async {
      expect(manager.isInitialized, isTrue);
      expect(manager.llmModels.length, ModelCatalog.curatedLlmModels.length);
      expect(
        manager.whisperModels.length,
        ModelCatalog.curatedWhisperModels.length,
      );

      for (final item in manager.llmModels) {
        expect(item.state, ModelDownloadState.notDownloaded);
        expect(item.isDownloaded, isFalse);
      }
      for (final item in manager.whisperModels) {
        expect(item.state, ModelDownloadState.notDownloaded);
        expect(item.isDownloaded, isFalse);
      }
    });

    test('downloadModel completes and updates state to downloaded', () async {
      final targetModel = ModelCatalog.curatedLlmModels.first;

      await manager.downloadModel(targetModel);

      final updated = manager.llmModels.firstWhere((m) => m.id == targetModel.id);
      expect(updated.state, ModelDownloadState.downloaded);
      expect(updated.isDownloaded, isTrue);
      expect(updated.localPath, isNotNull);
      expect(await File(updated.localPath!).exists(), isTrue);
    });

    test('loadModel and unloadModel switch state between downloaded and loaded', () async {
      final targetModel = ModelCatalog.curatedLlmModels.first;
      await manager.downloadModel(targetModel);

      var item = manager.llmModels.firstWhere((m) => m.id == targetModel.id);
      expect(item.state, ModelDownloadState.downloaded);

      // Load model
      await manager.loadModel(item);
      item = manager.llmModels.firstWhere((m) => m.id == targetModel.id);
      expect(item.state, ModelDownloadState.loaded);
      expect(item.isLoaded, isTrue);
      expect(mockLlm.isLoaded, isTrue);

      // Unload model
      await manager.unloadModel(item);
      item = manager.llmModels.firstWhere((m) => m.id == targetModel.id);
      expect(item.state, ModelDownloadState.downloaded);
      expect(item.isLoaded, isFalse);
      expect(mockLlm.isLoaded, isFalse);
    });

    test('Model switching: loading model B unloads model A', () async {
      final modelA = ModelCatalog.curatedLlmModels[0];
      final modelB = ModelCatalog.curatedLlmModels[1];

      await manager.downloadModel(modelA);
      await manager.downloadModel(modelB);

      final itemA = manager.llmModels.firstWhere((m) => m.id == modelA.id);
      final itemB = manager.llmModels.firstWhere((m) => m.id == modelB.id);

      // Load A
      await manager.loadModel(itemA);
      expect(manager.llmModels.firstWhere((m) => m.id == modelA.id).isLoaded, isTrue);
      expect(manager.llmModels.firstWhere((m) => m.id == modelB.id).isLoaded, isFalse);

      // Load B -> A should unload
      await manager.loadModel(itemB);
      expect(manager.llmModels.firstWhere((m) => m.id == modelA.id).isLoaded, isFalse);
      expect(manager.llmModels.firstWhere((m) => m.id == modelB.id).isLoaded, isTrue);
    });

    test('deleteModel safely unloads and removes file', () async {
      final targetModel = ModelCatalog.curatedLlmModels.first;
      await manager.downloadModel(targetModel);

      var item = manager.llmModels.firstWhere((m) => m.id == targetModel.id);
      await manager.loadModel(item);
      item = manager.llmModels.firstWhere((m) => m.id == targetModel.id);
      expect(item.isLoaded, isTrue);

      final localPath = item.localPath!;
      expect(await File(localPath).exists(), isTrue);

      // Delete model
      item = manager.llmModels.firstWhere((m) => m.id == targetModel.id);
      await manager.deleteModel(item);

      item = manager.llmModels.firstWhere((m) => m.id == targetModel.id);
      expect(item.state, ModelDownloadState.notDownloaded);
      expect(item.isLoaded, isFalse);
      expect(await File(localPath).exists(), isFalse);
    });

    test('importLocalModel copies file, adds to list, and loads it', () async {
      final extDir = await Directory.systemTemp.createTemp('ext_');
      final extFile = File(p.join(extDir.path, 'my_custom_model.gguf'));
      await extFile.writeAsBytes(List<int>.filled(512, 0xAA));

      final imported = await manager.importLocalModel(extFile.path, ModelType.llm);
      expect(imported.isCustomImport, isTrue);
      expect(imported.state, ModelDownloadState.loaded);
      expect(mockLlm.isLoaded, isTrue);

      // Check item appears in manager's list
      final found = manager.llmModels.firstWhere((m) => m.displayName == 'my_custom_model.gguf');
      expect(found.isLoaded, isTrue);

      await extDir.delete(recursive: true);
    });
  });
}
