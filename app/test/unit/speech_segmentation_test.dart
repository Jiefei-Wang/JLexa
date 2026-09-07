import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/waveform_service.dart';

import '../test_helper.dart';

void main() {
  final service = WaveformService();
  List<SpeechRegion> detect(List<double> peaks) =>
      service.detectSpeechRegions(peaks: peaks, durationMs: peaks.length * 50);

  test('Soft fast onset and trailing consonants remain inside the phrase', () {
    final cuts = detect([
      ...List.filled(20, .001),
      ...List.filled(6, .006), // quiet leading words below the onset threshold
      ...List.filled(24, .15),
      ...List.filled(4, .003), // soft trailing consonants
      ...List.filled(24, .001),
    ]);
    expect(cuts, hasLength(1));
    expect(cuts.single.startMs, lessThanOrEqualTo(1000));
    expect(cuts.single.endMs, greaterThanOrEqualTo(2700));
  });

  test(
    'Normal 600 ms hesitation stays within a phrase; long silence stays out',
    () {
      final cuts = detect([
        ...List.filled(20, .001),
        ...List.filled(20, .4),
        ...List.filled(12, .001),
        ...List.filled(30, .3),
        ...List.filled(50, .001),
        ...List.filled(30, .4),
        ...List.filled(20, .001),
      ]);
      expect(cuts, hasLength(2));
      expect(cuts.first.startMs, lessThan(1000));
      expect(cuts.first.endMs, greaterThan(4100));
      expect(cuts.last.startMs - cuts.first.endMs, greaterThan(1700));
    },
  );

  test(
    'Quiet speech is retained while silence and a single click create no cuts',
    () {
      expect(detect(List.filled(100, 0)), isEmpty);
      expect(detect(List.filled(100, .01)), isEmpty);
      expect(
        detect([...List.filled(40, .001), .9, ...List.filled(40, .001)]),
        isEmpty,
      );
      expect(
        detect([
          ...List.filled(20, .001),
          ...List.filled(20, .02),
          ...List.filled(20, .001),
        ]),
        hasLength(1),
      );
    },
  );

  test(
    'Long continuous speech has no arbitrary cut; real pauses may split it',
    () {
      final uninterrupted = detect([
        ...List.filled(200, .001),
        ...List.filled(450, .4),
        ...List.filled(200, .001),
      ]);
      expect(uninterrupted, hasLength(1));
      final paused = detect([
        ...List.filled(200, .001),
        ...List.filled(200, .4),
        ...List.filled(10, .001),
        ...List.filled(200, .4),
        ...List.filled(200, .001),
      ]);
      expect(paused, hasLength(2));
      expect(paused.first.endMs, greaterThanOrEqualTo(20000));
      expect(paused.last.startMs, lessThanOrEqualTo(20500));
      expect(paused.first.endMs, lessThanOrEqualTo(paused.last.startMs));
    },
  );

  test('TED reaction phrase is whole, and all produced bounds are valid', () {
    final data = jsonDecode(
      File('test/fixtures/ted_speech_envelope.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final peaks = (data['peaks'] as List)
        .cast<num>()
        .map((v) => v.toDouble())
        .toList();
    final cuts = service.detectSpeechRegions(
      peaks: peaks,
      durationMs: data['durationMs'],
    );
    // Absolute source interval 26.4–28.95 s; this excerpt starts at 10 s.
    expect(
      cuts.where((c) => c.startMs <= 16400 && c.endMs >= 18950),
      hasLength(1),
    );
    for (var i = 0; i < cuts.length; i++) {
      expect(cuts[i].startMs, greaterThanOrEqualTo(0));
      expect(cuts[i].endMs, lessThanOrEqualTo(data['durationMs']));
      expect(cuts[i].startMs, lessThan(cuts[i].endMs));
      if (i > 0) {
        expect(cuts[i].startMs, greaterThanOrEqualTo(cuts[i - 1].endMs));
      }
    }
  });

  test('WAV analysis retains real silence and quiet energy; old v3 cache is ignored', () async {
    setupMockPlatformChannels();
    final dir = await Directory.systemTemp.createTemp('jlexa-vad-');
    final id = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final file = File('${dir.path}/quiet.wav');
    final bytes = ByteData(44 + 32000);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        bytes.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, 16000, Endian.little);
    bytes.setUint32(28, 32000, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    bytes.setUint32(40, 32000, Endian.little);
    for (var i = 8000; i < 16000; i++) {
      bytes.setInt16(44 + i * 2, 160, Endian.little);
    }
    await file.writeAsBytes(bytes.buffer.asUint8List());
    final modified = (await file.lastModified()).millisecondsSinceEpoch;
    final cacheDir = Directory('${Directory.systemTemp.path}/waveforms');
    await cacheDir.create(recursive: true);
    final oldCache = File(
      '${cacheDir.path}/v3_${id}_${bytes.lengthInBytes}_$modified.peaks',
    );
    await oldCache.writeAsBytes(
      Float32List.fromList(List.filled(100, .02)).buffer.asUint8List(),
    );
    try {
      final result = await service.extractAndCacheWaveform(file.path, id, 1000);
      expect(result.take(50), everyElement(0.0));
      expect(result.skip(50), everyElement(closeTo(160 / 32768, .00001)));
      final restored = await WaveformService().loadCachedWaveform(
        id,
        fileSize: bytes.lengthInBytes,
        lastModified: modified,
      );
      expect(restored, result);
    } finally {
      await service.deleteCachedWaveform(id);
      await dir.delete(recursive: true);
    }
  });

  const auditPath = String.fromEnvironment('SEGMENT_AUDIT_INPUT');
  if (auditPath.isNotEmpty) {
    test('Audit user-supplied full audio envelope', () {
      final data = jsonDecode(
        File(auditPath).readAsStringSync(),
      ) as Map<String, dynamic>;
      final cuts = service.detectSpeechRegions(
        peaks: (data['peaks'] as List)
            .cast<num>()
            .map((p) => p.toDouble())
            .toList(),
        durationMs: data['durationMs'],
      );
      File('$auditPath.cuts.json').writeAsStringSync(
        jsonEncode(cuts.map((c) => [c.startMs, c.endMs]).toList()),
      );
      expect(cuts, isNotEmpty);
    });
  }
}
