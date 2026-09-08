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
import 'whisper_cut_postprocessor.dart';
import 'whisper_segmentation.dart';

/// One serial, cancellable worker per open lesson. Auto is deliberately absent:
/// recognition prepares durable cuts/text; the repeater decides what to display.
class WhisperWindowSession extends ChangeNotifier {
  final AudioLesson lesson;
  final LessonRepository repository;
  final AiService ai;
  final Future<AudioEnergyEnvelope> Function(int startMs, int endMs)?
  loadEnergy;
  List<AudioSegment> cuts;
  List<WhisperWindow> windows = [];
  final Set<int> completed = {};
  final Set<int> _polished = {};
  final Set<String> _adjustedPairs = {};
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
    this.loadEnergy,
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
      (!completed.contains(currentWindow!.index) ||
          (loadEnergy != null && !_polished.contains(currentWindow!.index))) &&
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
          if (state['polishVersion'] == 1) {
            _polished.addAll((state['polished'] as List? ?? []).cast<int>());
            _adjustedPairs.addAll(
              (state['adjustedPairs'] as List? ?? []).cast<String>(),
            );
          }
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

  String _encode(Set<int> done, {Set<int>? polished, Set<String>? pairs}) =>
      jsonEncode({
        'version': 1,
        'path': lesson.localPath,
        'duration': lesson.durationMs,
        'windows': windows
            .map(
              (w) => [
                w.index,
                w.startMs,
                w.endMs,
                w.decodeStartMs,
                w.decodeEndMs,
              ],
            )
            .toList(),
        'completed': done.toList(),
        'polishVersion': 1,
        'polished': (polished ?? _polished).toList(),
        'adjustedPairs': (pairs ?? _adjustedPairs).toList(),
      });

