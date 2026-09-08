import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/whisper_cut_postprocessor.dart';

AudioSegment cut(
  String id,
  int start,
  int end, {
  int revision = 0,
  List<TranscriptToken> tokens = const [],
}) => AudioSegment(
  id: id,
  lessonId: 'lesson',
  startMs: start,
  endMs: end,
  text: '$id.',
  revision: revision,
  transcriptCutRevision: revision,
  transcriptModelId: 'whisper-tiny',
  tokens: tokens,
);

List<AudioSegment> process(
  List<AudioSegment> cuts, {
  AudioEnergyEnvelope? energy,
  Set<String>? eligible,
  Set<String>? pairs = const {},
  Set<String>? mergeCutIds,
}) => WhisperCutPostprocessor.process(
  cuts: cuts,
  energy: energy ?? AudioEnergyEnvelope(startMs: 0, stepMs: 10, values: []),
  eligibleIds: eligible ?? cuts.map((c) => c.id).toSet(),
  boundaryPairs: pairs,
  mergeCutIds: mergeCutIds,
);

List<(int, int)> bounds(List<AudioSegment> cuts) =>
    cuts.map((c) => (c.startMs, c.endMs)).toList();

void main() {
  test(
    'merge scope limits initiators, not their shorter eligible neighbor',
    () {
      final input = [
        cut('left', 0, 800),
        cut('short', 2000, 3000),
        cut('right', 4000, 6000),
      ];
      expect(process(input, mergeCutIds: {}), hasLength(3));
      final result = process(input, mergeCutIds: {'short'});
      expect(result.map((c) => c.text), ['left. short.', 'right.']);
    },
  );

  test('merged left id inherits right initiator scope for short chains', () {
    final scope = {'b'};
    final result = process([
      cut('a', 0, 300),
      cut('b', 300, 700),
      cut('c', 700, 1000),
    ], mergeCutIds: scope);
    expect(result.single.text, 'a. b. c.');
    expect(result.single.id, 'a');
    expect(result.single.revision, 2);
    expect(scope, {'b'});
  });

  test(
    'snaps to quietest shared point and preserves transcript and tokens',
    () {
      const token = TranscriptToken(text: 'left', startMs: 1600, endMs: 1950);
      final left = cut('left', 0, 2000, revision: 3, tokens: [token]);
      final right = cut('right', 2200, 5000, revision: 6);
      final values = List<double>.filled(500, 1)..[213] = .01;
      final result = process(
        [right, left],
        pairs: null,
        energy: AudioEnergyEnvelope(startMs: 0, stepMs: 10, values: values),
      );
      expect(bounds(result), [(0, 2135), (2135, 5000)]);
      expect(result.map((c) => c.id), ['left', 'right']);
      expect(result.map((c) => c.revision), [4, 7]);
      expect(result.every((c) => c.hasValidTranscript), true);
      expect(result.first.tokens.single, same(token));
      expect(left.endMs, 2000);
      expect(left.revision, 3);
      expect(right.startMs, 2200);
      expect(values[213], .01);
    },
  );

  test('equal energy chooses closest center to old midpoint, then earlier', () {
    final result = process(
      [cut('a', 0, 2000), cut('b', 2200, 5000)],
      pairs: null,
      energy: AudioEnergyEnvelope(
        startMs: 0,
        stepMs: 10,
        values: List.filled(500, .2),
      ),
    );
    expect(result.first.endMs, 2095);
  });

  test(
    'touching cuts also snap but already optimal boundaries do not revise',
    () {
      final energy = AudioEnergyEnvelope(
        startMs: 0,
        stepMs: 10,
        values: List<double>.filled(500, 1)..[201] = 0,
      );
      final result = process(
        [cut('a', 0, 2000), cut('b', 2000, 5000)],
        energy: energy,
        pairs: null,
      );
      expect(bounds(result), [(0, 2015), (2015, 5000)]);
      final again = process(result, energy: energy, pairs: null);
      expect(again.map((c) => c.revision), [1, 1]);
    },
  );

  test(
    '499ms gap uses actual point inside narrow intersection without a center',
    () {
      final result = process(
        [cut('a', 0, 2000), cut('b', 2499, 5000)],
        pairs: null,
        energy: AudioEnergyEnvelope(
          startMs: 0,
          stepMs: 10,
          values: List.filled(500, 1),
        ),
      );
      expect(result.first.endMs, inInclusiveRange(2249, 2250));
      expect(result.first.endMs, result.last.startMs);
      expect((result.first.endMs - 2000).abs(), lessThanOrEqualTo(250));
      expect((result.last.startMs - 2499).abs(), lessThanOrEqualTo(250));
    },
  );

  test('500ms gaps and overlapping cuts do not snap', () {
    final energy = AudioEnergyEnvelope(
      startMs: 0,
      stepMs: 10,
      values: List.filled(500, 0),
    );
    for (final start in [1999, 2500]) {
      final input = [cut('a', 0, 2000), cut('b', start, 5000)];
      expect(
        bounds(process(input, pairs: null, energy: energy)),
        bounds(input),
      );
    }
  });

  test(
    'short cuts remain nonempty while snapping and envelope time is absolute',
    () {
      final result = process(
        [cut('a', 3000, 3020), cut('b', 3020, 3040)],
        pairs: null,
        mergeCutIds: {},
        energy: AudioEnergyEnvelope(
          startMs: 2990,
          stepMs: 10,
          values: [0, .1, .2, .3, .4, 0],
        ),
      );
      expect(bounds(result), [(3000, 3005), (3005, 3040)]);
      expect(result.every((c) => c.durationMs > 0), true);
    },
  );

  test('a merge does not resnap a previously processed outer boundary', () {
    final a = cut('a', 0, 1000);
    final b = cut('b', 1500, 3500);
    final c = cut('c', 3600, 6000);
    final result = process(
      [a, b, c],
      pairs: {WhisperCutPostprocessor.pairKey(b, c)},
      energy: AudioEnergyEnvelope(
        startMs: 0,
        stepMs: 10,
        values: List.filled(600, 0),
      ),
    );
    expect(bounds(result), [(0, 3545), (3545, 6000)]);
    expect(result.map((s) => s.revision), [2, 1]);
  });

  test('missing or invalid energy never fabricates a boundary', () {
    final input = [cut('a', 0, 2000), cut('b', 2200, 5000)];
    for (final energy in [
      AudioEnergyEnvelope(startMs: 8000, stepMs: 10, values: [0]),
      AudioEnergyEnvelope(startMs: 0, stepMs: 10, values: []),
      AudioEnergyEnvelope(
        startMs: 1700,
        stepMs: 10,
        values: List.generate(100, (i) => i.isEven ? double.nan : -1),
      ),
    ]) {
      expect(
        bounds(process(input, energy: energy, pairs: null)),
        bounds(input),
      );
    }
    expect(
      () => AudioEnergyEnvelope(startMs: 0, stepMs: 0, values: []),
      throwsArgumentError,
    );
  });

  test('pair authorization is stable across revisions and limits snapping', () {
    final a = cut('a', 0, 2000);
    final b = cut('b', 2100, 4500);
    final c = cut('c', 4600, 7000);
    expect(
      WhisperCutPostprocessor.pairKey(a, b),
      WhisperCutPostprocessor.pairKey(a.copyWith(revision: 20), b),
    );
    final result = process(
      [a, b, c],
      pairs: {WhisperCutPostprocessor.pairKey(a, b)},
      energy: AudioEnergyEnvelope(
        startMs: 0,
        stepMs: 10,
        values: List.filled(700, 0),
      ),
    );
    expect(result[0].endMs, result[1].startMs);
    expect(result[1].endMs, 4500);
    expect(result[2].startMs, 4600);
  });

  test('short cut prefers shorter neighbor, with left winning a tie', () {
    for (final rightDuration in [2000, 3000]) {
      final result = process([
        cut('left', 0, 2000),
        cut('short', 3000, 4000),
        cut('right', 5000, 5000 + rightDuration),
      ]);
      expect(result.map((c) => c.text), ['left. short.', 'right.']);
      expect(result.first.endMs, 4000);
    }
    final rightPreferred = process([
      cut('left', 0, 3000),
      cut('short', 4000, 5000),
      cut('right', 6000, 8000),
    ]);
    expect(rightPreferred.map((c) => c.text), ['left.', 'short. right.']);
  });

  test('span includes gaps and exceeding preferred-side limit does not switch sides', () {
    final input = [
      cut('left', 0, 2000),
      cut('short', 20000, 21000),
      cut('right', 21000, 26000),
    ];
    expect(bounds(process(input)), bounds(input));
    expect(process([cut('a', 0, 1000), cut('b', 8000, 10000)]), hasLength(1));
    expect(process([cut('a', 0, 1000), cut('b', 8000, 10001)]), hasLength(2));
  });

  test('1500ms is not short and chains merge until no short cut can merge', () {
    expect(process([cut('a', 0, 1500), cut('b', 3000, 4500)]), hasLength(2));
    final result = process([
      cut('c', 3000, 4000),
      cut('a', 0, 1000),
      cut('b', 1500, 2500),
    ]);
    expect(bounds(result), [(0, 4000)]);
    expect(result.single.text, 'a. b. c.');
    expect(result.single.revision, 2);
  });

  test(
    'merge keeps absolute tokens and produces a valid new transcript revision',
    () {
      const a = TranscriptToken(text: 'a', startMs: 300, endMs: 700);
      const b = TranscriptToken(text: 'b', startMs: 2200, endMs: 3100);
      final left = cut('a', 0, 1000, revision: 2, tokens: [a]);
      final right = cut('b', 2000, 4000, revision: 5, tokens: [b]);
      final result = process([right, left]).single;
      expect(result.id, 'a');
      expect(result.text, 'a. b.');
      expect(result.revision, 6);
      expect(result.transcriptCutRevision, 6);
      expect(result.hasValidTranscript, true);
      expect(result.tokens, [a, b]);
      expect(result.tokens.first, same(a));
      expect(result.tokens.last.endMs, 3100);
      expect(left.endMs, 1000);
      expect(left.tokens, [a]);
      expect(right.tokens, [b]);
    },
  );

  test(
    'ineligible, edited, stale, acoustic and model-less cuts are barriers',
    () {
      final base = cut('barrier', 2000, 2500);
      final variants = [
        base.copyWith(isUserEdited: true),
        base.copyWith(transcriptCutRevision: 99),
        base.copyWith(clearTranscript: true),
        base.copyWith(transcriptModelId: ''),
        base,
      ];
      for (final barrier in variants) {
        final result = process([
          cut('a', 0, 1000),
          barrier,
          cut('c', 4000, 5000),
        ], eligible: identical(barrier, base) ? {'a', 'c'} : null);
        expect(result, hasLength(3));
        expect(result[1], same(barrier));
      }
    },
  );

  test(
    'short cut can merge with opposite eligible side of an immutable neighbor',
    () {
      final result = process([
        cut('left', 0, 2000).copyWith(isUserEdited: true),
        cut('short', 3000, 4000),
        cut('right', 5000, 8000),
      ]);
      expect(result.map((c) => c.text), ['left.', 'short. right.']);
      expect(result.first.isUserEdited, true);
    },
  );

  test('snapping requires both eligible cuts and same lesson', () {
    final a = cut('a', 0, 2000);
    final b = cut('b', 2100, 5000);
    final energy = AudioEnergyEnvelope(
      startMs: 0,
      stepMs: 10,
      values: List.filled(500, 0),
    );
    expect(
      bounds(process([a, b], energy: energy, pairs: null, eligible: {'a'})),
      [(0, 2000), (2100, 5000)],
    );
    expect(
      bounds(
        process(
          [a, b.copyWith(lessonId: 'other')],
          energy: energy,
          pairs: null,
        ),
      ),
      [(0, 2000), (2100, 5000)],
    );
  });
}
