import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/ai/ai_service.dart';
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

  const MainScaffold({
    super.key,
    required this.dictionaryRepo,
    required this.vocabularyRepo,
    required this.lessonRepo,
    required this.audioService,
    required this.waveformService,
    required this.aiService,
  });

  @override
  State<MainScaffold> createState() => MainScaffoldState();
}

class MainScaffoldState extends State<MainScaffold> {
  int _currentIndex = 0;
  String? _targetDictionaryWord;
  AudioLesson? _activeLesson;

  void switchToTab(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  void openDictionaryForWord(String word) {
    setState(() {
      _targetDictionaryWord = word;
      _currentIndex = 1; // Dictionary tab
    });
  }

  void openRepeaterForLesson(AudioLesson lesson) {
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
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'm4a', 'wav', 'aac', 'ogg', 'flac'],
      );

      if (result != null && result.files.single.path != null) {
        final originalPath = result.files.single.path!;
        final fileName = result.files.single.name;
        final docDir = await getApplicationDocumentsDirectory();
        final lessonsDir = Directory(p.join(docDir.path, 'lessons'));
        if (!await lessonsDir.exists()) {
          await lessonsDir.create(recursive: true);
        }

        final lessonId = const Uuid().v4();
        final targetPath = p.join(lessonsDir.path, '${DateTime.now().millisecondsSinceEpoch}_$fileName');
        await File(originalPath).copy(targetPath);

        // Extract genuine audio duration via fast metadata detection, falling back to full audio info
        int durationMs = 0;
        try {
          if (Platform.isAndroid && widget.aiService.speechEngine is NativeWhisperEngine) {
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
          transcriptStatus: widget.aiService.speechEngine.isLoaded ? TranscriptStatus.none : TranscriptStatus.pendingModel,
        );

        await widget.lessonRepo.saveLesson(newLesson);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Imported "${newLesson.title}"'),
              action: SnackBarAction(
                label: 'Open',
                onPressed: () => openRepeaterForLesson(newLesson),
              ),
            ),
          );
        }

        openRepeaterForLesson(newLesson);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error importing audio: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeScreen(
            dictionaryRepo: widget.dictionaryRepo,
            lessonRepo: widget.lessonRepo,
            aiService: widget.aiService,
            onOpenDictionary: openDictionaryForWord,
            onOpenLesson: openRepeaterForLesson,
            onOpenSettings: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(aiService: widget.aiService),
                ),
              );
            },
            onOpenAiChat: () => switchToTab(4),
            onOpenVocabulary: () => switchToTab(3),
            onImportAudio: importAudioFile,
          ),
          DictionaryScreen(
            dictionaryRepo: widget.dictionaryRepo,
            vocabularyRepo: widget.vocabularyRepo,
            aiService: widget.aiService,
            initialWord: _targetDictionaryWord,
          ),
          RepeaterScreen(
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
          ),
        ],
      ),
      floatingActionButton: _currentIndex == 0 || _currentIndex == 2
          ? FloatingActionButton(
              onPressed: importAudioFile,
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              elevation: 3,
              tooltip: 'Import Audio Lesson',
              child: const Icon(Icons.add, size: 28),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border, width: 0.8)),
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
    );
  }
}
