import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:jlexa/features/settings/settings_screen.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';
import '../unit/backend_plugins_test.dart' show TestPlugins;

class MockAiEngine implements AiEngine {
  bool _isLoaded = false;
  String? _loadedPath;
  final loadedThreadSettings = <int?>[];

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
    loadedThreadSettings.add(runtimeSettings?.threads);
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
  Future<Map<String, dynamic>?> getAudioMetadata(String audioPath) async =>
      null;

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

  group('SettingsScreen Widget Tests', () {
    late Directory tempDir;
    late ModelStorage storage;
    late FakeModelDownloader downloader;
    late FakeModelFilePicker filePicker;
    late MockAiEngine mockLlm;
    late MockSpeechEngine mockSpeech;
    late AiService aiService;
    late ModelManager modelManager;
    late SettingsController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'jlexa_settings_widget_test_',
      );
      storage = ModelStorage(baseDirProvider: () async => tempDir);
      downloader = FakeModelDownloader(
        stepDelay: const Duration(milliseconds: 10),
      );
      filePicker = FakeModelFilePicker();
      mockLlm = MockAiEngine();
      mockSpeech = MockSpeechEngine();
      aiService = AiService(llm: mockLlm, speech: mockSpeech);
      modelManager = ModelManager(
        storage: storage,
        downloader: downloader,
        aiService: aiService,
      );
      await modelManager.initialize();

      controller = SettingsController(
        aiService: aiService,
        manager: modelManager,
        picker: filePicker,
      );
    });

    tearDown(() async {
      controller.dispose();
      modelManager.dispose();
      aiService.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets(
      'backend choices contain only Benchmark/Import actions and removable imported rows',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 5000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        controller.dispose();
        modelManager.dispose();
        aiService.dispose();
        final plugins = TestPlugins()..selected = 'a';
        aiService = AiService(
          llm: mockLlm,
          speech: mockSpeech,
          plugins: plugins,
        );
        modelManager = ModelManager(
          storage: storage,
          downloader: downloader,
          aiService: aiService,
        );
        controller = SettingsController(
          aiService: aiService,
          manager: modelManager,
          picker: filePicker,
        );
        await tester.runAsync(() async {
          await modelManager.initialize();
          await aiService.refreshPluginInfo();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(aiService: aiService, controller: controller),
          ),
        );
        await tester.runAsync(controller.refreshModels);
        await tester.pumpAndSettle();
        expect(find.text('Backend Plugins'), findsNothing);
        expect(find.text('Use built-in'), findsNothing);
        expect(find.text('Benchmark'), findsNWidgets(2));
        expect(find.text('Import'), findsNWidgets(2));
        expect(find.text('Whisper Backend'), findsOneWidget);
        expect(find.text('Snapdragon'), findsOneWidget);
        expect(find.byTooltip('Delete Other engine'), findsOneWidget);
        await tester.tap(find.byTooltip('Delete Other engine'));
        await tester.pumpAndSettle();
        expect(find.text('Other engine'), findsNothing);
        expect(plugins.selected, 'a');
        plugins.fail = true;
        await tester.tap(find.text('Import').first);
        await tester.pumpAndSettle();
        expect(find.textContaining('expected arm64-v8a'), findsOneWidget);
        expect(plugins.selected, 'a');
        expect(find.text('Snapdragon'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Renders curated models, recommended badges, and import options',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 4000));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(aiService: aiService, controller: controller),
          ),
        );
        await tester.pump();

        // Settings refreshes the filesystem inventory on entry. Await it rather
        // than depending on disk I/O finishing within a single frame.
        await tester.runAsync(controller.refreshModels);
        await tester.pump();

        // Verify Headers
        expect(find.text('Settings & Local Models'), findsOneWidget);
        expect(find.text('Local Language Model (LLM)'), findsOneWidget);
        expect(find.text('Speech Recognition Model (Whisper)'), findsOneWidget);
        expect(
          find.text('llama.cpp Runtime & Hardware Acceleration'),
          findsOneWidget,
        );
        expect(find.text('Sampling & Generation Settings'), findsOneWidget);

        // Verify Curated Model Names
        expect(find.text('Qwen2.5 0.5B Instruct'), findsOneWidget);
        expect(find.text('Qwen2.5 1.5B Instruct'), findsOneWidget);
        expect(find.text('Qwen2.5 3B Instruct'), findsOneWidget);
        expect(find.text('SmolLM2 360M Instruct'), findsOneWidget);

        expect(find.text('Whisper Tiny (English)'), findsOneWidget);
        expect(find.text('Whisper Base (English)'), findsOneWidget);
        expect(find.text('Whisper Small (English)'), findsOneWidget);

        // Verify Badges and Custom Models Note
        expect(find.text('RECOMMENDED'), findsNWidgets(2));
        expect(find.text('Model Storage Directory'), findsOneWidget);
        expect(find.text('Custom Models'), findsOneWidget);
      },
    );

    testWidgets(
      'Recommended model names remain complete on phone widths in both download states',
      (tester) async {
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final model = ModelCatalog.curatedWhisperModels.firstWhere(
          (model) => model.isRecommended,
        );
        for (final downloaded in [false, true]) {
          if (downloaded) {
            await tester.runAsync(() => controller.downloadModel(model));
          }
          for (final layout in [
            (width: 393.0, scale: 1.0),
            (width: 320.0, scale: 2.0),
          ]) {
            await tester.pumpWidget(const SizedBox());
            await tester.binding.setSurfaceSize(Size(layout.width, 850));
            await tester.pumpWidget(
              MaterialApp(
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(layout.scale)),
                  child: child!,
                ),
                home: SettingsScreen(
                  aiService: aiService,
                  controller: controller,
                ),
              ),
            );
            // Settings starts a real filesystem inventory scan on entry.
            // Finish that work before scrolling in the widget's fake clock.
            await tester.runAsync(controller.refreshModels);
            await tester.pump();
            final name = find.text(model.displayName);
            await tester.scrollUntilVisible(
              name,
              300,
              maxScrolls: 60,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            final paragraph = tester.renderObject<RenderParagraph>(name);
            expect(paragraph.didExceedMaxLines, isFalse);
            final header = find
                .ancestor(of: name, matching: find.byType(Column))
                .first;
            expect(
              find.descendant(of: header, matching: find.text('RECOMMENDED')),
              findsOneWidget,
            );
            final state = find.descendant(
              of: header,
              matching: find.text(downloaded ? 'DOWNLOADED' : 'GET'),
            );
            expect(state, findsOneWidget);
            expect(
              tester.getRect(state).right,
              lessThanOrEqualTo(layout.width),
            );
            expect(tester.takeException(), isNull);
          }
        }
      },
    );

    testWidgets(
      'When storage is unconfigured, catalog is hidden and setup prompt is displayed',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final unconfiguredBackend = FileSystemModelStorageBackend(
          baseDir: null,
          isConfigured: false,
        );
        final unconfiguredStorage = ModelStorage(backend: unconfiguredBackend);
        final unconfiguredManager = ModelManager(
          storage: unconfiguredStorage,
          downloader: downloader,
          aiService: aiService,
        );
        await unconfiguredManager.initialize();

        final unconfiguredController = SettingsController(
          aiService: aiService,
          manager: unconfiguredManager,
          picker: filePicker,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              aiService: aiService,
              controller: unconfiguredController,
            ),
          ),
        );
        await tester.pump();

        // Verify unconfigured banner and prompt are shown
        expect(find.text('Storage Directory Required'), findsOneWidget);
        expect(find.text('Model Catalog Unavailable'), findsOneWidget);
        expect(
          find.widgetWithText(FilledButton, 'Select Storage Folder'),
          findsOneWidget,
        );

        // Verify catalog is hidden
        expect(find.text('Local Language Model (LLM)'), findsNothing);
        expect(find.text('Speech Recognition Model (Whisper)'), findsNothing);

        unconfiguredController.dispose();
        unconfiguredManager.dispose();
      },
    );

    testWidgets(
      'Loaded legacy Whisper remains visible without a selected storage folder',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        late ModelManager legacyManager;
        late SettingsController legacyController;
        await tester.runAsync(() async {
          final file = File(p.join(tempDir.path, 'ggml-tiny.bin'));
          await file.writeAsBytes([1, 2, 3]);
          await aiService.loadSpeechModel(file.path);
          legacyManager = ModelManager(
            storage: ModelStorage(backend: FileSystemModelStorageBackend()),
            downloader: downloader,
            aiService: aiService,
          );
          await legacyManager.initialize();
          legacyController = SettingsController(
            aiService: aiService,
            manager: legacyManager,
          );
        });
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              aiService: aiService,
              controller: legacyController,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('ggml-tiny.bin'), findsOneWidget);
        expect(find.text('LOADED'), findsOneWidget);
        expect(
          find.text('Saved model outside the selected folder'),
          findsOneWidget,
        );
        expect(find.text('Whisper Tiny (English)'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        legacyController.dispose();
        legacyManager.dispose();
      },
    );

    testWidgets('CPU thread drag reloads only once with its final value', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => aiService.loadLlmModel('mock-runtime.gguf'));
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(aiService: aiService, controller: controller),
        ),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Advanced llama.cpp Parameters'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced llama.cpp Parameters'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('CPU Threads'));
      await tester.pumpAndSettle();
      final sliderFinder = find.byType(Slider).first;
      final rect = tester.getRect(sliderFinder);
      final before = mockLlm.loadedThreadSettings.length;
      final gesture = await tester.startGesture(
        Offset(rect.left + rect.width * .35, rect.center.dy),
      );
      await tester.pump();
      for (final fraction in [.45, .6, .8]) {
        await gesture.moveTo(
          Offset(rect.left + rect.width * fraction, rect.center.dy),
        );
        await tester.pump();
        expect(mockLlm.loadedThreadSettings.length, before);
      }
      final finalValue = tester.widget<Slider>(sliderFinder).value.round();
      await tester.runAsync(() async {
        await gesture.up();
        for (var i = 0; i < 20 && controller.isLoading; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(controller.isLoading, isFalse);
      expect(mockLlm.loadedThreadSettings.length, before + 1);
      expect(mockLlm.loadedThreadSettings.last, finalValue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Download workflow with progress, completion, use, and unload',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(aiService: aiService, controller: controller),
          ),
        );
        await tester.pump();

        // Download the model
        await tester.runAsync(() async {
          await controller.downloadModel(ModelCatalog.curatedLlmModels.first);
        });
        await tester.pump();

        // After download completes, button should change to 'Use'
        expect(find.widgetWithText(FilledButton, 'Use'), findsWidgets);

        // Load model
        final downloadedItem = controller.llmModels.firstWhere(
          (m) => m.id == ModelCatalog.curatedLlmModels.first.id,
        );
        await tester.runAsync(() async {
          await controller.loadModel(downloadedItem);
        });
        await tester.pump();

        // Model is loaded -> LOADED badge and Unload button visible
        expect(find.text('LOADED'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Unload'), findsOneWidget);

        // Unload model
        final loadedItem = controller.llmModels.firstWhere(
          (m) => m.id == ModelCatalog.curatedLlmModels.first.id,
        );
        await tester.runAsync(() async {
          await controller.unloadModel(loadedItem);
        });
        await tester.pump();

        // Returns to downloaded state with 'Use' button
        expect(find.widgetWithText(FilledButton, 'Use'), findsWidgets);
      },
    );

    testWidgets('Local GGUF import loads model into managed state', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      late Directory extDir;
      late File extFile;

      await tester.runAsync(() async {
        extDir = await Directory.systemTemp.createTemp('ext_');
        extFile = File(p.join(extDir.path, 'custom_imported.gguf'));
        await extFile.writeAsBytes(List<int>.filled(512, 0x11));
        filePicker.nextLlmPath = extFile.path;
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(aiService: aiService, controller: controller),
        ),
      );
      await tester.pump();

      // Import Local GGUF
      await tester.runAsync(() async {
        await controller.pickAndImportLlmModel();
      });
      await tester.pump();

      // Verify custom model is displayed and loaded
      expect(find.text('custom_imported.gguf'), findsOneWidget);
      expect(find.text('LOADED'), findsOneWidget);

      await tester.runAsync(() async {
        if (await extDir.exists()) {
          await extDir.delete(recursive: true);
        }
      });
    });
  });
}
