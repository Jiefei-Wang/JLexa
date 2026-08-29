enum AiModelState {
  noModel,
  loading,
  ready,
  generating,
  error,
}

abstract class AiException implements Exception {
  final String message;
  const AiException(this.message);

  @override
  String toString() => message;
}

class AiBusyException extends AiException {
  const AiBusyException([super.message = 'Another generation is already in progress. Please wait.']);
}

class AiModelNotLoadedException extends AiException {
  const AiModelNotLoadedException([super.message = 'No AI model loaded. Please load a model in Settings.']);
}

class AiGenerationException extends AiException {
  const AiGenerationException(super.message);
}

class AiCancelledException extends AiException {
  const AiCancelledException([super.message = 'AI generation was cancelled.']);
}

class AiUnsupportedPlatformException extends AiException {
  const AiUnsupportedPlatformException([super.message = 'Local AI inference is not supported on this platform.']);
}

enum AiRequestPriority {
  background,
  user,
}

class AiGenerationHandle {
  final String requestId;
  final Stream<String> stream;
  final Future<void> Function() onCancel;

  const AiGenerationHandle({
    required this.requestId,
    required this.stream,
    required this.onCancel,
  });

  Future<void> cancel() => onCancel();
}

class AiGenerationSettings {
  final double temperature;
  final int maxTokens;
  final double topP;
  final int contextLength;
  final int threads;

  const AiGenerationSettings({
    this.temperature = 0.7,
    this.maxTokens = 512,
    this.topP = 0.9,
    this.contextLength = 2048,
    this.threads = 4,
  });

  AiGenerationSettings copyWith({
    double? temperature,
    int? maxTokens,
    double? topP,
    int? contextLength,
    int? threads,
  }) {
    return AiGenerationSettings(
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      topP: topP ?? this.topP,
      contextLength: contextLength ?? this.contextLength,
      threads: threads ?? this.threads,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'temperature': temperature,
      'maxTokens': maxTokens,
      'topP': topP,
      'contextLength': contextLength,
      'threads': threads,
    };
  }

  factory AiGenerationSettings.fromMap(Map<String, dynamic> map) {
    double temp = (map['temperature'] as num?)?.toDouble() ?? 0.7;
    if (temp < 0.1 || temp > 2.0) temp = 0.7;

    int maxTok = (map['maxTokens'] as num?)?.toInt() ?? 512;
    if (maxTok < 16 || maxTok > 4096) maxTok = 512;

    double p = (map['topP'] as num?)?.toDouble() ?? 0.9;
    if (p < 0.05 || p > 1.0) p = 0.9;

    int ctx = (map['contextLength'] as num?)?.toInt() ?? 2048;
    if (ctx < 256 || ctx > 32768) ctx = 2048;

    int th = (map['threads'] as num?)?.toInt() ?? 4;
    if (th < 1 || th > 16) th = 4;

    return AiGenerationSettings(
      temperature: temp,
      maxTokens: maxTok,
      topP: p,
      contextLength: ctx,
      threads: th,
    );
  }
}

class ModelInfo {
  final String path;
  final String name;
  final int fileSizeBytes;
  final bool isLoaded;

  const ModelInfo({
    required this.path,
    required this.name,
    required this.fileSizeBytes,
    this.isLoaded = false,
  });

  String get formattedSize {
    if (fileSizeBytes <= 0) return '0 MB';
    final mb = fileSizeBytes / (1024 * 1024);
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }
}

class ChatMessage {
  final String id;
  final String role; // 'user', 'assistant'
  final String content;
  final DateTime timestamp;
  final String? audioTimestampLabel;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.audioTimestampLabel,
  });

  bool get isUser => role == 'user';

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'role': role,
      'content': content,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'audio_timestamp_label': audioTimestampLabel,
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      id: map['id'] as String,
      role: map['role'] as String,
      content: map['content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      audioTimestampLabel: map['audio_timestamp_label'] as String?,
    );
  }
}
