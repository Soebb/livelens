import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:livelens/design.dart';
import 'package:livelens/main.dart';
import 'package:livelens/src/app/app_controller.dart';
import 'package:livelens/src/data/datetime_adapter.dart';
import 'package:livelens/src/data/models.dart';
import 'package:livelens/src/data/repositories.dart';

// NOTE: All Hive/dart:io setup happens in setUp(), NOT inside testWidgets
// bodies — the latter run in a FakeAsync zone where real async file I/O
// (Directory.createTemp, Hive.openBox) never completes.

void main() {
  late AppController controller;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('livelens_wtest');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(SessionAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(SegmentAdapter());
    if (!Hive.isAdapterRegistered(30)) {
      Hive.registerAdapter(DateTimeAdapter());
    }

    final sessionBox = await Hive.openBox<Session>('w_sessions');
    final segmentBox = await Hive.openBox<Segment>('w_segments');

    controller = AppController(
      sessions: SessionRepository(sessionBox),
      segments: SegmentRepository(segmentBox),
      // prefs: null → in-memory theme only. A Hive `put` scheduled inside
      // the FakeAsync zone leaves a pending real-IO write that makes
      // Hive.deleteFromDisk() in tearDown hang forever.
      prefs: null,
      // Never touch the real EventChannel in widget tests.
      eventStream: const Stream.empty(),
    );
  });

  tearDown(() async {
    controller.dispose();
    await Hive.close();
    await Hive.deleteFromDisk();
    Hive.resetAdapters();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('App shell renders Dashboard with nav + start action', (
    tester,
  ) async {
    await tester.pumpWidget(LivelensApp(controller: controller));

    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget); // idle phase chip
    // The session-setup card (F-01/F-02) sits above the fold; the CTA is
    // revealed by scrolling the dashboard list.
    await tester.scrollUntilVisible(
      find.text('START TRANSLATION'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('START TRANSLATION'), findsOneWidget);
  });

  testWidgets('Capturing phase flips the dashboard into live controls', (
    tester,
  ) async {
    await tester.pumpWidget(LivelensApp(controller: controller));
    expect(find.text('Ready'), findsOneWidget);

    controller
      ..phase = LivePhase.capturing
      ..notifyListeners();
    await tester.pump();

    expect(find.text('Capturing'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('PAUSE'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('PAUSE'), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget);
    expect(find.text('START TRANSLATION'), findsNothing);
  });

  testWidgets('Settings theme toggle switches themeMode to dark', (
    tester,
  ) async {
    await tester.pumpWidget(LivelensApp(controller: controller));
    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Dark'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.themeMode, ThemeMode.dark);
  });

  testWidgets('PrimaryAction tap is handled', (tester) async {
    var pressed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: PrismThemes.dark(),
        home: Scaffold(
          body: Center(
            child: PrimaryAction(
              label: 'START TRANSLATION',
              onPressed: () => pressed = true,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('START TRANSLATION'));
    await tester.pumpAndSettle();

    expect(pressed, isTrue);
  });
}
