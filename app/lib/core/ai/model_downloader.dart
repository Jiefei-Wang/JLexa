import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'model_catalog.dart';

class ModelDownloadException implements Exception {
  final String message;
  final int? statusCode;
  const ModelDownloadException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

abstract class ModelDownloader {
  Future<void> download({
    required DownloadableModel model,
    required String destinationPartPath,
    required void Function(ModelProgress progress) onProgress,
  });

  void cancel(String modelId);

  bool isDownloading(String modelId);
}

class DioModelDownloader implements ModelDownloader {
  final Dio _dio;
  final Map<String, CancelToken> _activeTokens = {};

  DioModelDownloader({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 30),
              followRedirects: true,
              maxRedirects: 5,
            ),
          );

  @override
  bool isDownloading(String modelId) => _activeTokens.containsKey(modelId);

  @override
  void cancel(String modelId) {
    final token = _activeTokens.remove(modelId);
    if (token != null && !token.isCancelled) {
      token.cancel('User cancelled download');
    }
  }

  @override
  Future<void> download({
    required DownloadableModel model,
    required String destinationPartPath,
    required void Function(ModelProgress progress) onProgress,
  }) async {
    final cancelToken = CancelToken();
    _activeTokens[model.id] = cancelToken;

    final partFile = File(destinationPartPath);
    if (await partFile.exists()) {
      try {
        await partFile.delete();
      } catch (_) {}
    }

    try {
      await _dio.download(
        model.downloadUrl,
        destinationPartPath,
        cancelToken: cancelToken,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          final totalBytes = total > 0 ? total : model.expectedSizeBytes;
          final pct = totalBytes > 0 ? (received / totalBytes).clamp(0.0, 1.0) : 0.0;
          onProgress(
            ModelProgress(
              receivedBytes: received,
              totalBytes: totalBytes,
              progress: pct,
            ),
          );
        },
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        throw const ModelDownloadException('Download was cancelled.');
      }

      final status = e.response?.statusCode;
      if (status == 404) {
        throw ModelDownloadException(
          'Model file was not found on Hugging Face (HTTP 404).',
          statusCode: 404,
        );
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw const ModelDownloadException(
          'Connection timed out while downloading model. Check your internet connection.',
        );
      } else if (e.type == DioExceptionType.connectionError) {
        throw const ModelDownloadException(
          'Could not connect to Hugging Face. Check your internet connection.',
        );
      }

      throw ModelDownloadException(
        'Download failed: ${e.message ?? e.toString()}',
        statusCode: status,
      );
    } catch (e) {
      if (e is ModelDownloadException) rethrow;
      throw ModelDownloadException('Download failed: $e');
    } finally {
      _activeTokens.remove(model.id);
    }
  }
}

class FakeModelDownloader implements ModelDownloader {
  final Map<String, bool> _activeDownloads = {};
  final Duration stepDelay;
  final bool shouldFail;
  final String? failureMessage;

  FakeModelDownloader({
    this.stepDelay = const Duration(milliseconds: 50),
    this.shouldFail = false,
    this.failureMessage,
  });

  @override
  bool isDownloading(String modelId) => _activeDownloads[modelId] == true;

  @override
  void cancel(String modelId) {
    _activeDownloads[modelId] = false;
  }

  @override
  Future<void> download({
    required DownloadableModel model,
    required String destinationPartPath,
    required void Function(ModelProgress progress) onProgress,
  }) async {
    _activeDownloads[model.id] = true;

    if (shouldFail) {
      _activeDownloads.remove(model.id);
      throw ModelDownloadException(
        failureMessage ?? 'Simulated download failure',
      );
    }

    final totalBytes = model.expectedSizeBytes > 0 ? model.expectedSizeBytes : 1024 * 1024;
    const steps = 5;

    for (int i = 1; i <= steps; i++) {
      if (_activeDownloads[model.id] != true) {
        _activeDownloads.remove(model.id);
        throw const ModelDownloadException('Download was cancelled.');
      }

      if (stepDelay.inMilliseconds > 0) {
        await Future.delayed(stepDelay);
      }

      if (_activeDownloads[model.id] != true) {
        _activeDownloads.remove(model.id);
        throw const ModelDownloadException('Download was cancelled.');
      }

      final progress = i / steps;
      final received = (totalBytes * progress).round();
      onProgress(
        ModelProgress(
          receivedBytes: received,
          totalBytes: totalBytes,
          progress: progress,
        ),
      );
    }

    // Write a mock binary content to destinationPartPath
    final partFile = File(destinationPartPath);
    if (!await partFile.parent.exists()) {
      await partFile.parent.create(recursive: true);
    }

    // Write a compact fake file for tests
    final bytes = List<int>.filled(1024, 0x42);
    await partFile.writeAsBytes(bytes);

    _activeDownloads.remove(model.id);
  }
}
