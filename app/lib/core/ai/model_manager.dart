import 'dart:async';
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
  final Map<String, Completer<void>> _activeDownloads = {};
  final Set<String> _cancelledDownloadIds = {};
  bool _isChoosingStorageFolder = false;

  List<ManagedModelItem> _llmModels = [];
  List<ManagedModelItem> _whisperModels = [];
  bool _isInitialized = false;
  int _refreshRevision = 0;
  String? _inventoryError;

  bool _isDisposed = false;

  List<ManagedModelItem> get llmModels => List.unmodifiable(_llmModels);
  List<ManagedModelItem> get whisperModels => List.unmodifiable(_whisperModels);
  bool get isInitialized => _isInitialized;
  bool get isStorageConfigured => storage.isConfigured;
  String? get storageLocationDisplay => storage.baseLocationDisplay;
  String? get inventoryError => _inventoryError;
  bool get hasActiveDownloads => _activeDownloads.isNotEmpty;
  bool isCancellingDownload(String modelId) =>
      _cancelledDownloadIds.contains(modelId);

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
    }
    await refreshModels();
    _isInitialized = true;
    notifyListeners();
  }

  Future<bool> chooseInitialStorageFolder() async {
    _beginStorageFolderChange();
    try {
      final success = await storage.chooseBaseFolder();
      if (success) {
        await storage.cleanStalePartFiles();
        await refreshModels();
        notifyListeners();
      }
      return success;
    } finally {
      _isChoosingStorageFolder = false;
    }
  }

  Future<bool> changeStorageFolder() async {
    _beginStorageFolderChange();
    try {
      final previousLlmPath = aiService.llmEngine.isLoaded
          ? aiService.llmEngine.loadedModelPath
          : null;
      final previousSpeechPath = aiService.speechEngine.isLoaded
          ? aiService.speechEngine.loadedModelPath
          : null;

      final success = await storage.chooseBaseFolder();
      if (!success) return false;

      final newLlmFiles = await storage.listModelFiles(ModelType.llm);
      final newWhisperFiles = await storage.listModelFiles(ModelType.whisper);

      // Safely unload active LLM model if not in new folder
      if (previousLlmPath != null) {
        final existsInNew = newLlmFiles.any(
          (f) => _sameLocation(f.location, previousLlmPath),
        );
        if (!existsInNew) {
          await aiService.unloadLlmModel();
        }
      }

      // Safely unload active Whisper model if not in new folder
      if (previousSpeechPath != null) {
        final existsInNew = newWhisperFiles.any(
          (f) => _sameLocation(f.location, previousSpeechPath),
        );
        if (!existsInNew) {
          await aiService.unloadSpeechModel();
        }
      }

      await storage.cleanStalePartFiles();
      await refreshModels();
      notifyListeners();
      return true;
    } finally {
      _isChoosingStorageFolder = false;
    }
  }

  void _beginStorageFolderChange() {
    if (hasActiveDownloads || _isChoosingStorageFolder) {
      throw const ModelValidationException(
        'Wait for downloads to finish or cancel them before changing the model folder.',
      );
    }
    _isChoosingStorageFolder = true;
  }

  Future<void> refreshModels() async {
    final revision = ++_refreshRevision;
    final errors = <String>[];

    final downloadedLlmEntries = await _readModelFiles(
      ModelType.llm,
      _llmModels,
      errors,
    );
    final downloadedWhisperEntries = await _readModelFiles(
      ModelType.whisper,
      _whisperModels,
      errors,
    );
    final managedLocations = {
      ...downloadedLlmEntries.map((entry) => entry.location),
      ...downloadedWhisperEntries.map((entry) => entry.location),
    };
    await _includeSelectedModels(ModelType.llm, downloadedLlmEntries);
    await _includeSelectedModels(ModelType.whisper, downloadedWhisperEntries);
    if (_isDisposed || revision != _refreshRevision) return;
    _inventoryError = errors.isEmpty ? null : errors.join('\n');

    // Build curated LLM items
    final llmItems = <ManagedModelItem>[];
    final knownLlmLocations = <String>{};

    for (final catalog
        in storage.isConfigured
            ? ModelCatalog.curatedLlmModels
            : <DownloadableModel>[]) {
      final matchingFile = downloadedLlmEntries
          .where((f) => f.name.toLowerCase() == catalog.filename.toLowerCase())
          .firstOrNull;

      final exists = matchingFile != null;
      final fileLoc = matchingFile?.location;
      final size = matchingFile?.sizeBytes ?? 0;

      if (exists && fileLoc != null) {
        knownLlmLocations.add(fileLoc);
      }

      final isDownloading =
          _activeDownloads.containsKey(catalog.id) ||
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
          description: fileLoc != null && !managedLocations.contains(fileLoc)
              ? '${catalog.description}\nSaved model outside the selected folder.'
              : catalog.description,
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
            errorMessage: _modelErrors[itemId],
            state: isCurrentlyLoaded
                ? ModelDownloadState.loaded
                : (isLoading
                      ? ModelDownloadState.loading
                      : ModelDownloadState.downloaded),
            description: managedLocations.contains(file.location)
                ? 'Custom model in storage folder'
                : 'Saved model outside the selected folder',
            memoryHint: 'Custom',
            speedHint: 'Custom',
          ),
        );
      }
    }

    // Build curated Whisper items
    final whisperItems = <ManagedModelItem>[];
    final knownWhisperLocations = <String>{};

    for (final catalog
        in storage.isConfigured
            ? ModelCatalog.curatedWhisperModels
            : <DownloadableModel>[]) {
      final matchingFile = downloadedWhisperEntries
          .where((f) => f.name.toLowerCase() == catalog.filename.toLowerCase())
          .firstOrNull;

      final exists = matchingFile != null;
      final fileLoc = matchingFile?.location;
      final size = matchingFile?.sizeBytes ?? 0;

      if (exists && fileLoc != null) {
        knownWhisperLocations.add(fileLoc);
      }

      final isDownloading =
          _activeDownloads.containsKey(catalog.id) ||
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
          description: fileLoc != null && !managedLocations.contains(fileLoc)
              ? '${catalog.description}\nSaved model outside the selected folder.'
              : catalog.description,
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
            errorMessage: _modelErrors[itemId],
            state: isCurrentlyLoaded
                ? ModelDownloadState.loaded
                : (isLoading
                      ? ModelDownloadState.loading
                      : ModelDownloadState.downloaded),
            description: managedLocations.contains(file.location)
                ? 'Custom model in storage folder'
                : 'Saved model outside the selected folder',
            memoryHint: 'Custom',
            speedHint: 'Custom',
          ),
        );
      }
    }

    _llmModels = llmItems;
    _whisperModels = whisperItems;
  }

  Future<List<ModelFileEntry>> _readModelFiles(
    ModelType type,
    List<ManagedModelItem> previous,
    List<String> errors,
  ) async {
    if (!storage.isConfigured) return [];
    try {
      final entries = await storage.listModelFiles(type);
      return entries.where((entry) => entry.sizeBytes > 0).toList();
    } catch (e) {
      errors.add('Could not refresh ${type.name} models: $e');
      // A provider error must not turn known downloaded models into GET rows.
      return previous.where((item) => item.localPath != null).map((item) {
        return ModelFileEntry(
          location: item.localPath!,
          name: item.catalogModel?.filename ?? item.displayName,
          sizeBytes: item.fileSizeBytes,
        );
      }).toList();
    }
  }

  Future<void> _includeSelectedModels(
    ModelType type,
    List<ModelFileEntry> entries,
  ) async {
    final loadedPath = type == ModelType.llm
        ? (aiService.llmEngine.isLoaded
              ? aiService.llmEngine.loadedModelPath
              : null)
        : (aiService.speechEngine.isLoaded
              ? aiService.speechEngine.loadedModelPath
              : null);
    final configuredPath = type == ModelType.llm
        ? aiService.configuredLlmPath
        : aiService.configuredSpeechPath;

    for (final location in {configuredPath, loadedPath}.nonNulls) {
      if (location.isEmpty ||
          entries.any((entry) => _sameLocation(entry.location, location))) {
        continue;
      }
      ModelFileEntry? entry;
      try {
        entry = await storage.getModelFileEntry(location);
      } catch (_) {
        // Loaded native model state remains authoritative if its provider
        // cannot supply metadata. Do not guess a catalog variant from its URI.
      }
      if (entry != null && entry.sizeBytes > 0) {
        entries.add(entry);
      } else if (location == loadedPath) {
        entries.add(
          ModelFileEntry(
            location: location,
            name: type == ModelType.llm
                ? 'Active language model'
                : 'Active speech model',
            sizeBytes: 0,
          ),
        );
      }
    }
    // If two copies share a filename, the catalog row should describe the
    // actual loaded copy; the other copy remains independently visible.
    entries.sort(
      (a, b) =>
          (b.location == loadedPath ? 1 : 0) -
          (a.location == loadedPath ? 1 : 0),
    );
  }

  bool _sameLocation(String a, String b) {
    if (a == b) return true;
    if (a.startsWith('content://') || b.startsWith('content://')) return false;
    return p.canonicalize(a) == p.canonicalize(b);
  }

  void _syncModelStates() {
    refreshModels().then((_) => notifyListeners());
  }

  Future<void> downloadModel(DownloadableModel catalogModel) async {
    if (!storage.isConfigured || _isChoosingStorageFolder) {
      throw const ModelValidationException(
        'Select a model storage folder before downloading.',
      );
    }
    final modelId = catalogModel.id;
    final existingDownload = _activeDownloads[modelId];
    if (existingDownload != null) {
      await existingDownload.future;
      return;
    }
    // Claim before the first async storage call. Rapid taps must not open two
    // writers on the same .part file or permit a concurrent folder change.
    final completion = Completer<void>();
    _activeDownloads[modelId] = completion;
    _modelErrors.remove(modelId);
    String? destinationPartLocation;
    _downloadProgress[modelId] = const ModelProgress(
      receivedBytes: 0,
      totalBytes: 0,
      progress: 0.0,
    );
    notifyListeners();

    try {
      destinationPartLocation = await storage.prepareDownloadPart(
        catalogModel.modelType,
        catalogModel.filename,
      );
      _activePartPaths.add(destinationPartLocation);
      if (_cancelledDownloadIds.contains(modelId)) {
        throw const ModelDownloadCancelledException();
      }
      await refreshModels();
      notifyListeners();
      if (_cancelledDownloadIds.contains(modelId)) {
        throw const ModelDownloadCancelledException();
      }
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

      if (_cancelledDownloadIds.contains(modelId)) {
        throw const ModelDownloadCancelledException();
      }
      await storage.finalizeDownload(
        destinationPartLocation,
        catalogModel.filename,
        catalogModel.modelType,
        expectedSizeBytes: catalogModel.expectedSizeBytes,
      );

      _modelErrors.remove(modelId);
    } catch (e) {
      if (e is ModelDownloadCancelledException) {
        if (destinationPartLocation != null) {
          await storage.deleteModel(destinationPartLocation);
        }
        _modelErrors.remove(modelId);
        return;
      }

      _modelErrors[modelId] = e.toString();
      rethrow;
    } finally {
      _activePartPaths.remove(destinationPartLocation);
      _downloadProgress.remove(modelId);
      _cancelledDownloadIds.remove(modelId);
      _activeDownloads.remove(modelId);
      completion.complete();
      await refreshModels();
      notifyListeners();
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
    if (!_activeDownloads.containsKey(modelId)) return;
    _cancelledDownloadIds.add(modelId);
    storage.cancelDownload(modelId);
    downloader.cancel(modelId);
    // Keep the busy row and folder guard until the writer has acknowledged
    // cancellation and the owning download has finished its cleanup.
    notifyListeners();
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
        final previousLoadedPath = aiService.llmEngine.isLoaded
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
        final previousLoadedPath = aiService.speechEngine.isLoaded
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
    final activeDownload = _activeDownloads[item.id];
    if (activeDownload != null) {
      cancelDownload(item.id);
      await activeDownload.future;
    }

    // 2. If currently loaded, unload safely first
    if (item.isLoaded) {
      await unloadModel(item);
    }

    // 3. Delete file
    if (item.localPath != null && item.localPath!.isNotEmpty) {
      final deleted = await storage.deleteModelFile(item.localPath!);
      if (!deleted) {
        throw const ModelValidationException(
          'The storage provider could not delete this model file. Check folder access and try again.',
        );
      }
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
