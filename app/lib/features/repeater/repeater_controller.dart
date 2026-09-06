import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_service.dart';
import '../../core/ai/native_ai_bridge.dart';
import '../../core/ai/prompt_builder.dart';
import '../../core/audio/audio_models.dart';
import '../../core/audio/audio_service.dart';
import '../../core/audio/cut_editor.dart';
import '../../core/audio/lesson_repository.dart';
import '../../core/audio/snap_to_speech.dart';
import '../../core/audio/waveform_service.dart';

class RepeaterController extends ChangeNotifier {
  final LessonRepository lessonRepo;
  final AudioService audioService;
  final WaveformService waveformService;
  final AiService aiService;
  final ISnapToSpeechService snapToSpeechService =
      AmplitudeSnapToSpeechService();
  final _uuid = const Uuid();

  AudioLesson? _lesson;
  List<AudioSegment> _segments = [];
  List<double> _fullWaveformPeaks = [];
  bool _snapToSpeechEnabled = true;
  bool _isAiCardExpanded = true;
  String _aiExplanation = '';
  bool _isAiGenerating = false;
  bool _isLoading = false;
  bool _isWaveformLoading = false;
  bool _autoTranscribe = false;
  String? _visibleTranscriptCutId;
  Timer? _autoTranscribeDebounce;
  String? _notice;

  TranscriptionState _transcriptionState = TranscriptionState.idle;
  double _transcriptionProgress = 0.0;
  String? _transcriptionError;
  int _transcriptionGeneration = 0;
  String? _activeTranscriptionRequestId;
  String? _transcribingLessonId;
  Completer<void>? _transcriptionCompleter;

  int _loadGeneration = 0;
  String? _activeSegmentId;
  String? _selectedSegmentId;
  int _aiExplanationGeneration = 0;
  int _lastPersistedPositionMs = -1;
  DateTime _lastPersistTime = DateTime.fromMillisecondsSinceEpoch(0);
  bool _durationPersisted = false;

  // Item 18: Surface audio load errors
  String? _audioLoadError;

  AudioLesson? get lesson => _lesson;
  List<AudioSegment> get segments => _segments;
  List<double> get fullWaveformPeaks => _fullWaveformPeaks;
  bool get snapToSpeechEnabled => _snapToSpeechEnabled;
  bool get isAiCardExpanded => _isAiCardExpanded;
  String get aiExplanation => _aiExplanation;
  bool get isAiGenerating => _isAiGenerating;
  bool get isLoading => _isLoading;
  bool get isWaveformLoading => _isWaveformLoading;
  bool get autoTranscribe => _autoTranscribe;
  String? get notice => _notice;
  bool get isWhisperBusyElsewhere =>
      _transcribingLessonId != null && _transcribingLessonId != _lesson?.id;
  TranscriptionState get transcriptionState =>
      (_lesson?.id == _transcribingLessonId)
      ? _transcriptionState
      : TranscriptionState.idle;
  bool get isTranscribing =>
      (_lesson?.id == _transcribingLessonId) &&
      _transcriptionState == TranscriptionState.transcribing;
  double get transcriptionProgress =>
      (_lesson?.id == _transcribingLessonId) ? _transcriptionProgress : 0.0;
  String? get transcriptionError => _transcriptionError;
  String? get audioLoadError => _audioLoadError;
  bool get hasAudioLoadError => _audioLoadError != null;

  int get positionMs => (audioService.currentLesson?.id == _lesson?.id)
      ? audioService.positionMs
      : (_lesson?.currentPositionMs ?? 0);
  int get durationMs =>
      (audioService.currentLesson?.id == _lesson?.id &&
          audioService.durationMs > 0)
      ? audioService.durationMs
      : (_lesson?.durationMs ?? 0);
  bool get isPlaying =>
      (audioService.currentLesson?.id == _lesson?.id) && audioService.isPlaying;
  bool get isRepeatOne =>
      (audioService.currentLesson?.id == _lesson?.id) &&
      audioService.isRepeatOne;
  AudioSegment? get currentSegment {
    if (audioService.currentLesson?.id != _lesson?.id) return null;
    if (_selectedSegmentId != null) {
      for (final cut in _segments) {
        if (cut.id == _selectedSegmentId) return cut;
      }
    }
    return audioService.currentSegment;
  }

