import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_engine.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/ai/chat_repository.dart';
import 'package:jlexa/core/ai/prompt_builder.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:jlexa/features/ai_chat/ai_chat_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';

class ControlledChatEngine implements AiEngine {
  final streams = <StreamController<String>>[];
  final prompts = <List<ChatMessagePayload>>[];
  @override
  bool get isLoaded => true;
  @override
  String get loadedModelPath => 'test.gguf';
  @override
  AiModelState get state => AiModelState.ready;
  @override
  AiGenerationHandle startGeneration(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    final stream = StreamController<String>();
    streams.add(stream);
    prompts.add(chatMessages!);
    return AiGenerationHandle(
      requestId: '${streams.length}',
      stream: stream.stream,
      onCancel: () async {},
    ); // Deliberately permits late chunks after cancellation.
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  setUpAll(() async {
    setupMockPlatformChannels();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('jlexa-chat-tests');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  tearDownAll(() async {
    await AppDatabase.instance.close();
    await dir.delete(recursive: true);
  });

  test(
    'Chat stop, new chat, restart, regeneration, and deletion retain ownership',
    () async {
      final repo = ChatRepository();
      final engine = ControlledChatEngine();
      final ai = AiService(llm: engine);
      final chat = AiChatController(
        aiService: ai,
        speechEngine: ai.speechEngine,
        repository: repo,
      );
      await chat.ready;
      final pending = chat.sendMessage('请用中文解释 hello');
      await Future<void>.delayed(Duration.zero);
      engine.streams[0].add('你好');
      await Future<void>.delayed(Duration.zero);
      final firstId = chat.conversationId;
      await chat.newChat();
      engine.streams[0].add(' stale');
      await engine.streams[0].close();
      await pending;
      expect(chat.messages, isEmpty);
      final saved = (await repo.list()).single;
      expect(saved.messages.last.content, '你好');
      expect(saved.id, firstId);

      await chat.openConversation(saved);
      final staleHistory = (await repo.list()).single;
      final regenerate = chat.regenerate();
      await Future<void>.delayed(Duration.zero);
      expect(engine.prompts.last.where((m) => m.role == 'user').length, 1);
      expect(
        engine.prompts.last.first.content,
        contains('Chinese questions get Chinese answers'),
      );
      engine.streams.last.add('你好，hello 表示问候。');
      await engine.streams.last.close();
      await regenerate;
      expect(chat.messages.length, 2);
      await chat.openConversation(staleHistory);
      expect(chat.messages.last.content, '你好，hello 表示问候。');
      chat.dispose();
      final restored = AiChatController(
        aiService: ai,
        speechEngine: ai.speechEngine,
        repository: repo,
      );
      await restored.ready;
      expect(restored.messages.last.content, '你好，hello 表示问候。');
      await restored.deleteConversation(firstId);
      expect(await repo.list(), isEmpty);
      final cancelled = restored.sendMessage('Cancel before the first token');
      await Future<void>.delayed(Duration.zero);
      await restored.stopGeneration();
      await engine.streams.last.close();
      await cancelled;
      expect(restored.messages.length, 1);
      expect((await repo.list()).single.messages.length, 1);
      await restored.deleteConversation(restored.conversationId);
      restored.dispose();
    },
  );
}
