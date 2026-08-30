import 'package:flutter/material.dart';

import '../../core/ai/ai_service.dart';
import '../../core/audio/audio_models.dart';
import '../../core/audio/lesson_repository.dart';
import '../../core/dictionary/dictionary_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'home_controller.dart';
import 'widgets/lesson_card.dart';
import 'widgets/quick_tools.dart';
import 'widgets/recent_lookups.dart';

class HomeScreen extends StatefulWidget {
  final DictionaryRepository dictionaryRepo;
  final LessonRepository lessonRepo;
  final AiService aiService;
  final ValueChanged<String> onOpenDictionary;
  final ValueChanged<AudioLesson> onOpenLesson;
  final ValueChanged<String>? onDeleteLesson;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAiChat;
  final VoidCallback onOpenVocabulary;
  final VoidCallback onImportAudio;

  const HomeScreen({
    super.key,
    required this.dictionaryRepo,
    required this.lessonRepo,
    required this.aiService,
    required this.onOpenDictionary,
    required this.onOpenLesson,
    this.onDeleteLesson,
    required this.onOpenSettings,
    required this.onOpenAiChat,
    required this.onOpenVocabulary,
    required this.onImportAudio,
  });

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  late final HomeController _controller;
  final TextEditingController _searchController = TextEditingController();
  int _selectedFilterIndex = 0; // 0: Dictionary, 1: Repeater, 2: AI

  void refresh() {
    _controller.loadData();
  }

  @override
  void initState() {
    super.initState();
    _controller = HomeController(
      dictionaryRepo: widget.dictionaryRepo,
      lessonRepo: widget.lessonRepo,
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleSearchSubmit(String query) {
    if (query.trim().isNotEmpty) {
      widget.onOpenDictionary(query.trim());
      _searchController.clear();
      _controller.loadData();
    }
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
            title: Row(
              children: [
                const Text('JLexa', style: AppTypography.titleLarge),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.workspace_premium,
                        size: 14,
                        color: AppColors.primary,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Pro',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(
                  Icons.settings_outlined,
                  color: AppColors.textPrimary,
                ),
                onPressed: widget.onOpenSettings,
                tooltip: 'Settings & Local Models',
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _controller.loadData,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                // Top Segmented Pill Filter
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      _buildPillButton(0, 'Dictionary'),
                      _buildPillButton(1, 'Repeater'),
                      _buildPillButton(2, 'AI'),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // Search Bar
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: TextField(
                    controller: _searchController,
                    onSubmitted: _handleSearchSubmit,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search words, phrases or sentences',
                      prefixIcon: const Icon(
                        Icons.search,
                        color: AppColors.textSecondary,
                      ),
                      suffixIcon: IconButton(
                        icon: const Icon(
                          Icons.mic_none,
                          color: AppColors.textSecondary,
                        ),
                        onPressed: () {
                          // Quick voice search / AI Q&A
                          widget.onOpenAiChat();
                        },
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                // Recent Lookups
                RecentLookupsSection(
                  searches: _controller.recentSearches,
                  onWordTap: (word) {
                    widget.onOpenDictionary(word);
                    _controller.loadData();
                  },
                ),
                const SizedBox(height: 20),

                // Imported Audio Lessons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Imported Audio Lessons',
                      style: AppTypography.titleSmall,
                    ),
                    TextButton.icon(
                      onPressed: widget.onImportAudio,
                      icon: const Icon(
                        Icons.add,
                        size: 16,
                        color: AppColors.primary,
                      ),
                      label: const Text(
                        'Import',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_controller.lessons.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Center(
                      child: Column(
                        children: [
                          const Icon(
                            Icons.audio_file_outlined,
                            size: 48,
                            color: AppColors.textTertiary,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'No audio lessons yet',
                            style: AppTypography.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Import an MP3/M4A/WAV file to practice listening and sentence repeating.',
                            style: AppTypography.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: widget.onImportAudio,
                            icon: const Icon(
                              Icons.file_upload_outlined,
                              size: 18,
                            ),
                            label: const Text('Import Audio Lesson'),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ..._controller.lessons.map(
                    (lesson) => Padding(
                      padding: const EdgeInsets.only(bottom: 10.0),
                      child: LessonCard(
                        lesson: lesson,
                        onTap: () => widget.onOpenLesson(lesson),
                        onDelete: () async {
                          final id = lesson.id;
                          await _controller.deleteLesson(id);
                          widget.onDeleteLesson?.call(id);
                        },
                      ),
                    ),
                  ),

                const SizedBox(height: 20),

                // Quick Tools Grid
                QuickToolsGrid(
                  onOpenDictionary: () => widget.onOpenDictionary('resilient'),
                  onOpenTranslation: () => widget.onOpenDictionary('resilient'),
                  onOpenAiChat: widget.onOpenAiChat,
                  onOpenSpeechToText: widget.onOpenAiChat,
                ),
                const SizedBox(height: 30),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPillButton(int index, String label) {
    final isSelected = _selectedFilterIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _selectedFilterIndex = index;
          });
          if (index == 0) {
            widget.onOpenDictionary('resilient');
          }
          if (index == 1 && _controller.lessons.isNotEmpty) {
            widget.onOpenLesson(_controller.lessons.first);
          }
          if (index == 2) {
            widget.onOpenAiChat();
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected ? Colors.white : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
