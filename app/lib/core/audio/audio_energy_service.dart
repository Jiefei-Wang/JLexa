import 'package:flutter/services.dart';

import 'whisper_cut_postprocessor.dart';

/// Small 10 ms energy envelopes; PCM stays in the Android decoder.
class AudioEnergyService {
  static const _channel = MethodChannel('com.jlexa.app/whisper');

  static Future<AudioEnergyEnvelope> load(
    String path,
    int startMs,
    int endMs,
  ) async {
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'getAudioEnergy',
      {'audioPath': path, 'startMs': startMs, 'endMs': endMs},
    );
    if (raw == null || raw['values'] is! List || raw['stepMs'] != 10) {
      throw StateError('Could not read audio energy for segment refinement.');
    }
    final values = (raw['values'] as List)
        .map((v) => (v as num).toDouble())
        .toList();
    if (values.isEmpty || values.any((v) => !v.isFinite || v < 0)) {
      throw StateError('Audio energy data is empty or invalid.');
    }
    return AudioEnergyEnvelope(
      startMs: (raw['startMs'] as num).toInt(),
      stepMs: 10,
      values: values,
    );
  }
}
