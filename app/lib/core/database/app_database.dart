import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  static final AppDatabase instance = AppDatabase._init();
  static Database? _database;

  AppDatabase._init();

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
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
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
        FOREIGN KEY (lesson_id) REFERENCES audio_lessons (id) ON DELETE CASCADE
      )
    ''');

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

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
    }
  }
}
