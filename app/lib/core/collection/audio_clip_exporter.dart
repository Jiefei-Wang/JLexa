import 'package:flutter/services.dart';

abstract interface class AudioClipExporter {
  Future<int> exportClip({
    required String audioPath,
    required int startMs,
    required int endMs,
    required String outputPath,
  });
}

class NativeAudioClipExporter implements AudioClipExporter {
  static const _channel = MethodChannel('com.jlexa.app/whisper');

  @override
  Future<int> exportClip({
    required String audioPath,
    required int startMs,
    required int endMs,
    required String outputPath,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'exportAudioClip',
      {
        'audioPath': audioPath,
        'startMs': startMs,
        'endMs': endMs,
        'outputPath': outputPath,
      },
    );
    final durationMs = (result?['durationMs'] as num?)?.toInt() ?? 0;
    if (result?['path'] != outputPath || durationMs <= 0) {
      throw StateError('Audio clip export did not produce a valid file.');
    }
    return durationMs;
  }
}
