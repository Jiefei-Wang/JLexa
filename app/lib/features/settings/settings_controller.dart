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
  final bool _ownsManager;

  bool _isProcessing = false;
  String? _errorMessage;
  bool _isDisposed = false;

  bool get isLoading => _isProcessing || !modelManager.isInitialized;
  String? get errorMessage => _errorMessage;

  bool get isStorageConfigured => modelManager.isStorageConfigured;
  String? get storageLocationDisplay => modelManager.storageLocationDisplay;

  List<ManagedModelItem> get llmModels => modelManager.llmModels;
  List<ManagedModelItem> get whisperModels => modelManager.whisperModels;

  LlamaRuntimeSettings get llamaSettings => aiService.llamaRuntimeSettings;
  List<LlamaBackendInfo> get availableBackends => aiService.availableBackends;
  LlamaActiveBackendInfo get activeBackendInfo => aiService.activeBackendInfo;
  String? get llmRestorationError => aiService.llmRestorationError;
  String? get speechRestorationError => aiService.speechRestorationError;
  AiGenerationSettings get generationSettings => aiService.settings;

  Future<bool> chooseStorageFolder() async {
    _errorMessage = null;
    _isProcessing = true;
    notifyListeners();
    try {
      final success = await modelManager.chooseInitialStorageFolder();
      return success;
    } catch (e) {
      if (!_isDisposed) {
        _errorMessage = 'Failed to select storage folder: $e';
      }
      return false;
    } finally {
      if (!_isDisposed) {
        _isProcessing = false;
        notifyListeners();
      }
    }
  }

  Future<bool> changeStorageFolder() async {
    _errorMessage = null;
    _isProcessing = true;
    notifyListeners();
    try {
      final success = await modelManager.changeStorageFolder();
      return success;
    } catch (e) {
      if (!_isDisposed) {
        _errorMessage = 'Failed to change storage folder: $e';
      }
      return false;
    } finally {
      if (!_isDisposed) {
        _isProcessing = false;
        notifyListeners();
      }
    }
  }

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
  }) : _ownsManager = manager == null,
       modelManager =
           manager ??
           ModelManager(
             storage: ModelStorage(),
             downloader: DioModelDownloader(),
             aiService: aiService,
           ),
       filePicker = picker ?? PlatformModelFilePicker() {
    modelManager.addListener(_onModelManagerChanged);
    aiService.addListener(_onAiServiceChanged);
  }

  void _onModelManagerChanged() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  void _onAiServiceChanged() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  Future<void> updateBackendPreference(LlamaBackendPreference pref) async {
    final updated = llamaSettings.copyWith(backend: pref);
    await updateLlamaSettings(updated);
  }

  Future<void> updateLlamaSettings(LlamaRuntimeSettings newSettings) async {
    _errorMessage = null;
    try {
      await aiService.updateLlamaRuntimeSettings(newSettings, autoReload: true);
    } catch (e) {
      if (!_isDisposed) {
        _errorMessage = 'Failed to apply llama settings: $e';
      }
    }
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  Future<void> resetLlamaSettings() async {
    _errorMessage = null;
    try {
      await aiService.resetLlamaRuntimeSettings(autoReload: true);
    } catch (e) {
      if (!_isDisposed) {
        _errorMessage = 'Failed to reset settings: $e';
      }
    }
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  void updateAiGenerationSettings(AiGenerationSettings settings) {
    aiService.updateSettings(settings);
    if (!_isDisposed) {
      notifyListeners();
    }
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
    } on ModelDownloadCancelledException {
      _errorMessage = null;
    } catch (e) {
      if (!_isDisposed) {
        _errorMessage = 'Download failed: $e';
      }
    } finally {
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }

  void cancelDownload(String modelId) {
    _errorMessage = null;
    modelManager.cancelDownload(modelId);
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  Future<void> loadModel(ManagedModelItem item) async {
    _errorMessage = null;
    _isProcessing = true;
    notifyListeners();
    try {
      await modelManager.loadModel(item);
    } catch (e) {
      if (!_isDisposed) {
        _errorMessage = 'Failed to load model "${item.displayName}": $e';
      }
    } finally {
      if (!_isDisposed) {
        _isProcessing = false;
        notifyListeners();
      }
    }
  }

  Future<void> unloadModel(ManagedModelItem item) async {
    _errorMessage = null;
    _isProcessing = true;
    notifyListeners();
    try {
      await modelManager.unloadModel(item);
    } catch (e) {
      if (!_isDisposed) {
        _errorMessage = 'Failed to unload model: $e';
      }
    } finally {
      if (!_isDisposed) {
        _isProcessing = false;
        notifyListeners();
      }
    }
  }

  Future<void> deleteModel(ManagedModelItem item) async {
    _errorMessage = null;
    _isProcessing = true;
    notifyListeners();
    try {
      await modelManager.deleteModel(item);
    } catch (e) {
      if (!_isDisposed) {
        _errorMessage = 'Failed to delete model: $e';
      }
    } finally {
      if (!_isDisposed) {
        _isProcessing = false;
        notifyListeners();
      }
    }
  }

  Future<void> pickAndImportLlmModel() async {
    _errorMessage = null;
    try {
      final pickedPath = await filePicker.pickLlmModel();
      if (pickedPath == null || _isDisposed) return;

      _isProcessing = true;
      notifyListeners();

      await modelManager.importLocalModel(pickedPath, ModelType.llm);
    } catch (e) {
      if (!_isDisposed) {
        _errorMessage = '$e';
      }
    } finally {
      if (!_isDisposed) {
        _isProcessing = false;
        notifyListeners();
      }
    }
  }

  Future<void> pickAndImportSpeechModel() async {
    _errorMessage = null;
    try {
      final pickedPath = await filePicker.pickSpeechModel();
      if (pickedPath == null || _isDisposed) return;

      _isProcessing = true;
      notifyListeners();

      await modelManager.importLocalModel(pickedPath, ModelType.whisper);
    } catch (e) {
      if (!_isDisposed) {
        _errorMessage = '$e';
      }
    } finally {
      if (!_isDisposed) {
        _isProcessing = false;
        notifyListeners();
      }
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
    aiService.removeListener(_onAiServiceChanged);
    if (_ownsManager) {
      modelManager.dispose();
    }
    super.dispose();
  }
}
