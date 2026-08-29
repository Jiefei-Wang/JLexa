import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
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
  String? _voiceErrorMessage;
  AiGenerationHandle? _activeHandle;

  SentenceContext? get sentenceContext => _context;
  List<ChatMessage> get messages => _messages;
  bool get isGenerating => _isGenerating;
  bool get isRecording => _isRecording;
  bool get isSummaryExpanded => _isSummaryExpanded;
  String? get voiceErrorMessage => _voiceErrorMessage;

  AiChatController({
    required this.aiService,
    required this.speechEngine,
    SentenceContext? initialContext,
  }) : _context = initialContext {
    _initTts();
  }

  void _initTts() {
    try {
      _tts.setLanguage('en-US');
      _tts.setSpeechRate(0.45);
    } catch (_) {}
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

    if (_isGenerating || aiService.isGenerating) return;

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

    // Pass conversation history excluding the current query
    final priorHistory = _messages
        .take(_messages.length - 2)
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();

    try {
      final handle = _context != null
          ? aiService.startSentenceQA(
              context: _context,
              userQuestion: clean,
              chatHistory: priorHistory,
            )
          : aiService.startGeneralQA(
              userQuestion: clean,
              chatHistory: priorHistory,
            );
      _activeHandle = handle;

      String accumulated = '';
      await for (final chunk in handle.stream) {
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
    } catch (e) {
      final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
      if (idx != -1) {
        _messages[idx] = ChatMessage(
          id: assistantMsgId,
          role: 'assistant',
          content: 'Error generating response: $e',
          timestamp: DateTime.now(),
        );
      }
    } finally {
      _isGenerating = false;
      _activeHandle = null;
      notifyListeners();
    }
  }

  Future<String?> startStopRecording() async {
    _voiceErrorMessage = null;
    if (_isRecording) {
      // Stop recording
      _isRecording = false;
      notifyListeners();
      try {
        final path = await _audioRecorder.stop();
        if (path != null) {
          try {
            if (!speechEngine.isLoaded) {
              _voiceErrorMessage = 'Speech model not loaded. Please select a Whisper model in Settings.';
              notifyListeners();
              return null;
            }
            final segments = await speechEngine.transcribeAudio(
              audioPath: path,
              lessonId: 'voice_input',
            );
            if (segments.isNotEmpty) {
              return segments.map((s) => s.text.trim()).join(' ');
            }
          } catch (e) {
            _voiceErrorMessage = 'Voice transcription error: $e';
            notifyListeners();
          } finally {
            // Delete temp recording file
            try {
              final tempFile = File(path);
              if (await tempFile.exists()) {
                await tempFile.delete();
              }
            } catch (_) {}
          }
        }
      } catch (e) {
        _voiceErrorMessage = 'Error stopping recording: $e';
        notifyListeners();
      }
    } else {
      // Start recording
      try {
        final hasPerm = await _audioRecorder.hasPermission();
        if (!hasPerm) {
          _voiceErrorMessage = 'Microphone permission denied.';
          notifyListeners();
          return null;
        }

        final tempDir = await getTemporaryDirectory();
        final filePath = '${tempDir.path}/voice_input_${DateTime.now().millisecondsSinceEpoch}.wav';
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
          path: filePath,
        );
        _isRecording = true;
        notifyListeners();
      } catch (e) {
        _isRecording = false;
        _voiceErrorMessage = 'Error starting recording: $e';
        notifyListeners();
      }
    }
    return null;
  }

  @override
  void dispose() {
    _activeHandle?.cancel();
    _tts.stop();
    if (_isRecording) {
      _audioRecorder.stop();
    }
    _audioRecorder.dispose();
    super.dispose();
  }
}
