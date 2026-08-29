import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_service.dart';
import '../../core/ai/prompt_builder.dart';
import '../../core/audio/audio_models.dart';
import '../../core/audio/audio_service.dart';
import '../../core/audio/lesson_repository.dart';
import '../../core/audio/snap_to_speech.dart';
import '../../core/audio/waveform_service.dart';

class RepeaterController extends ChangeNotifier {
  final LessonRepository lessonRepo;
  final AudioService audioService;
  final WaveformService waveformService;
  final AiService aiService;
  final ISnapToSpeechService snapToSpeechService = AmplitudeSnapToSpeechService();
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

  // Item 2: Transcription state machine
  TranscriptionState _transcriptionState = TranscriptionState.idle;
  double _transcriptionProgress = 0.0;
  String? _transcriptionError;
  int _transcriptionGeneration = 0;

  int _loadGeneration = 0;
  String? _activeSegmentId;
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
  TranscriptionState get transcriptionState => _transcriptionState;
  bool get isTranscribing => _transcriptionState == TranscriptionState.transcribing;
  double get transcriptionProgress => _transcriptionProgress;
  String? get transcriptionError => _transcriptionError;
  String? get audioLoadError => _audioLoadError;
  bool get hasAudioLoadError => _audioLoadError != null;

  int get positionMs => audioService.positionMs;
  int get durationMs => audioService.durationMs > 0 ? audioService.durationMs : (_lesson?.durationMs ?? 0);
  bool get isPlaying => audioService.isPlaying;
  bool get isRepeatOne => audioService.isRepeatOne;
  AudioSegment? get currentSegment => audioService.currentSegment;

  RepeaterController({
    required this.lessonRepo,
    required this.audioService,
    required this.waveformService,
    required this.aiService,
    AudioLesson? initialLesson,
  }) {
    audioService.addListener(_onAudioServiceUpdate);
    if (initialLesson != null) {
      loadLesson(initialLesson);
    }
  }

  void _onAudioServiceUpdate() {
    _checkPersistPosition();
    _checkPersistDuration();
    final newSegId = audioService.currentSegment?.id;
    if (newSegId != _activeSegmentId) {
      _activeSegmentId = newSegId;
      _fetchAiExplanation();
    }
    notifyListeners();
  }

  // Item 14: Simplified position persistence — throttle to every 5s during playback
  void _checkPersistPosition() {
    if (_lesson == null) return;
    final now = DateTime.now();
    if (!audioService.isPlaying) {
      // Always persist on pause/stop
      _persistPositionNow();
    } else if (now.difference(_lastPersistTime).inSeconds >= 5) {
      _persistPositionNow();
    }
  }

  void _persistPositionNow() {
    if (_lesson == null || _isDisposed) return;
    final currentPos = positionMs;
    if (currentPos == _lastPersistedPositionMs) return;
    _lastPersistedPositionMs = currentPos;
    _lastPersistTime = DateTime.now();
    lessonRepo.updateLessonPosition(_lesson!.id, currentPos);
  }

  // Item 17: Persist actual player-reported duration when metadata had zero/wrong value
  void _checkPersistDuration() {
    if (_lesson == null || _durationPersisted) return;
    final playerDurationMs = audioService.durationMs;
    if (playerDurationMs > 0 && (_lesson!.durationMs == 0 || (_lesson!.durationMs - playerDurationMs).abs() > 1000)) {
      _durationPersisted = true;
      lessonRepo.updateLessonDuration(_lesson!.id, playerDurationMs);
      _lesson = _lesson!.copyWith(durationMs: playerDurationMs);
    }
  }

  // Item 6: Non-blocking lesson load — audio plays before waveform is ready
  Future<void> loadLesson(AudioLesson lesson) async {
    final currentGen = ++_loadGeneration;
    _isLoading = true;
    _lesson = lesson;
    _activeSegmentId = null;
    _transcriptionError = null;
    _audioLoadError = null;
    _durationPersisted = false;
    notifyListeners();

    try {
      // Step 1: Load segments from DB
      final segs = await lessonRepo.getSegmentsForLesson(lesson.id);
      if (currentGen != _loadGeneration) return;
      _segments = segs;

      // Step 2: Load audio immediately so playback works
      try {
        await audioService.loadLesson(lesson, _segments);
      } catch (e) {
        // Item 18: Surface audio load errors instead of silently swallowing
        _audioLoadError = 'Failed to load audio: $e';
      }
      if (currentGen != _loadGeneration) return;

      // Step 3: Show the lesson UI immediately
      _activeSegmentId = audioService.currentSegment?.id;
      _isLoading = false;
      notifyListeners();

      // Step 4: Load waveform asynchronously (non-blocking)
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
      _fetchAiExplanation();
    } catch (_) {
      _isLoading = false;
    }

    if (currentGen == _loadGeneration) {
      _isLoading = false;
      _isWaveformLoading = false;
      notifyListeners();
    }
  }

