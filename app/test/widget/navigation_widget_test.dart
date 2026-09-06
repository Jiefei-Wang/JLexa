import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets(
    'MainScaffold renders navigation destinations and switches tabs',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final dictionaryRepo = DictionaryRepository();
      final vocabularyRepo = VocabularyRepository();
      final lessonRepo = LessonRepository();
      final audioService = AudioService();
      final waveformService = WaveformService();
      final aiService = AiService();

      await tester.runAsync(() async {
        await dictionaryRepo.lookupWord('resilient');
        await Future.delayed(const Duration(milliseconds: 100));
      });

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

      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Verify Home screen loaded by checking app bar title
      expect(find.text('JLexa'), findsOneWidget);
      expect(find.text('Imported Audio Lessons'), findsOneWidget);
      expect(find.text('Quick Tools'), findsOneWidget);

      // Tap on Dictionary bottom navigation bar item
      await tester.tap(find.byIcon(Icons.menu_book_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify Dictionary screen is active
      expect(find.byType(DictionaryScreen), findsOneWidget);

      // Tap on Study/Vocabulary bottom navigation bar item
      await tester.tap(find.byIcon(Icons.style_outlined));
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Verify Study screen is active
      expect(find.byType(VocabularyScreen), findsOneWidget);
      expect(find.text('Vocabulary Study'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(DictionaryScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('JLexa'), findsOneWidget);
      var exitCalls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') exitCalls++;
          return null;
        },
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(exitCalls, 0);
      expect(find.textContaining('Press back again'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(exitCalls, 1);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    },
  );
}
