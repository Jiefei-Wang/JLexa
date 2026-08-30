import 'package:flutter/material.dart';

import '../../../core/audio/audio_models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class SegmentControls extends StatelessWidget {
  final AudioSegment? currentSegment;
  final bool snapToSpeech;
  final ValueChanged<bool> onToggleSnap;
  final VoidCallback onCutStart;
  final VoidCallback onAddCut;
  final VoidCallback onCutEnd;
  final VoidCallback onMergeNext;

  // Playback handlers
  final bool isPlaying;
  final bool isRepeatOne;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleRepeatOne;
  final VoidCallback onPrevSentence;
  final VoidCallback onNextSentence;

  const SegmentControls({
    super.key,
    required this.currentSegment,
    required this.snapToSpeech,
    required this.onToggleSnap,
    required this.onCutStart,
    required this.onAddCut,
    required this.onCutEnd,
    required this.onMergeNext,
    required this.isPlaying,
    required this.isRepeatOne,
    required this.onTogglePlay,
    required this.onToggleRepeatOne,
    required this.onPrevSentence,
    required this.onNextSentence,
  });

  String _formatDetailedTimestamp(int ms) {
    final int hours = ms ~/ 3600000;
    final int minutes = (ms % 3600000) ~/ 60000;
    final int seconds = (ms % 60000) ~/ 1000;
    final int millis = ms % 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final int startMs = currentSegment?.startMs ?? 0;
    final int endMs = currentSegment?.endMs ?? 0;
    final int durSec = ((endMs - startMs) / 1000).round();

    return Column(
      children: [
        // Adjust Segment header & Snap toggle
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Adjust Segment', style: AppTypography.labelLarge),
            Row(
              children: [
                const Text(
                  'Snap to speech',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 6),
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: snapToSpeech,
                    onChanged: onToggleSnap,
                    activeThumbColor: AppColors.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Cut Buttons Row
        Row(
          children: [
            _buildEditButton(
              icon: Icons.remove_circle_outline,
              label: 'Cut Start',
              onTap: onCutStart,
            ),
            const SizedBox(width: 8),
            _buildEditButton(
              icon: Icons.add_circle_outline,
              label: 'Add Cut',
              onTap: onAddCut,
              isPrimary: true,
            ),
            const SizedBox(width: 8),
            _buildEditButton(
              icon: Icons.remove_circle_outline,
              label: 'Cut End',
              onTap: onCutEnd,
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Segment Timestamp Badge & Merge action
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Segment: ${_formatDetailedTimestamp(startMs)} - ${_formatDetailedTimestamp(endMs)} (${durSec}s)',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(
                Icons.merge_type,
                size: 16,
                color: AppColors.textSecondary,
              ),
              tooltip: 'Merge with next segment',
              onPressed: onMergeNext,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Main Audio Playback Bar
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Prev Sentence
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(
                    Icons.skip_previous,
                    size: 26,
                    color: AppColors.textPrimary,
                  ),
                  onPressed: onPrevSentence,
                  tooltip: 'Previous Sentence',
                ),
                const Text(
                  'Prev\nSentence',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),

            // Repeat One Toggle
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    Icons.repeat_one,
                    size: 26,
                    color: isRepeatOne
                        ? AppColors.primary
                        : AppColors.textTertiary,
                  ),
                  onPressed: onToggleRepeatOne,
                  tooltip: 'Repeat Current Sentence',
                ),
                Text(
                  'Repeat One',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: isRepeatOne
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: isRepeatOne
                        ? AppColors.primary
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),

            // Big Play/Pause Button
            GestureDetector(
              onTap: onTogglePlay,
              child: Container(
                width: 58,
                height: 58,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x402563EB),
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(
                  isPlaying ? Icons.pause : Icons.play_arrow,
                  size: 32,
                  color: Colors.white,
                ),
              ),
            ),

            // Next Sentence
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(
                    Icons.skip_next,
                    size: 26,
                    color: AppColors.textPrimary,
                  ),
                  onPressed: onNextSentence,
                  tooltip: 'Next Sentence',
                ),
                const Text(
                  'Next\nSentence',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEditButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isPrimary = false,
  }) {
    return Expanded(
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(
          icon,
          size: 16,
          color: isPrimary ? AppColors.primary : AppColors.textSecondary,
        ),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isPrimary ? AppColors.primary : AppColors.textPrimary,
          ),
        ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 8),
          side: BorderSide(
            color: isPrimary ? AppColors.primary : AppColors.border,
          ),
          backgroundColor: isPrimary
              ? AppColors.primaryLight
              : AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
}
