import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../audio/audio_models.dart';
import 'ai_engine.dart';
import 'ai_models.dart';
import 'prompt_builder.dart';
import 'speech_engine.dart';

class NativeLlamaEngine implements AiEngine {
  static const MethodChannel _channel = MethodChannel('com.jlexa.app/llama');
  static const EventChannel _eventChannel = EventChannel('com.jlexa.app/llama_stream');
  static const _uuid = Uuid();

  bool _isLoaded = false;
  String? _loadedModelPath;
  AiModelState _state = AiModelState.noModel;

  final Map<String, StreamController<String>> _activeRequests = {};
  String? _currentRequestId;
  bool _isCurrentlyGenerating = false;
  StreamSubscription? _streamSubscription;

  NativeLlamaEngine() {
    _initStream();
  }

  void _initStream() {
    if (!Platform.isAndroid) return;
    _streamSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          final requestId = event['requestId'] as String?;
          final type = event['type'] as String?;
          if (requestId != null && _activeRequests.containsKey(requestId)) {
            final controller = _activeRequests[requestId]!;
            if (type == 'token') {
              final text = event['text'] as String? ?? '';
              if (!controller.isClosed) {
                controller.add(text);
              }
            } else if (type == 'done') {
              if (!controller.isClosed) {
                controller.close();
              }
              _activeRequests.remove(requestId);
              if (_currentRequestId == requestId) {
                _isCurrentlyGenerating = false;
                _currentRequestId = null;
                _state = _isLoaded ? AiModelState.ready : AiModelState.noModel;
              }
            } else if (type == 'cancelled') {
              if (!controller.isClosed) {
                controller.addError(const AiCancelledException());
                controller.close();
              }
              _activeRequests.remove(requestId);
              if (_currentRequestId == requestId) {
                _isCurrentlyGenerating = false;
                _currentRequestId = null;
                _state = _isLoaded ? AiModelState.ready : AiModelState.noModel;
              }
            } else if (type == 'error') {
              final msg = event['message'] as String? ?? 'Generation failed';
              if (!controller.isClosed) {
                controller.addError(AiGenerationException(msg));
                controller.close();
              }
              _activeRequests.remove(requestId);
              if (_currentRequestId == requestId) {
                _isCurrentlyGenerating = false;
                _currentRequestId = null;
                _state = _isLoaded ? AiModelState.ready : AiModelState.noModel;
              }
            }
          }
        }
      },
      onError: (dynamic error) {
        for (final controller in _activeRequests.values) {
          if (!controller.isClosed) {
            controller.addError(
              error is Exception ? error : AiGenerationException(error.toString()),
            );
            controller.close();
          }
        }
        _activeRequests.clear();
        _isCurrentlyGenerating = false;
        _currentRequestId = null;
        _state = _isLoaded ? AiModelState.ready : AiModelState.noModel;
      },
    );
  }

  @override
  bool get isLoaded => _isLoaded;

  @override
  String? get loadedModelPath => _loadedModelPath;

  @override
  AiModelState get state => _state;

  @override
  Future<void> loadModel(String modelPath, {AiGenerationSettings? settings}) async {
    if (!Platform.isAndroid) {
      throw const AiUnsupportedPlatformException();
    }

    _state = AiModelState.loading;
    try {
      final bool success = await _channel.invokeMethod('loadModel', {
            'modelPath': modelPath,
            'contextLength': settings?.contextLength ?? 2048,
            'threads': settings?.threads ?? 4,
          }) ??
          false;

      if (success) {
        _isLoaded = true;
        _loadedModelPath = modelPath;
        _state = AiModelState.ready;
      } else {
        _isLoaded = false;
        _loadedModelPath = null;
        _state = AiModelState.error;
        throw const AiGenerationException('The selected AI model could not be loaded.');
      }
    } catch (e) {
      _isLoaded = false;
      _loadedModelPath = null;
      _state = AiModelState.error;
      rethrow;
    }
  }

  AiRequestPriority _currentPriority = AiRequestPriority.user;

  @override
  Stream<String> generate(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
  }) {
    return startGeneration(
      prompt,
      settings: settings,
      seed: seed,
      chatMessages: chatMessages,
      priority: AiRequestPriority.user,
    ).stream;
  }

  @override
  AiGenerationHandle startGeneration(
    String prompt, {
    AiGenerationSettings? settings,
    int? seed,
    List<ChatMessagePayload>? chatMessages,
    AiRequestPriority priority = AiRequestPriority.user,
  }) {
    if (!Platform.isAndroid) {
      return AiGenerationHandle(
        requestId: '',
        stream: Stream.error(const AiUnsupportedPlatformException()),
        onCancel: () async {},
      );
    }

    if (!_isLoaded) {
      return AiGenerationHandle(
        requestId: '',
        stream: Stream.error(const AiModelNotLoadedException()),
        onCancel: () async {},
      );
    }

    // Pre-empt background task if a user task arrives
    if (_isCurrentlyGenerating) {
      if (_currentPriority == AiRequestPriority.background && priority == AiRequestPriority.user) {
        if (_currentRequestId != null) {
          cancelRequest(_currentRequestId!);
        }
      } else {
        return AiGenerationHandle(
          requestId: '',
          stream: Stream.error(const AiBusyException()),
          onCancel: () async {},
        );
      }
    }

    final requestId = _uuid.v4();
    final controller = StreamController<String>();
    _activeRequests[requestId] = controller;
    _currentRequestId = requestId;
    _currentPriority = priority;
    _isCurrentlyGenerating = true;
    _state = AiModelState.generating;

    () async {
      try {
        await _channel.invokeMethod('startGeneration', {
          'requestId': requestId,
          'prompt': prompt,
          'temperature': settings?.temperature ?? 0.7,
          'maxTokens': settings?.maxTokens ?? 512,
          'topP': settings?.topP ?? 0.9,
          'seed': seed ?? 0,
          if (chatMessages != null && chatMessages.isNotEmpty) ...{
            'chatRoles': chatMessages.map((m) => m.role).toList(),
            'chatContents': chatMessages.map((m) => m.content).toList(),
          },
        });
      } catch (e) {
        if (!controller.isClosed) {
          controller.addError(e is Exception ? e : AiGenerationException(e.toString()));
          controller.close();
        }
        _activeRequests.remove(requestId);
        if (_currentRequestId == requestId) {
          _currentRequestId = null;
          _isCurrentlyGenerating = false;
          _state = _isLoaded ? AiModelState.ready : AiModelState.noModel;
        }
      }
    }();

    return AiGenerationHandle(
      requestId: requestId,
      stream: controller.stream,
      onCancel: () => cancelRequest(requestId),
    );
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    if (!Platform.isAndroid) return;
    if (_currentRequestId == requestId) {
      try {
        await _channel.invokeMethod('cancelGeneration', {'requestId': requestId});
      } catch (_) {}
    }
  }

  @override
  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    if (_currentRequestId != null) {
      await cancelRequest(_currentRequestId!);
    }
  }

  @override
  Future<void> unload() async {
    if (!Platform.isAndroid) return;
    try {
      await cancel();
      await _channel.invokeMethod('unloadModel');
      _isLoaded = false;
      _loadedModelPath = null;
      _state = AiModelState.noModel;
    } catch (_) {}
  }

  void dispose() {
    _streamSubscription?.cancel();
    for (final ctrl in _activeRequests.values) {
      if (!ctrl.isClosed) ctrl.close();
    }
    _activeRequests.clear();
  }
}

