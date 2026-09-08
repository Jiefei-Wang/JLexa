import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test_helper.dart';
import 'llama_runtime_settings_test.dart'
    show MockTestAiEngine, MockTestSpeechEngine;

void main() {
  late Database db;
  setUpAll(() {
    sqfliteFfiInit();
    setupMockPlatformChannels();
  });
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    AppDatabase.setDatabaseForTesting(db);
  });
  tearDown(() async {
    AppDatabase.setDatabaseForTesting(null);
    await db.close();
  });
  AiService service() =>
      AiService(llm: MockTestAiEngine(), speech: MockTestSpeechEngine());
  test('Whisper segmentation defaults off, notifies and persists across initialization', () async {
    final first = service();
    addTearDown(first.dispose);
    expect(first.whisperSegmentationEnabled, false);
    await first.initialize();
    expect(first.whisperSegmentationEnabled, false);
    var changes = 0;
    first.addListener(() => changes++);
    await first.setWhisperSegmentationEnabled(true);
    expect(first.whisperSegmentationEnabled, true);
    expect(changes, 1);
    expect(
      (await db.query(
        'app_settings',
        where: 'key = ?',
        whereArgs: ['whisper_segmentation_enabled'],
      )).single['value'],
      'true',
    );
    await first.setWhisperSegmentationEnabled(true);
    expect(changes, 1);
    final restored = service();
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.whisperSegmentationEnabled, true);
    await restored.setWhisperSegmentationEnabled(false);
    final disabled = service();
    addTearDown(disabled.dispose);
    await disabled.initialize();
    expect(disabled.whisperSegmentationEnabled, false);
  });
}
