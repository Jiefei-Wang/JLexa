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

  AudioLesson? _currentLesson;
  List<AudioSegment> _segments = [];
  int _currentSegmentIndex = 0;

  bool _isPlaying = false;
  int _positionMs = 0;
  int _durationMs = 0;
  bool _isRepeatOne = false;
  bool _isSeeking = false;
  bool _hasLoadError = false;
  String? _loadErrorMessage;
  int _loadGeneration = 0;

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

        // Handle Repeat One segment boundary
        if (_isRepeatOne && currentSegment != null) {
          if (_positionMs >= currentSegment!.endMs) {
            seekTo(currentSegment!.startMs);
            return;
          }
        }

        // Sync active segment if normal playback
        _updateActiveSegment();
        notifyListeners();
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

  Future<void> loadLesson(
    AudioLesson lesson,
    List<AudioSegment> segments,
  ) async {
    final loadId = ++_loadGeneration;
    _hasLoadError = false;
    _loadErrorMessage = null;

    try {
      await _player.stop();
      if (loadId != _loadGeneration) return;

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
      if (loadId != _loadGeneration) return;

      if (lesson.currentPositionMs > 0) {
        await _player.seek(Duration(milliseconds: lesson.currentPositionMs));
      }
      if (loadId != _loadGeneration) return;

      _currentLesson = lesson;
      _segments = List.from(segments);
      _positionMs = lesson.currentPositionMs;
      _durationMs = lesson.durationMs;
      _updateActiveSegment();
      notifyListeners();
    } catch (e) {
      if (loadId != _loadGeneration) return;
      _hasLoadError = true;
      _loadErrorMessage = 'Failed to load audio: $e';
      notifyListeners();
      rethrow;
    }
  }

  void updateSegments(List<AudioSegment> newSegments) {
    _segments = List.from(newSegments);
    _updateActiveSegment();
    notifyListeners();
  }

  void _updateActiveSegment() {
    if (_segments.isEmpty) {
      _currentSegmentIndex = -1;
      return;
    }

    final index = _segments.indexWhere(
      (s) => s.containsPosition(_positionMs, isLast: s == _segments.last),
    );
    if (index != -1) {
      _currentSegmentIndex = index;
    } else {
      // Find nearest preceding segment
      int nearest = 0;
      for (int i = 0; i < _segments.length; i++) {
        if (_segments[i].startMs <= _positionMs) {
          nearest = i;
        } else {
          break;
        }
      }
      _currentSegmentIndex = nearest;
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

  Future<void> seekTo(int positionMs) async {
    _isSeeking = true;
    _positionMs = positionMs
        .clamp(0, _durationMs > 0 ? _durationMs : positionMs)
        .toInt();
    _updateActiveSegment();
    notifyListeners();

    try {
      await _player.seek(Duration(milliseconds: _positionMs));
    } catch (_) {
    } finally {
      _isSeeking = false;
    }
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
    notifyListeners();
  }

  Future<void> previousSentence() async {
    if (_segments.isEmpty) return;
    if (_currentSegmentIndex > 0) {
      _currentSegmentIndex--;
      await seekTo(_segments[_currentSegmentIndex].startMs);
    } else {
      await seekTo(_segments.first.startMs);
    }
  }

  Future<void> nextSentence() async {
    if (_segments.isEmpty) return;
    if (_currentSegmentIndex < _segments.length - 1) {
      _currentSegmentIndex++;
      await seekTo(_segments[_currentSegmentIndex].startMs);
    } else {
      await seekTo(_segments.last.startMs);
    }
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
    _playerInstance?.dispose();
    super.dispose();
  }
}
