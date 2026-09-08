import 'audio_models.dart';

/// A disjoint scheduling region and the larger audio range decoded for context.
class WhisperWindow {
  final int index, startMs, endMs, decodeStartMs, decodeEndMs;
  final int? sourceDurationMs;

  const WhisperWindow({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.decodeStartMs,
    required this.decodeEndMs,
    this.sourceDurationMs,
  });

  bool intersects(int start, int end) => start < endMs && end > startMs;
  bool contains(int positionMs) => positionMs >= startMs && positionMs < endMs;
  bool get reachesSourceEnd => decodeEndMs == (sourceDurationMs ?? endMs);

  WhisperWindow copyWith({int? decodeStartMs, int? decodeEndMs}) =>
      WhisperWindow(
        index: index,
        startMs: startMs,
        endMs: endMs,
        decodeStartMs: decodeStartMs ?? this.decodeStartMs,
        decodeEndMs: decodeEndMs ?? this.decodeEndMs,
        sourceDurationMs: sourceDurationMs,
      );
}

class WhisperRefinement {
  /// buildCandidates returns proposals; refine returns the entire merged list.
  final List<AudioSegment> cuts;
  final bool needsMoreContext;
  final int? deferredStartMs, deferredEndMs;
  const WhisperRefinement({
    required this.cuts,
    this.needsMoreContext = false,
    this.deferredStartMs,
    this.deferredEndMs,
  });
}

class WhisperSegmentation {
  static const int targetWindowMs = 60000;
  static const int contextMs = 15000;

  /// Move a minute boundary to the nearest acoustic speech edge. An unbroken
  /// acoustic region may make a window longer than a minute; speech is not cut
  /// at a timer boundary merely to keep the work units equally sized.
  static List<WhisperWindow> plan(
    List<AudioSegment> acousticCuts,
    int durationMs,
  ) {
    if (durationMs <= 0) return const [];
    final regions = <(int, int)>[];
    final sorted = acousticCuts.where((c) => c.endMs > c.startMs).toList()
      ..sort(_compare);
    for (final cut in sorted) {
      final start = cut.startMs.clamp(0, durationMs);
      final end = cut.endMs.clamp(0, durationMs);
      if (end <= start) continue;
      if (regions.isNotEmpty && start < regions.last.$2) {
        final last = regions.removeLast();
        regions.add((last.$1, end > last.$2 ? end : last.$2));
      } else {
        regions.add((start, end));
      }
    }
    final windows = <WhisperWindow>[];
    var start = 0;
    while (start < durationMs) {
      final target = (start + targetWindowMs).clamp(0, durationMs);
      var end = target;
      for (final region in regions) {
        if (region.$1 < target && region.$2 > target) {
          final earlier = region.$1;
          final later = region.$2;
          end =
              earlier >= start + targetWindowMs ~/ 2 &&
                  target - earlier < later - target
              ? earlier
              : later;
          break;
        }
      }
      windows.add(
        WhisperWindow(
          index: windows.length,
          startMs: start,
          endMs: end,
          decodeStartMs: (start - contextMs).clamp(0, durationMs),
          decodeEndMs: (end + contextMs).clamp(0, durationMs),
          sourceDurationMs: durationMs,
        ),
      );
      start = end;
    }
    return windows;
  }

  static List<WhisperWindow> prioritize(
    List<WhisperWindow> windows,
    int positionMs,
  ) {
    final result = List<WhisperWindow>.of(windows);
    int distance(WhisperWindow w) => w.contains(positionMs)
        ? 0
        : positionMs < w.startMs
        ? w.startMs - positionMs
        : positionMs - w.endMs + 1;
    result.sort((a, b) {
      final order = distance(a).compareTo(distance(b));
      return order == 0 ? a.index.compareTo(b.index) : order;
    });
    return result;
  }

