enum LlamaBackendPreference {
  auto,
  cpu,
  vulkan,
  opencl;

  String get label {
    switch (this) {
      case LlamaBackendPreference.auto:
        return 'Auto (Recommended)';
      case LlamaBackendPreference.cpu:
        return 'CPU';
      case LlamaBackendPreference.vulkan:
        return 'Vulkan';
      case LlamaBackendPreference.opencl:
        return 'OpenCL';
    }
  }

  String get description {
    switch (this) {
      case LlamaBackendPreference.auto:
        return 'Automatically selects the best compatible backend for this device.';
      case LlamaBackendPreference.cpu:
        return 'Universal CPU execution. Most compatible, safe fallback.';
      case LlamaBackendPreference.vulkan:
        return 'Hardware GPU acceleration via Vulkan.';
      case LlamaBackendPreference.opencl:
        return 'Hardware GPU acceleration via OpenCL.';
    }
  }

  static LlamaBackendPreference fromString(String? val) {
    if (val == null) return LlamaBackendPreference.auto;
    switch (val.toLowerCase().trim()) {
      case 'cpu':
        return LlamaBackendPreference.cpu;
      case 'vulkan':
        return LlamaBackendPreference.vulkan;
      case 'opencl':
        return LlamaBackendPreference.opencl;
      case 'auto':
      default:
        return LlamaBackendPreference.auto;
    }
  }
}

enum LlamaFlashAttention {
  auto,
  on,
  off;

  int get nativeValue {
    switch (this) {
      case LlamaFlashAttention.auto:
        return -1;
      case LlamaFlashAttention.on:
        return 1;
      case LlamaFlashAttention.off:
        return 0;
    }
  }

  static LlamaFlashAttention fromNativeValue(int? val) {
    if (val == 1) return LlamaFlashAttention.on;
    if (val == 0) return LlamaFlashAttention.off;
    return LlamaFlashAttention.auto;
  }

  static LlamaFlashAttention fromString(String? val) {
    if (val == null) return LlamaFlashAttention.auto;
    switch (val.toLowerCase().trim()) {
      case 'on':
      case 'true':
      case 'enabled':
        return LlamaFlashAttention.on;
      case 'off':
      case 'false':
      case 'disabled':
        return LlamaFlashAttention.off;
      case 'auto':
      default:
        return LlamaFlashAttention.auto;
    }
  }
}

class LlamaBackendInfo {
  final String backend;
  final bool compiled;
  final bool available;
  final String deviceName;
  final String? reasonUnavailable;

  const LlamaBackendInfo({
    required this.backend,
    required this.compiled,
    required this.available,
    this.deviceName = '',
    this.reasonUnavailable,
  });

  factory LlamaBackendInfo.fromMap(Map<dynamic, dynamic> map) {
    return LlamaBackendInfo(
      backend: map['backend']?.toString().toLowerCase() ?? 'unknown',
      compiled: map['compiled'] == true,
      available: map['available'] == true,
      deviceName: map['deviceName']?.toString() ?? '',
      reasonUnavailable: map['reasonUnavailable']?.toString().isNotEmpty == true
          ? map['reasonUnavailable'].toString()
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
    'backend': backend,
    'compiled': compiled,
    'available': available,
    'deviceName': deviceName,
    if (reasonUnavailable != null) 'reasonUnavailable': reasonUnavailable,
  };
}

class LlamaActiveBackendInfo {
  final String backend;
  final String deviceName;
  final int gpuLayers;
  final int contextLength;
  final int threads;
  final int batchSize;
  final int ubatchSize;
  final LlamaFlashAttention flashAttention;

  const LlamaActiveBackendInfo({
    this.backend = 'cpu',
    this.deviceName = 'CPU',
    this.gpuLayers = 0,
    this.contextLength = 2048,
    this.threads = 4,
    this.batchSize = 512,
    this.ubatchSize = 512,
    this.flashAttention = LlamaFlashAttention.auto,
  });

