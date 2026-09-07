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
  final bool isAutoStop;

  const AudioPlaybackState({
    this.isPlaying = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.isRepeatOne = false,
    this.isAutoStop = true,
  });

  AudioPlaybackState copyWith({
    bool? isPlaying,
    int? positionMs,
    int? durationMs,
    bool? isRepeatOne,
    bool? isAutoStop,
  }) {
    return AudioPlaybackState(
      isPlaying: isPlaying ?? this.isPlaying,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      isRepeatOne: isRepeatOne ?? this.isRepeatOne,
      isAutoStop: isAutoStop ?? this.isAutoStop,
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
  bool _completed = false;
  int _positionMs = 0;
  int _durationMs = 0;
  bool _isRepeatOne = false;
  bool _isAutoStop = true;
  bool _wantsPlaying = false;
  bool _isDisposed = false;
  bool _isSeeking = false;
  int _seekGeneration = 0;
  Future<void>? _boundaryTask;
  int _playbackGeneration = 0;
  String? _loopTargetCutId;
  String? _stoppedCutId;
  bool _resumeAfterScrub = false;
  bool _hasLoadError = false;
  String? _loadErrorMessage;
  int _loadGeneration = 0;
  Future<void> _loadChain = Future.value();

  bool get isPlaying => _isPlaying;
  int get positionMs => _positionMs;
  int get durationMs => _durationMs;
  bool get isRepeatOne => _isRepeatOne;
  bool get isAutoStop => _isAutoStop;
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
    var positionQueryPending = false;
    // A file picker or another activity can stop Flutter frames while native
    // audio keeps playing. Poll independently so cut boundaries still apply.
    // Reject queries that finish after a seek, pause or lesson switch.
    player.positionUpdater = TimerPositionUpdater(
      interval: const Duration(milliseconds: 40),
      getPosition: () async {
        // Timer ticks can overlap a slow platform call. Keep one query in flight
        // so an older response cannot overwrite a more recent position.
        if (_isDisposed || positionQueryPending) return null;
        positionQueryPending = true;
        final seek = _seekGeneration;
        final load = _loadGeneration;
        final playback = _playbackGeneration;
        try {
          final position = await player.getCurrentPosition();
          return !_isDisposed &&
                  seek == _seekGeneration &&
                  load == _loadGeneration &&
                  playback == _playbackGeneration
              ? position
              : null;
        } catch (_) {
          return null;
        } finally {
          positionQueryPending = false;
        }
      },
    );
    _initSubscriptions(player);
    return player;
  }

  void _initSubscriptions(AudioPlayer player) {
    try {
      _playerStateSub = player.onPlayerStateChanged.listen((state) {
        if (!_wantsPlaying || state == PlayerState.playing) {
          _isPlaying = _wantsPlaying && state == PlayerState.playing;
        }
        notifyListeners();
      }, onError: (_) {});

      _positionSub = player.onPositionChanged.listen((pos) {
        if (_isSeeking ||
            _completed ||
            !_wantsPlaying ||
            _currentLesson == null ||
            _boundaryTask != null) {
          return;
        }
        _positionMs = pos.inMilliseconds;
        final target = loopTarget;
        if (target != null && _positionMs >= target.endMs) {
          _startBoundaryAction(target);
          return;
        }
        _updateActiveSegment();
        _syncLoopTargetToActiveCut();
        notifyListeners();
      }, onError: (_) {});

      _completeSub = player.onPlayerComplete.listen((_) {
        if (!_wantsPlaying ||
            _currentLesson == null ||
            _isSeeking ||
            _boundaryTask != null) {
          return;
        }
        _isPlaying = false;
        final target = loopTarget;
        if (target != null) {
          _startBoundaryAction(target);
        } else {
          _wantsPlaying = false;
          _completed = true;
          _positionMs = _durationMs;
          _updateActiveSegment();
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
    ++_playbackGeneration;
    _wantsPlaying = false;
    _stoppedCutId = null;
    final completer = Completer<void>();

    _loadChain = _loadChain.then((_) async {
      if (gen != _loadGeneration) {
        completer.complete();
        return;
      }
      try {
        await _boundaryTask;
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
    ++_playbackGeneration;
    _wantsPlaying = false;
    _stoppedCutId = null;
    _loopTargetCutId = null;
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
        await _boundaryTask;
        if (loadId != _loadGeneration || _isDisposed) {
          completer.complete();
          return;
        }
        // Clear current lesson state when beginning a new load to avoid exposing stale audio
        _currentLesson = null;
        _segments = [];
        _currentSegmentIndex = -1;
        _positionMs = 0;
        _durationMs = 0;
        _completed = false;
        _isPlaying = false;
        notifyListeners();

        // Keep the native source after EOF so seeking/replaying still works.
        await _player.setReleaseMode(ReleaseMode.stop);
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
        _syncLoopTargetToActiveCut();
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

    if (_stoppedCutId != null) {
      final stopped = _segments.indexWhere(
        (s) => s.id == _stoppedCutId && s.endMs == _positionMs,
      );
      if (stopped >= 0) {
        _currentSegmentIndex = stopped;
        return;
      }
      _stoppedCutId = null;
    }
    _currentSegmentIndex = _segments.indexWhere(
      (s) => s.containsPosition(_positionMs),
    );
  }

  void _syncLoopTargetToActiveCut() {
    _loopTargetCutId = null;
    if (!_isRepeatOne && !_isAutoStop) return;
    _loopTargetCutId = currentSegment?.id;
    // Starting in a gap must still catch the first segment, even if a native
    // update jumps across that entire short segment.
    _loopTargetCutId ??= _segments
        .cast<AudioSegment?>()
        .firstWhere(
          (s) => s != null && s.startMs >= _positionMs,
          orElse: () => null,
        )
        ?.id;
  }

  void _startBoundaryAction(AudioSegment target) {
    if (_boundaryTask != null ||
        !_wantsPlaying ||
        (!_isRepeatOne && !_isAutoStop)) {
      return;
    }
    final task = _performBoundary(target, repeat: _isRepeatOne);
    _boundaryTask = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_boundaryTask, task)) _boundaryTask = null;
      }),
    );
  }

  Future<void> _performBoundary(
    AudioSegment target, {
    required bool repeat,
  }) async {
    final playbackGeneration = _playbackGeneration;
    final loadGeneration = _loadGeneration;
    bool ownsAction() =>
        !_isDisposed &&
        playbackGeneration == _playbackGeneration &&
        loadGeneration == _loadGeneration &&
        loopTarget?.id == target.id &&
        loopTarget?.startMs == target.startMs &&
        loopTarget?.endMs == target.endMs;
    try {
      if (repeat) {
        debugPrint(
          '[JLexaAudio] loop start cut=${target.id} '
          'bounds=${target.startMs}-${target.endMs} position=$_positionMs',
        );
        await seekTo(target.startMs, userInitiated: false);
        if (ownsAction() && _isRepeatOne && _wantsPlaying) {
          await _player.resume();
          debugPrint(
            '[JLexaAudio] loop resumed cut=${target.id} at=${target.startMs}',
          );
        }
      } else {
        _wantsPlaying = false;
        _isPlaying = false;
        _positionMs = target.endMs;
        _stoppedCutId = target.id;
        _updateActiveSegment();
        notifyListeners();
        await _player.pause();
        if (!ownsAction()) return;
        // Correct decoder overshoot while retaining the finished cut selected.
        await seekTo(target.endMs, userInitiated: false);
        if (ownsAction()) {
          _completed = target.endMs >= _durationMs;
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  Future<void> togglePlayPause() async {
    if (_isPlaying || (_boundaryTask != null && _wantsPlaying)) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> play() async {
    final generation = ++_playbackGeneration;
    _wantsPlaying = true;
    try {
      await _boundaryTask;
      if (_isDisposed || generation != _playbackGeneration) return;
      _stoppedCutId = null;
      if (_durationMs > 0 && _positionMs >= _durationMs) {
        await seekTo(0, userInitiated: false);
      }
      if (_isDisposed || generation != _playbackGeneration) return;
      _completed = false;
      _updateActiveSegment();
      _syncLoopTargetToActiveCut();
      await _player.resume();
    } catch (_) {}
  }

  Future<void> pause() async {
    final generation = ++_playbackGeneration;
    _wantsPlaying = false;
    _isPlaying = false;
    notifyListeners();
    try {
      await _boundaryTask;
      if (_isDisposed || generation != _playbackGeneration) return;
      await _player.pause();
    } catch (_) {}
  }

  Future<void> seekTo(int positionMs, {bool userInitiated = true}) async {
    final playback = userInitiated
        ? ++_playbackGeneration
        : _playbackGeneration;
    if (userInitiated) {
      _stoppedCutId = null;
      if (_boundaryTask != null) await _boundaryTask;
      if (_isDisposed || playback != _playbackGeneration) return;
    }
    _completed = false;
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
    final generation = ++_playbackGeneration;
    _wantsPlaying = false;
    _stoppedCutId = null;
    try {
      await _boundaryTask;
      if (_isDisposed || generation != _playbackGeneration) return;
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

  void toggleAutoStop() {
    _isAutoStop = !_isAutoStop;
    _syncLoopTargetToActiveCut();
    notifyListeners();
  }

  Future<void> previousSentence() async {
    if (_segments.isEmpty) return;
    if (currentSegment != null) {
      await seekTo(
        _segments[(_currentSegmentIndex - 1).clamp(0, _segments.length - 1)]
            .startMs,
      );
      return;
    }
    final before = _segments.where((s) => s.endMs <= _positionMs).toList();
    final target = before.isEmpty ? _segments.first : before.last;
    await seekTo(target.startMs);
  }

  Future<void> nextSentence() async {
    if (_segments.isEmpty) return;
    if (currentSegment != null) {
      await seekTo(
        _segments[(_currentSegmentIndex + 1).clamp(0, _segments.length - 1)]
            .startMs,
      );
      return;
    }
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
    _isDisposed = true;
    ++_playbackGeneration;
    ++_loadGeneration;
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _durationSub?.cancel();
    _completeSub?.cancel();
    _playerInstance?.dispose();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_isDisposed) super.notifyListeners();
  }
}
