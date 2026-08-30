import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../audio/audio_models.dart';
import 'ai_engine.dart';
import 'ai_models.dart';
import 'prompt_builder.dart';
import 'speech_engine.dart';

class _LlamaQueuedRequest {
  final String requestId;
  final String prompt;
  final AiGenerationSettings? settings;
  final int? seed;
  final List<ChatMessagePayload>? chatMessages;
  final AiRequestPriority priority;
  final StreamController<String> controller;
  final Completer<void> doneCompleter;
  bool isCancelled = false;
  bool hasStartedNatively = false;

  _LlamaQueuedRequest({
    required this.requestId,
    required this.prompt,
    this.settings,
    this.seed,
    this.chatMessages,
    required this.priority,
    required this.controller,
    required this.doneCompleter,
  });

  void cancelBeforeStart() {
    if (isCancelled || hasStartedNatively) return;
    isCancelled = true;
    if (!controller.isClosed) {
      controller.addError(const AiCancelledException());
      controller.close();
    }
    if (!doneCompleter.isCompleted) {
      doneCompleter.complete();
    }
  }
}

class NativeLlamaEngine implements AiEngine {
  static const MethodChannel _channel = MethodChannel('com.jlexa.app/llama');
  static const EventChannel _eventChannel = EventChannel(
    'com.jlexa.app/llama_stream',
  );
  static const _uuid = Uuid();

  bool _isLoaded = false;
  String? _loadedModelPath;
  AiModelState _state = AiModelState.noModel;

