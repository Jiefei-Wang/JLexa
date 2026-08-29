class SentenceContext {
  final String lessonTitle;
  final String sentenceText;
  final String? previousSentence;
  final String? nextSentence;
  final int startMs;
  final int endMs;
  final List<String> uncertainWords;
  final String? dictionaryContext;

  const SentenceContext({
    required this.lessonTitle,
    required this.sentenceText,
    this.previousSentence,
    this.nextSentence,
    this.startMs = 0,
    this.endMs = 0,
    this.uncertainWords = const [],
    this.dictionaryContext,
  });
}

class PromptBuilder {
  static const String systemPrefix =
      'You are JLexa, an expert offline English learning AI assistant. '
      'Explain clearly, accurately, and concisely. When appropriate, provide natural Chinese explanations for English learners.';

  static String buildDictionaryExplanation(String word) {
    return '''$systemPrefix

Explain the English word "$word" for a language learner.
Provide:
1. Core meaning and nuances
2. Typical collocations and common usage
3. Natural example sentences
4. Chinese translation of key points''';
  }

  static String buildTranslation(String text) {
    return '''$systemPrefix

Translate the following English text into natural, fluent Chinese:
"$text"''';
  }

  static String buildSentenceExplanation(SentenceContext context) {
    final buffer = StringBuffer();
    buffer.writeln(systemPrefix);
    buffer.writeln('\nExplain this sentence from the audio lesson "${context.lessonTitle}":');
    buffer.writeln('Current sentence: "${context.sentenceText}"');

    if (context.previousSentence != null && context.previousSentence!.isNotEmpty) {
      buffer.writeln('Previous context: "${context.previousSentence}"');
    }
    if (context.nextSentence != null && context.nextSentence!.isNotEmpty) {
      buffer.writeln('Following context: "${context.nextSentence}"');
    }
    if (context.uncertainWords.isNotEmpty) {
      buffer.writeln('Note: The speech recognizer was uncertain about words: ${context.uncertainWords.join(', ')}');
    }

    buffer.writeln('\nPlease format your answer with:');
    buffer.writeln('Summary: Concise 1-sentence explanation of what the speaker means.');
    buffer.writeln('Meaning: Nuances of key phrases and idioms in this context.');
    buffer.writeln('Possible correction: If any word seems misrecognized, suggest the intended word; otherwise state "No correction necessary."');

    return buffer.toString();
  }

  static String buildSentenceQA({
    required SentenceContext context,
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
  }) {
    final buffer = StringBuffer();
    buffer.writeln(systemPrefix);
    buffer.writeln('\nLesson: "${context.lessonTitle}"');
    buffer.writeln('Target sentence: "${context.sentenceText}"');

    if (context.previousSentence != null && context.previousSentence!.isNotEmpty) {
      buffer.writeln('Context before: "${context.previousSentence}"');
    }
    if (context.nextSentence != null && context.nextSentence!.isNotEmpty) {
      buffer.writeln('Context after: "${context.nextSentence}"');
    }

    if (chatHistory.isNotEmpty) {
      buffer.writeln('\nConversation history:');
      for (final msg in chatHistory) {
        final role = msg['role'] == 'user' ? 'User' : 'Assistant';
        buffer.writeln('$role: ${msg['content']}');
      }
    }

    buffer.writeln('\nUser: $userQuestion');
    buffer.writeln('Assistant:');

    return buffer.toString();
  }

  static String buildGeneralQA({
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
  }) {
    final buffer = StringBuffer();
    buffer.writeln(systemPrefix);

    if (chatHistory.isNotEmpty) {
      buffer.writeln('\nConversation history:');
      for (final msg in chatHistory) {
        final role = msg['role'] == 'user' ? 'User' : 'Assistant';
        buffer.writeln('$role: ${msg['content']}');
      }
    }

    buffer.writeln('\nUser: $userQuestion');
    buffer.writeln('Assistant:');

    return buffer.toString();
  }
}
