import 'package:flutter/material.dart';
import '../../../core/dictionary/dictionary_models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

class WordDetailCard extends StatelessWidget {
  final DictionaryEntry entry;
  final ValueChanged<String> onSpeak;
  final ValueChanged<String>? onSynonymTap;

  const WordDetailCard({
    super.key,
    required this.entry,
    required this.onSpeak,
    this.onSynonymTap,
  });

  @override
  Widget build(BuildContext context) {
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
          // Definition section
          const Text('Definition (Offline)', style: AppTypography.titleSmall),
          const SizedBox(height: 8),
          ...entry.definitions.map((def) => Padding(
                padding: const EdgeInsets.only(bottom: 6.0),
                child: Text(def, style: AppTypography.bodyMedium),
              )),
          if (entry.chineseDefinitions.isNotEmpty) ...[
            const SizedBox(height: 4),
            ...entry.chineseDefinitions.map((cdef) => Padding(
                  padding: const EdgeInsets.only(bottom: 4.0),
                  child: Text(
                    cdef,
                    style: AppTypography.bodyMedium.copyWith(color: AppColors.textSecondary),
                  ),
                )),
          ],

          // Synonyms section
          if (entry.synonyms.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Synonyms', style: AppTypography.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: entry.synonyms.map((syn) {
                return InkWell(
                  onTap: () => onSynonymTap?.call(syn),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      syn,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],

          // Examples section
          if (entry.examples.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text('Examples', style: AppTypography.titleSmall),
            const SizedBox(height: 8),
            ...entry.examples.map((ex) => Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 6.0, right: 8.0),
                        child: Icon(Icons.circle, size: 6, color: AppColors.primary),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(ex.english, style: AppTypography.bodyMedium),
                            if (ex.chinese != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2.0),
                                child: Text(
                                  ex.chinese!,
                                  style: AppTypography.bodySmall.copyWith(color: AppColors.textSecondary),
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.volume_up_outlined, size: 20, color: AppColors.primary),
                        onPressed: () => onSpeak(ex.english),
                        tooltip: 'Pronounce example',
                      ),
                    ],
                  ),
                )),
          ],
        ],
      ),
    );
  }
}
