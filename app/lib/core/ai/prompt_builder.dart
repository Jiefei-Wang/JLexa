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

class ChatMessagePayload {
  final String role; // 'system', 'user', 'assistant'
  final String content;

  const ChatMessagePayload({required this.role, required this.content});

  Map<String, String> toMap() => {'role': role, 'content': content};
}

class PromptBuilder {
  static const String systemPrefix =
      'You are JLexa, an expert offline English learning AI assistant. '
      'Explain clearly, accurately, and concisely. When appropriate, provide natural Chinese explanations for English learners.';

  static const String dictionaryAiSystemPrompt =
      'Return JSON only.\n'
      'Do not address the user.\n'
      'Do not include introductions.\n'
      'Do not include conclusions.\n'
      'Do not apologize.\n'
      'Do not include markdown fences.\n'
      'Do not include meta commentary.';

  static List<ChatMessagePayload> buildDictionaryAiAnswerMessages(
    String query,
  ) {
    final clean = query.trim();
    final isWord = !clean.contains(' ') && clean.isNotEmpty;
    final prompt =
        isWord
            ? 'Provide lexical information for the English word "$clean".\n'
                'Format strictly as JSON:\n'
                '{"type": "word", "senses": [{"partOfSpeech": "v.", "meaning": "..."}, {"partOfSpeech": "n.", "meaning": "..."}]}\n'
                'Use standard abbreviated part-of-speech labels (e.g. n., v., adj., adv., prep., conj., pron., interj.).'
            : 'Provide a concise Chinese explanation of the meaning and usage of "$clean".\n'
                'Format strictly as JSON:\n'
                '{"type": "phrase", "explanation": "表示……，通常用于……"}';

    return [
      const ChatMessagePayload(
        role: 'system',
        content: dictionaryAiSystemPrompt,
      ),
      ChatMessagePayload(role: 'user', content: prompt),
    ];
  }

  static String buildDictionaryAiAnswer(String query) {
    final clean = query.trim();
    final isWord = !clean.contains(' ') && clean.isNotEmpty;
    final prompt =
        isWord
            ? 'Provide lexical information for the English word "$clean".\n'
                'Format strictly as JSON:\n'
                '{"type": "word", "senses": [{"partOfSpeech": "v.", "meaning": "..."}, {"partOfSpeech": "n.", "meaning": "..."}]}\n'
                'Use standard abbreviated part-of-speech labels (e.g. n., v., adj., adv., prep., conj., pron., interj.).'
            : 'Provide a concise Chinese explanation of the meaning and usage of "$clean".\n'
                'Format strictly as JSON:\n'
                '{"type": "phrase", "explanation": "表示……，通常用于……"}';

    return '$dictionaryAiSystemPrompt\n\n$prompt';
  }

  static List<ChatMessagePayload> buildDictionaryExplanationMessages(
    String word,
  ) {
    return [
      const ChatMessagePayload(role: 'system', content: systemPrefix),
      ChatMessagePayload(
        role: 'user',
        content:
            'Explain the English word "$word" for a language learner.\nProvide:\n1. Core meaning and nuances\n2. Typical collocations and common usage\n3. Natural example sentences\n4. Chinese translation of key points',
      ),
    ];
  }

  static String buildDictionaryExplanation(String word) {
    return '''$systemPrefix

Explain the English word "$word" for a language learner.
Provide:
1. Core meaning and nuances
2. Typical collocations and common usage
3. Natural example sentences
4. Chinese translation of key points''';
  }

  static List<ChatMessagePayload> buildTranslationMessages(String text) {
    return [
      const ChatMessagePayload(role: 'system', content: systemPrefix),
      ChatMessagePayload(
        role: 'user',
        content:
            'Translate the following English text into natural, fluent Chinese:\n"$text"',
      ),
    ];
  }

  static String buildTranslation(String text) {
    return '''$systemPrefix

Translate the following English text into natural, fluent Chinese:
"$text"''';
  }

