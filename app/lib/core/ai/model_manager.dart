import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'ai_service.dart';
import 'model_catalog.dart';
import 'model_downloader.dart';
import 'model_storage.dart';

class ManagedModelItem {
  final String id;
  final String displayName;
  final ModelType type;
  final DownloadableModel? catalogModel;
  final String? localPath;
  final int fileSizeBytes;
  final bool isCustomImport;
  final ModelDownloadState state;
  final ModelProgress? progress;
  final String? errorMessage;
  final bool isRecommended;
  final String memoryHint;
  final String speedHint;
  final String description;

  const ManagedModelItem({
    required this.id,
    required this.displayName,
    required this.type,
    this.catalogModel,
    this.localPath,
    this.fileSizeBytes = 0,
    this.isCustomImport = false,
    this.state = ModelDownloadState.notDownloaded,
    this.progress,
    this.errorMessage,
    this.isRecommended = false,
    this.memoryHint = '',
    this.speedHint = '',
    this.description = '',
  });

  String get formattedSize {
    if (fileSizeBytes > 0) {
      return ModelCatalog.formatBytes(fileSizeBytes);
    }
    if (catalogModel != null) {
      return catalogModel!.formattedSize;
    }
    return 'Unknown';
  }

  bool get isLoaded => state == ModelDownloadState.loaded;
  bool get isDownloaded =>
      state == ModelDownloadState.downloaded ||
      state == ModelDownloadState.loading ||
      state == ModelDownloadState.loaded;
  bool get isDownloading => state == ModelDownloadState.downloading;

  ManagedModelItem copyWith({
    String? id,
    String? displayName,
    ModelType? type,
    DownloadableModel? catalogModel,
    String? localPath,
    int? fileSizeBytes,
    bool? isCustomImport,
    ModelDownloadState? state,
    ModelProgress? progress,
    String? errorMessage,
    bool? isRecommended,
    String? memoryHint,
    String? speedHint,
    String? description,
  }) {
    return ManagedModelItem(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      type: type ?? this.type,
      catalogModel: catalogModel ?? this.catalogModel,
      localPath: localPath ?? this.localPath,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      isCustomImport: isCustomImport ?? this.isCustomImport,
      state: state ?? this.state,
      progress: progress ?? this.progress,
      errorMessage: errorMessage,
      isRecommended: isRecommended ?? this.isRecommended,
      memoryHint: memoryHint ?? this.memoryHint,
      speedHint: speedHint ?? this.speedHint,
      description: description ?? this.description,
    );
  }
}

class ModelManager extends ChangeNotifier {
  final ModelStorage storage;
  final ModelDownloader downloader;
  final AiService aiService;

  final Map<String, ModelProgress> _downloadProgress = {};
  final Map<String, String> _modelErrors = {};
  final Set<String> _loadingModelIds = {};

  final Set<String> _activePartPaths = {};

  List<ManagedModelItem> _llmModels = [];
  List<ManagedModelItem> _whisperModels = [];
  bool _isInitialized = false;

  bool _isDisposed = false;

  List<ManagedModelItem> get llmModels => List.unmodifiable(_llmModels);
  List<ManagedModelItem> get whisperModels => List.unmodifiable(_whisperModels);
  bool get isInitialized => _isInitialized;
  bool get isStorageConfigured => storage.isConfigured;
  String? get storageLocationDisplay => storage.baseLocationDisplay;

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  ModelManager({
    required this.storage,
    required this.downloader,
    required this.aiService,
  }) {
    aiService.addListener(_onAiServiceChanged);
    initialize();
  }

  void _onAiServiceChanged() {
    _syncModelStates();
  }

  Future<void> initialize() async {
    final restored = await storage.restorePersistedFolderAccess();
    if (restored) {
      await storage.cleanStalePartFiles(activePartPaths: _activePartPaths);
      await refreshModels();
    } else {
      _llmModels = [];
      _whisperModels = [];
    }
    _isInitialized = true;
    notifyListeners();
  }

  Future<bool> chooseInitialStorageFolder() async {
    final success = await storage.chooseBaseFolder();
    if (success) {
      await storage.cleanStalePartFiles();
      await refreshModels();
      notifyListeners();
    }
    return success;
  }

