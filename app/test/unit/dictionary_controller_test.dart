import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_engine.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/prompt_builder.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:jlexa/features/dictionary/dictionary_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';

class ControllableAiEngine implements AiEngine {
  bool _isLoaded = true;
  String? _loadedPath = '/mock/path/model.gguf';

  final List<StreamController<String>> activeControllers = [];
  bool shouldThrowOnStart = false;
  String? errorMessage;

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
  }) => Stream.value('test');

  @override
  AiGenerationHandle startGeneration(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    if (shouldThrowOnStart) {
      return AiGenerationHandle(
        requestId: 'err_req',
        stream: Stream.error(Exception(errorMessage ?? 'Generation failed')),
        onCancel: () async {},
      );
    }

    final controller = StreamController<String>();
    activeControllers.add(controller);

    return AiGenerationHandle(
      requestId: 'req_${activeControllers.length}',
      stream: controller.stream,
      onCancel: () async {
        if (!controller.isClosed) {
          controller.addError(const AiCancelledException('AI generation was cancelled.'));
          await controller.close();
        }
      },
    );
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  group('DictionaryController AI Tab Cancellation & State Tests', () {
    late DictionaryRepository dictionaryRepo;
    late VocabularyRepository vocabularyRepo;
    late ControllableAiEngine mockEngine;
    late AiService aiService;
    late DictionaryController controller;

    setUp(() async {
      dictionaryRepo = DictionaryRepository();
      vocabularyRepo = VocabularyRepository();
      mockEngine = ControllableAiEngine();
      aiService = AiService(llm: mockEngine);
      controller = DictionaryController(
        dictionaryRepo: dictionaryRepo,
        vocabularyRepo: vocabularyRepo,
        aiService: aiService,
        initialWord: 'resilient',
      );
      await dictionaryRepo.lookupWord('resilient');
      await controller.search('resilient');
    });

    tearDown(() {
      controller.dispose();
      aiService.dispose();
    });

    test('Switching away from AI Translation cancels without leaving error text', () async {
      // 1. Switch to AI Translation Tab
      controller.setSelectedTab(1);
      expect(controller.selectedTab, 1);
      expect(controller.isAiGenerating, isTrue);

      // Verify a stream was opened
      expect(mockEngine.activeControllers.isNotEmpty, isTrue);
      final stream1 = mockEngine.activeControllers.last;

      // Emit a partial chunk
      stream1.add('Partial translation chunk...');
      await Future.delayed(const Duration(milliseconds: 20));
      expect(controller.aiTranslationText, contains('Partial translation'));

      // 2. User switches to Tab 0 (Dictionary) while translation is generating
      controller.setSelectedTab(0);
      expect(controller.selectedTab, 0);
      expect(controller.isAiGenerating, isFalse);

      await Future.delayed(const Duration(milliseconds: 20));

      // 3. Verify no error text poisoned the translation field
      expect(controller.aiTranslationText.contains('cancelled'), isFalse);
      expect(controller.aiTranslationText.contains('unavailable'), isFalse);

      // 4. User returns to AI Translation Tab (Tab 1)
      controller.setSelectedTab(1);
      expect(controller.selectedTab, 1);
      expect(controller.isAiGenerating, isTrue);

      // Fresh stream started
      final stream2 = mockEngine.activeControllers.last;
      expect(stream2, isNot(same(stream1)));

      stream2.add('New fresh translation response.');
      await stream2.close();
      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.aiTranslationText, 'New fresh translation response.');
      expect(controller.isAiGenerating, isFalse);
    });

    test('Switching away from AI Explanation cancels without leaving error text', () async {
      // 1. Switch to AI Explanation Tab
      controller.setSelectedTab(2);
      expect(controller.selectedTab, 2);
      expect(controller.isAiGenerating, isTrue);

      final stream1 = mockEngine.activeControllers.last;
      stream1.add('Partial explanation chunk...');
      await Future.delayed(const Duration(milliseconds: 20));

      // 2. Switch away to Tab 0
      controller.setSelectedTab(0);
      expect(controller.selectedTab, 0);
      expect(controller.isAiGenerating, isFalse);

      await Future.delayed(const Duration(milliseconds: 20));
      expect(controller.aiExplanationText.contains('cancelled'), isFalse);
      expect(controller.aiExplanationText.contains('unavailable'), isFalse);

      // 3. Return to Tab 2
      controller.setSelectedTab(2);
      expect(controller.selectedTab, 2);
      expect(controller.isAiGenerating, isTrue);

      final stream2 = mockEngine.activeControllers.last;
      stream2.add('New completed explanation.');
      await stream2.close();
      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.aiExplanationText, 'New completed explanation.');
      expect(controller.isAiGenerating, isFalse);
    });

    test('Stale chunk protection: old stream emitting after tab change does not pollute state', () async {
      final unclosedController = StreamController<String>.broadcast();
      final customEngine = ControllableAiEngine();
      final customAiService = AiService(llm: customEngine);

      // Create a handle whose stream will continue to emit after cancel
      final customDictController = DictionaryController(
        dictionaryRepo: dictionaryRepo,
        vocabularyRepo: vocabularyRepo,
        aiService: customAiService,
        initialWord: 'resilient',
      );
      await customDictController.search('resilient');

      customDictController.setSelectedTab(1);
      final stream1 = customEngine.activeControllers.last;

      // Switch away immediately to Tab 0
      customDictController.setSelectedTab(0);

      // If active controller is open, emit chunk
      if (!stream1.isClosed) {
        stream1.add('Late rogue chunk from old request');
      }
      await Future.delayed(const Duration(milliseconds: 20));

      // Active state on Tab 0 or Translation must not contain the rogue chunk
      expect(customDictController.aiTranslationText, isNot(contains('Late rogue chunk')));

      customDictController.dispose();
      customAiService.dispose();
      await unclosedController.close();
    });

    test('True generation failure surfaces informative error message', () async {
      mockEngine.shouldThrowOnStart = true;
      mockEngine.errorMessage = 'Out of memory native llama.cpp';

      controller.setSelectedTab(1);
      await Future.delayed(const Duration(milliseconds: 30));

      expect(controller.aiTranslationText, contains('Translation unavailable'));
      expect(controller.aiTranslationText, contains('Out of memory'));
      expect(controller.isAiGenerating, isFalse);
    });
  });
}
