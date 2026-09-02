import 'dart:convert';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('livelens/control');

  late Directory tempDir;
  late AppController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('livelens_g02');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(SessionAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(SegmentAdapter());
    // hive 2.2.3 cannot serialize DateTime natively (see DateTimeAdapter doc).
    if (!Hive.isAdapterRegistered(30)) {
      Hive.registerAdapter(DateTimeAdapter());
    }

    final sessionBox = await Hive.openBox<Session>('g_sessions');
    final segmentBox = await Hive.openBox<Segment>('g_segments');
    final prefsBox = await Hive.openBox<String>('g_prefs');

    controller = AppController(
      sessions: SessionRepository(sessionBox),
      segments: SegmentRepository(segmentBox),
      prefs: prefsBox,
      eventStream: const Stream.empty(),
    );
  });

  tearDown(() async {
    controller.dispose();
    await Hive.close();
    await Hive.deleteFromDisk();
    Hive.resetAdapters();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('OverlayStyle.fromWire — safe parse w/ contract defaults', () {
    test('full map round-trips through toWire', () {
      const style = OverlayStyle(
        fontSizeSp: 22,
        backgroundOpacity: 0.5,
        maxLines: 3,
        textAlign: OverlayTextAlign.left,
        theme: OverlayTheme.solid,
        showBilingual: true,
        idleCollapseSeconds: 7,
      );
      expect(OverlayStyle.fromWire(style.toWire()), style);
    });

    test('partial map fills contract §2.4 defaults', () {
      final style = OverlayStyle.fromWire({'fontSizeSp': 24});
      expect(style.fontSizeSp, 24);
      expect(style.backgroundOpacity, 0.82);
      expect(style.maxLines, 2);
      expect(style.textAlign, OverlayTextAlign.center);
      expect(style.theme, OverlayTheme.glass);
      expect(style.idleCollapseSeconds, 3);
      expect(style.maxWidthFraction, 0.78);
    });

    test('non-map input yields pure defaults', () {
      expect(OverlayStyle.fromWire(null), const OverlayStyle());
      expect(OverlayStyle.fromWire(42), const OverlayStyle());
      expect(OverlayStyle.fromWire(<String, String>{}), const OverlayStyle());
    });

    test('malformed values fall back per key', () {
      final style = OverlayStyle.fromWire(const {
        'fontSizeSp': 'huge',
        'textAlign': 'diagonal',
        'theme': 'shiny',
        'showBilingual': 'yes',
      });
      expect(style.fontSizeSp, 18.0);
      expect(style.textAlign, OverlayTextAlign.center);
      expect(style.theme, OverlayTheme.glass);
      expect(style.showBilingual, isFalse);
    });
  });

  group('Preflight controller logic (G-02)', () {
    test('runPreflight captures battery state + compat rows', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'isBatteryExemptionGranted') return true;
            if (call.method == 'performCompatCheck') {
              return [
                {
                  'pkg': 'com.google.android.youtube',
                  'label': 'YouTube',
                  'capturableLikely': true,
                },
              ];
            }
            return null;
          });

      await controller.runPreflight();

      expect(controller.batteryExemptionGranted, isTrue);
      expect(controller.compatRows, hasLength(1));
      expect(controller.compatRows.first.capturableLikely, isTrue);
      expect(controller.preflightError, isNull);
      expect(controller.preflightChecking, isFalse);
    });

    test(
      'runPreflight swallows platform failures into preflightError',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw PlatformException(code: 'NOPE');
            });

        await controller.runPreflight();

        expect(controller.preflightError, isNotNull);
        expect(controller.preflightChecking, isFalse);
        expect(controller.batteryExemptionGranted, isNull);
      },
    );

    test('checkOverlayPermission reflects the grant state', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => true);

      expect(await controller.checkOverlayPermission(), isTrue);
      expect(controller.overlayPermissionGranted, isTrue);
    });

    test('openBatteryExemptionSettings re-probes after deep-link', () async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            return call.method == 'isBatteryExemptionGranted';
          });

      await controller.openBatteryExemptionSettings();

      expect(methods, ['openBatterySettings', 'isBatteryExemptionGranted']);
      expect(controller.batteryExemptionGranted, isTrue);
    });
  });

  group('Settings live-push (overlay / governor / langs)', () {
    test('updateOverlayStyle pushes the full wire map + persists JSON', () {
      final methods = <String>[];
      Object? args;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            if (call.method == 'setOverlayStyle') args = call.arguments;
            return null;
          });

      controller.updateOverlayStyle(
        const OverlayStyle(fontSizeSp: 26, theme: OverlayTheme.solid),
      );

      expect(controller.overlayStyle.fontSizeSp, 26);
      expect(controller.overlayStyle.theme, OverlayTheme.solid);
      expect(methods, ['setOverlayStyle']);
      expect((args! as Map)['fontSizeSp'], 26);
      expect((args! as Map)['theme'], 'solid');

      // Persisted copy parses back to the same style.
      final json = controller.prefs!.get('overlayStyle')!;
      expect(OverlayStyle.fromWire(jsonDecode(json) as Map).fontSizeSp, 26);
    });

    test('updateGovernorPrefs pushes + persists', () {
      final methods = <String>[];
      Object? args;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            if (call.method == 'setGovernorPrefs') args = call.arguments;
            return null;
          });

      const prefs = GovernorPrefs(
        screenOffAutoPause: true,
        batteryLowThresholdPct: 25,
        inferenceQueueDepth: 5,
      );
      controller.updateGovernorPrefs(prefs);

      expect(controller.governorPrefs, prefs);
      expect(methods, ['setGovernorPrefs']);
      expect((args! as Map)['screenOffAutoPause'], isTrue);
      expect((args! as Map)['batteryLowThresholdPct'], 25);
      expect((args! as Map)['inferenceQueueDepth'], 5);
    });

    test('persisted settings reload on construction', () {
      controller
        ..updateOverlayStyle(const OverlayStyle(maxLines: 3))
        ..updateGovernorPrefs(const GovernorPrefs(batteryLowThresholdPct: 40))
        ..setDefaultSrcLang('ja');

      final reloaded = AppController(
        sessions: controller.sessions,
        segments: controller.segments,
        prefs: controller.prefs,
        eventStream: const Stream.empty(),
      );

      expect(reloaded.overlayStyle.maxLines, 3);
      expect(reloaded.governorPrefs.batteryLowThresholdPct, 40);
      expect(reloaded.defaultSrcLang, 'ja');
      reloaded.dispose();
    });

    test('start() uses the persisted source language', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      controller.setDefaultSrcLang('ja');

      await controller.start();
      await controller.stop();

      expect(controller.activeSession?.srcLang, 'ja');
    });
  });

  group('Preflight strip widget', () {
    testWidgets('renders rows with unknown state before any probe', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [PreflightStrip(controller: controller)]),
          ),
        ),
      );

      expect(find.text('Preflight'), findsOneWidget);
      expect(find.text('Overlay permission'), findsOneWidget);
      expect(find.text('Battery exemption'), findsOneWidget);
      expect(find.text('Check'), findsOneWidget); // overlay action visible
    });

    testWidgets('granted state shows no fix actions', (tester) async {
      controller
        ..overlayPermissionGranted = true
        ..batteryExemptionGranted = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(children: [PreflightStrip(controller: controller)]),
          ),
        ),
      );

      expect(find.text('Check'), findsNothing);
      expect(find.text('Exempt'), findsNothing);
    });
  });

  group('Settings cards widget', () {
    // prefs: null → no Hive writes inside the FakeAsync zone; a pending
    // real-IO write leaves pumpAndSettle hanging forever (see widget_test.dart).
    late AppController uiController;

    Widget host(WidgetTester tester) {
      uiController = AppController(
        sessions: controller.sessions,
        segments: controller.segments,
        prefs: null,
        eventStream: const Stream.empty(),
      );
      // Tall surface so the ListView builds ALL cards (off-screen children
      // are not otherwise inflated in tests).
      tester.view.physicalSize = const Size(1080, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      return MaterialApp(
        home: Scaffold(body: SettingsScreen(controller: uiController)),
      );
    }

    testWidgets('overlay + governor + languages cards render', (tester) async {
      await tester.pumpWidget(host(tester));

      expect(find.text('Overlay'), findsOneWidget);
      expect(find.text('Power & thermal'), findsOneWidget);
      expect(find.text('Languages'), findsOneWidget);
      expect(find.text('Bilingual source line'), findsOneWidget);
      expect(find.text('Pause when screen turns off'), findsOneWidget);
    });

    testWidgets('max-lines segment pushes a new overlay style', (tester) async {
      await tester.pumpWidget(host(tester));

      await tester.tap(find.text('3 lines'));
      await tester.pumpAndSettle();

      expect(uiController.overlayStyle.maxLines, 3);
      expect(uiController.overlayStyle.idleCollapseSeconds, 3); // untouched
    });

    testWidgets('solid theme toggle pushes OverlayTheme.solid', (tester) async {
      await tester.pumpWidget(host(tester));

      await tester.tap(find.text('Solid'));
      await tester.pumpAndSettle();

      expect(uiController.overlayStyle.theme, OverlayTheme.solid);
    });

    testWidgets('bilingual switch updates the style', (tester) async {
      await tester.pumpWidget(host(tester));

      await tester.tap(find.text('Bilingual source line'));
      await tester.pumpAndSettle();

      expect(uiController.overlayStyle.showBilingual, isTrue);
    });
  });
}
