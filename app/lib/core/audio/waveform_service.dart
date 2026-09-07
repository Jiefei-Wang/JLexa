import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

abstract class IWaveformService {
  Future<List<double>> extractAndCacheWaveform(
    String audioPath,
    String lessonId,
    int durationMs,
  );
  Future<List<double>?> loadCachedWaveform(
    String lessonId, {
    int? fileSize,
    int? lastModified,
  });
  Future<void> deleteCachedWaveform(String lessonId);
  List<double> getWindowSlice({
    required List<double> fullPeaks,
    required int totalDurationMs,
    required int centerPositionMs,
    int windowDurationMs = 10000,
    int targetSamples = 100,
  });
}

class SpeechRegion {
  final int startMs;
  final int endMs;
  const SpeechRegion(this.startMs, this.endMs);
}

class WaveformBar {
  final double timeMs;
  final double amplitude;
  const WaveformBar(this.timeMs, this.amplitude);
}

class WaveformService implements IWaveformService {
  static const MethodChannel _whisperChannel = MethodChannel(
    'com.jlexa.app/whisper',
  );
  final Map<String, List<double>> _memoryCache = {};

  List<double>? _barSource;
  int _barDuration = 0;
  double _barStepMs = 0;
  List<WaveformBar> _bars = const [];

  /// Aggregate once on the file's time grid. Scrolling changes x coordinates,
  /// never the membership or amplitude of a bar's source samples.
  List<WaveformBar> windowBars({
    required List<double> peaks,
    required int durationMs,
    required int windowStartMs,
    int windowMs = 20000,
    int targetSamples = 160,
  }) {
    if (peaks.isEmpty ||
        durationMs <= 0 ||
        windowMs <= 0 ||
        targetSamples <= 0) {
      return const [];
    }
    final msPerPeak = durationMs / peaks.length;
    final step = max(msPerPeak, windowMs / targetSamples);
    if (!identical(peaks, _barSource) ||
        _barDuration != durationMs ||
        _barStepMs != step) {
      _barSource = peaks;
      _barDuration = durationMs;
      _barStepMs = step;
      _bars = List.generate((durationMs / step).ceil(), (i) {
        final start = i * step;
        final end = min(durationMs.toDouble(), start + step);
        // Include every source interval touching this fixed time bucket, so a
        // brief or quiet peak cannot fall between display samples.
        final firstPeak = (start / msPerPeak).floor();
        final lastPeak = min(peaks.length, (end / msPerPeak).ceil());
        var amplitude = 0.0;
        for (var j = firstPeak; j < lastPeak; j++) {
          amplitude = max(amplitude, peaks[j]);
        }
        return WaveformBar((start + end) / 2, amplitude);
      });
    }
    final first = max(0, (windowStartMs / step).floor() - 1);
    final last = min(
      _bars.length,
      ((windowStartMs + windowMs) / step).ceil() + 1,
    );
    return first >= last ? const [] : _bars.sublist(first, last);
  }

