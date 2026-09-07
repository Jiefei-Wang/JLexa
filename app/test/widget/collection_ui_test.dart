import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/collection/collection_models.dart';
import 'package:jlexa/core/collection/collection_repository.dart';
import 'package:jlexa/core/theme/app_theme.dart';
import 'package:jlexa/core/vocabulary/vocabulary_models.dart';
import 'package:jlexa/core/vocabulary/vocabulary_repository.dart';
import 'package:jlexa/features/collection/collection_playback_controller.dart';
import 'package:jlexa/features/collection/collection_screen.dart';
import 'package:jlexa/features/vocabulary/study_screen.dart';
import 'package:jlexa/features/vocabulary/widgets/vocabulary_card.dart';

CollectionClip _clip({String id = 'one', String? transcript, String? title}) =>
    CollectionClip(
      id: id,
      sourceTitle: title ?? 'A saved lesson',
      sourceStartMs: 1250,
      sourceEndMs: 7250,
      durationMs: 6000,
      transcript:
          transcript ?? 'This complete sentence is saved with its audio.',
      audioFileName: '$id.wav',
      sourceKey: 'original-$id',
      createdAt: DateTime(2026, 9, 7),
    );

class _LocalClipFile implements File {
  @override
  final String path;
  final bool available;
  _LocalClipFile(this.path, this.available);
  @override
  Future<bool> exists() async => available;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryCollection extends CollectionRepository {
  final List<CollectionClip> entries;
  final List<String> events;
  bool loadError = false;
  bool deleteError = false;
  bool fileAvailable = true;
  final List<String> requestedFiles = [];
  final List<String> deletedFiles = [];

  _MemoryCollection(this.entries, {List<String>? events})
    : events = events ?? [];

  @override
  Future<List<CollectionClip>> getClips() async {
    if (loadError) throw StateError('Unavailable database');
    return List.of(entries);
  }

  @override
  Future<File> audioFile(CollectionClip clip) async {
    requestedFiles.add(clip.id);
    return _LocalClipFile(
      '/private/collection/${clip.audioFileName}',
      fileAvailable,
    );
  }

  @override
  Future<void> deleteClip(CollectionClip clip) async {
    if (deleteError) throw StateError('Cannot delete');
    events.add('delete:${clip.id}');
    deletedFiles.add(clip.audioFileName);
    entries.removeWhere((entry) => entry.id == clip.id);
    notifyListeners();
  }
}

class _MemoryVocabulary extends VocabularyRepository {
  @override
  Future<List<VocabularyWord>> getAllWords() async => [
    VocabularyWord(
      id: 'word',
      word: 'independent',
      definitionSnapshot: 'Able to work on its own.',
      source: 'Dictionary',
      dateAdded: DateTime(2026, 9, 1),
    ),
  ];
}

class _ClipPlayer implements AudioPlayer {
  final List<String> events;
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration>.broadcast();
  final states = StreamController<PlayerState>.broadcast();
  final completions = StreamController<void>.broadcast();
  Completer<void>? sourceGate;
  String? sourcePath;
  bool playing = false;
  bool disposed = false;

  _ClipPlayer({List<String>? events}) : events = events ?? [];

  @override
  Stream<Duration> get onPositionChanged => positions.stream;
  @override
  Stream<Duration> get onDurationChanged => durations.stream;
  @override
  Stream<PlayerState> get onPlayerStateChanged => states.stream;
  @override
  Stream<void> get onPlayerComplete => completions.stream;

  @override
  Future<void> pause() async {
    events.add('pause');
    playing = false;
    states.add(PlayerState.paused);
  }

  @override
  Future<void> stop() async {
    events.add('stop');
    playing = false;
    states.add(PlayerState.stopped);
  }

  @override
  Future<void> resume() async {
    events.add('resume:$sourcePath');
    playing = true;
    states.add(PlayerState.playing);
  }

  @override
  Future<void> seek(Duration position) async {
    events.add('seek:${position.inMilliseconds}');
    positions.add(position);
  }

  @override
  Future<void> setSourceDeviceFile(String path, {String? mimeType}) async {
    events.add('source:$path');
    final gate = sourceGate;
    sourceGate = null;
    await gate?.future;
    sourcePath = path;
  }

  @override
  Future<void> setReleaseMode(ReleaseMode releaseMode) async {
    events.add('release:${releaseMode.name}');
  }

  @override
  Future<Duration?> getDuration() async => const Duration(seconds: 6);

