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
      'Explain clearly, accurately, and concisely. Reply in the language of the user’s question: Chinese questions get Chinese answers, English questions get English answers. Follow an explicit request to translate or answer in another language.';

  static const String dictionaryAiSystemPrompt =
      '你是英汉词典。只输出用户所给英文单词的常用词性和简明中文释义。'
      '每行先写词性缩写（n.、v.、adj.、adv.等），再写中文释义。'
      '只列出该词实际存在的词性。不要输出JSON、Markdown、开场白或例句。';

  static List<ChatMessagePayload> buildDictionaryAiAnswerMessages(
    String query, {
    String? dictionaryContext,
  }) {
    final clean = query.trim();
    final isWord = !clean.contains(' ') && clean.isNotEmpty;
    if (!isWord) {
      return buildTranslationMessages(clean);
    }
    return [
      const ChatMessagePayload(
        role: 'system',
        content: dictionaryAiSystemPrompt,
      ),
      ChatMessagePayload(
        role: 'user',
        content: dictionaryContext == null || dictionaryContext.isEmpty
            ? clean
            : '$clean\n参考词典释义：\n$dictionaryContext\n请简明整理上述释义，不要重复或编造释义。',
      ),
    ];
  }

  static String buildDictionaryAiAnswer(
    String query, {
    String? dictionaryContext,
  }) {
    return buildDictionaryAiAnswerMessages(
      query,
      dictionaryContext: dictionaryContext,
    ).map((m) => m.content).join('\n\n');
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
      const ChatMessagePayload(
        role: 'system',
        content: '你是英汉翻译。把用户的英文翻译成自然、准确的简体中文。只输出中文译文，不重复英文，不输出JSON，不解释任务。',
      ),
      ChatMessagePayload(role: 'user', content: text),
    ];
  }

  static String buildTranslation(String text) {
    return buildTranslationMessages(text).map((m) => m.content).join('\n\n');
  }

  static List<ChatMessagePayload> buildSentenceExplanationMessages(
    SentenceContext context,
  ) {
    final buffer = StringBuffer('课文：${context.lessonTitle}\n');
    buffer.writeln('当前句子：${context.sentenceText}');
    if (context.previousSentence?.isNotEmpty == true) {
      buffer.writeln('上文：${context.previousSentence}');
    }
    if (context.nextSentence?.isNotEmpty == true) {
      buffer.writeln('下文：${context.nextSentence}');
    }
    if (context.uncertainWords.isNotEmpty) {
      buffer.writeln('以下词语的语音识别可能不准确：${context.uncertainWords.join(', ')}');
    }
    return [
      const ChatMessagePayload(
        role: 'system',
        content:
            '你是英语老师。用简体中文解释当前句子的意思，再简短说明其中的重点词语或用法。'
            '上下文只供参考。直接给出讲解，不重复任务要求。',
      ),
      ChatMessagePayload(role: 'user', content: buffer.toString()),
    ];
  }

  static String buildSentenceExplanation(SentenceContext context) {
    return buildSentenceExplanationMessages(context)
        .map((m) => m.content)
        .join('\n\n');
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
