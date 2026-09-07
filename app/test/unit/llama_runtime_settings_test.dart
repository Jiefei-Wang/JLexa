import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_engine.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/prompt_builder.dart';
import 'package:jlexa/core/ai/speech_engine.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';

class MockTestAiEngine implements AiEngine {
  bool _isLoaded = false;
  String? _loadedPath;
  LlamaRuntimeSettings? lastRuntimeSettings;
  bool shouldFail = false;
  LlamaBackendPreference? failingBackend;
  bool generating = false;
  Completer<void>? loadGate;
  Completer<void>? loadStarted;

  @override
  bool get isLoaded => _isLoaded;
  @override
  String? get loadedModelPath => _loadedPath;
  @override
  AiModelState get state => generating
      ? AiModelState.generating
      : (_isLoaded ? AiModelState.ready : AiModelState.noModel);

  @override
  Future<void> loadModel(
    String modelPath, {
    AiGenerationSettings? settings,
    LlamaRuntimeSettings? runtimeSettings,
  }) async {
    _isLoaded = false; // Native reload releases the previous model first.
    _loadedPath = null;
    if (loadStarted?.isCompleted == false) loadStarted!.complete();
    if (loadGate != null) await loadGate!.future;
    if (shouldFail ||
        (failingBackend != null &&
            runtimeSettings?.backend == failingBackend)) {
      throw Exception('Simulated engine load failure');
    }
    _isLoaded = true;
    _loadedPath = modelPath;
    lastRuntimeSettings = runtimeSettings;
  }

  @override
  Future<List<LlamaBackendInfo>> getAvailableBackends() async {
    return const [
      LlamaBackendInfo(
        backend: 'cpu',
        compiled: true,
        available: true,
        deviceName: 'CPU (Host)',
      ),
      LlamaBackendInfo(
        backend: 'vulkan',
        compiled: true,
        available: true,
        deviceName: 'Vulkan GPU (Adreno 730)',
      ),
    ];
  }

  @override
  Future<LlamaActiveBackendInfo> getActiveBackendInfo() async {
    return LlamaActiveBackendInfo(
      backend: lastRuntimeSettings?.backend == LlamaBackendPreference.vulkan
          ? 'vulkan'
          : 'cpu',
      deviceName: lastRuntimeSettings?.backend == LlamaBackendPreference.vulkan
          ? 'Vulkan GPU (Adreno 730)'
          : 'CPU (Host)',
      gpuLayers: lastRuntimeSettings?.gpuLayers ?? -1,
      contextLength: lastRuntimeSettings?.contextLength ?? 2048,
      threads: lastRuntimeSettings?.threads ?? 4,
      batchSize: lastRuntimeSettings?.batchSize ?? 512,
      ubatchSize: lastRuntimeSettings?.microBatchSize ?? 512,
      flashAttention:
          lastRuntimeSettings?.flashAttention ?? LlamaFlashAttention.auto,
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
      requestId: 'req_1',
      stream: Stream.value('test'),
      onCancel: () async {},
    );
  }
}

class MockTestSpeechEngine implements SpeechRecognitionEngine {
  bool _isLoaded = false;
  String? _loadedPath;
  bool shouldFail = false;

  @override
  bool get isLoaded => _isLoaded;
  @override
  String? get loadedModelPath => _loadedPath;

