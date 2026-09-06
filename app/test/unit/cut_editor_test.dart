import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/cut_editor.dart';
import 'package:jlexa/core/audio/waveform_service.dart';

AudioSegment cut(String id, int start, int end, {int revision = 0}) =>
    AudioSegment(
      id: id,
      lessonId: 'l',
      startMs: start,
      endMs: end,
      text: 'cached',
      revision: revision,
      transcriptCutRevision: revision,
    );

void main() {
  group('independent cut interval rules', () {
    final original = [
      cut('A', 2000, 4000),
      cut('B', 5000, 7000),
      cut('C', 8000, 10000),
    ];
    test('strict half-open active semantics leave gaps empty', () {
      expect(original.where((c) => c.containsPosition(4500)), isEmpty);
      expect(original.where((c) => c.containsPosition(4000)), isEmpty);
    });
    test('right expansion partially clips neighbor', () {
      final r = CutEditor.resize(
        snapshot: original,
        cutId: 'A',
        expectedRevision: 0,
        newStartMs: 2000,
        newEndMs: 6000,
        durationMs: 12000,
      );
      expect(r.cuts.map((c) => (c.id, c.startMs, c.endMs)), [
        ('A', 2000, 6000),
        ('B', 6000, 7000),
        ('C', 8000, 10000),
      ]);
      expect(r.cuts[1].revision, 1);
      expect(r.cuts[1].text, isEmpty);
    });
    test('right expansion consumes one and clips the next', () {
      final r = CutEditor.resize(
        snapshot: original,
        cutId: 'A',
        expectedRevision: 0,
        newStartMs: 2000,
        newEndMs: 9000,
        durationMs: 12000,
      );
      expect(r.deletedIds, contains('B'));
      expect(r.cuts.map((c) => (c.id, c.startMs, c.endMs)), [
        ('A', 2000, 9000),
        ('C', 9000, 10000),
      ]);
    });
    test('left expansion is symmetric and can consume many cuts', () {
      final r = CutEditor.resize(
        snapshot: original,
        cutId: 'C',
        expectedRevision: 0,
        newStartMs: 3000,
        newEndMs: 10000,
        durationMs: 12000,
      );
      expect(r.cuts.map((c) => (c.id, c.startMs, c.endMs)), [
        ('A', 2000, 3000),
        ('C', 3000, 10000),
      ]);
      expect(r.deletedIds, contains('B'));
    });
    test('gap lookup never modifies existing cuts', () {
      final gap = CutEditor.gapAt(original, 4500, 12000);
      expect((gap.startMs, gap.endMs), (4000, 5000));
      expect(original[0].endMs, 4000);
    });
    test('stale revision is rejected', () {
      expect(
        () => CutEditor.resize(
          snapshot: original,
          cutId: 'A',
          expectedRevision: 2,
          newStartMs: 1000,
          newEndMs: 4000,
          durationMs: 12000,
        ),
        throwsStateError,
      );
    });
  });

  test(
    'adaptive VAD returns no fake cut for silence and merges short pause',
    () {
      final service = WaveformService();
      expect(
        service.detectSpeechRegions(
          peaks: List.filled(100, 0.01),
          durationMs: 5000,
        ),
        isEmpty,
      );
      final peaks = [
        ...List.filled(10, 0.01),
        ...List.filled(10, 0.5),
        ...List.filled(4, 0.01),
        ...List.filled(10, 0.5),
        ...List.filled(10, 0.01),
      ];
      final regions = service.detectSpeechRegions(
        peaks: peaks,
        durationMs: 2200,
      );
      expect(regions, hasLength(1));
    },
  );
}
