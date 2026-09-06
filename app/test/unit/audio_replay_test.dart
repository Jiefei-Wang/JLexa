import 'dart:io';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/audio/audio_models.dart';
import 'package:jlexa/core/audio/audio_service.dart';

import '../test_helper.dart';

void main() {
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
