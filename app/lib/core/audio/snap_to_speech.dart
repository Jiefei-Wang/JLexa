import 'dart:math';

abstract class ISnapToSpeechService {
  int snapBoundary({
    required int proposedPositionMs,
    required List<double> waveformPeaks,
    required int totalDurationMs,
    int searchWindowMs = 400,
  });
}

class AmplitudeSnapToSpeechService implements ISnapToSpeechService {
  @override
  int snapBoundary({
    required int proposedPositionMs,
    required List<double> waveformPeaks,
    required int totalDurationMs,
    int searchWindowMs = 400,
  }) {
    if (waveformPeaks.isEmpty || totalDurationMs <= 0) {
      return proposedPositionMs;
    }

    final double msPerSample = totalDurationMs / waveformPeaks.length;
    final int sampleIndex = (proposedPositionMs / msPerSample)
        .round()
        .clamp(0, waveformPeaks.length - 1)
        .toInt();

    final int searchSamples = (searchWindowMs / msPerSample).round();
    final int startSample = max(0, sampleIndex - searchSamples);
    final int endSample = min(
      waveformPeaks.length - 1,
      sampleIndex + searchSamples,
    );

    if (startSample >= endSample) {
      return proposedPositionMs;
    }

    int minEnergyIndex = sampleIndex;
    double minEnergy = waveformPeaks[sampleIndex];

    for (int i = startSample; i <= endSample; i++) {
      if (waveformPeaks[i] < minEnergy) {
        minEnergy = waveformPeaks[i];
        minEnergyIndex = i;
      }
    }

    // Only snap if there is a noticeable local dip/valley
    if (minEnergy < 0.3) {
      final int snappedMs = (minEnergyIndex * msPerSample).round();
      return snappedMs.clamp(0, totalDurationMs).toInt();
    }

    return proposedPositionMs;
  }
}
