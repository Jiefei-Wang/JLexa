import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class RecentLookupsSection extends StatelessWidget {
  final List<String> searches;
  final ValueChanged<String> onWordTap;

  const RecentLookupsSection({
    super.key,
    required this.searches,
    required this.onWordTap,
  });

  @override
  Widget build(BuildContext context) {
    if (searches.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Recent Lookups', style: AppTypography.titleSmall),
            TextButton(
              onPressed: () {},
              child: const Text('See all', style: TextStyle(color: AppColors.primary, fontSize: 13)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: searches.map((word) {
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: ActionChip(
                  avatar: const Icon(Icons.history, size: 16, color: AppColors.textSecondary),
                  label: Text(word, style: AppTypography.bodySmall.copyWith(color: AppColors.textPrimary)),
                  backgroundColor: AppColors.surface,
                  side: const BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  onPressed: () => onWordTap(word),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}
