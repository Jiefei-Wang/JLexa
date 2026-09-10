import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/whisper_cut_postprocessor.dart';
import 'package:jlexa/core/audio/whisper_long_cut_splitter.dart';

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/whisper_small_long_sentence.json').readAsStringSync(),
  );
  final original = AudioSegment.fromMap(
    Map<String, dynamic>.from(fixture['cut']),
  );
  final energy = AudioEnergyEnvelope(
    startMs: fixture['startMs'],
    stepMs: 10,
    values: (fixture['values'] as List)
        .cast<num>()
        .map((v) => v.toDouble())
        .toList(),
  );
  LongCutSplitResult split(AudioSegment cut, {AudioEnergyEnvelope? envelope}) =>
      WhisperLongCutSplitter.split(
        cuts: [cut],
        energy: envelope ?? energy,
        eligibleIds: {cut.id},
      );
  test('real Pixel sentence preserves clause integrity instead of enforcing ten seconds', () {
    final result = split(original);
    expect(result.cuts, hasLength(2));
    expect(result.cuts.last.durationMs > 10000, isTrue);
    expect(result.cuts.first.startMs, original.startMs);
    expect(result.cuts.last.endMs, original.endMs);
    expect(
      result.cuts.expand((c) => c.tokens).map((t) => t.toMap()),
      original.tokens.map((t) => t.toMap()),
    );
    expect(
      result.cuts.where((c) => c.text.contains('best-selling')),
      hasLength(1),
    );
    expect(result.cuts.every((c) => c.hasValidTranscript), isTrue);
    for (var i = 1; i < result.cuts.length; i++) {
      expect(result.cuts[i - 1].endMs, result.cuts[i].startMs);
    }
  });
  test(
    'fine adjustment remains inside the verified quiet word-boundary corridor',
    () {
      final result = split(original);
      final adjusted = WhisperCutPostprocessor.process(
        cuts: result.cuts,
        energy: energy,
        eligibleIds: result.cuts.map((c) => c.id).toSet(),
        boundaryLimits: result.boundaryLimits,
      );
      for (var i = 1; i < adjusted.length; i++) {
        final limit =
            result.boundaryLimits[WhisperCutPostprocessor.pairKey(
              adjusted[i - 1],
              adjusted[i],
            )]!;
        expect(
          adjusted[i].startMs,
          inInclusiveRange(limit.startMs, limit.endMs),
        );
        expect(adjusted[i - 1].endMs, adjusted[i].startMs);
      }
    },
  );
  test('continuous speech, missing timing, manual edits and insufficient energy remain whole', () {
    expect(
      split(
        original,
        envelope: AudioEnergyEnvelope(
          startMs: 87000,
          stepMs: 10,
          values: List.filled(2600, 1),
        ),
      ).cuts,
      [original],
    );
    expect(split(original.copyWith(tokens: [])).cuts, hasLength(1));
    expect(split(original.copyWith(isUserEdited: true)).cuts, hasLength(1));
    expect(
      split(
        original,
        envelope: AudioEnergyEnvelope(
          startMs: 90000,
          stepMs: 10,
          values: [0, 1],
        ),
      ).cuts,
      [original],
    );
  });
  List<AudioSegment> synthetic(String text) {
    final words = text.split(' ');
    final tokens = <TranscriptToken>[
      for (var i = 0; i < words.length; i++)
        TranscriptToken(
          text: ' ${words[i]}',
          startMs: i * 700,
          endMs: i * 700 + 400,
        ),
    ];
    final cut = AudioSegment(
      id: 'synthetic',
      lessonId: 'l',
      startMs: 0,
      endMs: words.length * 700,
      text: text,
      tokens: tokens,
      transcriptModelId: 'small.en',
    );
    final values = List<double>.generate(
      words.length * 70,
      (i) => i % 70 < 40 ? 1 : 0,
    );
    return WhisperLongCutSplitter.split(
      cuts: [cut],
      energy: AudioEnergyEnvelope(startMs: 0, stepMs: 10, values: values),
      eligibleIds: {cut.id},
    ).cuts;
  }

  for (final text in [
    'They have consistently celebrated highly skilled leaders in best-selling books and popular documentaries for many decades now',
    'We have carefully studied the very different roles of A and B in this complicated situation today',
    'We have consistently celebrated good leaders, capable managers, and experienced teachers in our community for many years',
    'They have carefully studied the river for many years and know exactly where to enter the water safely',
    'We have not only carefully studied the entire river but also patiently observed all the local currents today',
    'We have carefully considered whether either we should stay, or we should leave before the dangerous weather arrives',
  ]) {
    test('preserves phrase or shared-subject coordination: $text', () {
      expect(synthetic(text), hasLength(1));
    });
  }
  for (final connector in ['and', 'but', 'or']) {
    test('allows $connector between explicit clauses with an acoustic pause', () {
      final result = synthetic(
        'We have carefully studied the entire river for many years, $connector they have never examined the strong currents at this location',
      );
      expect(result, hasLength(2));
      expect(result.last.text, startsWith('$connector they have'));
      expect(result.first.text, endsWith('years,'));
    });
  }
  test(
    'real clause split preserves adverb-verb phrase and entire noun list',
    () {
      // The real fixture also tokenizes words into pieces; gating reads the
      // complete suffix rather than treating the first BPE piece as a word.
      final result = split(original);
      expect(result.cuts.first.text, endsWith('exploration,'));
      expect(result.cuts.last.text, startsWith('and in the century since'));
      expect(result.cuts.last.text, contains('consistently celebrated'));
      expect(
        result.cuts.last.text,
        contains('books, blogs, documentaries, podcasts'),
      );
    },
  );

  test('new cuts are idempotent and ineligible cuts are preserved', () {
    final result = split(original);
    final again = WhisperLongCutSplitter.split(
      cuts: result.cuts,
      energy: energy,
      eligibleIds: result.cuts.map((c) => c.id).toSet(),
    );
    expect(again.cuts, result.cuts);
    expect(
      WhisperLongCutSplitter.split(
        cuts: [original],
        energy: energy,
        eligibleIds: {},
      ).cuts,
      [original],
    );
  });
}
