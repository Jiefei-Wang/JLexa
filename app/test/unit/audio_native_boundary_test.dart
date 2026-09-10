import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/audio_service.dart';

import '../test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('xyz.luan/audioplayers');
  late AudioService audio;
  late Directory directory;
  late List<MethodCall> calls;
  late String playerId;
  var nativePosition = 0;
  Completer<void>? clipGate;
  Completer<void>? seekGate;
  var rejectClip = false;

  Future<void> event(String name) async {
    await messenger.handlePlatformMessage(
      'xyz.luan/audioplayers/events/$playerId',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': name,
        if (name == 'audio.onPrepared') 'value': true,
      }),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> until(bool Function() done) async {
    final watch = Stopwatch()..start();
    while (!done()) {
      if (watch.elapsedMilliseconds > 2000) fail('Native work timed out');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(Duration.zero);
  }

  const cuts = [
    AudioSegment(id: 'a', lessonId: 'l', startMs: 0, endMs: 1000, text: ''),
    AudioSegment(id: 'b', lessonId: 'l', startMs: 1000, endMs: 2500, text: ''),
    AudioSegment(id: 'c', lessonId: 'l', startMs: 3000, endMs: 4000, text: ''),
  ];

  setUp(() async {
    setupMockPlatformChannels();
    calls = [];
    nativePosition = 0;
    rejectClip = false;
    clipGate = null;
    seekGate = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map;
      playerId = args['playerId'] as String;
      switch (call.method) {
        case 'create':
          messenger.setMockMessageHandler(
            'xyz.luan/audioplayers/events/$playerId',
            (_) async =>
                const StandardMethodCodec().encodeSuccessEnvelope(null),
          );
        case 'setSourceUrl':
          scheduleMicrotask(() => event('audio.onPrepared'));
        case 'setPlaybackEnd':
          if (rejectClip) throw PlatformException(code: 'clip_failed');
          await clipGate?.future;
        case 'seek':
          nativePosition = args['position'] as int;
          await seekGate?.future;
          scheduleMicrotask(() => event('audio.onSeekComplete'));
        case 'getCurrentPosition':
          return nativePosition;
        case 'getDuration':
          return 5000;
      }
      return null;
    });
    directory = await Directory.systemTemp.createTemp('jlexa-native-end-');
    final file = await File('${directory.path}/audio.wav').writeAsBytes([0]);
    audio = AudioService(nativeClipping: true);
    await audio.loadLesson(
      AudioLesson(
        id: 'l',
        title: 'Native cut',
        originalFileName: 'audio.wav',
        localPath: file.path,
        durationMs: 5000,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      ),
      cuts,
    );
  });

  tearDown(() async {
    clipGate?.complete();
    clipGate = null;
    seekGate?.complete();
    seekGate = null;
    audio.dispose();
    await Future<void>.delayed(Duration.zero);
    await directory.delete(recursive: true);
  });

  test(
    'Native completion owns the boundary, not a late position poll',
    () async {
      expect(
        calls.lastWhere((c) => c.method == 'setPlaybackEnd').arguments['endMs'],
        1000,
      );
      await audio.play();
      calls.clear();
      nativePosition = 1030;
      await until(() => calls.any((c) => c.method == 'getCurrentPosition'));
      expect(audio.currentSegment?.id, 'a');
      expect(audio.isPlaying, isTrue);
      expect(calls.where((c) => c.method == 'pause'), isEmpty);
      expect(calls.where((c) => c.method == 'setPlaybackEnd'), isEmpty);
      await event('audio.onComplete');
      await until(() => calls.any((c) => c.method == 'seek'));
      expect(audio.isPlaying, isFalse);
      expect(audio.positionMs, 1000);
      expect(audio.currentSegment?.id, 'a');
      expect(audio.durationMs, 5000);
    },
  );

  test(
    'Next awaits the new clip before seeking and resuming after Auto-stop',
    () async {
      await audio.play();
      await event('audio.onComplete');
      await until(
        () => !audio.isPlaying && calls.any((c) => c.method == 'seek'),
      );
      clipGate = Completer<void>();
      calls.clear();
      final navigation = audio.nextSentence();
      await until(() => calls.any((c) => c.method == 'setPlaybackEnd'));
      expect(
        calls.where((c) => c.method == 'resume' || c.method == 'seek'),
        isEmpty,
      );
      expect(calls.last.arguments['endMs'], 2500);
      expect(calls.last.arguments['positionMs'], 1000);
      clipGate!.complete();
      clipGate = null;
      await navigation;
      await until(() => audio.isPlaying);
      expect(audio.currentSegment?.id, 'b');
      expect(audio.positionMs, 1000);
      await audio.pause();
    },
  );

  test(
    'A Pause while native clipping prepares cannot be undone by Next',
    () async {
      await audio.play();
      await event('audio.onComplete');
      await until(
        () => !audio.isPlaying && calls.any((c) => c.method == 'seek'),
      );
      clipGate = Completer<void>();
      calls.clear();
      final navigation = audio.nextSentence();
      await until(() => calls.any((c) => c.method == 'setPlaybackEnd'));
      await audio.pause();
      clipGate!.complete();
      clipGate = null;
      await navigation;
      expect(audio.isPlaying, isFalse);
      expect(calls.where((c) => c.method == 'resume'), isEmpty);
    },
  );

  for (final repeat in [false, true]) {
    test('Native auto-pause then Play, repeat=$repeat', () async {
      if (repeat) audio.toggleRepeatOne();
      await audio.play();
      await event('audio.onComplete');
      await until(
        () => !audio.isPlaying && calls.any((c) => c.method == 'seek'),
      );
      expect(audio.positionMs, 1000);
      calls.clear();
      await audio.play();
      await until(() => audio.isPlaying);
      expect(audio.positionMs, repeat ? 0 : 1000);
      expect(audio.currentSegment?.id, repeat ? 'a' : 'b');
      if (!repeat) {
        final clip = calls.firstWhere((c) => c.method == 'setPlaybackEnd');
        expect(clip.arguments['endMs'], 2500);
        expect(clip.arguments['positionMs'], 1000);
        expect(
          calls.indexOf(clip),
          lessThan(calls.indexWhere((c) => c.method == 'resume')),
        );
      }
      await audio.pause();
    });
  }

  test('Continuous playback clears the clip, repeat restores it', () async {
    calls.clear();
    audio.toggleAutoStop();
    await audio.play();
    expect(
      calls.firstWhere((c) => c.method == 'setPlaybackEnd').arguments['endMs'],
      isNull,
    );
    audio.toggleRepeatOne();
    await until(
      () =>
          calls
              .lastWhere((c) => c.method == 'setPlaybackEnd')
              .arguments['endMs'] ==
          1000,
    );
    calls.clear();
    await event('audio.onComplete');
    await until(() => calls.any((c) => c.method == 'resume'));
    expect(
      calls.firstWhere((c) => c.method == 'seek').arguments['position'],
      0,
    );
    expect(audio.isPlaying, isTrue);
    await audio.pause();
  });

  test(
    'Editing a live endpoint preserves native position instead of rewinding',
    () async {
      await audio.play();
      calls.clear();
      audio.updateSegments([cuts[0].copyWith(endMs: 900), ...cuts.skip(1)]);
      await until(() => calls.any((c) => c.method == 'setPlaybackEnd'));
      final args = calls
          .firstWhere((c) => c.method == 'setPlaybackEnd')
          .arguments;
      expect(args['endMs'], 900);
      expect(args['positionMs'], isNull);
      expect(calls.where((c) => c.method == 'seek'), isEmpty);
      await audio.pause();
    },
  );

  test('Starting in a gap clips at the following cut end', () async {
    await audio.seekTo(2700);
    expect(audio.currentSegment, isNull);
    expect(
      calls.lastWhere((c) => c.method == 'setPlaybackEnd').arguments['endMs'],
      4000,
    );
    await audio.play();
    await event('audio.onComplete');
    await until(() => audio.positionMs == 4000 && !audio.isPlaying);
    expect(audio.currentSegment?.id, 'c');
  });

  test('Clip setup failure stops playback and exposes an error', () async {
    await audio.play();
    rejectClip = true;
    await audio.nextSentence();
    expect(audio.isPlaying, isFalse);
    expect(audio.hasLoadError, isTrue);
    expect(audio.loadErrorMessage, contains('playback boundary'));
  });

  test('Disabling Repeat during its pending seek continues playback', () async {
    audio.toggleAutoStop();
    audio.toggleRepeatOne();
    await audio.play();
    seekGate = Completer<void>();
    calls.clear();
    await event('audio.onComplete');
    await until(() => calls.any((c) => c.method == 'seek'));
    audio.toggleRepeatOne();
    seekGate!.complete();
    seekGate = null;
    await until(() => calls.any((c) => c.method == 'resume'));
    expect(audio.isPlaying, isTrue);
    expect(audio.isRepeatOne, isFalse);
    expect(
      calls.lastWhere((c) => c.method == 'setPlaybackEnd').arguments['endMs'],
      isNull,
    );
    await audio.pause();
  });
}
