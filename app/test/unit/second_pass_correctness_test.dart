import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/prompt_builder.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../test_helper.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  group('Second-Pass Correctness Unit Tests', () {
    test('AudioSegment containsPosition half-open intervals [start, end)', () {
      const segA = AudioSegment(
        id: 'seg_a',
        lessonId: 'lesson_1',
        startMs: 0,
        endMs: 1000,
        text: 'Segment A',
      );
      const segB = AudioSegment(
        id: 'seg_b',
        lessonId: 'lesson_1',
        startMs: 1000,
        endMs: 2000,
        text: 'Segment B',
      );

      // 0ms belongs to segA
      expect(segA.containsPosition(0), isTrue);
      // 999ms belongs to segA
      expect(segA.containsPosition(999), isTrue);
      // 1000ms does NOT belong to segA (half-open)
      expect(segA.containsPosition(1000), isFalse);
      // 1000ms belongs to segB
      expect(segB.containsPosition(1000), isTrue);

      // Last segment allows exact endpoint match
      expect(segB.containsPosition(2000, isLast: true), isTrue);
    });

    test('AiGenerationSettings copyWith, toMap, fromMap boundary clamping', () {
      const defaultSettings = AiGenerationSettings();
      expect(defaultSettings.temperature, equals(0.7));
      expect(defaultSettings.maxTokens, equals(512));
      expect(defaultSettings.threads, equals(4));

      final updated = defaultSettings.copyWith(
        temperature: 0.9,
        maxTokens: 1024,
      );
      expect(updated.temperature, equals(0.9));
      expect(updated.maxTokens, equals(1024));
      expect(updated.threads, equals(4));

      final map = updated.toMap();
      expect(map['temperature'], equals(0.9));
      expect(map['maxTokens'], equals(1024));

      final fromMap = AiGenerationSettings.fromMap({
        'temperature': 5.0, // out of bounds -> clamped to default 0.7
        'maxTokens': 9999, // out of bounds -> clamped to default 512
        'threads': 0, // out of bounds -> clamped to default 4
      });
      expect(fromMap.temperature, equals(0.7));
      expect(fromMap.maxTokens, equals(512));
      expect(fromMap.threads, equals(4));
    });

    test('PromptBuilder chat message builders structure roles and contents correctly', () {
      final dictMsgs = PromptBuilder.buildDictionaryExplanationMessages('resilient');
      expect(dictMsgs.length, equals(2));
      expect(dictMsgs[0].role, equals('system'));
      expect(dictMsgs[1].role, equals('user'));
      expect(dictMsgs[1].content, contains('resilient'));

      final transMsgs = PromptBuilder.buildTranslationMessages('Hello world');
      expect(transMsgs.length, equals(2));
      expect(transMsgs[0].role, equals('system'));
      expect(transMsgs[1].role, equals('user'));
      expect(transMsgs[1].content, contains('Hello world'));

      final sentenceCtx = const SentenceContext(
        lessonTitle: 'Lesson 1',
        sentenceText: 'Focus on high-impact endeavors.',
        previousSentence: 'When you build a resilient mindset.',
      );
      final sentenceMsgs = PromptBuilder.buildSentenceExplanationMessages(sentenceCtx);
      expect(sentenceMsgs.length, equals(2));
      expect(sentenceMsgs[0].role, equals('system'));
      expect(sentenceMsgs[1].content, contains('Lesson 1'));
      expect(sentenceMsgs[1].content, contains('Focus on high-impact endeavors.'));

      final qaMsgs = PromptBuilder.buildSentenceQAMessages(
        context: sentenceCtx,
        userQuestion: 'What does endeavors mean?',
        chatHistory: [
          {'role': 'user', 'content': 'What is the main point?'},
          {'role': 'assistant', 'content': 'The main point is focus.'},
        ],
      );
      expect(qaMsgs.length, equals(4));
      expect(qaMsgs[0].role, equals('system'));
      expect(qaMsgs[1].role, equals('user'));
      expect(qaMsgs[2].role, equals('assistant'));
      expect(qaMsgs[3].role, equals('user'));
      expect(qaMsgs[3].content, equals('What does endeavors mean?'));
    });

    test('LessonRepository updateLessonDuration and updateTranscriptStatus notify listeners', () async {
      final repo = LessonRepository();
      bool listenerNotified = false;
      repo.addListener(() {
        listenerNotified = true;
      });

      final lesson = AudioLesson(
        id: 'lesson_test_notif',
        title: 'Test Notification',
        originalFileName: 'test.mp3',
        localPath: 'asset:sample.mp3',
        durationMs: 0,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );

      await repo.saveLesson(lesson);
      expect(listenerNotified, isTrue);

      listenerNotified = false;
      await repo.updateLessonDuration('lesson_test_notif', 45000);
      expect(listenerNotified, isTrue);

      final fetched = await repo.getLesson('lesson_test_notif');
      expect(fetched?.durationMs, equals(45000));

      listenerNotified = false;
      await repo.updateTranscriptStatus('lesson_test_notif', TranscriptStatus.completed);
      expect(listenerNotified, isTrue);

      final fetchedAfterStatus = await repo.getLesson('lesson_test_notif');
      expect(fetchedAfterStatus?.transcriptStatus, equals(TranscriptStatus.completed));

      await repo.deleteLesson('lesson_test_notif');
    });
  });
}
