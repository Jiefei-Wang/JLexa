class DictionaryEntry {
  final String word;
  final String phonetic;
  final String partOfSpeech; // e.g. "Adjective", "Noun", "Verb"
  final List<String> definitions;
  final List<String> chineseDefinitions;
  final List<ExampleSentence> examples;
  final List<String> synonyms;
  final bool isHighFrequency;

  const DictionaryEntry({
    required this.word,
    required this.phonetic,
    required this.partOfSpeech,
    required this.definitions,
    this.chineseDefinitions = const [],
    this.examples = const [],
    this.synonyms = const [],
    this.isHighFrequency = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'word': word,
      'phonetic': phonetic,
      'partOfSpeech': partOfSpeech,
      'definitions': definitions,
      'chineseDefinitions': chineseDefinitions,
      'examples': examples.map((e) => e.toMap()).toList(),
      'synonyms': synonyms,
      'isHighFrequency': isHighFrequency ? 1 : 0,
    };
  }

  factory DictionaryEntry.fromMap(Map<String, dynamic> map) {
    return DictionaryEntry(
      word: map['word'] as String,
      phonetic: map['phonetic'] as String? ?? '',
      partOfSpeech: map['partOfSpeech'] as String? ?? '',
      definitions:
          (map['definitions'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      chineseDefinitions:
          (map['chineseDefinitions'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      examples:
          (map['examples'] as List<dynamic>?)
              ?.map((e) => ExampleSentence.fromMap(e as Map<String, dynamic>))
              .toList() ??
          [],
      synonyms:
          (map['synonyms'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      isHighFrequency:
          map['isHighFrequency'] == 1 || map['isHighFrequency'] == true,
    );
  }
}

class ExampleSentence {
  final String english;
  final String? chinese;

  const ExampleSentence({required this.english, this.chinese});

  Map<String, dynamic> toMap() {
    return {'english': english, 'chinese': chinese};
  }

  factory ExampleSentence.fromMap(Map<String, dynamic> map) {
    return ExampleSentence(
      english: map['english'] as String,
      chinese: map['chinese'] as String?,
    );
  }
}

sealed class DictionaryAiAnswer {
  const DictionaryAiAnswer();
}

class DictionaryWordAnswer extends DictionaryAiAnswer {
  final List<DictionaryWordSense> senses;
  const DictionaryWordAnswer({required this.senses});

  @override
  String toString() =>
      senses.map((s) => '${s.partOfSpeech} ${s.meaning}').join('\n');
}

class DictionaryWordSense {
  final String partOfSpeech;
  final String meaning;
  const DictionaryWordSense({
    required this.partOfSpeech,
    required this.meaning,
  });

  @override
  String toString() => '$partOfSpeech $meaning';
}

class DictionaryPhraseAnswer extends DictionaryAiAnswer {
  final String explanation;
  const DictionaryPhraseAnswer({required this.explanation});

  @override
  String toString() => explanation;
}
