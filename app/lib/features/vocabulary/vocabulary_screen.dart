import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/vocabulary/vocabulary_models.dart';
import '../../core/vocabulary/vocabulary_repository.dart';
import 'vocabulary_controller.dart';
import 'vocabulary_detail_screen.dart';
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
  bool _isStartingReview = false;
  final Set<String> _removingIds = {};

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

  Future<void> _startReview() async {
    if (_isStartingReview) return;
    FocusScope.of(context).unfocus();
    setState(() => _isStartingReview = true);
    try {
      final dueWords = await widget.vocabularyRepo.getDueWords();
      if (!mounted) return;
      if (dueWords.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No entries due for review right now.')),
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
      if (mounted) await _controller.loadWords();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open review. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isStartingReview = false);
    }
  }

  Future<bool> _removeWord(VocabularyWord word) async {
    if (!_removingIds.add(word.id)) return false;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: const Text('Remove saved entry?'),
          content: Text(
            'Remove “${word.word}” and its review progress from Study?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return false;
      await _controller.deleteWord(word.id);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Removed from Study')));
      }
      return true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not remove this entry. Please try again.'),
          ),
        );
      }
      return false;
    } finally {
      _removingIds.remove(word.id);
    }
  }

  void _openSavedEntry(VocabularyWord word) {
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VocabularyDetailScreen(
          word: word,
          onOpenDictionary: widget.onOpenWordInDictionary,
          onRemove: () => _removeWord(word),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text('Study', style: AppTypography.titleMedium),
      ),
      body: SafeArea(
        top: false,
        child: CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_controller.dueCount > 0) ...[
                      FilledButton.icon(
                        onPressed: _isStartingReview ? null : _startReview,
                        icon: const Icon(Icons.school_outlined),
                        label: Text(
                          'Review due entries (${_controller.dueCount})',
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _searchController,
                      onChanged: _controller.setSearchQuery,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => FocusScope.of(context).unfocus(),
                      decoration: InputDecoration(
                        hintText: 'Filter saved entries',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear filter',
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  _controller.setSearchQuery('');
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildFilterChip(0, 'All (${_controller.allCount})'),
                          _buildFilterChip(1, 'Due (${_controller.dueCount})'),
                          _buildFilterChip(
                            2,
                            'Learning (${_controller.learningCount})',
                          ),
                          _buildFilterChip(
                            3,
                            'Mastered (${_controller.masteredCount})',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
            if (_controller.isLoading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_controller.words.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.style_outlined,
                        size: 54,
                        color: AppColors.textTertiary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _controller.allCount == 0
                            ? 'No saved entries yet'
                            : 'No matching entries',
                        style: AppTypography.titleSmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _controller.allCount == 0
                            ? 'Save a word or phrase in Dictionary, or tap a word in a Listening transcript.'
                            : 'Try another filter or search.',
                        style: AppTypography.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                sliver: SliverList.builder(
                  itemCount: _controller.words.length,
                  itemBuilder: (context, index) {
                    final word = _controller.words[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: VocabularyCard(
                        word: word,
                        onTap: () => _openSavedEntry(word),
                        onDelete: () => _removeWord(word),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _buildFilterChip(int index, String label) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: _controller.filterTab == index,
      selectedColor: AppColors.primaryLight,
      onSelected: (_) => _controller.setFilterTab(index),
    ),
  );
}
