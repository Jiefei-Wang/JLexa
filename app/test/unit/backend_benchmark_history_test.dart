import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/backend_benchmark.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT)',
    );
    AppDatabase.setDatabaseForTesting(db);
  });
  tearDown(() async {
    AppDatabase.setDatabaseForTesting(null);
    await db.close();
  });
  String key(String model, String plugin) =>
      'backend_benchmark_v1:${jsonEncode([model, plugin])}';
  test('catalog preserves latest built-in and CPU plugin history for the same model', () async {
    final store = DatabaseBenchmarkStore(
      legacyPluginRows: {'true/Snapdragon/1/snap.so': 'plugin:a'},
    );
    const old = BackendBenchmarkResult(
      backend: 'cpu',
      time: '2026-09-07T12:00',
      promptTokens: 100,
      prefillUs: 1000000,
    );
    const recent = BackendBenchmarkResult(
      backend: 'cpu',
      time: '2026-09-07T13:00',
      promptTokens: 100,
      prefillUs: 500000,
    );
    await store.write(key('model', 'false/llama/1/old.so'), {'cpu': old});
    await store.write(key('model', 'false/llama/1/'), {'cpu': recent});
    await store.write(key('model', 'true/Snapdragon/1/snap.so'), {'cpu': old});
    await store.write(key('other-model', 'false/llama/1/'), {'cpu': old});
    final migrated = await store.read(key('model', 'backend_catalog_v1'));
    expect(migrated.keys, containsAll(['cpu', 'plugin:a']));
    expect(migrated['cpu']!.prefillSpeed, 200);
    expect(migrated['plugin:a']!.prefillSpeed, 100);
    expect(
      (await store.read(
        key('model', 'backend_catalog_v1'),
      ))['cpu']!.prefillSpeed,
      200,
    );
  });
  test('malformed legacy history does not prevent a new benchmark', () async {
    await db.insert('app_settings', {
      'key': key('model', 'false/old'),
      'value': 'invalid JSON',
    });
    expect(
      await DatabaseBenchmarkStore().read(key('model', 'backend_catalog_v1')),
      isEmpty,
    );
  });
}
