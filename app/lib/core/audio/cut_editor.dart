import 'audio_models.dart';

/// Pure, snapshot-based cut editing rules. Intervals are always [start, end).
class CutEditResult {
  final List<AudioSegment> cuts;
  final Set<String> changedIds;
  final Set<String> deletedIds;

  const CutEditResult(this.cuts, this.changedIds, this.deletedIds);
}

class CutEditor {
  static CutEditResult split({
    required List<AudioSegment> snapshot,
    required String cutId,
    required int expectedRevision,
    required int splitMs,
    required String rightCutId,
    required int durationMs,
  }) {
    final ordered = [...snapshot]
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final targetIndex = ordered.indexWhere(
      (cut) => cut.id == cutId && cut.revision == expectedRevision,
    );
    if (targetIndex < 0 || durationMs <= 0) {
      throw StateError('Cut changed while it was being split.');
    }
    final target = ordered[targetIndex];
    if (splitMs <= target.startMs || splitMs >= target.endMs) {
      throw ArgumentError('The split point must be inside the cut.');
    }
    if (rightCutId == cutId || ordered.any((cut) => cut.id == rightCutId)) {
      throw ArgumentError('The new cut id must be unique.');
    }

    final left = target.copyWith(
      endMs: splitMs,
      revision: target.revision + 1,
      isUserEdited: true,
      clearTranscript: true,
    );
    final right = AudioSegment(
      id: rightCutId,
      lessonId: target.lessonId,
      startMs: splitMs,
      endMs: target.endMs,
      text: '',
      confidence: -1,
      isUserEdited: true,
    );
    ordered
      ..removeAt(targetIndex)
      ..insertAll(targetIndex, [left, right]);
    validate(ordered, durationMs);
    return CutEditResult(ordered, {left.id, right.id}, const {});
  }

  static CutEditResult resize({
    required List<AudioSegment> snapshot,
    required String cutId,
    required int expectedRevision,
    required int newStartMs,
    required int newEndMs,
    required int durationMs,
  }) {
    final ordered = [...snapshot]
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final targetIndex = ordered.indexWhere(
      (c) => c.id == cutId && c.revision == expectedRevision,
    );
    if (targetIndex < 0 || durationMs <= 0) {
      throw StateError('Cut changed while it was being edited.');
    }
    final start = newStartMs.clamp(0, durationMs).toInt();
    final end = newEndMs.clamp(0, durationMs).toInt();
    if (start >= end) throw ArgumentError('A cut must have positive length.');

    final changed = <String>{cutId};
    final deleted = <String>{};
    final result = <AudioSegment>[];
    for (final cut in ordered) {
      if (cut.id == cutId) {
        result.add(
          cut.copyWith(
            startMs: start,
            endMs: end,
            revision: cut.revision + 1,
            isUserEdited: true,
            clearTranscript: true,
          ),
        );
        continue;
      }
      if (cut.endMs <= start || cut.startMs >= end) {
        result.add(cut);
        continue;
      }

      // The target covers this cut completely.
      if (cut.startMs >= start && cut.endMs <= end) {
        deleted.add(cut.id);
        continue;
      }

      // Partial overlap: retain the side outside the target. Since the input
      // is non-overlapping, only one side can remain.
      final clippedStart = cut.startMs < start ? cut.startMs : end;
      final clippedEnd = cut.startMs < start ? start : cut.endMs;
      if (clippedStart < clippedEnd) {
        result.add(
          cut.copyWith(
            startMs: clippedStart,
            endMs: clippedEnd,
            revision: cut.revision + 1,
            isUserEdited: true,
            clearTranscript: true,
          ),
        );
        changed.add(cut.id);
      } else {
        deleted.add(cut.id);
      }
    }
    result.sort((a, b) => a.startMs.compareTo(b.startMs));
    validate(result, durationMs);
    return CutEditResult(result, changed, deleted);
  }

  static void validate(List<AudioSegment> cuts, int durationMs) {
    int previousEnd = 0;
    for (var i = 0; i < cuts.length; i++) {
      final cut = cuts[i];
      if (cut.startMs < 0 ||
          cut.startMs >= cut.endMs ||
          cut.endMs > durationMs) {
        throw StateError('Invalid cut range ${cut.id}.');
      }
      if (i > 0 && cut.startMs < previousEnd) {
        throw StateError('Cuts overlap.');
      }
      previousEnd = cut.endMs;
    }
  }

  static ({int startMs, int endMs}) gapAt(
    List<AudioSegment> cuts,
    int positionMs,
    int durationMs,
  ) {
    var left = 0;
    var right = durationMs;
    for (final cut in cuts) {
      if (cut.containsPosition(positionMs)) {
        throw StateError('The playhead is already inside a cut.');
      }
      if (cut.endMs <= positionMs && cut.endMs > left) left = cut.endMs;
      if (cut.startMs > positionMs && cut.startMs < right) right = cut.startMs;
    }
    return (startMs: left, endMs: right);
  }
}

/// An edit mode keeps the original neighbors until the whole session is saved.
/// Each explicit adjustment replaces that cut's previous request, so retreating
/// restores even fully covered neighbors and never fills an original gap.
class CutBoundarySession {
  final List<AudioSegment> snapshot;
  final int durationMs;
  final Map<String, ({int? startMs, int? endMs})> _requests = {};
  late List<AudioSegment> _current = snapshot;

  CutBoundarySession(List<AudioSegment> cuts, this.durationMs)
    : snapshot = List.unmodifiable(cuts);

  ({int? startMs, int? endMs}) _request(String id, int startMs, int endMs) {
    final current = _current.firstWhere((c) => c.id == id);
    final previous = _requests[id];
    // An untouched edge may have been compressed by a neighbor. It must not
    // become an explicit edit merely because the other handle was moved.
    return (
      startMs: startMs != current.startMs ? startMs : previous?.startMs,
      endMs: endMs != current.endMs ? endMs : previous?.endMs,
    );
  }

  List<AudioSegment> preview(String id, int startMs, int endMs) {
    final requests = {..._requests}..remove(id);
    requests[id] = _request(id, startMs, endMs);
    var cuts = snapshot;
    for (final entry in requests.entries) {
      final index = cuts.indexWhere((c) => c.id == entry.key);
      if (index < 0) continue; // Covered by another explicitly edited cut.
      final cut = cuts[index];
      final start = entry.value.startMs ?? cut.startMs;
      final end = entry.value.endMs ?? cut.endMs;
      if (cut.startMs == start && cut.endMs == end) continue;
      cuts = CutEditor.resize(
        snapshot: cuts,
        cutId: cut.id,
        expectedRevision: cut.revision,
        newStartMs: start,
        newEndMs: end,
        durationMs: durationMs,
      ).cuts;
    }
    return cuts;
  }

  List<AudioSegment> resize(String id, int startMs, int endMs) {
    final request = _request(id, startMs, endMs);
    final cuts = preview(id, startMs, endMs);
    _requests.remove(id);
    _requests[id] = request;
    _current = cuts;
    return cuts;
  }
}
