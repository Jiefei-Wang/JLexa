import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

abstract class IWaveformService {
  Future<List<double>> extractAndCacheWaveform(String audioPath, String lessonId, int durationMs);
  Future<List<double>?> loadCachedWaveform(String lessonId);
  Future<void> deleteCachedWaveform(String lessonId);
  List<double> getWindowSlice({
    required List<double> fullPeaks,
    required int totalDurationMs,
    required int centerPositionMs,
    int windowDurationMs = 10000,
    int targetSamples = 100,
  });
}

class WaveformService implements IWaveformService {
  static const MethodChannel _whisperChannel = MethodChannel('com.jlexa.app/whisper');
  final Map<String, List<double>> _memoryCache = {};

  @override
  Future<List<double>> extractAndCacheWaveform(
    String audioPath,
    String lessonId,
    int durationMs,
  ) async {
    // Check cache in memory
    if (_memoryCache.containsKey(lessonId)) {
      return _memoryCache[lessonId]!;
    }

    // Check disk cache
    final cached = await loadCachedWaveform(lessonId);
    if (cached != null && cached.isNotEmpty) {
      _memoryCache[lessonId] = cached;
      return cached;
    }

    // Compute peaks from file
    List<double> peaks = [];
    final file = File(audioPath);

    if (await file.exists()) {
      try {
        if (Platform.isAndroid) {
          // Native Android MediaCodec / WAV PCM peak extraction
          final dynamic raw = await _whisperChannel.invokeMethod('extractAudioInfo', {
            'audioPath': audioPath,
            'numPeaks': max(100, (durationMs / 50).round()),
          });
          if (raw is Map && raw['peaks'] is List) {
            peaks = (raw['peaks'] as List).map((e) => (e as num).toDouble()).toList();
          }
        } else if (audioPath.toLowerCase().endsWith('.wav')) {
          peaks = await _extractFromWav(file, durationMs);
        }
      } catch (_) {
        peaks = [];
      }
    }

    if (peaks.isNotEmpty) {
      _memoryCache[lessonId] = peaks;
      await _saveCachedWaveform(lessonId, peaks);
    }

    return peaks;
  }

  @override
  Future<List<double>?> loadCachedWaveform(String lessonId) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/waveforms/v2_$lessonId.peaks');
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final floatList = Float32List.view(bytes.buffer);
        return floatList.map((e) => e.toDouble()).toList();
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> deleteCachedWaveform(String lessonId) async {
    try {
      _memoryCache.remove(lessonId);
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/waveforms/v2_$lessonId.peaks');
      if (await file.exists()) {
        await file.delete();
      }
      // Also delete any legacy cache file
      final legacyFile = File('${dir.path}/waveforms/$lessonId.peaks');
      if (await legacyFile.exists()) {
        await legacyFile.delete();
      }
    } catch (_) {}
  }

  Future<void> _saveCachedWaveform(String lessonId, List<double> peaks) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final waveformsDir = Directory('${dir.path}/waveforms');
      if (!await waveformsDir.exists()) {
        await waveformsDir.create(recursive: true);
      }
      final file = File('${waveformsDir.path}/v2_$lessonId.peaks');
      final float32 = Float32List.fromList(peaks);
      await file.writeAsBytes(float32.buffer.asUint8List());
    } catch (_) {}
  }

  Future<List<double>> _extractFromWav(File file, int durationMs) async {
    final bytes = await file.readAsBytes();
    if (bytes.length < 44) return [];

    // Parse RIFF chunks
    final byteData = ByteData.sublistView(bytes);
    if (byteData.getUint32(0, Endian.big) != 0x52494646) return []; // "RIFF"

    int offset = 12;
    int dataOffset = -1;
    int dataSize = 0;
    int channels = 1;
    int sampleRate = 16000;
    int bitsPerSample = 16;

    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = byteData.getUint32(offset + 4, Endian.little);

      if (chunkId == 'fmt ') {
        if (offset + 8 + 16 <= bytes.length) {
          channels = byteData.getUint16(offset + 10, Endian.little);
          sampleRate = byteData.getUint32(offset + 12, Endian.little);
          bitsPerSample = byteData.getUint16(offset + 22, Endian.little);
        }
      } else if (chunkId == 'data') {
        dataOffset = offset + 8;
        dataSize = min(chunkSize, bytes.length - dataOffset);
        break;
      }

      offset += 8 + chunkSize;
      if (chunkSize % 2 != 0) offset++;
    }

    if (dataOffset == -1 || dataSize <= 0 || channels <= 0 || bitsPerSample != 16) {
      return [];
    }

    final totalSamples = dataSize ~/ 2;
    final totalFrames = totalSamples ~/ channels;
    final int pointsCount = max(100, (durationMs > 0 ? durationMs : (totalFrames * 1000 ~/ sampleRate)) ~/ 50);
    final int blockSize = max(1, totalFrames ~/ pointsCount);
    final List<double> peaks = [];

    for (int frame = 0; frame < totalFrames; frame += blockSize) {
      double maxAmp = 0.0;
      final endFrame = min(frame + blockSize, totalFrames);
      for (int f = frame; f < endFrame; f += 2) {
        final samplePos = dataOffset + f * channels * 2;
        if (samplePos + 1 < bytes.length) {
          final sample = byteData.getInt16(samplePos, Endian.little);
          final norm = (sample.abs() / 32768.0).clamp(0.0, 1.0);
          if (norm > maxAmp) maxAmp = norm;
        }
      }
      peaks.add(maxAmp.clamp(0.02, 1.0));
    }

    return peaks;
  }

  @override
  List<double> getWindowSlice({
    required List<double> fullPeaks,
    required int totalDurationMs,
    required int centerPositionMs,
    int windowDurationMs = 10000,
    int targetSamples = 100,
  }) {
    if (fullPeaks.isEmpty || totalDurationMs <= 0) {
      return List.filled(targetSamples, 0.05);
    }

    final int halfWindowMs = windowDurationMs ~/ 2;
    final int startMs = centerPositionMs - halfWindowMs;

    final double msPerPeak = totalDurationMs / fullPeaks.length;
    final List<double> slice = [];

    for (int i = 0; i < targetSamples; i++) {
      final double currentMs = startMs + (i / targetSamples) * windowDurationMs;
      if (currentMs < 0 || currentMs > totalDurationMs) {
        slice.add(0.02); // Padding silence outside file bounds
      } else {
        final int peakIndex = (currentMs / msPerPeak).round().clamp(0, fullPeaks.length - 1);
        slice.add(fullPeaks[peakIndex]);
      }
    }

    return slice;
  }
}
