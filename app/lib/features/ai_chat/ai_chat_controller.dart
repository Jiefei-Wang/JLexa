import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_service.dart';
import '../../core/ai/chat_repository.dart';
import '../../core/ai/prompt_builder.dart';
import '../../core/ai/speech_engine.dart';

class AiChatController extends ChangeNotifier {
  final AiService aiService;
  final SpeechRecognitionEngine speechEngine;
  final FlutterTts _tts = FlutterTts();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final _uuid = const Uuid();

  SentenceContext? _context;
  final ChatRepository repository;
  late final Future<void> ready;
  bool _isReady = false;
  bool _isSwitching = false;
  bool get isReady => _isReady && !_isSwitching;
  int _generation = 0;
  String _conversationId = const Uuid().v4();
  String get conversationId => _conversationId;
  String? _storageError;
  String? _lastQueuedSnapshot;
  String get _snapshotKey =>
      jsonEncode([_conversationId, _messages.map((m) => m.toMap()).toList()]);
  String? get storageError => _storageError;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  bool get canRegenerate => !_isGenerating && _messages.any((m) => m.isUser);
  final List<ChatMessage> _messages = [];
  bool _isGenerating = false;
  bool _isRecording = false;
  bool _isSummaryExpanded = true;
  String? _voiceErrorMessage;
  AiGenerationHandle? _activeHandle;
  String? _activeVoiceRequestId;
  bool _isDisposed = false;

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
    ChatRepository? repository,
  }) : _context = initialContext,
       repository = repository ?? ChatRepository() {
    _initTts();
    ready = _restore(initialContext == null);
  }

  Future<void> _restore(bool restoreLatest) async {
    try {
      if (restoreLatest) {
        final conversations = await repository.list();
        if (!_isDisposed && conversations.isNotEmpty) _use(conversations.first);
      }
    } catch (e) {
      _storageError = 'Could not load chat history: $e';
    }
    if (!_isDisposed) {
      _isReady = true;
      notifyListeners();
    }
  }

  void _use(ChatConversation c) {
    _conversationId = c.id;
    _context = c.context;
    _messages
      ..clear()
      ..addAll(c.messages);
    _lastQueuedSnapshot = _snapshotKey;
  }

  Future<void> saveConversation() async {
    if (_messages.isEmpty) return;
    final key = _snapshotKey;
    if (key == _lastQueuedSnapshot) return;
    _lastQueuedSnapshot = key;
    final title = _messages
        .firstWhere((m) => m.isUser, orElse: () => _messages.first)
        .content;
    final snapshot = ChatConversation(
      id: _conversationId,
      title: title.length > 70 ? '${title.substring(0, 70)}…' : title,
      updatedAt: DateTime.now(),
      context: _context,
      messages: [..._messages],
    );
    try {
      await repository.save(snapshot);
      _storageError = null;
    } catch (e) {
      if (_lastQueuedSnapshot == key) _lastQueuedSnapshot = null;
      _storageError = 'Could not save chat: $e';
      if (!_isDisposed) notifyListeners();
    }
  }

  Future<void> stopGeneration() async {
    ++_generation;
    final handle = _activeHandle;
    _activeHandle = null;
    _isGenerating = false;
    _messages.removeWhere((m) => !m.isUser && m.content.trim().isEmpty);
    if (!_isDisposed) notifyListeners();
    if (handle != null) await handle.cancel();
    await saveConversation();
  }

  Future<void> newChat() async {
    await ready;
    if (_isSwitching) return;
    _isSwitching = true;
    try {
      await stopGeneration();
      if (_isDisposed) return;
      _conversationId = _uuid.v4();
      _context = null;
      _messages.clear();
    } finally {
      _isSwitching = false;
      if (!_isDisposed) notifyListeners();
    }
  }

  Future<void> openConversation(ChatConversation conversation) async {
    await ready;
    if (_isSwitching) return;
    _isSwitching = true;
    try {
      await stopGeneration();
      if (_isDisposed) return;
      // A history sheet can contain a snapshot taken before streaming finished.
      final latest = await repository.get(conversation.id);
      if (_isDisposed) return;
      if (latest != null) _use(latest);
    } finally {
      _isSwitching = false;
      if (!_isDisposed) notifyListeners();
    }
  }

  Future<void> deleteConversation(String id) async {
    if (id == _conversationId) {
      await newChat();
    }
    await repository.delete(id);
  }

  Future<void> deleteMessage(String id) async {
    await stopGeneration();
    final index = _messages.indexWhere((m) => m.id == id);
    if (index < 0) return;
    final user = _messages[index].isUser;
    _messages.removeAt(index);
    if (user && index < _messages.length && !_messages[index].isUser) {
      _messages.removeAt(index);
    }
    if (_messages.isEmpty) {
      await repository.delete(_conversationId);
    } else {
      await saveConversation();
    }
    if (!_isDisposed) notifyListeners();
  }

  Future<void> regenerate() async {
    await ready;
    if (_isGenerating || _isDisposed || _isSwitching) return;
    final index = _messages.lastIndexWhere((m) => m.isUser);
    if (index < 0) return;
    final question = _messages[index].content;
    _messages.removeRange(index + 1, _messages.length);
    await _generate(question);
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
    await ready;
    final clean = text.trim();
    if (clean.isEmpty || _isDisposed || _isGenerating || _isSwitching) return;
    _messages.add(
      ChatMessage(
        id: _uuid.v4(),
        role: 'user',
        content: clean,
        timestamp: DateTime.now(),
      ),
    );
    await _generate(clean);
  }

  Future<void> _generate(String question) async {
    final generation = ++_generation;
    _isGenerating = true;
    final priorHistory = _messages
        .take(_messages.length - 1)
        .where((m) => m.content.isNotEmpty)
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();
    final assistantId = _uuid.v4();
    _messages.add(
      ChatMessage(
        id: assistantId,
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
      ),
    );
    notifyListeners();
    unawaited(saveConversation());
    if (_isDisposed || generation != _generation) return;
    try {
      if (!aiService.llmEngine.isLoaded) {
        throw const AiModelNotLoadedException();
      }
      final handle = _context != null
          ? aiService.startSentenceQA(
              context: _context!,
              userQuestion: question,
              chatHistory: priorHistory,
            )
          : aiService.startGeneralQA(
              userQuestion: question,
              chatHistory: priorHistory,
            );
      _activeHandle = handle;
      var accumulated = '';
      await for (final chunk in handle.stream) {
        if (_isDisposed || generation != _generation) break;
        accumulated += chunk;
        final index = _messages.indexWhere((m) => m.id == assistantId);
        if (index < 0) break;
        _messages[index] = ChatMessage(
          id: assistantId,
          role: 'assistant',
          content: accumulated,
          timestamp: DateTime.now(),
        );
        notifyListeners();
        if (DateTime.now().difference(_lastSave).inMilliseconds > 1000) {
          _lastSave = DateTime.now();
          unawaited(saveConversation());
        }
      }
    } on AiCancelledException {
      // Keep the partial answer so Stop never destroys already received text.
    } catch (e) {
      if (_isDisposed || generation != _generation) return;
      final index = _messages.indexWhere((m) => m.id == assistantId);
      if (index >= 0) {
        _messages[index] = ChatMessage(
          id: assistantId,
          role: 'assistant',
          content: e is AiModelNotLoadedException
              ? 'Load a local AI model in Settings to ask questions and receive AI responses.'
              : 'Could not generate an answer: $e',
          timestamp: DateTime.now(),
        );
      }
    } finally {
      if (!_isDisposed && generation == _generation) {
        _isGenerating = false;
        _activeHandle = null;
        await saveConversation();
        notifyListeners();
      }
    }
  }

  Future<String?> startStopRecording() async {
    if (_isDisposed) return null;
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
            final reqId = _uuid.v4();
            _activeVoiceRequestId = reqId;
            final segments = await speechEngine.transcribeAudio(
              audioPath: path,
              lessonId: 'voice_input',
              requestId: reqId,
            );
            if (_isDisposed) return null;
            if (segments.isNotEmpty) {
              return segments.map((s) => s.text.trim()).join(' ');
            }
          } catch (e) {
            if (!_isDisposed) {
              _voiceErrorMessage = 'Voice transcription error: $e';
              notifyListeners();
            }
          } finally {
            _activeVoiceRequestId = null;
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
        if (!_isDisposed) {
          _voiceErrorMessage = 'Error stopping recording: $e';
          notifyListeners();
        }
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
        final filePath =
            '${tempDir.path}/voice_input_${DateTime.now().millisecondsSinceEpoch}.wav';
        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
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
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(saveConversation());
    ++_generation;
    _isDisposed = true;
    _activeHandle?.cancel();
    _activeHandle = null;
    if (_activeVoiceRequestId != null) {
      speechEngine.cancelRequest(_activeVoiceRequestId!);
      _activeVoiceRequestId = null;
    }
    _tts.stop();
    if (_isRecording) {
      _audioRecorder.stop();
    }
    _audioRecorder.dispose();
    super.dispose();
  }
}