  @override
  Future<void> dispose() async {
    disposed = true;
    await Future.wait([
      positions.close(),
      durations.close(),
      states.close(),
      completions.close(),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush() async {
  for (var i = 0; i < 25; i++) {
    await Future<void>.value();
  }
}

Future<void> _pumpPhone(
  WidgetTester tester,
  Widget screen, {
  double width = 400,
  double scale = 1,
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(bottom: 32);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      theme: AppTheme.lightTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: screen,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'Standalone clip playback pauses shared audio, seeks and replays EOF',
    () async {
      final events = <String>[];
      final repo = _MemoryCollection([_clip()], events: events);
      final player = _ClipPlayer(events: events);
      final controller = CollectionPlaybackController(
        repository: repo,
        playerFactory: () => player,
        onBeforePlay: () async => events.add('pause-listening'),
      );
      addTearDown(controller.dispose);

      await controller.play(repo.entries.single);
      expect(controller.isPlaying, isTrue);
      expect(repo.requestedFiles, ['one']);
      expect(
        events.indexOf('pause-listening'),
        lessThan(events.indexOf('resume:/private/collection/one.wav')),
      );
      expect(events, contains('release:stop'));
      player.positions.add(const Duration(seconds: 2));
      await _flush();
      expect(controller.position, const Duration(seconds: 2));
      await controller.pause();
      expect(player.playing, isFalse);
      expect(controller.position, const Duration(seconds: 2));
      await controller.play(repo.entries.single);
      expect(repo.requestedFiles, ['one']);
      await controller.seek(const Duration(seconds: 4));
      expect(events, contains('seek:4000'));
      player.completions.add(null);
      await _flush();
      expect(controller.isPlaying, isFalse);
      expect(controller.position, const Duration(seconds: 6));
      player.positions.add(Duration.zero);
      await _flush();
      expect(controller.position, const Duration(seconds: 6));
      await controller.play(repo.entries.single);
      expect(events.last, 'resume:/private/collection/one.wav');
      expect(events[events.length - 2], 'seek:0');
      expect(controller.position, Duration.zero);
    },
  );

  test(
    'Leaving during shared-audio pause invalidates a pending play permanently',
    () async {
      final gate = Completer<void>();
      final repo = _MemoryCollection([_clip()]);
      final player = _ClipPlayer();
      final controller = CollectionPlaybackController(
        repository: repo,
        playerFactory: () => player,
        onBeforePlay: () => gate.future,
      );
      addTearDown(controller.dispose);
      final pending = controller.play(repo.entries.single);
      await _flush();
      expect(controller.isPreparing, isTrue);
      controller.setActive(false);
      controller.setActive(true);
      gate.complete();
      await pending;
      await _flush();
      expect(
        player.events.where((event) => event.startsWith('resume:')),
        isEmpty,
      );
      expect(repo.requestedFiles, isEmpty);
      expect(controller.isPlaying, isFalse);
      expect(controller.isPreparing, isFalse);
      await controller.play(repo.entries.single);
      expect(player.playing, isTrue);
    },
  );

  test(
    'Rapid clip changes keep only the newest source and playback request',
    () async {
      final first = _clip();
      final second = _clip(id: 'two');
      final repo = _MemoryCollection([first, second]);
      final player = _ClipPlayer();
      final gate = Completer<void>();
      player.sourceGate = gate;
      final controller = CollectionPlaybackController(
        repository: repo,
        playerFactory: () => player,
      );
      addTearDown(controller.dispose);
      final pending = controller.play(first);
      await _flush();
      expect(player.events, contains('source:/private/collection/one.wav'));
      final latest = controller.play(second);
      gate.complete();
      await Future.wait([pending, latest]);
      expect(controller.clip!.id, 'two');
      expect(player.sourcePath, '/private/collection/two.wav');
      expect(player.events.where((event) => event.startsWith('resume:')), [
        'resume:/private/collection/two.wav',
      ]);
    },
  );

  test(
    'Cancelling source preparation prevents late audio and supports retry',
    () async {
      final repo = _MemoryCollection([_clip()]);
      final player = _ClipPlayer();
      final gate = Completer<void>();
      player.sourceGate = gate;
      final controller = CollectionPlaybackController(
        repository: repo,
        playerFactory: () => player,
      );
      addTearDown(controller.dispose);
      final pending = controller.play(repo.entries.single);
      await _flush();
      final cancelled = controller.toggle(repo.entries.single);
      gate.complete();
      await Future.wait([pending, cancelled]);
      expect(player.playing, isFalse);
      expect(controller.isPreparing, isFalse);
      expect(
        player.events.where((event) => event.startsWith('resume:')),
        isEmpty,
      );
      await controller.play(repo.entries.single);
      expect(player.playing, isTrue);
    },
  );

  test(
    'Disposal while preparing prevents playback and releases the player',
    () async {
      final gate = Completer<void>();
      final repo = _MemoryCollection([_clip()]);
      final player = _ClipPlayer();
      final controller = CollectionPlaybackController(
        repository: repo,
        playerFactory: () => player,
        onBeforePlay: () => gate.future,
      );
      final pending = controller.play(repo.entries.single);
      await _flush();
      controller.dispose();
      gate.complete();
      await pending;
      await _flush();
      expect(player.playing, isFalse);
      expect(player.disposed, isTrue);
      expect(
        player.events.where((event) => event.startsWith('resume:')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'Study keeps vocabulary search state and stops Collection on tab and parent navigation',
    (tester) async {
      final repo = _MemoryCollection([_clip()]);
      final player = _ClipPlayer();
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      final vocabulary = _MemoryVocabulary();
      await _pumpPhone(
        tester,
        ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (context, isActive, _) => StudyScreen(
            vocabularyRepo: vocabulary,
            collectionRepo: repo,
            onOpenWordInDictionary: (_) {},
            collectionPlayerFactory: () => player,
            isActive: isActive,
          ),
        ),
      );
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(VocabularyCard), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'unmatched');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Collection'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(player.playing, isTrue);
      await tester.tap(find.text('Vocabulary'));
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'unmatched',
      );
      expect(find.text('No matching entries'), findsOneWidget);
      await tester.tap(find.text('Collection'));
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(player.playing, isTrue);
      active.value = false;
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);
      active.value = true;
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Collection stops on a covering route and on background, without automatic restart',
    (tester) async {
      final repo = _MemoryCollection([_clip()]);
      final player = _ClipPlayer();
      final navigator = GlobalKey<NavigatorState>();
      await _pumpPhone(
        tester,
        Scaffold(
          body: CollectionScreen(
            collectionRepo: repo,
            playerFactory: () => player,
          ),
        ),
        navigatorKey: navigator,
      );
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(player.playing, isTrue);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Other page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(player.playing, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);
      expect(find.text('Play'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Saving changes refresh the list and confirmed deletion stops and removes the local clip',
    (tester) async {
      final events = <String>[];
      final repo = _MemoryCollection([], events: events);
      final player = _ClipPlayer(events: events);
      await _pumpPhone(
        tester,
        Scaffold(
          body: CollectionScreen(
            collectionRepo: repo,
            playerFactory: () => player,
          ),
        ),
      );
      expect(find.text('Your saved listening clips'), findsOneWidget);
      repo.entries.add(_clip());
      repo.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text(repo.entries.single.transcript), findsOneWidget);
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete clip'));
      await tester.pumpAndSettle();
      expect(player.playing, isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.deletedFiles, isEmpty);
      expect(repo.entries, hasLength(1));
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete clip'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(repo.deletedFiles, ['one.wav']);
      expect(repo.entries, isEmpty);
      expect(
        events.lastIndexOf('stop'),
        lessThan(events.indexOf('delete:one')),
      );
      expect(find.text('Your saved listening clips'), findsOneWidget);
      expect(find.text('Clip deleted'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Load retry and missing audio keep the transcript recoverable', (
    tester,
  ) async {
    final repo = _MemoryCollection([_clip()])..loadError = true;
    final player = _ClipPlayer();
    await _pumpPhone(
      tester,
      Scaffold(
        body: CollectionScreen(
          collectionRepo: repo,
          playerFactory: () => player,
        ),
      ),
    );
    expect(
      find.text('Could not load your collection. Please try again.'),
      findsOneWidget,
    );
    repo.loadError = false;
    repo.fileAvailable = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(find.text(repo.entries.single.transcript), findsOneWidget);
    expect(
      find.textContaining('The saved audio file is missing'),
      findsOneWidget,
    );
    expect(player.playing, isFalse);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    repo.fileAvailable = true;
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(player.playing, isTrue);
    expect(
      find.textContaining('The saved audio file is missing'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Failed deletion retains the clip and supports another attempt', (
    tester,
  ) async {
    final repo = _MemoryCollection([_clip()])..deleteError = true;
    await _pumpPhone(
      tester,
      Scaffold(
        body: CollectionScreen(
          collectionRepo: repo,
          playerFactory: () => _ClipPlayer(),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Delete clip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(repo.entries, hasLength(1));
    expect(
      find.text('Could not delete this clip. Please try again.'),
      findsOneWidget,
    );
    repo.deleteError = false;
    await tester.tap(find.byTooltip('Delete clip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(repo.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '320dp large text keeps controls reachable and the full transcript selectable',
    (tester) async {
      final transcript = List.filled(
        40,
        'A saved sentence with every detail retained.',
      ).join(' ');
      final repo = _MemoryCollection([
        _clip(
          transcript: transcript,
          title: 'A long lesson title that wraps across a narrow phone screen',
        ),
      ]);
      final player = _ClipPlayer();
      await _pumpPhone(
        tester,
        StudyScreen(
          vocabularyRepo: _MemoryVocabulary(),
          collectionRepo: repo,
          onOpenWordInDictionary: (_) {},
          collectionPlayerFactory: () => player,
        ),
        width: 320,
        scale: 2,
      );
      await tester.tap(find.text('Collection'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('0:01.250–0:07.250 in original audio'), findsOneWidget);
      await tester.ensureVisible(find.text('Play'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byTooltip('Replay clip')).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
      final savedText = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(savedText.data, transcript);
      final scroll = find.descendant(
        of: find.byType(CollectionScreen),
        matching: find.byType(CustomScrollView),
      );
      await tester.drag(scroll, const Offset(0, -15000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getBottomRight(find.byType(SelectableText)).dy,
        lessThanOrEqualTo(768),
      );
    },
  );
}
