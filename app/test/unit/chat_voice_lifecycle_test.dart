import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/chat_repository.dart';
import 'package:jlexa/core/ai/speech_engine.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/features/ai_chat/ai_chat_controller.dart';
import 'package:jlexa/features/ai_chat/chat_text.dart';
import 'package:record/record.dart';

class MemoryChats extends ChatRepository {
  final conversations = <String, ChatConversation>{};
  @override
  Future<List<ChatConversation>> list() async => conversations.values.toList();
  @override
  Future<ChatConversation?> get(String id) async => conversations[id];
  @override
  Future<void> save(ChatConversation conversation) async {
    conversations[conversation.id] = conversation;
  }

  @override
  Future<void> delete(String id) async => conversations.remove(id);
}

class ControlledRecorder implements AudioRecorder {
  Completer<bool>? permission;
  Completer<void>? startGate;
  int permissionCalls = 0;
  int starts = 0;
  int cancels = 0;
  bool running = false;
  String? path;

  @override
  Future<bool> hasPermission({bool request = true}) async {
    permissionCalls++;
    return permission?.future ?? true;
  }

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    starts++;
    this.path = path;
    await startGate?.future;
    running = true;
  }

  @override
  Future<String?> stop() async {
    running = false;
    return path;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    running = false;
  }

  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ControlledVoiceEngine implements SpeechRecognitionEngine {
  @override
  bool isLoaded = true;
  final requests = <String>[];
  final cancelled = <String>[];
  final results = <Completer<List<AudioSegment>>>[];
  @override
  Future<List<AudioSegment>> transcribeAudio({
    required String audioPath,
    required String lessonId,
    String? requestId,
    int nThreads = 4,
    void Function(double)? onProgress,
  }) {
    requests.add(requestId!);
    final result = Completer<List<AudioSegment>>();
    results.add(result);
    onProgress?.call(.5);
    return result.future;
  }

  void complete(String text) => results.last.complete([
    AudioSegment(
      id: 'voice',
      lessonId: 'voice_input',
      startMs: 0,
      endMs: 500,
      text: text,
    ),
  ]);
  @override
  Future<void> cancelRequest(String requestId) async {
    // Deliberately allow native results after cancellation to test ownership.
    cancelled.add(requestId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ControlledTts implements FlutterTts {
  final languages = <String>[];
  final utterances = <String>[];
  final completions = <Completer<int>>[];
  bool holdSpeech = false;
  bool available = true;
  int stops = 0;
  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async => 1;
  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;
  @override
  Future<dynamic> setLanguage(String language) async {
    languages.add(language);
    return 1;
  }

  @override
  Future<dynamic> isLanguageAvailable(String language) async => available;
  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    utterances.add(text);
    if (!holdSpeech) return 1;
    final completion = Completer<int>();
    completions.add(completion);
    return completion.future;
  }

  @override
  Future<dynamic> stop() async {
    stops++;
    for (final completion in completions) {
      if (!completion.isCompleted) completion.complete(0);
    }
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> flushVoice() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late ControlledRecorder recorder;
  late ControlledVoiceEngine speech;
  late ControlledTts tts;
  late AiChatController chat;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('jlexa-voice-test');
    recorder = ControlledRecorder();
    speech = ControlledVoiceEngine();
    tts = ControlledTts();
    chat = AiChatController(
      aiService: AiService(speech: speech),
      speechEngine: speech,
      repository: MemoryChats(),
      audioRecorder: recorder,
      tts: tts,
      recordingPathBuilder: () async => '${temp.path}/recording.wav',
    );
    await chat.ready;
  });
  tearDown(() async {
    chat.dispose();
    await flushVoice();
    await temp.delete(recursive: true);
  });

  test(
    'permission and native start cannot leave an invisible microphone running',
    () async {
      recorder.permission = Completer<bool>();
      final starting = chat.startStopRecording();
      await flushVoice();
      await chat.startStopRecording();
      expect(recorder.permissionCalls, 1);
      chat.setActive(false);
      recorder.permission!.complete(true);
      await starting;
      await flushVoice();
      expect(recorder.starts, 0);
      expect(chat.voiceState, ChatVoiceState.idle);

      chat.setActive(true);
      recorder.startGate = Completer<void>();
      final secondStart = chat.startStopRecording();
      await flushVoice();
      expect(recorder.starts, 1);
      chat.setActive(false);
      recorder.startGate!.complete();
      await secondStart;
      await flushVoice();
      expect(recorder.running, isFalse);
      expect(recorder.cancels, 1);
      expect(chat.voiceState, ChatVoiceState.idle);
    },
  );

  test(
    'new chat waits for voice cancellation and discards late results',
    () async {
      await chat.startStopRecording();
      await File(recorder.path!).writeAsString('temporary audio');
      final recognition = chat.startStopRecording();
      await flushVoice();
      expect(chat.voiceState, ChatVoiceState.transcribing);
      expect(chat.voiceProgress, .5);
      final oldConversation = chat.conversationId;
      final switching = chat.newChat();
      await flushVoice();
      expect(chat.voiceState, ChatVoiceState.cancelling);
      expect(chat.isReady, isFalse);
      expect(speech.cancelled, [speech.requests.single]);
      await chat.startStopRecording();
      expect(recorder.starts, 1);
      speech.complete('Old conversation text');
      expect(await recognition, isNull);
      await switching;
      expect(chat.conversationId, isNot(oldConversation));
      expect(chat.voiceState, ChatVoiceState.idle);
      expect(await File(recorder.path!).exists(), isFalse);
      expect(chat.messages, isEmpty);
      await chat.startStopRecording();
      expect(recorder.starts, 2);
      await chat.cancelVoiceInput();
    },
  );

  test(
    'offscreen recording cancels, missing model never opens microphone',
    () async {
      speech.isLoaded = false;
      await chat.startStopRecording();
      expect(recorder.permissionCalls, 0);
      expect(chat.voiceErrorMessage, contains('Whisper'));
      speech.isLoaded = true;
      await chat.startStopRecording();
      expect(recorder.running, isTrue);
      chat.setActive(false);
      await flushVoice();
      expect(recorder.running, isFalse);
      expect(speech.requests, isEmpty);
    },
  );

  test('read aloud strips Markdown, selects language, stops, and reports unavailable voice', () async {
    tts.holdSpeech = true;
    final reading = chat.speak(
      '**你好**，请读 [hello](https://example.test)',
      messageId: 'answer',
    );
    await flushVoice();
    expect(tts.languages.last, 'zh-CN');
    expect(tts.utterances.single, '你好，请读 hello');
    expect(chat.speakingMessageId, 'answer');
    await chat.speak('same answer', messageId: 'answer');
    await reading;
    expect(chat.speakingMessageId, isNull);
    tts.holdSpeech = false;
    await chat.speak('An **English** answer');
    expect(tts.languages.last, 'en-US');
    tts.available = false;
    await chat.speak('中文');
    expect(chat.speechErrorMessage, contains('Chinese'));
    expect(
      chatPlainText(
        '1. **Say**\n2. *Tell*\n![diagram](https://example.test/image.png)',
      ),
      'Say Tell diagram',
    );
  });
}
