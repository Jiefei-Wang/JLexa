import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jlexa/core/ai/model_catalog.dart';
import 'package:jlexa/core/ai/model_downloader.dart';
import 'package:jlexa/core/ai/model_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.jlexa.app/saf_storage');
  const events = MethodChannel('com.jlexa.app/saf_download_stream');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AndroidSafModelStorageBackend backend;
  late List<MethodCall> calls;
  late List<String> streamCalls;

  Future<void> send(String requestId, String type) async {
    await messenger.handlePlatformMessage(
      events.name,
      codec.encodeSuccessEnvelope({
        'requestId': requestId,
        'type': type,
        'bytesReceived': 64,
        'totalBytes': 128,
      }),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  List<String> launchedIds() => calls
      .where((call) => call.method == 'downloadFile')
      .map((call) => (call.arguments as Map)['requestId'] as String)
      .toList();

  Future<void> startSettled() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    calls = [];
    streamCalls = [];
    messenger.setMockMethodCallHandler(events, (call) async {
      streamCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'restorePersistedFolderAccess') {
        return {'treeUri': 'content://models/tree', 'displayName': 'Models'};
      }
      return null;
    });
    backend = AndroidSafModelStorageBackend.forTesting();
    expect(await backend.restorePersistedFolderAccess(), isTrue);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test(
    'Concurrent downloads share one native stream and cancel independently',
    () async {
      final firstModel = ModelCatalog.curatedLlmModels.first;
      final secondModel = ModelCatalog.curatedWhisperModels.first;
      final firstProgress = <ModelProgress>[];
      final secondProgress = <ModelProgress>[];
      final first = backend.download(
        model: firstModel,
        destinationPartLocation: 'content://models/first.part',
        onProgress: firstProgress.add,
      );
      final firstResult = expectLater(
        first,
        throwsA(isA<ModelDownloadCancelledException>()),
      );
      final second = backend.download(
        model: secondModel,
        destinationPartLocation: 'content://models/second.part',
        onProgress: secondProgress.add,
      );
      await startSettled();
      final ids = launchedIds();
      expect(ids, hasLength(2));
      expect(streamCalls, ['listen']);
      await send(ids[0], 'progress');
      await send(ids[1], 'progress');
      expect(firstProgress, hasLength(1));
      expect(secondProgress, hasLength(1));

      backend.cancelDownload(firstModel.id);
      await startSettled();
      expect(backend.isDownloading(firstModel.id), isTrue);
      expect(streamCalls, ['listen']);
      expect(
        (calls.singleWhere((call) => call.method == 'cancelDownload').arguments
            as Map)['requestId'],
        ids[0],
      );
      await send(ids[0], 'progress');
      expect(firstProgress, hasLength(1));
      await send(ids[0], 'cancelled');
      await firstResult;
      expect(backend.isDownloading(firstModel.id), isFalse);
      expect(backend.isDownloading(secondModel.id), isTrue);
      expect(streamCalls, ['listen']);

      await send(ids[1], 'progress');
      expect(secondProgress, hasLength(2));
      await send(ids[1], 'done');
      await second;
      expect(streamCalls, ['listen', 'cancel']);
      expect(backend.isDownloading(secondModel.id), isFalse);
    },
  );

  test(
    'Retry uses a fresh request ID and rejects stale terminal events',
    () async {
      final model = ModelCatalog.curatedLlmModels.first;
      final first = backend.download(
        model: model,
        destinationPartLocation: 'content://models/model.part',
        onProgress: (_) {},
      );
      final firstResult = expectLater(
        first,
        throwsA(isA<ModelDownloadCancelledException>()),
      );
      await startSettled();
      final oldId = launchedIds().single;
      backend.cancelDownload(model.id);
      await expectLater(
        backend.download(
          model: model,
          destinationPartLocation: 'content://models/model.part',
          onProgress: (_) {},
        ),
        throwsA(isA<ModelDownloadException>()),
      );
      await send(oldId, 'cancelled');
      await firstResult;

      var secondCompleted = false;
      final second = backend
          .download(
            model: model,
            destinationPartLocation: 'content://models/model.part',
            onProgress: (_) {},
          )
          .then((_) => secondCompleted = true);
      await startSettled();
      final newId = launchedIds().last;
      expect(newId, isNot(oldId));
      await send(oldId, 'done');
      await send(oldId, 'cancelled');
      expect(secondCompleted, isFalse);
      expect(backend.isDownloading(model.id), isTrue);
      await send(newId, 'done');
      await second;
      expect(secondCompleted, isTrue);
    },
  );

  test(
    'Native launch rejection releases download and stream ownership',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'downloadFile') {
          throw PlatformException(code: 'NO_ACCESS');
        }
        return null;
      });
      final model = ModelCatalog.curatedLlmModels.first;
      await expectLater(
        backend.download(
          model: model,
          destinationPartLocation: 'content://models/model.part',
          onProgress: (_) {},
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(backend.isDownloading(model.id), isFalse);
      expect(streamCalls, ['listen', 'cancel']);
    },
  );

  test(
    'Folder permission failure is reported instead of treated as cancellation',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'SAF_PERMISSION_ERROR',
          message: 'Read only',
        );
      });
      await expectLater(
        backend.chooseBaseFolder(),
        throwsA(
          isA<ModelValidationException>().having(
            (error) => error.message,
            'message',
            contains('Read only'),
          ),
        ),
      );
      expect(backend.baseLocationUriOrPath, 'content://models/tree');
    },
  );
}
