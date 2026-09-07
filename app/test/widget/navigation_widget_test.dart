import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_service.dart';
import 'package:jlexa/core/audio/audio_service.dart';
import 'package:jlexa/core/audio/lesson_repository.dart';
import 'package:jlexa/core/audio/waveform_service.dart';
import 'package:jlexa/core/collection/collection_models.dart';
import 'package:jlexa/core/collection/collection_repository.dart';
import 'package:jlexa/core/database/app_database.dart';
import 'package:jlexa/core/dictionary/dictionary_repository.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:jlexa/features/collection/collection_screen.dart';
import 'package:jlexa/features/dictionary/dictionary_screen.dart';
import 'package:jlexa/features/navigation/main_scaffold.dart';
import 'package:jlexa/features/vocabulary/study_screen.dart';
import 'package:jlexa/features/vocabulary/vocabulary_screen.dart';
import 'package:sqflite/sqflite.dart';

import '../test_helper.dart';

// Navigation exercises real repositories against completed local reads. A real
// FFI query launched by Home's Back refresh outlives fake-time widget pumps and
// leaves sqflite's lock-warning timer pending at teardown.
class _NavigationDatabase implements Database {
  final List<String> queriedTables = [];

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    queriedTables.add(table);
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NavigationCollection extends CollectionRepository {
  int loadCount = 0;

  @override
  Future<List<CollectionClip>> getClips() async {
    loadCount++;
    return [];
  }
}

void main() {
  late _NavigationDatabase database;
  setUp(() {
    setupMockPlatformChannels();
    database = _NavigationDatabase();
    AppDatabase.setDatabaseForTesting(database);
  });
  tearDown(() => AppDatabase.setDatabaseForTesting(null));

  testWidgets(
    'MainScaffold renders navigation destinations and switches tabs',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final dictionaryRepo = DictionaryRepository();
      final vocabularyRepo = VocabularyRepository();
      final collectionRepo = _NavigationCollection();
      final lessonRepo = LessonRepository();
      final audioService = AudioService();
      final waveformService = WaveformService();
      final aiService = AiService();

      await tester.pumpWidget(
        MaterialApp(
          home: MainScaffold(
            dictionaryRepo: dictionaryRepo,
            vocabularyRepo: vocabularyRepo,
            collectionRepo: collectionRepo,
            lessonRepo: lessonRepo,
            audioService: audioService,
            waveformService: waveformService,
            aiService: aiService,
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify Home screen loaded by checking app bar title
      expect(find.text('JLexa'), findsOneWidget);
      expect(find.text('Imported Audio Lessons'), findsOneWidget);
      expect(find.text('Quick Tools'), findsOneWidget);

      // Tap on Dictionary bottom navigation bar item
      await tester.tap(find.byIcon(Icons.menu_book_outlined));
      await tester.pumpAndSettle();

      // Verify Dictionary screen is active
      expect(find.byType(DictionaryScreen), findsOneWidget);

      // Tap on Study/Vocabulary bottom navigation bar item
      await tester.tap(find.byIcon(Icons.style_outlined));
      await tester.pumpAndSettle();

      // Verify Study screen is active
      expect(find.byType(StudyScreen), findsOneWidget);
      expect(find.byType(VocabularyScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Study'), findsOneWidget);
      await tester.tap(find.text('Collection'));
      await tester.pumpAndSettle();
      expect(find.byType(CollectionScreen), findsOneWidget);
      expect(find.byType(VocabularyScreen), findsNothing);
      expect(find.text('Your saved listening clips'), findsOneWidget);

      // An inner Study tab does not add a bottom-navigation history entry.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(DictionaryScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('JLexa'), findsOneWidget);
      expect(
        database.queriedTables.where((table) => table == 'recent_searches'),
        hasLength(2),
      );
      expect(collectionRepo.loadCount, 1);
      var exitCalls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') exitCalls++;
          return null;
        },
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(exitCalls, 0);
      expect(find.textContaining('Press back again'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(exitCalls, 1);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    },
  );
}
