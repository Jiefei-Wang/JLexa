import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/waveform_service.dart';
import 'package:jlexa/features/repeater/widgets/waveform_view.dart';

void main() {
  testWidgets(
    'pending local window shows progress and disables every cut edit',
    (tester) async {
      var edits = 0;
      var additions = 0;
      var deletions = 0;
      final segment = AudioSegment(
        id: 'cut',
        lessonId: 'lesson',
        text: '',
        startMs: 8000,
        endMs: 12000,
      );
      Future<void> show({required bool pending, bool editable = true}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 320,
                  child: WaveformView(
                    fullPeaks: const [.1, .2, .1],
                    totalDurationMs: 30000,
                    currentPositionMs: 10000,
                    segments: [segment],
                    currentSegment: segment,
                    waveformService: WaveformService(),
                    isWindowProcessing: pending,
                    onSegmentBoundsChanged: editable
                        ? (_, _, _, _) => edits++
                        : null,
                    onAddCut: () => additions++,
                    onDeleteCut: () => deletions++,
                  ),
                ),
              ),
            ),
          );
      IconButton action(String tooltip) => tester.widget<IconButton>(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tooltip),
      );
      await show(pending: false);
      await tester.tap(find.byTooltip('Edit segment boundaries'));
      await tester.pump();
      expect(action('Edit segment boundaries').isSelected, true);
      expect(find.byKey(const ValueKey('cut-start-handle')), findsOneWidget);

      await show(pending: true);
      final spinner = find.byKey(
        const ValueKey('window-segmentation-progress'),
      );
      expect(spinner, findsOneWidget);
      expect(
        tester.getCenter(spinner).dy,
        closeTo(tester.getCenter(find.text('Local Window')).dy, 1),
      );
      expect(action('Edit segment boundaries').isSelected, false);
      for (final tooltip in [
        'Edit segment boundaries',
        'Add cut at playhead',
        'Delete active cut',
      ]) {
        expect(action(tooltip).onPressed, isNull);
        await tester.tap(find.byTooltip(tooltip));
      }
      expect(find.byKey(const ValueKey('cut-start-handle')), findsNothing);
      expect([edits, additions, deletions], [0, 0, 0]);
      expect(tester.takeException(), isNull);

      await show(pending: false);
      expect(spinner, findsNothing);
      expect(action('Edit segment boundaries').isSelected, false);
      await tester.tap(find.byTooltip('Add cut at playhead'));
      expect(additions, 1);
      await tester.tap(find.byTooltip('Edit segment boundaries'));
      await tester.pump();
      await show(pending: false, editable: false);
      expect(action('Edit segment boundaries').isSelected, false);
      expect(find.byKey(const ValueKey('cut-start-handle')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
