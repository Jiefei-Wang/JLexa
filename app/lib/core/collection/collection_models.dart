class CollectionClip {
  final String id;
  final String sourceTitle;
  final int sourceStartMs;
  final int sourceEndMs;
  final int durationMs;
  final String transcript;
  final String audioFileName;
  final String sourceKey;
  final DateTime createdAt;

  const CollectionClip({
    required this.id,
    required this.sourceTitle,
    required this.sourceStartMs,
    required this.sourceEndMs,
    required this.durationMs,
    required this.transcript,
    required this.audioFileName,
    required this.sourceKey,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
    'id': id,
    'source_title': sourceTitle,
    'source_start_ms': sourceStartMs,
    'source_end_ms': sourceEndMs,
    'duration_ms': durationMs,
    'transcript': transcript,
    'audio_file_name': audioFileName,
    'source_key': sourceKey,
    'created_at': createdAt.millisecondsSinceEpoch,
  };

  factory CollectionClip.fromMap(Map<String, Object?> map) => CollectionClip(
    id: map['id'] as String,
    sourceTitle: map['source_title'] as String,
    sourceStartMs: map['source_start_ms'] as int,
    sourceEndMs: map['source_end_ms'] as int,
    durationMs: map['duration_ms'] as int,
    transcript: map['transcript'] as String,
    audioFileName: map['audio_file_name'] as String,
    sourceKey: map['source_key'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
  );
}
