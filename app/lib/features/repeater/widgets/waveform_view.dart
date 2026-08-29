import 'dart:math';
import 'package:flutter/material.dart';
import '../../../core/audio/audio_models.dart';
import '../../../core/audio/waveform_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class WaveformView extends StatefulWidget {
  final List<double> fullPeaks;
  final int totalDurationMs;
  final int currentPositionMs;
  final AudioSegment? currentSegment;
  final WaveformService waveformService;
  final void Function(int newStartMs, int newEndMs)? onSegmentBoundsChanged;

  const WaveformView({
    super.key,
    required this.fullPeaks,
    required this.totalDurationMs,
    required this.currentPositionMs,
    required this.currentSegment,
    required this.waveformService,
    this.onSegmentBoundsChanged,
  });

  @override
  State<WaveformView> createState() => _WaveformViewState();
}

class _WaveformViewState extends State<WaveformView> {
  // Dragging state
  int? _draggingStartMs;
  int? _draggingEndMs;

  String _formatTime(int ms) {
    final totalSec = (ms / 1000).floor().clamp(0, 86400);
    final min = totalSec ~/ 60;
    final sec = totalSec % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    const int windowDurationMs = 10000; // 10s
    final int centerMs = widget.currentPositionMs;
    final int windowStartMs = centerMs - 5000;
    final int windowEndMs = centerMs + 5000;

    final windowPeaks = widget.waveformService.getWindowSlice(
      fullPeaks: widget.fullPeaks,
      totalDurationMs: widget.totalDurationMs,
      centerPositionMs: centerMs,
      windowDurationMs: windowDurationMs,
      targetSamples: 80,
    );

    final activeStart = _draggingStartMs ?? widget.currentSegment?.startMs ?? (centerMs - 2000);
    final activeEnd = _draggingEndMs ?? widget.currentSegment?.endMs ?? (centerMs + 2000);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title and Speech Legend
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Text('Local Window (10 seconds)', style: AppTypography.labelLarge),
                SizedBox(width: 4),
                Icon(Icons.info_outline, size: 14, color: AppColors.textTertiary),
              ],
            ),
            Row(
              children: [
                Container(
                  width: 12,
                  height: 3,
                  decoration: BoxDecoration(
                    color: AppColors.waveformSpeech,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 4),
                const Text('Speech', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),

        // Clock timestamps (-5s, 0s, +5s)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_formatTime(max(0, windowStartMs)), style: AppTypography.labelSmall),
            Text(_formatTime(centerMs), style: AppTypography.labelSmall.copyWith(fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            Text(_formatTime(min(widget.totalDurationMs, windowEndMs)), style: AppTypography.labelSmall),
          ],
        ),
        const SizedBox(height: 6),

        // Waveform canvas container
        Container(
          height: 110,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final height = constraints.maxHeight;

              // Compute X coordinate for any millisecond timestamp in local window
              double msToX(int ms) {
                final relMs = ms - windowStartMs;
                return (relMs / windowDurationMs) * width;
              }

              int xToMs(double x) {
                final ratio = (x / width).clamp(0.0, 1.0);
                return (windowStartMs + ratio * windowDurationMs).round();
              }

              final double startX = msToX(activeStart).clamp(0.0, width);
              final double endX = msToX(activeEnd).clamp(0.0, width);
              final double centerX = width / 2;

              return Stack(
                children: [
                  // 1. Waveform Peaks
                  CustomPaint(
                    size: Size(width, height),
                    painter: _WaveformPainter(
                      peaks: windowPeaks,
                      speechColor: AppColors.waveformSpeech,
                      silenceColor: AppColors.waveformSilence,
                    ),
                  ),

                  // 2. Translucent Highlighted Segment Region
                  if (endX > startX)
                    Positioned(
                      left: startX,
                      width: max(2.0, endX - startX),
                      top: 0,
                      bottom: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.segmentHighlight,
                          border: Border.symmetric(
                            horizontal: BorderSide(color: AppColors.segmentBorder.withAlpha(120), width: 1.5),
                          ),
                        ),
                      ),
                    ),

                  // 3. Center Playhead Marker (Red vertical line)
                  Positioned(
                    left: centerX - 1,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 2,
                      color: AppColors.playhead,
                    ),
                  ),

                  // 4. Start Handle (Draggable)
                  Positioned(
                    left: startX - 16,
                    top: 0,
                    bottom: 0,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) {
                        setState(() {
                          _draggingStartMs = activeStart;
                          _draggingEndMs = activeEnd;
                        });
                      },
                      onHorizontalDragUpdate: (details) {
                        final newX = startX + details.delta.dx;
                        final newMs = xToMs(newX);
                        if (newMs < activeEnd - 300) {
                          setState(() {
                            _draggingStartMs = newMs;
                          });
                        }
                      },
                      onHorizontalDragEnd: (_) {
                        if (_draggingStartMs != null && widget.onSegmentBoundsChanged != null) {
                          widget.onSegmentBoundsChanged!(_draggingStartMs!, activeEnd);
                        }
                        setState(() {
                          _draggingStartMs = null;
                          _draggingEndMs = null;
                        });
                      },
                      child: SizedBox(
                        width: 32,
                        child: Center(
                          child: Container(
                            width: 4,
                            height: height * 0.8,
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(2),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withAlpha(100),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 5. End Handle (Draggable)
                  Positioned(
                    left: endX - 16,
                    top: 0,
                    bottom: 0,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) {
                        setState(() {
                          _draggingStartMs = activeStart;
                          _draggingEndMs = activeEnd;
                        });
                      },
                      onHorizontalDragUpdate: (details) {
                        final newX = endX + details.delta.dx;
                        final newMs = xToMs(newX);
                        if (newMs > activeStart + 300) {
                          setState(() {
                            _draggingEndMs = newMs;
                          });
                        }
                      },
                      onHorizontalDragEnd: (_) {
                        if (_draggingEndMs != null && widget.onSegmentBoundsChanged != null) {
                          widget.onSegmentBoundsChanged!(activeStart, _draggingEndMs!);
                        }
                        setState(() {
                          _draggingStartMs = null;
                          _draggingEndMs = null;
                        });
                      },
                      child: SizedBox(
                        width: 32,
                        child: Center(
                          child: Container(
                            width: 4,
                            height: height * 0.8,
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(2),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withAlpha(100),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 6),

        // Relative timeline labels: -5s, 0s (Current), +5s
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('-5s', style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
            Text('0s (Current)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            Text('+5s', style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
          ],
        ),
      ],
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> peaks;
  final Color speechColor;
  final Color silenceColor;

  _WaveformPainter({
    required this.peaks,
    required this.speechColor,
    required this.silenceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;

    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.5;

    final double step = size.width / peaks.length;
    final double midY = size.height / 2;

    for (int i = 0; i < peaks.length; i++) {
      final double peak = peaks[i].clamp(0.05, 1.0);
      final double barHeight = max(4.0, peak * (size.height * 0.78));

      final double x = i * step + step / 2;
      final double top = midY - barHeight / 2;
      final double bottom = midY + barHeight / 2;

      paint.color = peak > 0.25 ? speechColor : silenceColor;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.peaks != peaks;
  }
}
