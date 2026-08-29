import 'package:flutter/material.dart';
import '../../core/ai/ai_service.dart';
import '../../core/dictionary/dictionary_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/vocabulary/vocabulary_repository.dart';
import 'dictionary_controller.dart';
import 'widgets/ai_word_actions.dart';
import 'widgets/word_detail_card.dart';

class DictionaryScreen extends StatefulWidget {
  final DictionaryRepository dictionaryRepo;
  final VocabularyRepository vocabularyRepo;
  final AiService aiService;
  final String? initialWord;

  const DictionaryScreen({
    super.key,
    required this.dictionaryRepo,
    required this.vocabularyRepo,
    required this.aiService,
    this.initialWord,
  });

  @override
  State<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends State<DictionaryScreen> {
  late final DictionaryController _controller;
  final TextEditingController _searchTextController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = DictionaryController(
      dictionaryRepo: widget.dictionaryRepo,
      vocabularyRepo: widget.vocabularyRepo,
      aiService: widget.aiService,
      initialWord: widget.initialWord ?? 'resilient',
    );
    _searchTextController.text = widget.initialWord ?? 'resilient';
  }

  @override
  void didUpdateWidget(covariant DictionaryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialWord != null && widget.initialWord != oldWidget.initialWord) {
      _searchTextController.text = widget.initialWord!;
      _controller.search(widget.initialWord!);
    }
  }

  @override
  void dispose() {
    _searchTextController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final entry = _controller.currentEntry;

        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            elevation: 0,
            title: const Text('Dictionary', style: AppTypography.titleMedium),
            actions: [
              IconButton(
                icon: Icon(
                  _controller.isSaved ? Icons.star : Icons.star_border,
                  color: _controller.isSaved ? Colors.amber : AppColors.textPrimary,
                ),
                onPressed: _controller.currentEntry != null
                    ? () {
                        _controller.toggleSaveToVocabulary();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              _controller.isSaved ? 'Saved to Vocabulary' : 'Removed from Vocabulary',
                            ),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      }
                    : null,
                tooltip: 'Save to Vocabulary',
              ),
            ],
          ),
          body: Column(
            children: [
              // Search Header
              Container(
                color: AppColors.surface,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TextField(
                  controller: _searchTextController,
                  onChanged: _controller.onQueryChanged,
                  onSubmitted: _controller.search,
                  decoration: InputDecoration(
                    hintText: 'Search word...',
                    prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
                    suffixIcon: _searchTextController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchTextController.clear();
                              _controller.onQueryChanged('');
                            },
                          )
                        : null,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
              ),

              // Suggestions overlay if searching
              if (_controller.suggestions.isNotEmpty)
                Container(
                  color: AppColors.surface,
                  child: Column(
                    children: _controller.suggestions.map((s) {
                      return ListTile(
                        leading: const Icon(Icons.search, size: 18, color: AppColors.textSecondary),
                        title: Text(s, style: AppTypography.bodyMedium),
                        dense: true,
                        onTap: () {
                          _searchTextController.text = s;
                          _controller.search(s);
                        },
                      );
                    }).toList(),
                  ),
                ),

              const Divider(height: 1),

              // Main content
              Expanded(
                child: _controller.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : entry == null
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.search_off, size: 48, color: AppColors.textTertiary),
                                const SizedBox(height: 12),
                                Text('No entry found for "${_controller.currentQuery}"', style: AppTypography.titleSmall),
                                const SizedBox(height: 4),
                                const Text('Try searching another word like "resilient", "prioritize", or "meticulous".',
                                    style: AppTypography.bodySmall, textAlign: TextAlign.center),
                              ],
                            ),
                          )
                        : ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              // Word header
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(entry.word, style: AppTypography.wordDisplay),
                                            const SizedBox(width: 8),
                                            IconButton(
                                              icon: const Icon(Icons.volume_up, color: AppColors.primary, size: 24),
                                              onPressed: () => _controller.speak(entry.word),
                                              tooltip: 'Pronounce word',
                                            ),
                                          ],
                                        ),
                                        Text(entry.phonetic, style: AppTypography.phonetic),
                                      ],
                                    ),
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      if (entry.isHighFrequency)
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: AppColors.successLight,
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: const Text('High Frequency',
                                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.success)),
                                        ),
                                      const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: AppColors.warningLight,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(entry.partOfSpeech,
                                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.warning)),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),

                              // Segmented View Tabs
                              Container(
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: Row(
                                  children: [
                                    _buildTabButton(0, 'Dictionary'),
                                    _buildTabButton(1, 'AI Translation'),
                                    _buildTabButton(2, 'AI Explanation'),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 14),

                              // Tab Content
                              if (_controller.selectedTab == 0) ...[
                                WordDetailCard(
                                  entry: entry,
                                  onSpeak: _controller.speak,
                                  onSynonymTap: (syn) {
                                    _searchTextController.text = syn;
                                    _controller.search(syn);
                                  },
                                ),
                              ] else if (_controller.selectedTab == 1) ...[
                                Container(
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    color: AppColors.surface,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: AppColors.border),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Row(
                                        children: [
                                          Icon(Icons.translate, color: AppColors.secondary, size: 20),
                                          SizedBox(width: 8),
                                          Text('AI Translation', style: AppTypography.titleSmall),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      if (_controller.isAiGenerating)
                                        const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
                                      else
                                        Text(
                                          _controller.aiTranslationText.isNotEmpty
                                              ? _controller.aiTranslationText
                                              : (entry.chineseDefinitions.isNotEmpty
                                                  ? entry.chineseDefinitions.join('\n')
                                                  : 'No translation available.'),
                                          style: AppTypography.bodyLarge,
                                        ),
                                    ],
                                  ),
                                ),
                              ] else ...[
                                Container(
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    color: AppColors.surface,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: AppColors.border),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Row(
                                        children: [
                                          Icon(Icons.psychology, color: AppColors.accentPurple, size: 20),
                                          SizedBox(width: 8),
                                          Text('AI Contextual Explanation', style: AppTypography.titleSmall),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      if (_controller.isAiGenerating)
                                        const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
                                      else
                                        Text(
                                          _controller.aiExplanationText.isNotEmpty
                                              ? _controller.aiExplanationText
                                              : 'Load a local AI model to use AI explanation.',
                                          style: AppTypography.bodyMedium,
                                        ),
                                    ],
                                  ),
                                ),
                              ],

                              const SizedBox(height: 16),

                              // Ask AI about Word Section
                              AiWordActionsSection(
                                word: entry.word,
                                onAskPrompt: _controller.askAiAboutWord,
                                isGenerating: _controller.isAiGenerating,
                              ),
                              const SizedBox(height: 20),
                            ],
                          ),
              ),

              // Bottom status bar
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: AppColors.surface,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.check_circle, color: AppColors.success, size: 16),
                        SizedBox(width: 6),
                        Text('Offline dictionary available', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                      ],
                    ),
                    Icon(Icons.menu_book, size: 16, color: AppColors.textSecondary),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTabButton(int index, String label) {
    final isSelected = _controller.selectedTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _controller.setSelectedTab(index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primaryLight : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected ? AppColors.primary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
