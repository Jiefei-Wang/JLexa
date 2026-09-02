import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model_catalog.dart';

class ModelValidationException implements Exception {
  final String message;
  const ModelValidationException(this.message);

  @override
  String toString() => message;
}

class ModelStorage {
  final Future<Directory> Function()? _customBaseDirProvider;

  ModelStorage({Future<Directory> Function()? baseDirProvider})
    : _customBaseDirProvider = baseDirProvider;

  Future<Directory> getBaseModelsDirectory() async {
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
    final baseDir = await getBaseModelsDirectory();
    final subDirName = type == ModelType.llm ? 'llm' : 'whisper';
    final dir = Directory(p.join(baseDir.path, subDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> getFinalModelPath(ModelType type, String filename) async {
    final dir = await getModelTypeDirectory(type);
    final safeName = p.basename(filename);
    return p.join(dir.path, safeName);
  }

  Future<String> getPartModelPath(ModelType type, String filename) async {
    final dir = await getModelTypeDirectory(type);
    final safeName = p.basename(filename);
    return p.join(dir.path, '$safeName.part');
  }

  Future<void> cleanStalePartFiles({
    Set<String> activePartPaths = const {},
  }) async {
    final activeCanonical =
        activePartPaths.map((path) => p.canonicalize(path)).toSet();
    for (final type in ModelType.values) {
      try {
        final dir = await getModelTypeDirectory(type);
        if (await dir.exists()) {
          final entries = dir.listSync();
          for (final entry in entries) {
            if (entry is File && entry.path.endsWith('.part')) {
              if (activeCanonical.contains(p.canonicalize(entry.path))) {
                continue;
              }
              try {
                await entry.delete();
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
    }
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

    // If target file already exists and has the identical size, reuse it
    if (await targetFile.exists()) {
      final sourceLen = await sourceFile.length();
      final targetLen = await targetFile.length();
      if (sourceLen == targetLen) {
        return targetFile.path;
      }
      // If sizes differ, append unique suffix to avoid overwriting existing managed model
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

  Future<bool> deleteModelFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<List<File>> listDownloadedModels(ModelType type) async {
    final dir = await getModelTypeDirectory(type);
    if (!await dir.exists()) return [];

    final list = <File>[];
    final entries = dir.listSync();
    for (final entry in entries) {
      if (entry is File && !entry.path.endsWith('.part')) {
        final ext = p.extension(entry.path).toLowerCase();
        if (type == ModelType.llm && ext == '.gguf') {
          list.add(entry);
        } else if (type == ModelType.whisper &&
            (ext == '.bin' || ext == '.ggml' || ext == '.gguf')) {
          list.add(entry);
        }
      }
    }
    return list;
  }

  Future<bool> isModelFileDownloaded(ModelType type, String filename) async {
    final finalPath = await getFinalModelPath(type, filename);
    final file = File(finalPath);
    return (await file.exists()) && (await file.length() > 0);
  }
}
