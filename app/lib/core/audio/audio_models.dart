import 'dart:convert';

/// Canonical transcript status for lessons.
enum TranscriptStatus {
  none,
  pendingModel,
  processing,
  completed,
  failed;

  String toDbString() => name;

  static TranscriptStatus fromDbString(String? s) {
    switch (s) {
      case 'pendingModel':
        return TranscriptStatus.pendingModel;
      case 'processing':
        return TranscriptStatus.processing;
      case 'completed':
        return TranscriptStatus.completed;
      case 'ready': // legacy compatibility
        return TranscriptStatus.completed;
      case 'failed':
        return TranscriptStatus.failed;
      case 'pending_model':
        return TranscriptStatus.pendingModel;
      default:
        return TranscriptStatus.none;
    }
  }
}

/// State machine for an active transcription operation.
enum TranscriptionState { idle, transcribing, cancelling }

class AudioLesson {
  final String id;
  final String title;
  final String originalFileName;
  final String localPath;
  final int durationMs;
  final int currentPositionMs;
  final DateTime createdAt;
  final DateTime lastOpenedAt;
  final TranscriptStatus transcriptStatus;
  final String? waveformCachePath;
  final bool cutsInitialized;

  const AudioLesson({
    required this.id,
    required this.title,
    required this.originalFileName,
    required this.localPath,
    this.durationMs = 0,
    this.currentPositionMs = 0,
    required this.createdAt,
    required this.lastOpenedAt,
    this.transcriptStatus = TranscriptStatus.none,
    this.waveformCachePath,
    this.cutsInitialized = false,
  });

  double get progressPercentage {
    if (durationMs <= 0) return 0.0;
    final double progress = (currentPositionMs / durationMs)
        .clamp(0.0, 1.0)
        .toDouble();
    return progress;
  }

  AudioLesson copyWith({
    String? id,
    String? title,
    String? originalFileName,
    String? localPath,
    int? durationMs,
    int? currentPositionMs,
    DateTime? createdAt,
    DateTime? lastOpenedAt,
    TranscriptStatus? transcriptStatus,
    String? waveformCachePath,
    bool? cutsInitialized,
  }) {
    return AudioLesson(
      id: id ?? this.id,
      title: title ?? this.title,
      originalFileName: originalFileName ?? this.originalFileName,
      localPath: localPath ?? this.localPath,
      durationMs: durationMs ?? this.durationMs,
      currentPositionMs: currentPositionMs ?? this.currentPositionMs,
      createdAt: createdAt ?? this.createdAt,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
      transcriptStatus: transcriptStatus ?? this.transcriptStatus,
      waveformCachePath: waveformCachePath ?? this.waveformCachePath,
      cutsInitialized: cutsInitialized ?? this.cutsInitialized,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'original_file_name': originalFileName,
      'local_path': localPath,
      'duration_ms': durationMs,
      'current_position_ms': currentPositionMs,
      'created_at': createdAt.millisecondsSinceEpoch,
      'last_opened_at': lastOpenedAt.millisecondsSinceEpoch,
      'transcript_status': transcriptStatus.toDbString(),
      'waveform_cache_path': waveformCachePath,
      'cuts_initialized': cutsInitialized ? 1 : 0,
    };
  }

  factory AudioLesson.fromMap(Map<String, dynamic> map) {
    return AudioLesson(
      id: map['id'] as String,
      title: map['title'] as String,
      originalFileName: map['original_file_name'] as String,
      localPath: map['local_path'] as String,
      durationMs: map['duration_ms'] as int? ?? 0,
      currentPositionMs: map['current_position_ms'] as int? ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      lastOpenedAt: DateTime.fromMillisecondsSinceEpoch(
        map['last_opened_at'] as int,
      ),
      transcriptStatus: TranscriptStatus.fromDbString(
        map['transcript_status'] as String?,
      ),
      waveformCachePath: map['waveform_cache_path'] as String?,
      cutsInitialized:
          map['cuts_initialized'] == 1 || map['cuts_initialized'] == true,
    );
  }
}

class TranscriptToken {
  final String text;
  final int startMs;
  final int endMs;
  final double confidence; // 0.0 - 1.0

