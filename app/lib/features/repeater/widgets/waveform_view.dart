import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/audio/audio_models.dart';
import '../../../core/audio/cut_editor.dart';
import '../../../core/audio/waveform_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

typedef CutBoundsCallback = void Function(
  String cutId,
  int revision,
  int startMs,
  int endMs,
);

class WaveformView extends StatefulWidget {
  final List<double> fullPeaks;
  final int totalDurationMs;
  final int currentPositionMs;
  final List<AudioSegment> segments;
  final AudioSegment? currentSegment;
  final WaveformService waveformService;
  final ValueChanged<int>? onSeek;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;
  final CutBoundsCallback? onSegmentBoundsChanged;
  final VoidCallback? onAddCut;
  final VoidCallback? onDeleteCut;
  const WaveformView({
    super.key,
    required this.fullPeaks,
    required this.totalDurationMs,
    required this.currentPositionMs,
    required this.segments,
    required this.currentSegment,
    required this.waveformService,
    this.onSeek,
    this.onSeekStart,
    this.onSeekEnd,
    this.onSegmentBoundsChanged,
    this.onAddCut,
    this.onDeleteCut,
  });
  @override
  State<WaveformView> createState() => _WaveformViewState();
}

class _WaveformViewState extends State<WaveformView> {
  bool _editEnabled = false;
  int? _previewStart, _previewEnd;
  AudioSegment? _gestureCut;
  final _plotKey = GlobalKey();
  int? _gestureWindowStart;
  double _seekDx = 0;
  int _seekOrigin = 0;
  String _time(int ms) {
    final s = (ms / 1000).floor().clamp(0, 86400);
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    const windowMs = 20000;
    final center = widget.currentPositionMs;
    final windowStart = _gestureWindowStart ?? center - windowMs ~/ 2;
    final bars = widget.waveformService.windowBars(
      peaks: widget.fullPeaks,
      durationMs: widget.totalDurationMs,
      windowStartMs: windowStart,
      windowMs: windowMs,
      targetSamples: 160,
    );
    var displayedCuts = widget.segments;
    if (_gestureCut != null) {
      try {
        displayedCuts = CutEditor.resize(
          snapshot: widget.segments,
          cutId: _gestureCut!.id,
          expectedRevision: _gestureCut!.revision,
          newStartMs: _previewStart!,
          newEndMs: _previewEnd!,
          durationMs: widget.totalDurationMs,
        ).cuts;
      } on StateError {
        /* A newer lesson/edit superseded this gesture. */
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Local Window', style: AppTypography.labelLarge),
            ),
            IconButton(
              tooltip: 'Edit segment boundaries',
              isSelected: _editEnabled,
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                foregroundColor: _editEnabled ? AppColors.primary : null,
                backgroundColor: _editEnabled
                    ? AppColors.primary.withValues(alpha: 0.14)
                    : null,
              ),
              onPressed: widget.onSegmentBoundsChanged == null
                  ? null
                  : () {
                      _clearEdit();
                      setState(() => _editEnabled = !_editEnabled);
                    },
              icon: const Icon(Icons.edit_outlined),
              selectedIcon: const Icon(Icons.edit),
            ),
            IconButton(
              tooltip: 'Add cut at playhead',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onAddCut,
              icon: const Icon(Icons.add_circle_outline),
            ),
            IconButton(
              tooltip: 'Delete active cut',
              visualDensity: VisualDensity.compact,
              onPressed: widget.currentSegment != null
                  ? widget.onDeleteCut
                  : null,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_time(max(0, windowStart)), style: AppTypography.labelSmall),
            Text(_time(center), style: AppTypography.labelSmall),
            Text(
              _time(min(widget.totalDurationMs, windowStart + windowMs)),
              style: AppTypography.labelSmall,
            ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 110,
          child: LayoutBuilder(
            builder: (context, box) {
              final width = box.maxWidth;
              double toX(int ms) => (ms - windowStart) / windowMs * width;
              int toMs(double x) => (windowStart + x / width * windowMs)
                  .round()
                  .clamp(0, widget.totalDurationMs);
              final active = _gestureCut ?? widget.currentSegment;
              final sx = active == null
                  ? null
                  : toX(_previewStart ?? active.startMs);
              final ex = active == null
                  ? null
                  : toX(_previewEnd ?? active.endMs);
              Widget handle(bool start, double x) {
                // Split overlapping touch targets between the visible lines.
                // Even a short cut must allow its start to be dragged separately.
                final midpoint = (sx! + ex!) / 2;
                final hitLeft = start ? x - 16 : max(x - 16, midpoint);
                final hitRight = start ? min(x + 16, midpoint) : x + 16;
                return Positioned(
                  left: hitLeft,
                  width: hitRight - hitLeft,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    ignoring:
                        !_editEnabled || widget.onSegmentBoundsChanged == null,
                    child: GestureDetector(
                      key: ValueKey(
                        start ? 'cut-start-handle' : 'cut-end-handle',
                      ),
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) {
                        final c = widget.currentSegment;
                        if (c != null) {
                          setState(() {
                            _gestureCut = c;
                            _gestureWindowStart = windowStart;
                            _previewStart = c.startMs;
                            _previewEnd = c.endMs;
                          });
                          widget.onSeekStart?.call();
                        }
                      },
                      onHorizontalDragUpdate: (d) {
                        final c = _gestureCut;
                        if (c == null) return;
                        final plot =
                            _plotKey.currentContext!.findRenderObject()
                                as RenderBox;
                        final v = toMs(plot.globalToLocal(d.globalPosition).dx);
                        setState(() {
                          if (start && v < (_previewEnd ?? c.endMs)) {
                            _previewStart = v;
                          }
                          if (!start && v > (_previewStart ?? c.startMs)) {
                            _previewEnd = v;
                          }
                        });
                      },
                      onHorizontalDragCancel: _clearEdit,
                      onHorizontalDragEnd: (_) {
                        final c = _gestureCut;
                        if (c != null) {
                          widget.onSegmentBoundsChanged?.call(
                            c.id,
                            c.revision,
                            _previewStart ?? c.startMs,
                            _previewEnd ?? c.endMs,
                          );
                        }
                        _clearEdit();
                      },
                      child: Stack(
                        children: [
                          Positioned(
                            left: x - hitLeft - 1.5,
                            top: 14,
                            bottom: 14,
                            child: Container(
                              key: ValueKey(
                                start ? 'cut-start-line' : 'cut-end-line',
                              ),
                              width: 3,
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }

              return DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Stack(
                    key: _plotKey,
                    children: [
                      ...displayedCuts
                          .where(
                            (c) => toX(c.endMs) > 0 && toX(c.startMs) < width,
                          )
                          .map((c) {
                            // At least one logical pixel per side makes adjacent cuts
                            // distinguishable even when 10 ms is sub-pixel.
                            final inset = min(
                              (toX(c.endMs) - toX(c.startMs)) / 4,
                              max(1.0, width * 10 / windowMs),
                            );
                            final l = (toX(c.startMs) + inset).clamp(
                                  0.0,
                                  width,
                                ),
                                r = (toX(c.endMs) - inset).clamp(0.0, width);
                            return Positioned(
                              key: ValueKey('cut-shade-${c.id}'),
                              left: l,
                              width: max(0, r - l),
                              top: 0,
                              bottom: 0,
                              child: IgnorePointer(
                                child: ColoredBox(
                                  color: AppColors.segmentHighlight.withValues(
                                    alpha: c.id == active?.id ? 0.42 : 0.16,
                                  ),
                                ),
                              ),
                            );
                          }),
                      Positioned.fill(
                        child: GestureDetector(
                          key: const ValueKey('waveform-seek-area'),
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (_) {
                            _seekDx = 0;
                            _seekOrigin = widget.currentPositionMs;
                            widget.onSeekStart?.call();
                          },
                          onHorizontalDragUpdate: (d) {
                            _seekDx += d.delta.dx;
                            widget.onSeek?.call(
                              (_seekOrigin - _seekDx / width * windowMs)
                                  .round()
                                  .clamp(0, widget.totalDurationMs),
                            );
                          },
                          onHorizontalDragEnd: (_) => widget.onSeekEnd?.call(),
                          onHorizontalDragCancel: () =>
                              widget.onSeekEnd?.call(),
                          child: CustomPaint(
                            painter: _WaveformPainter(
                              bars,
                              windowStart,
                              windowMs,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: width / 2 - 1,
                        top: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: AppColors.playhead,
                            child: const SizedBox(width: 2),
                          ),
                        ),
                      ),
                      if (_editEnabled && sx != null && sx >= 0 && sx <= width)
                        handle(true, sx),
                      if (_editEnabled && ex != null && ex >= 0 && ex <= width)
                        handle(false, ex),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _clearEdit() {
    if (_gestureCut != null) widget.onSeekEnd?.call();
    if (mounted) {
      setState(() {
        _gestureCut = null;
        _gestureWindowStart = null;
        _previewStart = null;
        _previewEnd = null;
      });
    }
  }
}

class _WaveformPainter extends CustomPainter {
  final List<WaveformBar> bars;
  final int windowStartMs, windowMs;
  const _WaveformPainter(this.bars, this.windowStartMs, this.windowMs);
  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final p = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.25
      ..color = const Color(0xFF858585);
    for (final bar in bars) {
      final x = (bar.timeMs - windowStartMs) / windowMs * size.width;
      // A fixed square-root scale reveals quiet sound without a gate or
      // normalization that changes as the playback window moves. Raw peaks
      // remain untouched for speech detection.
      final h = max(
        1.0,
        sqrt(bar.amplitude.clamp(0.0, 1.0)) * size.height * .85,
      );
      canvas.drawLine(
        Offset(x, size.height / 2 - h / 2),
        Offset(x, size.height / 2 + h / 2),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.bars != bars ||
      old.windowStartMs != windowStartMs ||
      old.windowMs != windowMs;
}
