import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model_catalog.dart';
import 'model_storage_backend.dart';

export 'model_storage_backend.dart';

class ModelValidationException implements Exception {
  final String message;
  const ModelValidationException(this.message);

  @override
  String toString() => message;
}

class ModelStorage {
  final ModelStorageBackend backend;
  final Future<Directory> Function()? _customBaseDirProvider;

  ModelStorage({
    ModelStorageBackend? backend,
    Future<Directory> Function()? baseDirProvider,
  })  : _customBaseDirProvider = baseDirProvider,
        backend = backend ??
            (baseDirProvider != null
                ? FileSystemModelStorageBackend(
                    baseDirProvider: baseDirProvider,
                  )
                : (Platform.isAndroid
                    ? AndroidSafModelStorageBackend()
                    : FileSystemModelStorageBackend()));

  bool get isConfigured => backend.isConfigured;
  String? get baseLocationDisplay => backend.baseLocationDisplay;
  String? get baseLocationUriOrPath => backend.baseLocationUriOrPath;

  Future<bool> chooseBaseFolder() => backend.chooseBaseFolder();
  Future<bool> restorePersistedFolderAccess() => backend.restorePersistedFolderAccess();
  Future<void> clearConfiguredFolder() => backend.clearConfiguredFolder();

  Future<List<ModelFileEntry>> listModelFiles(ModelType type) => backend.listModelFiles(type);

  Future<String> prepareDownloadPart(ModelType type, String filename) =>
      backend.prepareDownloadPart(type, filename);

  Future<void> download({
    required DownloadableModel model,
    required String destinationPartLocation,
    required void Function(ModelProgress progress) onProgress,
  }) =>
      backend.download(
        model: model,
        destinationPartLocation: destinationPartLocation,
        onProgress: onProgress,
      );

  void cancelDownload(String modelId) => backend.cancelDownload(modelId);

  bool isDownloading(String modelId) => backend.isDownloading(modelId);

  Future<String> finalizeDownload(
    String partLocation,
    String filename,
    ModelType type, {
    int? expectedSizeBytes,
  }) =>
      backend.finalizeDownload(
        partLocation,
        filename,
        type,
        expectedSizeBytes: expectedSizeBytes,
      );

  Future<bool> deleteModel(String location) => backend.deleteModel(location);

  Future<bool> deleteModelFile(String path) => backend.deleteModel(path);

  Future<void> cleanStalePartFiles({
    Set<String> activePartPaths = const {},
  }) => backend.cleanStalePartFiles(activeLocations: activePartPaths);

  Future<bool> isModelFileDownloaded(ModelType type, String filename) =>
      backend.isModelFileDownloaded(type, filename);

  Future<String> getFinalModelLocation(ModelType type, String filename) =>
      backend.getFinalModelLocation(type, filename);

  Future<int> getFileSize(String location) => backend.getFileSize(location);
  Future<bool> fileExists(String location) => backend.fileExists(location);

  // Filesystem directory helpers for compatibility with file-based environments/tests
  Future<Directory> getBaseModelsDirectory() async {
    if (backend is FileSystemModelStorageBackend) {
      return (backend as FileSystemModelStorageBackend).getBaseDir();
    }
    if (_customBaseDirProvider != null) {
      final dir = await _customBaseDirProvider();
      return Directory(p.join(dir.path, 'models'));
    }
    try {
      final appSupport = await getApplicationSupportDirectory();
      return Directory(p.join(appSupport.path, 'models'));
    } catch (_) {
      final temp = Directory.systemTemp;
      return Directory(p.join(temp.path, 'jlexa_models'));
    }
  }

  Future<Directory> getModelTypeDirectory(ModelType type) async {
    if (backend is FileSystemModelStorageBackend) {
      final base = await (backend as FileSystemModelStorageBackend).getBaseDir();
      final subDirName = type == ModelType.llm ? 'llm' : 'whisper';
      final dir = Directory(p.join(base.path, subDirName));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    final baseDir = await getBaseModelsDirectory();
    final subDirName = type == ModelType.llm ? 'llm' : 'whisper';
    final dir = Directory(p.join(baseDir.path, subDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> getFinalModelPath(ModelType type, String filename) async {
    return backend.getFinalModelLocation(type, filename);
  }

  Future<String> getPartModelPath(ModelType type, String filename) async {
    return backend.prepareDownloadPart(type, filename);
  }

  Future<String> atomicFinalizeDownload(
    String partPath,
    String finalPath, {
    int? expectedSizeBytes,
  }) async {
    final partFile = File(partPath);
    if (!await partFile.exists()) {
      throw const ModelValidationException(
        'Download failed: partial file does not exist.',
      );
    }

    final size = await partFile.length();
    if (size == 0) {
      try {
        await partFile.delete();
      } catch (_) {}
      throw const ModelValidationException(
        'Download failed: downloaded file is empty (0 bytes).',
      );
    }

    if (expectedSizeBytes != null && expectedSizeBytes > 0) {
      if (size != expectedSizeBytes) {
        try {
          await partFile.delete();
        } catch (_) {}
        throw ModelValidationException(
          'Download validation failed: expected $expectedSizeBytes bytes, but got $size bytes.',
        );
      }
    }

    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      try {
        await finalFile.delete();
      } catch (_) {}
    }

    await partFile.rename(finalPath);
    return finalPath;
  }

  Future<void> validateModelFile(
    String path, {
    ModelType? type,
    int? expectedSizeBytes,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ModelValidationException('File does not exist: $path');
    }

    final size = await file.length();
    if (size == 0) {
      throw const ModelValidationException('Selected file is empty (0 bytes).');
    }

    final ext = p.extension(path).toLowerCase();
    if (type == ModelType.llm) {
      if (ext != '.gguf') {
        throw const ModelValidationException(
          'Invalid LLM model format. Only .gguf models are supported.',
        );
      }
    } else if (type == ModelType.whisper) {
      if (ext != '.bin' && ext != '.ggml' && ext != '.gguf') {
        throw const ModelValidationException(
          'Invalid Whisper model format. Only .bin, .ggml, or .gguf models are supported.',
        );
      }
    }
  }

  Future<String> importLocalFile(String sourcePath, ModelType type) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw ModelValidationException(
        'Source file does not exist: $sourcePath',
      );
    }

    await validateModelFile(sourcePath, type: type);

    final targetDir = await getModelTypeDirectory(type);
    final fileName = p.basename(sourcePath);
    final targetFile = File(p.join(targetDir.path, fileName));

    if (await targetFile.exists()) {
      final sourceLen = await sourceFile.length();
      final targetLen = await targetFile.length();
      if (sourceLen == targetLen) {
        return targetFile.path;
      }
      final nameWithoutExt = p.basenameWithoutExtension(fileName);
      final ext = p.extension(fileName);
      final uniqueName =
          '${nameWithoutExt}_${DateTime.now().millisecondsSinceEpoch}$ext';
      final uniqueTargetFile = File(p.join(targetDir.path, uniqueName));
      await sourceFile.copy(uniqueTargetFile.path);
      return uniqueTargetFile.path;
    }

    await sourceFile.copy(targetFile.path);
    return targetFile.path;
  }

  Future<List<File>> listDownloadedModels(ModelType type) async {
    final entries = await backend.listModelFiles(type);
    final list = <File>[];
    for (final entry in entries) {
      list.add(File(entry.location));
    }
    return list;
  }
}