  static List<ChatMessagePayload> buildSentenceExplanationMessages(
    SentenceContext context,
  ) {
    final buffer = StringBuffer();
    buffer.writeln(
      'Explain this sentence from the audio lesson "${context.lessonTitle}":',
    );
    buffer.writeln('Current sentence: "${context.sentenceText}"');

    if (context.previousSentence != null &&
        context.previousSentence!.isNotEmpty) {
      buffer.writeln('Previous context: "${context.previousSentence}"');
    }
    if (context.nextSentence != null && context.nextSentence!.isNotEmpty) {
      buffer.writeln('Following context: "${context.nextSentence}"');
    }
    if (context.uncertainWords.isNotEmpty) {
      buffer.writeln(
        'Note: The speech recognizer was uncertain about words: ${context.uncertainWords.join(', ')}',
      );
    }

    buffer.writeln('\nPlease format your answer with:');
    buffer.writeln(
      'Summary: Concise 1-sentence explanation of what the speaker means.',
    );
    buffer.writeln(
      'Meaning: Nuances of key phrases and idioms in this context.',
    );
    buffer.writeln(
      'Possible correction: If any word seems misrecognized, suggest the intended word; otherwise state "No correction necessary."',
    );

    return [
      const ChatMessagePayload(role: 'system', content: systemPrefix),
      ChatMessagePayload(role: 'user', content: buffer.toString()),
    ];
  }

  static String buildSentenceExplanation(SentenceContext context) {
    final buffer = StringBuffer();
    buffer.writeln(systemPrefix);
    buffer.writeln(
      '\nExplain this sentence from the audio lesson "${context.lessonTitle}":',
    );
    buffer.writeln('Current sentence: "${context.sentenceText}"');

    if (context.previousSentence != null &&
        context.previousSentence!.isNotEmpty) {
      buffer.writeln('Previous context: "${context.previousSentence}"');
    }
    if (context.nextSentence != null && context.nextSentence!.isNotEmpty) {
      buffer.writeln('Following context: "${context.nextSentence}"');
    }
    if (context.uncertainWords.isNotEmpty) {
      buffer.writeln(
        'Note: The speech recognizer was uncertain about words: ${context.uncertainWords.join(', ')}',
      );
    }

    buffer.writeln('\nPlease format your answer with:');
    buffer.writeln(
      'Summary: Concise 1-sentence explanation of what the speaker means.',
    );
    buffer.writeln(
      'Meaning: Nuances of key phrases and idioms in this context.',
    );
    buffer.writeln(
      'Possible correction: If any word seems misrecognized, suggest the intended word; otherwise state "No correction necessary."',
    );

    return buffer.toString();
  }

  static List<ChatMessagePayload> buildSentenceQAMessages({
    required SentenceContext context,
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
  }) {
    final msgs = <ChatMessagePayload>[
      const ChatMessagePayload(role: 'system', content: systemPrefix),
    ];

    final contextHeader = StringBuffer();
    contextHeader.writeln('Lesson: "${context.lessonTitle}"');
    contextHeader.writeln('Target sentence: "${context.sentenceText}"');
    if (context.previousSentence != null &&
        context.previousSentence!.isNotEmpty) {
      contextHeader.writeln('Context before: "${context.previousSentence}"');
    }
    if (context.nextSentence != null && context.nextSentence!.isNotEmpty) {
      contextHeader.writeln('Context after: "${context.nextSentence}"');
    }

    for (int i = 0; i < chatHistory.length; i++) {
      final msg = chatHistory[i];
      final role = msg['role'] == 'assistant' ? 'assistant' : 'user';
      final content = msg['content'] ?? '';
      if (i == 0 && role == 'user') {
        msgs.add(
          ChatMessagePayload(
            role: 'user',
            content: '$contextHeader\n\n$content',
          ),
        );
      } else {
        msgs.add(ChatMessagePayload(role: role, content: content));
      }
    }

    if (chatHistory.isEmpty) {
      msgs.add(
        ChatMessagePayload(
          role: 'user',
          content: '$contextHeader\n\nQuestion: $userQuestion',
        ),
      );
    } else {
      msgs.add(ChatMessagePayload(role: 'user', content: userQuestion));
    }

    return msgs;
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

    if (context.previousSentence != null &&
        context.previousSentence!.isNotEmpty) {
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

  static List<ChatMessagePayload> buildGeneralQAMessages({
    required String userQuestion,
    List<Map<String, String>> chatHistory = const [],
  }) {
    final msgs = <ChatMessagePayload>[
      const ChatMessagePayload(role: 'system', content: systemPrefix),
    ];

    for (final msg in chatHistory) {
      final role = msg['role'] == 'assistant' ? 'assistant' : 'user';
      msgs.add(ChatMessagePayload(role: role, content: msg['content'] ?? ''));
    }

    msgs.add(ChatMessagePayload(role: 'user', content: userQuestion));
    return msgs;
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