  // Item 1: Transcription captures immutable operation data
  // Item 2: Proper state machine with cancelling state
  // Item 25: Uses TranscriptStatus enum
  Future<void> transcribeLesson() async {
    if (_lesson == null) return;
    if (!aiService.speechEngine.isLoaded) {
      _transcriptionError = 'Whisper speech model not loaded. Please select a model in Settings.';
      notifyListeners();
      return;
    }
    if (_transcriptionState != TranscriptionState.idle) return;

    // Capture immutable operation identity
    final targetLesson = _lesson!;
    final targetLessonId = targetLesson.id;
    final targetAudioPath = targetLesson.localPath;
    final operationId = ++_transcriptionGeneration;

    _transcriptionState = TranscriptionState.transcribing;
    _transcriptionProgress = 0.0;
    _transcriptionError = null;
    notifyListeners();

    try {
      await lessonRepo.updateTranscriptStatus(targetLessonId, TranscriptStatus.processing);

      final segments = await aiService.speechEngine.transcribeAudio(
        audioPath: targetAudioPath,
        lessonId: targetLessonId,
        nThreads: aiService.settings.threads,
        onProgress: (p) {
          if (operationId != _transcriptionGeneration) return;
          _transcriptionProgress = p;
          notifyListeners();
        },
      );

      // Always persist results to the CORRECT lesson, regardless of navigation
      await lessonRepo.saveSegments(targetLessonId, segments);
      await lessonRepo.updateTranscriptStatus(targetLessonId, TranscriptStatus.completed);

      // Only update in-memory state if we're still viewing the same lesson
      if (operationId == _transcriptionGeneration && _lesson?.id == targetLessonId) {
        _segments = segments;
        audioService.updateSegments(_segments);
        _lesson = _lesson!.copyWith(transcriptStatus: TranscriptStatus.completed);
        _activeSegmentId = audioService.currentSegment?.id;
        _fetchAiExplanation();
      }
    } catch (e) {
      if (operationId == _transcriptionGeneration) {
        _transcriptionError = e.toString();
      }
      // Mark as failed in DB for the target lesson
      try {
        await lessonRepo.updateTranscriptStatus(targetLessonId, TranscriptStatus.failed);
      } catch (_) {}
    } finally {
      if (operationId == _transcriptionGeneration) {
        _transcriptionState = TranscriptionState.idle;
        notifyListeners();
      }
    }
  }

  // Item 2: Cancel sets state to cancelling, becomes idle after Future finishes
  Future<void> cancelTranscription() async {
    if (_transcriptionState != TranscriptionState.transcribing) return;
    _transcriptionState = TranscriptionState.cancelling;
    notifyListeners();
    try {
      await aiService.speechEngine.cancel();
    } catch (_) {}
    // Note: _transcriptionState becomes idle in the finally block of transcribeLesson
  }

  void toggleSnapToSpeech() {
    _snapToSpeechEnabled = !_snapToSpeechEnabled;
    notifyListeners();
  }

  void toggleAiCardExpanded() {
    _isAiCardExpanded = !_isAiCardExpanded;
    notifyListeners();
  }

  Future<void> seekTo(int targetMs) async {
    await audioService.seekTo(targetMs);
    _persistPositionNow();
    notifyListeners();
  }

  void togglePlayPause() {
    audioService.togglePlayPause();
    _persistPositionNow();
  }

  void toggleRepeatOne() => audioService.toggleRepeatOne();
  void previousSentence() => audioService.previousSentence();
  void nextSentence() => audioService.nextSentence();
  void repeatCurrentSentence() => audioService.repeatCurrentSentence();