  /// Conservative phrase regions from real PCM peaks (normally every 50 ms).
  /// Display-only amplitude floors must never be applied to this input.
  List<SpeechRegion> detectSpeechRegions({
    required List<double> peaks,
    required int durationMs,
    int mergeGapMs = 650,
    int minimumSpeechMs = 100,
  }) {
    if (peaks.isEmpty || durationMs <= 0) return const [];
    final sorted = [...peaks]..sort();
    final percentile = (sorted.length * 0.2).floor().clamp(
      0,
      sorted.length - 1,
    );
    final noise = sorted[percentile];
    final onThreshold = max(0.008, noise * 2.8);
    final offThreshold = max(0.004, onThreshold * 0.8);
    final msPerPeak = durationMs / peaks.length;
    final raw = <SpeechRegion>[];
    int? start;
    var quietFrames = 0;
    final releaseFrames = max(1, (150 / msPerPeak).ceil());
    for (var i = 0; i < peaks.length; i++) {
      if (start == null) {
        if (peaks[i] >= onThreshold) {
          start = i;
          quietFrames = 0;
        }
      } else if (peaks[i] < offThreshold) {
        quietFrames++;
        if (quietFrames >= releaseFrames) {
          final endFrame = i - quietFrames + 1;
          raw.add(
            SpeechRegion(
              (start * msPerPeak).floor(),
              min(durationMs, (endFrame * msPerPeak).ceil()),
            ),
          );
          start = null;
          quietFrames = 0;
        }
      } else {
        quietFrames = 0;
      }
    }
    if (start != null) {
      raw.add(
        SpeechRegion(
          (start * msPerPeak).floor(),
          ((peaks.length - quietFrames) * msPerPeak).ceil().clamp(
            0,
            durationMs,
          ),
        ),
      );
    }
    // Group raw speech BEFORE padding: the pause tolerance must describe the
    // actual pause, not vary with the protective head/tail context below.
    final groups = <List<SpeechRegion>>[];
    for (final region in raw) {
      if (groups.isNotEmpty &&
          region.startMs - groups.last.last.endMs <= mergeGapMs) {
        groups.last.add(region);
      } else {
        groups.add([region]);
      }
    }

    final phrases = <SpeechRegion>[];
    void addPhrases(List<SpeechRegion> group) {
      final start = group.first.startMs, end = group.last.endMs;
      if (end - start < minimumSpeechMs) return;
      // A soft length limit: use the strongest internal pause, keeping at least
      // 2.5 seconds on either side. Continuous speech is never cut on a timer.
      if (end - start > 16000) {
        int? split;
        var bestGap = 349;
        var bestDistance = double.infinity;
        for (var i = 1; i < group.length; i++) {
          final before = group[i - 1], after = group[i];
          final gap = after.startMs - before.endMs;
          final distance =
              ((before.endMs + after.startMs) / 2 - (start + end) / 2).abs();
          if (before.endMs - start >= 2500 &&
              end - after.startMs >= 2500 &&
              (gap > bestGap || (gap == bestGap && distance < bestDistance))) {
            split = i;
            bestGap = gap;
            bestDistance = distance;
          }
        }
        if (split != null) {
          addPhrases(group.sublist(0, split));
          addPhrases(group.sublist(split));
          return;
        }
      }
      phrases.add(SpeechRegion(start, end));
    }

    for (final group in groups) {
      addPhrases(group);
    }

    // Preserve fast/soft leading words and trailing consonants. If two padded
    // neighbors meet, share only their silent gap; never trim detected speech.
    return [
      for (var i = 0; i < phrases.length; i++)
        SpeechRegion(
          max(
            max(0, phrases[i].startMs - 400),
            i == 0 ? 0 : (phrases[i - 1].endMs + phrases[i].startMs) ~/ 2,
          ),
          min(
            min(durationMs, phrases[i].endMs + 250),
            i == phrases.length - 1
                ? durationMs
                : (phrases[i].endMs + phrases[i + 1].startMs) ~/ 2,
          ),
        ),
    ];
  }

  String _buildCacheKey(String lessonId, int? fileSize, int? lastModified) {
    return '${lessonId}_${fileSize ?? 0}_${lastModified ?? 0}';
  }

  String _buildFileName(String lessonId, int? fileSize, int? lastModified) {
    // v3 imposed a display floor that cannot be undone. Re-extract raw peaks;
    // this cache migration does not regenerate any persisted user segments.
    if (fileSize != null &&
        fileSize > 0 &&
        lastModified != null &&
        lastModified > 0) {
      return 'v4_${lessonId}_${fileSize}_$lastModified.peaks';
    } else if (fileSize != null && fileSize > 0) {
      return 'v4_${lessonId}_$fileSize.peaks';
    }
    return 'v4_$lessonId.peaks';
  }

