import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/audio_service.dart';

import '../test_helper.dart';

void main() {
  late Directory directory;
  late AudioService audio;
  late AudioLesson lesson;
  late String playerId;
  late List<MethodCall> calls;
  var nativePosition = 0;
  Completer<void>? pauseGate;
  Completer<void>? seekGate;
  Completer<int>? positionGate;
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> event(String name) async {
    await messenger.handlePlatformMessage(
      'xyz.luan/audioplayers/events/$playerId',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': name,
        if (name == 'audio.onPrepared') 'value': true,
      }),
      (_) {},
    );
  }

  Future<void> waitUntil(bool Function() condition) async {
    final elapsed = Stopwatch()..start();
    while (!condition()) {
      if (elapsed.elapsed > const Duration(seconds: 2)) {
        fail('Timed out waiting for native audio work without Flutter frames.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> position(int milliseconds) async {
    nativePosition = milliseconds;
    final previousQueries = calls
        .where((call) => call.method == 'getCurrentPosition')
        .length;
    await waitUntil(
      () =>
          calls.where((call) => call.method == 'getCurrentPosition').length >
          previousQueries,
    );
  }

  setUp(() async {
    setupMockPlatformChannels();
    calls = [];
    pauseGate = null;
    seekGate = null;
    positionGate = null;
    nativePosition = 0;
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        calls.add(call);
        final args = call.arguments as Map;
        playerId = args['playerId'] as String;
        if (call.method == 'create') {
          messenger.setMockMessageHandler(
            'xyz.luan/audioplayers/events/$playerId',
            (_) async =>
                const StandardMethodCodec().encodeSuccessEnvelope(null),
          );
        } else if (call.method.startsWith('setSource')) {
          scheduleMicrotask(() => event('audio.onPrepared'));
        } else if (call.method == 'seek') {
          nativePosition = args['position'] as int;
          final pending = seekGate;
          seekGate = null;
          await pending?.future;
          scheduleMicrotask(() => event('audio.onSeekComplete'));
        } else if (call.method == 'pause') {
          final pending = pauseGate;
          pauseGate = null;
          await pending?.future;
        } else if (call.method == 'getCurrentPosition') {
          final pending = positionGate;
          positionGate = null;
          return pending?.future ?? nativePosition;
        } else if (call.method == 'getDuration') {
          return 5000;
        }
        return 1;
      },
    );
    directory = await Directory.systemTemp.createTemp('jlexa-auto-stop-');
    final file = await File('${directory.path}/audio.wav').writeAsBytes([0]);
    lesson = AudioLesson(
      id: 'lesson',
      title: 'Boundary test',
      originalFileName: 'audio.wav',
      localPath: file.path,
      durationMs: 5000,
      createdAt: DateTime.now(),
      lastOpenedAt: DateTime.now(),
    );
    audio = AudioService();
    await audio.loadLesson(lesson, const [
      AudioSegment(
        id: 'a',
        lessonId: 'lesson',
        startMs: 0,
        endMs: 1000,
        text: '',
      ),
      AudioSegment(
        id: 'b',
        lessonId: 'lesson',
        startMs: 1000,
        endMs: 2000,
        text: '',
      ),
      AudioSegment(
        id: 'c',
        lessonId: 'lesson',
        startMs: 3000,
        endMs: 5000,
        text: '',
      ),
    ]);
  });
  tearDown(() async {
    audio.dispose();
    await directory.delete(recursive: true);
  });

  for (final repeat in [false, true]) {
    for (final autoStop in [false, true]) {
      test(
        'Repeat=$repeat Auto-stop=$autoStop works without Flutter frames',
        () async {
          expect(audio.isAutoStop, isTrue);
          if (repeat) audio.toggleRepeatOne();
          if (!autoStop) audio.toggleAutoStop();
          await audio.seekTo(400);
          await audio.play();
          calls.clear();
          await position(1100);
          if (repeat && !autoStop) {
            expect(audio.positionMs, 0);
            expect(audio.currentSegment?.id, 'a');
            expect(audio.isPlaying, isTrue);
            expect(calls.any((c) => c.method == 'resume'), isTrue);
            expect(calls.any((c) => c.method == 'pause'), isFalse);
          } else if (autoStop) {
            expect(audio.positionMs, 1000);
            expect(audio.currentSegment?.id, 'a');
            expect(audio.isPlaying, isFalse);
            expect(calls.any((c) => c.method == 'pause'), isTrue);
            expect(calls.any((c) => c.method == 'resume'), isFalse);
          } else {
            expect(audio.positionMs, 1100);
            expect(audio.currentSegment?.id, 'b');
            expect(audio.isPlaying, isTrue);
            expect(calls.any((c) => c.method == 'pause'), isFalse);
            expect(calls.any((c) => c.method == 'seek'), isFalse);
          }
          await audio.pause();
        },
      );
    }
  }

  test(
    'Repeat plus Auto-stop waits, then Play restarts the finished cut',
    () async {
      audio.toggleRepeatOne();
      await audio.play();
      await position(1100);
      expect(audio.isPlaying, isFalse);
      expect(audio.positionMs, 1000);
      await audio.play();
      expect(audio.positionMs, 0);
      expect(audio.currentSegment?.id, 'a');
      await position(1100);
      expect(audio.isPlaying, isFalse);
      await audio.seekTo(2500);
      await audio.play();
      await position(5100);
      expect(audio.isPlaying, isFalse);
      await audio.play();
      expect(audio.positionMs, 3000);
      await audio.pause();
    },
  );

  test(
    'Repeat without Auto-stop loops the first cut entered from a gap',
    () async {
      audio.toggleRepeatOne();
      audio.toggleAutoStop();
      await audio.seekTo(2500);
      await audio.play();
      await position(5100);
      expect(audio.positionMs, 3000);
      expect(audio.currentSegment?.id, 'c');
      expect(audio.isPlaying, isTrue);
      await audio.pause();
    },
  );

  test(
    'Auto-stop preserves Replay and Play continues through adjacent cuts',
    () async {
      await audio.play();
      await position(1050);
      await audio.repeatCurrentSentence();
      expect(audio.positionMs, 0);
      expect(audio.currentSegment?.id, 'a');
      await position(1050);
      await audio.play();
      expect(audio.currentSegment?.id, 'b');
      await position(2200);
      expect(audio.positionMs, 2000);
      expect(audio.currentSegment?.id, 'b');
      await audio.seekTo(2500);
      expect(audio.currentSegment, isNull);
      await audio.play();
      await position(5050);
      expect(audio.positionMs, 5000);
      expect(audio.currentSegment?.id, 'c');
      expect(audio.isPlaying, isFalse);
      await audio.play();
      expect(audio.positionMs, 0);
      await audio.pause();
    },
  );

  test(
    'Native EOF obeys Auto-stop and retains the final cut for Replay',
    () async {
      await audio.seekTo(4500);
      await audio.play();
      nativePosition = 5000;
      await event('audio.onComplete');
      await waitUntil(() => !audio.isPlaying && audio.positionMs == 5000);
      expect(audio.positionMs, 5000);
      expect(audio.currentSegment?.id, 'c');
      expect(audio.isPlaying, isFalse);
      await audio.repeatCurrentSentence();
      expect(audio.positionMs, 3000);
      await audio.pause();
    },
  );

  test('User seek supersedes a pending automatic pause without an old corrective seek', () async {
    await audio.play();
    final pendingPause = Completer<void>();
    pauseGate = pendingPause;
    await position(1100);
    final seeking = audio.seekTo(3500);
    pendingPause.complete();
    await seeking;
    await Future<void>.delayed(Duration.zero);
    expect(audio.positionMs, 3500);
    expect(audio.currentSegment?.id, 'c');
    expect(
      calls
          .where((c) => c.method == 'seek')
          .map((c) => c.arguments['position']),
      [3500],
    );
  });

  test('User pause during a loop seek prevents the loop resuming', () async {
    audio.toggleRepeatOne();
    audio.toggleAutoStop();
    await audio.play();
    final pendingSeek = Completer<void>();
    seekGate = pendingSeek;
    calls.clear();
    await position(1100);
    final pausing = audio.pause();
    pendingSeek.complete();
    await pausing;
    await Future<void>.delayed(Duration.zero);
    expect(audio.isPlaying, isFalse);
    expect(calls.any((c) => c.method == 'resume'), isFalse);
  });

  test('Previous and Next resume the cut selected after Auto-stop', () async {
    await audio.play();
    await position(1100);
    await audio.nextSentence();
    expect(audio.positionMs, 1000);
    expect(audio.currentSegment?.id, 'b');
    await waitUntil(() => audio.isPlaying);
    expect(audio.isPlaying, isTrue);
    await position(2100);
    await audio.previousSentence();
    expect(audio.positionMs, 0);
    expect(audio.currentSegment?.id, 'a');
    await waitUntil(() => audio.isPlaying);
    expect(audio.isPlaying, isTrue);
    await audio.pause();
  });

  test('Manual pause keeps Previous and Next silent', () async {
    await audio.seekTo(1400);
    await audio.play();
    await audio.pause();
    calls.clear();
    await audio.nextSentence();
    expect(audio.currentSegment?.id, 'c');
    expect(audio.isPlaying, isFalse);
    await audio.previousSentence();
    expect(audio.currentSegment?.id, 'b');
    expect(audio.isPlaying, isFalse);
    expect(calls.where((call) => call.method == 'resume'), isEmpty);
  });

  test('Explicit pause after Auto-stop cancels navigation autoplay', () async {
    await audio.play();
    await position(1100);
    await audio.pause();
    calls.clear();
    await audio.nextSentence();
    expect(audio.currentSegment?.id, 'b');
    expect(audio.isPlaying, isFalse);
    expect(calls.where((call) => call.method == 'resume'), isEmpty);
  });

  test('Scrubbing after Auto-stop keeps later navigation silent', () async {
    await audio.play();
    await position(1100);
    await audio.beginScrub();
    await audio.seekTo(1400);
    await audio.endScrub();
    await audio.nextSentence();
    expect(audio.currentSegment?.id, 'c');
    expect(audio.isPlaying, isFalse);
  });

  test('Next resumes after an in-flight automatic pause completes', () async {
    await audio.play();
    final pendingPause = Completer<void>();
    pauseGate = pendingPause;
    await position(1100);
    calls.clear();
    final navigating = audio.nextSentence();
    pendingPause.complete();
    await navigating;
    expect(audio.positionMs, 1000);
    expect(audio.currentSegment?.id, 'b');
    await waitUntil(() => audio.isPlaying);
    expect(audio.isPlaying, isTrue);
    expect(
      calls
          .where((call) => call.method == 'seek')
          .map((call) => call.arguments['position']),
      [1000],
    );
    await audio.pause();
  });

  test('Pause during navigation seek prevents autoplay', () async {
    await audio.play();
    await position(1100);
    final pendingSeek = Completer<void>();
    seekGate = pendingSeek;
    calls.clear();
    final navigating = audio.nextSentence();
    await waitUntil(() => seekGate == null);
    await audio.pause();
    pendingSeek.complete();
    await navigating;
    expect(audio.currentSegment?.id, 'b');
    expect(audio.isPlaying, isFalse);
    expect(calls.where((call) => call.method == 'resume'), isEmpty);
  });

  test(
    'Clearing the lesson during navigation seek prevents autoplay',
    () async {
      await audio.play();
      await position(1100);
      final pendingSeek = Completer<void>();
      seekGate = pendingSeek;
      calls.clear();
      final navigating = audio.nextSentence();
      await waitUntil(() => seekGate == null);
      await audio.clearLesson();
      pendingSeek.complete();
      await navigating;
      expect(audio.currentLesson, isNull);
      expect(audio.isPlaying, isFalse);
      expect(calls.where((call) => call.method == 'resume'), isEmpty);
    },
  );

  test('Rapid Next presses resume only the last selected segment', () async {
    await audio.play();
    await position(1100);
    final pendingSeek = Completer<void>();
    seekGate = pendingSeek;
    calls.clear();
    final firstNavigation = audio.nextSentence();
    await waitUntil(() => seekGate == null);
    final secondNavigation = audio.nextSentence();
    pendingSeek.complete();
    await Future.wait([firstNavigation, secondNavigation]);
    expect(audio.currentSegment?.id, 'c');
    expect(audio.positionMs, 3000);
    await waitUntil(() => audio.isPlaying);
    expect(audio.isPlaying, isTrue);
    expect(calls.where((call) => call.method == 'resume'), hasLength(1));
    await audio.pause();
  });

  test('Disabling Auto-stop clears navigation autoplay', () async {
    await audio.play();
    await position(1100);
    audio.toggleAutoStop();
    await audio.nextSentence();
    expect(audio.currentSegment?.id, 'b');
    expect(audio.isPlaying, isFalse);
  });

  test(
    'Slow timer query cannot overlap or stop a cut selected by a later seek',
    () async {
      await audio.play();
      final pendingPosition = Completer<int>();
      positionGate = pendingPosition;
      await waitUntil(() => positionGate == null);
      final pendingQueryCount = calls
          .where((call) => call.method == 'getCurrentPosition')
          .length;
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(
        calls.where((call) => call.method == 'getCurrentPosition').length,
        pendingQueryCount,
        reason:
            'Timer ticks must not start overlapping native position queries',
      );
      await audio.seekTo(3500);
      pendingPosition.complete(1100);
      await waitUntil(
        () =>
            calls.where((call) => call.method == 'getCurrentPosition').length >
            pendingQueryCount,
      );
      expect(audio.positionMs, 3500);
      expect(audio.currentSegment?.id, 'c');
      expect(audio.isPlaying, isTrue);
      await audio.pause();
    },
  );

  test('Timer polling stops while paused and restarts on Play', () async {
    await audio.play();
    await position(400);
    await audio.pause();
    final pausedQueryCount = calls
        .where((call) => call.method == 'getCurrentPosition')
        .length;
    await Future<void>.delayed(const Duration(milliseconds: 130));
    expect(
      calls.where((call) => call.method == 'getCurrentPosition').length,
      pausedQueryCount,
    );
    await audio.play();
    await position(1100);
    expect(audio.positionMs, 1000);
    expect(audio.isPlaying, isFalse);
  });

  test(
    'Lesson switch supersedes an automatic pause and clears its selected cut',
    () async {
      await audio.play();
      final pendingPause = Completer<void>();
      pauseGate = pendingPause;
      await position(1100);
      final nextLesson = AudioLesson(
        id: 'next',
        title: 'Next',
        originalFileName: lesson.originalFileName,
        localPath: lesson.localPath,
        durationMs: 5000,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );
      final loading = audio.loadLesson(nextLesson, const [
        AudioSegment(
          id: 'new',
          lessonId: 'next',
          startMs: 0,
          endMs: 5000,
          text: '',
        ),
      ]);
      pendingPause.complete();
      await loading;
      expect(audio.currentLesson?.id, 'next');
      expect(audio.positionMs, 0);
      expect(audio.currentSegment?.id, 'new');
      expect(audio.isPlaying, isFalse);
      expect(calls.where((c) => c.method == 'seek'), isEmpty);
    },
  );
}
