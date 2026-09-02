import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:livelens/bridge.dart';
import 'package:livelens/src/app/app_controller.dart';
import 'package:livelens/src/app/screens.dart';
import 'package:livelens/src/data/datetime_adapter.dart';
import 'package:livelens/src/data/models.dart';
import 'package:livelens/src/data/repositories.dart';

/// The one registry entry the native mock reports (E-01 shape, additive
/// extras included).
Map<Object?, Object?> modelWire({
  String id = 'whisper-tiny-int8',
  bool installed = false,
  bool downloadable = true,
}) =>
    <Object?, Object?>{
      'id': id,
      'label': 'Whisper Tiny (INT8)',
      'tier': 'fast',
      'sizeBytes': 47500000,
      'installed': installed,
      'downloadable': downloadable,
      'tasks': ['transcribe', 'translate'],
      'languages': ['en', 'ja', 'ko'],
      'minRamMb': 2048,
    };

Map<Object?, Object?> capsWire({String? activeId, List<Object?>? models}) =>
    <Object?, Object?>{
      'activeModelId': activeId,
      'downloadPath': '/data/models',
      'availableModels': models ?? [modelWire()],
      'sdkInt': 34,
      'device': 'test',
      'playbackCapture': true,
      'deviceTotalRamMb': 8192,
    };

