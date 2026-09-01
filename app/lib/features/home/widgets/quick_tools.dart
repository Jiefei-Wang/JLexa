import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class QuickToolsGrid extends StatelessWidget {
  final VoidCallback onOpenDictionary;
  final VoidCallback onOpenTranslation;
  final VoidCallback onOpenAiChat;
  final VoidCallback onOpenSpeechToText;

  const QuickToolsGrid({
    super.key,
    required this.onOpenDictionary,
    required this.onOpenTranslation,
    required this.onOpenAiChat,
    required this.onOpenSpeechToText,
  });

  Widget _buildToolItem({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: AppTypography.labelLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppTypography.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: AppColors.textTertiary,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Quick Tools', style: AppTypography.titleSmall),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.0,
          children: [
            _buildToolItem(
              title: 'Offline Dictionary',
              subtitle: 'Look up words offline',
              icon: Icons.menu_book,
              iconColor: AppColors.primary,
              iconBg: AppColors.primaryLight,
              onTap: onOpenDictionary,
            ),
            _buildToolItem(
              title: 'AI Translation',
              subtitle: 'Translate text instantly',
              icon: Icons.translate,
              iconColor: AppColors.secondary,
              iconBg: AppColors.secondaryLight,
              onTap: onOpenTranslation,
            ),
            _buildToolItem(
              title: 'Ask AI',
              subtitle: 'Ask questions, get answers',
              icon: Icons.chat_bubble_outline,
              iconColor: AppColors.accentPurple,
              iconBg: AppColors.accentPurpleLight,
              onTap: onOpenAiChat,
            ),
            _buildToolItem(
              title: 'Speech to Text',
              subtitle: 'Convert speech to text',
              icon: Icons.mic_none,
              iconColor: AppColors.warning,
              iconBg: AppColors.warningLight,
              onTap: onOpenSpeechToText,
            ),
          ],
        ),
      ],
    );
  }
}
