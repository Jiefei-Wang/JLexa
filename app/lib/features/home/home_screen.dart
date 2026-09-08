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
  final Future<void> Function(String lessonId)? onDeleteLesson;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenDictionaryManager;
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
    required this.onOpenDictionaryManager,
    required this.onImportAudio,
  });

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  late final HomeController _controller;
  final TextEditingController _searchController = TextEditingController();

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
      FocusManager.instance.primaryFocus?.unfocus();
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
            title: const Text('JLexa', style: AppTypography.titleLarge),
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
                      hintText: 'Word, phrase or sentence',
                      prefixIcon: const Icon(
                        Icons.search,
                        color: AppColors.textSecondary,
                      ),
                      suffixIcon: IconButton(
                        icon: const Icon(
                          Icons.arrow_forward,
                          color: AppColors.textSecondary,
                        ),
                        tooltip: 'Search dictionary',
                        onPressed: () =>
                            _handleSearchSubmit(_searchController.text),
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
                    const Expanded(
                      child: Text(
                        'Imported Audio Lessons',
                        style: AppTypography.titleSmall,
                      ),
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
                          if (widget.onDeleteLesson != null) {
                            await widget.onDeleteLesson!(id);
                          }
                          await _controller.deleteLesson(id);
                        },
                      ),
                    ),
                  ),

                const SizedBox(height: 20),

                // Quick Tools Grid
                QuickToolsGrid(
                  onOpenDictionaryManager: widget.onOpenDictionaryManager,
                  onOpenSettings: widget.onOpenSettings,
                ),
                const SizedBox(height: 30),
              ],
            ),
          ),
        );
      },
    );
  }
}
