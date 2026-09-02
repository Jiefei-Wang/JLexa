import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void setupMockPlatformChannels() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Mock flutter_tts
  messenger.setMockMethodCallHandler(
    const MethodChannel('flutter_tts'),
    (MethodCall call) async => 1,
  );

  // Mock audioplayers method channels
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (MethodCall call) async {
      if (call.arguments is Map &&
          (call.arguments as Map)['playerId'] != null) {
        final playerId = (call.arguments as Map)['playerId'] as String;
        messenger.setMockMessageHandler(
          'xyz.luan/audioplayers/events/$playerId',
          (ByteData? message) async {
            return const StandardMethodCodec().encodeSuccessEnvelope(null);
          },
        );

        if (call.method.startsWith('setSource')) {
          Future.microtask(() {
            messenger.handlePlatformMessage(
              'xyz.luan/audioplayers/events/$playerId',
              const StandardMethodCodec().encodeSuccessEnvelope({
                'event': 'audio.onPrepared',
                'value': true,
              }),
              (data) {},
            );
          });
        } else if (call.method == 'seek') {
          Future.microtask(() {
            messenger.handlePlatformMessage(
              'xyz.luan/audioplayers/events/$playerId',
              const StandardMethodCodec().encodeSuccessEnvelope({
                'event': 'audio.onSeekComplete',
                'value': true,
              }),
              (data) {},
            );
          });
        }
      }
      return 1;
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (MethodCall call) async => 1,
  );

  // Mock all audioplayer and native binary messages to prevent MissingPluginException
  messenger.setMockMessageHandler('xyz.luan/audioplayers.global/events', (
    ByteData? message,
  ) async {
    return const StandardMethodCodec().encodeSuccessEnvelope(null);
  });
  messenger.setMockMessageHandler('com.jlexa.app/llama_stream', (
    ByteData? message,
  ) async {
    return const StandardMethodCodec().encodeSuccessEnvelope(null);
  });
  messenger.setMockMessageHandler('com.jlexa.app/whisper_stream', (
    ByteData? message,
  ) async {
    return const StandardMethodCodec().encodeSuccessEnvelope(null);
  });

  // Mock record
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (MethodCall call) async {
      if (call.method == 'hasPermission') return true;
      return null;
    },
  );

  // Mock JLexa native channels
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.jlexa.app/llama'),
    (MethodCall call) async => false,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.jlexa.app/whisper'),
    (MethodCall call) async => false,
  );

  // Mock path_provider
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async {
      return Directory.systemTemp.path;
    },
  );
}
