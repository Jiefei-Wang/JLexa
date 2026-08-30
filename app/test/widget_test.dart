import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/audio/audio_service.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/audio/waveform_service.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:jlexa/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_helper.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  testWidgets('JLexaApp launches and displays Home', (
    WidgetTester tester,
  ) async {
    final dictionaryRepo = DictionaryRepository();
    final vocabularyRepo = VocabularyRepository();
    final lessonRepo = LessonRepository();
    final audioService = AudioService();
    final waveformService = WaveformService();
    final aiService = AiService();

    await tester.runAsync(() async {
      await dictionaryRepo.lookupWord('resilient');
      await tester.pumpWidget(
        JLexaApp(
          dictionaryRepo: dictionaryRepo,
          vocabularyRepo: vocabularyRepo,
          lessonRepo: lessonRepo,
          audioService: audioService,
          waveformService: waveformService,
          aiService: aiService,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 600));
    });

    await tester.pump();
    expect(find.text('JLexa'), findsOneWidget);
  });
}
