import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/utils/text_normalization.dart';

void main() {
  group('TextNormalization', () {
    test('normalizes plain word and trims whitespace', () {
      expect(TextNormalization.normalizeWord('  Resilient  '), 'resilient');
    });

    test('preserves internal apostrophe', () {
      expect(TextNormalization.normalizeWord("what's"), "what's");
      expect(TextNormalization.normalizeWord("It's"), "it's");
    });

    test('preserves internal hyphen', () {
      expect(TextNormalization.normalizeWord('high-impact'), 'high-impact');
      expect(TextNormalization.normalizeWord('state-of-the-art'), 'state-of-the-art');
    });

    test('strips leading and trailing punctuation', () {
      expect(TextNormalization.normalizeWord('"resilient,"'), 'resilient');
      expect(TextNormalization.normalizeWord('(prioritize)...'), 'prioritize');
      expect(TextNormalization.normalizeWord('schedule;'), 'schedule');
    });

    test('handles empty and special symbol strings', () {
      expect(TextNormalization.normalizeWord(''), '');
      expect(TextNormalization.normalizeWord('...'), '');
      expect(TextNormalization.normalizeWord('   '), '');
    });
  });
}
