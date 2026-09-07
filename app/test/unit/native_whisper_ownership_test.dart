import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/ai_models.dart';
import 'package:jlexa/core/ai/native_ai_bridge.dart';
import 'package:jlexa/core/audio/audio_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methodChannel = MethodChannel('com.jlexa.app/whisper');
  const events = MethodChannel('com.jlexa.app/whisper_stream');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late NativeWhisperEngine engine;
  late List<MethodCall> calls;
  late Map<String, Completer<List<Map<String, dynamic>>>> nativeResults;
  Completer<void>? unloadGate;
  bool cancelFails = false;

  Future<void> turn() => Future<void>.delayed(Duration.zero);
  List<Map<String, dynamic>> result(String id, String text) => [
    AudioSegment(
      id: id,
      lessonId: 'lesson',
      startMs: 1000,
      endMs: 2000,
      text: text,
    ).toMap(),
  ];
  List<MethodCall> getTranscriptions() =>
      calls.where((call) => call.method == 'transcribeAudio').toList();
  Future<List<AudioSegment>> cut(
    String id, {
    int start = 1000,
    int end = 2000,
    int revision = 1,
    void Function(double)? onProgress,
  }) => engine.transcribeCut(
    audioPath: '/lesson.mp3',
    lessonId: 'lesson',
    cutId: 'cut-$id',
    cutRevision: revision,
    startMs: start,
    endMs: end,
    modelId: 'tiny.bin',
    requestId: id,
    onProgress: onProgress,
  );
  Future<List<AudioSegment>> voice(
    String id, {
    void Function(double)? onProgress,
  }) => engine.transcribeAudio(
    audioPath: '/voice.wav',
    lessonId: 'voice_input',
    requestId: id,
    onProgress: onProgress,
  );
  Future<void> progress(String id, double value) async {
    await messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'requestId': id,
        'type': 'progress',
        'progress': value,
      }),
      (_) {},
    );
    await turn();
  }

  setUp(() async {
    calls = [];
    nativeResults = {};
    unloadGate = null;
    cancelFails = false;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      calls.add(call);
      if (call.method == 'loadModel') return true;
      if (call.method == 'transcribeAudio') {
        final id = (call.arguments as Map)['requestId'] as String;
        final pending = Completer<List<Map<String, dynamic>>>();
        nativeResults[id] = pending;
        return pending.future;
      }
      if (call.method == 'cancelTranscription' && cancelFails) {
        throw PlatformException(code: 'CANCEL_FAILED');
      }
      if (call.method == 'unloadModel') await unloadGate?.future;
      return null;
    });
    engine = NativeWhisperEngine.forTesting();
    await engine.loadModel('tiny.bin');
    await turn();
  });
  tearDown(() async {
    engine.dispose();
    await turn();
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test(
    'competing voice cannot steal Listening progress or cancellation ownership',
    () async {
      final listeningProgress = <double>[];
      final voiceProgress = <double>[];
      final listening = cut('listening', onProgress: listeningProgress.add);
      await turn();
      await expectLater(
        voice('voice', onProgress: voiceProgress.add),
        throwsA(isA<AiBusyException>()),
      );
      expect(getTranscriptions(), hasLength(1));
      expect(voiceProgress, isEmpty);
      await progress('voice', .9);
      await progress('listening', .4);
      expect(listeningProgress, [0, .4]);
      await engine.cancelRequest('voice');
      expect(
        calls.where((call) => call.method == 'cancelTranscription'),
        isEmpty,
      );

      final cancelledListening = expectLater(
        listening,
        throwsA(isA<AiCancelledException>()),
      );
      await engine.cancelRequest('listening');
      expect(calls.last.arguments, {'requestId': 'listening'});
      await progress('listening', .8);
      nativeResults['listening']!.complete(
        result('listening', 'late cancelled text'),
      );
      await cancelledListening;
      expect(listeningProgress, [0, .4]);

      final retry = voice('voice-retry', onProgress: voiceProgress.add);
      await turn();
      final args = getTranscriptions().last.arguments as Map;
      expect(args['audioPath'], '/voice.wav');
      expect(args.containsKey('cutId'), isFalse);
      expect(args.containsKey('cutStartMs'), isFalse);
      await engine.cancelRequest('listening');
      await progress('listening', 1);
      await progress('voice-retry', .6);
      expect(voiceProgress, [0, .6]);
      nativeResults['voice-retry']!.complete(
        result('voice', 'actual voice text'),
      );
      expect((await retry).single.text, 'actual voice text');
      expect(voiceProgress, [0, .6, 1]);
    },
  );

  test('cancellation acknowledgement keeps the slot until terminal and cut args never leak', () async {
    final original = cut('A', start: 3000, end: 5000, revision: 7);
    final originalCancelled = expectLater(
      original,
      throwsA(isA<AiCancelledException>()),
    );
    await turn();
    await engine.cancelRequest('A');
    await Future.wait([
      expectLater(
        cut('B', start: 6000, end: 8000, revision: 8),
        throwsA(isA<AiBusyException>()),
      ),
      expectLater(
        cut('C', start: 9000, end: 11000),
        throwsA(isA<AiBusyException>()),
      ),
      expectLater(voice('waiting-voice'), throwsA(isA<AiBusyException>())),
    ]);
    expect(getTranscriptions(), hasLength(1));
    nativeResults['A']!.completeError(PlatformException(code: 'CANCELLED'));
    await originalCancelled;
    final retry = cut('B', start: 6000, end: 8000, revision: 8);
    await turn();
    final args = getTranscriptions().last.arguments as Map;
    expect(args['cutId'], 'cut-B');
    expect(args['cutStartMs'], 6000);
    expect(args['cutEndMs'], 8000);
    expect(args['cutRevision'], 8);
    await expectLater(voice('B'), throwsA(isA<AiBusyException>()));
    nativeResults['B']!.complete(result('B', 'new cut'));
    expect((await retry).single.text, 'new cut');
  });

  test('reentrant progress cannot replace cut args and cancellation before dispatch starts no native work', () async {
    Future<void>? rejected;
    final pending = cut(
      'outer',
      start: 12000,
      end: 15000,
      onProgress: (value) {
        if (value == 0) {
          rejected = expectLater(
            cut('inner', start: 20000, end: 21000),
            throwsA(isA<AiBusyException>()),
          );
        }
      },
    );
    await turn();
    await rejected;
    expect(getTranscriptions(), hasLength(1));
    expect((getTranscriptions().single.arguments as Map)['cutStartMs'], 12000);
    nativeResults['outer']!.complete(result('outer', 'correct bounds'));
    await pending;
    await expectLater(
      voice(
        'cancel-before-native',
        onProgress: (value) {
          if (value == 0) {
            unawaited(engine.cancelRequest('cancel-before-native'));
          }
        },
      ),
      throwsA(isA<AiCancelledException>()),
    );
    expect(getTranscriptions(), hasLength(1));
  });

  test('failed native cancellation still rejects late results and never sends blanket or stale cancellation', () async {
    cancelFails = true;
    final pending = voice('first');
    final cancelled = expectLater(
      pending,
      throwsA(isA<AiCancelledException>()),
    );
    await turn();
    await engine.cancel();
    await engine.cancelRequest('first');
    expect(
      calls.where((call) => call.method == 'cancelTranscription'),
      hasLength(1),
    );
    expect(calls.last.arguments, {'requestId': 'first'});
    await expectLater(voice('too-soon'), throwsA(isA<AiBusyException>()));
    nativeResults['first']!.complete(result('first', 'native ignored cancel'));
    await cancelled;
    await engine.cancel();
    await engine.cancelRequest('first');
    expect(
      calls.where((call) => call.method == 'cancelTranscription'),
      hasLength(1),
    );
  });

  test('model unload waits for terminal work and blocks requests throughout model mutation', () async {
    final pending = cut('listening');
    final cancelled = expectLater(
      pending,
      throwsA(isA<AiCancelledException>()),
    );
    await turn();
    unloadGate = Completer<void>();
    final unloading = engine.unload();
    await turn();
    expect(calls.where((call) => call.method == 'unloadModel'), isEmpty);
    await expectLater(
      voice('before-terminal'),
      throwsA(isA<AiBusyException>()),
    );
    nativeResults['listening']!.complete(result('listening', 'late result'));
    await cancelled;
    await turn();
    expect(calls.where((call) => call.method == 'unloadModel'), hasLength(1));
    await expectLater(voice('during-unload'), throwsA(isA<AiBusyException>()));
    await expectLater(
      engine.loadModel('other.bin'),
      throwsA(isA<AiBusyException>()),
    );
    unloadGate!.complete();
    await unloading;
    expect(engine.isLoaded, isFalse);
    await expectLater(
      voice('unloaded'),
      throwsA(isA<AiModelNotLoadedException>()),
    );
    await engine.loadModel('other.bin');
    final next = voice('after-load');
    await turn();
    nativeResults['after-load']!.complete(result('voice', 'new model'));
    expect((await next).single.text, 'new model');
  });

  test(
    'native and progress callback failures release the request slot',
    () async {
      final failed = voice('bad-audio');
      final failure = expectLater(failed, throwsA(isA<PlatformException>()));
      await turn();
      nativeResults['bad-audio']!.completeError(
        PlatformException(code: 'DECODE_ERROR'),
      );
      await failure;
      await expectLater(
        voice(
          'bad-callback',
          onProgress: (_) => throw StateError('callback failed'),
        ),
        throwsStateError,
      );
      final next = voice('recovered');
      await turn();
      expect(getTranscriptions(), hasLength(2));
      nativeResults['recovered']!.complete(result('recovered', 'usable again'));
      expect((await next).single.text, 'usable again');
    },
  );
}
