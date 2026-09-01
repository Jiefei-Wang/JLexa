import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_service.dart';
import '../../core/ai/model_catalog.dart';
import '../../core/ai/model_downloader.dart';
import '../../core/ai/model_file_picker.dart';
import '../../core/ai/model_manager.dart';
import '../../core/ai/model_storage.dart';

class SettingsController extends ChangeNotifier {
  final AiService aiService;
  final ModelManager modelManager;
  final ModelFilePicker filePicker;

  bool _isProcessing = false;
  String? _errorMessage;
  bool _isDisposed = false;

  bool get isLoading => _isProcessing || !modelManager.isInitialized;
  String? get errorMessage => _errorMessage;

  List<ManagedModelItem> get llmModels => modelManager.llmModels;
  List<ManagedModelItem> get whisperModels => modelManager.whisperModels;

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  SettingsController({
    required this.aiService,
    ModelManager? manager,
    ModelFilePicker? picker,
  }) : modelManager =
           manager ??
           ModelManager(
             storage: ModelStorage(),
             downloader: DioModelDownloader(),
             aiService: aiService,
           ),
       filePicker = picker ?? PlatformModelFilePicker() {
    modelManager.addListener(_onModelManagerChanged);
  }

  void _onModelManagerChanged() {
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> downloadModel(DownloadableModel model) async {
    _errorMessage = null;
    notifyListeners();
    try {
      await modelManager.downloadModel(model);
    } catch (e) {
      _errorMessage = 'Download failed: $e';
      notifyListeners();
    }
  }

  void cancelDownload(String modelId) {
    modelManager.cancelDownload(modelId);
    notifyListeners();
  }

  Future<void> loadModel(ManagedModelItem item) async {
    _errorMessage = null;
    _isProcessing = true;
    notifyListeners();
    try {
      await modelManager.loadModel(item);
    } catch (e) {
      _errorMessage = 'Failed to load model "${item.displayName}": $e';
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  Future<void> unloadModel(ManagedModelItem item) async {
    _errorMessage = null;
    _isProcessing = true;
    notifyListeners();
    try {
      await modelManager.unloadModel(item);
    } catch (e) {
      _errorMessage = 'Failed to unload model: $e';
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  Future<void> deleteModel(ManagedModelItem item) async {
    _errorMessage = null;
    _isProcessing = true;
    notifyListeners();
    try {
      await modelManager.deleteModel(item);
    } catch (e) {
      _errorMessage = 'Failed to delete model: $e';
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  Future<void> pickAndImportLlmModel() async {
    _errorMessage = null;
    try {
      final pickedPath = await filePicker.pickLlmModel();
      if (pickedPath == null) return;

      _isProcessing = true;
      notifyListeners();

      await modelManager.importLocalModel(pickedPath, ModelType.llm);
    } catch (e) {
      _errorMessage = '$e';
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  Future<void> pickAndImportSpeechModel() async {
    _errorMessage = null;
    try {
      final pickedPath = await filePicker.pickSpeechModel();
      if (pickedPath == null) return;

      _isProcessing = true;
      notifyListeners();

      await modelManager.importLocalModel(pickedPath, ModelType.whisper);
    } catch (e) {
      _errorMessage = '$e';
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  // Backward compatibility getters
  ModelInfo? get llmInfo {
    final loadedPath =
        aiService.llmEngine.loadedModelPath ?? aiService.configuredLlmPath;
    if (loadedPath != null && loadedPath.isNotEmpty) {
      final file = File(loadedPath);
      return ModelInfo(
        path: loadedPath,
        name: p.basename(loadedPath),
        fileSizeBytes: file.existsSync() ? file.lengthSync() : 0,
        isLoaded: aiService.llmEngine.isLoaded,
      );
    }
    return null;
  }

  ModelInfo? get speechInfo {
    final loadedPath =
        aiService.speechEngine.loadedModelPath ??
        aiService.configuredSpeechPath;
    if (loadedPath != null && loadedPath.isNotEmpty) {
      final file = File(loadedPath);
      return ModelInfo(
        path: loadedPath,
        name: p.basename(loadedPath),
        fileSizeBytes: file.existsSync() ? file.lengthSync() : 0,
        isLoaded: aiService.speechEngine.isLoaded,
      );
    }
    return null;
  }

  @override
  void dispose() {
    _isDisposed = true;
    modelManager.removeListener(_onModelManagerChanged);
    super.dispose();
  }
}
