import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Playback controls only. Cut editing lives directly on the waveform.
class SegmentControls extends StatelessWidget {
  final bool isPlaying;
  final bool isRepeatOne;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleRepeatOne;
  final VoidCallback onPrevSentence;
  final VoidCallback onNextSentence;
  const SegmentControls({
    super.key,
    required this.isPlaying,
    required this.isRepeatOne,
    required this.onTogglePlay,
    required this.onToggleRepeatOne,
    required this.onPrevSentence,
    required this.onNextSentence,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          tooltip: 'Previous cut',
          onPressed: onPrevSentence,
          icon: const Icon(Icons.skip_previous),
        ),
        IconButton(
          tooltip: isPlaying ? 'Pause' : 'Play',
          onPressed: onTogglePlay,
          icon: Icon(
            isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
            size: 44,
            color: AppColors.primary,
          ),
        ),
        IconButton(
          tooltip: 'Next cut',
          onPressed: onNextSentence,
          icon: const Icon(Icons.skip_next),
        ),
        IconButton(
          tooltip: 'Repeat active cut',
          onPressed: onToggleRepeatOne,
          icon: Icon(
            Icons.repeat_one,
            color: isRepeatOne ? AppColors.primary : AppColors.textSecondary,
          ),
        ),
      ],
    ),
  );
}
