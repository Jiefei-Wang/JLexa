import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/waveform_service.dart';
import 'package:jlexa/features/repeater/widgets/waveform_view.dart';

void main() {
  testWidgets(
    'Merge selects a continuous range across gaps and excludes boundary editing',
    (tester) async {
      final cuts = [
        for (var i = 0; i < 3; i++)
          AudioSegment(
            id: '$i',
            lessonId: 'l',
            startMs: 1000 + i * 4000,
            endMs: 3000 + i * 4000,
            text: '',
          ),
      ];
      Map<String, int>? merged;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: WaveformView(
                fullPeaks: const [],
                totalDurationMs: 20000,
                currentPositionMs: 10000,
                segments: cuts,
                currentSegment: cuts.first,
                waveformService: WaveformService(),
                onSegmentBoundsChanged: (_, _, _, _) {},
                onBoundaryEditingChanged: (_) async {},
                onMergeSegments: (selection) async {
                  merged = selection;
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Edit segment boundaries'));
      await tester.pump();
      expect(find.byKey(const ValueKey('cut-start-line')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('merge-segments-button')));
      await tester.pump();
      expect(find.byKey(const ValueKey('cut-start-line')), findsNothing);
      final plot = tester.getRect(
        find.byKey(const ValueKey('waveform-seek-area')),
      );
      await tester.tapAt(Offset(plot.left + 40, plot.center.dy));
      await tester.pump();
      await tester.tapAt(
        Offset(plot.left + 80, plot.center.dy),
      ); // gap: unchanged
      await tester.pump();
      expect(find.textContaining('1 selected'), findsOneWidget);
      await tester.tapAt(Offset(plot.left + 200, plot.center.dy));
      await tester.pump();
      expect(find.textContaining('3 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('merge-segments-button')));
      await tester.pump();
      expect(merged?.keys, ['0', '1', '2']);
      expect(find.byKey(const ValueKey('merge-selection-count')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('merge-segments-button')));
      await tester.pump();
      await tester.tap(find.byTooltip('Edit segment boundaries'));
      await tester.pump();
      expect(find.byKey(const ValueKey('merge-selection-count')), findsNothing);
      expect(find.byKey(const ValueKey('cut-start-line')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
        final oldX = (bar.timeMs - 1000) / 20000 * 400;
        final newX = (bar.timeMs - 1073) / 20000 * 400;
        expect(oldX - newX, closeTo(1.46, .0001));
      }
    },
  );

  test('20 second display preserves quiet peaks in 160 fixed time buckets', () {
    final service = WaveformService();
    final peaks = List.filled(400, 0.0);
    peaks[1] = .001;
    peaks[399] = .8;
    final bars = service.windowBars(
      peaks: peaks,
      durationMs: 20000,
      windowStartMs: 0,
    );
    expect(bars, hasLength(160));
    expect(bars.first.amplitude, .001);
    expect(bars.last.amplitude, .8);
    expect(bars[20].amplitude, 0);
    expect(bars.first.timeMs, 62.5);
    expect(bars.last.timeMs, 19937.5);
    expect(peaks[1], .001); // Display scaling never changes the VAD input.
  });

  testWidgets('Quiet sound is visible and all amplitudes use thin gray bars', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WaveformView(
            fullPeaks: const [0, .01, 1],
            totalDurationMs: 20000,
            currentPositionMs: 10000,
            segments: const [],
            currentSegment: null,
            waveformService: WaveformService(),
          ),
        ),
      ),
    );
    final painter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byKey(const ValueKey('waveform-seek-area')),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter!;
    void paint(Canvas canvas) => painter.paint(canvas, const Size(400, 110));
    expect(paint, paintsExactlyCountTimes(#drawLine, 3));
    final heights = <double>[];
    expect(
      paint,
      paints..everything((method, arguments) {
        if (method != #drawLine) return false;
        final from = arguments[0] as Offset;
        final to = arguments[1] as Offset;
        final pen = arguments[2] as Paint;
        expect(pen.color.toARGB32(), 0xFF858585);
        expect(pen.strokeWidth, 1.25);
        heights.add(to.dy - from.dy);
        return true;
      }),
    );
    expect(heights, hasLength(3));
    expect(heights[1], greaterThan(heights[0] * 5));
    expect(heights[2], greaterThan(heights[1]));
  });

  testWidgets(
    'Subsecond cut handles have independent touch targets in a 20 second window',
    (tester) async {
      const cut = AudioSegment(
        id: 'short',
        lessonId: 'l',
        startMs: 9900,
        endMs: 10300,
        text: '',
      );
      int? savedStart, savedEnd;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: WaveformView(
                  fullPeaks: List.filled(600, .1),
                  totalDurationMs: 30000,
                  currentPositionMs: 10000,
                  segments: const [cut],
                  currentSegment: cut,
                  waveformService: WaveformService(),
                  onSegmentBoundsChanged: (_, _, start, end) {
                    savedStart = start;
                    savedEnd = end;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Edit segment boundaries'));
      await tester.pump();
      final start = tester.getCenter(
        find.byKey(const ValueKey('cut-start-line')),
      );
      final end = tester.getCenter(find.byKey(const ValueKey('cut-end-line')));
      expect(end.dx - start.dx, closeTo(8, .01));
      final startDrag = await tester.startGesture(start);
      await startDrag.moveBy(const Offset(-20, 0));
      await tester.pump();
      await startDrag.moveBy(const Offset(-20, 0));
      await startDrag.up();
      await tester.pump();
      expect(savedStart, closeTo(7900, 30));
      expect(savedEnd, 10300);
      final endDrag = await tester.startGesture(end);
      await endDrag.moveBy(const Offset(20, 0));
      await tester.pump();
      await endDrag.moveBy(const Offset(20, 0));
      await endDrag.up();
      await tester.pump();
      expect(savedStart, 9900);
      expect(savedEnd, closeTo(12300, 30));
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
      expect(find.text('Local Window'), findsOneWidget);
      expect(find.byKey(const ValueKey('cut-start-line')), findsNothing);
      expect(find.byKey(const ValueKey('cut-end-line')), findsNothing);
      final plot = tester.getRect(
        find.byKey(const ValueKey('waveform-seek-area')),
      );
      final end = Offset(plot.center.dx, plot.center.dy);
      final shade = tester.getRect(
        find.byKey(const ValueKey('cut-shade-left')),
      );
      final neighbor = tester.getRect(
        find.byKey(const ValueKey('cut-shade-right')),
      );
      expect(end.dx, closeTo(shade.right + 1, .01));
      expect(neighbor.left - shade.right, closeTo(2, .01));
      // A 4 second cut occupies one fifth of the 20 second plot.
      expect(shade.width + 2, closeTo(80, .01));
      // Locked by default: boundaries are hidden and drags cannot resize cuts.
      await tester.dragFrom(end, const Offset(-60, 0));
      await tester.pump();
      expect(savedEnd, isNull);
      expect(find.byKey(const ValueKey('cut-end-line')), findsNothing);
      final edit = find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Edit segment boundaries',
      );
      expect(tester.widget<IconButton>(edit).isSelected, isFalse);
      await tester.tap(edit);
      await tester.pump();
      expect(tester.widget<IconButton>(edit).isSelected, isTrue);
      final start = tester.getCenter(
        find.byKey(const ValueKey('cut-start-line')),
      );
      expect(start.dx, closeTo(shade.left - 1, .01));
      expect(
        tester.getCenter(find.byKey(const ValueKey('cut-end-line'))).dx,
        end.dx,
      );
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
      expect(savedEnd, closeTo(2000, 30));
      await tester.tap(edit);
      await tester.pump();
      expect(find.byKey(const ValueKey('cut-start-line')), findsNothing);
      expect(find.byKey(const ValueKey('cut-end-line')), findsNothing);
      savedEnd = null;
      await tester.dragFrom(end, const Offset(-60, 0));
      expect(savedEnd, isNull);
    },
  );
}
