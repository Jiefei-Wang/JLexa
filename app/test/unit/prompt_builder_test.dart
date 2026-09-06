import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/prompt_builder.dart';

void main() {
  group('PromptBuilder Tests', () {
    test('Dictionary sentences request Chinese translation without copyable placeholders', () {
      const sentence = 'Will Alice visit tomorrow?';
      final messages = PromptBuilder.buildDictionaryAiAnswerMessages(sentence);
      expect(messages.first.content, contains('只输出中文译文'));
      expect(messages.last.content, sentence);
      expect(
        PromptBuilder.buildDictionaryAiAnswer(sentence),
        isNot(contains('表示……')),
      );
      expect(
        PromptBuilder.buildDictionaryAiAnswer(sentence),
        contains(sentence),
      );
    });
    test('buildDictionaryExplanation formats prompt with word and educational guidelines', () {
      final prompt = PromptBuilder.buildDictionaryExplanation('resilient');
      expect(prompt, contains('resilient'));
      expect(prompt, contains('JLexa'));
      expect(prompt, contains('Chinese'));
    });

    test('buildTranslation formats prompt for text', () {
      final prompt = PromptBuilder.buildTranslation('The power of habit');
      expect(prompt, contains('The power of habit'));
      expect(prompt, contains('翻译'));
      expect(prompt, contains('中文'));
    });

    test('buildSentenceExplanation includes sentence, context, and uncertain words', () {
      const context = SentenceContext(
        lessonTitle: 'TED Talk: The power of habit',
        sentenceText: 'The key is not to prioritize what is on your schedule.',
        previousSentence: 'Most people think they never have enough time.',
        nextSentence: 'When you build a resilient mindset...',
        uncertainWords: ['schedule'],
      );

      final prompt = PromptBuilder.buildSentenceExplanation(context);
      expect(prompt, contains('TED Talk: The power of habit'));
      expect(
        prompt,
        contains('The key is not to prioritize what is on your schedule.'),
      );
      expect(
        prompt,
        contains('Most people think they never have enough time.'),
      );
      expect(prompt, contains('schedule'));
      expect(prompt, contains('用简体中文解释当前句子的意思'));
      expect(prompt, isNot(contains('Possible correction:')));
      expect(prompt, contains('不重复任务要求'));
    });

    test('buildSentenceQA includes user question and chat history', () {
      const context = SentenceContext(
        lessonTitle: 'TED Talk',
        sentenceText: 'Schedule your priorities.',
      );

      final prompt = PromptBuilder.buildSentenceQA(
        context: context,
        userQuestion: 'What does prioritize mean?',
        chatHistory: [
          {'role': 'user', 'content': 'Hello'},
          {'role': 'assistant', 'content': 'Hi! How can I help?'},
        ],
      );

      expect(prompt, contains('Schedule your priorities.'));
      expect(prompt, contains('What does prioritize mean?'));
      expect(prompt, contains('User: Hello'));
      expect(prompt, contains('Assistant: Hi! How can I help?'));
    });
  });
}