  Future<bool> changeStorageFolder() async {
    final previousLlmPath =
        aiService.llmEngine.isLoaded ? aiService.llmEngine.loadedModelPath : null;
    final previousSpeechPath =
        aiService.speechEngine.isLoaded ? aiService.speechEngine.loadedModelPath : null;

    final success = await storage.chooseBaseFolder();
    if (!success) return false;

    final newLlmFiles = await storage.listModelFiles(ModelType.llm);
    final newWhisperFiles = await storage.listModelFiles(ModelType.whisper);

    // Safely unload active LLM model if not in new folder
    if (previousLlmPath != null) {
      final existsInNew = newLlmFiles.any(
        (f) =>
            f.location == previousLlmPath ||
            p.basename(f.location) == p.basename(previousLlmPath),
      );
      if (!existsInNew) {
        await aiService.unloadLlmModel();
      }
    }

    // Safely unload active Whisper model if not in new folder
    if (previousSpeechPath != null) {
      final existsInNew = newWhisperFiles.any(
        (f) =>
            f.location == previousSpeechPath ||
            p.basename(f.location) == p.basename(previousSpeechPath),
      );
      if (!existsInNew) {
        await aiService.unloadSpeechModel();
      }
    }

    await storage.cleanStalePartFiles();
    await refreshModels();
    notifyListeners();
    return true;
  }

