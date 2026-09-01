import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class ModelPickerException implements Exception {
  final String message;
  const ModelPickerException(this.message);

  @override
  String toString() => message;
}

abstract class ModelFilePicker {
  Future<String?> pickLlmModel();
  Future<String?> pickSpeechModel();
}

class PlatformModelFilePicker implements ModelFilePicker {
  @override
  Future<String?> pickLlmModel() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );

      if (result == null || result.files.isEmpty) {
        return null; // User cancelled picker
      }

      final filePath = result.files.single.path;
      if (filePath == null || filePath.isEmpty) {
        return null;
      }

      final ext = p.extension(filePath).toLowerCase();
      if (ext != '.gguf') {
        final filename = p.basename(filePath);
        throw ModelPickerException(
          'Invalid file type "$filename". Local LLM requires a .gguf model file.',
        );
      }

      final file = File(filePath);
      if (!await file.exists()) {
        throw ModelPickerException('Selected file could not be accessed.');
      }

      return filePath;
    } on PlatformException catch (e) {
      throw ModelPickerException(
        'Unable to open file picker: ${e.message ?? e.code}',
      );
    } catch (e) {
      if (e is ModelPickerException) rethrow;
      throw ModelPickerException('File selection error: $e');
    }
  }

  @override
  Future<String?> pickSpeechModel() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );

      if (result == null || result.files.isEmpty) {
        return null;
      }

      final filePath = result.files.single.path;
      if (filePath == null || filePath.isEmpty) {
        return null;
      }

      final ext = p.extension(filePath).toLowerCase();
      if (ext != '.bin' && ext != '.ggml' && ext != '.gguf') {
        final filename = p.basename(filePath);
        throw ModelPickerException(
          'Invalid file type "$filename". Whisper speech recognition requires a .bin, .ggml, or .gguf model file.',
        );
      }

      final file = File(filePath);
      if (!await file.exists()) {
        throw ModelPickerException('Selected file could not be accessed.');
      }

      return filePath;
    } on PlatformException catch (e) {
      throw ModelPickerException(
        'Unable to open file picker: ${e.message ?? e.code}',
      );
    } catch (e) {
      if (e is ModelPickerException) rethrow;
      throw ModelPickerException('File selection error: $e');
    }
  }
}

class FakeModelFilePicker implements ModelFilePicker {
  String? nextLlmPath;
  String? nextSpeechPath;
  bool shouldThrow;
  String? errorMessage;

  FakeModelFilePicker({
    this.nextLlmPath,
    this.nextSpeechPath,
    this.shouldThrow = false,
    this.errorMessage,
  });

  @override
  Future<String?> pickLlmModel() async {
    if (shouldThrow) {
      throw ModelPickerException(errorMessage ?? 'Simulated picker error');
    }
    return nextLlmPath;
  }

  @override
  Future<String?> pickSpeechModel() async {
    if (shouldThrow) {
      throw ModelPickerException(errorMessage ?? 'Simulated picker error');
    }
    return nextSpeechPath;
  }
}
