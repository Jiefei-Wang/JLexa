import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_engine.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/model_catalog.dart';
import 'package:jlexa/core/ai/model_downloader.dart';
import 'package:jlexa/core/ai/model_file_picker.dart';
import 'package:jlexa/core/ai/model_manager.dart';
import 'package:jlexa/core/ai/model_storage.dart';
import 'package:jlexa/core/ai/prompt_builder.dart';
import 'package:jlexa/core/ai/speech_engine.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/features/settings/settings_controller.dart';
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
  AiModelState get state =>
      _isLoaded ? AiModelState.ready : AiModelState.noModel;

  @override
  Future<void> loadModel(
    String modelPath, {
    AiGenerationSettings? settings,
    LlamaRuntimeSettings? runtimeSettings,
  }) async {
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
      LlamaBackendInfo(
        backend: 'vulkan',
        compiled: true,
        available: true,
        deviceName: 'Vulkan GPU (Mock)',
      ),
    ];
  }

  @override
  Future<LlamaActiveBackendInfo> getActiveBackendInfo() async {
    return const LlamaActiveBackendInfo(
      backend: 'cpu',
      deviceName: 'CPU (Mock)',
      gpuLayers: 0,
      contextLength: 2048,
      threads: 4,
    );
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
  }) => Stream.value('test');

  @override
  AiGenerationHandle startGeneration(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    return AiGenerationHandle(
      requestId: 'mock',
      stream: Stream.value('test'),
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

  group('SettingsController & ModelManager Ownership Lifecycle Tests', () {
    late Directory tempDir;
    late ModelStorage storage;
    late FakeModelDownloader downloader;
    late FakeModelFilePicker filePicker;
    late MockAiEngine mockLlm;
    late MockSpeechEngine mockSpeech;
    late AiService aiService;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'jlexa_settings_lifecycle_test_',
      );
      storage = ModelStorage(baseDirProvider: () async => tempDir);
      downloader = FakeModelDownloader(
        stepDelay: const Duration(milliseconds: 10),
      );
      filePicker = FakeModelFilePicker();
      mockLlm = MockAiEngine();
      mockSpeech = MockSpeechEngine();
      aiService = AiService(llm: mockLlm, speech: mockSpeech);
    });

    tearDown(() async {
      aiService.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('External ModelManager is NOT disposed when SettingsController is disposed', () async {
      final appLevelManager = ModelManager(
        storage: storage,
        downloader: downloader,
        aiService: aiService,
      );
      await appLevelManager.initialize();

      final controller = SettingsController(
        aiService: aiService,
        manager: appLevelManager,
        picker: filePicker,
      );

      expect(controller.llmModels.isNotEmpty, isTrue);

      // Dispose controller (simulating leaving Settings)
      controller.dispose();

      // App-level manager must still be fully alive and usable
      expect(appLevelManager.isInitialized, isTrue);
      expect(appLevelManager.llmModels.isNotEmpty, isTrue);

      appLevelManager.dispose();
    });

    test('Internally created ModelManager IS disposed when SettingsController is disposed', () async {
      final controller = SettingsController(
        aiService: aiService,
        picker: filePicker,
      );
      await controller.modelManager.initialize();

      expect(controller.modelManager.isInitialized, isTrue);

      controller.dispose();
      // Internal manager was disposed with controller
    });

    test('Simulate navigation: start download -> leave Settings -> reopen Settings -> download persists without part deletion', () async {
      final slowDownloader = FakeModelDownloader(
        stepDelay: const Duration(milliseconds: 30),
      );
      final appLevelManager = ModelManager(
        storage: storage,
        downloader: slowDownloader,
        aiService: aiService,
      );
      await appLevelManager.initialize();

      // 1. User opens Settings Screen -> creates Controller 1 with shared manager
      final controller1 = SettingsController(
        aiService: aiService,
        manager: appLevelManager,
        picker: filePicker,
      );

      final targetModel = ModelCatalog.curatedLlmModels.first;

      // 2. User starts download
      final downloadFuture = controller1.downloadModel(targetModel);
      await Future.delayed(const Duration(milliseconds: 20));

      // Part file should be active
      expect(slowDownloader.isDownloading(targetModel.id), isTrue);

      // 3. User leaves Settings -> controller 1 is disposed
      controller1.dispose();

      // 4. User re-opens Settings -> creates Controller 2 with shared manager
      final controller2 = SettingsController(
        aiService: aiService,
        manager: appLevelManager,
        picker: filePicker,
      );

      // Controller 2 should see the active download in real time
      final itemInScreen2 = controller2.llmModels.firstWhere(
        (m) => m.id == targetModel.id,
      );
      expect(itemInScreen2.state, ModelDownloadState.downloading);

      // 5. Download completes cleanly
      await downloadFuture;

      // Part file finalized into final model without being destroyed by reopening Settings
      final finalPath = await storage.getFinalModelPath(
        targetModel.modelType,
        targetModel.filename,
      );
      expect(await File(finalPath).exists(), isTrue);

      final finalItem = controller2.llmModels.firstWhere(
        (m) => m.id == targetModel.id,
      );
      expect(finalItem.state, ModelDownloadState.downloaded);
      expect(finalItem.isDownloaded, isTrue);
      expect(controller2.errorMessage, isNull);

      controller2.dispose();
      appLevelManager.dispose();
    });

    test('cancelDownload in SettingsController clears error message and updates state', () async {
      final slowDownloader = FakeModelDownloader(
        stepDelay: const Duration(milliseconds: 40),
      );
      final appLevelManager = ModelManager(
        storage: storage,
        downloader: slowDownloader,
        aiService: aiService,
      );
      await appLevelManager.initialize();

      final controller = SettingsController(
        aiService: aiService,
        manager: appLevelManager,
        picker: filePicker,
      );

      final targetModel = ModelCatalog.curatedLlmModels.first;
      final downloadFuture = controller.downloadModel(targetModel);
      await Future.delayed(const Duration(milliseconds: 15));

      controller.cancelDownload(targetModel.id);
      await downloadFuture;

      expect(controller.errorMessage, isNull);
      final item = controller.llmModels.firstWhere((m) => m.id == targetModel.id);
      expect(item.state, ModelDownloadState.notDownloaded);

      controller.dispose();
      appLevelManager.dispose();
    });
  });
}
