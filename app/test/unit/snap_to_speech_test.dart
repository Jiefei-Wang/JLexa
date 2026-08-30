import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/snap_to_speech.dart';

void main() {
  group('AmplitudeSnapToSpeechService Tests', () {
    late AmplitudeSnapToSpeechService snapService;

    setUp(() {
      snapService = AmplitudeSnapToSpeechService();
    });

    test('Snaps boundary toward local silence valley', () {
      // Create synthetic waveform with a dip at index 10 (which corresponds to 1000ms in a 2000ms / 20 samples file)
      final peaks = [
        0.8,
        0.8,
        0.7,
        0.8,
        0.9,
        0.7,
        0.8,
        0.6,
        0.4,
        0.1, // index 9 has low energy
        0.05, // index 10 has silence (0.05)
        0.1, 0.4, 0.7, 0.8, 0.9, 0.8, 0.7, 0.8, 0.8,
      ];
      const totalDurationMs = 2000;
      // Proposed cut at 850ms (near index 8 or 9)
      const proposedMs = 850;

      final snapped = snapService.snapBoundary(
        proposedPositionMs: proposedMs,
        waveformPeaks: peaks,
        totalDurationMs: totalDurationMs,
        searchWindowMs: 400,
      );

      // Index 10 is at 1000ms
      expect(snapped, equals(1000));
    });

    test('Does not snap if in high energy region without silence dip', () {
      final peaks = List.filled(20, 0.85); // Continuous loud speech
      const totalDurationMs = 2000;
      const proposedMs = 850;

      final snapped = snapService.snapBoundary(
        proposedPositionMs: proposedMs,
        waveformPeaks: peaks,
        totalDurationMs: totalDurationMs,
        searchWindowMs: 400,
      );

      expect(snapped, equals(proposedMs));
    });
  });
}
