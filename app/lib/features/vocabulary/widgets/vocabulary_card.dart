import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/vocabulary/vocabulary_models.dart';

class VocabularyCard extends StatelessWidget {
  final VocabularyWord word;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const VocabularyCard({
    super.key,
    required this.word,
    required this.onTap,
    required this.onDelete,
  });

  Color _getStateColor(VocabularyState state) {
    switch (state) {
      case VocabularyState.newWord:
        return AppColors.primary;
      case VocabularyState.learning:
        return AppColors.warning;
      case VocabularyState.review:
        return AppColors.secondary;
      case VocabularyState.mastered:
        return AppColors.success;
    }
  }

  String _getStateLabel(VocabularyState state) {
    switch (state) {
      case VocabularyState.newWord:
        return 'New';
      case VocabularyState.learning:
        return 'Learning';
      case VocabularyState.review:
        return 'Review';
      case VocabularyState.mastered:
        return 'Mastered';
    }
  }

  @override
  Widget build(BuildContext context) {
    final stateColor = _getStateColor(word.state);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(word.word, style: AppTypography.titleSmall),
                      if (word.phonetic != null &&
                          word.phonetic!.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(word.phonetic!, style: AppTypography.bodySmall),
                      ],
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Saved entry actions',
                  onSelected: (_) => onDelete(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove from Study'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: stateColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _getStateLabel(word.state),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: stateColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              word.definitionSnapshot,
              style: AppTypography.bodyMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (word.sourceSentence != null &&
                word.sourceSentence!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '"${word.sourceSentence!}"',
                  style: AppTypography.bodySmall.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(
                  'Reviews: ${word.reviewCount} • Interval: ${word.intervalDays}d',
                  style: AppTypography.labelSmall,
                ),
                if (word.isDue)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warningLight,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'Due for Review',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: AppColors.warning,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