  const TranscriptToken({
    required this.text,
    this.startMs = 0,
    this.endMs = 0,
    this.confidence = 1.0,
  });

  bool get isUncertain => confidence < 0.85;
  bool get isLowConfidence => confidence < 0.65;

  Map<String, dynamic> toMap() {
    return {
      'text': text,
      'start_ms': startMs,
      'end_ms': endMs,
      'confidence': confidence,
    };
  }

  factory TranscriptToken.fromMap(Map<String, dynamic> map) {
    return TranscriptToken(
      text: map['text'] as String,
      startMs: map['start_ms'] as int? ?? 0,
      endMs: map['end_ms'] as int? ?? 0,
      confidence: (map['confidence'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

class AudioSegment {
  final String id;
  final String lessonId;
  final int startMs;
  final int endMs;
  final String text;
  final double confidence;
  final bool isUserEdited;
  final List<TranscriptToken> tokens;

  /// Monotonically increasing content version for this cut. Any boundary
  /// change invalidates transcript/explanation data created for an older
  /// revision.
  final int revision;
  final int? transcriptCutRevision;
  final String? transcriptModelId;

  const AudioSegment({
    required this.id,
    required this.lessonId,
    required this.startMs,
    required this.endMs,
    required this.text,
    this.confidence = 1.0,
    this.isUserEdited = false,
    this.tokens = const [],
    this.revision = 0,
    this.transcriptCutRevision,
    this.transcriptModelId,
  });

  int get durationMs => endMs - startMs;

  bool containsPosition(int positionMs, {bool isLast = false}) =>
      positionMs >= startMs && positionMs < endMs;

  bool get hasValidTranscript =>
      text.trim().isNotEmpty &&
      (transcriptCutRevision == null || transcriptCutRevision == revision);

  AudioSegment copyWith({
    String? id,
    String? lessonId,
    int? startMs,
    int? endMs,
    String? text,
    double? confidence,
    bool? isUserEdited,
    List<TranscriptToken>? tokens,
    int? revision,
    int? transcriptCutRevision,
    String? transcriptModelId,
    bool clearTranscript = false,
  }) {
    return AudioSegment(
      id: id ?? this.id,
      lessonId: lessonId ?? this.lessonId,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      text: clearTranscript ? '' : (text ?? this.text),
      confidence: clearTranscript ? -1.0 : (confidence ?? this.confidence),
      isUserEdited: isUserEdited ?? this.isUserEdited,
      tokens: clearTranscript ? const [] : (tokens ?? this.tokens),
      revision: revision ?? this.revision,
      transcriptCutRevision: clearTranscript
          ? null
          : (transcriptCutRevision ?? this.transcriptCutRevision),
      transcriptModelId: clearTranscript
          ? null
          : (transcriptModelId ?? this.transcriptModelId),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'lesson_id': lessonId,
      'start_ms': startMs,
      'end_ms': endMs,
      'text': text,
      'confidence': confidence,
      'is_user_edited': isUserEdited ? 1 : 0,
      'tokens_json': jsonEncode(tokens.map((t) => t.toMap()).toList()),
      'revision': revision,
      'transcript_cut_revision': transcriptCutRevision,
      'transcript_model_id': transcriptModelId,
    };
  }

  factory AudioSegment.fromMap(Map<String, dynamic> map) {
    List<TranscriptToken> parsedTokens = [];
    if (map['tokens_json'] != null &&
        (map['tokens_json'] as String).isNotEmpty) {
      try {
        final decoded =
            jsonDecode(map['tokens_json'] as String) as List<dynamic>;
        parsedTokens = decoded
            .map((e) => TranscriptToken.fromMap(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }

    return AudioSegment(
      id: map['id'] as String,
      lessonId: map['lesson_id'] as String,
      startMs: map['start_ms'] as int,
      endMs: map['end_ms'] as int,
      text: map['text'] as String,
      confidence: (map['confidence'] as num?)?.toDouble() ?? 1.0,
      isUserEdited: map['is_user_edited'] == 1 || map['is_user_edited'] == true,
      tokens: parsedTokens,
      revision: map['revision'] as int? ?? 0,
      transcriptCutRevision: map['transcript_cut_revision'] as int?,
      transcriptModelId: map['transcript_model_id'] as String?,
    );
  }
}
