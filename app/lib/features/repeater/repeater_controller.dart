import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
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

  AudioLesson? get lesson => _lesson;
  List<AudioSegment> get segments => _segments;
  List<double> get fullWaveformPeaks => _fullWaveformPeaks;
  bool get snapToSpeechEnabled => _snapToSpeechEnabled;
  bool get isAiCardExpanded => _isAiCardExpanded;
  String get aiExplanation => _aiExplanation;
  bool get isAiGenerating => _isAiGenerating;
  bool get isLoading => _isLoading;

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
    notifyListeners();
  }

  Future<void> _loadDefaultLesson() async {
    final all = await lessonRepo.getAllLessons();
    if (all.isNotEmpty) {
      await loadLesson(all.first);
    }
  }

  Future<void> loadLesson(AudioLesson lesson) async {
    _isLoading = true;
    _lesson = lesson;
    notifyListeners();

    try {
      _segments = await lessonRepo.getSegmentsForLesson(lesson.id);
      _fullWaveformPeaks = await waveformService.extractAndCacheWaveform(
        lesson.localPath,
        lesson.id,
        lesson.durationMs,
      );

      await audioService.loadLesson(lesson, _segments);
      _fetchAiExplanation();
    } catch (_) {}

    _isLoading = false;
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
    if (_lesson != null) {
      await lessonRepo.updateLessonPosition(_lesson!.id, targetMs);
    }
    notifyListeners();
  }

  void togglePlayPause() => audioService.togglePlayPause();
  void toggleRepeatOne() => audioService.toggleRepeatOne();
  void previousSentence() => audioService.previousSentence();
  void nextSentence() => audioService.nextSentence();
  void repeatCurrentSentence() => audioService.repeatCurrentSentence();

  // Segment adjustment operations
  Future<void> updateSegmentBounds({
    required String segmentId,
    required int newStartMs,
    required int newEndMs,
  }) async {
    final index = _segments.indexWhere((s) => s.id == segmentId);
    if (index == -1) return;

    int finalStart = newStartMs.clamp(0, durationMs);
    int finalEnd = newEndMs.clamp(0, durationMs);

    if (_snapToSpeechEnabled) {
      finalStart = snapToSpeechService.snapBoundary(
        proposedPositionMs: finalStart,
        waveformPeaks: _fullWaveformPeaks,
        totalDurationMs: durationMs,
      );
      finalEnd = snapToSpeechService.snapBoundary(
        proposedPositionMs: finalEnd,
        waveformPeaks: _fullWaveformPeaks,
        totalDurationMs: durationMs,
      );
    }

    if (finalEnd - finalStart < 500) {
      finalEnd = finalStart + 500;
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

    // Split words between the two segments approximately
    final words = seg.text.split(' ');
    final mid = words.length ~/ 2;
    final text1 = words.take(mid).join(' ');
    final text2 = words.skip(mid).join(' ');

    final firstSeg = seg.copyWith(
      endMs: positionMs,
      text: text1.isNotEmpty ? text1 : seg.text,
      isUserEdited: true,
    );

    final secondSeg = AudioSegment(
      id: _uuid.v4(),
      lessonId: seg.lessonId,
      startMs: positionMs,
      endMs: seg.endMs,
      text: text2.isNotEmpty ? text2 : '...',
      confidence: seg.confidence,
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

    if (!aiService.llmEngine.isLoaded) {
      _aiExplanation = 'Load a local AI model to generate an explanation.';
      notifyListeners();
      return;
    }

    _isAiGenerating = true;
    _aiExplanation = '';
    notifyListeners();

    final context = getCurrentSentenceContext();
    await for (final chunk in aiService.explainSentence(context)) {
      _aiExplanation += chunk;
      notifyListeners();
    }
    _isAiGenerating = false;
    notifyListeners();
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
    audioService.removeListener(_onAudioServiceUpdate);
    super.dispose();
  }
}
