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
import 'chat_text.dart';

enum ChatVoiceState { idle, starting, recording, transcribing, cancelling }

class AiChatController extends ChangeNotifier {
  final AiService aiService;
  final SpeechRecognitionEngine speechEngine;
  final FlutterTts _tts;
  final AudioRecorder _audioRecorder;
  final Future<String> Function()? recordingPathBuilder;
  late final Future<void> _ttsReady;
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
  ChatVoiceState _voiceState = ChatVoiceState.idle;
  ChatVoiceState get voiceState => _voiceState;
  bool get isVoiceBusy => _voiceState != ChatVoiceState.idle;
  double? _voiceProgress;
  double? get voiceProgress => _voiceProgress;
  bool _isActive = true;
  bool _awaitingMicrophonePermission = false;
  Completer<void>? _voiceResume;
  int _voiceGeneration = 0;
  Future<String?>? _voiceTask;
  Future<void>? _voiceCancellation;
  String? _recordingPath;
  int _speechGeneration = 0;
  String? _speakingMessageId;
  String? get speakingMessageId => _speakingMessageId;
  String? _speechErrorMessage;
  String? get speechErrorMessage => _speechErrorMessage;
  bool _isSummaryExpanded = true;
  String? _voiceErrorMessage;
  AiGenerationHandle? _activeHandle;
  String? _activeVoiceRequestId;
  bool _isDisposed = false;

  SentenceContext? get sentenceContext => _context;
  List<ChatMessage> get messages => _messages;
  bool get isGenerating => _isGenerating;
  bool get isRecording => _voiceState == ChatVoiceState.recording;
  bool get isSummaryExpanded => _isSummaryExpanded;
  String? get voiceErrorMessage => _voiceErrorMessage;

  AiChatController({
    required this.aiService,
    required this.speechEngine,
    SentenceContext? initialContext,
    ChatRepository? repository,
    AudioRecorder? audioRecorder,
    FlutterTts? tts,
    this.recordingPathBuilder,
  }) : _context = initialContext,
       _audioRecorder = audioRecorder ?? AudioRecorder(),
       _tts = tts ?? FlutterTts(),
       repository = repository ?? ChatRepository() {
    _ttsReady = _initTts();
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
      await cancelVoiceInput();
      await stopSpeaking();
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
      await cancelVoiceInput();
      await stopSpeaking();
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
    await stopSpeaking();
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
    await stopSpeaking();
    if (_isGenerating || _isDisposed || _isSwitching) return;
    final index = _messages.lastIndexWhere((m) => m.isUser);
    if (index < 0) return;
    final question = _messages[index].content;
    _messages.removeRange(index + 1, _messages.length);
    await _generate(question);
  }