  @override
  Future<List<double>> extractAndCacheWaveform(
    String audioPath,
    String lessonId,
    int durationMs,
  ) async {
    int fileSize = 0;
    int lastModified = 0;
    final file = File(audioPath);
    if (await file.exists()) {
      try {
        fileSize = await file.length();
        lastModified = (await file.lastModified()).millisecondsSinceEpoch;
      } catch (_) {}
    }

    final memKey = _buildCacheKey(lessonId, fileSize, lastModified);
    if (_memoryCache.containsKey(memKey)) {
      return _memoryCache[memKey]!;
    }

    // Check disk cache
    final cached = await loadCachedWaveform(
      lessonId,
      fileSize: fileSize,
      lastModified: lastModified,
    );
    if (cached != null && cached.isNotEmpty) {
      _memoryCache[memKey] = cached;
      return cached;
    }

    // Compute peaks from file
    List<double> peaks = [];

    if (await file.exists()) {
      try {
        if (Platform.isAndroid) {
          // Native Android MediaCodec / WAV PCM peak extraction
          final dynamic raw = await _whisperChannel.invokeMethod(
            'extractAudioInfo',
            {
              'audioPath': audioPath,
              'numPeaks': max(100, (durationMs / 50).round()),
            },
          );
          if (raw is Map && raw['peaks'] is List) {
            peaks = (raw['peaks'] as List)
                .map((e) => (e as num).toDouble())
                .toList();
          }
        } else if (audioPath.toLowerCase().endsWith('.wav')) {
          peaks = await _extractFromWav(file, durationMs);
        }
      } catch (_) {
        peaks = [];
      }
    }

    if (peaks.isNotEmpty) {
      _memoryCache[memKey] = peaks;
      await _saveCachedWaveform(
        lessonId,
        peaks,
        fileSize: fileSize,
        lastModified: lastModified,
      );
    }

    return peaks;
  }

  @override
  Future<List<double>?> loadCachedWaveform(
    String lessonId, {
    int? fileSize,
    int? lastModified,
  }) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      // Only exact fingerprint match allowed
      final targetFileName = _buildFileName(lessonId, fileSize, lastModified);
      final file = File('${dir.path}/waveforms/$targetFileName');
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
      _memoryCache.removeWhere(
        (k, v) => k.startsWith('${lessonId}_') || k == lessonId,
      );
      final dir = await getApplicationDocumentsDirectory();
      final waveformsDir = Directory('${dir.path}/waveforms');
      if (await waveformsDir.exists()) {
        final files = await waveformsDir.list().toList();
        for (final f in files) {
          if (f is File) {
            final name = f.uri.pathSegments.last;
            if (name.contains(lessonId)) {
              await f.delete();
            }
          }
        }
      }
    } catch (_) {}
  }

  Future<void> saveCachedWaveform(
    String lessonId,
    List<double> peaks, {
    int? fileSize,
    int? lastModified,
  }) => _saveCachedWaveform(
    lessonId,
    peaks,
    fileSize: fileSize,
    lastModified: lastModified,
  );

  Future<void> _saveCachedWaveform(
    String lessonId,
    List<double> peaks, {
    int? fileSize,
    int? lastModified,
  }) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final waveformsDir = Directory('${dir.path}/waveforms');
      if (!await waveformsDir.exists()) {
        await waveformsDir.create(recursive: true);
      }
      final targetFileName = _buildFileName(lessonId, fileSize, lastModified);
      final file = File('${waveformsDir.path}/$targetFileName');
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

    if (dataOffset == -1 ||
        dataSize <= 0 ||
        channels <= 0 ||
        bitsPerSample != 16) {
      return [];
    }

    final totalSamples = dataSize ~/ 2;
    final totalFrames = totalSamples ~/ channels;
    final int pointsCount = max(
      100,
      (durationMs > 0 ? durationMs : (totalFrames * 1000 ~/ sampleRate)) ~/ 50,
    );
    final int blockSize = max(1, totalFrames ~/ pointsCount);
    final List<double> peaks = [];

    for (int frame = 0; frame < totalFrames; frame += blockSize) {
      double maxAmp = 0.0;
      final endFrame = min(frame + blockSize, totalFrames);
      for (int f = frame; f < endFrame; f += 2) {
        final samplePos = dataOffset + f * channels * 2;
        if (samplePos + 1 < bytes.length) {
          final sample = byteData.getInt16(samplePos, Endian.little);
          final norm = (sample.abs() / 32768.0).clamp(0.0, 1.0).toDouble();
          if (norm > maxAmp) maxAmp = norm;
        }
      }
      peaks.add(maxAmp.clamp(0.0, 1.0).toDouble());
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
        final int peakIndex = (currentMs / msPerPeak)
            .round()
            .clamp(0, fullPeaks.length - 1)
            .toInt();
        slice.add(fullPeaks[peakIndex]);
      }
    }

    return slice;
  }
}
