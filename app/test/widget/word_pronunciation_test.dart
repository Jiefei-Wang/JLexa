import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/dictionary/dictionary_models.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:jlexa/features/dictionary/dictionary_controller.dart';
import 'package:jlexa/features/repeater/widgets/word_explanation_sheet.dart';

import '../test_helper.dart';

class _EmptyDictionary extends DictionaryRepository {
  @override
  Future<DictionaryEntry?> lookupWord(String word) async => null;
}

class _EmptyVocabulary extends VocabularyRepository {
  @override
  Future<bool> isWordSaved(String word) async => false;
}

void main() {
  late String language;
  late List<({String text, String language})> utterances;
  Completer<void>? nextEnglishSetup;

  setUp(() {
    setupMockPlatformChannels();
    language = 'en-US';
    utterances = [];
    nextEnglishSetup = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          if (call.method == 'setLanguage') {
            if (call.arguments == 'en-US') {
              final pending = nextEnglishSetup;
              nextEnglishSetup = null;
              await pending?.future;
            }
            language = call.arguments as String;
          } else if (call.method == 'speak') {
            utterances.add((
              text: call.arguments is Map
                  ? (call.arguments as Map)['text'] as String
                  : call.arguments as String,
              language: language,
            ));
          }
          return 1;
        });
  });

  DictionaryController dictionary() => DictionaryController(
    dictionaryRepo: _EmptyDictionary(),
    vocabularyRepo: _EmptyVocabulary(),
    aiService: AiService(),
  );

  Widget sheet() => MaterialApp(
    home: Scaffold(
      body: WordExplanationSheet(
        word: 'butterfly',
        sentenceText: 'A butterfly flew past.',
        dictionaryRepo: _EmptyDictionary(),
        vocabularyRepo: _EmptyVocabulary(),
        aiService: AiService(),
      ),
    ),
  );

  testWidgets(
    'Dictionary and Listening restore English after Chinese read aloud',
    (tester) async {
      final controller = dictionary();
      addTearDown(controller.dispose);
      final otherFeatureTts = FlutterTts();
      await otherFeatureTts.setLanguage('zh-CN');
      await otherFeatureTts.speak('你好');
      await controller.speak('butterfly');
      expect(utterances.last, (text: 'butterfly', language: 'en-US'));

      await tester.pumpWidget(sheet());
      await tester.pumpAndSettle();
      await otherFeatureTts.setLanguage('zh-CN');
      await otherFeatureTts.speak('你好');
      await tester.tap(find.byIcon(Icons.volume_up));
      await tester.pumpAndSettle();
      expect(utterances.last, (text: 'butterfly', language: 'en-US'));
      expect(utterances.length, 4);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Dictionary rejects superseded and disposed pronunciation requests',
    (tester) async {
      final controller = dictionary();
      final olderSetup = Completer<void>();
      nextEnglishSetup = olderSetup;
      final older = controller.speak('older');
      await tester.pump();
      await controller.speak('newer');
      olderSetup.complete();
      await older;
      expect(utterances, [(text: 'newer', language: 'en-US')]);

      final disposedSetup = Completer<void>();
      nextEnglishSetup = disposedSetup;
      final disposed = controller.speak('closed');
      await tester.pump();
      controller.dispose();
      disposedSetup.complete();
      await disposed;
      expect(utterances, [(text: 'newer', language: 'en-US')]);
    },
  );

  testWidgets('Closing the word sheet prevents pending pronunciation', (
    tester,
  ) async {
    await tester.pumpWidget(sheet());
    await tester.pumpAndSettle();
    final setup = Completer<void>();
    nextEnglishSetup = setup;
    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    setup.complete();
    await tester.pumpAndSettle();
    expect(utterances, isEmpty);
  });
}
