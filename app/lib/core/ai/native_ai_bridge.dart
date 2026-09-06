import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../audio/audio_models.dart';
import 'ai_engine.dart';
import 'ai_models.dart';
import 'llama_request_coordinator.dart';
import 'prompt_builder.dart';
import 'speech_engine.dart';

class NativeLlamaEngine implements AiEngine {
  static const MethodChannel _channel = MethodChannel('com.jlexa.app/llama');
  static const EventChannel _eventChannel = EventChannel(
    'com.jlexa.app/llama_stream',
  );
  static const _uuid = Uuid();

  bool _isLoaded = false;
  String? _loadedModelPath;
  AiModelState _state = AiModelState.noModel;

  late final LlamaRequestCoordinator _coordinator;
  StreamSubscription? _streamSubscription;

  NativeLlamaEngine() {
    _coordinator = LlamaRequestCoordinator(
      onNativeStart: _startNativeGeneration,
      onNativeCancel: _cancelNativeGeneration,
    );
    _initStream();
  }

  void _initStream() {
    if (!Platform.isAndroid) return;
    _streamSubscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          final requestId = event['requestId'] as String?;
          final type = event['type'] as String?;
          if (requestId != null) {
            if (type == 'token') {
              final text = event['text'] as String? ?? '';
              _coordinator.onToken(requestId, text);
            } else if (type == 'done') {
              _coordinator.onDone(requestId);
              _updateState();
            } else if (type == 'cancelled') {
              _coordinator.onCancelled(requestId);
              _updateState();
            } else if (type == 'error') {
              final msg = event['message'] as String? ?? 'Generation failed';
              _coordinator.onError(requestId, msg);
              _updateState();
            }
          }
        }
      },
      onError: (dynamic error) {
        final activeId = _coordinator.activeRequest?.requestId;
        if (activeId != null) {
          _coordinator.onError(activeId, error.toString());
          _updateState();
        }
      },
    );
  }

  void _updateState() {
    if (_coordinator.activeRequest != null) {
      _state = AiModelState.generating;
    } else {
      _state = _isLoaded ? AiModelState.ready : AiModelState.noModel;
    }
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
    LlamaRuntimeSettings? runtimeSettings,
  }) async {
    if (!Platform.isAndroid) {
      throw const AiUnsupportedPlatformException();
    }

    _state = AiModelState.loading;
    try {
      final runtime = runtimeSettings ?? LlamaRuntimeSettings.defaultSettings;
      final bool success =
          await _channel.invokeMethod('loadModel', {
            'modelPath': modelPath,
            'backend': runtime.backend.name,
            'contextLength':
                runtime.contextLength ?? settings?.contextLength ?? 2048,
            'threads': runtime.threads ?? settings?.threads ?? 4,
            'gpuLayers': runtime.gpuLayers ?? -1,
            'batchSize': runtime.batchSize ?? 512,
            'ubatchSize': runtime.microBatchSize ?? 512,
            'flashAttention': runtime.flashAttention.nativeValue,
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
  Future<List<LlamaBackendInfo>> getAvailableBackends() async {
    if (!Platform.isAndroid) {
      return const [
        LlamaBackendInfo(
          backend: 'cpu',
          compiled: true,
          available: true,
          deviceName: 'CPU (Host)',
        ),
      ];
    }
    try {
      final List<dynamic>? list = await _channel.invokeMethod(
        'getAvailableBackends',
      );
      if (list == null) return const [];
      return list.map((item) => LlamaBackendInfo.fromMap(item as Map)).toList();
    } catch (_) {
      return const [
        LlamaBackendInfo(
          backend: 'cpu',
          compiled: true,
          available: true,
          deviceName: 'CPU',
        ),
      ];
    }
  }

  @override
  Future<LlamaActiveBackendInfo> getActiveBackendInfo() async {
    if (!Platform.isAndroid) {
      return const LlamaActiveBackendInfo();
    }
    try {
      final Map<dynamic, dynamic>? map = await _channel.invokeMethod(
        'getActiveBackendInfo',
      );
      if (map == null) return const LlamaActiveBackendInfo();
      return LlamaActiveBackendInfo.fromMap(map);
    } catch (_) {
      return const LlamaActiveBackendInfo();
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
    final handle = _coordinator.queueRequest(
      requestId: requestId,
      prompt: prompt,
      settings: settings,
      seed: seed,
      chatMessages: chatMessages,
      priority: priority,
    );

    _updateState();
    return handle;
  }

  Future<void> _startNativeGeneration(LlamaQueuedRequest req) async {
    _state = AiModelState.generating;
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
  }

  Future<void> _cancelNativeGeneration(String requestId) async {
    try {
      await _channel.invokeMethod('cancelGeneration', {'requestId': requestId});
    } catch (_) {}
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    if (!Platform.isAndroid) return;
    await _coordinator.cancelRequest(requestId);
    _updateState();
  }

  @override
  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    await _coordinator.cancelAll();
    _updateState();
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
    _coordinator.dispose();
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

  String? _activeRequestId;
  bool _isCancelling = false;
  Completer<void>? _activeTranscriptionCompleter;

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

    // If an earlier request is actively cancelling, wait for it to reach terminal before starting
    if (_isCancelling && _activeTranscriptionCompleter != null) {
      try {
        await _activeTranscriptionCompleter!.future;
      } catch (_) {}
    }

    final reqId = requestId ?? _uuid.v4();
    _activeRequestId = reqId;
    _isCancelling = false;
    final completer = Completer<void>();
    _activeTranscriptionCompleter = completer;

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
    } on PlatformException catch (e) {
      if (e.code == 'BUSY' || e.message?.contains('BUSY') == true) {
        throw const AiBusyException(
          'Whisper is busy finishing another transcription.',
        );
      }
      rethrow;
    } finally {
      _progressCallbacks.remove(reqId);
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (_activeRequestId == reqId) {
        _activeRequestId = null;
        _isCancelling = false;
        _activeTranscriptionCompleter = null;
      }
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
    if (_activeRequestId == requestId) {
      _isCancelling = true;
    }
    try {
      await _channel.invokeMethod('cancelTranscription', {
        'requestId': requestId,
      });
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    if (_activeRequestId != null) {
      _isCancelling = true;
    }
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
