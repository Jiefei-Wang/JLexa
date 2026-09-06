import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'model_catalog.dart';
import 'model_downloader.dart';
import 'model_storage.dart';

class ModelFileEntry {
  final String location; // content:// URI on SAF, filesystem path on desktop/tests
  final String name;
  final int sizeBytes;
  final DateTime? lastModified;

  const ModelFileEntry({
    required this.location,
    required this.name,
    required this.sizeBytes,
    this.lastModified,
  });

  @override
  String toString() => 'ModelFileEntry(name: $name, size: $sizeBytes, location: $location)';
}

abstract class ModelStorageBackend {
  bool get isConfigured;
  String? get baseLocationDisplay;
  String? get baseLocationUriOrPath;

  Future<bool> chooseBaseFolder();
  Future<bool> restorePersistedFolderAccess();
  Future<void> clearConfiguredFolder();

  Future<List<ModelFileEntry>> listModelFiles(ModelType type);
  Future<String> prepareDownloadPart(ModelType type, String filename);
  Future<void> download({
    required DownloadableModel model,
    required String destinationPartLocation,
    required void Function(ModelProgress progress) onProgress,
  });
  void cancelDownload(String modelId);
  bool isDownloading(String modelId);

  Future<String> finalizeDownload(
    String partLocation,
    String filename,
    ModelType type, {
    int? expectedSizeBytes,
  });

  Future<bool> deleteModel(String location);
  Future<void> cleanStalePartFiles({Set<String> activeLocations = const {}});
  Future<bool> isModelFileDownloaded(ModelType type, String filename);
  Future<String> getFinalModelLocation(ModelType type, String filename);
  Future<int> getFileSize(String location);
  Future<bool> fileExists(String location);
}

/// Standard filesystem backend for Desktop (Windows, macOS, Linux), unit tests, and CI.
class FileSystemModelStorageBackend implements ModelStorageBackend {
  Directory? _baseDir;
  bool _isConfigured;
  final Future<Directory?> Function()? _folderPicker;
  final Future<Directory> Function()? _baseDirProvider;
  final ModelDownloader _downloader;

  FileSystemModelStorageBackend({
    Directory? baseDir,
    bool isConfigured = false,
    Future<Directory?> Function()? folderPicker,
    Future<Directory> Function()? baseDirProvider,
    ModelDownloader? downloader,
  })  : _baseDir = baseDir,
        _isConfigured = isConfigured || baseDir != null || baseDirProvider != null,
        // ignore: prefer_initializing_formals
        _folderPicker = folderPicker,
        _baseDirProvider = baseDirProvider,
        _downloader = downloader ?? DioModelDownloader() {
    if (_baseDir != null && _isConfigured) {
      _ensureSubdirectoriesSync(_baseDir!);
    }
  }

  static void _ensureSubdirectoriesSync(Directory base) {
    final llmDir = Directory(p.join(base.path, 'llm'));
    if (!llmDir.existsSync()) llmDir.createSync(recursive: true);
    final whisperDir = Directory(p.join(base.path, 'whisper'));
    if (!whisperDir.existsSync()) whisperDir.createSync(recursive: true);
  }

  @override
  bool get isConfigured => (_isConfigured && _baseDir != null) || _baseDirProvider != null;

  @override
  String? get baseLocationDisplay => _baseDir?.path;

  @override
  String? get baseLocationUriOrPath => _baseDir?.path;

  Future<Directory> getBaseDir() async {
    if (_baseDir != null) return _baseDir!;
    if (_baseDirProvider != null) {
      final dir = await _baseDirProvider();
      _baseDir = dir;
      _ensureSubdirectoriesSync(dir);
      return dir;
    }
    throw const ModelValidationException('Storage base directory has not been configured.');
  }

  Directory get baseDir {
    if (_baseDir == null) {
      throw const ModelValidationException('Storage base directory has not been configured.');
    }
    return _baseDir!;
  }

  void configureWithDirectory(Directory dir) {
    _baseDir = dir;
    _isConfigured = true;
    _ensureSubdirectoriesSync(dir);
  }