  @override
  Future<void> loadModel(String modelPath) async {
    if (shouldFail) {
      throw Exception('Simulated speech load failure');
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
  Future<List<AudioSegment>> transcribeAudio({
    required String audioPath,
    required String lessonId,
    String? requestId,
    int nThreads = 4,
    void Function(double progress)? onProgress,
  }) async {
    return const [];
  }

  @override
  Future<Map<String, dynamic>?> getAudioMetadata(String audioPath) async {
    return {'duration_ms': 1000};
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  group('LlamaRuntimeSettings Unit Tests', () {
    test('LlamaBackendPreference labels, descriptions, and parsing', () {
      expect(
        LlamaBackendPreference.fromString('cpu'),
        LlamaBackendPreference.cpu,
      );
      expect(
        LlamaBackendPreference.fromString('VULKAN'),
        LlamaBackendPreference.vulkan,
      );
      expect(
        LlamaBackendPreference.fromString('opencl'),
        LlamaBackendPreference.opencl,
      );
      expect(
        LlamaBackendPreference.fromString('auto'),
        LlamaBackendPreference.auto,
      );
      expect(
        LlamaBackendPreference.fromString('invalid'),
        LlamaBackendPreference.auto,
      );

      expect(LlamaBackendPreference.auto.label, contains('Auto'));
      expect(LlamaBackendPreference.vulkan.description, contains('Vulkan'));
    });

    test('LlamaFlashAttention values and parsing', () {
      expect(LlamaFlashAttention.auto.nativeValue, -1);
      expect(LlamaFlashAttention.on.nativeValue, 1);
      expect(LlamaFlashAttention.off.nativeValue, 0);

      expect(LlamaFlashAttention.fromNativeValue(1), LlamaFlashAttention.on);
      expect(LlamaFlashAttention.fromNativeValue(0), LlamaFlashAttention.off);
      expect(LlamaFlashAttention.fromNativeValue(-1), LlamaFlashAttention.auto);

      expect(LlamaFlashAttention.fromString('enabled'), LlamaFlashAttention.on);
      expect(
        LlamaFlashAttention.fromString('disabled'),
        LlamaFlashAttention.off,
      );
      expect(LlamaFlashAttention.fromString('auto'), LlamaFlashAttention.auto);
    });

    test('LlamaRuntimeSettings serialization and copyWith', () {
      const settings = LlamaRuntimeSettings(
        backend: LlamaBackendPreference.vulkan,
        threads: 6,
        contextLength: 4096,
        gpuLayers: 33,
        batchSize: 1024,
        microBatchSize: 256,
        flashAttention: LlamaFlashAttention.on,
      );

      final map = settings.toMap();
      final roundtrip = LlamaRuntimeSettings.fromMap(map);

      expect(roundtrip.backend, LlamaBackendPreference.vulkan);
      expect(roundtrip.threads, 6);
      expect(roundtrip.contextLength, 4096);
      expect(roundtrip.gpuLayers, 33);
      expect(roundtrip.batchSize, 1024);
      expect(roundtrip.microBatchSize, 256);
      expect(roundtrip.flashAttention, LlamaFlashAttention.on);

      final modified = roundtrip.copyWith(
        backend: LlamaBackendPreference.cpu,
        threads: null,
      );
      expect(modified.backend, LlamaBackendPreference.cpu);
      expect(modified.threads, isNull);
      expect(modified.resolvedThreads, 4);
    });
  });

  group('AiService Startup Restoration & Hardware Runtime Tests', () {
    late Directory tempDir;
    late File mockLlmFile;
    late File mockWhisperFile;
    late MockTestAiEngine aiEngine;
    late MockTestSpeechEngine speechEngine;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('jlexa_test_ai_');
      mockLlmFile = File('${tempDir.path}/test_model.gguf');
      await mockLlmFile.writeAsString('mock llm data');

      mockWhisperFile = File('${tempDir.path}/test_whisper.bin');
      await mockWhisperFile.writeAsString('mock whisper data');

      final db = await openDatabase(
        inMemoryDatabasePath,
        version: 1,
        onCreate: (db, v) async {
          await db.execute(
            'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
        },
      );
      AppDatabase.setDatabaseForTesting(db);

      aiEngine = MockTestAiEngine();
      speechEngine = MockTestSpeechEngine();
    });

    tearDown(() async {
      AppDatabase.setDatabaseForTesting(null);
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('AiService.initialize restores saved models and resolves runtime configuration', () async {
      final db = await AppDatabase.instance.database;
      await db.insert('app_settings', {
        'key': 'llm_model_path',
        'value': mockLlmFile.path,
      });
      await db.insert('app_settings', {
        'key': 'whisper_model_path',
        'value': mockWhisperFile.path,
      });
      await db.insert('app_settings', {
        'key': 'llama_runtime_settings',
        'value': jsonEncode(
          const LlamaRuntimeSettings(
            backend: LlamaBackendPreference.vulkan,
            threads: 6,
            contextLength: 4096,
          ).toMap(),
        ),
      });

      final service = AiService(llm: aiEngine, speech: speechEngine);
      expect(service.initState, AiServiceInitState.uninitialized);

      await service.initialize();

      expect(service.initState, AiServiceInitState.ready);
      expect(service.configuredLlmPath, mockLlmFile.path);
      expect(service.configuredSpeechPath, mockWhisperFile.path);
      expect(aiEngine.isLoaded, isTrue);
      expect(speechEngine.isLoaded, isTrue);
      expect(
        service.llamaRuntimeSettings.backend,
        LlamaBackendPreference.vulkan,
      );
      expect(service.llamaRuntimeSettings.threads, 6);
      expect(service.availableBackends.length, 2);
      expect(service.activeBackendInfo.backend, 'vulkan');
      expect(service.llmRestorationError, isNull);
      expect(service.speechRestorationError, isNull);

      service.dispose();
    });

    test(
      'AiService handles missing/stale files gracefully without crashing',
      () async {
        final db = await AppDatabase.instance.database;
        await db.delete('app_settings');
        await db.insert('app_settings', {
          'key': 'llm_model_path',
          'value': '/nonexistent/path/model.gguf',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await db.insert('app_settings', {
          'key': 'whisper_model_path',
          'value': '/nonexistent/path/whisper.bin',
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        final service = AiService(llm: aiEngine, speech: speechEngine);
        await service.initialize();

        expect(service.initState, AiServiceInitState.readyWithWarnings);
        expect(aiEngine.isLoaded, isFalse);
        expect(speechEngine.isLoaded, isFalse);
        expect(service.llmRestorationError, contains('not found'));
        expect(service.speechRestorationError, contains('not found'));

        service.dispose();
      },
    );

    test('AiService restores Android SAF content URI models', () async {
      const llmUri =
          'content://com.android.externalstorage.documents/tree/models/document/llm%2Fmodel.gguf';
      const whisperUri =
          'content://com.android.externalstorage.documents/tree/models/document/whisper%2Fmodel.bin';
      final db = await AppDatabase.instance.database;
      await db.delete('app_settings');
      await db.insert('app_settings', {
        'key': 'llm_model_path',
        'value': llmUri,
      });
      await db.insert('app_settings', {
        'key': 'whisper_model_path',
        'value': whisperUri,
      });

      final service = AiService(llm: aiEngine, speech: speechEngine);
      await service.initialize();

      expect(service.initState, AiServiceInitState.ready);
      expect(aiEngine.loadedModelPath, llmUri);
      expect(speechEngine.loadedModelPath, whisperUri);
      expect(service.llmRestorationError, isNull);
      expect(service.speechRestorationError, isNull);

      service.dispose();
    });

    test('AiService transactional reload applies new runtime settings to loaded model', () async {
      final service = AiService(llm: aiEngine, speech: speechEngine);
      await service.initialize();

      // Load model explicitly with CPU settings
      await service.loadLlmModel(
        mockLlmFile.path,
        runtimeSettings: const LlamaRuntimeSettings(
          backend: LlamaBackendPreference.cpu,
          threads: 4,
        ),
      );
      expect(aiEngine.isLoaded, isTrue);
      expect(service.activeBackendInfo.backend, 'cpu');

      // Update settings to Vulkan -> triggers automatic reload
      await service.updateLlamaRuntimeSettings(
        const LlamaRuntimeSettings(
          backend: LlamaBackendPreference.vulkan,
          threads: 8,
        ),
        autoReload: true,
      );

      expect(aiEngine.isLoaded, isTrue);
      expect(service.activeBackendInfo.backend, 'vulkan');
      expect(service.activeBackendInfo.threads, 8);

      service.dispose();
    });

    test('Failed Vulkan reload restores the actual prior runtime and saved preference', () async {
      final service = AiService(llm: aiEngine, speech: speechEngine);
      await service.updateLlamaRuntimeSettings(
        const LlamaRuntimeSettings(backend: LlamaBackendPreference.cpu),
      );
      await service.loadLlmModel(
        mockLlmFile.path,
        runtimeSettings: const LlamaRuntimeSettings(
          backend: LlamaBackendPreference.cpu,
          threads: 6,
        ),
      );
      aiEngine.failingBackend = LlamaBackendPreference.vulkan;
      await expectLater(
        service.updateLlamaRuntimeSettings(
          const LlamaRuntimeSettings(backend: LlamaBackendPreference.vulkan),
        ),
        throwsA(
          isA<AiGenerationException>().having(
            (e) => e.message,
            'message',
            contains('restored'),
          ),
        ),
      );
      expect(aiEngine.isLoaded, isTrue);
      expect(aiEngine.loadedModelPath, mockLlmFile.path);
      expect(service.activeBackendInfo.backend, 'cpu');
      expect(service.activeBackendInfo.threads, 6);
      expect(service.llamaRuntimeSettings.backend, LlamaBackendPreference.cpu);
      final rows = await (await AppDatabase.instance.database).query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['llama_runtime_settings'],
      );
      expect(jsonDecode(rows.single['value'] as String)['backend'], 'cpu');
      service.dispose();
    });

    test(
      'Failed rollback reports both failures and clears stale active runtime',
      () async {
        final service = AiService(llm: aiEngine, speech: speechEngine);
        await service.updateLlamaRuntimeSettings(
          const LlamaRuntimeSettings(backend: LlamaBackendPreference.cpu),
        );
        await service.loadLlmModel(mockLlmFile.path);
        aiEngine.shouldFail = true;
        await expectLater(
          service.updateLlamaRuntimeSettings(
            const LlamaRuntimeSettings(backend: LlamaBackendPreference.vulkan),
          ),
          throwsA(
            isA<AiGenerationException>().having(
              (e) => e.message,
              'message',
              contains('previous runtime also failed'),
            ),
          ),
        );
        expect(aiEngine.isLoaded, isFalse);
        expect(
          service.activeBackendInfo.toMap(),
          const LlamaActiveBackendInfo().toMap(),
        );
        expect(
          service.llamaRuntimeSettings.backend,
          LlamaBackendPreference.cpu,
        );
        service.dispose();
      },
    );

    test('Concurrent runtime switch is rejected while the accepted switch finishes', () async {
      final service = AiService(llm: aiEngine, speech: speechEngine);
      await service.loadLlmModel(mockLlmFile.path);
      aiEngine.loadStarted = Completer<void>();
      aiEngine.loadGate = Completer<void>();
      final switchFuture = service.updateLlamaRuntimeSettings(
        const LlamaRuntimeSettings(backend: LlamaBackendPreference.vulkan),
      );
      await aiEngine.loadStarted!.future;
      await expectLater(
        service.updateLlamaRuntimeSettings(
          const LlamaRuntimeSettings(backend: LlamaBackendPreference.cpu),
        ),
        throwsA(isA<AiBusyException>()),
      );
      aiEngine.loadGate!.complete();
      await switchFuture;
      expect(
        service.llamaRuntimeSettings.backend,
        LlamaBackendPreference.vulkan,
      );
      expect(service.activeBackendInfo.backend, 'vulkan');
      service.dispose();
    });

    test('Runtime settings cannot interrupt an active generation', () async {
      final service = AiService(llm: aiEngine, speech: speechEngine);
      await service.loadLlmModel(mockLlmFile.path);
      aiEngine.generating = true;
      await expectLater(
        service.updateLlamaRuntimeSettings(
          const LlamaRuntimeSettings(backend: LlamaBackendPreference.vulkan),
        ),
        throwsA(isA<AiBusyException>()),
      );
      expect(aiEngine.isLoaded, isTrue);
      expect(service.llamaRuntimeSettings.backend, LlamaBackendPreference.auto);
      service.dispose();
    });
  });
}
