import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_engine.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/prompt_builder.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:jlexa/core/dictionary/dictionary_models.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:jlexa/core/vocabulary/vocabulary_models.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:jlexa/features/dictionary/dictionary_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';

class ControllableAiEngine implements AiEngine {
  bool _isLoaded = true;
  String? _loadedPath = '/mock/path/model.gguf';

  final List<StreamController<String>> activeControllers = [];
  final List<String> prompts = [];
  bool shouldThrowOnStart = false;
  String? errorMessage;

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
  }) => Stream.value('test');

  @override
  AiGenerationHandle startGeneration(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    prompts.add(prompt);
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
          controller.addError(
            const AiCancelledException('AI generation was cancelled.'),
          );
          await controller.close();
        }
      },
    );
  }
}

class DelayedVocabularyRepository extends VocabularyRepository {
  Completer<bool>? nextSavedCheck;

  @override
  Future<bool> isWordSaved(String word) {
    final pending = nextSavedCheck;
    if (pending == null) return super.isWordSaved(word);
    nextSavedCheck = null;
    return pending.future;
  }
}

class RefreshableDictionaryRepository extends DictionaryRepository {
  DictionaryEntry? entry = const DictionaryEntry(
    word: 'sample',
    phonetic: '',
    partOfSpeech: '',
    definitions: ['A sample.'],
  );
  @override
  Future<DictionaryEntry?> lookupWord(String word) async => entry;
  void disableImportedDictionary() {
    entry = null;
    notifyListeners();
  }
}

