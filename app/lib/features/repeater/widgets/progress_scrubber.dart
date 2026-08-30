import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class ProgressScrubber extends StatelessWidget {
  final int positionMs;
  final int durationMs;
  final ValueChanged<int> onSeek;

  const ProgressScrubber({
    super.key,
    required this.positionMs,
    required this.durationMs,
    required this.onSeek,
  });

  String _formatTime(int ms) {
    final int totalSec = (ms / 1000).floor().clamp(0, 86400).toInt();
    final min = totalSec ~/ 60;
    final sec = totalSec % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final double maxVal = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final double currentVal = positionMs
        .toDouble()
        .clamp(0.0, maxVal)
        .toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Total Progress', style: AppTypography.labelLarge),
            Text(
              '${_formatTime(positionMs)} / ${_formatTime(durationMs)}',
              style: AppTypography.bodySmall.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: AppColors.primary,
            inactiveTrackColor: AppColors.border,
            thumbColor: AppColors.primary,
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 7.0,
              elevation: 2,
              pressedElevation: 4,
            ),
            overlayColor: AppColors.primary.withAlpha(40),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
          ),
          child: Slider(
            value: currentVal,
            min: 0.0,
            max: maxVal,
            onChanged: (val) => onSeek(val.toInt()),
          ),
        ),
      ],
    );
  }
}
