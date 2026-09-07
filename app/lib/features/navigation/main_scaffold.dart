import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/ai/ai_service.dart';
import '../../core/ai/model_downloader.dart';
import '../../core/ai/model_manager.dart';
import '../../core/ai/model_storage.dart';
import '../../core/ai/native_ai_bridge.dart';
import '../../core/audio/audio_models.dart';
import '../../core/audio/audio_service.dart';
import '../../core/audio/lesson_repository.dart';
import '../../core/audio/waveform_service.dart';
import '../../core/dictionary/dictionary_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/vocabulary/vocabulary_repository.dart';
import '../ai_chat/ai_chat_screen.dart';
import '../dictionary/dictionary_screen.dart';
import '../home/home_screen.dart';
import '../repeater/repeater_screen.dart';
import '../settings/settings_screen.dart';
import '../vocabulary/vocabulary_screen.dart';

class MainScaffold extends StatefulWidget {
  final DictionaryRepository dictionaryRepo;
  final VocabularyRepository vocabularyRepo;
  final LessonRepository lessonRepo;
  final AudioService audioService;
  final WaveformService waveformService;
  final AiService aiService;
  final ModelManager? modelManager;

  const MainScaffold({
    super.key,
    required this.dictionaryRepo,
    required this.vocabularyRepo,
    required this.lessonRepo,
    required this.audioService,
    required this.waveformService,
    required this.aiService,
    this.modelManager,
  });

  @override
  State<MainScaffold> createState() => MainScaffoldState();
}

class MainScaffoldState extends State<MainScaffold> {
  final GlobalKey<HomeScreenState> _homeKey = GlobalKey<HomeScreenState>();
  final GlobalKey<RepeaterScreenState> _repeaterKey =
      GlobalKey<RepeaterScreenState>();
  late final ModelManager _modelManager;
  bool _ownsModelManager = false;
  int _currentIndex = 0;
  final List<int> _tabHistory = [];
  DateTime? _lastExitBack;
  bool _isImporting = false;
  String? _targetDictionaryWord;
  int _dictionaryInitialTab = 0;
  bool _focusDictionaryInput = false;
  int _dictionaryNavigationRevision = 0;
  AudioLesson? _activeLesson;

  @override
  void initState() {
    super.initState();
    if (widget.modelManager != null) {
      _modelManager = widget.modelManager!;
    } else {
      _modelManager = ModelManager(
        storage: ModelStorage(),
        downloader: DioModelDownloader(),
        aiService: widget.aiService,
      );
      _ownsModelManager = true;
    }
  }

  @override
  void dispose() {
    if (_ownsModelManager) {
      _modelManager.dispose();
    }
    super.dispose();
  }

  void switchToTab(int index) {
    if (index == _currentIndex) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _lastExitBack = null;
    if (index == 0) {
      _tabHistory.clear();
    } else {
      _tabHistory.add(_currentIndex);
    }
    setState(() {
      _currentIndex = index;
    });
    if (index == 0) {
      _homeKey.currentState?.refresh();
    }
  }

  Future<void> handleLessonDeleted(String lessonId) async {
    await _repeaterKey.currentState?.prepareLessonDeletion(lessonId);
    if (_activeLesson?.id == lessonId) {
      setState(() {
        _activeLesson = null;
      });
    }
  }

  void openDictionaryForWord(String word, {int selectedTab = 0}) {
    switchToTab(1);
    setState(() {
      _targetDictionaryWord = word;
      _dictionaryInitialTab = selectedTab;
      _focusDictionaryInput = word.trim().isEmpty;
      _dictionaryNavigationRevision++;
      _currentIndex = 1; // Dictionary tab
    });
  }

  void openRepeaterForLesson(AudioLesson lesson) {
    switchToTab(2);
    setState(() {
      _activeLesson = lesson;
      _currentIndex = 2; // Repeater tab
    });
  }

