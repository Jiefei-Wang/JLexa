import 'dart:async';

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

class DelayedWaveform extends WaveformService {
  final pending = Completer<List<double>>();
  @override
  Future<List<double>> extractAndCacheWaveform(
    String path,
    String id,
    int duration,
  ) => pending.future;
}

// Keep this UI test independent of the audio plugin's shared event channels.
class ScreenAudioService extends AudioService {
  AudioLesson? lesson;
  List<AudioSegment> cuts = [];
  @override
  AudioLesson? get currentLesson => lesson;
  @override
  int get positionMs => lesson?.currentPositionMs ?? 0;
  @override
  int get durationMs => lesson?.durationMs ?? 0;
  @override
  AudioSegment? get currentSegment => cuts.isEmpty ? null : cuts.first;
  @override
  Future<void> loadLesson(
    AudioLesson lesson,
    List<AudioSegment> segments,
  ) async {
    this.lesson = lesson;
    cuts = segments;
    notifyListeners();
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(setupMockPlatformChannels);

  for (final withSavedCuts in [true, false]) {
    testWidgets(
      'RepeaterScreen waits for waveform before declaring no speech (saved cuts: $withSavedCuts)',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final dictionaryRepo = DictionaryRepository();
        final vocabularyRepo = VocabularyRepository();
        final lessonRepo = LessonRepository();
        final audioService = ScreenAudioService();
        final waveformService = DelayedWaveform();
        final aiService = AiService();

        final testLesson = AudioLesson(
          id: 'test_lesson_$withSavedCuts',
          title: 'TED Talk: The power of habit',
          originalFileName: 'test.mp3',
          localPath: 'asset:sample.mp3',
          durationMs: 868000,
          currentPositionMs: 504000,
          createdAt: DateTime.now(),
          lastOpenedAt: DateTime.now(),
        );

        final testSegment = AudioSegment(
          id: 'test_seg_$withSavedCuts',
          lessonId: testLesson.id,
          startMs: 504000,
          endMs: 514000,
          text: 'The key is not to prioritize what is on your schedule.',
        );

        await tester.runAsync(() async {
          await lessonRepo.saveLesson(testLesson);
          await lessonRepo.saveSegments(
            testLesson.id,
            withSavedCuts ? [testSegment] : [],
          );
        });

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

        for (
          var attempt = 0;
          attempt < 100 && find.text('Total Progress').evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pump();

        expect(
          find.text('Preparing waveform and speech segments…'),
          findsOneWidget,
        );
        expect(find.text('No speech cuts'), findsNothing);
        waveformService.pending.complete([]);
        for (
          var attempt = 0;
          attempt < 100 &&
              find
                  .text('Preparing waveform and speech segments…')
                  .evaluate()
                  .isNotEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(
          find.text('Preparing waveform and speech segments…'),
          findsNothing,
        );
        expect(
          find.text('No speech cuts'),
          withSavedCuts ? findsNothing : findsOneWidget,
        );

        // Verify key Repeater UI components
        expect(find.text('Total Progress'), findsOneWidget);
        expect(find.text('Local Window'), findsOneWidget);
        expect(find.text('Adjust Segment'), findsNothing);
        expect(find.byTooltip('Add cut at playhead'), findsOneWidget);
        expect(find.byTooltip('Delete active cut'), findsOneWidget);
        expect(find.text('Transcript'), findsOneWidget);
        expect(find.text('AI Explanation'), findsOneWidget);
        expect(find.text('Generate Explanation'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        audioService.dispose();
      },
    );
  }
}