class NativeWhisperEngine implements SpeechRecognitionEngine {
  static const MethodChannel _channel = MethodChannel('com.jlexa.app/whisper');
  static const EventChannel _eventChannel = EventChannel('com.jlexa.app/whisper_stream');
  static const _uuid = Uuid();

  bool _isLoaded = false;
  String? _loadedModelPath;

  final Map<String, void Function(double)> _progressCallbacks = {};
  StreamSubscription? _streamSubscription;

  NativeWhisperEngine() {
    _initStream();
  }

  void _initStream() {
    if (!Platform.isAndroid) return;
    _streamSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          final requestId = event['requestId'] as String?;
          final type = event['type'] as String?;
          if (type == 'progress' && requestId != null && _progressCallbacks.containsKey(requestId)) {
            final progress = (event['progress'] as num?)?.toDouble() ?? 0.0;
            _progressCallbacks[requestId]?.call(progress.clamp(0.0, 1.0));
          }
        }
      },
      onError: (_) {},
    );
  }

  @override
  bool get isLoaded => _isLoaded;

  @override
  String? get loadedModelPath => _loadedModelPath;

  @override
  Future<void> loadModel(String modelPath) async {
    if (!Platform.isAndroid) {
      throw const AiUnsupportedPlatformException();
    }

    final bool success = await _channel.invokeMethod('loadModel', {
          'modelPath': modelPath,
        }) ??
        false;

    if (success) {
      _isLoaded = true;
      _loadedModelPath = modelPath;
    } else {
      _isLoaded = false;
      _loadedModelPath = null;
      throw const AiGenerationException('The selected speech model could not be loaded.');
    }
  }

  @override
  Future<List<AudioSegment>> transcribeAudio({
    required String audioPath,
    required String lessonId,
    int nThreads = 4,
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw const AiUnsupportedPlatformException();
    }

    if (!_isLoaded) {
      throw const AiModelNotLoadedException('Speech model not configured. Please select a Whisper model.');
    }

    final requestId = _uuid.v4();
    if (onProgress != null) {
      _progressCallbacks[requestId] = onProgress;
      onProgress(0.0);
    }

    try {
      final dynamic rawResult = await _channel.invokeMethod('transcribeAudio', {
        'audioPath': audioPath,
        'lessonId': lessonId,
        'requestId': requestId,
        'threads': nThreads,
      });

      if (onProgress != null) {
        onProgress(1.0);
      }

      if (rawResult is List) {
        return rawResult.map((e) => AudioSegment.fromMap(Map<String, dynamic>.from(e as Map))).toList();
      }

      return [];
    } finally {
      _progressCallbacks.remove(requestId);
    }
  }

  @override
  Future<Map<String, dynamic>?> getAudioMetadata(String audioPath) async {
    if (!Platform.isAndroid) return null;
    try {
      final dynamic raw = await _channel.invokeMethod('getAudioMetadata', {
        'audioPath': audioPath,
      });
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> extractAudioInfo(String audioPath, {int numPeaks = 200}) async {
    if (!Platform.isAndroid) return null;
    try {
      final dynamic raw = await _channel.invokeMethod('extractAudioInfo', {
        'audioPath': audioPath,
        'numPeaks': numPeaks,
      });
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('cancelTranscription');
    } catch (_) {}
  }

  @override
  Future<void> unload() async {
    if (!Platform.isAndroid) return;
    try {
      await cancel();
      await _channel.invokeMethod('unloadModel');
      _isLoaded = false;
      _loadedModelPath = null;
    } catch (_) {}
  }

  void dispose() {
    _streamSubscription?.cancel();
    _progressCallbacks.clear();
  }
}
