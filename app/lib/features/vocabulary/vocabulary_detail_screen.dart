import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/vocabulary/vocabulary_models.dart';

class VocabularyDetailScreen extends StatefulWidget {
  final VocabularyWord word;
  final ValueChanged<String> onOpenDictionary;
  final Future<bool> Function() onRemove;

  const VocabularyDetailScreen({
    super.key,
    required this.word,
    required this.onOpenDictionary,
    required this.onRemove,
  });

  @override
  State<VocabularyDetailScreen> createState() => _VocabularyDetailScreenState();
}

class _VocabularyDetailScreenState extends State<VocabularyDetailScreen> {
  bool _isRemoving = false;

  Future<void> _remove() async {
    if (_isRemoving) return;
    setState(() => _isRemoving = true);
    final removed = await widget.onRemove();
    if (!mounted) return;
    if (removed) {
      Navigator.of(context).pop();
    } else {
      setState(() => _isRemoving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final word = widget.word;
    final translation = word.translationSnapshot?.trim() ?? '';
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Saved entry')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            SelectableText(word.word, style: AppTypography.wordDisplay),
            if (word.phonetic?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(word.phonetic!, style: AppTypography.phonetic),
            ],
            if (word.partOfSpeech?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(word.partOfSpeech!, style: AppTypography.bodySmall),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _isRemoving
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          widget.onOpenDictionary(word.word);
                        },
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('Open Dictionary'),
                ),
                TextButton.icon(
                  onPressed: _isRemoving ? null : _remove,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text('Saved meaning', style: AppTypography.titleSmall),
            const SizedBox(height: 8),
            SelectableText(
              word.definitionSnapshot.isEmpty
                  ? 'No meaning was saved for this entry.'
                  : word.definitionSnapshot,
              style: AppTypography.bodyLarge,
            ),
            if (translation.isNotEmpty &&
                translation != word.definitionSnapshot.trim()) ...[
              const SizedBox(height: 24),
              const Text('Saved translation', style: AppTypography.titleSmall),
              const SizedBox(height: 8),
              SelectableText(translation, style: AppTypography.bodyLarge),
            ],
            if (word.sourceSentence?.isNotEmpty == true) ...[
              const SizedBox(height: 24),
              const Text('Example or context', style: AppTypography.titleSmall),
              const SizedBox(height: 8),
              SelectableText(
                word.sourceSentence!,
                style: AppTypography.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
