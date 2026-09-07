import 'package:flutter/material.dart';

import '../../../core/ai/prompt_builder.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class SentenceSummaryCard extends StatelessWidget {
  final SentenceContext contextData;
  final bool isExpanded;
  final VoidCallback onToggleExpand;

  const SentenceSummaryCard({
    super.key,
    required this.contextData,
    required this.isExpanded,
    required this.onToggleExpand,
  });

  String _time(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.format_quote, color: AppColors.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Selected sentence',
                  style: AppTypography.titleSmall,
                ),
              ),
              TextButton(
                onPressed: onToggleExpand,
                child: Text(isExpanded ? 'Hide' : 'Show'),
              ),
            ],
          ),
        ),
        if (isExpanded) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contextData.lessonTitle, style: AppTypography.bodySmall),
                if (contextData.endMs > contextData.startMs) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_time(contextData.startMs)}–${_time(contextData.endMs)}',
                    style: AppTypography.bodySmall,
                  ),
                ],
                const SizedBox(height: 8),
                SelectableText(
                  contextData.sentenceText,
                  style: AppTypography.bodyMedium.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (contextData.previousSentence?.trim().isNotEmpty ??
                    false) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Before: ${contextData.previousSentence}',
                    style: AppTypography.bodySmall,
                  ),
                ],
                if (contextData.nextSentence?.trim().isNotEmpty ?? false) ...[
                  const SizedBox(height: 8),
                  Text(
                    'After: ${contextData.nextSentence}',
                    style: AppTypography.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    ),
  );
}