  Future<void> refreshModels() async {
    if (!storage.isConfigured) {
      _llmModels = [];
      _whisperModels = [];
      return;
    }

    final downloadedLlmEntries = await storage.listModelFiles(ModelType.llm);
    final downloadedWhisperEntries = await storage.listModelFiles(ModelType.whisper);

    // Build curated LLM items
    final llmItems = <ManagedModelItem>[];
    final knownLlmLocations = <String>{};

    for (final catalog in ModelCatalog.curatedLlmModels) {
      final matchingFile = downloadedLlmEntries.where(
        (f) => f.name.toLowerCase() == catalog.filename.toLowerCase(),
      ).firstOrNull;

      final exists = matchingFile != null && matchingFile.sizeBytes > 0;
      final fileLoc = matchingFile?.location;
      final size = matchingFile?.sizeBytes ?? 0;

      if (exists && fileLoc != null) {
        knownLlmLocations.add(fileLoc);
      }

      final isDownloading =
          downloader.isDownloading(catalog.id) ||
          _downloadProgress.containsKey(catalog.id);
      final isLoading = _loadingModelIds.contains(catalog.id);
      final isCurrentlyLoaded =
          aiService.llmEngine.isLoaded &&
          aiService.llmEngine.loadedModelPath != null &&
          fileLoc != null &&
          (aiService.llmEngine.loadedModelPath == fileLoc ||
              p.canonicalize(aiService.llmEngine.loadedModelPath!) ==
                  p.canonicalize(fileLoc));

      ModelDownloadState state;
      if (isCurrentlyLoaded) {
        state = ModelDownloadState.loaded;
      } else if (isLoading) {
        state = ModelDownloadState.loading;
      } else if (isDownloading) {
        state = ModelDownloadState.downloading;
      } else if (exists) {
        state = ModelDownloadState.downloaded;
      } else if (_modelErrors.containsKey(catalog.id)) {
        state = ModelDownloadState.error;
      } else {
        state = ModelDownloadState.notDownloaded;
      }

      llmItems.add(
        ManagedModelItem(
          id: catalog.id,
          displayName: catalog.displayName,
          type: ModelType.llm,
          catalogModel: catalog,
          localPath: exists ? fileLoc : null,
          fileSizeBytes: size,
          isCustomImport: false,
          state: state,
          progress: _downloadProgress[catalog.id],
          errorMessage: _modelErrors[catalog.id],
          isRecommended: catalog.isRecommended,
          memoryHint: catalog.memoryHint,
          speedHint: catalog.speedHint,
          description: catalog.description,
        ),
      );
    }

    // Check for custom placed/imported LLM files in managed storage
    for (final file in downloadedLlmEntries) {
      if (!knownLlmLocations.contains(file.location)) {
        final isCurrentlyLoaded =
            aiService.llmEngine.isLoaded &&
            aiService.llmEngine.loadedModelPath != null &&
            (aiService.llmEngine.loadedModelPath == file.location ||
                p.canonicalize(aiService.llmEngine.loadedModelPath!) ==
                    p.canonicalize(file.location));

        final itemId = 'custom_llm_${file.name}_${file.location.hashCode}';
        final isLoading = _loadingModelIds.contains(itemId);

        llmItems.add(
          ManagedModelItem(
            id: itemId,
            displayName: file.name,
            type: ModelType.llm,
            localPath: file.location,
            fileSizeBytes: file.sizeBytes,
            isCustomImport: true,
            state: isCurrentlyLoaded
                ? ModelDownloadState.loaded
                : (isLoading
                    ? ModelDownloadState.loading
                    : ModelDownloadState.downloaded),
            description: 'Custom model in storage folder',
            memoryHint: 'Custom',
            speedHint: 'Custom',
          ),
        );
      }
    }

    // Build curated Whisper items
    final whisperItems = <ManagedModelItem>[];
    final knownWhisperLocations = <String>{};

    for (final catalog in ModelCatalog.curatedWhisperModels) {
      final matchingFile = downloadedWhisperEntries.where(
        (f) => f.name.toLowerCase() == catalog.filename.toLowerCase(),
      ).firstOrNull;

      final exists = matchingFile != null && matchingFile.sizeBytes > 0;
      final fileLoc = matchingFile?.location;
      final size = matchingFile?.sizeBytes ?? 0;

      if (exists && fileLoc != null) {
        knownWhisperLocations.add(fileLoc);
      }

      final isDownloading =
          downloader.isDownloading(catalog.id) ||
          _downloadProgress.containsKey(catalog.id);
      final isLoading = _loadingModelIds.contains(catalog.id);
      final isCurrentlyLoaded =
          aiService.speechEngine.isLoaded &&
          aiService.speechEngine.loadedModelPath != null &&
          fileLoc != null &&
          (aiService.speechEngine.loadedModelPath == fileLoc ||
              p.canonicalize(aiService.speechEngine.loadedModelPath!) ==
                  p.canonicalize(fileLoc));

      ModelDownloadState state;
      if (isCurrentlyLoaded) {
        state = ModelDownloadState.loaded;
      } else if (isLoading) {
        state = ModelDownloadState.loading;
      } else if (isDownloading) {
        state = ModelDownloadState.downloading;
      } else if (exists) {
        state = ModelDownloadState.downloaded;
      } else if (_modelErrors.containsKey(catalog.id)) {
        state = ModelDownloadState.error;
      } else {
        state = ModelDownloadState.notDownloaded;
      }

      whisperItems.add(
        ManagedModelItem(
          id: catalog.id,
          displayName: catalog.displayName,
          type: ModelType.whisper,
          catalogModel: catalog,
          localPath: exists ? fileLoc : null,
          fileSizeBytes: size,
          isCustomImport: false,
          state: state,
          progress: _downloadProgress[catalog.id],
          errorMessage: _modelErrors[catalog.id],
          isRecommended: catalog.isRecommended,
          memoryHint: catalog.memoryHint,
          speedHint: catalog.speedHint,
          description: catalog.description,
        ),
      );
    }

    // Check for custom placed/imported Whisper files
    for (final file in downloadedWhisperEntries) {
      if (!knownWhisperLocations.contains(file.location)) {
        final isCurrentlyLoaded =
            aiService.speechEngine.isLoaded &&
            aiService.speechEngine.loadedModelPath != null &&
            (aiService.speechEngine.loadedModelPath == file.location ||
                p.canonicalize(aiService.speechEngine.loadedModelPath!) ==
                    p.canonicalize(file.location));

        final itemId = 'custom_whisper_${file.name}_${file.location.hashCode}';
        final isLoading = _loadingModelIds.contains(itemId);

        whisperItems.add(
          ManagedModelItem(
            id: itemId,
            displayName: file.name,
            type: ModelType.whisper,
            localPath: file.location,
            fileSizeBytes: file.sizeBytes,
            isCustomImport: true,
            state: isCurrentlyLoaded
                ? ModelDownloadState.loaded
                : (isLoading
                    ? ModelDownloadState.loading
                    : ModelDownloadState.downloaded),
            description: 'Custom model in storage folder',
            memoryHint: 'Custom',
            speedHint: 'Custom',
          ),
        );
      }
    }

    _llmModels = llmItems;
    _whisperModels = whisperItems;
  }

