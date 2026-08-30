import 'package:flutter/material.dart';

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

class _AiChatScreenState extends State<AiChatScreen> {
  late final AiChatController _controller;
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isNotEmpty) {
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
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            elevation: 0,
            title: const Text('AI Q&A', style: AppTypography.titleMedium),
            actions: [
              IconButton(
                icon: const Icon(Icons.history, color: AppColors.textPrimary),
                onPressed: () {},
                tooltip: 'History',
              ),
            ],
          ),
          body: Column(
            children: [
              // Context summary & example questions (Header area)
              Expanded(
                child: ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_controller.sentenceContext != null) ...[
                      SentenceSummaryCard(
                        contextData: _controller.sentenceContext!,
                        isExpanded: _controller.isSummaryExpanded,
                        onToggleExpand: _controller.toggleSummaryExpanded,
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Example Questions
                    const Text(
                      'Example Questions',
                      style: AppTypography.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    _buildExampleQuestionTile('Why is this phrase used?'),
                    _buildExampleQuestionTile(
                      'Explain this sentence in Chinese.',
                    ),
                    _buildExampleQuestionTile(
                      'What does "prioritize" mean here?',
                    ),
                    _buildExampleQuestionTile(
                      'Give me another example sentence.',
                    ),
                    _buildExampleQuestionTile('Is the transcription correct?'),
                    const SizedBox(height: 16),

                    // Chat messages list
                    const Divider(height: 24),
                    ..._controller.messages.map(
                      (msg) =>
                          ChatBubble(message: msg, onSpeak: _controller.speak),
                    ),

                    if (_controller.isGenerating)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Recording Status Banner if active
              if (_controller.isRecording)
                Container(
                  color: AppColors.primaryLight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.mic, color: AppColors.primary, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Listening...',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      TextButton(
                        onPressed: _toggleVoiceRecording,
                        child: const Text(
                          'Tap to stop',
                          style: TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // Bottom Input Bar
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  border: Border(top: BorderSide(color: AppColors.border)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(
                            _controller.isRecording
                                ? Icons.stop
                                : Icons.mic_none,
                            color: _controller.isRecording
                                ? AppColors.error
                                : AppColors.textSecondary,
                          ),
                          onPressed: _toggleVoiceRecording,
                          tooltip: 'Voice Input',
                        ),
                        Expanded(
                          child: TextField(
                            controller: _inputController,
                            onSubmitted: (_) => _send(),
                            decoration: const InputDecoration(
                              hintText: 'Ask anything about this audio...',
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                        IconButton.filled(
                          onPressed: _controller.isGenerating ? null : _send,
                          icon: const Icon(Icons.send, size: 18),
                          style: IconButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'AI responses may be imperfect. Please verify important information.',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

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
              Text(
                question,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.primary,
                  fontWeight: FontWeight.w500,
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
