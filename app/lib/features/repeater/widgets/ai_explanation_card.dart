import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class AiExplanationCard extends StatelessWidget {
  final bool isExpanded;
  final VoidCallback onToggleExpand;
  final String explanation;
  final bool isGenerating;
  final VoidCallback onOpenQa;

  const AiExplanationCard({
    super.key,
    required this.isExpanded,
    required this.onToggleExpand,
    required this.explanation,
    required this.isGenerating,
    required this.onOpenQa,
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
                const Row(
                  children: [
                    Icon(Icons.psychology, size: 20, color: AppColors.accentPurple),
                    SizedBox(width: 8),
                    Text('AI Explanation', style: AppTypography.titleSmall),
                  ],
                ),
                TextButton(
                  onPressed: onToggleExpand,
                  child: Text(
                    isExpanded ? 'Hide' : 'Show',
                    style: const TextStyle(color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w600),
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
                  if (isGenerating)
                    const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
                  else
                    Text(
                      explanation.isNotEmpty
                          ? explanation
                          : 'In this sentence, the speaker advises focusing on what truly matters instead of just following a busy schedule.\n\n'
                              '"on your schedule" refers to allocating time on a calendar. '
                              'The sentence highlights that we should schedule our real priorities rather than letting external demands dictate our time.\n\n'
                              'Possible correction: No correction necessary. The transcript appears natural.',
                      style: AppTypography.bodyMedium,
                    ),
                  const SizedBox(height: 16),

                  // Q&A Button
                  InkWell(
                    onTap: onOpenQa,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.chat_bubble_outline, size: 18, color: AppColors.primary),
                              SizedBox(width: 8),
                              Text('Q&A about this sentence', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600, fontSize: 13)),
                            ],
                          ),
                          Icon(Icons.chevron_right, size: 18, color: AppColors.primary),
                        ],
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
