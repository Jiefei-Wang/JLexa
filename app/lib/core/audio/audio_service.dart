import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'audio_models.dart';

class AudioPlaybackState {
  final bool isPlaying;
  final int positionMs;
  final int durationMs;
  final bool isRepeatOne;

  const AudioPlaybackState({
    this.isPlaying = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.isRepeatOne = false,
  });

  AudioPlaybackState copyWith({
    bool? isPlaying,
    int? positionMs,
    int? durationMs,
    bool? isRepeatOne,
  }) {
    return AudioPlaybackState(
      isPlaying: isPlaying ?? this.isPlaying,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      isRepeatOne: isRepeatOne ?? this.isRepeatOne,
    );
  }
}

class AudioService extends ChangeNotifier {
  AudioPlayer? _playerInstance;
  AudioPlayer get _player => _playerInstance ??= _createPlayer();

  StreamSubscription? _positionSub;
  StreamSubscription? _playerStateSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _completeSub;

  AudioLesson? _currentLesson;
  List<AudioSegment> _segments = [];
  int _currentSegmentIndex = 0;

  bool _isPlaying = false;
  int _positionMs = 0;
  int _durationMs = 0;
  bool _isRepeatOne = false;
  bool _isSeeking = false;
  int _seekGeneration = 0;
  bool _loopSeekInFlight = false;
  String? _loopTargetCutId;
  bool _resumeAfterScrub = false;
  bool _hasLoadError = false;
  String? _loadErrorMessage;
  int _loadGeneration = 0;
  Future<void> _loadChain = Future.value();

  bool get isPlaying => _isPlaying;
  int get positionMs => _positionMs;
  int get durationMs => _durationMs;
  bool get isRepeatOne => _isRepeatOne;
  bool get hasLoadError => _hasLoadError;
  String? get loadErrorMessage => _loadErrorMessage;
  AudioLesson? get currentLesson => _currentLesson;
  List<AudioSegment> get segments => _segments;
  int get currentSegmentIndex => _currentSegmentIndex;

  AudioSegment? get currentSegment {
    if (_segments.isEmpty ||
        _currentSegmentIndex < 0 ||
        _currentSegmentIndex >= _segments.length) {
      return null;
    }
    return _segments[_currentSegmentIndex];
  }

  AudioSegment? get loopTarget => _loopTargetCutId == null
      ? null
      : _segments.cast<AudioSegment?>().firstWhere(
          (s) => s?.id == _loopTargetCutId,
          orElse: () => null,
        );

  AudioService();

  AudioPlayer _createPlayer() {
    final player = AudioPlayer();
    _initSubscriptions(player);
    return player;
  }

