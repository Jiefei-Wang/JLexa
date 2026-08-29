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

  bool _isTranscribing = false;
  double _transcriptionProgress = 0.0;
  String? _transcriptionError;

  int _loadGeneration = 0;
  String? _activeSegmentId;
  int _aiExplanationGeneration = 0;
  int _lastPersistedPositionMs = -1;
  DateTime _lastPersistTime = DateTime.fromMillisecondsSinceEpoch(0);

  AudioLesson? get lesson => _lesson;
  List<AudioSegment> get segments => _segments;
  List<double> get fullWaveformPeaks => _fullWaveformPeaks;
  bool get snapToSpeechEnabled => _snapToSpeechEnabled;
  bool get isAiCardExpanded => _isAiCardExpanded;
  String get aiExplanation => _aiExplanation;
  bool get isAiGenerating => _isAiGenerating;
  bool get isLoading => _isLoading;
  bool get isTranscribing => _isTranscribing;
  double get transcriptionProgress => _transcriptionProgress;
  String? get transcriptionError => _transcriptionError;

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
    } else {
      _loadDefaultLesson();
    }
  }

  void _onAudioServiceUpdate() {
    _checkPersistPosition();
    final newSegId = audioService.currentSegment?.id;
    if (newSegId != _activeSegmentId) {
      _activeSegmentId = newSegId;
      _fetchAiExplanation();
    }
    notifyListeners();
  }

  void _checkPersistPosition() {
    if (_lesson == null) return;
    final now = DateTime.now();
    // Persist every 5s during playback, or immediately if paused/stopped or position jumped
    if (!audioService.isPlaying ||
        now.difference(_lastPersistTime).inSeconds >= 5 ||
        (_lastPersistedPositionMs - positionMs).abs() > 2000) {
      _persistPositionNow();
    }
  }

  void _persistPositionNow() {
    if (_lesson == null || _isDisposed) return;
    _lastPersistedPositionMs = positionMs;
    _lastPersistTime = DateTime.now();
    lessonRepo.updateLessonPosition(_lesson!.id, positionMs);
  }

  Future<void> _loadDefaultLesson() async {
    final all = await lessonRepo.getAllLessons();
    if (all.isNotEmpty) {
      await loadLesson(all.first);
    }
  }

  Future<void> loadLesson(AudioLesson lesson) async {
    final currentGen = ++_loadGeneration;
    _isLoading = true;
    _lesson = lesson;
    _activeSegmentId = null;
    _transcriptionError = null;
    notifyListeners();

    try {
      final segs = await lessonRepo.getSegmentsForLesson(lesson.id);
      if (currentGen != _loadGeneration) return;
      _segments = segs;

      final peaks = await waveformService.extractAndCacheWaveform(
        lesson.localPath,
        lesson.id,
        lesson.durationMs,
      );
      if (currentGen != _loadGeneration) return;
      _fullWaveformPeaks = peaks;

      await audioService.loadLesson(lesson, _segments);
      if (currentGen != _loadGeneration) return;

      _activeSegmentId = audioService.currentSegment?.id;
      _fetchAiExplanation();
    } catch (_) {}

    if (currentGen == _loadGeneration) {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> transcribeLesson() async {
    if (_lesson == null) return;
    if (!aiService.speechEngine.isLoaded) {
      _transcriptionError = 'Whisper speech model not loaded. Please select a model in Settings.';
      notifyListeners();
      return;
    }

    _isTranscribing = true;
    _transcriptionProgress = 0.0;
    _transcriptionError = null;
    notifyListeners();

    try {
      final segments = await aiService.speechEngine.transcribeAudio(
        audioPath: _lesson!.localPath,
        lessonId: _lesson!.id,
        nThreads: aiService.settings.threads,
        onProgress: (p) {
          _transcriptionProgress = p;
          notifyListeners();
        },
      );

      _segments = segments;
      audioService.updateSegments(_segments);
      await lessonRepo.saveSegments(_lesson!.id, segments);
      await lessonRepo.updateTranscriptStatus(_lesson!.id, 'ready');
      _lesson = _lesson!.copyWith(transcriptStatus: 'ready');
      _activeSegmentId = audioService.currentSegment?.id;
      _fetchAiExplanation();
    } catch (e) {
      _transcriptionError = e.toString();
    } finally {
      _isTranscribing = false;
      notifyListeners();
    }
  }

  Future<void> cancelTranscription() async {
    try {
      await aiService.speechEngine.cancel();
    } catch (_) {}
    _isTranscribing = false;
    notifyListeners();
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

  // Segment adjustment operations with strict boundary validation
  Future<void> updateSegmentBounds({
    required String segmentId,
    required int newStartMs,
    required int newEndMs,
  }) async {
    final index = _segments.indexWhere((s) => s.id == segmentId);
    if (index == -1) return;

    final totalDur = durationMs > 0 ? durationMs : 1000000;
    int finalStart = newStartMs.clamp(0, totalDur);
    int finalEnd = newEndMs.clamp(0, totalDur);

    if (_snapToSpeechEnabled) {
      finalStart = snapToSpeechService.snapBoundary(
        proposedPositionMs: finalStart,
        waveformPeaks: _fullWaveformPeaks,
        totalDurationMs: totalDur,
      );
      finalEnd = snapToSpeechService.snapBoundary(
        proposedPositionMs: finalEnd,
        waveformPeaks: _fullWaveformPeaks,
        totalDurationMs: totalDur,
      );
    }

    // Min duration clamp without exceeding total duration
    if (finalEnd - finalStart < 500) {
      if (finalStart + 500 <= totalDur) {
        finalEnd = finalStart + 500;
      } else if (totalDur >= 500) {
        finalEnd = totalDur;
        finalStart = totalDur - 500;
      } else {
        finalStart = 0;
        finalEnd = totalDur;
      }
    }

    // Prevent overlap with adjacent segments
    if (index > 0) {
      finalStart = max(finalStart, _segments[index - 1].endMs);
    }
    if (index < _segments.length - 1) {
      finalEnd = min(finalEnd, _segments[index + 1].startMs);
    }

    if (finalEnd <= finalStart) {
      finalEnd = min(finalStart + 500, totalDur);
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

    final hasTimestamps = seg.tokens.any((t) => t.startMs > 0 || t.endMs > 0);
    if (seg.tokens.isNotEmpty && hasTimestamps) {
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
      final words = seg.text.split(' ');
      final ratio = (positionMs - seg.startMs) / max(1, seg.endMs - seg.startMs);
      final wordIndex = (words.length * ratio).round().clamp(1, max(1, words.length - 1)).toInt();
      text1 = words.take(wordIndex).join(' ');
      text2 = words.skip(wordIndex).join(' ');
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

  Future<void> _fetchAiExplanation() async {
    final cur = currentSegment;
    if (cur == null) return;

    final gen = ++_aiExplanationGeneration;

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
      await for (final chunk in aiService.explainSentence(context)) {
        if (gen != _aiExplanationGeneration || _isDisposed) break;
        _aiExplanation += chunk;
        notifyListeners();
      }
    } catch (e) {
      if (gen == _aiExplanationGeneration && !_isDisposed) {
        _aiExplanation = 'Explanation unavailable: $e';
      }
    }

    if (gen == _aiExplanationGeneration && !_isDisposed) {
      _isAiGenerating = false;
      notifyListeners();
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
    _isDisposed = true;
    _persistPositionNow();
    audioService.removeListener(_onAudioServiceUpdate);
    super.dispose();
  }
}
