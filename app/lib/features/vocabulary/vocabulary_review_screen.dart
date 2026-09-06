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

  void _handleRating(ReviewRating rating) async {
    if (_isSubmittingReview || _currentIndex >= widget.dueWords.length) return;
    setState(() {
      _isSubmittingReview = true;
    });

    try {
      final word = widget.dueWords[_currentIndex];
      await widget.vocabularyRepo.reviewWord(word.id, rating);

      if (mounted) {
        setState(() {
          _reviewedCount++;
          _showAnswer = false;
          _currentIndex++;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmittingReview = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.dueWords.isEmpty || _currentIndex >= widget.dueWords.length) {
      return Scaffold(
        appBar: AppBar(title: const Text('Review Completed')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  size: 64,
                  color: AppColors.success,
                ),
                const SizedBox(height: 16),
                const Text('All caught up!', style: AppTypography.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'You reviewed $_reviewedCount words today.',
                  style: AppTypography.bodyMedium,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back to Vocabulary'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final word = widget.dueWords[_currentIndex];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Review (${_currentIndex + 1}/${widget.dueWords.length})'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              // Progress Bar
              LinearProgressIndicator(
                value: (_currentIndex + 1) / widget.dueWords.length,
                backgroundColor: AppColors.border,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppColors.primary,
                ),
                minHeight: 6,
              ),
              const SizedBox(height: 24),

              // Flashcard
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _showAnswer = !_showAnswer;
                    });
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(8),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(word.word, style: AppTypography.wordDisplay),
                          if (word.phonetic != null &&
                              word.phonetic!.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(word.phonetic!, style: AppTypography.phonetic),
                          ],
                          const SizedBox(height: 24),
                          if (!_showAnswer)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primaryLight,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Text(
                                'Tap card to reveal answer',
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 13,
                                ),
                              ),
                            )
                          else ...[
                            const Divider(height: 32),
                            Text(
                              word.definitionSnapshot,
                              style: AppTypography.bodyLarge,
                              textAlign: TextAlign.center,
                            ),
                            if (word.sourceSentence != null &&
                                word.sourceSentence!.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.background,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '"${word.sourceSentence!}"',
                                  style: AppTypography.bodySmall.copyWith(
                                    fontStyle: FontStyle.italic,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Spaced Repetition Buttons
              if (_showAnswer)
                Row(
                  children: [
                    _buildRatingButton(
                      label: 'Again',
                      subtext: 'Today',
                      color: AppColors.error,
                      rating: ReviewRating.again,
                    ),
                    const SizedBox(width: 8),
                    _buildRatingButton(
                      label: 'Hard',
                      subtext: '+1d',
                      color: AppColors.warning,
                      rating: ReviewRating.hard,
                    ),
                    const SizedBox(width: 8),
                    _buildRatingButton(
                      label: 'Good',
                      subtext: '+3d',
                      color: AppColors.primary,
                      rating: ReviewRating.good,
                    ),
                    const SizedBox(width: 8),
                    _buildRatingButton(
                      label: 'Easy',
                      subtext: '+7d',
                      color: AppColors.success,
                      rating: ReviewRating.easy,
                    ),
                  ],
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _showAnswer = true;
                      });
                    },
                    child: const Text('Show Answer'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRatingButton({
    required String label,
    required String subtext,
    required Color color,
    required ReviewRating rating,
  }) {
    return Expanded(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          side: BorderSide(
            color: _isSubmittingReview ? color.withAlpha(80) : color,
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: _isSubmittingReview ? null : () => _handleRating(rating),
        child: Column(
          children: [
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtext,
              style: TextStyle(color: color.withAlpha(180), fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}
