import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/whisper_segmentation.dart';

AudioSegment cut(
  String id,
  int start,
  int end, {
  String text = '',
  bool edited = false,
  List<TranscriptToken> tokens = const [],
}) => AudioSegment(
  id: id,
  lessonId: 'lesson',
  startMs: start,
  endMs: end,
  text: text,
  isUserEdited: edited,
  tokens: tokens,
);

const first = WhisperWindow(
  index: 0,
  startMs: 0,
  endMs: 60000,
  decodeStartMs: 0,
  decodeEndMs: 75000,
  sourceDurationMs: 120000,
);
const second = WhisperWindow(
  index: 1,
  startMs: 60000,
  endMs: 120000,
  decodeStartMs: 45000,
  decodeEndMs: 120000,
  sourceDurationMs: 120000,
);

WhisperRefinement candidates(
  WhisperWindow window,
  List<AudioSegment> recognized, {
  List<AudioSegment> acoustic = const [],
}) => WhisperSegmentation.buildCandidates(
  window: window,
  recognized: recognized,
  acousticCuts: acoustic,
  lessonId: 'lesson',
  modelId: 'tiny',
);

void main() {
  test('minute boundaries move to acoustic gaps and never split speech', () {
    final acoustic = [
      cut('a', 1000, 7000),
      cut('b', 50000, 70000),
      cut('c', 118000, 130000),
    ];
    final windows = WhisperSegmentation.plan(acoustic, 180000);
    expect(windows.first.endMs, 70000);
    expect(windows.first.decodeEndMs, 85000);
    expect(windows.last.endMs, 180000);
    for (var i = 0; i < windows.length; i++) {
      final w = windows[i];
      expect(w.decodeStartMs, greaterThanOrEqualTo(0));
      expect(w.decodeEndMs, lessThanOrEqualTo(180000));
      expect(w.endMs, greaterThan(w.startMs));
      if (i > 0) expect(w.startMs, windows[i - 1].endMs);
      expect(
        acoustic.any((c) => c.startMs < w.endMs && c.endMs > w.endMs),
        false,
      );
    }
  });

  test('continuous speech is not cut merely to enforce one minute', () {
    final windows = WhisperSegmentation.plan([
      cut('speech', 0, 150000),
    ], 160000);
    expect(windows.first.endMs, 150000);
    expect(windows.last.endMs, 160000);
  });

  test(
    'planner handles silence, invalid bounds and active-window priority',
    () {
      expect(WhisperSegmentation.plan([], 0), isEmpty);
      final windows = WhisperSegmentation.plan([cut('bad', 300, 100)], 150000);
      expect(windows.map((w) => w.endMs), [60000, 120000, 150000]);
      expect(
        WhisperSegmentation.prioritize(windows, 70000).map((w) => w.index),
        [1, 0, 2],
      );
      expect(WhisperSegmentation.prioritize(windows, 60000).first.index, 1);
    },
  );

  test(
    'whole crossing sentence is available whichever adjacent window runs first',
    () {
      final recognized = [
        cut('raw1', 55000, 59000, text: 'We walked through'),
        cut('raw2', 60500, 67000, text: 'the park together.'),
      ];
      // The pause here is less than the long-gap split threshold.
      final joined = [recognized.first.copyWith(endMs: 59500), recognized.last];
      for (final window in [first, second]) {
        final result = candidates(window, joined);
        expect(result.needsMoreContext, false);
        expect(result.cuts, hasLength(1));
        expect(result.cuts.single.startMs, 55000);
        expect(result.cuts.single.endMs, 67000);
        expect(result.cuts.single.text, 'We walked through the park together.');
        expect(result.cuts.single.hasValidTranscript, true);
        expect(result.cuts.single.transcriptModelId, 'tiny');
      }
    },
  );

  test('timestamped punctuation splits sentences but preserves decoder word timing', () {
    final raw = cut(
      'raw',
      1000,
      4000,
      text: 'Hello. How are you?',
      tokens: [
        const TranscriptToken(text: 'Hello', startMs: 1000, endMs: 1500),
        const TranscriptToken(text: '.', startMs: 0, endMs: 0),
        const TranscriptToken(text: ' How', startMs: 1600, endMs: 2100),
        const TranscriptToken(text: ' are', startMs: 2100, endMs: 2400),
        const TranscriptToken(text: ' you?', startMs: 2400, endMs: 4000),
      ],
    );
    final result = candidates(first, [raw]);
    expect(result.cuts.map((c) => c.text), ['Hello.', 'How are you?']);
    expect(result.cuts.map((c) => (c.startMs, c.endMs)), [
      (1000, 1500),
      (1600, 4000),
    ]);
    expect(result.cuts.first.tokens.last.endMs, 1500);
  });

  test('common abbreviations and decimal punctuation do not split', () {
    final raw = cut(
      'raw',
      1000,
      6000,
      text: 'Dr. Lee paid 3.14 dollars.',
      tokens: [
        const TranscriptToken(text: 'Dr', startMs: 1000, endMs: 1500),
        const TranscriptToken(text: '.'),
        const TranscriptToken(text: ' Lee paid ', startMs: 1600, endMs: 3000),
        const TranscriptToken(text: '3', startMs: 3000, endMs: 3300),
        const TranscriptToken(text: '.'),
        const TranscriptToken(text: '14', startMs: 3300, endMs: 4000),
        const TranscriptToken(text: ' dollars.', startMs: 4000, endMs: 6000),
      ],
    );
    expect(
      candidates(first, [raw]).cuts.single.text,
      'Dr. Lee paid 3.14 dollars.',
    );
  });

  test('long silence separates phrases and retained gaps remain empty', () {
    final result = candidates(first, [
      cut('a', 1000, 2000, text: 'Hello'),
      cut('b', 5000, 7000, text: 'Over here!'),
    ]);
    expect(result.cuts.map((c) => (c.startMs, c.endMs)), [
      (1000, 2000),
      (5000, 7000),
    ]);
    expect(candidates(first, []).cuts, isEmpty);
  });

  test(
    'truncated tail requests extension and keeps full acoustic fallback',
    () {
      final acoustic = [cut('speech', 55000, 90000)];
      final raw = [
        cut(
          'raw',
          55000,
          74500,
          text: 'A sentence that continues beyond this context',
        ),
      ];
      final result = candidates(first, raw, acoustic: acoustic);
      expect(result.needsMoreContext, true);
      expect(result.deferredEndMs, 74500);
      expect(result.cuts.single.id, 'speech');
      expect(result.cuts.single.endMs, 90000);
      expect(result.cuts.single.text, isEmpty);
      expect(result.cuts.single.hasValidTranscript, false);
      final expanded = candidates(first.copyWith(decodeEndMs: 120000), [
        cut(
          'full',
          55000,
          88000,
          text: 'A sentence that continues beyond this context and finishes.',
        ),
      ]);
      expect(expanded.needsMoreContext, false);
      expect(expanded.cuts.single.endMs, 88000);
    },
  );

  test(
    'leading fragment requests earlier context, true source start does not',
    () {
      final raw = [
        cut(
          'raw',
          45000,
          68000,
          text: 'the incomplete beginning of a sentence.',
        ),
      ];
      final result = candidates(
        second,
        raw,
        acoustic: [cut('a', 39000, 69000)],
      );
      expect(result.needsMoreContext, true);
      expect(result.deferredStartMs, 45000);
      expect(result.cuts.single.startMs, 39000);
      expect(result.cuts.single.text, '');
      expect(
        candidates(first, [
          cut('raw', 0, 1000, text: 'Hello.'),
        ]).needsMoreContext,
        false,
      );
    },
  );

  test('true EOF accepts a sentence without punctuation', () {
    final result = candidates(second, [
      cut('raw', 110000, 119900, text: 'The final sentence'),
    ]);
    expect(result.needsMoreContext, false);
    expect(result.cuts.single.text, 'The final sentence');
  });

  test(
    'crossing proposals replace overlapping acoustic cuts outside owned window',
    () {
      final result = WhisperSegmentation.refine(
        window: second,
        recognized: [
          cut('raw', 55000, 67000, text: 'A full crossing sentence.'),
        ],
        existingCuts: [
          cut('before', 4000, 6000),
          cut('left', 54000, 59000),
          cut('right', 60500, 68000),
          cut('after', 130000, 132000),
        ],
        lessonId: 'lesson',
        modelId: 'tiny',
      );
      expect(result.cuts.map((c) => c.id), [
        'before',
        'lesson_whisper_55000_67000',
        'after',
      ]);
    },
  );

  test('protected manual cuts and deleted holes cannot be resurrected', () {
    final manual = cut(
      'manual',
      58000,
      63000,
      text: 'My correction',
      edited: true,
    );
    final result = WhisperSegmentation.refine(
      window: second,
      recognized: [
        cut('cross', 55000, 67000, text: 'Overwrite attempt.'),
        cut('deleted', 40000, 61000, text: 'Deleted sentence.'),
      ],
      existingCuts: [manual, cut('pending', 80000, 81000)],
      protectedWindows: [first],
      lessonId: 'lesson',
      modelId: 'tiny',
    );
    expect(result.cuts, [manual]);
    expect(result.cuts.single.text, 'My correction');
  });

  test('out-of-order completion is deterministic and overlapping context deduplicates', () {
    final acoustic = [
      cut('a', 5000, 10000),
      cut('crossing', 55000, 67000),
      cut('b', 80000, 85000),
    ];
    final recognized = [
      cut('ra', 5000, 10000, text: 'First.'),
      cut('rc', 55000, 67000, text: 'The crossing sentence.'),
      cut('rb', 80000, 85000, text: 'Last.'),
    ];
    List<AudioSegment> process(List<WhisperWindow> order) {
      var existing = acoustic;
      final protected = <String>{};
      final completed = <WhisperWindow>[];
      for (final w in order) {
        final result = WhisperSegmentation.refine(
          window: w,
          recognized: recognized
              .where(
                (c) => c.startMs >= w.decodeStartMs && c.endMs <= w.decodeEndMs,
              )
              .toList(),
          existingCuts: existing,
          acousticCuts: acoustic,
          protectedCutIds: protected,
          protectedWindows: completed,
          lessonId: 'lesson',
          modelId: 'tiny',
        );
        existing = result.cuts;
        protected.addAll(
          existing.where((c) => c.hasValidTranscript).map((c) => c.id),
        );
        completed.add(w);
      }
      return existing;
    }

    final forward = process([first, second]);
    final reverse = process([second, first]);
    expect(
      forward.map((c) => c.toMap()).toList(),
      reverse.map((c) => c.toMap()).toList(),
    );
    expect(forward, hasLength(3));
    expect(forward[1].text, 'The crossing sentence.');
  });
  test('protected sentence conflict retains adjacent acoustic speech', () {
    final manual = cut('manual', 10000, 12000, text: 'My edit', edited: true);
    final acoustic = cut('keep', 12000, 15000);
    final result = WhisperSegmentation.refine(
      window: first,
      recognized: [
        cut(
          'proposal',
          9000,
          15000,
          text: 'A sentence spanning the manual edit.',
        ),
      ],
      existingCuts: [manual, acoustic],
      lessonId: 'lesson',
      modelId: 'tiny',
    );
    expect(result.cuts.map((c) => c.id), ['manual', 'keep']);
    expect(result.cuts.first.text, 'My edit');
  });

  test(
    'period at a continuing acoustic context edge still needs extension',
    () {
      final result = candidates(
        first,
        [cut('raw', 55000, 74990, text: 'It has not really ended.')],
        acoustic: [cut('speech', 54000, 90000)],
      );
      expect(result.needsMoreContext, true);
      expect(result.cuts.single.startMs, 54000);
      expect(result.cuts.single.endMs, 90000);
      expect(result.cuts.single.text, isEmpty);
    },
  );
  test('timestamp overlap merges whole sentences without dropping words', () {
    final result = candidates(first, [
      cut('one', 1000, 3000, text: 'First sentence.'),
      cut('two', 2900, 5000, text: 'Second sentence.'),
    ]);
    expect(result.cuts, hasLength(1));
    expect(result.cuts.single.startMs, 1000);
    expect(result.cuts.single.endMs, 5000);
    expect(result.cuts.single.text, 'First sentence. Second sentence.');
    expect(result.cuts.single.hasValidTranscript, true);
  });
}
