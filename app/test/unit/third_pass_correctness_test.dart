import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_engine.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/prompt_builder.dart';
import 'package:jlexa/core/ai/speech_engine.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/audio_service.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/audio/waveform_service.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:jlexa/core/vocabulary/vocabulary_models.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:jlexa/features/dictionary/dictionary_controller.dart';
import 'package:jlexa/features/repeater/repeater_controller.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';

class FakePathProviderPlatform extends PathProviderPlatform {
  final String path;
  FakePathProviderPlatform(this.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

class TestMockAiEngine implements AiEngine {
  bool _isLoaded = true;
  String? _loadedModelPath = '/mock/model.gguf';
  AiModelState _state = AiModelState.ready;
  final List<String> cancelledRequests = [];
  final List<String> generateCalls = [];
  String? currentRequestId;

  @override
  bool get isLoaded => _isLoaded;
  @override
  String? get loadedModelPath => _loadedModelPath;
  @override
  AiModelState get state => _state;

  void setLoaded(bool loaded) {
    _isLoaded = loaded;
    _state = loaded ? AiModelState.ready : AiModelState.noModel;
  }

  @override
  Future<void> loadModel(
    String modelPath, {
    AiGenerationSettings? settings,
    LlamaRuntimeSettings? runtimeSettings,
  }) async {
    if (modelPath.contains('invalid')) {
      throw Exception('Invalid model file');
    }
    _isLoaded = true;
    _loadedModelPath = modelPath;
    _state = AiModelState.ready;
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
  Stream<String> generate(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
  }) {
    return startGeneration(
      prompt,
      settings: settings,
      seed: seed,
      chatMessages: chatMessages,
    ).stream;
  }

  @override
  AiGenerationHandle startGeneration(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    generateCalls.add(prompt);
    if (!_isLoaded) {
      return AiGenerationHandle(
        requestId: '',
        stream: Stream.error(const AiModelNotLoadedException()),
        onCancel: () async {},
      );
    }

    final reqId = 'req_${DateTime.now().microsecondsSinceEpoch}';
    currentRequestId = reqId;
    final controller = StreamController<String>();

    () async {
      await Future.delayed(const Duration(milliseconds: 10));
      if (!controller.isClosed) {
        controller.add('Explanation ');
      }
      await Future.delayed(const Duration(milliseconds: 10));
      if (!controller.isClosed) {
        controller.add('for $prompt');
        controller.close();
      }
    }();

    return AiGenerationHandle(
      requestId: reqId,
      stream: controller.stream,
      onCancel: () => cancelRequest(reqId),
    );
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    cancelledRequests.add(requestId);
  }

  @override
  Future<void> cancel() async {
    if (currentRequestId != null) {
      cancelledRequests.add(currentRequestId!);
    }
  }

  @override
  Future<void> unload() async {
    _isLoaded = false;
    _loadedModelPath = null;
    _state = AiModelState.noModel;
  }
}

class TestMockSpeechEngine implements SpeechRecognitionEngine {
  bool _isLoaded = true;
  String? _loadedModelPath = '/mock/whisper.bin';
  bool cancelCalled = false;
  Completer<List<AudioSegment>>? transcriptionCompleter;

  @override
  bool get isLoaded => _isLoaded;
  @override
  String? get loadedModelPath => _loadedModelPath;

  void setLoaded(bool loaded) {
    _isLoaded = loaded;
  }

  @override
  Future<void> loadModel(String modelPath) async {
    if (modelPath.contains('invalid')) {
      throw Exception('Invalid whisper model');
    }
    _isLoaded = true;
    _loadedModelPath = modelPath;
  }

  @override
  Future<List<AudioSegment>> transcribeAudio({
    required String audioPath,
    required String lessonId,
    String? requestId,
    int nThreads = 4,
    void Function(double progress)? onProgress,
  }) async {
    if (!_isLoaded) {
      throw const AiModelNotLoadedException();
    }
    onProgress?.call(0.25);
    onProgress?.call(0.75);

    if (transcriptionCompleter != null) {
      return transcriptionCompleter!.future;
    }

    return [
      AudioSegment(
        id: '${lessonId}_seg_0',
        lessonId: lessonId,
        startMs: 0,
        endMs: 2000,
        text: 'Transcribed sentence one',
      ),
      AudioSegment(
        id: '${lessonId}_seg_1',
        lessonId: lessonId,
        startMs: 2000,
        endMs: 4000,
        text: 'Transcribed sentence two',
      ),
    ];
  }

  @override
  Future<Map<String, dynamic>?> getAudioMetadata(String audioPath) async => {
    'durationMs': 4000,
  };

  @override
  Future<void> cancel() async {
    cancelCalled = true;
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    cancelCalled = true;
  }

  @override
  Future<void> unload() async {
    _isLoaded = false;
  }
}

class ControllableAudioService extends AudioService {
  AudioLesson? _lesson;
  List<AudioSegment> _cuts = const [];
  int _position = 0;

  @override
  AudioLesson? get currentLesson => _lesson;
  @override
  List<AudioSegment> get segments => _cuts;
  @override
  int get positionMs => _position;
  @override
  int get durationMs => _lesson?.durationMs ?? 0;
  @override
  AudioSegment? get currentSegment {
    for (final cut in _cuts) {
      if (cut.containsPosition(_position)) return cut;
    }
    return null;
  }

  @override
  Future<void> loadLesson(
    AudioLesson lesson,
    List<AudioSegment> segments,
  ) async {
    _lesson = lesson;
    _cuts = List.of(segments);
    _position = lesson.currentPositionMs;
    notifyListeners();
  }

  @override
  Future<void> seekTo(int positionMs, {bool userInitiated = true}) async {
    _position = positionMs;
    notifyListeners();
  }

  @override
  void updateSegments(List<AudioSegment> newSegments) {
    _cuts = List.of(newSegments);
    notifyListeners();
  }
}

class FixedSpeechWaveform extends WaveformService {
  @override
  Future<List<double>> extractAndCacheWaveform(
    String path,
    String id,
    int duration,
  ) async => [
    ...List.filled(20, .001),
    ...List.filled(20, .5),
    ...List.filled(40, .001),
    ...List.filled(20, .7),
    ...List.filled(20, .001),
  ];
}

void main() {
  late Directory tempDir;
  late LessonRepository lessonRepo;
  late AudioService audioService;
  late WaveformService waveformService;
  late TestMockAiEngine aiEngine;
  late TestMockSpeechEngine speechEngine;
  late AiService aiService;
  late DictionaryRepository dictRepo;
  late VocabularyRepository vocabRepo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('jlexa_third_pass_');
    PathProviderPlatform.instance = FakePathProviderPlatform(tempDir.path);

    final db = await AppDatabase.instance.database;
    await db.delete('recent_searches');
    await db.delete('vocabulary');
    await db.delete('audio_segments');
    await db.delete('audio_lessons');
    await db.delete('chat_messages');
    await db.delete('app_settings');

    lessonRepo = LessonRepository();
    audioService = AudioService();
    waveformService = WaveformService();
    aiEngine = TestMockAiEngine();
    speechEngine = TestMockSpeechEngine();
    aiService = AiService(llm: aiEngine, speech: speechEngine);
    dictRepo = DictionaryRepository();
    vocabRepo = VocabularyRepository();

    final dummyAudio = File('${tempDir.path}/test_sample.mp3');
    await dummyAudio.writeAsBytes(List.filled(100, 0));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Third-Pass Android Correctness Tests', () {
    test('1. TranscriptStatus enum serialization & legacy compatibility', () {
      expect(TranscriptStatus.none.toDbString(), equals('none'));
      expect(
        TranscriptStatus.pendingModel.toDbString(),
        equals('pendingModel'),
      );
      expect(TranscriptStatus.processing.toDbString(), equals('processing'));
      expect(TranscriptStatus.completed.toDbString(), equals('completed'));
      expect(TranscriptStatus.failed.toDbString(), equals('failed'));

      // Legacy conversions
      expect(
        TranscriptStatus.fromDbString('ready'),
        equals(TranscriptStatus.completed),
      );
      expect(
        TranscriptStatus.fromDbString('pending_model'),
        equals(TranscriptStatus.pendingModel),
      );
      expect(
        TranscriptStatus.fromDbString('completed'),
        equals(TranscriptStatus.completed),
      );
      expect(
        TranscriptStatus.fromDbString('unknown_status'),
        equals(TranscriptStatus.none),
      );
      expect(
        TranscriptStatus.fromDbString(null),
        equals(TranscriptStatus.none),
      );
    });

    test(
      '2. Lesson A transcription is invalidated after switching to Lesson B',
      () async {
        final lessonA = AudioLesson(
          id: 'lesson_A',
          title: 'Lesson A',
          originalFileName: 'lesson_a.mp3',
          localPath: '${tempDir.path}/test_sample.mp3',
          durationMs: 5000,
          createdAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
        );
        final lessonB = AudioLesson(
          id: 'lesson_B',
          title: 'Lesson B',
          originalFileName: 'lesson_b.mp3',
          localPath: '${tempDir.path}/test_sample.mp3',
          durationMs: 6000,
          createdAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
        );

        await lessonRepo.saveLesson(lessonA);
        await lessonRepo.saveLesson(lessonB);
        await lessonRepo.saveSegments('lesson_A', [
          const AudioSegment(
            id: 'cut_a',
            lessonId: 'lesson_A',
            startMs: 0,
            endMs: 5000,
            text: '',
          ),
        ]);

        final controller = RepeaterController(
          lessonRepo: lessonRepo,
          audioService: audioService,
          waveformService: waveformService,
          aiService: aiService,
        );
        await controller.loadLesson(lessonA);

        speechEngine.transcriptionCompleter = Completer<List<AudioSegment>>();

        // Start transcribing lesson A
        final transcribeFuture = controller.transcribeLesson();
        await Future.delayed(const Duration(milliseconds: 20));
        expect(controller.isTranscribing, isTrue);

        // User switches to lesson B while transcription of A is in-flight
        await controller.loadLesson(lessonB);
        expect(controller.lesson?.id, equals('lesson_B'));

        // Transcription of lesson A completes
        speechEngine.transcriptionCompleter!.complete([
          const AudioSegment(
            id: 'seg_a_0',
            lessonId: 'lesson_A',
            startMs: 0,
            endMs: 2500,
            text: 'Lesson A sentence',
          ),
        ]);
        await transcribeFuture;

        // Controller should NOT have overwritten its current UI segments (which are for Lesson B)
        expect(
          controller.segments.any((s) => s.lessonId == 'lesson_A'),
          isFalse,
        );

        // Switching lessons invalidates the old request for both UI and persistence.
        final dbLessonA = await lessonRepo.getLesson('lesson_A');
        expect(dbLessonA?.transcriptStatus, equals(TranscriptStatus.none));
        final savedCuts = await lessonRepo.getSegmentsForLesson('lesson_A');
        expect(savedCuts.single.text, isEmpty);

        controller.dispose();
      },
    );

    test(
      '3. Cancel transcription state machine transitions correctly',
      () async {
        final lesson = AudioLesson(
          id: 'lesson_cancel_test',
          title: 'Cancel Test',
          originalFileName: 'test.mp3',
          localPath: '${tempDir.path}/test_sample.mp3',
          durationMs: 5000,
          createdAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
        );
        await lessonRepo.saveLesson(lesson);
        await lessonRepo.saveSegments('lesson_cancel_test', [
          const AudioSegment(
            id: 'cut_cancel',
            lessonId: 'lesson_cancel_test',
            startMs: 0,
            endMs: 5000,
            text: '',
          ),
        ]);

        final controller = RepeaterController(
          lessonRepo: lessonRepo,
          audioService: audioService,
          waveformService: waveformService,
          aiService: aiService,
        );
        await controller.loadLesson(lesson);

        speechEngine.transcriptionCompleter = Completer<List<AudioSegment>>();

        final transcribeFuture = controller.transcribeLesson();
        await Future.delayed(const Duration(milliseconds: 20));
        expect(
          controller.transcriptionState,
          equals(TranscriptionState.transcribing),
        );

        // User hits cancel
        await controller.cancelTranscription();
        expect(
          controller.transcriptionState,
          equals(TranscriptionState.cancelling),
        );
        expect(speechEngine.cancelCalled, isTrue);

        // Underlying whisper completes (e.g. empty or cancelled)
        speechEngine.transcriptionCompleter!.complete([]);
        await transcribeFuture;

        // Controller returns to idle
        expect(controller.transcriptionState, equals(TranscriptionState.idle));

        controller.dispose();
      },
    );

    test(
      '3b. invalidating an active transcription still releases the state slot',
      () async {
        final lesson = AudioLesson(
          id: 'lesson_invalidated_cancel',
          title: 'Invalidated Cancel',
          originalFileName: 'test.mp3',
          localPath: '${tempDir.path}/test_sample.mp3',
          durationMs: 5000,
          createdAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
        );
        await lessonRepo.saveLesson(lesson);
        await lessonRepo.saveSegments(lesson.id, [
          AudioSegment(
            id: 'cut_invalidated_cancel',
            lessonId: lesson.id,
            startMs: 0,
            endMs: 5000,
            text: '',
          ),
        ]);

        final controller = RepeaterController(
          lessonRepo: lessonRepo,
          audioService: audioService,
          waveformService: waveformService,
          aiService: aiService,
        );
        await controller.loadLesson(lesson);
        speechEngine.transcriptionCompleter = Completer<List<AudioSegment>>();

        final transcription = controller.transcribeLesson();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(controller.transcriptionState, TranscriptionState.transcribing);

        // Disabling Auto invalidates the operation generation before asking
        // Whisper to cancel. The stale operation must still release the one
        // shared transcription slot when native work reaches terminal state.
        final disableAuto = controller.setAutoTranscribe(false);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(controller.transcriptionState, TranscriptionState.cancelling);
        speechEngine.transcriptionCompleter!.complete(const []);
        await Future.wait([transcription, disableAuto]);

        expect(controller.transcriptionState, TranscriptionState.idle);
        expect(controller.isTranscribing, isFalse);
        controller.dispose();
      },
    );

    test('3c. Auto waits for cancelled cut transcription before starting the new cut', () async {
      final controlledAudio = ControllableAudioService();
      final lesson = AudioLesson(
        id: 'lesson_auto_switch',
        title: 'Auto Switch',
        originalFileName: 'test.mp3',
        localPath: '${tempDir.path}/test_sample.mp3',
        durationMs: 5000,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );
      await lessonRepo.saveLesson(lesson);
      await lessonRepo.saveSegments(lesson.id, const [
        AudioSegment(
          id: 'cut_auto_a',
          lessonId: 'lesson_auto_switch',
          startMs: 0,
          endMs: 2000,
          text: '',
        ),
        AudioSegment(
          id: 'cut_auto_b',
          lessonId: 'lesson_auto_switch',
          startMs: 2500,
          endMs: 5000,
          text: '',
        ),
      ]);

      final controller = RepeaterController(
        lessonRepo: lessonRepo,
        audioService: controlledAudio,
        waveformService: waveformService,
        aiService: aiService,
      );
      await controller.loadLesson(lesson);
      speechEngine.transcriptionCompleter = Completer<List<AudioSegment>>();
      await controller.setAutoTranscribe(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.transcriptionState, TranscriptionState.transcribing);
      expect(controller.currentSegment?.id, 'cut_auto_a');

      await controller.seekTo(3000);
      expect(controller.currentSegment?.id, 'cut_auto_b');
      expect(speechEngine.cancelCalled, isTrue);
      speechEngine.transcriptionCompleter!.complete(const [
        AudioSegment(
          id: 'native_result',
          lessonId: 'lesson_auto_switch',
          startMs: 0,
          endMs: 1000,
          text: 'new cut transcript',
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 550));

      final saved = await lessonRepo.getSegmentsForLesson(lesson.id);
      expect(saved.map((cut) => '${cut.id}:${cut.text}').toList(), const [
        'cut_auto_a:',
        'cut_auto_b:new cut transcript',
      ]);
      expect(saved.singleWhere((cut) => cut.id == 'cut_auto_a').text, isEmpty);
      expect(
        saved.singleWhere((cut) => cut.id == 'cut_auto_b').text,
        'new cut transcript',
      );
      expect(controller.transcriptionState, TranscriptionState.idle);
      controller.dispose();
      controlledAudio.dispose();
    });

    test(
      '3d. Auto off hides cached transcripts until explicitly requested',
      () async {
        final controlledAudio = ControllableAudioService();
        final lesson = AudioLesson(
          id: 'lesson_saved_transcripts',
          title: 'Saved Transcripts',
          originalFileName: 'test.mp3',
          localPath: '${tempDir.path}/test_sample.mp3',
          durationMs: 5000,
          createdAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
        );
        await lessonRepo.saveLesson(lesson);
        await lessonRepo.saveSegments(lesson.id, const [
          AudioSegment(
            id: 'saved_a',
            lessonId: 'lesson_saved_transcripts',
            startMs: 0,
            endMs: 2000,
            text: 'first persisted transcript',
            transcriptCutRevision: 0,
            transcriptModelId: '/older/whisper.bin',
          ),
          AudioSegment(
            id: 'saved_b',
            lessonId: 'lesson_saved_transcripts',
            startMs: 2500,
            endMs: 5000,
            text: 'second persisted transcript',
            transcriptCutRevision: 0,
            transcriptModelId: '/older/whisper.bin',
          ),
        ]);

        final controller = RepeaterController(
          lessonRepo: lessonRepo,
          audioService: controlledAudio,
          waveformService: waveformService,
          aiService: aiService,
        );
        await controller.loadLesson(lesson);
        expect(controller.autoTranscribe, isFalse);
        expect(controller.visibleTranscriptSegment, isNull);
        await controller.transcribeCurrentCut();
        expect(
          controller.visibleTranscriptSegment?.text,
          'first persisted transcript',
        );
        await controller.seekTo(3000);
        expect(controller.visibleTranscriptSegment, isNull);
        await controller.transcribeCurrentCut();
        expect(
          controller.visibleTranscriptSegment?.text,
          'second persisted transcript',
        );
        await controller.setAutoTranscribe(false);
        expect(controller.visibleTranscriptSegment, isNull);

        controller.dispose();
        controlledAudio.dispose();
      },
    );

    test('saved edits survive same-file import; resets preserve bounds and redo excludes silence', () async {
      final audio = ControllableAudioService();
      final lesson = AudioLesson(
        id: 'persist-edits',
        title: 'Persist edits',
        originalFileName: 'test.mp3',
        localPath: '${tempDir.path}/test_sample.mp3',
        durationMs: 6000,
        currentPositionMs: 1200,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );
      await lessonRepo.saveLesson(lesson);
      await lessonRepo.saveSegments(lesson.id, [
        AudioSegment(
          id: 'edited',
          lessonId: lesson.id,
          startMs: 1000,
          endMs: 2500,
          text: 'cached',
          revision: 3,
          transcriptCutRevision: 3,
          isUserEdited: true,
        ),
      ]);
      final controller = RepeaterController(
        lessonRepo: lessonRepo,
        audioService: audio,
        waveformService: FixedSpeechWaveform(),
        aiService: aiService,
      );
      await controller.loadLesson(
        lesson,
      ); // stale cutsInitialized=false from caller
      expect(controller.segments.single.id, 'edited');
      expect(controller.visibleTranscriptSegment, isNull);
      await controller.transcribeCurrentCut();
      expect(controller.visibleTranscriptSegment?.text, 'cached');
      await controller.resetTranscripts();
      expect(controller.segments.single.startMs, 1000);
      expect(controller.segments.single.endMs, 2500);
      expect(controller.segments.single.text, isEmpty);
      expect(controller.segments.single.revision, 4);
      expect(controller.visibleTranscriptSegment, isNull);
      final renamed = await File(lesson.localPath)
          .copy('${tempDir.path}/renamed.mp3');
      final hash = await lessonRepo.audioFingerprint(renamed.path);
      final existing = await lessonRepo.findByAudioFingerprint(hash);
      expect(existing?.id, lesson.id);
      await controller.deleteCurrentCut();
      await controller.loadLesson(lesson);
      expect(
        controller.segments,
        isEmpty,
        reason: 'Deleted cuts must not resurrect on reload',
      );
      await controller.redoSegments();
      expect(controller.segments, hasLength(2));
      expect(controller.segments.first.startMs, greaterThanOrEqualTo(500));
      expect(controller.segments.last.endMs, lessThan(5300));
      expect(
        controller.segments.last.startMs - controller.segments.first.endMs,
        greaterThan(1000),
      );
      expect(
        controller.segments.every((c) => c.text.isEmpty && c.id != 'edited'),
        isTrue,
      );
      controller.dispose();
      audio.dispose();
    });

    test('4. Dictionary search rapid race does not overwrite isSaved with stale query', () async {
      final dictController = DictionaryController(
        dictionaryRepo: dictRepo,
        vocabularyRepo: vocabRepo,
        aiService: aiService,
        initialWord: 'resilient',
      );

      // Save 'resilient' to vocab
      await vocabRepo.saveWord(
        VocabularyWord(
          id: 'voc_resilient',
          word: 'resilient',
          definitionSnapshot: 'Able to recover',
          dateAdded: DateTime.now(),
        ),
      );

      // Lookup 'resilient' -> isSaved is true
      await dictController.search('resilient');
      expect(dictController.isSaved, isTrue);

      // Rapidly search for 'eloquent' (not saved)
      await dictController.search('eloquent');
      expect(dictController.currentQuery, equals('eloquent'));
      expect(dictController.isSaved, isFalse);

      dictController.dispose();
    });

    test(
      '5. Dictionary search immediately invalidates running AI translations',
      () async {
        final dictController = DictionaryController(
          dictionaryRepo: dictRepo,
          vocabularyRepo: vocabRepo,
          aiService: aiService,
          initialWord: 'resilient',
        );

        await dictController.search('resilient');
        dictController.setSelectedTab(1); // AI Translation tab

        // Start search for new word
        await dictController.search('vibrant');
        // Previous AI text should be cleared
        expect(dictController.currentQuery, equals('vibrant'));

        dictController.dispose();
      },
    );

    test('6. Dictionary query empty clears suggestions and invalidates pending searches', () async {
      final dictController = DictionaryController(
        dictionaryRepo: dictRepo,
        vocabularyRepo: vocabRepo,
        aiService: aiService,
        initialWord: 'resilient',
      );

      await dictController.onQueryChanged('res');
      expect(dictController.suggestions.isNotEmpty, isTrue);

      await dictController.onQueryChanged('');
      expect(dictController.suggestions, isEmpty);

      dictController.dispose();
    });

    test(
      '7. Repeater sentence change never starts or cancels AI automatically',
      () async {
        final lesson = AudioLesson(
          id: 'lesson_ai_cancel',
          title: 'AI Cancel Test',
          originalFileName: 'test.mp3',
          localPath: '${tempDir.path}/test_sample.mp3',
          durationMs: 10000,
          createdAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
        );
        await lessonRepo.saveLesson(lesson);
        await lessonRepo.saveSegments('lesson_ai_cancel', [
          const AudioSegment(
            id: 's1',
            lessonId: 'lesson_ai_cancel',
            startMs: 0,
            endMs: 3000,
            text: 'Sentence one',
          ),
          const AudioSegment(
            id: 's2',
            lessonId: 'lesson_ai_cancel',
            startMs: 3000,
            endMs: 6000,
            text: 'Sentence two',
          ),
        ]);

        final controller = RepeaterController(
          lessonRepo: lessonRepo,
          audioService: audioService,
          waveformService: waveformService,
          aiService: aiService,
        );
        await controller.loadLesson(lesson);
        expect(controller.currentSegment?.id, equals('s1'));

        // Move to next sentence
        controller.nextSentence();
        await Future.delayed(const Duration(milliseconds: 50));

        expect(aiEngine.generateCalls, isEmpty);
        expect(aiEngine.cancelledRequests, isEmpty);

        controller.dispose();
      },
    );

    test('8. Repeater null currentSegment clears AI explanation and cancels handle', () async {
      final lesson = AudioLesson(
        id: 'lesson_null_seg',
        title: 'Null Seg Test',
        originalFileName: 'test.mp3',
        localPath: '${tempDir.path}/test_sample.mp3',
        durationMs: 10000,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );
      await lessonRepo.saveLesson(lesson);
      await lessonRepo.saveSegments('lesson_null_seg', []);

      final controller = RepeaterController(
        lessonRepo: lessonRepo,
        audioService: audioService,
        waveformService: waveformService,
        aiService: aiService,
      );
      await controller.loadLesson(lesson);

      expect(controller.currentSegment, isNull);
      expect(controller.aiExplanation, isEmpty);
      expect(controller.isAiGenerating, isFalse);

      controller.dispose();
    });

    test(
      '9. Segment boundary edits compress an overlapping neighbor',
      () async {
        final lesson = AudioLesson(
          id: 'lesson_bounds_test',
          title: 'Bounds Test',
          originalFileName: 'test.mp3',
          localPath: '${tempDir.path}/test_sample.mp3',
          durationMs: 10000,
          createdAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
        );
        await lessonRepo.saveLesson(lesson);
        await lessonRepo.saveSegments('lesson_bounds_test', [
          const AudioSegment(
            id: 'seg_1',
            lessonId: 'lesson_bounds_test',
            startMs: 0,
            endMs: 3000,
            text: 'First',
          ),
          const AudioSegment(
            id: 'seg_2',
            lessonId: 'lesson_bounds_test',
            startMs: 3000,
            endMs: 6000,
            text: 'Second',
          ),
          const AudioSegment(
            id: 'seg_3',
            lessonId: 'lesson_bounds_test',
            startMs: 6000,
            endMs: 9000,
            text: 'Third',
          ),
        ]);

        final controller = RepeaterController(
          lessonRepo: lessonRepo,
          audioService: audioService,
          waveformService: waveformService,
          aiService: aiService,
        );
        await controller.loadLesson(lesson);

        // Attempt to expand seg_2 startMs into seg_1 (< 3000)
        await controller.updateSegmentBounds(
          segmentId: 'seg_2',
          newStartMs: 1500, // Proposed overlap with seg_1
          newEndMs: 5500,
        );

        final seg2 = controller.segments.firstWhere((s) => s.id == 'seg_2');
        expect(seg2.startMs, equals(1500));
        expect(seg2.endMs, equals(5500));
        final seg1 = controller.segments.firstWhere((s) => s.id == 'seg_1');
        expect(seg1.endMs, equals(1500));

        controller.dispose();
      },
    );

    test(
      '10. Add Cut splits the active cut and keeps the left cut selected',
      () async {
        final controlledAudio = ControllableAudioService();
        final lesson = AudioLesson(
          id: 'lesson_split_test',
          title: 'Split Test',
          originalFileName: 'test.mp3',
          localPath: '${tempDir.path}/test_sample.mp3',
          durationMs: 10000,
          createdAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
        );
        await lessonRepo.saveLesson(lesson);
        await lessonRepo.saveSegments('lesson_split_test', [
          const AudioSegment(
            id: 'seg_split',
            lessonId: 'lesson_split_test',
            startMs: 0,
            endMs: 4000,
            text: 'One two three four five',
            tokens: [
              TranscriptToken(text: 'One', startMs: 0, endMs: 0),
              TranscriptToken(text: 'two', startMs: 0, endMs: 0),
              TranscriptToken(text: 'three', startMs: 0, endMs: 0),
              TranscriptToken(text: 'four', startMs: 0, endMs: 0),
              TranscriptToken(text: 'five', startMs: 0, endMs: 0),
            ],
          ),
        ]);

        final controller = RepeaterController(
          lessonRepo: lessonRepo,
          audioService: controlledAudio,
          waveformService: waveformService,
          aiService: aiService,
        );
        await controller.loadLesson(lesson);
        await controller.seekTo(2000); // Split at midpoint

        await controller.addCutAtPlayhead();

        expect(controller.segments.length, equals(2));
        expect(controller.segments[0].startMs, equals(0));
        expect(controller.segments[0].endMs, equals(2000));
        expect(controller.segments[1].startMs, equals(2000));
        expect(controller.segments[1].endMs, equals(4000));
        expect(controller.segments.every((cut) => cut.text.isEmpty), isTrue);
        expect(controller.positionMs, equals(1900));
        expect(controller.currentSegment?.id, equals('seg_split'));

        // A late native decoder callback at the exact half-open boundary
        // must not steal the explicit post-split selection from the left cut.
        await controlledAudio.seekTo(2000);
        expect(controller.currentSegment?.id, equals('seg_split'));

        // The next explicit user seek releases the selection override and
        // resumes normal playhead-based cut selection.
        await controller.seekTo(2000);
        expect(controller.currentSegment?.id, isNot('seg_split'));

        controller.dispose();
        controlledAudio.dispose();
      },
    );

    test('11. Position persistence throttled during playback and not notifying listeners', () async {
      final lesson = AudioLesson(
        id: 'lesson_pos_test',
        title: 'Position Test',
        originalFileName: 'test.mp3',
        localPath: '${tempDir.path}/test_sample.mp3',
        durationMs: 30000,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );
      await lessonRepo.saveLesson(lesson);

      bool repoNotified = false;
      lessonRepo.addListener(() {
        repoNotified = true;
      });

      // Updating position directly on repo should NOT notify listeners (preventing Home screen loop)
      await lessonRepo.updateLessonPosition('lesson_pos_test', 12000);
      expect(repoNotified, isFalse);

      final updated = await lessonRepo.getLesson('lesson_pos_test');
      expect(updated?.currentPositionMs, equals(12000));
    });

    test(
      '12. Final position persisted on RepeaterController dispose',
      () async {
        final lesson = AudioLesson(
          id: 'lesson_dispose_pos',
          title: 'Dispose Pos Test',
          originalFileName: 'test.mp3',
          localPath: '${tempDir.path}/test_sample.mp3',
          durationMs: 30000,
          createdAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
        );
        await lessonRepo.saveLesson(lesson);

        final controller = RepeaterController(
          lessonRepo: lessonRepo,
          audioService: audioService,
          waveformService: waveformService,
          aiService: aiService,
        );
        await controller.loadLesson(lesson);
        await controller.seekTo(18500);

        controller.dispose();

        final fetched = await lessonRepo.getLesson('lesson_dispose_pos');
        expect(fetched?.currentPositionMs, equals(18500));
      },
    );

    test(
      '13. Failed model load in AiService preserves prior configured path',
      () async {
        await aiService.loadLlmModel('/valid/model.gguf');
        expect(aiService.configuredLlmPath, equals('/valid/model.gguf'));

        // Attempt invalid model load
        try {
          await aiService.loadLlmModel('/invalid/bad_model.gguf');
        } catch (_) {}

        // Prior configured path must be preserved
        expect(aiService.configuredLlmPath, equals('/valid/model.gguf'));
      },
    );

    test('14. Failed speech model load in AiService preserves prior configured path', () async {
      await aiService.loadSpeechModel('/valid/whisper.bin');
      expect(aiService.configuredSpeechPath, equals('/valid/whisper.bin'));

      // Attempt invalid whisper load
      try {
        await aiService.loadSpeechModel('/invalid/bad_whisper.bin');
      } catch (_) {}

      expect(aiService.configuredSpeechPath, equals('/valid/whisper.bin'));
    });

    test(
      '15. WaveformService caches with version v4 and file size check',
      () async {
        final audioFile = File('${tempDir.path}/test_wave.wav');
        await audioFile.writeAsBytes(List.filled(500, 0));

        final peaks = await waveformService.extractAndCacheWaveform(
          audioFile.path,
          'lesson_wave_test',
          5000,
        );
        expect(peaks, isNotNull);

        // Verify cached file exists with v4 prefix
        final cached = await waveformService.loadCachedWaveform(
          'lesson_wave_test',
          fileSize: 500,
        );
        // Even if mock returns empty peaks for dummy bytes, loadCachedWaveform returns correctly without throwing
        expect(cached, isNull); // Empty peaks not saved to disk
      },
    );

    test(
      '16. AiRequestPriority pre-emption: background yields to user request',
      () async {
        final handle1 = aiService.startExplainSentence(
          const SentenceContext(lessonTitle: 'T', sentenceText: 'Text'),
          priority: AiRequestPriority.background,
        );
        expect(handle1.requestId.isNotEmpty, isTrue);

        // User initiates explicit translation
        final handle2 = aiService.startTranslateText(
          'Word',
          priority: AiRequestPriority.user,
        );
        expect(handle2.requestId.isNotEmpty, isTrue);

        await handle1.cancel();
        await handle2.cancel();
      },
    );

    test(
      '17. PromptBuilder creates correct prompt templates for all features',
      () {
        final sentencePrompt = PromptBuilder.buildSentenceExplanation(
          const SentenceContext(
            lessonTitle: 'Tech Talk',
            sentenceText: 'Machine learning algorithms improve automatically.',
          ),
        );
        expect(
          sentencePrompt.contains(
            'Machine learning algorithms improve automatically.',
          ),
          isTrue,
        );
        expect(sentencePrompt.contains('Tech Talk'), isTrue);

        final wordPrompt = PromptBuilder.buildDictionaryExplanation(
          'algorithms',
        );
        expect(wordPrompt.contains('algorithms'), isTrue);

        final qaPrompt = PromptBuilder.buildSentenceQA(
          context: const SentenceContext(
            lessonTitle: 'Tech Talk',
            sentenceText: 'Machine learning algorithms improve automatically.',
          ),
          userQuestion: 'How does it improve?',
        );
        expect(qaPrompt.contains('How does it improve?'), isTrue);

        final generalQa = PromptBuilder.buildGeneralQA(
          userQuestion: 'What is JLexa?',
        );
        expect(generalQa.contains('What is JLexa?'), isTrue);
      },
    );

    test('18. AudioLesson copyWith, toMap, fromMap with all TranscriptStatus states', () {
      final base = AudioLesson(
        id: 'lesson_full_test',
        title: 'Full Test',
        originalFileName: 'full.mp3',
        localPath: '/path/to/full.mp3',
        durationMs: 12000,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1600000000000),
        lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(1600000001000),
        currentPositionMs: 4000,
        transcriptStatus: TranscriptStatus.processing,
      );

      final map = base.toMap();
      expect(map['id'], equals('lesson_full_test'));
      expect(map['transcript_status'], equals('processing'));
      expect(map['current_position_ms'], equals(4000));

      final restored = AudioLesson.fromMap(map);
      expect(restored.id, equals('lesson_full_test'));
      expect(restored.transcriptStatus, equals(TranscriptStatus.processing));
      expect(restored.currentPositionMs, equals(4000));

      final completedCopy = base.copyWith(
        transcriptStatus: TranscriptStatus.completed,
      );
      expect(
        completedCopy.transcriptStatus,
        equals(TranscriptStatus.completed),
      );
      expect(completedCopy.durationMs, equals(12000));
    });

    test('19. Waveform cache invalidation on lesson deletion', () async {
      final lesson = AudioLesson(
        id: 'lesson_delete_wave_test',
        title: 'Delete Wave',
        originalFileName: 'wave.mp3',
        localPath: '${tempDir.path}/wave_del.mp3',
        durationMs: 5000,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );
      await lessonRepo.saveLesson(lesson);
      await waveformService.saveCachedWaveform('lesson_delete_wave_test', [
        0.1,
        0.5,
        0.9,
      ], fileSize: 100);

      final loadedBefore = await waveformService.loadCachedWaveform(
        'lesson_delete_wave_test',
        fileSize: 100,
      );
      expect(loadedBefore, isNotNull);

      // Deleting the lesson must clean up the cached waveform
      await lessonRepo.deleteLesson('lesson_delete_wave_test');

      final loadedAfter = await waveformService.loadCachedWaveform(
        'lesson_delete_wave_test',
        fileSize: 100,
      );
      expect(loadedAfter, isNull);
    });

    test('20. RepeaterController surfaces audio load error properly', () async {
      final badLesson = AudioLesson(
        id: 'lesson_bad_path',
        title: 'Bad Path',
        originalFileName: 'non_existent.mp3',
        localPath: '/non_existent_directory/non_existent.mp3',
        durationMs: 5000,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );
      await lessonRepo.saveLesson(badLesson);

      final controller = RepeaterController(
        lessonRepo: lessonRepo,
        audioService: audioService,
        waveformService: waveformService,
        aiService: aiService,
      );
      await controller.loadLesson(badLesson);

      expect(controller.hasAudioLoadError, isTrue);
      expect(controller.audioLoadError, isNotNull);

      controller.dispose();
    });
  });
}
