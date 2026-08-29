import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';

void main() {
  group('AudioSegment Operations & Constraint Tests', () {
    test('AudioSegment containsPosition works correctly', () {
      const segment = AudioSegment(
        id: 'seg_1',
        lessonId: 'lesson_1',
        startMs: 1000,
        endMs: 5000,
        text: 'The key is not to prioritize what is on your schedule.',
      );

      expect(segment.containsPosition(1000), isTrue);
      expect(segment.containsPosition(3000), isTrue);
      expect(segment.containsPosition(4999), isTrue);
      expect(segment.containsPosition(5000), isFalse);
      expect(segment.containsPosition(5000, isLast: true), isTrue);
      expect(segment.containsPosition(999), isFalse);
      expect(segment.containsPosition(5001), isFalse);
      expect(segment.durationMs, equals(4000));
    });

    test('Split segment at playhead maintains timeline continuity', () {
      const original = AudioSegment(
        id: 'seg_1',
        lessonId: 'lesson_1',
        startMs: 1000,
        endMs: 6000,
        text: 'Part one and part two of the sentence.',
      );

      const splitPointMs = 3500;

      // Invariants:
      // seg1.start = original.start
      // seg1.end = splitPoint
      // seg2.start = splitPoint
      // seg2.end = original.end
      final seg1 = original.copyWith(endMs: splitPointMs, text: 'Part one');
      final seg2 = AudioSegment(
        id: 'seg_2',
        lessonId: original.lessonId,
        startMs: splitPointMs,
        endMs: original.endMs,
        text: 'and part two of the sentence.',
      );

      expect(seg1.startMs, equals(1000));
      expect(seg1.endMs, equals(3500));
      expect(seg2.startMs, equals(3500));
      expect(seg2.endMs, equals(6000));
      expect(seg1.durationMs + seg2.durationMs, equals(original.durationMs));
    });

    test('Merge adjacent segments combines text and bounds correctly', () {
      const seg1 = AudioSegment(
        id: 'seg_1',
        lessonId: 'lesson_1',
        startMs: 1000,
        endMs: 3000,
        text: 'Hello world,',
      );

      const seg2 = AudioSegment(
        id: 'seg_2',
        lessonId: 'lesson_1',
        startMs: 3000,
        endMs: 5500,
        text: 'welcome to JLexa.',
      );

      final merged = seg1.copyWith(
        endMs: seg2.endMs,
        text: '${seg1.text} ${seg2.text}',
      );

      expect(merged.startMs, equals(1000));
      expect(merged.endMs, equals(5500));
      expect(merged.text, equals('Hello world, welcome to JLexa.'));
      expect(merged.durationMs, equals(4500));
    });

    test('Boundary constraint invariants (start >= 0, end <= duration, start < end)', () {
      const totalDuration = 10000;
      int proposedStart = -500;
      int proposedEnd = 12000;

      int validStart = proposedStart.clamp(0, totalDuration);
      int validEnd = proposedEnd.clamp(0, totalDuration);

      expect(validStart, greaterThanOrEqualTo(0));
      expect(validEnd, lessThanOrEqualTo(totalDuration));
      expect(validStart, lessThan(validEnd));
    });

    test('TranscriptToken uncertainty thresholds', () {
      const highConf = TranscriptToken(text: 'clear', confidence: 0.95);
      const mediumConf = TranscriptToken(text: 'schedule', confidence: 0.72);
      const lowConf = TranscriptToken(text: 'mumble', confidence: 0.50);

      expect(highConf.isUncertain, isFalse);
      expect(mediumConf.isUncertain, isTrue);
      expect(mediumConf.isLowConfidence, isFalse);
      expect(lowConf.isLowConfidence, isTrue);
    });
  });
}
