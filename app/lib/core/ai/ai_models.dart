enum AiModelState {
  noModel,
  loading,
  ready,
  generating,
  error,
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

  Map<String, dynamic> toMap() {
    return {
      'temperature': temperature,
      'maxTokens': maxTokens,
      'topP': topP,
      'contextLength': contextLength,
      'threads': threads,
    };
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
