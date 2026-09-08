import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/dictionary/dictionary_store.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory temp;
  late Database db;
  late DictionaryStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('jlexa-dictionary-test-');
    db = await databaseFactoryFfi.openDatabase('${temp.path}/catalog.db');
    store = DictionaryStore(testingDatabase: db);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  Future<ManagedDictionary> import(
    String text, {
    String name = 'sample.txt',
  }) async {
    final source = await File('${temp.path}/$name').writeAsString(text);
    return store.importFile(source.path, temporaryDirectory: temp);
  }

  test(
    'import, lookup, suggestions, disable, reopen and delete persist',
    () async {
      final result = await import(
        'jlexatest@A local definition.\nJlexaAlias@@@@LINK=jlexatest',
      );
      expect(result.count, 2);
      expect(
        (await store.lookup('jlexatest'))!.definitions.single,
        contains('A local definition.'),
      );
      expect(
        (await store.lookup('jlexaalias'))!.definitions.single,
        contains('A local definition.'),
      );
      expect(await store.suggestions('jlexa'), ['jlexaalias', 'jlexatest']);
      expect(await store.suggestions('%'), isEmpty);
      await store.setEnabled(result.id, false);
      expect(await store.lookup('jlexatest'), isNull);
      final reopened = DictionaryStore(testingDatabase: db);
      expect(
        (await reopened.list()).singleWhere((d) => d.id == result.id).enabled,
        false,
      );
      await reopened.setEnabled(result.id, true);
      expect(await reopened.lookup('jlexatest'), isNotNull);
      await reopened.delete(result.id);
      expect(await reopened.lookup('jlexatest'), isNull);
      expect(await db.query('dictionary_entries'), isEmpty);
      expect(await File('${temp.path}/sample.txt').exists(), true);
    },
  );

  test(
    'corrupt import leaves catalog and existing definitions unchanged',
    () async {
      await import('retained@Valid entry.');
      await expectLater(
        import('bad@Definition\nbroken row'),
        throwsFormatException,
      );
      expect((await store.list()).length, 3);
      expect(await store.lookup('bad'), isNull);
      expect(await store.lookup('retained'), isNotNull);
      expect(
        await Directory('${temp.path}/dictionary-import').list().length,
        0,
      );
    },
  );

  test(
    'duplicate definitions coexist; redirect cycles never recurse forever',
    () async {
      await import(
        'poly@First sense\npoly@Second sense\na@@@@LINK=b\nb@@@@LINK=a',
      );
      expect((await store.lookup('poly'))!.definitions.length, 2);
      expect(await store.lookup('a'), isNull);
    },
  );

  test(
    'builtins cannot be removed and disable affects cached core lookups',
    () async {
      final repo = DictionaryRepository(store: store);
      expect(await repo.lookupWord('resilient'), isNotNull);
      var changes = 0;
      repo.addListener(() => changes++);
      await repo.setDictionaryEnabled('builtin-core', false);
      await repo.setDictionaryEnabled('builtin-ecdict', false);
      expect(await repo.lookupWord('resilient'), isNull);
      expect(await repo.searchSuggestions('resi'), isEmpty);
      await expectLater(
        repo.deleteDictionary('builtin-core'),
        throwsStateError,
      );
      await repo.setDictionaryEnabled('builtin-core', true);
      expect(await repo.lookupWord('resilient'), isNotNull);
      expect(changes, 3);
      repo.dispose();
    },
  );
}
