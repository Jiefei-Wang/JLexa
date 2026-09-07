import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/vocabulary/vocabulary_models.dart';
import '../../core/vocabulary/vocabulary_repository.dart';

class VocabularyReviewScreen extends StatefulWidget {
  final List<VocabularyWord> dueWords;
  final VocabularyRepository vocabularyRepo;
  const VocabularyReviewScreen({
    super.key,
    required this.dueWords,
    required this.vocabularyRepo,
  });
  @override
  State<VocabularyReviewScreen> createState() => _VocabularyReviewScreenState();
}

class _VocabularyReviewScreenState extends State<VocabularyReviewScreen> {
  int _currentIndex = 0;
  bool _showAnswer = false;
  int _reviewedCount = 0;
  bool _isSubmittingReview = false;

  Future<void> _handleRating(ReviewRating rating) async {
    if (_isSubmittingReview || _currentIndex >= widget.dueWords.length) return;
    setState(() => _isSubmittingReview = true);
    try {
      await widget.vocabularyRepo.reviewWord(
        widget.dueWords[_currentIndex].id,
        rating,
      );
      if (mounted) {
        setState(() {
          _reviewedCount++;
          _showAnswer = false;
          _currentIndex++;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save this review. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmittingReview = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_currentIndex >= widget.dueWords.length) {
      return Scaffold(
        appBar: AppBar(title: const Text('Review')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Icon(
                Icons.check_circle_outline,
                size: 64,
                color: AppColors.success,
              ),
              const SizedBox(height: 16),
              const Text(
                'All caught up!',
                style: AppTypography.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'You reviewed $_reviewedCount ${_reviewedCount == 1 ? 'entry' : 'entries'} in this session.',
                style: AppTypography.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back to Study'),
              ),
            ],
          ),
        ),
      );
    }

    final word = widget.dueWords[_currentIndex];
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Review ${_currentIndex + 1}/${widget.dueWords.length}'),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scrollEverything =
                constraints.maxHeight < 440 ||
                MediaQuery.textScalerOf(context).scale(14) > 20;
            final progress = LinearProgressIndicator(
              value: _reviewedCount / widget.dueWords.length,
              backgroundColor: AppColors.border,
              color: AppColors.primary,
              minHeight: 6,
            );
            final controls = _showAnswer
                ? _buildRatings(word)
                : SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => setState(() => _showAnswer = true),
                      child: const Text('Show Answer'),
                    ),
                  );
            if (scrollEverything) {
              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  progress,
                  const SizedBox(height: 20),
                  _buildCard(word, scrollable: false),
                  const SizedBox(height: 20),
                  controls,
                ],
              );
            }
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  progress,
                  const SizedBox(height: 20),
                  Expanded(child: _buildCard(word, scrollable: true)),
                  const SizedBox(height: 20),
                  controls,
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCard(VocabularyWord word, {required bool scrollable}) {
    final translation = word.translationSnapshot?.trim() ?? '';
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          word.word,
          style: AppTypography.wordDisplay,
          textAlign: TextAlign.center,
        ),
        if (word.phonetic?.isNotEmpty == true) ...[
          const SizedBox(height: 8),
          Text(word.phonetic!, style: AppTypography.phonetic),
        ],
        const SizedBox(height: 24),
        if (!_showAnswer)
          const Text(
            'Tap card to reveal answer',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.primary, fontSize: 13),
          )
        else ...[
          const Divider(height: 16),
          Text(
            word.definitionSnapshot,
            style: AppTypography.bodyLarge,
            textAlign: TextAlign.center,
          ),
          if (translation.isNotEmpty &&
              translation != word.definitionSnapshot.trim()) ...[
            const SizedBox(height: 16),
            Text(
              translation,
              style: AppTypography.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ],
          if (word.sourceSentence?.isNotEmpty == true) ...[
            const SizedBox(height: 16),
            Text(
              '“${word.sourceSentence!}”',
              style: AppTypography.bodySmall.copyWith(
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ],
    );
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _showAnswer = !_showAnswer),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: scrollable ? SingleChildScrollView(child: content) : content,
        ),
      ),
    );
  }

  Widget _buildRatings(VocabularyWord word) {
    const labels = ['Again', 'Hard', 'Good', 'Easy'];
    const colors = [
      AppColors.error,
      AppColors.warning,
      AppColors.primary,
      AppColors.success,
    ];
    final now = DateTime.now();
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth >= 340 &&
                MediaQuery.textScalerOf(context).scale(14) <= 20
            ? 4
            : 2;
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final rating in ReviewRating.values)
              SizedBox(
                width: width,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: colors[rating.index]),
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _isSubmittingReview
                      ? null
                      : () => _handleRating(rating),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        labels[rating.index],
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: colors[rating.index],
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatDelay(
                          widget.vocabularyRepo
                              .previewReview(word, rating, now: now)
                              .nextReview!
                              .difference(now),
                        ),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: colors[rating.index],
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  String _formatDelay(Duration delay) {
    if (delay.inDays > 0) {
      return '${delay.inDays} ${delay.inDays == 1 ? 'day' : 'days'}';
    }
    if (delay.inHours > 0) return '${delay.inHours} hr';
    return '${delay.inMinutes.clamp(1, 59)} min';
  }
}
