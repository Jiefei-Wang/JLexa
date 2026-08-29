import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/audio/audio_service.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/audio/waveform_service.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:jlexa/features/dictionary/dictionary_screen.dart';
import 'package:jlexa/features/navigation/main_scaffold.dart';
import 'package:jlexa/features/vocabulary/vocabulary_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../test_helper.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  testWidgets('MainScaffold renders navigation destinations and switches tabs', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final dictionaryRepo = DictionaryRepository();
    final vocabularyRepo = VocabularyRepository();
    final lessonRepo = LessonRepository();
    final audioService = AudioService();
    final waveformService = WaveformService();
    final aiService = AiService();

    await tester.runAsync(() async {
      await dictionaryRepo.lookupWord('resilient');
      await tester.pumpWidget(
        MaterialApp(
          home: MainScaffold(
            dictionaryRepo: dictionaryRepo,
            vocabularyRepo: vocabularyRepo,
            lessonRepo: lessonRepo,
            audioService: audioService,
            waveformService: waveformService,
            aiService: aiService,
          ),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 600));
    });

    await tester.pump();

    // Verify Home screen loaded by checking app bar title
    expect(find.text('JLexa'), findsOneWidget);
    expect(find.text('Imported Audio Lessons'), findsOneWidget);
    expect(find.text('Quick Tools'), findsOneWidget);

    // Tap on Dictionary bottom navigation bar item
    await tester.tap(find.byIcon(Icons.menu_book_outlined));
    await tester.pump();

    // Verify Dictionary screen is active
    expect(find.byType(DictionaryScreen), findsOneWidget);

    // Tap on Study/Vocabulary bottom navigation bar item
    await tester.tap(find.byIcon(Icons.style_outlined));
    await tester.runAsync(() async {
      await Future.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();

    // Verify Study screen is active
    expect(find.byType(VocabularyScreen), findsOneWidget);
    expect(find.text('Vocabulary Study'), findsOneWidget);
  });
}
