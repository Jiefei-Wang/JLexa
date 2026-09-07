import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../core/collection/collection_models.dart';
import '../../core/collection/collection_repository.dart';

/// Plays only the standalone audio owned by Collection, with one local player.
class CollectionPlaybackController extends ChangeNotifier {
  final CollectionRepository repository;
  final Future<void> Function()? onBeforePlay;
  final AudioPlayer Function() _playerFactory;
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _commands = Future.value();
  int _generation = 0;
  bool _active = true;
  bool _disposed = false;
  String? _loadedClipId;
  CollectionClip? _clip;
  CollectionClip? get clip => _clip;
  bool _playing = false;
  bool get isPlaying => _playing;
  bool _preparing = false;
  bool get isPreparing => _preparing;
  bool _completed = false;
  Duration _position = Duration.zero;
  Duration get position => _position;
  Duration _duration = Duration.zero;
  Duration get duration => _duration;
  String? _error;
  String? get error => _error;
  bool get canSeek =>
      !_preparing && _clip != null && _loadedClipId == _clip!.id;

  CollectionPlaybackController({
    required this.repository,
    this.onBeforePlay,
    AudioPlayer Function()? playerFactory,
  }) : _playerFactory = playerFactory ?? AudioPlayer.new;

  bool _owns(int generation) =>
      !_disposed && _active && generation == _generation;

  AudioPlayer _getPlayer() {
    if (_player != null) return _player!;
    final player = _playerFactory();
    _player = player;
    _subscriptions.addAll([
      player.onPositionChanged.listen((position) {
        // Android can report a reset-to-zero position after the EOF event.
        // Keep the completed position until an explicit seek, replay or stop.
        if (_disposed || !_active || _completed || !canSeek) return;
        _position = _bounded(position);
        notifyListeners();
      }),
      player.onDurationChanged.listen((duration) {
        if (_disposed || !_active || !canSeek || duration <= Duration.zero) {
          return;
        }
        _duration = duration;
        _position = _bounded(_position);
        notifyListeners();
      }),
      player.onPlayerStateChanged.listen((state) {
        if (_disposed || !_active || !canSeek) return;
        _playing = state == PlayerState.playing;
        notifyListeners();
      }),
      player.onPlayerComplete.listen((_) {
        if (_disposed || !_active || !canSeek) return;
        _playing = false;
        _completed = true;
        _position = _duration;
        notifyListeners();
      }),
    ]);
    return player;
  }

  Duration _bounded(Duration value) => Duration(
    milliseconds: value.inMilliseconds.clamp(0, _duration.inMilliseconds),
  );

  Future<void> _enqueue(Future<void> Function() action) {
    final command = _commands.then((_) => action());
    _commands = command.catchError((Object _) {});
    return command;
  }

  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    if (!active) unawaited(stop());
  }

  Future<void> toggle(CollectionClip clip) {
    if (_clip?.id == clip.id && (_playing || _preparing)) return pause();
    return play(clip);
  }

  Future<void> play(CollectionClip clip, {bool replay = false}) {
    if (_disposed || !_active) return Future.value();
    final generation = ++_generation;
    final changingClip = _clip?.id != clip.id;
    _clip = clip;
    _preparing = true;
    _playing = false;
    _error = null;
    if (changingClip) {
      _duration = Duration(milliseconds: clip.durationMs);
      _position = Duration.zero;
      _completed = false;
    }
    notifyListeners();
    return _enqueue(() async {
      if (!_owns(generation)) return;
      try {
        final player = _getPlayer();
        await player.pause();
        if (!_owns(generation)) return;
        await onBeforePlay?.call();
        if (!_owns(generation)) return;
        if (_loadedClipId != clip.id) {
          final file = await repository.audioFile(clip);
          if (!_owns(generation)) return;
          if (!await file.exists()) {
            throw const FileSystemException('Saved clip is missing.');
          }
          if (!_owns(generation)) return;
          await player.setReleaseMode(ReleaseMode.stop);
          if (!_owns(generation)) return;
          await player.setSourceDeviceFile(file.path);
          _loadedClipId = clip.id;
          if (!_owns(generation)) return;
          final measuredDuration = await player.getDuration();
          if (!_owns(generation)) return;
          _duration =
              measuredDuration != null && measuredDuration > Duration.zero
              ? measuredDuration
              : Duration(milliseconds: clip.durationMs);
          _position = Duration.zero;
        }
        if (replay || _completed || _position >= _duration) {
          await player.seek(Duration.zero);
          if (!_owns(generation)) return;
          _position = Duration.zero;
        }
        _completed = false;
        await player.resume();
        if (!_owns(generation)) {
          await player.stop();
          return;
        }
        _playing = true;
      } catch (error) {
        if (_owns(generation)) {
          _playing = false;
          _error = error is FileSystemException
              ? 'The saved audio file is missing or unreadable. Save this clip again from Listening.'
              : 'Could not play this clip. Please try again.';
        }
      } finally {
        if (_owns(generation)) {
          _preparing = false;
          notifyListeners();
        }
      }
    });
  }

  Future<void> pause() {
    ++_generation;
    _playing = false;
    _preparing = false;
    if (!_disposed) notifyListeners();
    return _enqueue(() async {
      try {
        await _player?.pause();
      } catch (_) {}
    });
  }

  Future<void> stop() {
    ++_generation;
    _playing = false;
    _preparing = false;
    _completed = false;
    _position = Duration.zero;
    if (!_disposed) notifyListeners();
    return _enqueue(() async {
      try {
        await _player?.stop();
      } catch (_) {}
    });
  }

  Future<void> seek(Duration position) {
    if (_disposed || !_active || !canSeek) {
      return Future.value();
    }
    final generation = ++_generation;
    final target = _bounded(position);
    _position = target;
    _completed = false;
    notifyListeners();
    return _enqueue(() async {
      if (!_owns(generation)) return;
      try {
        await _player?.seek(target);
      } catch (_) {
        if (_owns(generation)) {
          _error = 'Could not seek in this clip. Please try again.';
          notifyListeners();
        }
      }
    });
  }

  Future<void> forget(String clipId) async {
    if (_clip?.id != clipId) return;
    await stop();
    if (_disposed || _clip?.id != clipId) return;
    _clip = null;
    _loadedClipId = null;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(
      _enqueue(() async {
        try {
          await _player?.stop();
        } catch (_) {}
        try {
          await _player?.dispose();
        } catch (_) {}
      }),
    );
    super.dispose();
  }
}
