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
  test('real Pixel Small sentence fits ten seconds without losing words or splitting compounds', () {
    final result = split(original);
    expect(result.cuts, hasLength(3));
    expect(
      result.cuts.every((c) => c.durationMs <= 10000 && c.durationMs >= 2000),
      isTrue,
    );
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
