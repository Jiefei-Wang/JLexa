import 'dart:math' as math;

import 'audio_models.dart';
import 'whisper_cut_postprocessor.dart';

class LongCutSplitResult {
  final List<AudioSegment> cuts;
  final Map<String, ({int startMs, int endMs})> boundaryLimits;
  final Map<String, String> parents;
  const LongCutSplitResult(this.cuts, this.boundaryLimits, this.parents);
}

/// Phrase proposals precede the existing fine adjustment. A time budget alone
/// never creates an edge: every proposal needs a complete word and a quiet core.
class WhisperLongCutSplitter {
  static const targetMs = 10000;
  static const minimumMs = 2000;

  static LongCutSplitResult split({
    required List<AudioSegment> cuts,
    required AudioEnergyEnvelope energy,
    required Set<String> eligibleIds,
  }) {
    final output = <AudioSegment>[];
    final limits = <String, ({int startMs, int endMs})>{};
    final parents = <String, String>{};
    for (final cut in cuts) {
      final parts =
          eligibleIds.contains(cut.id) &&
              !cut.isUserEdited &&
              cut.hasValidTranscript &&
              cut.durationMs > targetMs &&
              cut.startMs >= energy.startMs &&
              cut.endMs <= energy.startMs + energy.values.length * energy.stepMs
          ? _divide(cut, energy)
          : <_Boundary>[];
      var tokenStart = 0;
      var start = cut.startMs;
      final children = <AudioSegment>[];
      for (var i = 0; i <= parts.length; i++) {
        if (parts.isEmpty) {
          children.add(cut);
          break;
        }
        final tokenEnd = i < parts.length
            ? parts[i].tokenIndex
            : cut.tokens.length;
        final end = i < parts.length ? parts[i].time : cut.endMs;
        final tokens = cut.tokens.sublist(tokenStart, tokenEnd);
        children.add(
          cut.copyWith(
            id: i == 0 ? cut.id : '${cut.id}_phrase_$tokenStart',
            startMs: start,
            endMs: end,
            tokens: tokens,
            text: tokens.map((t) => t.text).join().trim(),
            revision: cut.revision + 1,
            transcriptCutRevision: cut.revision + 1,
          ),
        );
        start = end;
        tokenStart = tokenEnd;
      }
      for (var i = 0; i < parts.length; i++) {
        limits[WhisperCutPostprocessor.pairKey(children[i], children[i + 1])] =
            (startMs: parts[i].lower, endMs: parts[i].upper);
      }
      for (final child in children) {
        parents[child.id] = cut.id;
      }
      output.addAll(children);
    }
    return LongCutSplitResult(output, limits, parents);
  }

