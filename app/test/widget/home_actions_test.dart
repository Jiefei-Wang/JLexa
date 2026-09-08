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
    'Home keeps search and exposes only dictionary management and settings tools',
    (tester) async {
      tester.view.physicalSize = const Size(320, 680);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ai = AiService();
      addTearDown(ai.dispose);
      final queries = <String>[];
      var dictionaryManager = 0;
      var settings = 0;
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
            onOpenSettings: () => settings++,
            onOpenDictionaryManager: () => dictionaryManager++,
            onImportAudio: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Dictionary'), findsNothing);
      expect(find.text('Listening'), findsNothing);
      expect(find.text('Ask AI'), findsNothing);
      await tester.enterText(find.byType(TextField), 'What does “Alice” mean?');
      await tester.tap(find.byTooltip('Search dictionary'));
      await tester.pumpAndSettle();
      expect(queries.last, 'What does “Alice” mean?');
      await tester.scrollUntilVisible(
        find.text('Dictionary Manager'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dictionary Manager'));
      expect(dictionaryManager, 1);
      await tester.scrollUntilVisible(
        find.text('Settings'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      expect(settings, 1);
      expect(find.text('AI Translation'), findsNothing);
      expect(find.text('Saved Vocabulary'), findsNothing);
      expect(find.text('Offline Dictionary'), findsNothing);
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