  // Item 12: Rewritten segment boundary algorithm — legal range first, then preferences
  Future<void> updateSegmentBounds({
    required String segmentId,
    required int newStartMs,
    required int newEndMs,
  }) async {
    final index = _segments.indexWhere((s) => s.id == segmentId);
    if (index == -1) return;

    final totalDur = durationMs > 0 ? durationMs : 1000000;

    // Step 1: Compute legal range from neighbors
    final int minimumStart = index > 0 ? _segments[index - 1].endMs : 0;
    final int maximumEnd = index < _segments.length - 1 ? _segments[index + 1].startMs : totalDur;

    // Step 2: Clamp proposed values to legal range
    int finalStart = newStartMs.clamp(minimumStart, maximumEnd);
    int finalEnd = newEndMs.clamp(minimumStart, maximumEnd);

    // Step 3: Apply snap-to-speech if enabled
    if (_snapToSpeechEnabled) {
      finalStart = snapToSpeechService.snapBoundary(
        proposedPositionMs: finalStart,
        waveformPeaks: _fullWaveformPeaks,
        totalDurationMs: totalDur,
      ).clamp(minimumStart, maximumEnd);
      finalEnd = snapToSpeechService.snapBoundary(
        proposedPositionMs: finalEnd,
        waveformPeaks: _fullWaveformPeaks,
        totalDurationMs: totalDur,
      ).clamp(minimumStart, maximumEnd);
    }

    // Step 4: Enforce minimum duration (500ms) only if range allows
    if (finalEnd - finalStart < 500) {
      final rangeAvailable = maximumEnd - minimumStart;
      if (rangeAvailable >= 500) {
        if (finalStart + 500 <= maximumEnd) {
          finalEnd = finalStart + 500;
        } else {
          finalStart = maximumEnd - 500;
          finalEnd = maximumEnd;
        }
      } else {
        // Range is too small — fill it entirely
        finalStart = minimumStart;
        finalEnd = maximumEnd;
      }
    }

    // Step 5: Final safety — ensure start < end
    if (finalEnd <= finalStart) {
      finalEnd = min(finalStart + 500, maximumEnd);
      if (finalEnd <= finalStart) return; // Can't fix — skip edit
    }

    final updated = _segments[index].copyWith(
      startMs: finalStart,
      endMs: finalEnd,
      isUserEdited: true,
    );

    _segments[index] = updated;
    audioService.updateSegments(_segments);
    await lessonRepo.updateSegment(updated);
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

  // Item 13: Token timestamp validation for split operations
  Future<void> addCutAtPlayhead() async {
    final seg = currentSegment;
    if (seg == null) return;
    if (positionMs <= seg.startMs + 400 || positionMs >= seg.endMs - 400) return;

    final index = _segments.indexWhere((s) => s.id == seg.id);
    if (index == -1) return;

    List<TranscriptToken> tokens1 = [];
    List<TranscriptToken> tokens2 = [];
    String text1 = '';
    String text2 = '';

    final hasReliableTimestamps = _hasReliableTokenTimestamps(seg.tokens, seg);
    if (seg.tokens.isNotEmpty && hasReliableTimestamps) {
      int splitIndex = -1;
      for (int i = 0; i < seg.tokens.length; i++) {
        final tok = seg.tokens[i];
        final tokMid = tok.startMs > 0 && tok.endMs > 0 ? (tok.startMs + tok.endMs) ~/ 2 : tok.endMs;
        if (tokMid <= positionMs) {
          splitIndex = i + 1;
        } else {
          break;
        }
      }

      if (splitIndex <= 0) splitIndex = 1;
      if (splitIndex >= seg.tokens.length) splitIndex = seg.tokens.length - 1;

      tokens1 = seg.tokens.sublist(0, splitIndex);
      tokens2 = seg.tokens.sublist(splitIndex);
      text1 = tokens1.map((t) => t.text).join(' ');
      text2 = tokens2.map((t) => t.text).join(' ');
    } else {
      // Proportional fallback for both text and tokens
      final words = seg.text.split(' ');
      final ratio = (positionMs - seg.startMs) / max(1, seg.endMs - seg.startMs);
      final wordIndex = (words.length * ratio).round().clamp(1, max(1, words.length - 1)).toInt();
      text1 = words.take(wordIndex).join(' ');
      text2 = words.skip(wordIndex).join(' ');

      // Split tokens proportionally too if they exist but lack timestamps
      if (seg.tokens.isNotEmpty) {
        final tokenSplit = (seg.tokens.length * ratio).round().clamp(1, max(1, seg.tokens.length - 1)).toInt();
        tokens1 = seg.tokens.sublist(0, tokenSplit);
        tokens2 = seg.tokens.sublist(tokenSplit);
      }
    }

    final firstSeg = seg.copyWith(
      endMs: positionMs,
      text: text1.isNotEmpty ? text1 : seg.text,
      tokens: tokens1,
      isUserEdited: true,
    );

    final secondSeg = AudioSegment(
      id: _uuid.v4(),
      lessonId: seg.lessonId,
      startMs: positionMs,
      endMs: seg.endMs,
      text: text2.isNotEmpty ? text2 : '...',
      confidence: seg.confidence,
      tokens: tokens2,
      isUserEdited: true,
    );

    _segments[index] = firstSeg;
    _segments.insert(index + 1, secondSeg);

    audioService.updateSegments(_segments);
    if (_lesson != null) {
      await lessonRepo.saveSegments(_lesson!.id, _segments);
    }
    notifyListeners();
  }

  /// Item 13: Check if token timestamps are reliable enough for timestamp-based splitting.
  bool _hasReliableTokenTimestamps(List<TranscriptToken> tokens, AudioSegment segment) {
    if (tokens.length < 2) return false;

    int timestampedCount = 0;
    bool isMonotonic = true;
    int lastEndMs = -1;

    for (final tok in tokens) {
      final hasTs = tok.startMs > 0 || tok.endMs > 0;
      if (hasTs) {
        timestampedCount++;
        // Check monotonicity
        if (tok.startMs > 0 && lastEndMs > 0 && tok.startMs < lastEndMs - 100) {
          isMonotonic = false;
        }
        lastEndMs = tok.endMs > 0 ? tok.endMs : lastEndMs;
        // Check within segment bounds (with 100ms tolerance)
        if (tok.startMs > 0 && tok.startMs < segment.startMs - 100) return false;
        if (tok.endMs > 0 && tok.endMs > segment.endMs + 100) return false;
      }
    }

    // Require at least 50% of tokens to have timestamps AND monotonic
    return timestampedCount >= tokens.length * 0.5 && isMonotonic;
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
    final prev = (curIndex > 0 && curIndex < _segments.length) ? _segments[curIndex - 1].text : null;
    final next = (curIndex >= 0 && curIndex < _segments.length - 1) ? _segments[curIndex + 1].text : null;

    final uncertain = cur?.tokens
            .where((t) => t.isUncertain)
            .map((t) => t.text)
            .toList() ??
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

  // Item 10: Track AI generation and cancel properly on segment change
  Future<void> _fetchAiExplanation() async {
    final cur = currentSegment;
    if (cur == null) {
      // Null segment: cancel pending request and clear explanation
      _activeAiHandle?.cancel();
      _activeAiHandle = null;
      _aiExplanation = '';
      _isAiGenerating = false;
      notifyListeners();
      return;
    }

    final gen = ++_aiExplanationGeneration;
    _activeAiHandle?.cancel();
    _activeAiHandle = null;

    if (!aiService.llmEngine.isLoaded) {
      _aiExplanation = 'Load a local AI model in Settings to generate explanations.';
      notifyListeners();
      return;
    }

    _isAiGenerating = true;
    _aiExplanation = '';
    notifyListeners();

    try {
      final context = getCurrentSentenceContext();
      final handle = aiService.startExplainSentence(context);
      _activeAiHandle = handle;

      await for (final chunk in handle.stream) {
        if (gen != _aiExplanationGeneration || _isDisposed) break;
        _aiExplanation += chunk;
        notifyListeners();
      }
    } catch (e) {
      if (gen == _aiExplanationGeneration && !_isDisposed) {
        if (e is AiBusyException) {
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
    _activeAiHandle?.cancel();
    // Item 15: Persist position BEFORE setting _isDisposed
    _persistPositionNow();
    _isDisposed = true;
    audioService.removeListener(_onAudioServiceUpdate);
    super.dispose();
  }
}
