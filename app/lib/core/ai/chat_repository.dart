import 'dart:convert';

import '../database/app_database.dart';
import 'ai_models.dart';
import 'prompt_builder.dart';

class ChatConversation {
  final String id, title;
  final DateTime updatedAt;
  final SentenceContext? context;
  final List<ChatMessage> messages;
  const ChatConversation({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.messages,
    this.context,
  });

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'messages_json': jsonEncode(messages.map((m) => m.toMap()).toList()),
    'context_json': context == null
        ? null
        : jsonEncode({
            'lessonTitle': context!.lessonTitle,
            'sentenceText': context!.sentenceText,
            'previousSentence': context!.previousSentence,
            'nextSentence': context!.nextSentence,
            'startMs': context!.startMs,
            'endMs': context!.endMs,
            'uncertainWords': context!.uncertainWords,
          }),
  };

  factory ChatConversation.fromMap(Map<String, Object?> row) {
    final raw = row['context_json'] as String?;
    final c = raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
    return ChatConversation(
      id: row['id'] as String,
      title: row['title'] as String,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      messages: (jsonDecode(row['messages_json'] as String) as List)
          .map((m) => ChatMessage.fromMap(Map<String, dynamic>.from(m as Map)))
          .toList(),
      context: c == null
          ? null
          : SentenceContext(
              lessonTitle: c['lessonTitle'],
              sentenceText: c['sentenceText'],
              previousSentence: c['previousSentence'],
              nextSentence: c['nextSentence'],
              startMs: c['startMs'] ?? 0,
              endMs: c['endMs'] ?? 0,
              uncertainWords: List<String>.from(c['uncertainWords'] ?? []),
            ),
    );
  }
}

class ChatRepository {
  // All controllers share ordering: deletion cannot be overtaken by an older save.
  static Future<void> _writes = Future.value();
  Future<void> _write(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> save(ChatConversation conversation) => _write(() async {
    final db = await AppDatabase.instance.database;
    final row = conversation.toMap();
    await db.transaction((txn) async {
      final changed = await txn.update(
        'chat_conversations',
        row,
        where: 'id = ?',
        whereArgs: [conversation.id],
      );
      if (changed == 0) await txn.insert('chat_conversations', row);
    });
  });

  Future<List<ChatConversation>> list() async {
    await _writes;
    final db = await AppDatabase.instance.database;
    return (await db.query(
      'chat_conversations',
      orderBy: 'updated_at DESC',
    )).map(ChatConversation.fromMap).toList();
  }

  Future<ChatConversation?> get(String id) async {
    await _writes;
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'chat_conversations',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : ChatConversation.fromMap(rows.single);
  }

  Future<void> delete(String id) => _write(() async {
    final db = await AppDatabase.instance.database;
    await db.delete('chat_conversations', where: 'id = ?', whereArgs: [id]);
  });
}