  @override
  Future<bool> chooseBaseFolder() async {
    if (_folderPicker != null) {
      final picked = await _folderPicker();
      if (picked != null) {
        configureWithDirectory(picked);
        return true;
      }
      return false;
    }
    // Default fallback if no custom picker injected: use system temp directory for tests
    final defaultDir = Directory(p.join(Directory.systemTemp.path, 'jlexa_models'));
    configureWithDirectory(defaultDir);
    return true;
  }

  @override
  Future<bool> restorePersistedFolderAccess() async {
    if (_baseDirProvider != null) {
      final dir = await _baseDirProvider();
      _baseDir = dir;
      _ensureSubdirectoriesSync(dir);
      _isConfigured = true;
      return true;
    }
    if (_baseDir != null && await _baseDir!.exists()) {
      _ensureSubdirectoriesSync(_baseDir!);
      _isConfigured = true;
      return true;
    }
    return isConfigured;
  }

  @override
  Future<void> clearConfiguredFolder() async {
    _baseDir = null;
    _isConfigured = false;
  }

  Future<Directory> _getTypeDir(ModelType type) async {
    final base = await getBaseDir();
    final subName = type == ModelType.llm ? 'llm' : 'whisper';
    final dir = Directory(p.join(base.path, subName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  @override
  Future<List<ModelFileEntry>> listModelFiles(ModelType type) async {
    if (!isConfigured) return [];
    final dir = await _getTypeDir(type);
    if (!await dir.exists()) return [];

    final list = <ModelFileEntry>[];
    final entries = dir.listSync();
    for (final entry in entries) {
      if (entry is File && !entry.path.endsWith('.part')) {
        final ext = p.extension(entry.path).toLowerCase();
        final name = p.basename(entry.path);
        if (type == ModelType.llm && ext == '.gguf') {
          list.add(
            ModelFileEntry(
              location: entry.path,
              name: name,
              sizeBytes: entry.lengthSync(),
              lastModified: entry.lastModifiedSync(),
            ),
          );
        } else if (type == ModelType.whisper &&
            (ext == '.bin' || ext == '.ggml' || ext == '.gguf')) {
          list.add(
            ModelFileEntry(
              location: entry.path,
              name: name,
              sizeBytes: entry.lengthSync(),
              lastModified: entry.lastModifiedSync(),
            ),
          );
        }
      }
    }
    return list;
  }

  @override
  Future<String> prepareDownloadPart(ModelType type, String filename) async {
    final dir = await _getTypeDir(type);
    final safeName = p.basename(filename);
    final partFile = File(p.join(dir.path, '$safeName.part'));
    if (await partFile.exists()) {
      try {
        await partFile.delete();
      } catch (_) {}
    }
    return partFile.path;
  }

  @override
  Future<void> download({
    required DownloadableModel model,
    required String destinationPartLocation,
    required void Function(ModelProgress progress) onProgress,
  }) {
    return _downloader.download(
      model: model,
      destinationPartPath: destinationPartLocation,
      onProgress: onProgress,
    );
  }

  @override
  void cancelDownload(String modelId) {
    _downloader.cancel(modelId);
  }

  @override
  bool isDownloading(String modelId) {
    return _downloader.isDownloading(modelId);
  }

  @override
  Future<String> finalizeDownload(
    String partLocation,
    String filename,
    ModelType type, {
    int? expectedSizeBytes,
  }) async {
    final partFile = File(partLocation);
    if (!await partFile.exists()) {
      throw const ModelValidationException('Download failed: partial file does not exist.');
    }

    final size = await partFile.length();
    if (size == 0) {
      try {
        await partFile.delete();
      } catch (_) {}
      throw const ModelValidationException('Download failed: downloaded file is empty (0 bytes).');
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

    final targetDir = await _getTypeDir(type);
    final finalPath = p.join(targetDir.path, p.basename(filename));
    final finalFile = File(finalPath);
    if (await finalFile.exists()) {
      try {
        await finalFile.delete();
      } catch (_) {}
    }

    await partFile.rename(finalPath);
    return finalPath;
  }

  @override
  Future<bool> deleteModel(String location) async {
    try {
      final f = File(location);
      if (await f.exists()) {
        await f.delete();
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<void> cleanStalePartFiles({Set<String> activeLocations = const {}}) async {
    if (!isConfigured) return;
    final activeCanonical = activeLocations.map((l) => p.canonicalize(l)).toSet();
    for (final type in ModelType.values) {
      try {
        final dir = await _getTypeDir(type);
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

  @override
  Future<bool> isModelFileDownloaded(ModelType type, String filename) async {
    if (!isConfigured) return false;
    final dir = await _getTypeDir(type);
    final file = File(p.join(dir.path, p.basename(filename)));
    return (await file.exists()) && (await file.length() > 0);
  }

  @override
  Future<String> getFinalModelLocation(ModelType type, String filename) async {
    final dir = await _getTypeDir(type);
    return p.join(dir.path, p.basename(filename));
  }

  @override
  Future<int> getFileSize(String location) async {
    try {
      final f = File(location);
      if (await f.exists()) return await f.length();
    } catch (_) {}
    return 0;
  }

  @override
  Future<bool> fileExists(String location) async {
    try {
      final f = File(location);
      return await f.exists();
    } catch (_) {}
    return false;
  }
}

/// Android Storage Access Framework (SAF) backend.
/// Communicates through `com.jlexa.app/saf_storage` platform channel.
class AndroidSafModelStorageBackend implements ModelStorageBackend {
  static const MethodChannel _channel = MethodChannel('com.jlexa.app/saf_storage');
  static const EventChannel _downloadEventChannel = EventChannel('com.jlexa.app/saf_download_stream');

  bool _isConfigured = false;
  String? _treeUri;
  String? _displayName;

  final Map<String, StreamSubscription> _downloadSubs = {};
  final Set<String> _activeDownloadIds = {};

  AndroidSafModelStorageBackend() {
    _initDownloadStream();
  }

  void _initDownloadStream() {
    if (!Platform.isAndroid) return;
  }

  @override
  bool get isConfigured => _isConfigured && _treeUri != null;

  @override
  String? get baseLocationDisplay => _displayName ?? _treeUri;

  @override
  String? get baseLocationUriOrPath => _treeUri;

  @override
  Future<bool> chooseBaseFolder() async {
    if (!Platform.isAndroid) return false;
    try {
      final Map? res = await _channel.invokeMapMethod('chooseBaseFolder');
      if (res != null && res['treeUri'] != null) {
        _treeUri = res['treeUri'] as String;
        _displayName = res['displayName'] as String? ?? 'Models';
        _isConfigured = true;
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<bool> restorePersistedFolderAccess() async {
    if (!Platform.isAndroid) return false;
    try {
      final Map? res = await _channel.invokeMapMethod('restorePersistedFolderAccess');
      if (res != null && res['treeUri'] != null) {
        _treeUri = res['treeUri'] as String;
        _displayName = res['displayName'] as String? ?? 'Models';
        _isConfigured = true;
        return true;
      }
    } catch (_) {}
    _treeUri = null;
    _displayName = null;
    _isConfigured = false;
    return false;
  }

  @override
  Future<void> clearConfiguredFolder() async {
    _treeUri = null;
    _displayName = null;
    _isConfigured = false;
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('clearPersistedFolderAccess');
      } catch (_) {}
    }
  }

  @override
  Future<List<ModelFileEntry>> listModelFiles(ModelType type) async {
    if (!isConfigured || !Platform.isAndroid) return [];
    try {
      final List? list = await _channel.invokeListMethod(
        'listModelFiles',
        {'type': type.name},
      );
      if (list == null) return [];
      return list.map((item) {
        final map = item as Map;
        return ModelFileEntry(
          location: map['uri'] as String,
          name: map['name'] as String,
          sizeBytes: (map['size'] as num?)?.toInt() ?? 0,
          lastModified: map['lastModified'] != null
              ? DateTime.fromMillisecondsSinceEpoch((map['lastModified'] as num).toInt())
              : null,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<String> prepareDownloadPart(ModelType type, String filename) async {
    if (!isConfigured || !Platform.isAndroid) {
      throw const ModelValidationException('Storage not configured.');
    }
    final Map? res = await _channel.invokeMapMethod(
      'prepareDownloadPart',
      {'type': type.name, 'filename': filename},
    );
    if (res != null && res['partUri'] != null) {
      return res['partUri'] as String;
    }
    throw const ModelValidationException('Failed to create partial download file in SAF storage.');
  }

  @override
  Future<void> download({
    required DownloadableModel model,
    required String destinationPartLocation,
    required void Function(ModelProgress progress) onProgress,
  }) async {
    if (!isConfigured || !Platform.isAndroid) {
      throw const ModelValidationException('Storage not configured.');
    }

    final completer = Completer<void>();
    _activeDownloadIds.add(model.id);

    StreamSubscription? sub;
    sub = _downloadEventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map && event['requestId'] == model.id) {
          final type = event['type'] as String?;
          if (type == 'progress') {
            final received = (event['bytesReceived'] as num).toInt();
            final total = (event['totalBytes'] as num?)?.toInt() ?? model.expectedSizeBytes;
            final pct = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
            onProgress(
              ModelProgress(
                receivedBytes: received,
                totalBytes: total,
                progress: pct,
              ),
            );
          } else if (type == 'done') {
            if (!completer.isCompleted) completer.complete();
          } else if (type == 'cancelled') {
            if (!completer.isCompleted) {
              completer.completeError(const ModelDownloadCancelledException());
            }
          } else if (type == 'error') {
            if (!completer.isCompleted) {
              final msg = event['message'] as String? ?? 'SAF download error';
              completer.completeError(ModelDownloadException(msg));
            }
          }
        }
      },
      onError: (err) {
        if (!completer.isCompleted) {
          completer.completeError(ModelDownloadException(err.toString()));
        }
      },
    );
    _downloadSubs[model.id] = sub;

    try {
      await _channel.invokeMethod('downloadFile', {
        'url': model.downloadUrl,
        'targetUri': destinationPartLocation,
        'requestId': model.id,
        'expectedSizeBytes': model.expectedSizeBytes,
      });
      await completer.future;
    } finally {
      _activeDownloadIds.remove(model.id);
      await sub.cancel();
      _downloadSubs.remove(model.id);
    }
  }

  @override
  void cancelDownload(String modelId) {
    if (!Platform.isAndroid) return;
    try {
      _channel.invokeMethod('cancelDownload', {'requestId': modelId});
    } catch (_) {}
    final sub = _downloadSubs.remove(modelId);
    sub?.cancel();
    _activeDownloadIds.remove(modelId);
  }

  @override
  bool isDownloading(String modelId) => _activeDownloadIds.contains(modelId);

  @override
  Future<String> finalizeDownload(
    String partLocation,
    String filename,
    ModelType type, {
    int? expectedSizeBytes,
  }) async {
    if (!isConfigured || !Platform.isAndroid) {
      throw const ModelValidationException('Storage not configured.');
    }
    final Map? res = await _channel.invokeMapMethod('finalizeDownload', {
      'partUri': partLocation,
      'filename': filename,
      'type': type.name,
      'expectedSizeBytes': expectedSizeBytes ?? 0,
    });
    if (res != null && res['finalUri'] != null) {
      return res['finalUri'] as String;
    }
    throw const ModelValidationException('Failed to finalize download in SAF storage.');
  }

  @override
  Future<bool> deleteModel(String location) async {
    if (!isConfigured || !Platform.isAndroid) return false;
    try {
      final bool? res = await _channel.invokeMethod('deleteModelFile', {'uri': location});
      return res == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> cleanStalePartFiles({Set<String> activeLocations = const {}}) async {
    if (!isConfigured || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('cleanStalePartFiles', {
        'activeUris': activeLocations.toList(),
      });
    } catch (_) {}
  }

  @override
  Future<bool> isModelFileDownloaded(ModelType type, String filename) async {
    final files = await listModelFiles(type);
    final target = filename.toLowerCase();
    for (final f in files) {
      if (f.name.toLowerCase() == target && f.sizeBytes > 0) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<String> getFinalModelLocation(ModelType type, String filename) async {
    final files = await listModelFiles(type);
    final target = filename.toLowerCase();
    for (final f in files) {
      if (f.name.toLowerCase() == target) {
        return f.location;
      }
    }
    return '';
  }

  @override
  Future<int> getFileSize(String location) async {
    if (!Platform.isAndroid) return 0;
    try {
      final int? size = await _channel.invokeMethod('getFileSize', {'uri': location});
      return size ?? 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<bool> fileExists(String location) async {
    if (!Platform.isAndroid) return false;
    try {
      final bool? exists = await _channel.invokeMethod('fileExists', {'uri': location});
      return exists == true;
    } catch (_) {
      return false;
    }
  }
}
