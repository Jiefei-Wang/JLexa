import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_service.dart';

class SettingsController extends ChangeNotifier {
  final AiService aiService;

  ModelInfo? _llmInfo;
  ModelInfo? _speechInfo;
  bool _isLoading = false;
  String? _errorMessage;

  ModelInfo? get llmInfo => _llmInfo;
  ModelInfo? get speechInfo => _speechInfo;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  SettingsController({required this.aiService}) {
    _refreshModelInfo();
  }

  void _refreshModelInfo() {
    final llmPath = aiService.llmEngine.loadedModelPath;
    if (llmPath != null && llmPath.isNotEmpty) {
      final file = File(llmPath);
      final size = file.existsSync() ? file.lengthSync() : 0;
      _llmInfo = ModelInfo(
        path: llmPath,
        name: llmPath.split(Platform.pathSeparator).last,
        fileSizeBytes: size,
        isLoaded: aiService.llmEngine.isLoaded,
      );
    } else {
      _llmInfo = null;
    }

    final speechPath = aiService.speechEngine.loadedModelPath;
    if (speechPath != null && speechPath.isNotEmpty) {
      final file = File(speechPath);
      final size = file.existsSync() ? file.lengthSync() : 0;
      _speechInfo = ModelInfo(
        path: speechPath,
        name: speechPath.split(Platform.pathSeparator).last,
        fileSizeBytes: size,
        isLoaded: aiService.speechEngine.isLoaded,
      );
    } else {
      _speechInfo = null;
    }

    notifyListeners();
  }

  Future<void> pickAndLoadLlmModel() async {
    _errorMessage = null;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gguf', 'bin'],
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        _isLoading = true;
        notifyListeners();

        await aiService.loadLlmModel(path);
        _refreshModelInfo();
      }
    } catch (e) {
      _errorMessage = 'Failed to load LLM model: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> unloadLlmModel() async {
    await aiService.unloadLlmModel();
    _refreshModelInfo();
  }

  Future<void> pickAndLoadSpeechModel() async {
    _errorMessage = null;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['bin', 'ggml', 'gguf'],
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        _isLoading = true;
        notifyListeners();

        await aiService.loadSpeechModel(path);
        _refreshModelInfo();
      }
    } catch (e) {
      _errorMessage = 'Failed to load speech model: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> unloadSpeechModel() async {
    await aiService.unloadSpeechModel();
    _refreshModelInfo();
  }
}
