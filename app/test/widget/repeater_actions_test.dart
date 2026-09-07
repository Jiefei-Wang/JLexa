import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/features/repeater/widgets/segment_controls.dart';
import 'package:jlexa/features/repeater/widgets/transcript_view.dart';

void main() {
  testWidgets(
    'Replay sits between Next and Repeat and does not toggle looping',
    (tester) async {
      var replays = 0, loopToggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: SegmentControls(
                isPlaying: false,
                isRepeatOne: false,
                onTogglePlay: () {},
                onToggleRepeatOne: () => loopToggles++,
                onPrevSentence: () {},
                onNextSentence: () {},
                onReplay: () => replays++,
              ),
            ),
          ),
        ),
      );
      final replay = find.byTooltip('Replay active cut');
      expect(
        tester.getCenter(replay).dx,
        greaterThan(tester.getCenter(find.byTooltip('Next cut')).dx),
      );
      expect(
        tester.getCenter(replay).dx,
        lessThan(tester.getCenter(find.byTooltip('Repeat active cut')).dx),
      );
      await tester.tap(replay);
      expect(replays, 1);
      expect(loopToggles, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Transcribe stays in its card, prevents duplicate requests and offers cancellation',
    (tester) async {
      var requests = 0, cancellations = 0;
      Future<void> show({
        bool busy = false,
        bool cancelling = false,
        double? progress,
      }) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: TranscriptView(
                segment: null,
                auto: false,
                onAutoChanged: (_) {},
                onWordTap: (_) {},
                onTranscribe: () => requests++,
                onCancel: () => cancellations++,
                isTranscribing: busy,
                isCancelling: cancelling,
                progress: progress,
              ),
            ),
          ),
        ),
      );
      await show();
      await tester.tap(find.text('Transcribe'));
      expect(requests, 1);
      await show(busy: true, progress: 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .value,
        isNull,
      );
      expect(find.textContaining('No transcript'), findsNothing);
      expect(find.textContaining('Whisper'), findsNothing);
      await tester.tap(find.text('Transcribing…'));
      expect(requests, 1);
      await show(busy: true, progress: .42);
      expect(find.text('Transcribing 42%'), findsOneWidget);
      expect(
        tester.getCenter(find.text('Transcribing 42%')).dy,
        closeTo(tester.getCenter(find.byTooltip('Cancel transcription')).dy, 1),
        reason:
            'Cancel must remain next to the busy action when the group wraps.',
      );
      await tester.tap(find.byTooltip('Cancel transcription'));
      expect(cancellations, 1);
      await show(cancelling: true, progress: .42);
      expect(find.text('Transcribing 42%'), findsNothing);
      expect(find.text('Cancelling…'), findsOneWidget);
      final cancelButton = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Cancelling transcription',
        ),
      );
      expect(cancelButton.onPressed, isNull);
      await show();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('No transcript'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Transcribing and cancel fit together at large text sizes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(
              width: 320,
              child: TranscriptView(
                segment: null,
                auto: false,
                onAutoChanged: (_) {},
                onWordTap: (_) {},
                isTranscribing: true,
                progress: .42,
                onCancel: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Transcribing 42%'), findsOneWidget);
    expect(find.byTooltip('Cancel transcription'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      tester.getCenter(find.text('Transcribing 42%')).dy,
      closeTo(tester.getCenter(find.byTooltip('Cancel transcription')).dy, 1),
    );
  });
}
