import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/audio_service.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/audio/waveform_service.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:jlexa/features/repeater/repeater_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  testWidgets(
    'RepeaterScreen renders total progress, waveform, controls, and transcript',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final dictionaryRepo = DictionaryRepository();
      final vocabularyRepo = VocabularyRepository();
      final lessonRepo = LessonRepository();
      final audioService = AudioService();
      final waveformService = WaveformService();
      final aiService = AiService();

      final testLesson = AudioLesson(
        id: 'test_lesson_1',
        title: 'TED Talk: The power of habit',
        originalFileName: 'test.mp3',
        localPath: 'asset:sample.mp3',
        durationMs: 868000,
        currentPositionMs: 504000,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );

      const testSegment = AudioSegment(
        id: 'test_seg_1',
        lessonId: 'test_lesson_1',
        startMs: 504000,
        endMs: 514000,
        text: 'The key is not to prioritize what is on your schedule.',
      );

      await tester.runAsync(() async {
        await lessonRepo.saveLesson(testLesson);
        await lessonRepo.saveSegments('test_lesson_1', [testSegment]);
        await tester.pumpWidget(
          MaterialApp(
            home: RepeaterScreen(
              lessonRepo: lessonRepo,
              audioService: audioService,
              waveformService: waveformService,
              aiService: aiService,
              dictionaryRepo: dictionaryRepo,
              vocabularyRepo: vocabularyRepo,
              activeLesson: testLesson,
              onOpenAiChat: ({
                required String lessonTitle,
                required String sentenceText,
                String? prevSentence,
                String? nextSentence,
                int startMs = 0,
                int endMs = 0,
                List<String> uncertainWords = const [],
              }) {},
              onImportAudio: () {},
            ),
          ),
        );
        await Future.delayed(const Duration(milliseconds: 600));
      });

      await tester.pump();

      // Verify key Repeater UI components
      expect(find.text('Total Progress'), findsOneWidget);
      expect(find.text('Local Window (10 seconds)'), findsOneWidget);
      expect(find.text('Adjust Segment'), findsOneWidget);
      expect(find.text('Snap to speech'), findsOneWidget);
      expect(find.text('Cut Start'), findsOneWidget);
      expect(find.text('Add Cut'), findsOneWidget);
      expect(find.text('Cut End'), findsOneWidget);
      expect(find.text('Transcript'), findsOneWidget);
      expect(find.text('AI Explanation'), findsOneWidget);
    },
  );
}
