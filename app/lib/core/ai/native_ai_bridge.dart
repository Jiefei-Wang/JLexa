import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../audio/audio_models.dart';
import 'ai_engine.dart';
import 'ai_models.dart';
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
            } else if (type == 'cancelled') {
              if (!controller.isClosed) {
                controller.close();
              }
              _activeRequests.remove(requestId);
            } else if (type == 'error') {
              final msg = event['message'] as String? ?? 'Generation failed';
              if (!controller.isClosed) {
                controller.addError(Exception(msg));
                controller.close();
              }
              _activeRequests.remove(requestId);
            }
          }
        }
      },
      onError: (dynamic error) {
        for (final controller in _activeRequests.values) {
          if (!controller.isClosed) {
            controller.addError(error is Exception ? error : Exception(error.toString()));
            controller.close();
          }
        }
        _activeRequests.clear();
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
      throw UnsupportedError('Local AI inference for iOS is not implemented yet.');
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
        throw Exception('The selected AI model could not be loaded.');
      }
    } catch (e) {
      _isLoaded = false;
      _loadedModelPath = null;
      _state = AiModelState.error;
      rethrow;
    }
  }

  @override
  Stream<String> generate(String prompt, {AiGenerationSettings? settings}) async* {
    if (!Platform.isAndroid) {
      yield 'Local AI inference for iOS is not implemented yet.';
      return;
    }

    if (!_isLoaded) {
      yield 'Load a local AI model to use AI explanation.';
      return;
    }

    if (_isCurrentlyGenerating) {
      yield 'Another generation is already in progress. Please wait.';
      return;
    }

    final requestId = _uuid.v4();
    final controller = StreamController<String>();
    _activeRequests[requestId] = controller;
    _currentRequestId = requestId;
    _isCurrentlyGenerating = true;
    _state = AiModelState.generating;

    try {
      await _channel.invokeMethod('startGeneration', {
        'requestId': requestId,
        'prompt': prompt,
        'temperature': settings?.temperature ?? 0.7,
        'maxTokens': settings?.maxTokens ?? 512,
        'topP': settings?.topP ?? 0.9,
      });

      yield* controller.stream;
    } catch (e) {
      yield '\n[Error generating response: $e]';
    } finally {
      _activeRequests.remove(requestId);
      if (!controller.isClosed) {
        controller.close();
      }
      if (_currentRequestId == requestId) {
        _currentRequestId = null;
        _isCurrentlyGenerating = false;
      }
      _state = _isLoaded ? AiModelState.ready : AiModelState.noModel;
    }
  }

  @override
  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    try {
      final reqId = _currentRequestId;
      await _channel.invokeMethod('cancelGeneration', {'requestId': reqId});
      if (reqId != null) {
        final ctrl = _activeRequests.remove(reqId);
        if (ctrl != null && !ctrl.isClosed) {
          ctrl.close();
        }
      }
      _isCurrentlyGenerating = false;
      _currentRequestId = null;
      _state = _isLoaded ? AiModelState.ready : AiModelState.noModel;
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

  bool _isLoaded = false;
  String? _loadedModelPath;

  @override
  bool get isLoaded => _isLoaded;

  @override
  String? get loadedModelPath => _loadedModelPath;

  @override
  Future<void> loadModel(String modelPath) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Local speech recognition for iOS is not implemented yet.');
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
      throw Exception('The selected speech model could not be loaded.');
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
      throw UnsupportedError('Local speech recognition for iOS is not implemented yet.');
    }

    if (!_isLoaded) {
      throw Exception('Speech model not configured. Please select a Whisper model.');
    }

    final dynamic rawResult = await _channel.invokeMethod('transcribeAudio', {
      'audioPath': audioPath,
      'lessonId': lessonId,
      'threads': nThreads,
    });

    if (rawResult is List) {
      return rawResult.map((e) => AudioSegment.fromMap(Map<String, dynamic>.from(e as Map))).toList();
    }

    return [];
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
}