  void _syncModelStates() {
    refreshModels().then((_) => notifyListeners());
  }

  Future<void> downloadModel(DownloadableModel catalogModel) async {
    if (!storage.isConfigured) {
      throw const ModelValidationException('Storage folder has not been configured.');
    }
    final modelId = catalogModel.id;
    _modelErrors.remove(modelId);

    final destinationPartLocation = await storage.prepareDownloadPart(
      catalogModel.modelType,
      catalogModel.filename,
    );

    _activePartPaths.add(destinationPartLocation);

    _downloadProgress[modelId] = const ModelProgress(
      receivedBytes: 0,
      totalBytes: 0,
      progress: 0.0,
    );
    await refreshModels();
    notifyListeners();

    try {
      if (storage.backend is AndroidSafModelStorageBackend) {
        await storage.download(
          model: catalogModel,
          destinationPartLocation: destinationPartLocation,
          onProgress: (prog) {
            _downloadProgress[modelId] = prog;
            _updateItemProgress(modelId, prog);
          },
        );
      } else {
        await downloader.download(
          model: catalogModel,
          destinationPartPath: destinationPartLocation,
          onProgress: (prog) {
            _downloadProgress[modelId] = prog;
            _updateItemProgress(modelId, prog);
          },
        );
      }

      await storage.finalizeDownload(
        destinationPartLocation,
        catalogModel.filename,
        catalogModel.modelType,
        expectedSizeBytes: catalogModel.expectedSizeBytes,
      );

      _downloadProgress.remove(modelId);
      _modelErrors.remove(modelId);
      await refreshModels();
      notifyListeners();
    } catch (e) {
      _downloadProgress.remove(modelId);
      if (e is ModelDownloadCancelledException) {
        await storage.deleteModel(destinationPartLocation);
        _modelErrors.remove(modelId);
        await refreshModels();
        notifyListeners();
        return;
      }

      _modelErrors[modelId] = e.toString();
      await refreshModels();
      notifyListeners();
      rethrow;
    } finally {
      _activePartPaths.remove(destinationPartLocation);
    }
  }

  void _updateItemProgress(String modelId, ModelProgress prog) {
    bool updated = false;
    for (int i = 0; i < _llmModels.length; i++) {
      if (_llmModels[i].id == modelId) {
        _llmModels[i] = _llmModels[i].copyWith(
          state: ModelDownloadState.downloading,
          progress: prog,
        );
        updated = true;
        break;
      }
    }
    if (!updated) {
      for (int i = 0; i < _whisperModels.length; i++) {
        if (_whisperModels[i].id == modelId) {
          _whisperModels[i] = _whisperModels[i].copyWith(
            state: ModelDownloadState.downloading,
            progress: prog,
          );
          updated = true;
          break;
        }
      }
    }
    if (updated) {
      notifyListeners();
    }
  }

  void cancelDownload(String modelId) {
    storage.cancelDownload(modelId);
    downloader.cancel(modelId);
    _downloadProgress.remove(modelId);
    _modelErrors.remove(modelId);
    _syncModelStates();
  }