  static List<_Boundary> _divide(AudioSegment cut, AudioEnergyEnvelope energy) {
    final tokens = cut.tokens;
    if (tokens.length < 2) return [];
    final candidates = <_Boundary>[];
    var wordStart = 0;
    for (var i = 1; i < tokens.length; i++) {
      final next = tokens[i];
      if (!RegExp(r'^\s+[A-Za-z0-9]').hasMatch(next.text)) continue;
      final leftTokens = tokens.sublist(wordStart, i);
      final leftText = leftTokens.map((t) => t.text).join().trim();
      wordStart = i;
      final leftWord = leftText.toLowerCase().replaceAll(
        RegExp(r"[^a-z'-]"),
        '',
      );
      // Gate on clause structure before considering acoustic energy. A comma
      // or a long pause alone does not make a phrase safe to split.
      if (!_clauseBoundary(tokens, i)) continue;
      // Never split a BPE word, hyphenated expression, or after a function word
      // that belongs to the following noun/verb phrase.
      if (leftText.endsWith('-') || leftText.endsWith("'")) continue;
      if (const {
        'a',
        'an',
        'the',
        'of',
        'to',
        'in',
        'on',
        'at',
        'for',
        'with',
        'by',
        'as',
        'and',
        'or',
        'but',
        'if',
        'that',
        'this',
        'these',
        'those',
        'my',
        'your',
        'his',
        'her',
        'our',
        'their',
        'is',
        'are',
        'was',
        'were',
        'be',
        'been',
        'being',
        'has',
        'have',
        'had',
        'will',
        'would',
        'can',
        'could',
        'should',
        'must',
        'not',
        'before',
        'after',
      }.contains(leftWord)) {
        continue;
      }
      final spoken = leftTokens
          .where((t) => RegExp(r'[A-Za-z0-9]').hasMatch(t.text))
          .toList();
      if (spoken.isEmpty ||
          next.endMs <= next.startMs ||
          next.confidence < .35) {
        continue;
      }
      final left = spoken.last;
      if (left.endMs <= left.startMs ||
          left.confidence < .35 ||
          left.endMs > next.startMs + 120) {
        continue;
      }
      final lower = math.max(cut.startMs + minimumMs, left.endMs - 120);
      final upper = math.min(cut.endMs - minimumMs, next.startMs + 120);
      if (lower >= upper) continue;
      final quiet = _quietCore(
        energy,
        lower,
        upper,
        (left.endMs + next.startMs) ~/ 2,
      );
      if (quiet == null) continue;
      candidates.add(_Boundary(i, quiet.$1, quiet.$2, quiet.$3, 0));
    }
    candidates.sort((a, b) => a.time.compareTo(b.time));
    // Dynamic programming avoids leaving a tiny tail. Overlong spans are legal
    // only when safe proposals cannot cover them; penalize them, never invent
    // timer boundaries or interpolate missing word timestamps.
    final nodes = [
      _Boundary(0, cut.startMs, cut.startMs, cut.startMs, 0),
      ...candidates,
      _Boundary(tokens.length, cut.endMs, cut.endMs, cut.endMs, 0),
    ];
    final costs = List<double>.filled(nodes.length, double.infinity);
    final previous = List<int>.filled(nodes.length, -1);
    costs[0] = 0;
    for (var j = 1; j < nodes.length; j++) {
      for (var i = 0; i < j; i++) {
        final length = nodes[j].time - nodes[i].time;
        if (length < minimumMs || nodes[j].tokenIndex <= nodes[i].tokenIndex) {
          continue;
        }
        final over = math.max(0, length - targetMs) / 1000;
        final cost =
            costs[i] +
            1.5 +
            math.pow((length - 7500) / 7500, 2) +
            (over > 0 ? 100 : 0) +
            over * over * 8 +
            (j == nodes.length - 1 ? 0 : nodes[j].penalty);
        if (cost < costs[j]) {
          costs[j] = cost.toDouble();
          previous[j] = i;
        }
      }
    }
    final selected = <_Boundary>[];
    var index = previous.last;
    while (index > 0) {
      selected.add(nodes[index]);
      index = previous[index];
    }
    return selected.reversed.toList();
  }

  // Deliberately narrow English clause recognizer, not a POS parser. Unknown
  // structures stay whole. In particular, shared-subject verbs and noun lists
  // do not qualify just because they contain and/or/but.
  static bool _clauseBoundary(List<TranscriptToken> tokens, int index) {
    final left = tokens.take(index).map((t) => t.text).join().toLowerCase();
    final right = tokens.skip(index).map((t) => t.text).join().toLowerCase();
    final connector = RegExp(
      r'^\s*(and|but|or|yet|so|because|although|though|whereas|while|unless|if)\b',
    ).firstMatch(right);
    if (connector == null) return false;
    final tail = left.split(RegExp(r'[,;.!?]')).last;
    // Correlative pairs remain together, even with a long acoustic pause.
    if (RegExp(r'\b(both|either|neither)\b|\bnot\s+(only|just)\b')
        .hasMatch(tail)) {
      return false;
    }
    if (RegExp(r'\b(either|neither)\b|\bnot\s+(only|just)\b').hasMatch(left)) {
      return false;
    }
    final name = connector.group(1)!;
    final comma = RegExp(r'[,;]\s*$').hasMatch(left);
    // Without punctuation, subordinators can introduce required complements
    // ("I wonder if ...", "we know because ..."). Decline that ambiguity.
    if (!{'and', 'but', 'or', 'yet', 'so'}.contains(name) && !comma) {
      return false;
    }
    final body = right.substring(connector.end).trimLeft();
    if (!_explicitClause(body, allowIntro: comma)) return false;
    return _explicitClause(left, allowIntro: true);
  }