Future<void> waitForSavedState(
  DictionaryController controller,
  bool expected,
) async {
  if (controller.isSaved == expected) return;
  final completed = Completer<void>();
  void onChange() {
    if (controller.isSaved == expected && !completed.isCompleted) {
      completed.complete();
    }
  }

  controller.addListener(onChange);
  try {
    await completed.future.timeout(const Duration(seconds: 5));
  } finally {
    controller.removeListener(onChange);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  test('dictionary management refreshes offline result without restarting active AI', () async {
    final repo = RefreshableDictionaryRepository();
    final engine = ControllableAiEngine();
    final service = AiService(llm: engine);
    final controller = DictionaryController(
      dictionaryRepo: repo,
      vocabularyRepo: VocabularyRepository(),
      aiService: service,
    );
    await controller.search('sample');
    controller.setSelectedTab(1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.prompts.length, 1);
    expect(controller.isAiGenerating, true);
    repo.disableImportedDictionary();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.currentEntry, isNull);
    expect(controller.isAiGenerating, true);
    expect(engine.prompts.length, 1);
    expect(engine.activeControllers.single.isClosed, false);
    controller.dispose();
    service.dispose();
    repo.dispose();
  });

  group('DictionaryController AI Tab Cancellation & State Tests', () {
    late DictionaryRepository dictionaryRepo;
    late VocabularyRepository vocabularyRepo;
    late ControllableAiEngine mockEngine;
    late AiService aiService;
    late DictionaryController controller;

    setUp(() async {
      final db = await AppDatabase.instance.database;
      await db.delete('vocabulary');

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

    test(
      'Sentence query preserves case, punctuation and non-Latin text',
      () async {
        const query = 'Will Alice visit 北京 tomorrow?';
        await controller.search(query);
        expect(controller.currentQuery, query);
        expect(controller.currentEntry, isNull);
      },
    );

    test(
      'Regenerate and cancelled retries retain the custom request',
      () async {
        const request = 'Compare this word with flexible using two examples.';
        final first = controller.askAiAboutWord(request);
        mockEngine.activeControllers.last.add('A comparison with examples.');
        await mockEngine.activeControllers.last.close();
        await first;
        final originalPrompt = mockEngine.prompts.last;
        expect(originalPrompt, contains(request));

        final regenerated = controller.retryAiAnswer();
        expect(mockEngine.prompts.last, originalPrompt);
        controller.cancelAiAnswer();
        await regenerated;

        final retried = controller.retryAiAnswer();
        expect(mockEngine.prompts.last, originalPrompt);
        mockEngine.activeControllers.last.add('A second comparison.');
        await mockEngine.activeControllers.last.close();
        await retried;
        expect(
          (controller.aiAnswer as DictionaryPhraseAnswer).explanation,
          'A second comparison.',
        );

        await controller.search('meticulous');
        expect(mockEngine.prompts.last, isNot(contains(request)));
        expect(mockEngine.prompts.last, contains('meticulous'));
      },
    );

    test('Failed chip request retries the same request', () async {
      const request = 'Translate this text into natural Chinese.';
      mockEngine.shouldThrowOnStart = true;
      await controller.askAiAboutWord(request);
      expect(controller.aiErrorMessage, isNotNull);
      final originalPrompt = mockEngine.prompts.last;

      mockEngine.shouldThrowOnStart = false;
      final retried = controller.retryAiAnswer();
      expect(mockEngine.prompts.last, originalPrompt);
      mockEngine.activeControllers.last.add('有适应力的');
      await mockEngine.activeControllers.last.close();
      await retried;
      expect(controller.aiErrorMessage, isNull);
    });

    test('Navigation applies the requested mode before starting AI', () async {
      controller.setSelectedTab(1);
      mockEngine.activeControllers.last.add('adj. 有适应力的');
      await mockEngine.activeControllers.last.close();
      await pumpEventQueue();
      final previousRequests = mockEngine.prompts.length;

      await controller.search('meticulous', selectedTab: 0);
      expect(controller.selectedTab, 0);
      expect(controller.currentQuery, 'meticulous');
      expect(mockEngine.prompts, hasLength(previousRequests));

      const sentence = 'I will meet Alice tomorrow.';
      await controller.search(sentence, selectedTab: 1);
      expect(controller.selectedTab, 1);
      expect(mockEngine.prompts, hasLength(previousRequests + 1));
      expect(mockEngine.prompts.last, contains(sentence));
    });

    test('Study deletion clears the star and allows saving again', () async {
      await controller.toggleSaveToVocabulary();
      expect(controller.isSaved, isTrue);
      final first = await vocabularyRepo.getWord('resilient');
      await vocabularyRepo.deleteWord(first!.id);
      await waitForSavedState(controller, false);

      await controller.toggleSaveToVocabulary();
      expect(controller.isSaved, isTrue);
      expect(await vocabularyRepo.isWordSaved('resilient'), isTrue);
      await controller.toggleSaveToVocabulary();
      expect(controller.isSaved, isFalse);
      expect(await vocabularyRepo.isWordSaved('resilient'), isFalse);
    });

    test('A saved-state refresh cannot overwrite a later query', () async {
      final delayedRepo = DelayedVocabularyRepository();
      final otherController = DictionaryController(
        dictionaryRepo: dictionaryRepo,
        vocabularyRepo: delayedRepo,
        aiService: aiService,
      );
      addTearDown(otherController.dispose);
      await otherController.search('resilient');
      final pending = Completer<bool>();
      delayedRepo.nextSavedCheck = pending;
      await delayedRepo.saveWord(
        VocabularyWord(
          id: 'saved-elsewhere',
          word: 'resilient',
          definitionSnapshot: 'Able to recover',
          dateAdded: DateTime.now(),
        ),
      );
      await otherController.search('meticulous');
      pending.complete(true);
      await pumpEventQueue();
      expect(otherController.currentQuery, 'meticulous');
      expect(otherController.isSaved, isFalse);
    });

    for (final query in ['I will meet Alice tomorrow.', '明天见！']) {
      test('AI vocabulary preserves and removes "$query"', () async {
        await controller.search(query);
        controller.setSelectedTab(1);
        mockEngine.activeControllers.last.add('这是一个简明解释。');
        await mockEngine.activeControllers.last.close();
        await pumpEventQueue();

        await controller.toggleSaveToVocabulary();
        final saved = await vocabularyRepo.getWord(query);
        expect(saved?.word, query);
        expect(controller.isSaved, isTrue);
        expect(saved?.definitionSnapshot, contains('简明解释'));

        await controller.toggleSaveToVocabulary();
        expect(controller.isSaved, isFalse);
        expect(await vocabularyRepo.getWord(query), isNull);
      });
    }

    test('Typing a draft does not retarget displayed results; clearing resets them', () async {
      await controller.onQueryChanged('apple');
      expect(controller.currentQuery, 'resilient');
      expect(controller.currentEntry?.word, 'resilient');
      controller.setSelectedTab(1);
      await controller.onQueryChanged('');
      expect(controller.currentQuery, isEmpty);
      expect(controller.currentEntry, isNull);
      expect(controller.isAiGenerating, isFalse);
      expect(controller.isSaved, isFalse);
    });

    test(
      'Switching away from AI Answer cancels without leaving error text',
      () async {
        // 1. Switch to AI Answer Tab (Tab 1)
        controller.setSelectedTab(1);
        expect(controller.selectedTab, 1);
        expect(controller.isAiGenerating, isTrue);

        // Verify a stream was opened
        expect(mockEngine.activeControllers.isNotEmpty, isTrue);
        final stream1 = mockEngine.activeControllers.last;

        // Emit a partial chunk
        stream1.add('{"type": "word", "senses": [{"partOfSpeech": "adj."');
        await Future.delayed(const Duration(milliseconds: 20));
        expect(controller.aiRawStreamingText, contains('"type": "word"'));

        // 2. User switches to Tab 0 (Dictionary) while generation is running
        controller.setSelectedTab(0);
        expect(controller.selectedTab, 0);
        expect(controller.isAiGenerating, isFalse);

        await Future.delayed(const Duration(milliseconds: 20));

        // 3. Verify no error text poisoned the state
        expect(controller.aiErrorMessage, isNull);

        // 4. User returns to AI Answer Tab (Tab 1)
        controller.setSelectedTab(1);
        expect(controller.selectedTab, 1);
        expect(controller.isAiGenerating, isTrue);

        // Fresh stream started
        final stream2 = mockEngine.activeControllers.last;
        expect(stream2, isNot(same(stream1)));

        stream2.add(
          '{"type": "word", "senses": [{"partOfSpeech": "adj.", "meaning": "有弹性的；适应力强的"}]}',
        );
        await stream2.close();
        await Future.delayed(const Duration(milliseconds: 20));

        expect(controller.aiAnswer, isA<DictionaryWordAnswer>());
        final wordAnswer = controller.aiAnswer as DictionaryWordAnswer;
        expect(wordAnswer.senses.first.partOfSpeech, 'adj.');
        expect(wordAnswer.senses.first.meaning, contains('适应力强'));
        expect(controller.isAiGenerating, isFalse);
      },
    );

    test(
      'Structured phrase answer parses correctly and stores in vocabulary',
      () async {
        await controller.search('take it for granted');
        controller.setSelectedTab(1);

        final stream = mockEngine.activeControllers.last;
        stream.add(
          '{"type": "phrase", "explanation": "表示“认为某事理所当然”，通常用于描述没有意识到某事物价值的情况。"}',
        );
        await stream.close();
        await pumpEventQueue();

        expect(controller.aiAnswer, isA<DictionaryPhraseAnswer>());
        final phraseAnswer = controller.aiAnswer as DictionaryPhraseAnswer;
        expect(phraseAnswer.explanation, contains('理所当然'));

        // Test vocabulary saving with phrase answer
        await controller.toggleSaveToVocabulary();
        expect(controller.isSaved, isTrue);
        final saved = await vocabularyRepo.getWord('take it for granted');
        expect(saved, isNotNull);
        expect(saved!.definitionSnapshot, contains('理所当然'));
        expect(saved.translationSnapshot, contains('理所当然'));
      },
    );

    test('Stale chunk protection: old stream emitting after tab change does not pollute state', () async {
      final customEngine = ControllableAiEngine();
      final customAiService = AiService(llm: customEngine);

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

      // Active state on Tab 0 must not contain the rogue chunk
      expect(customDictController.aiRawStreamingText, isEmpty);
      expect(customDictController.aiAnswer, isNull);

      customDictController.dispose();
      customAiService.dispose();
    });

    test(
      'True generation failure surfaces informative error message',
      () async {
        mockEngine.shouldThrowOnStart = true;
        mockEngine.errorMessage = 'Out of memory native llama.cpp';

        controller.setSelectedTab(1);
        await Future.delayed(const Duration(milliseconds: 30));

        expect(controller.aiErrorMessage, contains('AI Answer unavailable'));
        expect(controller.aiErrorMessage, contains('Out of memory'));
        expect(controller.isAiGenerating, isFalse);
      },
    );
  });
}
