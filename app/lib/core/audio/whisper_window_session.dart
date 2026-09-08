import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../ai/ai_models.dart';
import '../ai/ai_service.dart';
import '../ai/native_ai_bridge.dart';
import 'audio_models.dart';
import 'lesson_repository.dart';
import 'whisper_segmentation.dart';

/// One serial, cancellable worker per open lesson. Auto is deliberately absent:
/// recognition prepares durable cuts/text; the repeater decides what to display.
class WhisperWindowSession extends ChangeNotifier {
  final AudioLesson lesson;
  final LessonRepository repository;
  final AiService ai;
  List<AudioSegment> cuts;
  List<WhisperWindow> windows = [];
  final Set<int> completed = {};
  final Map<int, String> _errors = {};
  int _position = 0;
  bool _paused = true;
  bool _disposed = false;
  Future<void>? _work;
  String? _request;
  int? _workingIndex;
  int _epoch = 0;
  String? _initializationError;

  WhisperWindowSession({
    required this.lesson,
    required this.repository,
    required this.ai,
    required this.cuts,
  });

  WhisperWindow? get currentWindow {
    if (windows.isEmpty) return null;
    return windows.firstWhere(
      (w) => _position >= w.startMs && _position < w.endMs,
      orElse: () => windows.last,
    );
  }

  String? get error => _initializationError ?? _errors[currentWindow?.index];
  bool get pending =>
      currentWindow != null &&
      !completed.contains(currentWindow!.index) &&
      error == null;

  bool isCutVisible(AudioSegment cut) {
    // A finalized crossing sentence can extend into the next pending window.
    // Hide the current pending window altogether until its result is ready.
    if (_initializationError != null) return true;
    if (pending && currentWindow!.intersects(cut.startMs, cut.endMs)) {
      return false;
    }
    return windows.any(
      (w) =>
          w.intersects(cut.startMs, cut.endMs) &&
          (completed.contains(w.index) || _errors.containsKey(w.index)),
    );
  }

  Future<void> initialize(int positionMs) async {
    _position = positionMs;
    try {
      final stored = await repository.getSetting(
        'whisper_windows_${lesson.id}',
      );
      if (stored != null && stored.isNotEmpty) {
        final state = jsonDecode(stored) as Map<String, dynamic>;
        if (state['version'] == 1 &&
            state['path'] == lesson.localPath &&
            state['duration'] == lesson.durationMs) {
          windows = (state['windows'] as List).map((raw) {
            final w = raw as List;
            return WhisperWindow(
              index: w[0] as int,
              startMs: w[1] as int,
              endMs: w[2] as int,
              decodeStartMs: w[3] as int,
              decodeEndMs: w[4] as int,
              sourceDurationMs: lesson.durationMs,
            );
          }).toList();
          completed.addAll((state['completed'] as List).cast<int>());
        }
      }
      if (windows.isEmpty) {
        windows = WhisperSegmentation.plan(cuts, lesson.durationMs);
        await repository.setSetting(
          'whisper_windows_${lesson.id}',
          _encode(completed),
        );
      }
    } catch (e) {
      _initializationError = 'Could not prepare Whisper segments: $e';
    }
    if (!_disposed) notifyListeners();
  }

  String _encode(Set<int> done) => jsonEncode({
    'version': 1,
    'path': lesson.localPath,
    'duration': lesson.durationMs,
    'windows': windows
        .map(
          (w) => [w.index, w.startMs, w.endMs, w.decodeStartMs, w.decodeEndMs],
        )
        .toList(),
    'completed': done.toList(),
  });

  void updatePosition(int positionMs) {
    final before = currentWindow?.index;
    _position = positionMs;
    if (before == currentWindow?.index) return;
    // A newly visited, unfinished window takes priority over background work.
    if (pending && _workingIndex != currentWindow?.index && _request != null) {
      ++_epoch;
      unawaited(ai.speechEngine.cancelRequest(_request!));
    }
    if (!_disposed) notifyListeners();
    if (!_paused) resume();
  }

  void retry() {
    if (_initializationError != null) {
      _initializationError = null;
      unawaited(initialize(_position).then((_) => resume()));
      return;
    }
    _errors.clear();
    if (!_disposed) notifyListeners();
    resume();
  }

