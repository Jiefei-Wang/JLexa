import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';
import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_service.dart';
import '../../core/ai/prompt_builder.dart';
import '../../core/ai/speech_engine.dart';

class AiChatController extends ChangeNotifier {
  final AiService aiService;
  final SpeechRecognitionEngine speechEngine;
  final FlutterTts _tts = FlutterTts();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final _uuid = const Uuid();

  final SentenceContext? _context;
  final List<ChatMessage> _messages = [];
  bool _isGenerating = false;
  bool _isRecording = false;
  bool _isSummaryExpanded = true;

  SentenceContext? get sentenceContext => _context;
  List<ChatMessage> get messages => _messages;
  bool get isGenerating => _isGenerating;
  bool get isRecording => _isRecording;
  bool get isSummaryExpanded => _isSummaryExpanded;

  AiChatController({
    required this.aiService,
    required this.speechEngine,
    SentenceContext? initialContext,
  }) : _context = initialContext {
    _initTts();
    _initSampleConversation();
  }

  void _initTts() {
    try {
      _tts.setLanguage('en-US');
      _tts.setSpeechRate(0.45);
    } catch (_) {}
  }

  void _initSampleConversation() {
    if (_context != null) {
      _messages.add(
        ChatMessage(
          id: _uuid.v4(),
          role: 'user',
          content: 'Why is this phrase used?',
          timestamp: DateTime.now().subtract(const Duration(minutes: 2)),
          audioTimestampLabel: '02:41',
        ),
      );
      _messages.add(
        ChatMessage(
          id: _uuid.v4(),
          role: 'assistant',
          content:
              'It\'s used to highlight the importance of intentionally focusing on what matters most. '
              '"Prioritize" means to decide the order of importance, while "schedule" refers to allocating time on your calendar.',
          timestamp: DateTime.now().subtract(const Duration(minutes: 2)),
          audioTimestampLabel: '02:41',
        ),
      );
    }
  }

  void toggleSummaryExpanded() {
    _isSummaryExpanded = !_isSummaryExpanded;
    notifyListeners();
  }

  Future<void> speak(String text) async {
    try {
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> sendMessage(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;

    final userMessage = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: clean,
      timestamp: DateTime.now(),
    );
    _messages.add(userMessage);
    notifyListeners();

    if (!aiService.llmEngine.isLoaded) {
      _messages.add(
        ChatMessage(
          id: _uuid.v4(),
          role: 'assistant',
          content: 'Load a local AI model in Settings to ask questions and receive AI responses.',
          timestamp: DateTime.now(),
        ),
      );
      notifyListeners();
      return;
    }

    _isGenerating = true;
    final assistantMsgId = _uuid.v4();
    final assistantMsg = ChatMessage(
      id: assistantMsgId,
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
    );
    _messages.add(assistantMsg);
    notifyListeners();

    final ctx = _context ??
        const SentenceContext(
          lessonTitle: 'General Q&A',
          sentenceText: '',
        );

    final historyList = _messages
        .take(_messages.length - 1)
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();

    String accumulated = '';
    await for (final chunk in aiService.askSentenceQA(
      context: ctx,
      userQuestion: clean,
      chatHistory: historyList,
    )) {
      accumulated += chunk;
      final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
      if (idx != -1) {
        _messages[idx] = ChatMessage(
          id: assistantMsgId,
          role: 'assistant',
          content: accumulated,
          timestamp: DateTime.now(),
        );
        notifyListeners();
      }
    }

    _isGenerating = false;
    notifyListeners();
  }

  Future<String?> startStopRecording() async {
    if (_isRecording) {
      // Stop recording
      _isRecording = false;
      notifyListeners();
      try {
        final path = await _audioRecorder.stop();
        if (path != null && speechEngine.isLoaded) {
          final segments = await speechEngine.transcribeAudio(
            audioPath: path,
            lessonId: 'voice_input',
          );
          if (segments.isNotEmpty) {
            return segments.map((s) => s.text).join(' ');
          }
        }
      } catch (_) {}
    } else {
      // Start recording
      if (await _audioRecorder.hasPermission()) {
        _isRecording = true;
        notifyListeners();
        // Record to temp audio
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
          path: '',
        );
      }
    }
    return null;
  }

  @override
  void dispose() {
    _tts.stop();
    _audioRecorder.dispose();
    super.dispose();
  }
}