  AudioSegment? get visibleTranscriptSegment {
    final cut = currentSegment;
    return cut != null &&
            cut.id == _visibleTranscriptCutId &&
            cut.hasValidTranscript
        ? cut
        : null;
  }

  bool get canAddCut => _lesson != null;
  bool get canDeleteCut => currentSegment != null;

  RepeaterController({
    required this.lessonRepo,
    required this.audioService,
    required this.waveformService,
    required this.aiService,
    AudioLesson? initialLesson,
  }) {
    audioService.addListener(_onAudioServiceUpdate);
    _loadAutoPreference();
    if (initialLesson != null) {
      loadLesson(initialLesson);
    }
  }

  Future<void> _loadAutoPreference() async {
    _autoTranscribe =
        (await lessonRepo.getSetting('repeater_auto_transcribe')) == 'true';
    if (!_isDisposed) notifyListeners();
  }

  void _onAudioServiceUpdate() {
    if (_lesson == null || audioService.currentLesson?.id != _lesson?.id) {
      return;
    }
    _checkPersistPosition();
    _checkPersistDuration();
    if (audioService.isPlaying) _selectedSegmentId = null;
    final newSegId = currentSegment?.id;
    if (newSegId != _activeSegmentId) {
      debugPrint(
        '[JLexaWhisper] active cut changed from=$_activeSegmentId to=$newSegId '
        'state=$_transcriptionState generation=$_transcriptionGeneration',
      );
      _activeSegmentId = newSegId;
      _invalidateExplanation();
      final switchGeneration = ++_transcriptionGeneration;
      final pendingTranscription = _transcriptionCompleter?.future;
      unawaited(cancelTranscription());
      _autoTranscribeDebounce?.cancel();
      final cut = currentSegment;
      _visibleTranscriptCutId = cut?.hasValidTranscript == true
          ? cut!.id
          : null;
      if (_autoTranscribe && cut != null) {
        if (cut.hasValidTranscript &&
            cut.transcriptModelId == aiService.speechEngine.loadedModelPath) {
          _visibleTranscriptCutId = cut.id;
        } else {
          unawaited(
            _queueAutoTranscriptionAfterCancellation(
              cutId: cut.id,
              cutRevision: cut.revision,
              switchGeneration: switchGeneration,
              pendingTranscription: pendingTranscription,
            ),
          );
        }
      }
    }
    notifyListeners();
  }

