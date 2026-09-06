import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../dictionary/offline_dictionary_data.dart';

class AppDatabase {
  static final AppDatabase instance = AppDatabase._init();
  static Database? _database;

  AppDatabase._init();

  static void setDatabaseForTesting(Database? db) {
    _database = db;
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('jlexa_app.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 3,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE audio_lessons ADD COLUMN cuts_initialized INTEGER NOT NULL DEFAULT 1',
          );
          await db.execute(
            'ALTER TABLE audio_segments ADD COLUMN revision INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE audio_segments ADD COLUMN transcript_cut_revision INTEGER',
          );
          await db.execute(
            'ALTER TABLE audio_segments ADD COLUMN transcript_model_id TEXT',
          );
          // Existing rows predate revision tracking. Their transcript belongs
          // to revision zero; existing empty lessons are treated as explicitly
          // initialized so migration never resurrects user-deleted cuts.
          await db.execute(
            "UPDATE audio_segments SET transcript_cut_revision = 0 WHERE TRIM(text) <> ''",
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE audio_lessons ADD COLUMN source_hash TEXT',
          );
          await _createConversations(db);
        }
      },
      onOpen: (db) async {
        try {
          await db.execute(
            "UPDATE audio_lessons SET transcript_status = 'none' WHERE transcript_status = 'processing'",
          );
          await db.execute('''
            CREATE TABLE IF NOT EXISTS offline_dictionary (
              word TEXT PRIMARY KEY,
              phonetic TEXT,
              part_of_speech TEXT,
              definitions_json TEXT NOT NULL,
              chinese_definitions_json TEXT NOT NULL,
              examples_json TEXT NOT NULL,
              synonyms_json TEXT NOT NULL,
              is_high_frequency INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_offline_dict_word ON offline_dictionary(word)',
          );

          final count = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM offline_dictionary'),
          );
          if (count == null || count < kOfflineDictionaryEntries.length) {
            final batch = db.batch();
            for (final entry in kOfflineDictionaryEntries) {
              batch.insert('offline_dictionary', {
                'word': entry.word.toLowerCase(),
                'phonetic': entry.phonetic,
                'part_of_speech': entry.partOfSpeech,
                'definitions_json': jsonEncode(entry.definitions),
                'chinese_definitions_json': jsonEncode(
                  entry.chineseDefinitions,
                ),
                'examples_json': jsonEncode(
                  entry.examples.map((e) => e.toMap()).toList(),
                ),
                'synonyms_json': jsonEncode(entry.synonyms),
                'is_high_frequency': entry.isHighFrequency ? 1 : 0,
              }, conflictAlgorithm: ConflictAlgorithm.ignore);
            }
            await batch.commit(noResult: true);
          }
        } catch (_) {}
      },
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // Offline dictionary
    await db.execute('''
      CREATE TABLE offline_dictionary (
        word TEXT PRIMARY KEY,
        phonetic TEXT,
        part_of_speech TEXT,
        definitions_json TEXT NOT NULL,
        chinese_definitions_json TEXT NOT NULL,
        examples_json TEXT NOT NULL,
        synonyms_json TEXT NOT NULL,
        is_high_frequency INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_offline_dict_word ON offline_dictionary(word)',
    );

    final batch = db.batch();
    for (final entry in kOfflineDictionaryEntries) {
      batch.insert('offline_dictionary', {
        'word': entry.word.toLowerCase(),
        'phonetic': entry.phonetic,
        'part_of_speech': entry.partOfSpeech,
        'definitions_json': jsonEncode(entry.definitions),
        'chinese_definitions_json': jsonEncode(entry.chineseDefinitions),
        'examples_json': jsonEncode(
          entry.examples.map((e) => e.toMap()).toList(),
        ),
        'synonyms_json': jsonEncode(entry.synonyms),
        'is_high_frequency': entry.isHighFrequency ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);

    // Recent search keywords
    await db.execute('''
      CREATE TABLE recent_searches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        word TEXT NOT NULL UNIQUE,
        searched_at INTEGER NOT NULL
      )
    ''');

    // Vocabulary items (SRS)
    await db.execute('''
      CREATE TABLE vocabulary (
        id TEXT PRIMARY KEY,
        word TEXT NOT NULL UNIQUE,
        phonetic TEXT,
        part_of_speech TEXT,
        definition_snapshot TEXT,
        translation_snapshot TEXT,
        source TEXT,
        source_sentence TEXT,
        state TEXT NOT NULL,
        date_added INTEGER NOT NULL,
        last_reviewed INTEGER,
        next_review INTEGER,
        review_count INTEGER NOT NULL DEFAULT 0,
        interval_days INTEGER NOT NULL DEFAULT 0,
        ease_factor REAL NOT NULL DEFAULT 2.5
      )
    ''');

    // Audio lessons
    await db.execute('''
      CREATE TABLE audio_lessons (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        original_file_name TEXT NOT NULL,
        local_path TEXT NOT NULL,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        current_position_ms INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        last_opened_at INTEGER NOT NULL,
        transcript_status TEXT NOT NULL DEFAULT 'none',
        waveform_cache_path TEXT
        ,cuts_initialized INTEGER NOT NULL DEFAULT 0
        ,source_hash TEXT
      )
    ''');

    // Audio segments
    await db.execute('''
      CREATE TABLE audio_segments (
        id TEXT PRIMARY KEY,
        lesson_id TEXT NOT NULL,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        text TEXT NOT NULL,
        confidence REAL NOT NULL DEFAULT 1.0,
        is_user_edited INTEGER NOT NULL DEFAULT 0,
        tokens_json TEXT,
        revision INTEGER NOT NULL DEFAULT 0,
        transcript_cut_revision INTEGER,
        transcript_model_id TEXT,
        FOREIGN KEY (lesson_id) REFERENCES audio_lessons (id) ON DELETE CASCADE
      )
    ''');

    await _createConversations(db);

    // Chat messages
    await db.execute('''
      CREATE TABLE chat_messages (
        id TEXT PRIMARY KEY,
        lesson_id TEXT,
        segment_id TEXT,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL
      )
    ''');

    // Key-value settings
    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  Future<void> _createConversations(Database db) async {
    await db.execute('''CREATE TABLE chat_conversations (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, context_json TEXT,
      messages_json TEXT NOT NULL, updated_at INTEGER NOT NULL
    )''');
  }

  Future<void> close() async {
    final db = _database;
    _database = null;
    if (db != null) {
      await db.close();
    }
  }
}
