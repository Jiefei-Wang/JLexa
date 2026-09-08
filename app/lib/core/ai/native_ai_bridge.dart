import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../audio/audio_models.dart';
import 'ai_engine.dart';
import 'ai_models.dart';
import 'backend_benchmark.dart';
import 'llama_request_coordinator.dart';
import 'prompt_builder.dart';
import 'speech_engine.dart';

class NativeLlamaEngine implements AiEngine, BenchmarkEngine {
  static const MethodChannel _channel = MethodChannel('com.jlexa.app/llama');
  static const EventChannel _eventChannel = EventChannel(
    'com.jlexa.app/llama_stream',
  );
  static const _uuid = Uuid();

  String? _benchmarkId;
  final _benchmarkEvents = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get benchmarkEvents => _benchmarkEvents.stream;

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
          if (event['type'] == 'benchmark') {
            if (!_benchmarkEvents.isClosed) {
              _benchmarkEvents.add(Map<String, dynamic>.from(event));
            }
            return;
          }
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

    if (_benchmarkId != null) {
      throw const AiBusyException('Benchmark is running.');
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

    if (_benchmarkId != null) {
      return AiGenerationHandle(
        requestId: '',
        stream: Stream.error(const AiBusyException('Benchmark is running.')),
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

  @override
  Future<bool> supportsBenchmark() async =>
      Platform.isAndroid &&
      (await _channel.invokeMethod<bool>('benchmarkSupported') ?? false);

  @override
  Future<Map<String, dynamic>> runBenchmark({
    required String requestId,
    required List<String> backends,
    required LlamaRuntimeSettings runtime,
  }) async {
    if (_benchmarkId != null ||
        _state == AiModelState.generating ||
        _state == AiModelState.loading) {
      throw const AiBusyException(
        'Wait for the current AI operation to finish.',
      );
    }
    if (!_isLoaded || _loadedModelPath == null) {
      throw const AiModelNotLoadedException();
    }
    _benchmarkId = requestId;
    _state = AiModelState.generating;
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>(
        'runBenchmark',
        {
          'requestId': requestId,
          'modelPath': _loadedModelPath,
          'backends': backends,
          'contextLength': runtime.contextLength ?? 2048,
          'threads': runtime.threads ?? 4,
          'gpuLayers': runtime.gpuLayers ?? -1,
          'batchSize': runtime.batchSize ?? 512,
          'ubatchSize': runtime.microBatchSize ?? 512,
          'flashAttention': runtime.flashAttention.nativeValue,
        },
      );
      if (value == null) {
        throw const AiGenerationException('No benchmark result returned.');
      }
      if (value['restored'] != true) {
        _isLoaded = false;
        _loadedModelPath = null;
      }
      return value;
    } finally {
      _benchmarkId = null;
      _state = _isLoaded ? AiModelState.ready : AiModelState.noModel;
    }
  }

  @override
  Future<void> stopBenchmark(String requestId) async {
    if (requestId == _benchmarkId) {
      await _channel.invokeMethod<void>('cancelBenchmark', {
        'requestId': requestId,
      });
    }
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
    if (_benchmarkId != null) {
      await stopBenchmark(_benchmarkId!);
      return;
    }
    await _coordinator.cancelAll();
    _updateState();
  }

  @override
  Future<void> unload() async {
    if (_benchmarkId != null) {
      throw const AiBusyException('Stop the benchmark before changing models.');
    }
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
    if (_benchmarkId != null) unawaited(stopBenchmark(_benchmarkId!));
    _benchmarkEvents.close();
    _streamSubscription?.cancel();
    _coordinator.dispose();
  }
}

class _WhisperRequest {
  final String id;
  final void Function(double)? onProgress;
  final done = Completer<void>();
  bool started = false;
  bool cancelled = false;
  Future<void>? cancellation;

  _WhisperRequest(this.id, this.onProgress);
}

class NativeWhisperEngine implements SpeechRecognitionEngine {
  static const MethodChannel _channel = MethodChannel('com.jlexa.app/whisper');
  static const EventChannel _eventChannel = EventChannel(
    'com.jlexa.app/whisper_stream',
  );
  static const _uuid = Uuid();

  bool _isLoaded = false;
  String? _loadedModelPath;

  StreamSubscription? _streamSubscription;
  final bool _isAndroid;
  _WhisperRequest? _activeRequest;
  bool _isChangingModel = false;
  bool _isDisposed = false;
  bool get isBusy => _activeRequest != null || _isChangingModel;

  NativeWhisperEngine() : _isAndroid = Platform.isAndroid {
    _initStream();
  }

  @visibleForTesting
  NativeWhisperEngine.forTesting() : _isAndroid = true {
    _initStream();
  }

  void _initStream() {
    if (!_isAndroid) return;
    _streamSubscription = _eventChannel.receiveBroadcastStream().listen((
      dynamic event,
    ) {
      if (event is Map) {
        final requestId = event['requestId'] as String?;
        final type = event['type'] as String?;
        final active = _activeRequest;
        if (type == 'progress' &&
            active != null &&
            active.id == requestId &&
            !active.cancelled &&
            !_isDisposed) {
          final progress = (event['progress'] as num?)?.toDouble() ?? 0.0;
          active.onProgress?.call(progress.clamp(0.0, 1.0).toDouble());
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
    if (!_isAndroid) {
      throw const AiUnsupportedPlatformException();
    }
    if (_isDisposed) throw StateError('The speech engine is disposed.');
    if (_isChangingModel) {
      throw const AiBusyException('Whisper is changing its speech model.');
    }
    _isChangingModel = true;
    try {
      await _finishActiveRequest();
      if (_isDisposed) throw StateError('The speech engine is disposed.');
      final bool success =
          await _channel.invokeMethod('loadModel', {'modelPath': modelPath}) ??
          false;
      _isLoaded = success;
      _loadedModelPath = success ? modelPath : null;
      if (!success) {
        throw const AiGenerationException(
          'The selected speech model could not be loaded.',
        );
      }
    } finally {
      _isChangingModel = false;
    }
  }

  @override
  Future<List<AudioSegment>> transcribeAudio({
    required String audioPath,
    required String lessonId,
    String? requestId,
    int nThreads = 4,
    void Function(double progress)? onProgress,
  }) => _transcribe(
    audioPath: audioPath,
    lessonId: lessonId,
    requestId: requestId,
    nThreads: nThreads,
    onProgress: onProgress,
  );

  Future<List<AudioSegment>> _transcribe({
    required String audioPath,
    required String lessonId,
    String? requestId,
    required int nThreads,
    void Function(double progress)? onProgress,
    Map<String, Object?> cutArguments = const {},
  }) async {
    if (!_isAndroid) {
      throw const AiUnsupportedPlatformException();
    }
    if (_isDisposed) throw StateError('The speech engine is disposed.');
    // Claim one slot before invoking callbacks or awaiting platform work.
    // Cancellation acknowledgement does not mean native work has finished.
    if (_activeRequest != null || _isChangingModel) {
      throw const AiBusyException(
        'Whisper is busy finishing another transcription or model change. Try again when it finishes.',
      );
    }
    if (!_isLoaded) {
      throw const AiModelNotLoadedException(
        'Speech model not configured. Please select a Whisper model.',
      );
    }

    final reqId = requestId ?? _uuid.v4();
    final active = _WhisperRequest(reqId, onProgress);
    _activeRequest = active;
    try {
      onProgress?.call(0.0);
      if (active.cancelled) throw const AiCancelledException();
      active.started = true;
      final dynamic rawResult = await _channel.invokeMethod('transcribeAudio', {
        'audioPath': audioPath,
        'lessonId': lessonId,
        'requestId': reqId,
        'threads': nThreads,
        ...cutArguments,
      });
      if (active.cancelled) throw const AiCancelledException();
      onProgress?.call(1.0);
      if (active.cancelled) throw const AiCancelledException();
      if (rawResult is List) {
        return rawResult
            .map(
              (e) => AudioSegment.fromMap(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
      }

      return [];
    } on PlatformException catch (e) {
      if (active.cancelled || e.code == 'CANCELLED') {
        throw const AiCancelledException();
      }
      if (e.code == 'BUSY' || e.message?.contains('BUSY') == true) {
        throw const AiBusyException(
          'Whisper is busy finishing another transcription.',
        );
      }
      rethrow;
    } finally {
      if (identical(_activeRequest, active)) _activeRequest = null;
      active.done.complete();
    }
  }

  Future<List<AudioSegment>> transcribeCut({
    required String audioPath,
    required String lessonId,
    required String cutId,
    required int cutRevision,
    required int startMs,
    required int endMs,
    required String modelId,
    String? requestId,
    int nThreads = 4,
    void Function(double progress)? onProgress,
  }) => _transcribe(
    audioPath: audioPath,
    lessonId: lessonId,
    requestId: requestId,
    nThreads: nThreads,
    onProgress: onProgress,
    cutArguments: {
      'cutId': cutId,
      'cutRevision': cutRevision,
      'cutStartMs': startMs,
      'cutEndMs': endMs,
      'modelId': modelId,
    },
  );

  @override
  Future<Map<String, dynamic>?> getAudioMetadata(String audioPath) async {
    if (!_isAndroid || _isDisposed) return null;
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
    if (!_isAndroid || _isDisposed) return null;
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
    final active = _activeRequest;
    if (!_isAndroid || active == null || active.id != requestId) return;
    active.cancelled = true;
    if (!active.started) return;
    await (active.cancellation ??= _cancelNativeRequest(active));
  }

  Future<void> _cancelNativeRequest(_WhisperRequest active) async {
    try {
      await _channel.invokeMethod('cancelTranscription', {
        'requestId': active.id,
      });
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    final active = _activeRequest;
    if (active != null) await cancelRequest(active.id);
  }

  Future<void> _finishActiveRequest() async {
    final active = _activeRequest;
    if (active == null) return;
    await cancelRequest(active.id);
    await active.done.future;
  }

  @override
  Future<void> unload() async {
    if (!_isAndroid || _isDisposed) return;
    if (_isChangingModel) {
      throw const AiBusyException('Whisper is changing its speech model.');
    }
    _isChangingModel = true;
    try {
      await _finishActiveRequest();
      await _channel.invokeMethod('unloadModel');
      _isLoaded = false;
      _loadedModelPath = null;
    } finally {
      _isChangingModel = false;
    }
  }

  void dispose() {
    _isDisposed = true;
    unawaited(cancel());
    _streamSubscription?.cancel();
  }
}
