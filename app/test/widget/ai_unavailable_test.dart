import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/speech_engine.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/features/ai_chat/ai_chat_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../test_helper.dart';

class MockSpeechEngine implements SpeechRecognitionEngine {
  @override
  bool get isLoaded => false;

  @override
  String? get loadedModelPath => null;

  @override
  Future<void> cancel() async {}

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Future<List<AudioSegment>> transcribeAudio({
    required String audioPath,
    required String lessonId,
    int nThreads = 4,
    void Function(double progress)? onProgress,
  }) async {
    return [];
  }

  @override
  Future<Map<String, dynamic>?> getAudioMetadata(String audioPath) async {
    return {'durationMs': 1000};
  }

  @override
  Future<void> unload() async {}
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  testWidgets('AI Q&A screen displays informative state when no local AI model is loaded', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final aiService = AiService(speech: MockSpeechEngine());

    await tester.pumpWidget(
      MaterialApp(
        home: AiChatScreen(
          aiService: aiService,
          speechEngine: aiService.speechEngine,
          initialContext: const {
            'lessonTitle': 'TED Talk: The power of habit',
            'sentenceText': 'The key is not to prioritize what is on your schedule.',
          },
        ),
      ),
    );

    await tester.pump();

    expect(find.text('AI Q&A'), findsOneWidget);
    expect(find.text('Context Summary'), findsOneWidget);
    expect(find.text('Example Questions'), findsOneWidget);
    expect(find.text('Explain this sentence in Chinese.'), findsOneWidget);

    // Tap an example question when no model is loaded
    await tester.tap(find.text('Explain this sentence in Chinese.'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Verify polite unconfigured guidance is shown instead of crash
    expect(find.textContaining('Load a local AI model in Settings'), findsOneWidget);
  });
}
