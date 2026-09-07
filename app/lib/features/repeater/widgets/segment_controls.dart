import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Playback controls only. Cut editing lives directly on the waveform.
class SegmentControls extends StatelessWidget {
  final bool isPlaying;
  final bool isRepeatOne;
  final bool isAutoStop;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleRepeatOne;
  final VoidCallback onPrevSentence;
  final VoidCallback onNextSentence;
  final VoidCallback? onReplay;
  final VoidCallback? onToggleAutoStop;
  const SegmentControls({
    super.key,
    required this.isPlaying,
    required this.isRepeatOne,
    required this.onTogglePlay,
    required this.onToggleRepeatOne,
    required this.onPrevSentence,
    required this.onNextSentence,
    this.onReplay,
    this.isAutoStop = true,
    this.onToggleAutoStop,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Wrap(
      alignment: WrapAlignment.spaceEvenly,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 4,
      children: [
        IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: 'Previous cut',
          onPressed: onPrevSentence,
          icon: const Icon(Icons.skip_previous),
        ),
        IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: isPlaying ? 'Pause' : 'Play',
          onPressed: onTogglePlay,
          icon: Icon(
            isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
            size: 44,
            color: AppColors.primary,
          ),
        ),
        IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: 'Next cut',
          onPressed: onNextSentence,
          icon: const Icon(Icons.skip_next),
        ),
        IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: 'Replay active cut',
          onPressed: onReplay,
          icon: const Icon(Icons.replay),
        ),
        IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: 'Repeat active cut',
          onPressed: onToggleRepeatOne,
          icon: Icon(
            Icons.repeat_one,
            color: isRepeatOne ? AppColors.primary : AppColors.textSecondary,
          ),
        ),
        IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: 'Auto-stop at cut end',
          isSelected: isAutoStop,
          onPressed: onToggleAutoStop,
          style: IconButton.styleFrom(
            foregroundColor: isAutoStop
                ? AppColors.primary
                : AppColors.textSecondary,
            backgroundColor: isAutoStop ? AppColors.primaryLight : null,
          ),
          icon: const Icon(Icons.stop_circle_outlined),
        ),
      ],
    ),
  );
}
