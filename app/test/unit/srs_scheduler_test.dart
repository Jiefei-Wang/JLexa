import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/vocabulary/srs_scheduler.dart';
import 'package:jlexa/core/vocabulary/vocabulary_models.dart';

void main() {
  group('SimpleSrsScheduler Tests', () {
    late SimpleSrsScheduler scheduler;
    final baseTime = DateTime(2026, 1, 1, 12, 0);

    setUp(() {
      scheduler = SimpleSrsScheduler();
    });

    test(
      'New word review with "Again" resets interval and sets state to learning',
      () {
        final word = VocabularyWord(
          id: '1',
          word: 'resilient',
          definitionSnapshot: 'Able to recover',
          dateAdded: baseTime,
        );

        final updated = scheduler.scheduleReview(
          word,
          ReviewRating.again,
          now: baseTime,
        );
        expect(updated.intervalDays, equals(0));
        expect(updated.state, equals(VocabularyState.learning));
        expect(updated.reviewCount, equals(1));
        expect(updated.nextReview, isNotNull);
        expect(updated.nextReview!.isAfter(baseTime), isTrue);
      },
    );

    test('Word review with "Hard" increments interval by 1 day', () {
      final word = VocabularyWord(
        id: '2',
        word: 'prioritize',
        definitionSnapshot: 'Treat as important',
        dateAdded: baseTime,
        intervalDays: 0,
      );

      final updated = scheduler.scheduleReview(
        word,
        ReviewRating.hard,
        now: baseTime,
      );
      expect(updated.intervalDays, equals(1));
      expect(updated.state, equals(VocabularyState.learning));
    });

    test('Word review with "Good" on new word sets interval to 3 days', () {
      final word = VocabularyWord(
        id: '3',
        word: 'meticulous',
        definitionSnapshot: 'Very precise',
        dateAdded: baseTime,
        intervalDays: 0,
      );

      final updated = scheduler.scheduleReview(
        word,
        ReviewRating.good,
        now: baseTime,
      );
      expect(updated.intervalDays, equals(3));
      expect(updated.state, equals(VocabularyState.review));
      expect(updated.nextReview, equals(baseTime.add(const Duration(days: 3))));
    });

    test(
      'Word review with "Easy" sets interval to 7 days and boosts ease factor',
      () {
        final word = VocabularyWord(
          id: '4',
          word: 'endeavor',
          definitionSnapshot: 'Try hard to achieve',
          dateAdded: baseTime,
          intervalDays: 0,
          easeFactor: 2.5,
        );

        final updated = scheduler.scheduleReview(
          word,
          ReviewRating.easy,
          now: baseTime,
        );
        expect(updated.intervalDays, equals(7));
        expect(updated.easeFactor, greaterThan(2.5));
        expect(
          updated.nextReview,
          equals(baseTime.add(const Duration(days: 7))),
        );
      },
    );

    test('Word reaches mastered state after multiple successful reviews', () {
      VocabularyWord word = VocabularyWord(
        id: '5',
        word: 'significant',
        definitionSnapshot: 'Important',
        dateAdded: baseTime,
        reviewCount: 3,
        intervalDays: 3,
      );

      word = scheduler.scheduleReview(word, ReviewRating.good, now: baseTime);
      expect(word.reviewCount, equals(4));
      expect(word.state, equals(VocabularyState.mastered));
    });
  });
}