  _LlamaQueuedRequest? _activeRequest;
  _LlamaQueuedRequest? _pendingRequest;
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
          if (requestId != null && _activeRequest?.requestId == requestId) {
            final active = _activeRequest!;
            final controller = active.controller;
            final completer = active.doneCompleter;

            if (type == 'token') {
              final text = event['text'] as String? ?? '';
              if (!controller.isClosed) {
                controller.add(text);
              }
            } else if (type == 'done') {
              if (!controller.isClosed) {
                controller.close();
              }
              if (!completer.isCompleted) {
                completer.complete();
              }
              _onNativeTerminal(requestId);
            } else if (type == 'cancelled') {
              if (!controller.isClosed) {
                controller.addError(const AiCancelledException());
                controller.close();
              }
              if (!completer.isCompleted) {
                completer.complete();
              }
              _onNativeTerminal(requestId);
            } else if (type == 'error') {
              final msg = event['message'] as String? ?? 'Generation failed';
              if (!controller.isClosed) {
                controller.addError(AiGenerationException(msg));
                controller.close();
              }
              if (!completer.isCompleted) {
                completer.complete();
              }
              _onNativeTerminal(requestId);
            }
          }
        }
      },
      onError: (dynamic error) {
        if (_activeRequest != null) {
          final active = _activeRequest!;
          if (!active.controller.isClosed) {
            active.controller.addError(
              error is Exception
                  ? error
                  : AiGenerationException(error.toString()),
            );
            active.controller.close();
          }
          if (!active.doneCompleter.isCompleted) {
            active.doneCompleter.complete();
          }
          _onNativeTerminal(active.requestId);
        }
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
  Future<void> loadModel(
    String modelPath, {
    AiGenerationSettings? settings,
  }) async {
    if (!Platform.isAndroid) {
      throw const AiUnsupportedPlatformException();
    }

    _state = AiModelState.loading;
    try {
      final bool success =
          await _channel.invokeMethod('loadModel', {
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
        throw const AiGenerationException(
          'The selected AI model could not be loaded.',
        );
      }
    } catch (e) {
      _isLoaded = false;
      _loadedModelPath = null;
      _state = AiModelState.error;
      rethrow;
    }
  }

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
        done: Future.value(),
      );
    }

    if (!_isLoaded) {
      return AiGenerationHandle(
        requestId: '',
        stream: Stream.error(const AiModelNotLoadedException()),
        onCancel: () async {},
        done: Future.value(),
      );
    }

    final requestId = _uuid.v4();
    final controller = StreamController<String>();
    final doneCompleter = Completer<void>();

    final req = _LlamaQueuedRequest(
      requestId: requestId,
      prompt: prompt,
      settings: settings,
      seed: seed,
      chatMessages: chatMessages,
      priority: priority,
      controller: controller,
      doneCompleter: doneCompleter,
    );

    // If there is already a pending request, the newest request supersedes it
    if (_pendingRequest != null) {
      _pendingRequest!.cancelBeforeStart();
      _pendingRequest = null;
    }

    if (_activeRequest == null) {
      // Nothing running natively, start immediately
      _startNativeGeneration(req);
    } else {
      // A request is currently running natively.
      // Set new request as pending replacement and cancel the active request.
      _pendingRequest = req;
      cancelRequest(_activeRequest!.requestId);
    }

    return AiGenerationHandle(
      requestId: requestId,
      stream: controller.stream,
      onCancel: () => _handleCancel(req),
      done: doneCompleter.future,
    );
  }

  Future<void> _handleCancel(_LlamaQueuedRequest req) async {
    if (req == _pendingRequest) {
      req.cancelBeforeStart();
      _pendingRequest = null;
    } else if (req == _activeRequest) {
      await cancelRequest(req.requestId);
    }
  }

  Future<void> _startNativeGeneration(_LlamaQueuedRequest req) async {
    if (req.isCancelled) {
      _onNativeTerminal(req.requestId);
      return;
    }

    _activeRequest = req;
    req.hasStartedNatively = true;
    _state = AiModelState.generating;

    try {
      await _channel.invokeMethod('startGeneration', {
        'requestId': req.requestId,
        'prompt': req.prompt,
        'temperature': req.settings?.temperature ?? 0.7,
        'maxTokens': req.settings?.maxTokens ?? 512,
        'topP': req.settings?.topP ?? 0.9,
        'seed': req.seed ?? 0,
        if (req.chatMessages != null && req.chatMessages!.isNotEmpty) ...{
          'chatRoles': req.chatMessages!.map((m) => m.role).toList(),
          'chatContents': req.chatMessages!.map((m) => m.content).toList(),
        },
      });
    } catch (e) {
      if (!req.controller.isClosed) {
        req.controller.addError(
          e is Exception ? e : AiGenerationException(e.toString()),
        );
        req.controller.close();
      }
      if (!req.doneCompleter.isCompleted) {
        req.doneCompleter.complete();
      }
      _onNativeTerminal(req.requestId);
    }
  }

  void _onNativeTerminal(String requestId) {
    if (_activeRequest?.requestId == requestId) {
      _activeRequest = null;
    }

    // Check if there is a pending request waiting to start
    while (_pendingRequest != null) {
      final nextReq = _pendingRequest!;
      _pendingRequest = null;
      if (!nextReq.isCancelled) {
        _startNativeGeneration(nextReq);
        return;
      }
    }

    _state = _isLoaded ? AiModelState.ready : AiModelState.noModel;
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    if (!Platform.isAndroid) return;
    if (_pendingRequest?.requestId == requestId) {
      _pendingRequest!.cancelBeforeStart();
      _pendingRequest = null;
      return;
    }
    try {
      await _channel.invokeMethod('cancelGeneration', {'requestId': requestId});
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    if (_pendingRequest != null) {
      _pendingRequest!.cancelBeforeStart();
      _pendingRequest = null;
    }
    if (_activeRequest != null) {
      await cancelRequest(_activeRequest!.requestId);
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
    if (_pendingRequest != null) {
      _pendingRequest!.cancelBeforeStart();
      _pendingRequest = null;
    }
    if (_activeRequest != null) {
      if (!_activeRequest!.controller.isClosed) {
        _activeRequest!.controller.close();
      }
      if (!_activeRequest!.doneCompleter.isCompleted) {
        _activeRequest!.doneCompleter.complete();
      }
      _activeRequest = null;
    }
  }
}

class NativeWhisperEngine implements SpeechRecognitionEngine {
  static const MethodChannel _channel = MethodChannel('com.jlexa.app/whisper');
  static const EventChannel _eventChannel = EventChannel(
    'com.jlexa.app/whisper_stream',
  );
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
    _streamSubscription = _eventChannel.receiveBroadcastStream().listen((
      dynamic event,
    ) {
      if (event is Map) {
        final requestId = event['requestId'] as String?;
        final type = event['type'] as String?;
        if (type == 'progress' &&
            requestId != null &&
            _progressCallbacks.containsKey(requestId)) {
          final progress = (event['progress'] as num?)?.toDouble() ?? 0.0;
          _progressCallbacks[requestId]?.call(
            progress.clamp(0.0, 1.0).toDouble(),
          );
        }
      }
    }, onError: (_) {});
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

    final bool success =
        await _channel.invokeMethod('loadModel', {'modelPath': modelPath}) ??
        false;

    if (success) {
      _isLoaded = true;
      _loadedModelPath = modelPath;
    } else {
      _isLoaded = false;
      _loadedModelPath = null;
      throw const AiGenerationException(
        'The selected speech model could not be loaded.',
      );
    }
  }

  @override
  Future<List<AudioSegment>> transcribeAudio({
    required String audioPath,
    required String lessonId,
    String? requestId,
    int nThreads = 4,
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw const AiUnsupportedPlatformException();
    }

    if (!_isLoaded) {
      throw const AiModelNotLoadedException(
        'Speech model not configured. Please select a Whisper model.',
      );
    }

    final reqId = requestId ?? _uuid.v4();
    if (onProgress != null) {
      _progressCallbacks[reqId] = onProgress;
      onProgress(0.0);
    }

    try {
      final dynamic rawResult = await _channel.invokeMethod('transcribeAudio', {
        'audioPath': audioPath,
        'lessonId': lessonId,
        'requestId': reqId,
        'threads': nThreads,
      });

      if (onProgress != null) {
        onProgress(1.0);
      }

      if (rawResult is List) {
        return rawResult
            .map(
              (e) => AudioSegment.fromMap(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
      }

      return [];
    } finally {
      _progressCallbacks.remove(reqId);
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

  Future<Map<String, dynamic>?> extractAudioInfo(
    String audioPath, {
    int numPeaks = 200,
  }) async {
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
  Future<void> cancelRequest(String requestId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('cancelTranscription', {
        'requestId': requestId,
      });
    } catch (_) {}
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
