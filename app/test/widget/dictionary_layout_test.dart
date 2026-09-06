import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/dictionary/dictionary_models.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:jlexa/features/dictionary/dictionary_screen.dart';
import 'package:jlexa/features/vocabulary/vocabulary_review_screen.dart';
import 'package:jlexa/core/vocabulary/vocabulary_models.dart';

import '../test_helper.dart';

class _Dictionary extends DictionaryRepository {
  @override
  Future<DictionaryEntry?> lookupWord(String word) async => null;
  @override
  Future<List<String>> searchSuggestions(String query) async =>
      List.generate(6, (i) => 'apple$i');
}

class _Vocabulary extends VocabularyRepository {
  @override
  Future<bool> isWordSaved(String word) async => false;
}

void main() {
  setUpAll(setupMockPlatformChannels);

  testWidgets('Review answer controls stay above Android system navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(
      MaterialApp(
        home: VocabularyReviewScreen(
          vocabularyRepo: _Vocabulary(),
          dueWords: [
            VocabularyWord(
              id: 'sentence',
              word: 'I look forward to seeing you tomorrow.',
              definitionSnapshot: List.filled(
                30,
                'A long explanation.',
              ).join(' '),
              translationSnapshot: '',
              source: 'Dictionary',
              dateAdded: DateTime.now(),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Show Answer')).bottom, lessThan(752));
    await tester.tap(find.text('Show Answer'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.text('Good')).bottom, lessThan(752));
  });

  testWidgets('Long sentence and keyboard suggestions fit a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ai = AiService();
    addTearDown(ai.dispose);
    const sentence =
        'I am looking forward to seeing you tomorrow. Will Alice join us?';
    await tester.pumpWidget(
      MaterialApp(
        home: DictionaryScreen(
          dictionaryRepo: _Dictionary(),
          vocabularyRepo: _Vocabulary(),
          aiService: ai,
          initialWord: sentence,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField).first, 'ap');
    tester.view.viewInsets = const FakeViewPadding(bottom: 350);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('apple0'), findsOneWidget);
  });
}
