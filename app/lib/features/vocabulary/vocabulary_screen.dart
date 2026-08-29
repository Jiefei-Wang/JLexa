import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/vocabulary/vocabulary_repository.dart';
import 'vocabulary_controller.dart';
import 'vocabulary_review_screen.dart';
import 'widgets/vocabulary_card.dart';

class VocabularyScreen extends StatefulWidget {
  final VocabularyRepository vocabularyRepo;
  final ValueChanged<String> onOpenWordInDictionary;

  const VocabularyScreen({
    super.key,
    required this.vocabularyRepo,
    required this.onOpenWordInDictionary,
  });

  @override
  State<VocabularyScreen> createState() => _VocabularyScreenState();
}

class _VocabularyScreenState extends State<VocabularyScreen> {
  late final VocabularyController _controller;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = VocabularyController(vocabularyRepo: widget.vocabularyRepo);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _startReview() async {
    final dueWords = await widget.vocabularyRepo.getDueWords();
    if (!mounted) return;

    if (dueWords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No words due for review right now!')),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VocabularyReviewScreen(
          dueWords: dueWords,
          vocabularyRepo: widget.vocabularyRepo,
        ),
      ),
    );

    _controller.loadWords();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            elevation: 0,
            title: const Text('Vocabulary Study', style: AppTypography.titleMedium),
            actions: [
              if (_controller.dueCount > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 12.0),
                  child: ElevatedButton.icon(
                    onPressed: _startReview,
                    icon: const Icon(Icons.school, size: 16),
                    label: Text('Review (${_controller.dueCount})'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                  ),
                ),
            ],
          ),
          body: Column(
            children: [
              // Search field
              Container(
                color: AppColors.surface,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: _controller.setSearchQuery,
                  decoration: const InputDecoration(
                    hintText: 'Filter saved words...',
                    prefixIcon: Icon(Icons.search, color: AppColors.textSecondary),
                    contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
              ),

              // Filter Chips
              Container(
                color: AppColors.surface,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildFilterChip(0, 'All (${_controller.allCount})'),
                      _buildFilterChip(1, 'Due (${_controller.dueCount})'),
                      _buildFilterChip(2, 'Learning (${_controller.learningCount})'),
                      _buildFilterChip(3, 'Mastered (${_controller.masteredCount})'),
                    ],
                  ),
                ),
              ),

              const Divider(height: 1),

              // Word List
              Expanded(
                child: _controller.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _controller.words.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.style_outlined, size: 54, color: AppColors.textTertiary),
                                const SizedBox(height: 12),
                                const Text('No words in this list', style: AppTypography.titleSmall),
                                const SizedBox(height: 6),
                                const Text(
                                  'Look up words in the Dictionary or tap any word in the Repeater transcript to save it here.',
                                  style: AppTypography.bodySmall,
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: _controller.words.length,
                            itemBuilder: (context, index) {
                              final word = _controller.words[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10.0),
                                child: VocabularyCard(
                                  word: word,
                                  onTap: () => widget.onOpenWordInDictionary(word.word),
                                  onDelete: () => _controller.deleteWord(word.id),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFilterChip(int index, String label) {
    final isSelected = _controller.filterTab == index;
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(fontSize: 12, color: isSelected ? AppColors.primary : AppColors.textSecondary, fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500)),
        selected: isSelected,
        selectedColor: AppColors.primaryLight,
        backgroundColor: AppColors.background,
        side: BorderSide(color: isSelected ? AppColors.primary : AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onSelected: (_) => _controller.setFilterTab(index),
      ),
    );
  }
}
