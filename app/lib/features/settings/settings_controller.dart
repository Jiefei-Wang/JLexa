import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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
    aiService.addListener(_refreshModelInfo);
    _refreshModelInfo();
  }

  void _refreshModelInfo() {
    final llmPath = aiService.llmEngine.loadedModelPath ?? aiService.configuredLlmPath;
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

    final speechPath = aiService.speechEngine.loadedModelPath ?? aiService.configuredSpeechPath;
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

  Future<String> _copyToAppStorage(String sourcePath, String subDir) async {
    final sourceFile = File(sourcePath);
    final appSupport = await getApplicationSupportDirectory();
    final targetDir = Directory('${appSupport.path}/models/$subDir');
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    final fileName = sourceFile.uri.pathSegments.last;
    final targetFile = File('${targetDir.path}/$fileName');

    // If file already exists and has same size, reuse it
    if (await targetFile.exists()) {
      final sourceLen = await sourceFile.length();
      final targetLen = await targetFile.length();
      if (sourceLen == targetLen) {
        return targetFile.path;
      }
    }

    await sourceFile.copy(targetFile.path);
    return targetFile.path;
  }

  Future<void> pickAndLoadLlmModel() async {
    _errorMessage = null;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gguf'],
      );

      if (result != null && result.files.single.path != null) {
        final rawPath = result.files.single.path!;
        _isLoading = true;
        notifyListeners();

        // Explicitly unload previous model first
        if (aiService.llmEngine.isLoaded) {
          await aiService.unloadLlmModel();
        }

        // Copy to app support storage
        final managedPath = await _copyToAppStorage(rawPath, 'llm');

        await aiService.loadLlmModel(managedPath);
        _refreshModelInfo();
      }
    } catch (e) {
      _errorMessage = 'Failed to load LLM model: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadConfiguredLlmModel() async {
    final path = aiService.configuredLlmPath;
    if (path == null || path.isEmpty) return;

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await aiService.loadLlmModel(path);
      _refreshModelInfo();
    } catch (e) {
      _errorMessage = 'Failed to load configured LLM model: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> unloadLlmModel() async {
    await aiService.unloadLlmModel();
    _refreshModelInfo();
  }

  Future<void> forgetLlmModel({bool deleteFile = false}) async {
    await aiService.forgetLlmModel(deleteFile: deleteFile);
    _refreshModelInfo();
  }

  Future<void> pickAndLoadSpeechModel() async {
    _errorMessage = null;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['bin', 'ggml'],
      );

      if (result != null && result.files.single.path != null) {
        final rawPath = result.files.single.path!;
        _isLoading = true;
        notifyListeners();

        // Explicitly unload previous model first
        if (aiService.speechEngine.isLoaded) {
          await aiService.unloadSpeechModel();
        }

        // Copy to app support storage
        final managedPath = await _copyToAppStorage(rawPath, 'whisper');

        await aiService.loadSpeechModel(managedPath);
        _refreshModelInfo();
      }
    } catch (e) {
      _errorMessage = 'Failed to load speech model: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadConfiguredSpeechModel() async {
    final path = aiService.configuredSpeechPath;
    if (path == null || path.isEmpty) return;

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await aiService.loadSpeechModel(path);
      _refreshModelInfo();
    } catch (e) {
      _errorMessage = 'Failed to load configured speech model: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> unloadSpeechModel() async {
    await aiService.unloadSpeechModel();
    _refreshModelInfo();
  }

  Future<void> forgetSpeechModel({bool deleteFile = false}) async {
    await aiService.forgetSpeechModel(deleteFile: deleteFile);
    _refreshModelInfo();
  }

  @override
  void dispose() {
    aiService.removeListener(_refreshModelInfo);
    super.dispose();
  }
}
