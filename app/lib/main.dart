import 'package:flutter/material.dart';
import 'core/ai/ai_service.dart';
import 'core/audio/audio_service.dart';
import 'core/audio/lesson_repository.dart';
import 'core/audio/waveform_service.dart';
import 'core/dictionary/dictionary_repository.dart';
import 'core/theme/app_theme.dart';
import 'core/vocabulary/vocabulary_repository.dart';
import 'features/navigation/main_scaffold.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dictionaryRepo = DictionaryRepository();
  final vocabularyRepo = VocabularyRepository();
  final lessonRepo = LessonRepository();
  final audioService = AudioService();
  final waveformService = WaveformService();
  final aiService = AiService();

  runApp(
    JLexaApp(
      dictionaryRepo: dictionaryRepo,
      vocabularyRepo: vocabularyRepo,
      lessonRepo: lessonRepo,
      audioService: audioService,
      waveformService: waveformService,
      aiService: aiService,
    ),
  );
}

class JLexaApp extends StatelessWidget {
  final DictionaryRepository dictionaryRepo;
  final VocabularyRepository vocabularyRepo;
  final LessonRepository lessonRepo;
  final AudioService audioService;
  final WaveformService waveformService;
  final AiService aiService;

  const JLexaApp({
    super.key,
    required this.dictionaryRepo,
    required this.vocabularyRepo,
    required this.lessonRepo,
    required this.audioService,
    required this.waveformService,
    required this.aiService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JLexa',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: MainScaffold(
        dictionaryRepo: dictionaryRepo,
        vocabularyRepo: vocabularyRepo,
        lessonRepo: lessonRepo,
        audioService: audioService,
        waveformService: waveformService,
        aiService: aiService,
      ),
    );
  }
}
