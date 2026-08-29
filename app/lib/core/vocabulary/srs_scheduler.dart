import 'vocabulary_models.dart';

abstract class ISrsScheduler {
  VocabularyWord scheduleReview(VocabularyWord word, ReviewRating rating, {DateTime? now});
}

class SimpleSrsScheduler implements ISrsScheduler {
  @override
  VocabularyWord scheduleReview(VocabularyWord word, ReviewRating rating, {DateTime? now}) {
    final currentTime = now ?? DateTime.now();
    int newInterval;
    VocabularyState newState;
    double newEase = word.easeFactor;
    int newReviewCount = word.reviewCount + 1;

    switch (rating) {
      case ReviewRating.again:
        newInterval = 0; // Review again today / within minutes
        newState = VocabularyState.learning;
        newEase = (newEase - 0.2).clamp(1.3, 3.0);
        break;

      case ReviewRating.hard:
        newInterval = word.intervalDays == 0 ? 1 : (word.intervalDays * 1.2).ceil();
        if (newInterval < 1) newInterval = 1;
        newState = VocabularyState.learning;
        newEase = (newEase - 0.15).clamp(1.3, 3.0);
        break;

      case ReviewRating.good:
        if (word.intervalDays == 0) {
          newInterval = 3;
        } else if (word.intervalDays == 1) {
          newInterval = 3;
        } else {
          newInterval = (word.intervalDays * word.easeFactor).round();
        }
        newState = newReviewCount >= 4 ? VocabularyState.mastered : VocabularyState.review;
        break;

      case ReviewRating.easy:
        if (word.intervalDays == 0) {
          newInterval = 7;
        } else {
          newInterval = (word.intervalDays * word.easeFactor * 1.5).round();
          if (newInterval < 7) newInterval = 7;
        }
        newEase = (newEase + 0.15).clamp(1.3, 3.0);
        newState = newReviewCount >= 3 ? VocabularyState.mastered : VocabularyState.review;
        break;
    }

    final nextReviewDate = newInterval == 0
        ? currentTime.add(const Duration(minutes: 10))
        : currentTime.add(Duration(days: newInterval));

    return word.copyWith(
      lastReviewed: currentTime,
      nextReview: nextReviewDate,
      intervalDays: newInterval,
      reviewCount: newReviewCount,
      easeFactor: newEase,
      state: newState,
    );
  }
}
