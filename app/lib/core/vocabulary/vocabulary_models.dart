enum ReviewRating {
  again, // Failed / need reset
  hard, // Difficult / short interval
  good, // Normal / standard interval
  easy, // Very easy / longest interval
}

enum VocabularyState { newWord, learning, review, mastered }

class VocabularyWord {
  final String id;
  final String word;
  final String? phonetic;
  final String? partOfSpeech;
  final String definitionSnapshot;
  final String? translationSnapshot;
  final String? source;
  final String? sourceSentence;
  final VocabularyState state;
  final DateTime dateAdded;
  final DateTime? lastReviewed;
  final DateTime? nextReview;
  final int reviewCount;
  final int intervalDays;
  final double easeFactor;

  const VocabularyWord({
    required this.id,
    required this.word,
    this.phonetic,
    this.partOfSpeech,
    required this.definitionSnapshot,
    this.translationSnapshot,
    this.source,
    this.sourceSentence,
    this.state = VocabularyState.newWord,
    required this.dateAdded,
    this.lastReviewed,
    this.nextReview,
    this.reviewCount = 0,
    this.intervalDays = 0,
    this.easeFactor = 2.5,
  });

  bool get isDue {
    if (nextReview == null) return true;
    return DateTime.now().isAfter(nextReview!);
  }

  VocabularyWord copyWith({
    String? id,
    String? word,
    String? phonetic,
    String? partOfSpeech,
    String? definitionSnapshot,
    String? translationSnapshot,
    String? source,
    String? sourceSentence,
    VocabularyState? state,
    DateTime? dateAdded,
    DateTime? lastReviewed,
    DateTime? nextReview,
    int? reviewCount,
    int? intervalDays,
    double? easeFactor,
  }) {
    return VocabularyWord(
      id: id ?? this.id,
      word: word ?? this.word,
      phonetic: phonetic ?? this.phonetic,
      partOfSpeech: partOfSpeech ?? this.partOfSpeech,
      definitionSnapshot: definitionSnapshot ?? this.definitionSnapshot,
      translationSnapshot: translationSnapshot ?? this.translationSnapshot,
      source: source ?? this.source,
      sourceSentence: sourceSentence ?? this.sourceSentence,
      state: state ?? this.state,
      dateAdded: dateAdded ?? this.dateAdded,
      lastReviewed: lastReviewed ?? this.lastReviewed,
      nextReview: nextReview ?? this.nextReview,
      reviewCount: reviewCount ?? this.reviewCount,
      intervalDays: intervalDays ?? this.intervalDays,
      easeFactor: easeFactor ?? this.easeFactor,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'word': word,
      'phonetic': phonetic,
      'part_of_speech': partOfSpeech,
      'definition_snapshot': definitionSnapshot,
      'translation_snapshot': translationSnapshot,
      'source': source,
      'source_sentence': sourceSentence,
      'state': state.name,
      'date_added': dateAdded.millisecondsSinceEpoch,
      'last_reviewed': lastReviewed?.millisecondsSinceEpoch,
      'next_review': nextReview?.millisecondsSinceEpoch,
      'review_count': reviewCount,
      'interval_days': intervalDays,
      'ease_factor': easeFactor,
    };
  }

  factory VocabularyWord.fromMap(Map<String, dynamic> map) {
    return VocabularyWord(
      id: map['id'] as String,
      word: map['word'] as String,
      phonetic: map['phonetic'] as String?,
      partOfSpeech: map['part_of_speech'] as String?,
      definitionSnapshot: map['definition_snapshot'] as String? ?? '',
      translationSnapshot: map['translation_snapshot'] as String?,
      source: map['source'] as String?,
      sourceSentence: map['source_sentence'] as String?,
      state: VocabularyState.values.firstWhere(
        (e) => e.name == map['state'],
        orElse: () => VocabularyState.newWord,
      ),
      dateAdded: DateTime.fromMillisecondsSinceEpoch(map['date_added'] as int),
      lastReviewed: map['last_reviewed'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['last_reviewed'] as int)
          : null,
      nextReview: map['next_review'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['next_review'] as int)
          : null,
      reviewCount: map['review_count'] as int? ?? 0,
      intervalDays: map['interval_days'] as int? ?? 0,
      easeFactor: (map['ease_factor'] as num?)?.toDouble() ?? 2.5,
    );
  }
}
