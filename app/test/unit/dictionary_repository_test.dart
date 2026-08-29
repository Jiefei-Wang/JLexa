import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DictionaryRepository Tests', () {
    late DictionaryRepository repository;

    setUp(() {
      repository = DictionaryRepository();
    });

    test('Look up existing word "resilient"', () async {
      final entry = await repository.lookupWord('resilient');
      expect(entry, isNotNull);
      expect(entry!.word, equals('resilient'));
      expect(entry.partOfSpeech, equals('Adjective'));
      expect(entry.isHighFrequency, isTrue);
      expect(entry.definitions, isNotEmpty);
      expect(entry.synonyms, contains('robust'));
    });

    test('Look up word "prioritize"', () async {
      final entry = await repository.lookupWord('prioritize');
      expect(entry, isNotNull);
      expect(entry!.word, equals('prioritize'));
      expect(entry.partOfSpeech, equals('Verb'));
      expect(entry.chineseDefinitions, isNotEmpty);
    });

    test('Look up words required by spec', () async {
      final requiredWords = [
        'schedule',
        'priority',
        'meticulous',
        'endeavor',
        'context',
        'significant',
        'interpret',
      ];

      for (final word in requiredWords) {
        final entry = await repository.lookupWord(word);
        expect(entry, isNotNull, reason: 'Failed looking up $word');
        expect(entry!.word, equals(word));
      }
    });

    test('Search suggestions return prefix matches', () async {
      final suggestions = await repository.searchSuggestions('pri');
      expect(suggestions, contains('prioritize'));
      expect(suggestions, contains('priority'));
    });

    test('Look up non-existent word returns null gracefully', () async {
      final entry = await repository.lookupWord('nonexistentwordxyz123');
      expect(entry, isNull);
    });
  });
}
