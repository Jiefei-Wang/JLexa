import 'dart:io';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/audio_service.dart';

import '../test_helper.dart';

void main() {
  test(
    'Previous selects the preceding cut while Replay restarts the active cut',
    () async {
      final calls = <MethodCall>[];
      setupMockPlatformChannels(onAudioCall: calls.add);
      final audio = AudioService();
      addTearDown(audio.dispose);
      final directory = await Directory.systemTemp.createTemp(
        'jlexa-navigation-',
      );
      final file = await File('${directory.path}/sample.wav').writeAsBytes([0]);
      addTearDown(() => directory.delete(recursive: true));
      final lesson = AudioLesson(
        id: 'cut-navigation',
        title: 'Navigation',
        originalFileName: 'sample.wav',
        localPath: file.path,
        durationMs: 6000,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );
      await audio.loadLesson(lesson, const [
        AudioSegment(
          id: 'a',
          lessonId: 'cut-navigation',
          startMs: 0,
          endMs: 1500,
          text: '',
        ),
        AudioSegment(
          id: 'b',
          lessonId: 'cut-navigation',
          startMs: 2000,
          endMs: 3500,
          text: '',
        ),
        AudioSegment(
          id: 'c',
          lessonId: 'cut-navigation',
          startMs: 4000,
          endMs: 6000,
          text: '',
        ),
      ]);
      for (final position in [2000, 2800]) {
        await audio.seekTo(position);
        await audio.previousSentence();
        expect(audio.currentSegment?.id, 'a');
        expect(audio.positionMs, 0);
      }
      await audio.seekTo(3800);
      await audio.previousSentence();
      expect(audio.currentSegment?.id, 'b');
      await audio.seekTo(6000);
      await audio.previousSentence();
      expect(audio.currentSegment?.id, 'c');
      await audio.seekTo(0);
      await audio.previousSentence();
      expect(audio.positionMs, 0);

      for (final repeat in [false, true]) {
        // The mock channel returns 1 for player queries after resume; reload
        // supplies the fixture duration before checking the next replay.
        await audio.loadLesson(lesson, audio.segments);
        if (audio.isRepeatOne != repeat) audio.toggleRepeatOne();
        await audio.seekTo(2800);
        calls.clear();
        await audio.repeatCurrentSentence();
        expect(
          calls
              .firstWhere((call) => call.method == 'seek')
              .arguments['position'],
          2000,
        );
        expect(audio.isRepeatOne, repeat);
        expect(calls.any((call) => call.method == 'resume'), isTrue);
      }
    },
  );

  test(
    'EOF retains source and replay seeks to the beginning before resume',
    () async {
      final calls = <MethodCall>[];
      late AudioService audio;
      var pauseDuringSeek = false;
      setupMockPlatformChannels(
        onAudioCall: (call) {
          calls.add(call);
          if (pauseDuringSeek && call.method == 'seek') {
            unawaited(audio.pause());
          }
        },
      );
      final directory = await Directory.systemTemp.createTemp('jlexa-replay-');
      final file = await File('${directory.path}/sample.wav').writeAsBytes([0]);
      audio = AudioService();
      addTearDown(() async {
        audio.dispose();
        await directory.delete(recursive: true);
      });
      final lesson = AudioLesson(
        id: 'replay',
        title: 'Replay',
        originalFileName: 'sample.wav',
        localPath: file.path,
        durationMs: 1000,
        createdAt: DateTime.now(),
        lastOpenedAt: DateTime.now(),
      );
      await audio.loadLesson(lesson, []);
      expect(
        calls
            .firstWhere((c) => c.method == 'setReleaseMode')
            .arguments['releaseMode'],
        'ReleaseMode.stop',
      );
      final playerId = calls
          .firstWhere((c) => c.method == 'create')
          .arguments['playerId'];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        'xyz.luan/audioplayers/events/$playerId',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'audio.onComplete',
        }),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(audio.positionMs, audio.durationMs);
      expect(audio.positionMs, greaterThan(0));
      calls.clear();
      await audio.play();
      final seekIndex = calls.indexWhere((c) => c.method == 'seek');
      final resumeIndex = calls.indexWhere((c) => c.method == 'resume');
      expect(seekIndex, greaterThanOrEqualTo(0));
      expect(resumeIndex, greaterThan(seekIndex));
      expect(calls[seekIndex].arguments['position'], 0);

      audio.updateSegments([
        AudioSegment(
          id: 'last',
          lessonId: lesson.id,
          startMs: 0,
          endMs: 1000,
          text: '',
        ),
      ]);
      audio.toggleRepeatOne();
      calls.clear();
      pauseDuringSeek = true;
      await messenger.handlePlatformMessage(
        'xyz.luan/audioplayers/events/$playerId',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'audio.onComplete',
        }),
        (_) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls.any((c) => c.method == 'pause'), isTrue);
      expect(
        calls.any((c) => c.method == 'resume'),
        isFalse,
        reason: 'A loop seek must never resume over a user pause',
      );
    },
  );
}
