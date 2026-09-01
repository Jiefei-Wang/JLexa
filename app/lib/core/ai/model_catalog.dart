import 'dart:math';

enum ModelType {
  llm,
  whisper,
}

enum ModelDownloadState {
  notDownloaded,
  downloading,
  downloaded,
  loading,
  loaded,
  error,
}

class ModelProgress {
  final int receivedBytes;
  final int totalBytes;
  final double progress; // 0.0 to 1.0

  const ModelProgress({
    required this.receivedBytes,
    required this.totalBytes,
    required this.progress,
  });

  String get formattedReceived => ModelCatalog.formatBytes(receivedBytes);
  String get formattedTotal =>
      totalBytes > 0 ? ModelCatalog.formatBytes(totalBytes) : 'Unknown';
  String get percentageString => '${(progress * 100).toStringAsFixed(0)}%';

  @override
  String toString() => '$formattedReceived / $formattedTotal ($percentageString)';
}

class DownloadableModel {
  final String id;
  final String displayName;
  final ModelType modelType;
  final String repository;
  final String filename;
  final String downloadUrl;
  final int expectedSizeBytes;
  final String? sha256;
  final String description;
  final String parameterCount;
  final String quantization;
  final bool isRecommended;
  final String memoryHint;
  final String speedHint;
  final String languageHint;

  const DownloadableModel({
    required this.id,
    required this.displayName,
    required this.modelType,
    required this.repository,
    required this.filename,
    required this.downloadUrl,
    required this.expectedSizeBytes,
    this.sha256,
    required this.description,
    required this.parameterCount,
    required this.quantization,
    this.isRecommended = false,
    required this.memoryHint,
    required this.speedHint,
    this.languageHint = 'English',
  });

  String get formattedSize => ModelCatalog.formatBytes(expectedSizeBytes);

  Map<String, dynamic> toMap() => {
    'id': id,
    'displayName': displayName,
    'modelType': modelType.name,
    'repository': repository,
    'filename': filename,
    'downloadUrl': downloadUrl,
    'expectedSizeBytes': expectedSizeBytes,
    'sha256': sha256,
    'description': description,
    'parameterCount': parameterCount,
    'quantization': quantization,
    'isRecommended': isRecommended,
    'memoryHint': memoryHint,
    'speedHint': speedHint,
    'languageHint': languageHint,
  };
}

class ModelCatalog {
  static const List<DownloadableModel> curatedLlmModels = [
    DownloadableModel(
      id: 'qwen2.5-0.5b-instruct',
      displayName: 'Qwen2.5 0.5B Instruct',
      modelType: ModelType.llm,
      repository: 'Qwen/Qwen2.5-0.5B-Instruct-GGUF',
      filename: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
      downloadUrl:
          'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf',
      expectedSizeBytes: 491400032,
      description:
          'Ultra-fast and minimal RAM footprint. Great for quick sentence lookups on budget phones.',
      parameterCount: '0.5B',
      quantization: 'Q4_K_M',
      isRecommended: false,
      memoryHint: '~600 MB RAM',
      speedHint: 'Fastest',
      languageHint: 'English & Chinese',
    ),
    DownloadableModel(
      id: 'qwen2.5-1.5b-instruct',
      displayName: 'Qwen2.5 1.5B Instruct',
      modelType: ModelType.llm,
      repository: 'Qwen/Qwen2.5-1.5B-Instruct-GGUF',
      filename: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
      downloadUrl:
          'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf',
      expectedSizeBytes: 1117320736,
      description:
          'Optimal balance of accuracy, grammar insights, and speed. Highly recommended for daily practice.',
      parameterCount: '1.5B',
      quantization: 'Q4_K_M',
      isRecommended: true,
      memoryHint: '~1.4 GB RAM',
      speedHint: 'Balanced',
      languageHint: 'English & Chinese',
    ),
    DownloadableModel(
      id: 'qwen2.5-3b-instruct',
      displayName: 'Qwen2.5 3B Instruct',
      modelType: ModelType.llm,
      repository: 'Qwen/Qwen2.5-3B-Instruct-GGUF',
      filename: 'qwen2.5-3b-instruct-q4_k_m.gguf',
      downloadUrl:
          'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf',
      expectedSizeBytes: 2104932768,
      description:
          'Highest quality explanations and nuanced reasoning. Recommended for devices with 6GB+ RAM.',
      parameterCount: '3B',
      quantization: 'Q4_K_M',
      isRecommended: false,
      memoryHint: '~2.5 GB RAM',
      speedHint: 'Moderate',
      languageHint: 'English & Chinese',
    ),
    DownloadableModel(
      id: 'smollm2-360m-instruct',
      displayName: 'SmolLM2 360M Instruct',
      modelType: ModelType.llm,
      repository: 'HuggingFaceTB/SmolLM2-360M-Instruct-GGUF',
      filename: 'smollm2-360m-instruct-q8_0.gguf',
      downloadUrl:
          'https://huggingface.co/HuggingFaceTB/SmolLM2-360M-Instruct-GGUF/resolve/main/smollm2-360m-instruct-q8_0.gguf',
      expectedSizeBytes: 386404992,
      description:
          'Compact model optimized for low-end mobile hardware with fast response times.',
      parameterCount: '360M',
      quantization: 'Q8_0',
      isRecommended: false,
      memoryHint: '~450 MB RAM',
      speedHint: 'Ultra Fast',
      languageHint: 'English',
    ),
  ];