  Future<void> loadModel(ManagedModelItem item) async {
    if (item.localPath == null || item.localPath!.isEmpty) {
      throw const ModelValidationException('Model file path is missing.');
    }

    _loadingModelIds.add(item.id);
    _modelErrors.remove(item.id);
    await refreshModels();
    notifyListeners();

    try {
      if (item.type == ModelType.llm) {
        final previousLoadedPath =
            aiService.llmEngine.isLoaded
                ? aiService.llmEngine.loadedModelPath
                : null;

        try {
          await aiService.loadLlmModel(item.localPath!);
        } catch (e) {
          // Attempt rollback to previously loaded LLM model
          if (previousLoadedPath != null &&
              previousLoadedPath != item.localPath) {
            try {
              await aiService.loadLlmModel(previousLoadedPath);
              _modelErrors[item.id] =
                  'Failed to load model "${item.displayName}": $e. Restored previous model.';
            } catch (rollbackErr) {
              _modelErrors[item.id] =
                  'Failed to load model "${item.displayName}": $e. Also failed to restore previous model: $rollbackErr.';
            }
          } else {
            _modelErrors[item.id] =
                'Failed to load model "${item.displayName}": $e';
          }
          rethrow;
        }
      } else {
        final previousLoadedPath =
            aiService.speechEngine.isLoaded
                ? aiService.speechEngine.loadedModelPath
                : null;

        try {
          await aiService.loadSpeechModel(item.localPath!);
        } catch (e) {
          // Attempt rollback to previously loaded Whisper model
          if (previousLoadedPath != null &&
              previousLoadedPath != item.localPath) {
            try {
              await aiService.loadSpeechModel(previousLoadedPath);
              _modelErrors[item.id] =
                  'Failed to load model "${item.displayName}": $e. Restored previous model.';
            } catch (rollbackErr) {
              _modelErrors[item.id] =
                  'Failed to load model "${item.displayName}": $e. Also failed to restore previous model: $rollbackErr.';
            }
          } else {
            _modelErrors[item.id] =
                'Failed to load model "${item.displayName}": $e';
          }
          rethrow;
        }
      }
    } finally {
      _loadingModelIds.remove(item.id);
      await refreshModels();
      notifyListeners();
    }
  }

  Future<void> unloadModel(ManagedModelItem item) async {
    if (item.type == ModelType.llm) {
      await aiService.unloadLlmModel();
    } else {
      await aiService.unloadSpeechModel();
    }
    await refreshModels();
    notifyListeners();
  }

  Future<void> deleteModel(ManagedModelItem item) async {
    // 1. If actively downloading, cancel download first
    if (downloader.isDownloading(item.id)) {
      cancelDownload(item.id);
    }

    // 2. If currently loaded, unload safely first
    if (item.isLoaded) {
      await unloadModel(item);
    }

    // 3. Delete file
    if (item.localPath != null && item.localPath!.isNotEmpty) {
      await storage.deleteModelFile(item.localPath!);
    }

    // 4. Forget persisted path in AiService if it was the selected model
    if (item.type == ModelType.llm) {
      if (aiService.configuredLlmPath == item.localPath) {
        await aiService.forgetLlmModel(deleteFile: false);
      }
    } else {
      if (aiService.configuredSpeechPath == item.localPath) {
        await aiService.forgetSpeechModel(deleteFile: false);
      }
    }

    _modelErrors.remove(item.id);
    _downloadProgress.remove(item.id);
    await refreshModels();
    notifyListeners();
  }

  Future<ManagedModelItem> importLocalModel(
    String sourcePath,
    ModelType type,
  ) async {
    final managedPath = await storage.importLocalFile(sourcePath, type);
    await refreshModels();

    final items = type == ModelType.llm ? _llmModels : _whisperModels;
    ManagedModelItem? importedItem;
    for (final item in items) {
      if (item.localPath != null &&
          p.canonicalize(item.localPath!) == p.canonicalize(managedPath)) {
        importedItem = item;
        break;
      }
    }

    importedItem ??= ManagedModelItem(
      id: 'imported_${managedPath.hashCode}',
      displayName: p.basename(managedPath),
      type: type,
      localPath: managedPath,
      fileSizeBytes: File(managedPath).existsSync()
          ? File(managedPath).lengthSync()
          : 0,
      isCustomImport: true,
      state: ModelDownloadState.downloaded,
    );

    // Automatically load newly imported model
    await loadModel(importedItem);
    await refreshModels();

    final updatedItems = type == ModelType.llm ? _llmModels : _whisperModels;
    for (final item in updatedItems) {
      if (item.localPath != null &&
          p.canonicalize(item.localPath!) == p.canonicalize(managedPath)) {
        return item;
      }
    }
    return importedItem.copyWith(state: ModelDownloadState.loaded);
  }

  @override
  void dispose() {
    _isDisposed = true;
    aiService.removeListener(_onAiServiceChanged);
    for (final id in _downloadProgress.keys.toList()) {
      try {
        storage.cancelDownload(id);
        downloader.cancel(id);
      } catch (_) {}
    }
    _downloadProgress.clear();
    _loadingModelIds.clear();
    super.dispose();
  }
}