  Future<void> _queueAutoTranscriptionAfterCancellation({
    required String cutId,
    required int cutRevision,
    required int switchGeneration,
    required Future<void>? pendingTranscription,
  }) async {
    if (pendingTranscription != null) {
      try {
        await pendingTranscription;
      } catch (_) {}
    }
    if (_isDisposed ||
        !_autoTranscribe ||
        switchGeneration != _transcriptionGeneration ||
        currentSegment?.id != cutId ||
        currentSegment?.revision != cutRevision) {
      return;
    }
    _autoTranscribeDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!_isDisposed &&
          _autoTranscribe &&
          switchGeneration == _transcriptionGeneration &&
          currentSegment?.id == cutId &&
          currentSegment?.revision == cutRevision &&
          _transcriptionState == TranscriptionState.idle) {
        unawaited(transcribeCurrentCut(automatic: true));
      }
    });
  }

  // Item 14: Simplified position persistence — throttle to every 5s during playback
  void _checkPersistPosition() {
    if (_lesson == null || audioService.currentLesson?.id != _lesson?.id) {
      return;
    }
    final now = DateTime.now();
    if (!audioService.isPlaying) {
      // Always persist on pause/stop
      _persistPositionNow();
    } else if (now.difference(_lastPersistTime).inSeconds >= 5) {
      _persistPositionNow();
    }
  }

  void _persistPositionNow() {
    if (_lesson == null ||
        _isDisposed ||
        audioService.currentLesson?.id != _lesson!.id) {
      return;
    }
    final currentPos = positionMs;
    if (currentPos == _lastPersistedPositionMs) return;
    _lastPersistedPositionMs = currentPos;
    _lastPersistTime = DateTime.now();
    lessonRepo.updateLessonPosition(_lesson!.id, currentPos);
  }

  // Item 17: Persist actual player-reported duration when metadata had zero/wrong value
  void _checkPersistDuration() {
    if (_lesson == null ||
        _durationPersisted ||
        audioService.currentLesson?.id != _lesson?.id) {
      return;
    }
    final playerDurationMs = audioService.durationMs;
    if (playerDurationMs > 0 &&
        (_lesson!.durationMs == 0 ||
            (_lesson!.durationMs - playerDurationMs).abs() > 1000)) {
      _durationPersisted = true;
      lessonRepo.updateLessonDuration(_lesson!.id, playerDurationMs);
      _lesson = _lesson!.copyWith(durationMs: playerDurationMs);
    }
  }

  Future<void> clearLesson() async {
    _loadGeneration++;
    _lesson = null;
    _segments = [];
    _fullWaveformPeaks = [];
    _activeSegmentId = null;
    _selectedSegmentId = null;
    _visibleTranscriptCutId = null;
    _transcriptionError = null;
    _audioLoadError = null;
    _durationPersisted = false;
    _lastPersistedPositionMs = -1;
    _isLoading = false;
    _isWaveformLoading = false;

    _activeAiHandle?.cancel();
    _activeAiHandle = null;
    _aiExplanation = '';
    _isAiGenerating = false;

    await audioService.clearLesson();
    notifyListeners();
  }

  // Non-blocking atomic lesson load
  Future<void> loadLesson(AudioLesson lesson) async {
    // 1. Persist previous lesson position before switching only if audio matched
    final oldLesson = _lesson;
    if (oldLesson != null && audioService.currentLesson?.id == oldLesson.id) {
      final currentPos = positionMs;
      if (currentPos != _lastPersistedPositionMs) {
        _lastPersistedPositionMs = currentPos;
        _lastPersistTime = DateTime.now();
        lessonRepo.updateLessonPosition(oldLesson.id, currentPos);
      }
    }

    final currentGen = ++_loadGeneration;
    _isLoading = true;
    _lesson = lesson;
    _segments = [];
    _fullWaveformPeaks = [];
    _activeSegmentId = null;
    _selectedSegmentId = null;
    _transcriptionError = null;
    _audioLoadError = null;
    _durationPersisted = false;
    _lastPersistedPositionMs = -1;

    // Cancel active AI explanation for old lesson
    _activeAiHandle?.cancel();
    _activeAiHandle = null;
    _aiExplanation = '';
    _isAiGenerating = false;

    notifyListeners();

    try {
      // Step 1: Load segments from DB
      final segs = await lessonRepo.getSegmentsForLesson(lesson.id);
      if (currentGen != _loadGeneration) return;
      _segments = segs;

      // Step 2: Load audio in AudioService
      try {
        await audioService.loadLesson(lesson, _segments);
      } catch (e) {
        _audioLoadError = 'Failed to load audio: $e';
      }
      if (currentGen != _loadGeneration) return;

      // Step 3: Show the lesson UI immediately
      _activeSegmentId = audioService.currentSegment?.id;
      final activeCut = audioService.currentSegment;
      _visibleTranscriptCutId = activeCut?.hasValidTranscript == true
          ? activeCut!.id
          : null;
      _isLoading = false;
      notifyListeners();

      // Step 4: Load waveform asynchronously
      _isWaveformLoading = true;
      notifyListeners();

      try {
        final peaks = await waveformService.extractAndCacheWaveform(
          lesson.localPath,
          lesson.id,
          lesson.durationMs,
        );
        if (currentGen != _loadGeneration) return;
        _fullWaveformPeaks = peaks;
      } catch (_) {}

      _isWaveformLoading = false;
      if (!_lesson!.cutsInitialized &&
          _segments.isEmpty &&
          _fullWaveformPeaks.isNotEmpty) {
        await _initializeCutsFromDetectedSpeech(currentGen);
      }
    } catch (_) {
      _isLoading = false;
    }

    if (currentGen == _loadGeneration) {
      _isLoading = false;
      _isWaveformLoading = false;
      notifyListeners();
    }
  }

  Future<void> transcribeCurrentCut({bool automatic = false}) async {
    final cut = currentSegment;
    if (_lesson == null || cut == null) {
      _transcriptionError = 'Move the playhead into a cut before transcribing.';
      notifyListeners();
      return;
    }
    if (!aiService.speechEngine.isLoaded) {
      _transcriptionError =
          'Whisper speech model not loaded. Please select a model in Settings.';
      notifyListeners();
      return;
    }
    if (_transcriptionState != TranscriptionState.idle) {
      if (isWhisperBusyElsewhere) {
        _transcriptionError = 'Whisper is busy transcribing another lesson.';
        notifyListeners();
      }
      return;
    }

    // Capture immutable operation identity. Only this cut/revision/model may
    // consume the result.
    final targetLesson = _lesson!;
    final targetLessonId = targetLesson.id;
    final targetAudioPath = targetLesson.localPath;
    final targetCutId = cut.id;
    final targetRevision = cut.revision;
    final targetStartMs = cut.startMs;
    final targetEndMs = cut.endMs;
    final targetModelId = aiService.speechEngine.loadedModelPath ?? '';
    final operationId = ++_transcriptionGeneration;
    debugPrint(
      '[JLexaWhisper] transcription start cut=$targetCutId '
      'revision=$targetRevision generation=$operationId automatic=$automatic',
    );
    final reqId = const Uuid().v4();
    _activeTranscriptionRequestId = reqId;
    _transcribingLessonId = targetLessonId;
    final completer = Completer<void>();
    _transcriptionCompleter = completer;

    _transcriptionState = TranscriptionState.transcribing;
    _transcriptionProgress = 0.0;
    _transcriptionError = null;
    notifyListeners();

    try {
      void onProgress(double p) {
        if (operationId != _transcriptionGeneration) return;
        _transcriptionProgress = p;
        notifyListeners();
      }

      final engine = aiService.speechEngine;
      final recognized = engine is NativeWhisperEngine
          ? await engine.transcribeCut(
              audioPath: targetAudioPath,
              lessonId: targetLessonId,
              cutId: targetCutId,
              cutRevision: targetRevision,
              startMs: targetStartMs,
              endMs: targetEndMs,
              modelId: targetModelId,
              requestId: reqId,
              nThreads: aiService.settings.threads,
              onProgress: onProgress,
            )
          : await engine.transcribeAudio(
              audioPath: targetAudioPath,
              lessonId: targetLessonId,
              requestId: reqId,
              nThreads: aiService.settings.threads,
              onProgress: onProgress,
            );

      // If cancelled while transcribeAudio was finishing, reject result
      if (_transcriptionState == TranscriptionState.cancelling) {
        throw const AiCancelledException();
      }

      // A cut/lesson switch invalidates the operation even when the native
      // engine races cancellation and returns a plausible final result.
      // Never persist that stale text into the cut it was started for.
      if (operationId != _transcriptionGeneration ||
          _lesson?.id != targetLessonId) {
        debugPrint(
          '[JLexaWhisper] rejected stale result cut=$targetCutId '
          'operation=$operationId current=$_transcriptionGeneration',
        );
        return;
      }

      final currentIndex = _segments.indexWhere(
        (s) => s.id == targetCutId && s.revision == targetRevision,
      );
      if (currentIndex < 0) return;
      final combinedText = recognized.map((s) => s.text).join().trim();
      final combinedTokens = recognized.expand((s) => s.tokens).toList();
      final validConfidences = combinedTokens
          .map((t) => t.confidence)
          .where((c) => c >= 0 && c <= 1)
          .toList();
      final confidence = validConfidences.isEmpty
          ? -1.0
          : validConfidences.reduce((a, b) => a + b) / validConfidences.length;
      final updated = _segments[currentIndex].copyWith(
        text: combinedText,
        tokens: combinedTokens,
        confidence: confidence,
        transcriptCutRevision: targetRevision,
        transcriptModelId: targetModelId,
      );
      await lessonRepo.updateSegment(updated);

      if (operationId == _transcriptionGeneration &&
          _lesson?.id == targetLessonId &&
          currentSegment?.id == targetCutId &&
          currentSegment?.revision == targetRevision) {
        _segments[currentIndex] = updated;
        audioService.updateSegments(_segments);
        _visibleTranscriptCutId = targetCutId;
        _transcriptionError = combinedText.isEmpty
            ? 'No speech was recognized in this cut.'
            : null;
      }
    } catch (e) {
      if (e is AiCancelledException ||
          e.toString().contains('cancel') ||
          _transcriptionState == TranscriptionState.cancelling) {
        if (operationId == _transcriptionGeneration &&
            _lesson?.id == targetLessonId) {
          _transcriptionError = null;
        }
      } else if (e is PlatformException &&
              (e.code.toLowerCase() == 'busy' ||
                  e.message?.toLowerCase().contains('busy') == true) ||
          e is AiBusyException ||
          e.toString().toLowerCase().contains('busy')) {
        // BUSY is a retryable temporary state, NOT a transcription failure!
        if (operationId == _transcriptionGeneration) {
          _transcriptionError = 'Whisper is busy finishing another transcription. Please try again.';
        }
      } else {
        if (operationId == _transcriptionGeneration) {
          _transcriptionError = e.toString();
        }
      }
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (_transcriptionCompleter == completer) {
        _transcriptionCompleter = null;
        _activeTranscriptionRequestId = null;
        _transcribingLessonId = null;
        _transcriptionState = TranscriptionState.idle;
        notifyListeners();
      }
    }
  }

  Future<void> _initializeCutsFromDetectedSpeech(int loadGeneration) async {
    final target = _lesson;
    if (target == null || target.cutsInitialized) return;
    final regions = waveformService.detectSpeechRegions(
      peaks: _fullWaveformPeaks,
      durationMs: durationMs,
    );
    final cuts = regions
        .map(
          (r) => AudioSegment(
            id: _uuid.v4(),
            lessonId: target.id,
            startMs: r.startMs,
            endMs: r.endMs,
            text: '',
            confidence: -1,
          ),
        )
        .toList();
    if (loadGeneration != _loadGeneration || _lesson?.id != target.id) return;
    await lessonRepo.commitCutSet(target.id, const {}, cuts);
    _lesson = target.copyWith(cutsInitialized: true);
    _segments = cuts;
    audioService.updateSegments(cuts);
  }

  Future<void> transcribeLesson() => transcribeCurrentCut();

  Future<void> cancelTranscription() async {
    if (_transcriptionState != TranscriptionState.transcribing) return;
    _transcriptionState = TranscriptionState.cancelling;
    notifyListeners();
    try {
      if (_activeTranscriptionRequestId != null) {
        await aiService.speechEngine.cancelRequest(
          _activeTranscriptionRequestId!,
        );
      } else {
        await aiService.speechEngine.cancel();
      }
    } catch (_) {}
  }

  Future<void> prepareLessonDeletion(String lessonId) async {
    // 1. If this lesson is currently transcribing, cancel and await transcription terminal completion
    if (_transcribingLessonId == lessonId) {
      final reqId = _activeTranscriptionRequestId;
      _transcriptionState = TranscriptionState.cancelling;
      notifyListeners();
      if (reqId != null) {
        try {
          await aiService.speechEngine.cancelRequest(reqId);
        } catch (_) {}
      } else {
        try {
          await aiService.speechEngine.cancel();
        } catch (_) {}
      }
      final comp = _transcriptionCompleter;
      if (comp != null && !comp.isCompleted) {
        try {
          await comp.future;
        } catch (_) {}
      }
    }

    // 2. If this lesson is currently active in Repeater/AudioService, clean it up
    if (_lesson?.id == lessonId) {
      await clearLesson();
    }
  }

  void toggleSnapToSpeech() {
    _snapToSpeechEnabled = !_snapToSpeechEnabled;
    notifyListeners();
  }

  void toggleAiCardExpanded() {
    _isAiCardExpanded = !_isAiCardExpanded;
    notifyListeners();
  }

  Future<void> setAutoTranscribe(bool value) async {
    _autoTranscribe = value;
    await lessonRepo.setSetting('repeater_auto_transcribe', value.toString());
    _autoTranscribeDebounce?.cancel();
    if (!value) {
      _transcriptionGeneration++;
      await cancelTranscription();
      final cut = currentSegment;
      _visibleTranscriptCutId = cut?.hasValidTranscript == true
          ? cut!.id
          : null;
    } else if (currentSegment != null) {
      final cut = currentSegment!;
      if (cut.hasValidTranscript &&
          cut.transcriptModelId == aiService.speechEngine.loadedModelPath) {
        _visibleTranscriptCutId = cut.id;
      } else {
        unawaited(transcribeCurrentCut(automatic: true));
      }
    }
    notifyListeners();
  }

  Future<void> seekTo(int targetMs) async {
    _selectedSegmentId = null;
    await audioService.seekTo(targetMs);
    _persistPositionNow();
    notifyListeners();
  }

  Future<void> beginWaveformSeek() {
    _selectedSegmentId = null;
    return audioService.beginScrub();
  }

  Future<void> endWaveformSeek() => audioService.endScrub();

  void togglePlayPause() {
    _selectedSegmentId = null;
    audioService.togglePlayPause();
    _persistPositionNow();
  }

  void toggleRepeatOne() => audioService.toggleRepeatOne();
  void previousSentence() {
    _selectedSegmentId = null;
    audioService.previousSentence();
  }

  void nextSentence() {
    _selectedSegmentId = null;
    audioService.nextSentence();
  }

  void repeatCurrentSentence() {
    _selectedSegmentId = null;
    audioService.repeatCurrentSentence();
  }

  // Item 12: Rewritten segment boundary algorithm — legal range first, then preferences
  Future<void> updateSegmentBounds({
    required String segmentId,
    required int newStartMs,
    required int newEndMs,
    int? expectedRevision,
  }) async {
    final index = _segments.indexWhere((s) => s.id == segmentId);
    if (index == -1) return;

    final totalDur = durationMs;
    if (totalDur <= 0) return;
    final original = _segments[index];
    if (expectedRevision != null && original.revision != expectedRevision) {
      return;
    }
    var finalStart = newStartMs.clamp(0, totalDur).toInt();
    var finalEnd = newEndMs.clamp(0, totalDur).toInt();

    // Snap only the side actually moved; the opposite boundary is immutable.
    if (_snapToSpeechEnabled) {
      if (newStartMs != original.startMs && newEndMs == original.endMs) {
        finalStart = snapToSpeechService
            .snapBoundary(
              proposedPositionMs: finalStart,
              waveformPeaks: _fullWaveformPeaks,
              totalDurationMs: totalDur,
            )
            .clamp(0, totalDur)
            .toInt();
      } else if (newEndMs != original.endMs && newStartMs == original.startMs) {
        finalEnd = snapToSpeechService
            .snapBoundary(
              proposedPositionMs: finalEnd,
              waveformPeaks: _fullWaveformPeaks,
              totalDurationMs: totalDur,
            )
            .clamp(0, totalDur)
            .toInt();
      }
    }
    if (finalStart >= finalEnd) return;
    final snapshot = [..._segments];
    final expected = {for (final c in snapshot) c.id: c.revision};
    final result = CutEditor.resize(
      snapshot: snapshot,
      cutId: segmentId,
      expectedRevision: expectedRevision ?? original.revision,
      newStartMs: finalStart,
      newEndMs: finalEnd,
      durationMs: totalDur,
    );
    _invalidateExplanation();
    _transcriptionGeneration++;
    _visibleTranscriptCutId = null;
    try {
      await lessonRepo.commitCutSet(_lesson!.id, expected, result.cuts);
      _segments = result.cuts;
      audioService.updateSegments(_segments);
    } catch (e) {
      _notice = 'Cut edit was not saved: $e';
    }
    notifyListeners();
  }

  Future<void> cutStartAtPlayhead() async {
    final seg = currentSegment;
    if (seg == null) return;
    if (positionMs < seg.endMs - 300) {
      await updateSegmentBounds(
        segmentId: seg.id,
        newStartMs: positionMs,
        newEndMs: seg.endMs,
      );
    }
  }

  Future<void> cutEndAtPlayhead() async {
    final seg = currentSegment;
    if (seg == null) return;
    if (positionMs > seg.startMs + 300) {
      await updateSegmentBounds(
        segmentId: seg.id,
        newStartMs: seg.startMs,
        newEndMs: positionMs,
      );
    }
  }

  Future<void> addCutAtPlayhead() async {
    if (_lesson == null) return;
    final targetLessonId = _lesson!.id;
    final targetPosition = positionMs;
    final snapshot = [..._segments];
    final expected = {for (final c in snapshot) c.id: c.revision};
    final activeCut = currentSegment;

    if (activeCut != null) {
      if (targetPosition <= activeCut.startMs ||
          targetPosition >= activeCut.endMs) {
        _notice = 'Move the playhead inside the cut before splitting it.';
        notifyListeners();
        return;
      }
      _transcriptionGeneration++;
      await cancelTranscription();
      _invalidateExplanation();
      try {
        final result = CutEditor.split(
          snapshot: snapshot,
          cutId: activeCut.id,
          expectedRevision: activeCut.revision,
          splitMs: targetPosition,
          rightCutId: _uuid.v4(),
          durationMs: durationMs,
        );
        await lessonRepo.commitCutSet(targetLessonId, expected, result.cuts);
        if (_lesson?.id != targetLessonId) return;
        _segments = result.cuts;
        _selectedSegmentId = activeCut.id;
        _visibleTranscriptCutId = null;
        _notice = null;
        // Intervals are half-open, so the exact split point belongs to the
        // right cut. Android audio decoders can quantize a 1 ms seek back to
        // the boundary, so select a point up to 100 ms inside the left cut
        // (or its midpoint when the left cut is very short).
        final leftDurationMs = targetPosition - activeCut.startMs;
        final selectionOffsetMs = min(100, max(1, leftDurationMs ~/ 2));
        await audioService.seekTo(targetPosition - selectionOffsetMs);
        audioService.updateSegments(_segments);
      } catch (e) {
        _notice = 'Cut split was not saved: $e';
      }
      notifyListeners();
      return;
    }

    final gap = CutEditor.gapAt(snapshot, targetPosition, durationMs);
    final regions = waveformService.detectSpeechRegions(
      peaks: _fullWaveformPeaks,
      durationMs: durationMs,
    );
    final region = regions.cast<SpeechRegion?>().firstWhere(
      (r) =>
          r != null &&
          r.startMs <= targetPosition &&
          targetPosition < r.endMs &&
          r.startMs < gap.endMs &&
          r.endMs > gap.startMs,
      orElse: () => null,
    );
    if (region == null) {
      _notice = 'No connected speech was detected at the playhead.';
      notifyListeners();
      return;
    }
    final newCut = AudioSegment(
      id: _uuid.v4(),
      lessonId: targetLessonId,
      startMs: max(gap.startMs, region.startMs),
      endMs: min(gap.endMs, region.endMs),
      text: '',
      confidence: -1,
      isUserEdited: true,
    );
    if (_lesson?.id != targetLessonId || currentSegment != null) return;
    final updated = [...snapshot, newCut]
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    await lessonRepo.commitCutSet(targetLessonId, expected, updated);
    _segments = updated;
    _selectedSegmentId = null;
    audioService.updateSegments(updated);
    notifyListeners();
  }

  Future<void> deleteCurrentCut() async {
    final cut = currentSegment;
    if (_lesson == null || cut == null) return;
    final snapshot = [..._segments];
    final expected = {for (final c in snapshot) c.id: c.revision};
    _transcriptionGeneration++;
    await cancelTranscription();
    _invalidateExplanation();
    final updated = snapshot.where((c) => c.id != cut.id).toList();
    await lessonRepo.commitCutSet(_lesson!.id, expected, updated);
    _segments = updated;
    _selectedSegmentId = null;
    _visibleTranscriptCutId = null;
    audioService.updateSegments(updated);
    notifyListeners();
  }

  Future<void> mergeWithNextSegment() async {
    final curIndex = audioService.currentSegmentIndex;
    if (curIndex < 0 || curIndex >= _segments.length - 1) return;

    final cur = _segments[curIndex];
    final next = _segments[curIndex + 1];

    final merged = cur.copyWith(
      endMs: next.endMs,
      text: '${cur.text} ${next.text}',
      isUserEdited: true,
      tokens: [...cur.tokens, ...next.tokens],
    );

    _segments[curIndex] = merged;
    _segments.removeAt(curIndex + 1);

    audioService.updateSegments(_segments);
    if (_lesson != null) {
      await lessonRepo.saveSegments(_lesson!.id, _segments);
    }
    notifyListeners();
  }

  SentenceContext getCurrentSentenceContext() {
    final cur = currentSegment;
    final curIndex = audioService.currentSegmentIndex;
    final prev = (curIndex > 0 && curIndex < _segments.length)
        ? _segments[curIndex - 1].text
        : null;
    final next = (curIndex >= 0 && curIndex < _segments.length - 1)
        ? _segments[curIndex + 1].text
        : null;

    final uncertain =
        cur?.tokens.where((t) => t.isUncertain).map((t) => t.text).toList() ??
        [];

    return SentenceContext(
      lessonTitle: _lesson?.title ?? 'Audio Lesson',
      sentenceText: cur?.text ?? '',
      previousSentence: prev,
      nextSentence: next,
      startMs: cur?.startMs ?? 0,
      endMs: cur?.endMs ?? 0,
      uncertainWords: uncertain,
    );
  }

  AiGenerationHandle? _activeAiHandle;

  void _invalidateExplanation() {
    _aiExplanationGeneration++;
    _activeAiHandle?.cancel();
    _activeAiHandle = null;
    _aiExplanation = '';
    _isAiGenerating = false;
  }

  void cancelExplanation() {
    _invalidateExplanation();
    notifyListeners();
  }

  /// Explanation generation has exactly one entry point: an explicit tap.
  Future<void> generateExplanation() async {
    final cur = currentSegment;
    if (cur == null || !cur.hasValidTranscript) {
      _aiExplanation = 'Transcribe this cut before generating an explanation.';
      notifyListeners();
      return;
    }

    final gen = ++_aiExplanationGeneration;
    _activeAiHandle?.cancel();
    _activeAiHandle = null;

    if (!aiService.llmEngine.isLoaded) {
      _aiExplanation =
          'Load a local AI model in Settings to generate explanations.';
      notifyListeners();
      return;
    }

    _isAiGenerating = true;
    _aiExplanation = '';
    notifyListeners();

    try {
      final context = getCurrentSentenceContext();
      final handle = aiService.startExplainSentence(
        context,
        priority: AiRequestPriority.user,
      );
      _activeAiHandle = handle;

      await for (final chunk in handle.stream) {
        if (gen != _aiExplanationGeneration || _isDisposed) break;
        _aiExplanation += chunk;
        notifyListeners();
      }
    } catch (e) {
      if (gen == _aiExplanationGeneration && !_isDisposed) {
        if (e is AiCancelledException) {
          _aiExplanation = '';
        } else if (e is AiBusyException) {
          _aiExplanation = 'AI is busy with another request. Explanation will be available shortly.';
        } else {
          _aiExplanation = 'Explanation unavailable: $e';
        }
      }
    } finally {
      if (gen == _aiExplanationGeneration && !_isDisposed) {
        _isAiGenerating = false;
        _activeAiHandle = null;
        notifyListeners();
      }
    }
  }

  bool _isDisposed = false;

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _aiExplanationGeneration++;
    _transcriptionGeneration++;
    _autoTranscribeDebounce?.cancel();
    _activeAiHandle?.cancel();
    // Item 15: Persist position BEFORE setting _isDisposed
    _persistPositionNow();
    _isDisposed = true;
    audioService.removeListener(_onAudioServiceUpdate);
    super.dispose();
  }
}