  static const List<DownloadableModel> curatedWhisperModels = [
    DownloadableModel(
      id: 'whisper-tiny-en',
      displayName: 'Whisper Tiny (English)',
      modelType: ModelType.whisper,
      repository: 'ggerganov/whisper.cpp',
      filename: 'ggml-tiny.en.bin',
      downloadUrl:
          'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin',
      expectedSizeBytes: 77704715,
      description:
          'Fastest speech transcription with minimal battery and memory consumption.',
      parameterCount: '39M',
      quantization: 'F16',
      isRecommended: false,
      memoryHint: '~150 MB RAM',
      speedHint: 'Fastest',
      languageHint: 'English Only',
    ),
    DownloadableModel(
      id: 'whisper-base-en',
      displayName: 'Whisper Base (English)',
      modelType: ModelType.whisper,
      repository: 'ggerganov/whisper.cpp',
      filename: 'ggml-base.en.bin',
      downloadUrl:
          'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin',
      expectedSizeBytes: 147964211,
      description:
          'Recommended speech model for high accuracy and fast transcription on Android.',
      parameterCount: '74M',
      quantization: 'F16',
      isRecommended: true,
      memoryHint: '~250 MB RAM',
      speedHint: 'Fast',
      languageHint: 'English Only',
    ),
    DownloadableModel(
      id: 'whisper-small-en',
      displayName: 'Whisper Small (English)',
      modelType: ModelType.whisper,
      repository: 'ggerganov/whisper.cpp',
      filename: 'ggml-small.en.bin',
      downloadUrl:
          'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin',
      expectedSizeBytes: 487614201,
      description:
          'Best transcription accuracy for challenging accents, background noise, and fast speech.',
      parameterCount: '244M',
      quantization: 'F16',
      isRecommended: false,
      memoryHint: '~600 MB RAM',
      speedHint: 'Moderate',
      languageHint: 'English Only',
    ),
  ];

  static List<DownloadableModel> get allCuratedModels => [
    ...curatedLlmModels,
    ...curatedWhisperModels,
  ];

  static DownloadableModel? findById(String id) {
    for (final model in allCuratedModels) {
      if (model.id == id) return model;
    }
    return null;
  }

  static DownloadableModel? findCuratedByFilename(String filename) {
    for (final model in allCuratedModels) {
      if (model.filename.toLowerCase() == filename.toLowerCase()) {
        return model;
      }
    }
    return null;
  }

  static DownloadableModel? findCuratedByPath(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    return findCuratedByFilename(name);
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    final i = (log(bytes) / log(1024)).floor().clamp(0, suffixes.length - 1);
    final value = bytes / pow(1024, i);
    if (i == 0) return '$bytes B';
    if (value == value.roundToDouble()) return '${value.toInt()} ${suffixes[i]}';
    return '${value.toStringAsFixed(value >= 100 ? 0 : (value >= 10 ? 1 : 2))} ${suffixes[i]}';
  }
}
