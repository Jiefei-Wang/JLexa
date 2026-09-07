import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/vocabulary/srs_scheduler.dart';
import 'package:jlexa/core/vocabulary/vocabulary_models.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:jlexa/features/vocabulary/vocabulary_detail_screen.dart';
import 'package:jlexa/features/vocabulary/vocabulary_review_screen.dart';
import 'package:jlexa/features/vocabulary/vocabulary_screen.dart';
import 'package:jlexa/features/vocabulary/widgets/vocabulary_card.dart';

class _MemoryVocabulary extends VocabularyRepository {
  final List<VocabularyWord> entries;
  final List<ReviewRating> ratings = [];

  _MemoryVocabulary(this.entries, {super.scheduler});

  @override
  Future<List<VocabularyWord>> getAllWords() async => List.of(entries);
  @override
  Future<void> deleteWord(String id) async {
    entries.removeWhere((word) => word.id == id);
    notifyListeners();
  }

  @override
  Future<void> reviewWord(String id, ReviewRating rating) async {
    final index = entries.indexWhere((word) => word.id == id);
    entries[index] = previewReview(entries[index], rating);
    ratings.add(rating);
    notifyListeners();
  }
}

class _SixHourScheduler implements ISrsScheduler {
  @override
  VocabularyWord scheduleReview(
    VocabularyWord word,
    ReviewRating rating, {
    DateTime? now,
  }) => word.copyWith(
    nextReview: (now ?? DateTime.now()).add(const Duration(hours: 6)),
  );
}

VocabularyWord _entry({String? definition, int interval = 0}) => VocabularyWord(
  id: 'saved-phrase',
  word: 'I will meet Alice tomorrow.',
  definitionSnapshot: definition ?? 'A plan to meet Alice the following day.',
  translationSnapshot: '我明天会见 Alice。',
  sourceSentence: 'We agreed on the meeting time yesterday.',
  source: 'Dictionary',
  dateAdded: DateTime(2026, 9, 1),
  intervalDays: interval,
  reviewCount: interval == 0 ? 0 : 3,
);

Future<void> _pumpPhone(
  WidgetTester tester,
  Widget child, {
  double width = 400,
  double scale = 1,
  double keyboard = 0,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(bottom: 32);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Saved phrase opens full offline snapshots before dictionary lookup',
    (tester) async {
      final meaning = List.filled(
        40,
        'The saved explanation remains available offline.',
      ).join(' ');
      final repo = _MemoryVocabulary([_entry(definition: meaning)]);
      String? openedQuery;
      await _pumpPhone(
        tester,
        VocabularyScreen(
          vocabularyRepo: repo,
          onOpenWordInDictionary: (query) => openedQuery = query,
        ),
      );
      await tester.tap(find.byType(VocabularyCard));
      await tester.pumpAndSettle();
      expect(find.byType(VocabularyDetailScreen), findsOneWidget);
      expect(openedQuery, isNull);
      expect(find.text(meaning), findsOneWidget);
      final list = find.descendant(
        of: find.byType(VocabularyDetailScreen),
        matching: find.byType(ListView),
      );
      await tester.drag(list, const Offset(0, -10000));
      await tester.pumpAndSettle();
      expect(find.text('我明天会见 Alice。'), findsOneWidget);
      expect(
        tester
            .getBottomRight(
              find.text('We agreed on the meeting time yesterday.'),
            )
            .dy,
        lessThan(768),
      );
      await tester.drag(list, const Offset(0, 10000));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Dictionary'));
      await tester.pumpAndSettle();
      expect(openedQuery, 'I will meet Alice tomorrow.');
      expect(find.byType(VocabularyDetailScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Card removal is discoverable and confirmation can be cancelled',
    (tester) async {
      final repo = _MemoryVocabulary([_entry()]);
      await _pumpPhone(
        tester,
        VocabularyScreen(vocabularyRepo: repo, onOpenWordInDictionary: (_) {}),
      );
      await tester.tap(find.byTooltip('Saved entry actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from Study'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.entries, hasLength(1));

      await tester.tap(find.byType(VocabularyCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Remove'),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.entries, isEmpty);
      expect(find.byType(VocabularyDetailScreen), findsNothing);
      expect(find.text('No saved entries yet'), findsOneWidget);
    },
  );

  testWidgets(
    'Review shows the actual scaled intervals and commits the selected one',
    (tester) async {
      final word = _entry(interval: 10);
      final repo = _MemoryVocabulary([word]);
      await _pumpPhone(
        tester,
        VocabularyReviewScreen(dueWords: [word], vocabularyRepo: repo),
      );
      await tester.tap(find.text('Show Answer'));
      await tester.pumpAndSettle();
      for (final label in ['10 min', '12 days', '25 days', '38 days']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text(word.translationSnapshot!), findsOneWidget);
      await tester.tap(find.text('Hard'));
      await tester.pumpAndSettle();
      expect(repo.ratings, [ReviewRating.hard]);
      expect(repo.entries.single.intervalDays, 12);
      expect(
        repo.entries.single.nextReview!.difference(DateTime.now()).inSeconds,
        closeTo(const Duration(days: 12).inSeconds, 2),
      );
      expect(
        find.text('You reviewed 1 entry in this session.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Review previews use the repository configured scheduler', (
    tester,
  ) async {
    final word = _entry();
    final repo = _MemoryVocabulary([word], scheduler: _SixHourScheduler());
    await _pumpPhone(
      tester,
      VocabularyReviewScreen(dueWords: [word], vocabularyRepo: repo),
    );
    await tester.tap(find.text('Show Answer'));
    await tester.pumpAndSettle();
    expect(find.text('6 hr'), findsNWidgets(4));
    await tester.tap(find.text('Easy'));
    await tester.pumpAndSettle();
    expect(
      repo.entries.single.nextReview!.difference(DateTime.now()).inSeconds,
      closeTo(const Duration(hours: 6).inSeconds, 2),
    );
  });

  testWidgets(
    'Study cards and empty filters fit 320dp with large text and keyboard',
    (tester) async {
      final repo = _MemoryVocabulary([_entry()]);
      await _pumpPhone(
        tester,
        VocabularyScreen(vocabularyRepo: repo, onOpenWordInDictionary: (_) {}),
        width: 320,
        scale: 2,
        keyboard: 300,
      );
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'unmatched');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
      await tester.pumpAndSettle();
      expect(find.text('No matching entries'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Large-text review answer and completion remain scrollable with a keyboard',
    (tester) async {
      final word = _entry(
        definition: List.filled(20, 'A detailed saved meaning.').join(' '),
      );
      final repo = _MemoryVocabulary([word]);
      await _pumpPhone(
        tester,
        VocabularyReviewScreen(dueWords: [word], vocabularyRepo: repo),
        width: 320,
        scale: 2,
        keyboard: 300,
      );
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Show Answer'), 300);
      await tester.tap(find.text('Show Answer'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Good'), 300);
      await tester.tap(find.text('Good'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Back to Study'), 300);
      expect(find.text('All caught up!'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
