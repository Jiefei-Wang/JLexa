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
  final Set<String> failLoadPaths = {};

  @override
  bool get isLoaded => _isLoaded;

  @override
  String? get loadedModelPath => _loadedPath;

  @override
  AiModelState get state => _isLoaded ? AiModelState.ready : AiModelState.noModel;

  @override
  Future<void> loadModel(
    String modelPath, {
    AiGenerationSettings? settings,
    LlamaRuntimeSettings? runtimeSettings,
  }) async {
    if (failLoadPaths.contains(p.canonicalize(modelPath)) ||
        failLoadPaths.contains(modelPath)) {
      _isLoaded = false;
      _loadedPath = null;
      throw Exception('Simulated load failure for $modelPath');
    }
    _isLoaded = true;
    _loadedPath = modelPath;
  }

  @override
  Future<List<LlamaBackendInfo>> getAvailableBackends() async {
    return const [
      LlamaBackendInfo(
        backend: 'cpu',
        compiled: true,
        available: true,
        deviceName: 'CPU (Mock)',
      ),
    ];
  }

  @override
  Future<LlamaActiveBackendInfo> getActiveBackendInfo() async {
    return const LlamaActiveBackendInfo();
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
  final Set<String> failLoadPaths = {};

  @override
  bool get isLoaded => _isLoaded;

  @override
  String? get loadedModelPath => _loadedPath;

  @override
  Future<void> loadModel(String modelPath) async {
    if (failLoadPaths.contains(p.canonicalize(modelPath)) ||
        failLoadPaths.contains(modelPath)) {
      _isLoaded = false;
      _loadedPath = null;
      throw Exception('Simulated speech model load failure for $modelPath');
    }
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

    test('cancelDownload: clean cancel leaves no error, removes part, returns to notDownloaded', () async {
      final targetModel = ModelCatalog.curatedLlmModels.first;
      final slowDownloader = FakeModelDownloader(
        stepDelay: const Duration(milliseconds: 50),
      );
      final testManager = ModelManager(
        storage: storage,
        downloader: slowDownloader,
        aiService: aiService,
      );
      await testManager.initialize();

      // Start download in background
      final downloadFuture = testManager.downloadModel(targetModel);
      await Future.delayed(const Duration(milliseconds: 20));

      // Cancel download
      testManager.cancelDownload(targetModel.id);
      await downloadFuture; // Should resolve cleanly without rethrowing cancel error

      final item = testManager.llmModels.firstWhere((m) => m.id == targetModel.id);
      expect(item.state, ModelDownloadState.notDownloaded);
      expect(item.errorMessage, isNull);
      expect(item.isDownloaded, isFalse);

      final partPath = await storage.getPartModelPath(
        targetModel.modelType,
        targetModel.filename,
      );
      final finalPath = await storage.getFinalModelPath(
        targetModel.modelType,
        targetModel.filename,
      );
      expect(await File(partPath).exists(), isFalse);
      expect(await File(finalPath).exists(), isFalse);

      testManager.dispose();
    });

    test('Cancelling after completion does not delete completed model', () async {
      final targetModel = ModelCatalog.curatedLlmModels.first;
      await manager.downloadModel(targetModel);

      final item = manager.llmModels.firstWhere((m) => m.id == targetModel.id);
      expect(item.isDownloaded, isTrue);
      final finalPath = item.localPath!;
      expect(await File(finalPath).exists(), isTrue);

      // Call cancel after completion
      manager.cancelDownload(targetModel.id);
      await manager.refreshModels();

      expect(await File(finalPath).exists(), isTrue);
      final afterItem = manager.llmModels.firstWhere((m) => m.id == targetModel.id);
      expect(afterItem.isDownloaded, isTrue);
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

    test('LLM Model switching rollback: when B fails to load, A is restored', () async {
      final modelA = ModelCatalog.curatedLlmModels[0];
      final modelB = ModelCatalog.curatedLlmModels[1];

      await manager.downloadModel(modelA);
      await manager.downloadModel(modelB);

      final itemA = manager.llmModels.firstWhere((m) => m.id == modelA.id);
      final itemB = manager.llmModels.firstWhere((m) => m.id == modelB.id);

      // 1. Successfully load Model A
      await manager.loadModel(itemA);
      expect(mockLlm.isLoaded, isTrue);
      expect(mockLlm.loadedModelPath, itemA.localPath);
      expect(manager.llmModels.firstWhere((m) => m.id == modelA.id).isLoaded, isTrue);

      // 2. Configure mock engine to fail on Model B
      mockLlm.failLoadPaths.add(p.canonicalize(itemB.localPath!));

      // 3. Attempt loading Model B -> should throw but restore Model A
      await expectLater(
        () => manager.loadModel(itemB),
        throwsA(isA<Exception>()),
      );

      // 4. Verify Model A is restored and still loaded
      expect(mockLlm.isLoaded, isTrue);
      expect(mockLlm.loadedModelPath, itemA.localPath);

      final finalItemA = manager.llmModels.firstWhere((m) => m.id == modelA.id);
      final finalItemB = manager.llmModels.firstWhere((m) => m.id == modelB.id);

      expect(finalItemA.state, ModelDownloadState.loaded);
      expect(finalItemA.isLoaded, isTrue);
      expect(finalItemB.isLoaded, isFalse);
      expect(finalItemB.errorMessage, contains('Restored previous model'));
    });

    test('Whisper Model switching rollback: when B fails to load, A is restored', () async {
      final modelA = ModelCatalog.curatedWhisperModels[0];
      final modelB = ModelCatalog.curatedWhisperModels[1];

      await manager.downloadModel(modelA);
      await manager.downloadModel(modelB);

      final itemA = manager.whisperModels.firstWhere((m) => m.id == modelA.id);
      final itemB = manager.whisperModels.firstWhere((m) => m.id == modelB.id);

      // 1. Successfully load Whisper Model A
      await manager.loadModel(itemA);
      expect(mockSpeech.isLoaded, isTrue);
      expect(mockSpeech.loadedModelPath, itemA.localPath);
      expect(manager.whisperModels.firstWhere((m) => m.id == modelA.id).isLoaded, isTrue);

      // 2. Configure mock speech engine to fail on Model B
      mockSpeech.failLoadPaths.add(p.canonicalize(itemB.localPath!));

      // 3. Attempt loading Model B
      await expectLater(
        () => manager.loadModel(itemB),
        throwsA(isA<Exception>()),
      );

      // 4. Verify Whisper Model A is restored and still loaded
      expect(mockSpeech.isLoaded, isTrue);
      expect(mockSpeech.loadedModelPath, itemA.localPath);

      final finalItemA = manager.whisperModels.firstWhere((m) => m.id == modelA.id);
      final finalItemB = manager.whisperModels.firstWhere((m) => m.id == modelB.id);

      expect(finalItemA.state, ModelDownloadState.loaded);
      expect(finalItemA.isLoaded, isTrue);
      expect(finalItemB.isLoaded, isFalse);
      expect(finalItemB.errorMessage, contains('Restored previous model'));
    });

    test('Load invalid model when no model loaded leaves no model loaded', () async {
      final model = ModelCatalog.curatedLlmModels.first;
      await manager.downloadModel(model);

      final item = manager.llmModels.firstWhere((m) => m.id == model.id);
      mockLlm.failLoadPaths.add(p.canonicalize(item.localPath!));

      await expectLater(
        () => manager.loadModel(item),
        throwsA(isA<Exception>()),
      );

      expect(mockLlm.isLoaded, isFalse);
      expect(aiService.llmEngine.isLoaded, isFalse);
      final updated = manager.llmModels.firstWhere((m) => m.id == model.id);
      expect(updated.isLoaded, isFalse);
      expect(updated.errorMessage, contains('Failed to load model'));
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

    test('deleteModel cancels active download if downloading', () async {
      final targetModel = ModelCatalog.curatedLlmModels.first;
      final slowDownloader = FakeModelDownloader(
        stepDelay: const Duration(milliseconds: 50),
      );
      final testManager = ModelManager(
        storage: storage,
        downloader: slowDownloader,
        aiService: aiService,
      );
      await testManager.initialize();

      // Start download
      final downloadFuture = testManager.downloadModel(targetModel);
      await Future.delayed(const Duration(milliseconds: 20));

      // Delete model while downloading
      final item = testManager.llmModels.firstWhere((m) => m.id == targetModel.id);
      await testManager.deleteModel(item);
      await downloadFuture;

      final updated = testManager.llmModels.firstWhere((m) => m.id == targetModel.id);
      expect(updated.state, ModelDownloadState.notDownloaded);

      testManager.dispose();
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