  void _initSubscriptions(AudioPlayer player) {
    try {
      _playerStateSub = player.onPlayerStateChanged.listen((state) {
        _isPlaying = state == PlayerState.playing;
        notifyListeners();
      }, onError: (_) {});

      _positionSub = player.onPositionChanged.listen((pos) {
        if (_isSeeking) return;
        _positionMs = pos.inMilliseconds;
        final target = loopTarget;
        if (_isRepeatOne && target != null && _positionMs >= target.endMs) {
          unawaited(_performLoop(target));
          return;
        }
        _updateActiveSegment();
        _syncLoopTargetToActiveCut();
        notifyListeners();
      }, onError: (_) {});

      _completeSub = player.onPlayerComplete.listen((_) {
        _isPlaying = false;
        final target = loopTarget;
        if (_isRepeatOne && target != null) {
          unawaited(_performLoop(target));
        } else {
          notifyListeners();
        }
      }, onError: (_) {});

      _durationSub = player.onDurationChanged.listen((dur) {
        final newDurationMs = dur.inMilliseconds;
        if (newDurationMs > 0 && newDurationMs != _durationMs) {
          _durationMs = newDurationMs;
          notifyListeners();
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  Future<void> clearLesson() {
    final gen = ++_loadGeneration;
    final completer = Completer<void>();

    _loadChain = _loadChain.then((_) async {
      if (gen != _loadGeneration) {
        completer.complete();
        return;
      }
      try {
        await _player.stop();
      } catch (_) {}
      _currentLesson = null;
      _segments = [];
      _currentSegmentIndex = -1;
      _positionMs = 0;
      _durationMs = 0;
      _isPlaying = false;
      _loopTargetCutId = null;
      _hasLoadError = false;
      _loadErrorMessage = null;
      notifyListeners();
      completer.complete();
    });

    return completer.future;
  }

  Future<void> loadLesson(AudioLesson lesson, List<AudioSegment> segments) {
    final loadId = ++_loadGeneration;
    _hasLoadError = false;
    _loadErrorMessage = null;

    final completer = Completer<void>();

    _loadChain = _loadChain.then((_) async {
      if (loadId != _loadGeneration) {
        // Skip stale requested load entirely before doing native player work
        completer.complete();
        return;
      }

      try {
        // Clear current lesson state when beginning a new load to avoid exposing stale audio
        _currentLesson = null;
        _segments = [];
        _currentSegmentIndex = -1;
        _positionMs = 0;
        _durationMs = 0;
        _isPlaying = false;
        notifyListeners();

        await _player.stop();
        if (loadId != _loadGeneration) {
          completer.complete();
          return;
        }

        if (lesson.localPath.startsWith('asset:')) {
          await _player.setSource(
            AssetSource(lesson.localPath.replaceFirst('asset:', '')),
          );
        } else {
          final file = File(lesson.localPath);
          if (!await file.exists()) {
            throw Exception('Audio file does not exist at ${lesson.localPath}');
          }
          await _player.setSource(DeviceFileSource(lesson.localPath));
        }
        if (loadId != _loadGeneration) {
          completer.complete();
          return;
        }

        if (lesson.currentPositionMs > 0) {
          await _player.seek(Duration(milliseconds: lesson.currentPositionMs));
        }
        if (loadId != _loadGeneration) {
          completer.complete();
          return;
        }

        _currentLesson = lesson;
        _segments = List.from(segments);
        _positionMs = lesson.currentPositionMs;
        _durationMs = lesson.durationMs;
        _updateActiveSegment();
        notifyListeners();
        completer.complete();
      } catch (e) {
        if (loadId == _loadGeneration) {
          _hasLoadError = true;
          _loadErrorMessage = 'Failed to load audio: $e';
          notifyListeners();
          completer.completeError(e);
        } else {
          completer.complete();
        }
      }
    });

    return completer.future;
  }

  void updateSegments(List<AudioSegment> newSegments) {
    _segments = List.from(newSegments);
    _updateActiveSegment();
    _syncLoopTargetToActiveCut();
    notifyListeners();
  }

  void _updateActiveSegment() {
    if (_segments.isEmpty) {
      _currentSegmentIndex = -1;
      return;
    }

    _currentSegmentIndex = _segments.indexWhere(
      (s) => s.containsPosition(_positionMs),
    );
  }

  void _syncLoopTargetToActiveCut() {
    _loopTargetCutId = _isRepeatOne ? currentSegment?.id : null;
  }

  Future<void> _performLoop(AudioSegment target) async {
    if (_loopSeekInFlight || !_isRepeatOne || loopTarget?.id != target.id) {
      return;
    }
    _loopSeekInFlight = true;
    try {
      await seekTo(target.startMs, userInitiated: false);
      if (_isRepeatOne && loopTarget?.id == target.id) await play();
    } finally {
      _loopSeekInFlight = false;
    }
  }

  Future<void> togglePlayPause() async {
    if (_isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> play() async {
    try {
      await _player.resume();
    } catch (_) {}
  }

  Future<void> pause() async {
    try {
      await _player.pause();
    } catch (_) {}
  }

  Future<void> seekTo(int positionMs, {bool userInitiated = true}) async {
    final generation = ++_seekGeneration;
    _isSeeking = true;
    _positionMs = positionMs
        .clamp(0, _durationMs > 0 ? _durationMs : positionMs)
        .toInt();
    _updateActiveSegment();
    if (userInitiated) _syncLoopTargetToActiveCut();
    notifyListeners();

    try {
      final target = _positionMs;
      await _player.seek(Duration(milliseconds: target));
    } catch (_) {
    } finally {
      if (generation == _seekGeneration) _isSeeking = false;
    }
  }

  Future<void> beginScrub() async {
    _resumeAfterScrub = _isPlaying;
    if (_isPlaying) await pause();
  }

  Future<void> endScrub() async {
    if (_resumeAfterScrub) await play();
    _resumeAfterScrub = false;
  }

  Future<void> stop() async {
    try {
      await _player.stop();
      _isPlaying = false;
      notifyListeners();
    } catch (_) {}
  }

  void toggleRepeatOne() {
    _isRepeatOne = !_isRepeatOne;
    _syncLoopTargetToActiveCut();
    notifyListeners();
  }

  Future<void> previousSentence() async {
    if (_segments.isEmpty) return;
    final before = _segments.where((s) => s.startMs < _positionMs).toList();
    final target = before.isEmpty ? _segments.first : before.last;
    await seekTo(target.startMs);
  }

  Future<void> nextSentence() async {
    if (_segments.isEmpty) return;
    final after = _segments.where((s) => s.startMs > _positionMs).toList();
    final target = after.isEmpty ? _segments.last : after.first;
    await seekTo(target.startMs);
  }

  Future<void> repeatCurrentSentence() async {
    final seg = currentSegment;
    if (seg != null) {
      await seekTo(seg.startMs);
      await play();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _durationSub?.cancel();
    _completeSub?.cancel();
    _playerInstance?.dispose();
    super.dispose();
  }
}