  void updatePosition(int positionMs) {
    final before = currentWindow?.index;
    _position = positionMs;
    if (before == currentWindow?.index) return;
    // A newly visited, unfinished window takes priority over background work.
    if (pending &&
        _workingIndex != null &&
        _workingIndex != currentWindow?.index) {
      ++_epoch;
      if (_request != null) unawaited(ai.speechEngine.cancelRequest(_request!));
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

  List<AudioSegment> _polish(
    List<AudioSegment> input,
    WhisperWindow window,
    Set<int> done,
    AudioEnergyEnvelope energy,
    Set<String> adjustedPairs,
  ) {
    bool ready(AudioSegment c) => windows.any(
      (w) =>
          done.contains(w.index) && w.contains(c.startMs + c.durationMs ~/ 2),
    );
    final eligible = input
        .where(
          (c) =>
              ready(c) &&
              !c.isUserEdited &&
              c.hasValidTranscript &&
              c.transcriptModelId?.trim().isNotEmpty == true,
        )
        .map((c) => c.id)
        .toSet();
    bool covered(AudioSegment a, AudioSegment b) =>
        a.endMs - 250 >= energy.startMs &&
        b.startMs + 250 <=
            energy.startMs + energy.values.length * energy.stepMs;
    final boundaryPairs = <String>{};
    final finishedPairs = {...adjustedPairs};
    for (var i = 1; i < input.length; i++) {
      final a = input[i - 1], b = input[i];
      final key = WhisperCutPostprocessor.pairKey(a, b);
      if (covered(a, b) &&
          eligible.contains(a.id) &&
          eligible.contains(b.id) &&
          b.startMs - a.endMs >= 0 &&
          b.startMs - a.endMs < 500) {
        if (!adjustedPairs.contains(key)) boundaryPairs.add(key);
        finishedPairs.add(key);
      }
    }
    final own = <int>[
      for (var i = 0; i < input.length; i++)
        if (window.intersects(input[i].startMs, input[i].endMs)) i,
    ];
    final mergeIds = <String>{};
    if (own.isNotEmpty) {
      for (
        var i = max(0, own.first - 1);
        i <= min(input.length - 1, own.last + 1);
        i++
      ) {
        // Do not choose a merge side before the neighboring window has supplied
        // its final sentences. The next window also revisits its two neighbors.
        final neighbors = [
          if (i > 0) input[i - 1],
          if (i + 1 < input.length) input[i + 1],
        ];
        if (input[i].startMs >= energy.startMs &&
            input[i].endMs <=
                energy.startMs + energy.values.length * energy.stepMs &&
            neighbors.every((c) => c.isUserEdited || ready(c))) {
          mergeIds.add(input[i].id);
        }
      }
    }
    final result = WhisperCutPostprocessor.process(
      cuts: input,
      energy: energy,
      eligibleIds: eligible,
      boundaryPairs: boundaryPairs,
      mergeCutIds: mergeIds,
    );
    final original = {for (final cut in input) cut.id: cut};
    for (final cut in result) {
      final old = original[cut.id];
      if (old != null &&
          (old.startMs != cut.startMs || old.endMs != cut.endMs)) {
        debugPrint(
          '[JLexaWhisper] polish cut=${cut.id} '
          'old=${old.startMs}-${old.endMs} new=${cut.startMs}-${cut.endMs}',
        );
      }
    }
    // Merging retains the left ID, so remember the resulting exterior pairs
    // too. Otherwise the same audio boundary could move another 250 ms later.
    final livePairs = <String>{};
    for (var i = 1; i < result.length; i++) {
      final a = result[i - 1], b = result[i];
      final key = WhisperCutPostprocessor.pairKey(a, b);
      livePairs.add(key);
      // The exterior boundary came from the original cut just before b;
      // that cut's ID may have disappeared into a during a short-cut merge.
      final originalRight = input.indexWhere((c) => c.id == b.id);
      if (originalRight > 0 &&
          finishedPairs.contains(
            WhisperCutPostprocessor.pairKey(
              input[originalRight - 1],
              input[originalRight],
            ),
          )) {
        adjustedPairs.add(key);
      }
    }
    adjustedPairs.retainAll(livePairs);
    return result;
  }

  Future<void> _run() async {
    while (!_paused && !_disposed) {
      final queue = WhisperSegmentation.prioritize(windows, _position).where(
        (w) =>
            (!completed.contains(w.index) ||
                (loadEnergy != null && !_polished.contains(w.index))) &&
            !_errors.containsKey(w.index),
      );
      if (queue.isEmpty) return;
      var window = queue.first;
      final needsRecognition = !completed.contains(window.index);
      if (needsRecognition && !ai.speechEngine.isLoaded) {
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
      debugPrint(
        '[JLexaWhisper] window start lesson=${lesson.id} window=${window.index} range=${window.startMs}-${window.endMs} stage=${needsRecognition ? "recognize" : "polish"}',
      );
      try {
        WhisperRefinement? refined = needsRecognition
            ? null
            : WhisperRefinement(cuts: snapshot);
        // Extend only when a sentence reaches a context edge. Existing acoustic
        // bounds are retained if recognition still cannot resolve that edge.
        for (var attempt = 0; needsRecognition && attempt < 3; attempt++) {
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
            (needsRecognition && ai.speechEngine.loadedModelPath != model)) {
          continue;
        }
        final done = {...completed, window.index};
        final polished = {..._polished};
        final pairs = {..._adjustedPairs};
        var resultCuts = refined.cuts;
        if (loadEnergy != null) {
          final energy = await loadEnergy!(
            window.decodeStartMs,
            window.decodeEndMs,
          );
          if (_disposed ||
              _paused ||
              epoch != _epoch ||
              (needsRecognition && ai.speechEngine.loadedModelPath != model)) {
            continue;
          }
          resultCuts = _polish(resultCuts, window, done, energy, pairs);
          polished.add(window.index);
        }
        await repository.commitWhisperWindow(
          lesson.id,
          {for (final cut in snapshot) cut.id: cut.revision},
          resultCuts,
          _encode(done, polished: polished, pairs: pairs),
        );
        cuts = resultCuts;
        completed.add(window.index);
        _polished.addAll(polished);
        _adjustedPairs
          ..clear()
          ..addAll(pairs);
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
