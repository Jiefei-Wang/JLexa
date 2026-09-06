import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai/chat_repository.dart';

import '../../core/ai/ai_service.dart';
import '../../core/ai/prompt_builder.dart';
import '../../core/ai/speech_engine.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'ai_chat_controller.dart';
import 'widgets/chat_bubble.dart';
import 'widgets/sentence_summary_card.dart';

class AiChatScreen extends StatefulWidget {
  final AiService aiService;
  final SpeechRecognitionEngine speechEngine;
  final Map<String, dynamic>? initialContext;

  const AiChatScreen({
    super.key,
    required this.aiService,
    required this.speechEngine,
    this.initialContext,
  });

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen>
    with WidgetsBindingObserver {
  late final AiChatController _controller;
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SentenceContext? sentenceCtx;
    if (widget.initialContext != null) {
      final map = widget.initialContext!;
      sentenceCtx = SentenceContext(
        lessonTitle: map['lessonTitle'] as String? ?? 'Audio Lesson',
        sentenceText: map['sentenceText'] as String? ?? '',
        previousSentence: map['prevSentence'] as String?,
        nextSentence: map['nextSentence'] as String?,
        startMs: map['startMs'] as int? ?? 0,
        endMs: map['endMs'] as int? ?? 0,
        uncertainWords:
            (map['uncertainWords'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            [],
      );
    } else {
      sentenceCtx = null;
    }

    _controller = AiChatController(
      aiService: widget.aiService,
      speechEngine: widget.speechEngine,
      initialContext: sentenceCtx,
    );
    _controller.addListener(_onChatChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onChatChanged);
    _inputController.dispose();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isNotEmpty && !_controller.isGenerating && _controller.isReady) {
      _controller.sendMessage(text);
      _inputController.clear();
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _toggleVoiceRecording() async {
    final transcribedText = await _controller.startStopRecording();
    if (!mounted) return;
    if (transcribedText != null && transcribedText.isNotEmpty) {
      _inputController.text = transcribedText;
    } else if (_controller.voiceErrorMessage != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_controller.voiceErrorMessage!),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_controller.saveConversation());
    }
  }

  void _onChatChanged() {
    if (_scrollController.hasClients &&
        _scrollController.position.extentAfter < 160) {
      _scrollToBottom();
    }
  }

  Future<bool> _confirmDelete(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete conversation?'),
          content: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _showHistory() async {
    await _controller.saveConversation();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .75,
            child: FutureBuilder<List<ChatConversation>>(
              future: _controller.repository.list(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Could not load history: ${snapshot.error}'),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final chats = snapshot.data!;
                return Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Chat history',
                        style: AppTypography.titleMedium,
                      ),
                    ),
                    Expanded(
                      child: chats.isEmpty
                          ? const Center(child: Text('No saved conversations.'))
                          : ListView.builder(
                              itemCount: chats.length,
                              itemBuilder: (context, index) {
                                final chat = chats[index];
                                return ListTile(
                                  title: Text(
                                    chat.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    '${chat.updatedAt.toLocal().toString().substring(0, 16)} • ${chat.messages.length} messages',
                                  ),
                                  selected:
                                      chat.id == _controller.conversationId,
                                  onTap: () async {
                                    Navigator.pop(context);
                                    await _controller.openConversation(chat);
                                    _inputController.clear();
                                    _scrollToBottom();
                                  },
                                  trailing: IconButton(
                                    tooltip: 'Delete conversation',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () async {
                                      if (!await _confirmDelete(chat.title)) {
                                        return;
                                      }
                                      await _controller.deleteConversation(
                                        chat.id,
                                      );
                                      if (context.mounted) refresh(() {});
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('AI Q&A', style: AppTypography.titleMedium),
        actions: [
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: !_controller.isReady
                ? null
                : () async {
                    await _controller.newChat();
                    _inputController.clear();
                  },
          ),
          IconButton(
            tooltip: 'Chat history',
            icon: const Icon(Icons.history),
            onPressed: _showHistory,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_controller.storageError != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _controller.storageError!,
                  style: const TextStyle(color: AppColors.error),
                ),
              ),
            Expanded(
              child: !_controller.isReady
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      children: [
                        if (_controller.sentenceContext != null)
                          SentenceSummaryCard(
                            contextData: _controller.sentenceContext!,
                            isExpanded: _controller.isSummaryExpanded,
                            onToggleExpand: _controller.toggleSummaryExpanded,
                          ),
                        if (_controller.messages.isEmpty) ...[
                          const SizedBox(height: 16),
                          const Text(
                            'Example Questions',
                            style: AppTypography.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          _buildExampleQuestionTile(
                            _controller.sentenceContext == null
                                ? 'Explain the difference between "say" and "tell".'
                                : 'Explain this sentence in Chinese.',
                          ),
                          _buildExampleQuestionTile(
                            'Give me three useful English phrases for daily conversation.',
                          ),
                        ],
                        ..._controller.messages
                            .where((m) => m.content.isNotEmpty)
                            .map(
                              (msg) => ChatBubble(
                                message: msg,
                                onSpeak: _controller.speak,
                                onDelete: () =>
                                    _controller.deleteMessage(msg.id),
                              ),
                            ),
                        if (_controller.isGenerating)
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          ),
                        if (_controller.canRegenerate)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _controller.regenerate,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Regenerate answer'),
                            ),
                          ),
                      ],
                    ),
            ),
            if (_controller.isRecording)
              ListTile(
                tileColor: AppColors.primaryLight,
                title: const Text('Listening…'),
                leading: const Icon(Icons.mic),
                trailing: TextButton(
                  onPressed: _toggleVoiceRecording,
                  child: const Text('Stop recording'),
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Voice Input',
                    icon: Icon(
                      _controller.isRecording ? Icons.stop : Icons.mic_none,
                    ),
                    onPressed: _toggleVoiceRecording,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Message…',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton.filled(
                    tooltip: _controller.isGenerating
                        ? 'Stop generating'
                        : 'Send message',
                    onPressed: !_controller.isReady
                        ? null
                        : _controller.isGenerating
                        ? _controller.stopGeneration
                        : _send,
                    icon: Icon(
                      _controller.isGenerating ? Icons.stop : Icons.send,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildExampleQuestionTile(String question) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: InkWell(
        onTap: () {
          _controller.sendMessage(question);
          _scrollToBottom();
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  question,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 16,
                color: AppColors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
