import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/prompt_builder.dart';
import 'package:jlexa/features/ai_chat/ai_chat_controller.dart';
import 'package:jlexa/features/ai_chat/ai_chat_screen.dart';
import 'package:jlexa/features/ai_chat/widgets/chat_bubble.dart';
import 'package:jlexa/features/ai_chat/widgets/sentence_summary_card.dart';

import '../test_helper.dart';
import '../unit/chat_voice_lifecycle_test.dart';

void main() {
  setUpAll(setupMockPlatformChannels);

  for (final nextState in [
    AppLifecycleState.resumed,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    testWidgets(
      'microphone permission inactive then ${nextState.name} preserves only a visible start',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final recorder = ControlledRecorder()..permission = Completer<bool>();
        final speech = ControlledVoiceEngine();
        final ai = AiService(speech: speech);
        final chat = AiChatController(
          aiService: ai,
          speechEngine: speech,
          audioRecorder: recorder,
          tts: ControlledTts(),
          repository: MemoryChats(),
          recordingPathBuilder: () async =>
              '${Directory.systemTemp.path}/jlexa-widget-permission.wav',
        );
        await chat.ready;
        await tester.pumpWidget(
          MaterialApp(
            home: AiChatScreen(
              aiService: ai,
              speechEngine: speech,
              controllerFactory: () => chat,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Voice Input'));
        await tester.pumpAndSettle();
        expect(recorder.permissionCalls, 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        if (nextState == AppLifecycleState.resumed) {
          recorder.permission!.complete(true);
          await tester.pumpAndSettle();
          expect(
            recorder.starts,
            0,
            reason:
                'Permission grant alone must not open an inactive microphone.',
          );
          expect(chat.voiceState, ChatVoiceState.starting);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpAndSettle();
          expect(recorder.starts, 1);
          expect(recorder.running, isTrue);
          expect(chat.voiceState, ChatVoiceState.recording);
        } else {
          if (nextState == AppLifecycleState.hidden) {
            recorder.permission!.complete(true);
            await tester.pumpAndSettle();
            expect(chat.voiceState, ChatVoiceState.starting);
          }
          if (nextState == AppLifecycleState.paused) {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
          }
          tester.binding.handleAppLifecycleStateChanged(nextState);
          await tester.pump();
          if (!recorder.permission!.isCompleted) {
            recorder.permission!.complete(true);
          }
          await tester.pumpAndSettle();
          expect(recorder.starts, 0);
          expect(chat.voiceState, ChatVoiceState.idle);
          if (nextState == AppLifecycleState.paused) {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
          }
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pumpAndSettle();
          expect(
            recorder.starts,
            0,
            reason: 'Returning from the background needs a fresh user request.',
          );
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(flushVoice);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      },
    );
  }

  testWidgets('context is factual and fits a narrow screen at large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: SentenceSummaryCard(
                contextData: const SentenceContext(
                  lessonTitle: 'TED lesson',
                  sentenceText: 'Do you have children?',
                  previousSentence: 'Tell me about yourself.',
                  nextSentence: 'Yes, I do.',
                  startMs: 65000,
                  endMs: 69000,
                ),
                isExpanded: true,
                onToggleExpand: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('TED lesson'), findsOneWidget);
    expect(find.text('1:05–1:09'), findsOneWidget);
    expect(find.text('Do you have children?'), findsOneWidget);
    expect(find.textContaining('priorities'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'assistant Markdown is selectable, wide content scrolls, and images never load',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const answer =
          '**Say** and *tell*.\n\n'
          '1. First example\n2. Second example\n\n'
          '| Long first column | Second column | Third column |\n'
          '| --- | --- | --- |\n| One | Two | Three |\n\n'
          '```text\nvery_long_code_without_any_breaks_012345678901234567890123456789\n```\n'
          '![Example diagram](https://example.test/tracker.png)';
      Widget bubble(String source) => MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: ListView(
              children: [
                ChatBubble(
                  message: ChatMessage(
                    id: 'a',
                    role: 'assistant',
                    content: source,
                    timestamp: DateTime(2026),
                  ),
                  onSpeak: (_) {},
                  onDelete: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(bubble(answer));
      expect(
        tester.widget<MarkdownBody>(find.byType(MarkdownBody)).selectable,
        isTrue,
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('Image: Example diagram'), findsOneWidget);
      expect(find.textContaining('**Say**', findRichText: true), findsNothing);
      expect(
        find.textContaining('Say and tell.', findRichText: true),
        findsWidgets,
      );
      expect(
        tester.getSize(find.byTooltip('Read answer aloud')).width,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byTooltip('Read answer aloud')).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(bubble('**A partial streamed'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(bubble('**A partial streamed answer**'));
      expect(
        find.textContaining('A partial streamed answer', findRichText: true),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'voice results preserve typed drafts and can be inserted explicitly',
    (tester) async {
      final recorder = ControlledRecorder();
      final speech = ControlledVoiceEngine();
      final ai = AiService(speech: speech);
      final chat = AiChatController(
        aiService: ai,
        speechEngine: speech,
        audioRecorder: recorder,
        tts: ControlledTts(),
        repository: MemoryChats(),
        recordingPathBuilder: () async =>
            '${Directory.systemTemp.path}/jlexa-widget-voice-unused.wav',
      );
      await chat.ready;
      await tester.pumpWidget(
        MaterialApp(
          home: AiChatScreen(
            aiService: ai,
            speechEngine: speech,
            controllerFactory: () => chat,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice Input'));
      await tester.pumpAndSettle();
      expect(chat.isRecording, isTrue);
      await tester.enterText(find.byType(TextField), 'Keep my typed draft');
      await tester.tap(find.byTooltip('Stop recording and transcribe'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Transcribing…'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Voice Input',
              ),
            )
            .onPressed,
        isNull,
      );
      speech.complete('Recognized spoken words');
      await tester.pump();
      // The controller deletes a real temporary recording before delivery.
      // Let that filesystem future complete outside Flutter's fake clock.
      await tester.runAsync(flushVoice);
      await tester.pumpAndSettle();
      expect(chat.voiceState, ChatVoiceState.idle);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep my typed draft',
      );
      await tester.scrollUntilVisible(
        find.text('Voice transcript'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Voice transcript'), findsOneWidget);
      await tester.ensureVisible(find.text('Insert into message'));
      await tester.tap(find.text('Insert into message'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep my typed draft\nRecognized spoken words',
      );
      expect(find.text('Voice transcript'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(flushVoice);
    },
  );

  testWidgets(
    'composer and recording controls fit with keyboard and large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final recorder = ControlledRecorder();
      final speech = ControlledVoiceEngine();
      final ai = AiService(speech: speech);
      final chat = AiChatController(
        aiService: ai,
        speechEngine: speech,
        audioRecorder: recorder,
        tts: ControlledTts(),
        repository: MemoryChats(),
        recordingPathBuilder: () async =>
            '${Directory.systemTemp.path}/jlexa-widget-keyboard.wav',
      );
      await chat.ready;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 600),
              viewInsets: EdgeInsets.only(bottom: 280),
              textScaler: TextScaler.linear(2),
            ),
            child: AiChatScreen(
              aiService: ai,
              speechEngine: speech,
              controllerFactory: () => chat,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice Input'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'Line one\nLine two\nLine three\nLine four\nLine five',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(flushVoice);
    },
  );

  testWidgets('switching tabs or covering the route stops microphone capture', (
    tester,
  ) async {
    final recorder = ControlledRecorder();
    final speech = ControlledVoiceEngine();
    final ai = AiService(speech: speech);
    final chat = AiChatController(
      aiService: ai,
      speechEngine: speech,
      audioRecorder: recorder,
      tts: ControlledTts(),
      repository: MemoryChats(),
      recordingPathBuilder: () async =>
          '${Directory.systemTemp.path}/jlexa-widget-voice-hidden.wav',
    );
    await chat.ready;
    var active = true;
    late StateSetter refresh;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return AiChatScreen(
              aiService: ai,
              speechEngine: speech,
              isActive: active,
              controllerFactory: () => chat,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Voice Input'));
    await tester.pumpAndSettle();
    expect(recorder.running, isTrue);
    refresh(() => active = false);
    await tester.pump();
    await tester.runAsync(flushVoice);
    await tester.pumpAndSettle();
    expect(recorder.running, isFalse);
    refresh(() => active = true);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Voice Input'));
    await tester.pumpAndSettle();
    expect(recorder.running, isTrue);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Another screen')),
      ),
    );
    await tester.pump();
    await tester.runAsync(flushVoice);
    await tester.pumpAndSettle();
    expect(recorder.running, isFalse);
    expect(speech.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(flushVoice);
  });
}