  Future<void> _initTts() async {
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.45);
    } catch (_) {}
  }

  void toggleSummaryExpanded() {
    _isSummaryExpanded = !_isSummaryExpanded;
    notifyListeners();
  }

  Future<void> speak(String text, {String? messageId}) async {
    if (!_isActive || _isDisposed || isVoiceBusy) return;
    final id = messageId ?? text;
    if (_speakingMessageId == id) {
      await stopSpeaking();
      return;
    }
    final generation = ++_speechGeneration;
    _speakingMessageId = id;
    _speechErrorMessage = null;
    notifyListeners();
    try {
      await _ttsReady;
      await _tts.stop();
      if (generation != _speechGeneration || !_isActive || _isDisposed) return;
      final plainText = chatPlainText(text);
      final language = RegExp(r'[\u3400-\u9fff]').hasMatch(plainText)
          ? 'zh-CN'
          : 'en-US';
      final available = await _tts.isLanguageAvailable(language);
      if (generation != _speechGeneration || _isDisposed) return;
      if (available == false || available == 0) {
        _speechErrorMessage = language == 'zh-CN'
            ? 'Install a Chinese text-to-speech voice in Android Settings to read this answer aloud.'
            : 'Install an English text-to-speech voice in Android Settings to read this answer aloud.';
        return;
      }
      await _tts.setLanguage(language);
      if (generation != _speechGeneration || !_isActive || _isDisposed) return;
      await _tts.speak(plainText);
    } catch (e) {
      if (generation == _speechGeneration && !_isDisposed) {
        _speechErrorMessage = 'Could not read this answer aloud: $e';
      }
    } finally {
      if (generation == _speechGeneration && !_isDisposed) {
        _speakingMessageId = null;
        notifyListeners();
      }
    }
  }

  Future<void> stopSpeaking() async {
    ++_speechGeneration;
    _speakingMessageId = null;
    notifyListeners();
    try {
      await _tts.stop();
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

  void setActive(bool active, {bool preserveVoiceStart = false}) {
    final preservePermission =
        !active &&
        preserveVoiceStart &&
        _voiceState == ChatVoiceState.starting &&
        _awaitingMicrophonePermission;
    if (_isActive == active && (_voiceResume == null || preservePermission)) {
      return;
    }
    _isActive = active;
    if (active) {
      final resume = _voiceResume;
      _voiceResume = null;
      resume?.complete();
    } else {
      if (preservePermission) {
        // Android's permission dialog temporarily makes the app inactive.
        // Retain the user's request, but do not open the microphone until
        // focus returns. A real route/tab departure or background still cancels.
        _voiceResume ??= Completer<void>();
      } else {
        unawaited(cancelVoiceInput());
      }
      unawaited(stopSpeaking());
    }
  }

  bool _ownsVoice(int generation) =>
      !_isDisposed && _isActive && generation == _voiceGeneration;

  Future<String?> startStopRecording() {
    if (_isDisposed || !_isActive || !isReady) return Future.value();
    _voiceErrorMessage = null;
    if (isRecording) {
      _voiceState = ChatVoiceState.transcribing;
      _voiceProgress = null;
      notifyListeners();
      return _voiceTask = _finishRecording(_voiceGeneration);
    }
    if (isVoiceBusy) return Future.value();
    if (!speechEngine.isLoaded) {
      _voiceErrorMessage =
          'Load a Whisper speech model in Settings before using voice input.';
      notifyListeners();
      return Future.value();
    }
    // Claim the operation before requesting permission; repeated taps cannot
    // start another recorder while an Android permission dialog is open.
    final generation = ++_voiceGeneration;
    _voiceState = ChatVoiceState.starting;
    notifyListeners();
    return _voiceTask = _startRecording(generation);
  }

  Future<String?> _startRecording(int generation) async {
    try {
      await stopSpeaking();
      if (!_ownsVoice(generation)) return null;
      _awaitingMicrophonePermission = true;
      final hasPermission = await _audioRecorder.hasPermission();
      final resume = _voiceResume;
      if (resume != null) await resume.future;
      _awaitingMicrophonePermission = false;
      if (!_ownsVoice(generation)) return null;
      if (!hasPermission) {
        _voiceErrorMessage = 'Microphone permission denied.';
        return null;
      }
      final path = recordingPathBuilder != null
          ? await recordingPathBuilder!()
          : '${(await getTemporaryDirectory()).path}/voice_input_${_uuid.v4()}.wav';
      if (!_ownsVoice(generation)) return null;
      _recordingPath = path;
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      if (!_ownsVoice(generation)) {
        await _audioRecorder.cancel();
        return null;
      }
      _voiceState = ChatVoiceState.recording;
    } catch (e) {
      if (_ownsVoice(generation)) {
        _voiceErrorMessage = 'Could not start recording: $e';
      }
      try {
        await _audioRecorder.cancel();
      } catch (_) {}
    } finally {
      _awaitingMicrophonePermission = false;
      if (_voiceState != ChatVoiceState.recording) {
        await _deleteRecording(_recordingPath);
        _recordingPath = null;
        if (generation == _voiceGeneration) _voiceState = ChatVoiceState.idle;
      }
      notifyListeners();
    }
    return null;
  }

  Future<String?> _finishRecording(int generation) async {
    String? path = _recordingPath;
    String? requestId;
    String? transcript;
    var recorderStopped = false;
    try {
      path = await _audioRecorder.stop() ?? path;
      recorderStopped = true;
      if (!_ownsVoice(generation)) return null;
      if (path == null) throw StateError('The recording was not saved.');
      requestId = _uuid.v4();
      _activeVoiceRequestId = requestId;
      final segments = await speechEngine.transcribeAudio(
        audioPath: path,
        lessonId: 'voice_input',
        requestId: requestId,
        onProgress: (progress) {
          if (!_ownsVoice(generation)) return;
          _voiceProgress = progress.clamp(0, 1).toDouble();
          notifyListeners();
        },
      );
      if (!_ownsVoice(generation)) return null;
      final text = segments.map((s) => s.text.trim()).join(' ').trim();
      if (text.isEmpty) {
        _voiceErrorMessage = 'No speech recognized. Try recording again.';
        return null;
      }
      transcript = text;
    } catch (e) {
      if (!recorderStopped) {
        try {
          await _audioRecorder.cancel();
        } catch (_) {}
      }
      if (_ownsVoice(generation)) {
        _voiceErrorMessage = 'Could not transcribe the recording: $e';
      }
    } finally {
      if (_activeVoiceRequestId == requestId) _activeVoiceRequestId = null;
      await _deleteRecording(path);
      _recordingPath = null;
      if (generation == _voiceGeneration) {
        _voiceState = ChatVoiceState.idle;
        _voiceProgress = null;
      }
      notifyListeners();
    }
    // Deleting the temporary audio is asynchronous too; cancellation during
    // cleanup must still prevent delivery of this result.
    return _ownsVoice(generation) ? transcript : null;
  }

  Future<void> cancelVoiceInput() {
    if (_voiceCancellation != null) return _voiceCancellation!;
    if (!isVoiceBusy) return Future.value();
    return _voiceCancellation = _cancelVoiceInput().whenComplete(() {
      _voiceCancellation = null;
    });
  }

  Future<void> _cancelVoiceInput() async {
    final previousState = _voiceState;
    ++_voiceGeneration;
    final resume = _voiceResume;
    _voiceResume = null;
    resume?.complete();
    _voiceState = ChatVoiceState.cancelling;
    notifyListeners();
    try {
      if (previousState == ChatVoiceState.recording) {
        await _audioRecorder.cancel();
      }
      final requestId = _activeVoiceRequestId;
      if (requestId != null) await speechEngine.cancelRequest(requestId);
    } catch (_) {
      // Still wait for this operation's terminal result; a late result is
      // invalid and cannot populate a different conversation or draft.
    } finally {
      await _voiceTask;
      await _deleteRecording(_recordingPath);
      _recordingPath = null;
      _voiceState = ChatVoiceState.idle;
      _voiceProgress = null;
      notifyListeners();
    }
  }

  Future<void> _deleteRecording(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
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
    unawaited(stopSpeaking());
    unawaited(cancelVoiceInput().whenComplete(_audioRecorder.dispose));
    super.dispose();
  }
}
