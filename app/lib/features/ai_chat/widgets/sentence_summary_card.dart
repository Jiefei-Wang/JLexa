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

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.lightbulb_outline,
                      size: 20,
                      color: AppColors.primary,
                    ),
                    SizedBox(width: 8),
                    Text('Context Summary', style: AppTypography.titleSmall),
                  ],
                ),
                TextButton(
                  onPressed: onToggleExpand,
                  child: Text(
                    isExpanded ? 'Hide' : 'Show',
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (isExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '"${contextData.sentenceText}"',
                          style: AppTypography.bodyMedium.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'This sentence emphasizes setting priorities first and organizing your time around what truly matters, instead of reacting to everything on your calendar.',
                          style: AppTypography.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppColors.secondaryLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.track_changes,
                      color: AppColors.secondary,
                      size: 26,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