  static bool _explicitClause(String text, {required bool allowIntro}) {
    // Contractions are expanded only for structural recognition, never in the
    // transcript. A short introductory adjunct is allowed before the subject.
    text = text
        .replaceAll('’', "'")
        .replaceAll(RegExp(r"\b(i|you|we|they)'re\b"), 'they are')
        .replaceAll(RegExp(r"\b(he|she|it)'s\b"), 'it is')
        .replaceAll(RegExp(r"\b(i|you|we|they)'ve\b"), 'they have')
        .replaceAll(RegExp(r"\b(i|you|he|she|it|we|they)'ll\b"), 'they will')
        .replaceAll("i'm", 'i am');
    const predicate =
        r'(?:am|is|are|was|were|has|have|had|do|does|did|can|could|will|would|shall|should|must|may|might|know|knows|knew|think|thinks|thought|want|wants|wanted|need|needs|needed|see|sees|saw|say|says|said|feel|feels|felt|work|works|worked|live|lives|lived|left|stayed|returned|arrived|failed|succeeded)';
    const subject =
        r'(?:i|you|he|she|it|we|they|there|one\s+of\s+(?:them|us)|(?:the|this|that|these|those|both\s+of\s+these)\s+(?!(?:and|or|but)\b)[a-z]+(?:\s+(?!(?:and|or|but)\b)[a-z]+){0,2})';
    const adverb =
        r'(?:(?:not|never|always|often|also|still|already|really|just|[a-z]+ly)\s+){0,2}';
    final match = RegExp('\\b$subject\\s+$adverb$predicate\\b')
        .firstMatch(text);
    if (match == null) return false;
    final intro = text.substring(0, match.start).trim();
    if (intro.isEmpty) return true;
    if (!allowIntro) return false;
    // Do not find a later subject by crossing another clause/list item.
    if (RegExp(r'\b(and|or|but|because|although|if|who|which|that)\b')
        .hasMatch(intro)) {
      return false;
    }
    return RegExp(r"[a-z]+(?:'[a-z]+)?").allMatches(intro).length <= 8;
  }

  static (int, int, int)? _quietCore(
    AudioEnergyEnvelope energy,
    int lower,
    int upper,
    int preferred,
  ) {
    final step = energy.stepMs;
    if (step > 20) return null;
    final contextStart = math.max(0, (lower - energy.startMs - 800) ~/ step);
    final contextEnd = math.min(
      energy.values.length,
      (upper - energy.startMs + 800) ~/ step,
    );
    if (contextStart >= contextEnd) return null;
    final sorted = energy.values.sublist(contextStart, contextEnd)..sort();
    final reference = sorted[(sorted.length * .75).floor()];
    if (!reference.isFinite || reference <= 1e-10) return null;
    final threshold = reference * .06;
    final first = math.max(0, ((lower - energy.startMs) / step).ceil());
    final last = math.min(
      energy.values.length,
      ((upper - energy.startMs) / step).floor(),
    );
    int? runStart;
    (int, int, int)? best;
    var bestScore = double.infinity;
    for (var i = first; i <= last; i++) {
      final quiet =
          i < last &&
          energy.values[i].isFinite &&
          energy.values[i] <= threshold;
      if (quiet) {
        runStart ??= i;
        continue;
      }
      if (runStart == null) continue;
      final start = energy.startMs + runStart * step;
      final end = energy.startMs + i * step;
      if (end - start >= 120) {
        final time = (start + end) ~/ 2;
        final score = (time - preferred).abs() - (end - start) * .25;
        if (score < bestScore) {
          bestScore = score;
          best = (time, start + 20, end - 20);
        }
      }
      runStart = null;
    }
    return best;
  }
}

class _Boundary {
  final int tokenIndex, time, lower, upper;
  final double penalty;
  const _Boundary(
    this.tokenIndex,
    this.time,
    this.lower,
    this.upper,
    this.penalty,
  );
}