  /// Recognition and token timestamps must already be absolute lesson times.
  /// A sentence intersecting the scheduling region is kept whole, including
  /// its context outside that region. No word timestamps are interpolated.
  static WhisperRefinement buildCandidates({
    required WhisperWindow window,
    required List<AudioSegment> recognized,
    required List<AudioSegment> acousticCuts,
    required String lessonId,
    required String modelId,
  }) {
    final units = <_Unit>[];
    final ordered = List<AudioSegment>.of(recognized)..sort(_compare);
    for (final segment in ordered) {
      if (segment.text.trim().isEmpty || segment.endMs <= segment.startMs) {
        continue;
      }
      final tokens = segment.tokens
          .where((t) => t.text.isNotEmpty && !t.text.startsWith('<|'))
          .toList();
      if (tokens.isEmpty) {
        units.add(
          _Unit(
            segment.text,
            segment.startMs,
            segment.endMs,
            segment.confidence,
            const [],
          ),
        );
      } else {
        var previousEnd = segment.startMs;
        for (final token in tokens) {
          // Whisper punctuation tokens can have zero/unavailable timestamps.
          // Keep them in decoder order and anchor them to the preceding word.
          final hasTime =
              token.endMs > token.startMs &&
              token.startMs >= segment.startMs &&
              token.endMs <= segment.endMs;
          final start = hasTime ? token.startMs : previousEnd;
          final end = hasTime ? token.endMs : previousEnd;
          final anchored = TranscriptToken(
            text: token.text,
            startMs: start,
            endMs: end,
            confidence: token.confidence,
          );
          units.add(
            _Unit(token.text, start, end, token.confidence, [anchored]),
          );
          previousEnd = end;
        }
      }
    }
    final groups = <List<_Unit>>[];
    var group = <_Unit>[];
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (group.isNotEmpty && unit.start - group.last.end >= 1200) {
        groups.add(group);
        group = [];
      }
      group.add(unit);
      final joined = group.map((u) => u.text).join();
      final decimal =
          RegExp(r'\d\.$').hasMatch(joined) &&
          i + 1 < units.length &&
          RegExp(r'^\d').hasMatch(units[i + 1].text);
      if (_endsSentence(joined) && !decimal) {
        groups.add(group);
        group = [];
      }
    }
    if (group.isNotEmpty) groups.add(group);
    final proposals = <AudioSegment>[];
    final fallback = <String, AudioSegment>{};
    int? deferredStart, deferredEnd;
    for (final sentence in groups) {
      final start = sentence.first.start;
      final end = sentence.map((u) => u.end).reduce((a, b) => a > b ? a : b);
      if (end <= start || !window.intersects(start, end)) continue;
      final leading =
          window.decodeStartMs > 0 && start <= window.decodeStartMs + 500;
      final trailing =
          !window.reachesSourceEnd &&
          ((!_endsSentence(sentence.map((u) => u.text).join()) &&
                  end >= window.decodeEndMs - 1500) ||
              (end >= window.decodeEndMs - 500 &&
                  acousticCuts.any(
                    (c) =>
                        c.startMs < window.decodeEndMs &&
                        c.endMs > window.decodeEndMs,
                  )));
      if (leading || trailing) {
        if (leading) {
          deferredStart = deferredStart == null || start < deferredStart
              ? start
              : deferredStart;
        }
        if (trailing) {
          deferredEnd = deferredEnd == null || end > deferredEnd
              ? end
              : deferredEnd;
        }
        for (final acoustic in acousticCuts) {
          if (_overlaps(acoustic.startMs, acoustic.endMs, start, end) &&
              window.intersects(acoustic.startMs, acoustic.endMs)) {
            fallback[acoustic.id] = acoustic.copyWith(clearTranscript: true);
          }
        }
        continue;
      }
      final tokens = sentence.expand((u) => u.tokens).toList();
      final text = StringBuffer();
      for (final unit in sentence) {
        // Token text contains BPE whitespace; segment-only text does not.
        if (unit.tokens.isEmpty && text.isNotEmpty) text.write(' ');
        text.write(unit.text);
      }
      proposals.add(
        AudioSegment(
          id: '${lessonId}_whisper_${start}_$end',
          lessonId: lessonId,
          startMs: start,
          endMs: end,
          text: text.toString().trim(),
          confidence:
              sentence.map((u) => u.confidence).reduce((a, b) => a + b) /
              sentence.length,
          tokens: tokens,
          revision: 0,
          transcriptCutRevision: 0,
          transcriptModelId: modelId,
        ),
      );
    }
    // If context was insufficient, preserve an entire acoustic region rather
    // than presenting a silently truncated sentence or fabricated transcript.
    proposals.removeWhere(
      (p) => fallback.values.any((a) => _overlapCuts(a, p)),
    );
    proposals.addAll(fallback.values);
    proposals.sort(_compare);
    final disjoint = <AudioSegment>[];
    for (final p in proposals) {
      if (disjoint.isEmpty || !_overlapCuts(disjoint.last, p)) {
        disjoint.add(p);
      } else {
        // Decoder word timestamps can overlap at sentence boundaries. Keep
        // both sentences in one cut rather than dropping words or guessing
        // which side owns the overlap.
        final previous = disjoint.removeLast();
        final end = previous.endMs > p.endMs ? previous.endMs : p.endMs;
        final complete = previous.hasValidTranscript && p.hasValidTranscript;
        disjoint.add(
          AudioSegment(
            id: '${lessonId}_whisper_${previous.startMs}_$end',
            lessonId: lessonId,
            startMs: previous.startMs,
            endMs: end,
            text: complete ? '${previous.text} ${p.text}' : '',
            tokens: complete ? [...previous.tokens, ...p.tokens] : const [],
            confidence: complete
                ? (previous.confidence + p.confidence) / 2
                : -1,
            transcriptCutRevision: complete ? 0 : null,
            transcriptModelId: complete ? modelId : null,
          ),
        );
      }
    }
    return WhisperRefinement(
      cuts: disjoint,
      needsMoreContext: deferredStart != null || deferredEnd != null,
      deferredStartMs: deferredStart,
      deferredEndMs: deferredEnd,
    );
  }

  static WhisperRefinement refine({
    required WhisperWindow window,
    required List<AudioSegment> recognized,
    required List<AudioSegment> existingCuts,
    required String lessonId,
    required String modelId,
    List<AudioSegment>? acousticCuts,
    Set<String> protectedCutIds = const {},
    List<WhisperWindow> protectedWindows = const [],
  }) {
    final proposed = buildCandidates(
      window: window,
      recognized: recognized,
      acousticCuts: acousticCuts ?? existingCuts,
      lessonId: lessonId,
      modelId: modelId,
    );
    bool inProtectedWindow(AudioSegment c) =>
        protectedWindows.any((w) => w.contains(c.startMs + c.durationMs ~/ 2));
    bool protected(AudioSegment c) =>
        c.isUserEdited ||
        protectedCutIds.contains(c.id) ||
        inProtectedWindow(c);
    final protectedCuts = existingCuts.where(protected).toList();
    final rejected = proposed.cuts
        .where(
          (c) =>
              inProtectedWindow(c) ||
              protectedCuts.any((p) => _overlapCuts(p, c)),
        )
        .toList();
    final accepted = proposed.cuts
        .where(
          (c) =>
              !inProtectedWindow(c) &&
              !protectedCuts.any((p) => _overlapCuts(p, c)),
        )
        .toList();
    final merged = existingCuts
        .where(
          (c) =>
              protected(c) ||
              ((!window.contains(c.startMs + c.durationMs ~/ 2) ||
                      rejected.any((p) => _overlapCuts(p, c))) &&
                  !accepted.any((p) => _overlapCuts(p, c))),
        )
        .toList();
    merged.addAll(accepted);
    merged.sort(_compare);
    return WhisperRefinement(
      cuts: merged,
      needsMoreContext: proposed.needsMoreContext,
      deferredStartMs: proposed.deferredStartMs,
      deferredEndMs: proposed.deferredEndMs,
    );
  }

  static bool _endsSentence(String text) {
    final value = text.trimRight();
    if (RegExp(
      r'\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc)\.$',
      caseSensitive: false,
    ).hasMatch(value)) {
      return false;
    }
    return RegExp(r'''[.!?。！？]["”’')\]]*$''').hasMatch(value);
  }

  static int _compare(AudioSegment a, AudioSegment b) {
    final order = a.startMs.compareTo(b.startMs);
    if (order != 0) return order;
    final end = a.endMs.compareTo(b.endMs);
    return end != 0 ? end : a.id.compareTo(b.id);
  }

  static bool _overlaps(int a, int b, int c, int d) => a < d && c < b;
  static bool _overlapCuts(AudioSegment a, AudioSegment b) =>
      _overlaps(a.startMs, a.endMs, b.startMs, b.endMs);
}

class _Unit {
  final String text;
  final int start, end;
  final double confidence;
  final List<TranscriptToken> tokens;
  const _Unit(this.text, this.start, this.end, this.confidence, this.tokens);
}
