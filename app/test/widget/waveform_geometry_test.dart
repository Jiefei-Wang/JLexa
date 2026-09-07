import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/waveform_service.dart';
import 'package:jlexa/features/repeater/widgets/waveform_view.dart';

void main() {
  test(
    'Scrolling retains the time and amplitude of every shared waveform bar',
    () {
      final service = WaveformService();
      final peaks = List.generate(400, (i) => (i % 7) / 7);
      final a = service.windowBars(
        peaks: peaks,
        durationMs: 20000,
        windowStartMs: 1000,
      );
      final b = service.windowBars(
        peaks: peaks,
        durationMs: 20000,
        windowStartMs: 1073,
      );
      final shared = a
          .where((bar) => b.any((other) => other.timeMs == bar.timeMs))
          .toList();
      expect(shared.length, greaterThan(50));
      for (final bar in shared) {
        expect(
          b.firstWhere((other) => other.timeMs == bar.timeMs).amplitude,
          bar.amplitude,
        );
        final oldX = (bar.timeMs - 1000) / 10000 * 400;
        final newX = (bar.timeMs - 1073) / 10000 * 400;
        expect(oldX - newX, closeTo(2.92, .0001));
      }
    },
  );

  testWidgets(
    'Handles align with real bounds and dragging previews the same shaded bounds',
    (tester) async {
      const left = AudioSegment(
        id: 'left',
        lessonId: 'l',
        startMs: 1000,
        endMs: 5000,
        text: '',
      );
      const right = AudioSegment(
        id: 'right',
        lessonId: 'l',
        startMs: 5000,
        endMs: 9000,
        text: '',
      );
      int? savedEnd;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: WaveformView(
                  fullPeaks: List.filled(200, .3),
                  totalDurationMs: 10000,
                  currentPositionMs: 5000,
                  segments: const [left, right],
                  currentSegment: left,
                  waveformService: WaveformService(),
                  onSegmentBoundsChanged: (_, _, _, end) => savedEnd = end,
                ),
              ),
            ),
          ),
        ),
      );
      final start = tester.getCenter(
        find.byKey(const ValueKey('cut-start-line')),
      );
      final end = tester.getCenter(find.byKey(const ValueKey('cut-end-line')));
      final shade = tester.getRect(
        find.byKey(const ValueKey('cut-shade-left')),
      );
      final neighbor = tester.getRect(
        find.byKey(const ValueKey('cut-shade-right')),
      );
      expect(start.dx, closeTo(shade.left - 1, .01));
      expect(end.dx, closeTo(shade.right + 1, .01));
      expect(neighbor.left - shade.right, closeTo(2, .01));
      expect(end.dx - start.dx, closeTo(160, .01));
      // Locked by default: dragging a visible boundary cannot resize the cut.
      await tester.dragFrom(end, const Offset(-60, 0));
      await tester.pump();
      expect(savedEnd, isNull);
      expect(tester.getCenter(find.byKey(const ValueKey('cut-end-line'))), end);
      final edit = find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Edit segment boundaries',
      );
      expect(tester.widget<IconButton>(edit).isSelected, isFalse);
      await tester.tap(edit);
      await tester.pump();
      expect(tester.widget<IconButton>(edit).isSelected, isTrue);
      final drag = await tester.startGesture(end);
      await drag.moveBy(const Offset(-20, 0));
      await tester.pump();
      await drag.moveBy(const Offset(-40, 0));
      await tester.pump();
      final previewEnd = tester.getCenter(
        find.byKey(const ValueKey('cut-end-line')),
      );
      final previewShade = tester.getRect(
        find.byKey(const ValueKey('cut-shade-left')),
      );
      expect(previewEnd.dx, lessThan(end.dx));
      expect(previewEnd.dx, closeTo(previewShade.right + 1, .01));
      await drag.up();
      expect(savedEnd, closeTo(3500, 30));
      await tester.tap(edit);
      await tester.pump();
      savedEnd = null;
      await tester.dragFrom(end, const Offset(-60, 0));
      expect(savedEnd, isNull);
    },
  );
}
