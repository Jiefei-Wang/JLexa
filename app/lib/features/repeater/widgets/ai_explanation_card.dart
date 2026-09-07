import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class AiExplanationCard extends StatelessWidget {
  final bool isExpanded;
  final VoidCallback onToggleExpand;
  final String explanation;
  final bool isGenerating;
  final VoidCallback onOpenQa;
  final VoidCallback onGenerate;
  final VoidCallback? onCancel;

  const AiExplanationCard({
    super.key,
    required this.isExpanded,
    required this.onToggleExpand,
    required this.explanation,
    required this.isGenerating,
    required this.onOpenQa,
    required this.onGenerate,
    this.onCancel,
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
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Row(
                    children: [
                      Icon(
                        Icons.psychology,
                        size: 20,
                        color: AppColors.accentPurple,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'AI Explanation',
                          style: AppTypography.titleSmall,
                        ),
                      ),
                    ],
                  ),
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

          // Collapsible body
          if (isExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isGenerating) ...[
                    if (explanation.isNotEmpty)
                      Text(explanation, style: AppTypography.bodyMedium),
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(),
                      ),
                    ),
                    if (onCancel != null)
                      TextButton(
                        onPressed: onCancel,
                        child: const Text('Cancel'),
                      ),
                  ] else
                    explanation.isNotEmpty
                        ? Text(explanation, style: AppTypography.bodyMedium)
                        : OutlinedButton.icon(
                            onPressed: onGenerate,
                            icon: const Icon(Icons.auto_awesome, size: 18),
                            label: const Text('Generate Explanation'),
                          ),
                  if (!isGenerating && explanation.isNotEmpty)
                    TextButton.icon(
                      onPressed: onGenerate,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Generate Again'),
                    ),
                  const SizedBox(height: 16),

                  // Q&A Button
                  Semantics(
                    button: true,
                    child: InkWell(
                      onTap: onOpenQa,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primaryLight,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Icon(
                              Icons.chat_bubble_outline,
                              size: 18,
                              color: AppColors.primary,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Q&A about this sentence',
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              size: 18,
                              color: AppColors.primary,
                            ),
                          ],
                        ),
                      ),
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