  void openAiChatWithContext({
    required String lessonTitle,
    required String sentenceText,
    String? prevSentence,
    String? nextSentence,
    int startMs = 0,
    int endMs = 0,
    List<String> uncertainWords = const [],
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AiChatScreen(
          aiService: widget.aiService,
          speechEngine: widget.aiService.speechEngine,
          initialContext: {
            'lessonTitle': lessonTitle,
            'sentenceText': sentenceText,
            'prevSentence': prevSentence,
            'nextSentence': nextSentence,
            'startMs': startMs,
            'endMs': endMs,
            'uncertainWords': uncertainWords,
          },
        ),
      ),
    );
  }

  Future<void> importAudioFile() async {
    if (_isImporting) return;
    _isImporting = true;
    ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? progressNotice;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'm4a', 'wav', 'aac', 'ogg', 'flac'],
      );

      if (result != null && result.files.single.path != null) {
        if (!mounted) return;
        progressNotice = ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            duration: Duration(hours: 1),
            content: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Expanded(child: Text('Importing audio…')),
              ],
            ),
          ),
        );
        final originalPath = result.files.single.path!;
        final hash = await widget.lessonRepo.audioFingerprint(originalPath);
        final existing = await widget.lessonRepo.findByAudioFingerprint(hash);
        if (!mounted) return;
        if (existing != null) {
          openRepeaterForLesson(existing);
          return;
        }
        final fileName = result.files.single.name;
        final docDir = await getApplicationDocumentsDirectory();
        final lessonsDir = Directory(p.join(docDir.path, 'lessons'));
        if (!await lessonsDir.exists()) {
          await lessonsDir.create(recursive: true);
        }

        final lessonId = const Uuid().v4();
        final targetPath = p.join(
          lessonsDir.path,
          '${DateTime.now().millisecondsSinceEpoch}_$fileName',
        );
        await File(originalPath).copy(targetPath);

        // Extract genuine audio duration via fast metadata detection, falling back to full audio info
        int durationMs = 0;
        try {
          if (Platform.isAndroid &&
              widget.aiService.speechEngine is NativeWhisperEngine) {
            final engine = widget.aiService.speechEngine as NativeWhisperEngine;
            final meta = await engine.getAudioMetadata(targetPath);
            if (meta != null && meta['durationMs'] != null) {
              durationMs = (meta['durationMs'] as num).toInt();
            }
            if (durationMs <= 0) {
              final info = await engine.extractAudioInfo(targetPath);
              if (info != null && info['durationMs'] != null) {
                durationMs = (info['durationMs'] as num).toInt();
              }
            }
          }
        } catch (_) {}

        final newLesson = AudioLesson(
          id: lessonId,
          title: fileName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), ''),
          originalFileName: fileName,
          localPath: targetPath,
          durationMs: durationMs,
          createdAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
          transcriptStatus: widget.aiService.speechEngine.isLoaded
              ? TranscriptStatus.none
              : TranscriptStatus.pendingModel,
        );

        await widget.lessonRepo.saveLesson(newLesson);
        await widget.lessonRepo.setAudioFingerprint(newLesson.id, hash);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Imported "${newLesson.title}"'),
              duration: const Duration(seconds: 2),
            ),
          );
        }

        if (mounted) openRepeaterForLesson(newLesson);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error importing audio: $e')));
      }
    } finally {
      progressNotice?.close();
      _isImporting = false;
    }
  }

  void _handleBack() {
    if (_currentIndex != 0) {
      setState(() {
        _currentIndex = _tabHistory.isEmpty ? 0 : _tabHistory.removeLast();
      });
      if (_currentIndex == 0) _homeKey.currentState?.refresh();
      _lastExitBack = null;
      return;
    }
    final now = DateTime.now();
    if (_lastExitBack != null &&
        now.difference(_lastExitBack!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastExitBack = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('再按一次返回键退出 / Press back again to exit'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: [
            HomeScreen(
              key: _homeKey,
              dictionaryRepo: widget.dictionaryRepo,
              lessonRepo: widget.lessonRepo,
              aiService: widget.aiService,
              onOpenDictionary: openDictionaryForWord,
              onOpenLesson: openRepeaterForLesson,
              onDeleteLesson: handleLessonDeleted,
              onOpenSettings: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(
                      aiService: widget.aiService,
                      modelManager: _modelManager,
                    ),
                  ),
                );
              },
              onOpenAiChat: () => switchToTab(4),
              onOpenTranslation: () =>
                  openDictionaryForWord('', selectedTab: 1),
              onOpenListening: () => switchToTab(2),
              onOpenVocabulary: () => switchToTab(3),
              onImportAudio: importAudioFile,
            ),
            DictionaryScreen(
              dictionaryRepo: widget.dictionaryRepo,
              vocabularyRepo: widget.vocabularyRepo,
              aiService: widget.aiService,
              initialWord: _targetDictionaryWord,
              navigationRevision: _dictionaryNavigationRevision,
              initialTab: _dictionaryInitialTab,
              focusOnNavigation: _focusDictionaryInput,
            ),
            RepeaterScreen(
              key: _repeaterKey,
              lessonRepo: widget.lessonRepo,
              audioService: widget.audioService,
              waveformService: widget.waveformService,
              aiService: widget.aiService,
              dictionaryRepo: widget.dictionaryRepo,
              vocabularyRepo: widget.vocabularyRepo,
              activeLesson: _activeLesson,
              onOpenAiChat: openAiChatWithContext,
              onImportAudio: importAudioFile,
            ),
            VocabularyScreen(
              vocabularyRepo: widget.vocabularyRepo,
              onOpenWordInDictionary: openDictionaryForWord,
            ),
            AiChatScreen(
              aiService: widget.aiService,
              speechEngine: widget.aiService.speechEngine,
              isActive: _currentIndex == 4,
            ),
          ],
        ),
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            border: Border(
              top: BorderSide(color: AppColors.border, width: 0.8),
            ),
          ),
          child: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (index) => switchToTab(index),
            backgroundColor: AppColors.surface,
            indicatorColor: AppColors.primaryLight,
            elevation: 0,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home, color: AppColors.primary),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.menu_book_outlined),
                selectedIcon: Icon(Icons.menu_book, color: AppColors.primary),
                label: 'Dictionary',
              ),
              NavigationDestination(
                icon: Icon(Icons.graphic_eq_outlined),
                selectedIcon: Icon(Icons.graphic_eq, color: AppColors.primary),
                label: 'Listening',
              ),
              NavigationDestination(
                icon: Icon(Icons.style_outlined),
                selectedIcon: Icon(Icons.style, color: AppColors.primary),
                label: 'Study',
              ),
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble, color: AppColors.primary),
                label: 'Ask AI',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