const benchmarkWire = <Object?, Object?>{
  'rounds': 3,
  'chunkSeconds': 5.0,
  'rtf': 0.31,
  'latencyP50Ms': 300.0,
  'latencyP90Ms': 450.0,
  'rssMb': 380.0,
  'batteryPctPerMin': 0.05,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('livelens/control');

  late Directory tempDir;
  late AppController controller;
  late StreamController<ModelDownloadProgress> modelEvents;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('livelens_epic67');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(SessionAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(SegmentAdapter());
    if (!Hive.isAdapterRegistered(30)) {
      Hive.registerAdapter(DateTimeAdapter());
    }

    final sessionBox = await Hive.openBox<Session>('e67_sessions');
    final segmentBox = await Hive.openBox<Segment>('e67_segments');
    final prefsBox = await Hive.openBox<String>('e67_prefs');

    modelEvents = StreamController<ModelDownloadProgress>.broadcast();

    controller = AppController(
      sessions: SessionRepository(sessionBox),
      segments: SegmentRepository(segmentBox),
      prefs: prefsBox,
      eventStream: const Stream.empty(),
      modelEventStream: modelEvents.stream,
    );
  });

  tearDown(() async {
    controller.dispose();
    await modelEvents.close();
    await Hive.close();
    await Hive.deleteFromDisk();
    Hive.resetAdapters();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // -- E-01 registry ----------------------------------------------------------

  group('E-01: refreshCapabilities + language validation (F-01)', () {
    test('parses the registry incl. additive fields and active model',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getCapabilities') {
              return capsWire(activeId: 'whisper-tiny-int8');
            }
            return null;
          });

      await controller.refreshCapabilities();

      expect(controller.capabilitiesError, isNull);
      expect(controller.models, hasLength(1));
      final m = controller.models.single;
      expect(m.id, 'whisper-tiny-int8');
      expect(m.tier, ModelTier.fast);
      expect(m.minRamMb, 2048);
      expect(m.languages, containsAll(['en', 'ja']));
      expect(m.downloadState, DownloadPhase.idle);
      expect(controller.activeModel?.id, 'whisper-tiny-int8');
    });

    test('failure lands in capabilitiesError, never throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getCapabilities') {
              throw PlatformException(code: 'INTERNAL_ERROR');
            }
            return null;
          });

      await controller.refreshCapabilities();

      expect(controller.capabilities, isNull);
      expect(controller.capabilitiesError, isNotNull);
      expect(controller.models, isEmpty);
    });

    test('langSupported: auto always true; installed matrix decides',
        () async {
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => capsWire(models: [modelWire(installed: false)]),
          );
      await controller.refreshCapabilities();

      expect(controller.langSupported('auto'), isTrue);
      expect(controller.langSupported('ja'), isFalse); // not installed

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => capsWire(models: [modelWire(installed: true)]),
          );
      await controller.refreshCapabilities();

      expect(controller.langSupported('ja'), isTrue);
      expect(controller.langSupported('fr'), isFalse); // not in matrix
    });
  });

  // -- E-02 downloads ---------------------------------------------------------

  group('E-02: download lifecycle', () {
    test('downloadModel sends the frozen envelope', () async {
      final methods = <String>[];
      final args = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            args.add(call.arguments);
            return call.method == 'downloadModel' ? true : null;
          });

      final err = await controller.downloadModel('whisper-tiny-int8');

      expect(err, isNull);
      expect(methods, ['downloadModel']);
      expect(args.single, {'modelId': 'whisper-tiny-int8'});
    });

    test('progress events flow through the additive channel', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'downloadModel' ? true : null,
          );
      await controller.downloadModel('whisper-tiny-int8');

      modelEvents.add(
        const ModelDownloadProgress(
          modelId: 'whisper-tiny-int8',
          state: DownloadPhase.downloading,
          bytesDone: 1024,
          bytesTotal: 4096,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final p = controller.downloadProgressFor('whisper-tiny-int8');
      expect(p, isNotNull);
      expect(p!.state, DownloadPhase.downloading);
      expect(p.bytesDone, 1024);
      expect(p.fraction, closeTo(0.25, 1e-9));
      expect(controller.downloadProgressFor('other-model'), isNull);
    });

    test('done event clears errors and re-reads the registry', () async {
      var capsReads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getCapabilities') {
              capsReads++;
              return capsWire();
            }
            return call.method == 'downloadModel' ? true : null;
          });
      await controller.refreshCapabilities();
      final before = capsReads;

      modelEvents.add(
        const ModelDownloadProgress(
          modelId: 'whisper-tiny-int8',
          state: DownloadPhase.done,
          bytesDone: 4096,
          bytesTotal: 4096,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(controller.downloadError, isNull);
      expect(capsReads, greaterThan(before));
    });

    test('failed event surfaces the native error string', () async {
      modelEvents.add(
        const ModelDownloadProgress(
          modelId: 'whisper-tiny-int8',
          state: DownloadPhase.failed,
          bytesDone: 10,
          bytesTotal: 100,
          error: 'MODEL_CHECKSUM',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.downloadError, 'MODEL_CHECKSUM');
    });

    test('pause + cancel hit their wire methods; cancel swallows errors',
        () async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            if (call.method == 'cancelModelDownload') {
              throw PlatformException(code: 'MODEL_MISSING');
            }
            return null;
          });

      await controller.pauseDownload('m');
      await controller.cancelDownload('m'); // must not throw

      expect(methods, ['pauseModelDownload', 'cancelModelDownload']);
    });
  });

  // -- E-03 benchmark ---------------------------------------------------------

  group('E-03: benchmark', () {
    test('parses the native metrics map into BenchmarkResult', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'runBenchmark' ? benchmarkWire : null,
          );

      final err = await controller.runBenchmark();

      expect(err, isNull);
      expect(controller.benchmarking, isFalse);
      expect(controller.lastBenchmark!.rtf, closeTo(0.31, 1e-9));
      expect(controller.lastBenchmark!.latencyP90Ms, 450.0);
      expect(controller.lastBenchmark!.rounds, 3);
    });

    test('native refusal lands in benchmarkError', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'runBenchmark') {
              throw PlatformException(
                code: 'INVALID_ARGUMENT',
                message: 'stop the active session before benchmarking',
              );
            }
            return null;
          });

      await controller.runBenchmark();

      expect(controller.lastBenchmark, isNull);
      expect(controller.benchmarkError, contains('INVALID_ARGUMENT'));
    });
  });

  // -- E-04 hot swap + F-02 task mode -----------------------------------------

  group('E-04/F-02: model swap + session metadata', () {
    test('loadModel / unloadModel wire names', () async {
      final methods = <String>[];
      final args = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            args.add(call.arguments);
            return null;
          });

      await controller.loadModel('whisper-tiny-int8');
      await controller.unloadModel();

      // Each mutation is followed by a capability refresh so the UI's
      // active-model indicator stays truthful (E-01).
      expect(methods, ['loadModel', 'getCapabilities', 'unloadModel', 'getCapabilities']);
      expect(args.first, {'modelId': 'whisper-tiny-int8'});
    });

    test('MODEL_MISSING surfaces in the returned error string', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'loadModel') {
              throw PlatformException(code: 'MODEL_MISSING');
            }
            return null;
          });

      final err = await controller.loadModel('nope');

      expect(err, contains('MODEL_MISSING'));
    });

    test(
      'transcribe mode: session tgtLang==srcLang, wire taskId=transcribe',
      () async {
        Object? startArgs;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'startSession') startArgs = call.arguments;
              return null;
            });

        controller.setTaskMode('transcribe');
        expect(controller.prefs!.get('taskMode'), 'transcribe');

        await controller.start(srcLang: 'ja');

        expect(controller.activeSession!.mode, 'transcribe');
        expect(controller.activeSession!.tgtLang, 'ja');
        expect(startArgs, {
          'sourceLang': 'ja',
          'taskId': 'transcribe',
          'sessionId': controller.activeSession!.id,
        });
      },
    );

    test('translate mode: session targets English (HT-3)', () async {
      Object? startArgs;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'startSession') startArgs = call.arguments;
            return null;
          });

      await controller.start(srcLang: 'ja');

      expect(controller.activeSession!.mode, 'translate');
      expect(controller.activeSession!.tgtLang, 'en');
      expect(startArgs, {
        'sourceLang': 'ja',
        'taskId': 'translate',
        'sessionId': controller.activeSession!.id,
      });
    });
  });

  // -- Wire: additive modelDownload payload ------------------------------------

  group('ModelDownloadProgress wire (additive channel)', () {
    test('parses the verbatim wire sample', () {
      final p = ModelDownloadProgress.fromWire(const {
        'type': 'modelDownload',
        'v': 1,
        'modelId': 'whisper-tiny-int8',
        'state': 'downloading',
        'bytesDone': 1000,
        'bytesTotal': 4000,
        'error': '',
      });
      expect(p.modelId, 'whisper-tiny-int8');
      expect(p.state, DownloadPhase.downloading);
      expect(p.fraction, closeTo(0.25, 1e-9));
      expect(p.error, '');
    });

    test('malformed shape throws; unknown state falls back to idle', () {
      expect(
        () => ModelDownloadProgress.fromWire(const {
          'type': 'modelDownload',
          'v': 1,
          'modelId': 'x',
          'state': 'downloading',
        }),
        throwsException,
      );
      // Additive-change rule: unrecognized phase values degrade to idle.
      final p = ModelDownloadProgress.fromWire(const {
        'type': 'modelDownload',
        'v': 1,
        'modelId': 'x',
        'state': 'warping',
        'bytesDone': 0,
        'bytesTotal': 0,
      });
      expect(p.state, DownloadPhase.idle);
    });

    test('round-trips through toWire', () {
      const p = ModelDownloadProgress(
        modelId: 'm',
        state: DownloadPhase.paused,
        bytesDone: 5,
        bytesTotal: 10,
        error: 'MODEL_SPACE',
      );
      expect(ModelDownloadProgress.fromWire(p.toWire()), equals(p));
    });
  });

  // -- Models screen smoke ------------------------------------------------------

  group('ModelsScreen', () {
    testWidgets('renders registry entries with state-driven actions',
        (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getCapabilities') {
              return capsWire(
                activeId: 'whisper-tiny-int8',
                models: [modelWire(installed: true)],
              );
            }
            return null;
          });

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ModelsScreen(controller: controller))),
      );
      await tester.pumpAndSettle();

      expect(find.text('Whisper Tiny (INT8)'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget); // loaded & installed
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('downloading model shows progress + pause/cancel',
        (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => capsWire());

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ModelsScreen(controller: controller))),
      );
      await tester.pumpAndSettle();

      modelEvents.add(
        const ModelDownloadProgress(
          modelId: 'whisper-tiny-int8',
          state: DownloadPhase.downloading,
          bytesDone: 1000,
          bytesTotal: 4000,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });
  });
}
