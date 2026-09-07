import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/features/repeater/widgets/transcript_view.dart';

void main() {
  const segment = AudioSegment(
    id: 'cut',
    lessonId: 'lesson',
    startMs: 0,
    endMs: 2000,
    text: 'Complete sentence.',
  );
  testWidgets(
    'visible subtitle offers collection saving and retains word actions',
    (tester) async {
      var saves = 0;
      String? tappedWord;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TranscriptView(
              segment: segment,
              auto: false,
              onAutoChanged: (_) {},
              onWordTap: (word) => tappedWord = word,
              onAddToCollection: () => saves++,
            ),
          ),
        ),
      );
      expect(find.text('Tap a word to see its explanation'), findsNothing);
      await tester.tap(find.text('Add to Collection'));
      await tester.tap(find.text('Complete'));
      expect(saves, 1);
      expect(tappedWord, 'Complete');
    },
  );

  testWidgets(
    'hidden subtitle cannot be saved and busy button cannot duplicate save',
    (tester) async {
      var saves = 0;
      Widget view(AudioSegment? cut, {bool saving = false}) => MaterialApp(
        home: Scaffold(
          body: TranscriptView(
            segment: cut,
            auto: false,
            onAutoChanged: (_) {},
            onWordTap: (_) {},
            isSavingToCollection: saving,
            onAddToCollection: () => saves++,
          ),
        ),
      );
      await tester.pumpWidget(view(null));
      expect(find.text('Add to Collection'), findsNothing);
      await tester.pumpWidget(view(segment, saving: true));
      await tester.tap(find.text('Saving…'));
      expect(saves, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );

  testWidgets('collection action fits narrow screen at large text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: TranscriptView(
                segment: segment,
                auto: false,
                onAutoChanged: (_) {},
                onWordTap: (_) {},
                onAddToCollection: () {},
                onPlaySentence: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
