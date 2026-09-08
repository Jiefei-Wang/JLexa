import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:jlexa/core/dictionary/dictionary_store.dart';
import 'package:jlexa/features/dictionary/dictionary_manager_screen.dart';

class _Repository extends DictionaryRepository {
  bool enabled = true, deleted = false;
  @override
  Future<List<ManagedDictionary>> managedDictionaries() async => [
    const ManagedDictionary(
      id: 'core',
      name: 'JLexa Core',
      format: 'Built-in',
      count: 20,
      enabled: true,
      builtIn: true,
    ),
    if (!deleted)
      ManagedDictionary(
        id: 'custom',
        name: 'Imported dictionary',
        format: 'MDX',
        count: 12,
        enabled: enabled,
        builtIn: false,
      ),
  ];
  @override
  Future<void> setDictionaryEnabled(String id, bool value) async {
    enabled = value;
  }

  @override
  Future<void> deleteDictionary(String id) async {
    deleted = true;
  }
}

void main() {
  testWidgets(
    'manager enables/disables and confirms removal of imported dictionary',
    (tester) async {
      final repo = _Repository();
      await tester.pumpWidget(
        MaterialApp(home: DictionaryManagerScreen(dictionaryRepo: repo)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Dictionary Manager'), findsOneWidget);
      expect(find.text('Import'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      await tester.tap(find.text('Imported dictionary'));
      await tester.pumpAndSettle();
      expect(repo.enabled, false);
      await tester.tap(find.byTooltip('Delete Imported dictionary'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.deleted, false);
      await tester.tap(find.byTooltip('Delete Imported dictionary'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Imported dictionary'), findsNothing);
      expect(find.text('JLexa Core'), findsOneWidget);
      repo.dispose();
    },
  );
}
