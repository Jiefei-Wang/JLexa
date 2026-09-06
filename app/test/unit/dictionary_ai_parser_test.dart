import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/dictionary/dictionary_ai_parser.dart';
import 'package:jlexa/core/dictionary/dictionary_models.dart';

void main() {
  group('DictionaryAiParser Tests', () {
    test('Parses clean word JSON with multiple senses', () {
      const jsonStr = '''
{
  "type": "word",
  "senses": [
    {
      "partOfSpeech": "v.",
      "meaning": "坚持；持续"
    },
    {
      "partOfSpeech": "n.",
      "meaning": "坚持；持续存在"
    }
  ]
}''';

      final answer = DictionaryAiParser.parse(jsonStr, query: 'persist');
      expect(answer, isA<DictionaryWordAnswer>());
      final wordAnswer = answer as DictionaryWordAnswer;
      expect(wordAnswer.senses.length, 2);
      expect(wordAnswer.senses[0].partOfSpeech, 'v.');
      expect(wordAnswer.senses[0].meaning, '坚持；持续');
      expect(wordAnswer.senses[1].partOfSpeech, 'n.');
      expect(wordAnswer.senses[1].meaning, '坚持；持续存在');
    });

    test('Parses markdown code-fenced word JSON', () {
      const fenced = '''
```json
{
  "type": "word",
  "senses": [
    {
      "partOfSpeech": "adj.",
      "meaning": "有弹性的；适应力强的"
    }
  ]
}
```''';

      final answer = DictionaryAiParser.parse(fenced, query: 'resilient');
      expect(answer, isA<DictionaryWordAnswer>());
      final wordAnswer = answer as DictionaryWordAnswer;
      expect(wordAnswer.senses.length, 1);
      expect(wordAnswer.senses[0].partOfSpeech, 'adj.');
      expect(wordAnswer.senses[0].meaning, '有弹性的；适应力强的');
    });

    test('Parses clean phrase JSON response', () {
      const jsonStr = '''
{
  "type": "phrase",
  "explanation": "表示“认为某事理所当然”，通常用于描述没有意识到某事物价值的情况。"
}''';

      final answer = DictionaryAiParser.parse(jsonStr, query: 'take it for granted');
      expect(answer, isA<DictionaryPhraseAnswer>());
      final phraseAnswer = answer as DictionaryPhraseAnswer;
      expect(phraseAnswer.explanation, contains('理所当然'));
    });

    test('Falls back gracefully from plain text POS lines for a word query', () {
      const plainOutput = '''
Sure! Here is the explanation:
v. 跑；运行；经营
n. 跑步；一段运行
I hope this helps!
''';

      final answer = DictionaryAiParser.parse(plainOutput, query: 'run');
      expect(answer, isA<DictionaryWordAnswer>());
      final wordAnswer = answer as DictionaryWordAnswer;
      expect(wordAnswer.senses.length, 2);
      expect(wordAnswer.senses[0].partOfSpeech, 'v.');
      expect(wordAnswer.senses[0].meaning, '跑；运行；经营');
      expect(wordAnswer.senses[1].partOfSpeech, 'n.');
      expect(wordAnswer.senses[1].meaning, '跑步；一段运行');
    });

    test('Falls back gracefully from conversational text for phrase query without leaking filler', () {
      const plainOutput = '''
Sure! This phrase means:
表示“偶尔，有时”，用于描述不规律发生的事情。
Let me know if you need anything else!
''';

      final answer = DictionaryAiParser.parse(plainOutput, query: 'now and then');
      expect(answer, isA<DictionaryPhraseAnswer>());
      final phraseAnswer = answer as DictionaryPhraseAnswer;
      expect(phraseAnswer.explanation, contains('偶尔，有时'));
      expect(phraseAnswer.explanation.contains('Sure!'), isFalse);
      expect(phraseAnswer.explanation.contains('Let me know'), isFalse);
    });

    test('Handles completely empty output safely', () {
      final answer = DictionaryAiParser.parse('', query: 'word');
      expect(answer, isA<DictionaryWordAnswer>());
      expect((answer as DictionaryWordAnswer).senses, isNotEmpty);
    });
  });
}
