import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../audio/audio_models.dart';
import 'ai_engine.dart';
import 'ai_models.dart';
import 'speech_engine.dart';

class NativeLlamaEngine implements AiEngine {
  static const MethodChannel _channel = MethodChannel('com.jlexa.app/llama');
  static const EventChannel _eventChannel = EventChannel('com.jlexa.app/llama_stream');

  bool _isLoaded = false;
  String? _loadedModelPath;
  AiModelState _state = AiModelState.noModel;

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
        _state = AiModelState.error;
        throw Exception('The selected AI model could not be loaded.');
      }
    } catch (e) {
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

    _state = AiModelState.generating;
    try {
      await _channel.invokeMethod('startGeneration', {
        'prompt': prompt,
        'temperature': settings?.temperature ?? 0.7,
        'maxTokens': settings?.maxTokens ?? 512,
        'topP': settings?.topP ?? 0.9,
      });

      await for (final event in _eventChannel.receiveBroadcastStream()) {
        if (event is String) {
          yield event;
        } else if (event is Map && event['error'] != null) {
          yield '\n[Error: ${event['error']}]';
          break;
        }
      }
    } catch (e) {
      yield '\n[Error generating response: $e]';
    } finally {
      _state = _isLoaded ? AiModelState.ready : AiModelState.noModel;
    }
  }

  @override
  Future<void> cancel() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('cancelGeneration');
    } catch (_) {}
  }

  @override
  Future<void> unload() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('unloadModel');
      _isLoaded = false;
      _loadedModelPath = null;
      _state = AiModelState.noModel;
    } catch (_) {}
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
      await _channel.invokeMethod('unloadModel');
      _isLoaded = false;
      _loadedModelPath = null;
    } catch (_) {}
  }
}
