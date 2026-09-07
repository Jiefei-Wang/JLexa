import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:jlexa/features/home/home_screen.dart';
import 'package:jlexa/features/home/widgets/lesson_card.dart';

import '../test_helper.dart';

class _Dictionary extends DictionaryRepository {
  @override
  Future<List<String>> getRecentSearches({int limit = 10}) async => [
    'Yesterday',
  ];
}

class _Lessons extends LessonRepository {
  @override
  Future<List<AudioLesson>> getAllLessons() async => [];
}

void main() {
  setUpAll(setupMockPlatformChannels);

  testWidgets(
    'Home shortcuts and search open the requested task on small phones',
    (tester) async {
      tester.view.physicalSize = const Size(320, 680);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ai = AiService();
      addTearDown(ai.dispose);
      final queries = <String>[];
      var listening = 0;
      var translation = 0;
      var vocabulary = 0;
      var chat = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: HomeScreen(
            dictionaryRepo: _Dictionary(),
            lessonRepo: _Lessons(),
            aiService: ai,
            onOpenDictionary: queries.add,
            onOpenLesson: (_) => fail('There is no lesson to open'),
            onOpenSettings: () {},
            onOpenAiChat: () => chat++,
            onOpenTranslation: () => translation++,
            onOpenListening: () => listening++,
            onOpenVocabulary: () => vocabulary++,
            onImportAudio: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Dictionary'));
      expect(queries, ['']);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Listening'));
      expect(listening, 1);
      await tester.enterText(find.byType(TextField), 'What does “Alice” mean?');
      await tester.tap(find.byTooltip('Search dictionary'));
      await tester.pumpAndSettle();
      expect(queries.last, 'What does “Alice” mean?');
      expect(chat, 0);
      await tester.scrollUntilVisible(
        find.text('AI Translation'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI Translation'));
      expect(translation, 1);
      await tester.scrollUntilVisible(
        find.text('Saved Vocabulary'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved Vocabulary'));
      expect(vocabulary, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Deleting a lesson requires a deliberate confirmation', (
    tester,
  ) async {
    var deleted = 0;
    final now = DateTime.now();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LessonCard(
            lesson: AudioLesson(
              id: 'qa',
              title: 'QA lesson',
              originalFileName: 'qa.wav',
              localPath: 'qa.wav',
              createdAt: now,
              lastOpenedAt: now,
            ),
            onTap: () {},
            onDelete: () => deleted++,
          ),
        ),
      ),
    );
    Future<void> openDelete() async {
      await tester.tap(find.byTooltip('Lesson options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete lesson'));
      await tester.pumpAndSettle();
    }

    await openDelete();
    expect(deleted, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleted, 0);
    await openDelete();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
  });
}
