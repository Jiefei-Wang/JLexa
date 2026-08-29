import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/vocabulary/srs_scheduler.dart';
import 'package:jlexa/core/vocabulary/vocabulary_models.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../test_helper.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    setupMockPlatformChannels();
  });

  test('VocabularyRepository notifies listeners on save, review, and delete', () async {
    final repo = VocabularyRepository();
    int notificationCount = 0;
    repo.addListener(() {
      notificationCount++;
    });

    final word = VocabularyWord(
      id: 'voc_test_1',
      word: '  Resilient!  ',
      definitionSnapshot: 'Able to withstand hardship',
      dateAdded: DateTime.now(),
    );

    // Save word
    await repo.saveWord(word);
    expect(notificationCount, equals(1));

    // Verify word was normalized
    final saved = await repo.getWord('resilient');
    expect(saved, isNotNull);
    expect(saved!.word, equals('resilient'));

    // Review word
    await repo.reviewWord('voc_test_1', ReviewRating.good);
    expect(notificationCount, equals(2));

    // Delete word
    await repo.deleteWord('voc_test_1');
    expect(notificationCount, equals(3));

    final deleted = await repo.getWord('resilient');
    expect(deleted, isNull);
  });
}
