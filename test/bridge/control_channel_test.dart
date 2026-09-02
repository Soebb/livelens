import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livelens/bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('livelens/control');
  final control = LivelensControl();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => call.arguments);
    // Default: echo arguments back; individual tests override.
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('Wire conformance — exact method names & argument envelopes', () {
    test('startSession sends lowerCamelCase method + frozen args', () async {
      Object? capturedArgs;
      String? capturedMethod;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedMethod = call.method;
            capturedArgs = call.arguments;
            return null;
          });

      await control.startSession(
        sourceLang: 'ja',
        taskId: LivelensTask.translate,
        sessionId: 'sess-1',
      );

      expect(capturedMethod, 'startSession');
      expect(capturedArgs, {
        'sourceLang': 'ja',
        'taskId': 'translate',
        'sessionId': 'sess-1',
      });
    });

    test('startSession with auto (null) sourceLang', () async {
      Object? capturedArgs;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedArgs = call.arguments;
            return null;
          });

      await control.startSession(
        taskId: LivelensTask.transcribe,
        sessionId: 'sess-2',
      );

      expect(capturedArgs, {
        'sourceLang': null,
        'taskId': 'transcribe',
        'sessionId': 'sess-2',
      });
    });

    test('pause / resume / stopSession method names', () async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            return null;
          });

      await control.pause();
      await control.resume();
      await control.stopSession();

      expect(methods, ['pause', 'resume', 'stopSession']);
    });

    test('loadModel envelope', () async {
      Object? capturedArgs;
      String? capturedMethod;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedMethod = call.method;
            capturedArgs = call.arguments;
            return null;
          });

      await control.loadModel(modelId: 'whisper-tiny-int8');

      expect(capturedMethod, 'loadModel');
      expect(capturedArgs, {'modelId': 'whisper-tiny-int8'});
    });

    test('setOverlayStyle pushes full token map', () async {
      Object? capturedArgs;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedArgs = call.arguments;
            return null;
          });

      const style = OverlayStyle();
      await control.setOverlayStyle(style);

      expect(capturedArgs, style.toWire());
      // Spot-check frozen defaults from visual.md Part 4:
      expect((capturedArgs as Map)['backgroundOpacity'], 0.82);
      expect((capturedArgs as Map)['cornerRadiusPx'], 20.0);
      expect((capturedArgs as Map)['maxWidthFraction'], 0.78);
      expect((capturedArgs as Map)['idleCollapseSeconds'], 3);
    });

    test('saveOverlayPosition envelope', () async {
      Object? capturedArgs;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedArgs = call.arguments;
            return null;
          });

      await control.saveOverlayPosition(x: 10, y: 20, w: 300, h: 80);

      expect(capturedArgs, {'x': 10.0, 'y': 20.0, 'w': 300.0, 'h': 80.0});
    });

    test('setGovernorPrefs envelope', () async {
      Object? capturedArgs;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedArgs = call.arguments;
            return null;
          });

      const prefs = GovernorPrefs(
        screenOffAutoPause: true,
        batteryLowThresholdPct: 20,
        thermalHysteresisMs: 45000,
        inferenceQueueDepth: 4,
      );
      await control.setGovernorPrefs(prefs);

      expect(capturedArgs, prefs.toWire());
    });
  });

  group('Reply parsing — getCapabilities / performCompatCheck', () {
    test('getCapabilities parses a realistic native reply', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return {
              'activeModelId': 'whisper-tiny-int8',
              'downloadPath': '/data/user/0/dev.livelens.livelens/files/models',
              'availableModels': [
                {
                  'id': 'whisper-tiny-int8',
                  'label': 'Whisper tiny — FAST',
                  'tier': 'fast',
                  'sizeBytes': 165000000,
                  'installed': true,
                },
                {
                  'id': 'whisper-base-int8',
                  'label': 'Whisper base — BALANCED',
                  'tier': 'balanced',
                  'sizeBytes': 190000000,
                  'installed': false,
                },
              ],
            };
          });

      final caps = await control.getCapabilities();

      expect(caps.activeModelId, 'whisper-tiny-int8');
      expect(caps.downloadPath, contains('/files/models'));
      expect(caps.availableModels, hasLength(2));
      expect(caps.availableModels.first.tier, ModelTier.fast);
      expect(caps.availableModels.first.installed, isTrue);
      expect(caps.availableModels[1].tier, ModelTier.balanced);
    });

    test('getCapabilities with activeModelId=null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return {
              'activeModelId': null,
              'downloadPath': '/x',
              'availableModels': [],
            };
          });

      final caps = await control.getCapabilities();
      expect(caps.activeModelId, isNull);
      expect(caps.availableModels, isEmpty);
    });

    test('performCompatCheck parses rows', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return [
              {
                'pkg': 'com.google.android.youtube',
                'label': 'YouTube',
                'capturableLikely': true,
              },
              {
                'pkg': 'com.netflix.mediaclient',
                'label': 'Netflix',
                'capturableLikely': false,
              },
            ];
          });

      final rows = await control.performCompatCheck();
      expect(rows, hasLength(2));
      expect(rows.first.pkg, 'com.google.android.youtube');
      expect(rows.last.capturableLikely, isFalse); // DRM blocker (HT-1)
    });

    test('boolean replies coerce strictly', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => true);
      expect(await control.requestOverlayPermission(), isTrue);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => false);
      expect(await control.isBatteryExemptionGranted(), isFalse);
    });
  });

  group('Error propagation — PlatformException codes pass through', () {
    test('loadModel surfaces MODEL_MISSING', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'MODEL_MISSING',
              message: 'not installed',
            );
          });

      await expectLater(
        control.loadModel(modelId: 'nope'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'MODEL_MISSING',
          ),
        ),
      );
    });

    test('startSession surfaces CAPTURE_INIT_FAILED', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'CAPTURE_INIT_FAILED');
          });

      await expectLater(
        control.startSession(taskId: LivelensTask.translate, sessionId: 's'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'CAPTURE_INIT_FAILED',
          ),
        ),
      );
    });
  });

  group('DTO shape validation rejects malformed native replies', () {
    test('getCapabilities with non-list models throws', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return {
              'activeModelId': null,
              'downloadPath': '/x',
              'availableModels': 7,
            };
          });

      await expectLater(control.getCapabilities(), throwsA(isA<Exception>()));
    });

    test('model entry with bad tier throws', () async {
      expect(
        () => ModelInfo.fromWire({
          'id': 'm',
          'label': 'M',
          'tier': 'ultra',
          'sizeBytes': 1,
          'installed': false,
        }),
        throwsA(isA<Exception>()),
      );
    });
  });
}