  factory LlamaActiveBackendInfo.fromMap(Map<dynamic, dynamic> map) {
    return LlamaActiveBackendInfo(
      backend: map['backend']?.toString() ?? 'cpu',
      deviceName: map['deviceName']?.toString() ?? 'CPU',
      gpuLayers: (map['gpuLayers'] as num?)?.toInt() ?? 0,
      contextLength: (map['contextLength'] as num?)?.toInt() ?? 2048,
      threads: (map['threads'] as num?)?.toInt() ?? 4,
      batchSize: (map['batchSize'] as num?)?.toInt() ?? 512,
      ubatchSize: (map['ubatchSize'] as num?)?.toInt() ?? 512,
      flashAttention: LlamaFlashAttention.fromNativeValue(
        (map['flashAttention'] as num?)?.toInt(),
      ),
    );
  }

  Map<String, dynamic> toMap() => {
    'backend': backend,
    'deviceName': deviceName,
    'gpuLayers': gpuLayers,
    'contextLength': contextLength,
    'threads': threads,
    'batchSize': batchSize,
    'ubatchSize': ubatchSize,
    'flashAttention': flashAttention.name,
  };
}

class LlamaRuntimeSettings {
  final LlamaBackendPreference backend;
  final int? threads; // null = auto
  final int? contextLength; // null = auto (default 2048)
  final int?
  gpuLayers; // null = auto (-1 when accelerated), 0 = none, >0 = custom
  final int? batchSize; // null = auto (512)
  final int? microBatchSize; // null = auto (512)
  final LlamaFlashAttention flashAttention; // default auto

  const LlamaRuntimeSettings({
    this.backend = LlamaBackendPreference.auto,
    this.threads,
    this.contextLength,
    this.gpuLayers,
    this.batchSize,
    this.microBatchSize,
    this.flashAttention = LlamaFlashAttention.auto,
  });

  int get resolvedThreads => (threads != null && threads! > 0) ? threads! : 4;
  int get resolvedContextLength =>
      (contextLength != null && contextLength! > 0) ? contextLength! : 2048;
  int get resolvedGpuLayers => gpuLayers ?? -1;
  int get resolvedBatchSize =>
      (batchSize != null && batchSize! > 0) ? batchSize! : 512;
  int get resolvedMicroBatchSize =>
      (microBatchSize != null && microBatchSize! > 0) ? microBatchSize! : 512;

  Map<String, dynamic> toMap() {
    return {
      'version': 1,
      'backend': backend.name,
      'threads': threads,
      'contextLength': contextLength,
      'gpuLayers': gpuLayers,
      'batchSize': batchSize,
      'microBatchSize': microBatchSize,
      'flashAttention': flashAttention.name,
    };
  }

  factory LlamaRuntimeSettings.fromMap(Map<String, dynamic> map) {
    return LlamaRuntimeSettings(
      backend: LlamaBackendPreference.fromString(map['backend']?.toString()),
      threads: (map['threads'] as num?)?.toInt(),
      contextLength: (map['contextLength'] as num?)?.toInt(),
      gpuLayers: (map['gpuLayers'] as num?)?.toInt(),
      batchSize: (map['batchSize'] as num?)?.toInt(),
      microBatchSize: (map['microBatchSize'] as num?)?.toInt(),
      flashAttention: LlamaFlashAttention.fromString(
        map['flashAttention']?.toString(),
      ),
    );
  }

  LlamaRuntimeSettings copyWith({
    LlamaBackendPreference? backend,
    Object? threads = _sentinel,
    Object? contextLength = _sentinel,
    Object? gpuLayers = _sentinel,
    Object? batchSize = _sentinel,
    Object? microBatchSize = _sentinel,
    LlamaFlashAttention? flashAttention,
  }) {
    return LlamaRuntimeSettings(
      backend: backend ?? this.backend,
      threads: identical(threads, _sentinel) ? this.threads : threads as int?,
      contextLength: identical(contextLength, _sentinel)
          ? this.contextLength
          : contextLength as int?,
      gpuLayers: identical(gpuLayers, _sentinel)
          ? this.gpuLayers
          : gpuLayers as int?,
      batchSize: identical(batchSize, _sentinel)
          ? this.batchSize
          : batchSize as int?,
      microBatchSize: identical(microBatchSize, _sentinel)
          ? this.microBatchSize
          : microBatchSize as int?,
      flashAttention: flashAttention ?? this.flashAttention,
    );
  }

  static const _sentinel = Object();

  static const LlamaRuntimeSettings defaultSettings = LlamaRuntimeSettings();
}
