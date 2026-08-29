import 'package:flutter/material.dart';
import '../../../core/audio/audio_models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class TranscriptView extends StatelessWidget {
  final AudioSegment? segment;
  final ValueChanged<String> onWordTap;
  final VoidCallback? onPlaySentence;

  const TranscriptView({
    super.key,
    required this.segment,
    required this.onWordTap,
    this.onPlaySentence,
  });

  Color _getTokenColor(TranscriptToken token) {
    if (token.confidence >= 0.85) {
      return AppColors.textPrimary;
    } else if (token.confidence >= 0.65) {
      return AppColors.warning; // Amber/Orange
    } else {
      return AppColors.error; // Red
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = segment?.text ?? 'No transcript available for this segment.';
    final double confidence = segment?.confidence ?? 1.0;
    final int confidencePercent = (confidence * 100).round();

    final List<TranscriptToken> tokens = segment?.tokens.isNotEmpty == true
        ? segment!.tokens
        : text
            .split(' ')
            .map((w) => TranscriptToken(text: w, confidence: 1.0))
            .toList();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with AI Confidence Badge
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Transcript', style: AppTypography.titleSmall),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: confidence >= 0.85 ? AppColors.successLight : AppColors.warningLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'AI Confidence $confidencePercent%',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: confidence >= 0.85 ? AppColors.success : AppColors.warning,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Interactive Word-by-Word Tokens
          Wrap(
            spacing: 4,
            runSpacing: 6,
            children: tokens.map((token) {
              final color = _getTokenColor(token);
              final isUncertain = token.isUncertain;

              return InkWell(
                onTap: () => onWordTap(token.text),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: isUncertain
                      ? BoxDecoration(
                          color: color.withAlpha(25),
                          borderRadius: BorderRadius.circular(4),
                        )
                      : null,
                  child: Text(
                    token.text,
                    style: AppTypography.transcript.copyWith(
                      color: color,
                      fontWeight: isUncertain ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),

          // Footer helper
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.touch_app, size: 14, color: AppColors.textTertiary),
                  const SizedBox(width: 4),
                  const Text('Tap a word to see explanation', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                ],
              ),
              if (onPlaySentence != null)
                InkWell(
                  onTap: onPlaySentence,
                  borderRadius: BorderRadius.circular(6),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      children: [
                        Icon(Icons.volume_up_outlined, size: 16, color: AppColors.primary),
                        SizedBox(width: 4),
                        Text('Listen', style: TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