  void resume() {
    if (_disposed || _initializationError != null) return;
    _paused = false;
    if (_work != null) return;
    _work = _run().whenComplete(() {
      _work = null;
    });
  }

  Future<void> pause() async {
    _paused = true;
    ++_epoch;
    final request = _request;
    if (request != null) await ai.speechEngine.cancelRequest(request);
    await _work;
  }

  Future<void> _run() async {
    while (!_paused && !_disposed) {
      final queue = WhisperSegmentation.prioritize(windows, _position).where(
        (w) => !completed.contains(w.index) && !_errors.containsKey(w.index),
      );
      if (queue.isEmpty) return;
      var window = queue.first;
      if (!ai.speechEngine.isLoaded) {
        for (final w in windows.where((w) => !completed.contains(w.index))) {
          _errors[w.index] = 'Load a Whisper model in Settings.';
        }
        notifyListeners();
        return;
      }
      final timer = Stopwatch()..start();
      final epoch = _epoch;
      final snapshot = List<AudioSegment>.of(cuts);
      final model = ai.speechEngine.loadedModelPath ?? '';
      _workingIndex = window.index;
      debugPrint('[JLexaWhisper] window start lesson=${lesson.id} window=${window.index} range=${window.startMs}-${window.endMs}');
      try {
        WhisperRefinement? refined;
        // Extend only when a sentence reaches a context edge. Existing acoustic
        // bounds are retained if recognition still cannot resolve that edge.
        for (var attempt = 0; attempt < 3; attempt++) {
          final request = const Uuid().v4();
          _request = request;
          final engine = ai.speechEngine;
          final recognized = engine is NativeWhisperEngine
              ? await engine.transcribeCut(
                  audioPath: lesson.localPath,
                  lessonId: lesson.id,
                  cutId: 'window-${window.index}',
                  cutRevision: 0,
                  startMs: window.decodeStartMs,
                  endMs: window.decodeEndMs,
                  modelId: model,
                  requestId: request,
                  nThreads: ai.settings.threads,
                )
              : await engine.transcribeAudio(
                  audioPath: lesson.localPath,
                  lessonId: lesson.id,
                  requestId: request,
                  nThreads: ai.settings.threads,
                );
          if (_disposed ||
              _paused ||
              epoch != _epoch ||
              ai.speechEngine.loadedModelPath != model) {
            break;
          }
          refined = WhisperSegmentation.refine(
            window: window,
            recognized: recognized,
            acousticCuts: snapshot,
            existingCuts: snapshot,
            lessonId: lesson.id,
            modelId: model,
            protectedCutIds: snapshot
                .where(
                  (c) =>
                      c.isUserEdited ||
                      windows.any(
                        (w) =>
                            completed.contains(w.index) &&
                            w.intersects(c.startMs, c.endMs),
                      ),
                )
                .map((c) => c.id)
                .toSet(),
            protectedWindows: windows
                .where((w) => completed.contains(w.index))
                .toList(),
          );
          if (!refined.needsMoreContext) break;
          window = window.copyWith(
            decodeStartMs: max(0, window.decodeStartMs - 60000),
            decodeEndMs: min(lesson.durationMs, window.decodeEndMs + 60000),
          );
        }
        if (_disposed ||
            _paused ||
            epoch != _epoch ||
            refined == null ||
            ai.speechEngine.loadedModelPath != model) {
          continue;
        }
        final done = {...completed, window.index};
        await repository.commitWhisperWindow(
          lesson.id,
          {for (final cut in snapshot) cut.id: cut.revision},
          refined.cuts,
          _encode(done),
        );
        cuts = refined.cuts;
        completed.add(window.index);
        debugPrint(
          '[JLexaWhisper] window ready lesson=${lesson.id} '
          'window=${window.index} range=${window.startMs}-${window.endMs} cuts=${cuts.length} elapsedMs=${timer.elapsedMilliseconds}',
        );
      } catch (e) {
        if (!_disposed &&
            !_paused &&
            epoch == _epoch &&
            e is! AiCancelledException) {
          _errors[window.index] = 'Whisper segmentation failed: $e';
        }
      } finally {
        _request = null;
        _workingIndex = null;
        if (!_disposed) notifyListeners();
      }
      // Let playback, pointer input and pending model operations run first.
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(pause());
    super.dispose();
  }
}
