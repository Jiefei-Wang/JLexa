import 'dart:convert';
import 'dart:math' as math;

import 'audio_models.dart';

/// Mean-square energy for consecutive bins on the source audio timeline.
class AudioEnergyEnvelope {
  final int startMs;
  final int stepMs;
  final List<double> values;

  AudioEnergyEnvelope({
    required this.startMs,
    required this.stepMs,
    required List<double> values,
  }) : values = List.unmodifiable(values) {
    if (stepMs <= 0) {
      throw ArgumentError.value(stepMs, 'stepMs', 'Must be positive');
    }
  }
}

class WhisperCutPostprocessor {
  static String pairKey(AudioSegment left, AudioSegment right) =>
      jsonEncode([left.id, right.id]);

  static List<AudioSegment> process({
    required List<AudioSegment> cuts,
    required AudioEnergyEnvelope energy,
    required Set<String> eligibleIds,
    Set<String>? boundaryPairs,
    Set<String>? mergeCutIds,
  }) {
    final mergeInitiators = mergeCutIds == null
        ? null
        : Set<String>.of(mergeCutIds);
    final result = List<AudioSegment>.of(cuts)
      ..sort((a, b) {
        final start = a.startMs.compareTo(b.startMs);
        if (start != 0) return start;
        final end = a.endMs.compareTo(b.endMs);
        return end != 0 ? end : a.id.compareTo(b.id);
      });
    bool editable(AudioSegment cut) =>
        eligibleIds.contains(cut.id) &&
        !cut.isUserEdited &&
        cut.durationMs > 0 &&
        cut.hasValidTranscript &&
        cut.transcriptModelId?.trim().isNotEmpty == true;

    // Snap each authorized original adjacency once, before any merges.
    for (var i = 0; i + 1 < result.length; i++) {
      final left = result[i];
      final right = result[i + 1];
      final gap = right.startMs - left.endMs;
      if (!editable(left) ||
          !editable(right) ||
          left.lessonId != right.lessonId ||
          gap < 0 ||
          gap >= 500 ||
          (boundaryPairs != null &&
              !boundaryPairs.contains(pairKey(left, right)))) {
        continue;
      }
      final lower = math.max(
        math.max(left.endMs - 250, right.startMs - 250),
        left.startMs + 1,
      );
      final upper = math.min(
        math.min(left.endMs + 250, right.startMs + 250),
        right.endMs - 1,
      );
      final boundary = _quietest(
        energy,
        lower,
        upper,
        (left.endMs + right.startMs) / 2,
      );
      if (boundary == null) continue;
      if (left.endMs != boundary) {
        result[i] = left.copyWith(
          endMs: boundary,
          revision: left.revision + 1,
          transcriptCutRevision: left.revision + 1,
        );
      }
      if (right.startMs != boundary) {
        result[i + 1] = right.copyWith(
          startMs: boundary,
          revision: right.revision + 1,
          transcriptCutRevision: right.revision + 1,
        );
      }
    }

    // Restart after a merge so newly formed short cuts get the same rules.
    var changed = true;
    while (changed) {
      changed = false;
      for (var i = 0; i < result.length; i++) {
        final cut = result[i];
        if (!editable(cut) ||
            cut.durationMs >= 1500 ||
            (mergeInitiators != null && !mergeInitiators.contains(cut.id))) {
          continue;
        }
        bool available(int index) =>
            index >= 0 &&
            index < result.length &&
            editable(result[index]) &&
            result[index].lessonId == cut.lessonId;
        final hasLeft = available(i - 1);
        final hasRight = available(i + 1);
        if (!hasLeft && !hasRight) continue;
        final neighbor =
            hasLeft &&
                (!hasRight ||
                    result[i - 1].durationMs <= result[i + 1].durationMs)
            ? i - 1
            : i + 1;
        final first = math.min(i, neighbor);
        final last = math.max(i, neighbor);
        final left = result[first];
        final right = result[last];
        final end = math.max(left.endMs, right.endMs);
        if (end - left.startMs > 10000) continue;
        final revision = math.max(left.revision, right.revision) + 1;
        result[first] = left.copyWith(
          endMs: end,
          text: '${left.text.trim()} ${right.text.trim()}',
          tokens: List.unmodifiable([...left.tokens, ...right.tokens]),
          confidence: math.min(left.confidence, right.confidence),
          revision: revision,
          transcriptCutRevision: revision,
        );
        result.removeAt(last);
        if (mergeInitiators != null) {
          final mayContinue =
              mergeInitiators.contains(left.id) ||
              mergeInitiators.contains(right.id);
          mergeInitiators.removeAll([left.id, right.id]);
          if (mayContinue) mergeInitiators.add(left.id);
        }
        changed = true;
        break;
      }
    }
    return result;
  }

  static int? _quietest(
    AudioEnergyEnvelope energy,
    int lower,
    int upper,
    double oldMidpoint,
  ) {
    if (lower > upper || energy.values.isEmpty) return null;
    final halfStep = energy.stepMs / 2;
    final firstCenter = ((lower - energy.startMs - halfStep) / energy.stepMs)
        .ceil();
    final lastCenter = ((upper - energy.startMs - halfStep) / energy.stepMs)
        .floor();
    final hasCenters = firstCenter <= lastCenter;
    final first = math.max(
      0,
      hasCenters
          ? firstCenter
          : ((lower - energy.startMs) / energy.stepMs).floor(),
    );
    final last = math.min(
      energy.values.length - 1,
      hasCenters
          ? lastCenter
          : ((upper - energy.startMs) / energy.stepMs).floor(),
    );
    int? best;
    var bestEnergy = double.infinity;
    var bestDistance = double.infinity;
    for (var i = first; i <= last; i++) {
      final value = energy.values[i];
      if (!value.isFinite || value < 0) continue;
      final binStart = energy.startMs + i * energy.stepMs;
      final point = hasCenters
          ? (binStart + halfStep).round().clamp(lower, upper)
          : oldMidpoint.round().clamp(
              math.max(lower, binStart),
              math.min(upper, binStart + energy.stepMs - 1),
            );
      final distance = (point - oldMidpoint).abs();
      if (value < bestEnergy ||
          (value == bestEnergy && distance < bestDistance)) {
        best = point.toInt();
        bestEnergy = value;
        bestDistance = distance;
      }
    }
    return best;
  }
}
