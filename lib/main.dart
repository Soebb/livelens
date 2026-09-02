import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:livelens/design.dart';

import 'src/app/app_controller.dart';
import 'src/app/screens.dart';
import 'src/data/datetime_adapter.dart';
import 'src/data/models.dart';
import 'src/data/repositories.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  Hive.registerAdapter(SessionAdapter());
  Hive.registerAdapter(SegmentAdapter());
  // hive 2.2.3 cannot serialize DateTime natively (see DateTimeAdapter doc).
  Hive.registerAdapter(DateTimeAdapter());
  final sessionBox = await Hive.openBox<Session>('sessions');
  final segmentBox = await Hive.openBox<Segment>('segments');
  final prefsBox = await Hive.openBox<String>('prefs');

  runApp(
    LivelensApp(
      controller: AppController(
        sessions: SessionRepository(sessionBox),
        segments: SegmentRepository(segmentBox),
        prefs: prefsBox,
      ),
    ),
  );
}

/// Application root. Dark-first per visual.md §4.1; light theme derived.
class LivelensApp extends StatelessWidget {
  const LivelensApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => MaterialApp(
        title: 'LiveLens',
        theme: PrismThemes.light(),
        darkTheme: PrismThemes.dark(),
        themeMode: controller.themeMode,
        home: AppShell(controller: controller),
      ),
    );
  }
}

/// Bottom-nav shell: Dashboard (live) · Sessions · Settings (visual.md §4.3).
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      DashboardScreen(controller: widget.controller),
      SessionsScreen(controller: widget.controller),
      ModelsScreen(controller: widget.controller),
      SettingsScreen(controller: widget.controller),
    ];

    return Scaffold(
      body: SafeArea(
        // #device-bug: without this, dashboard content drew under the
        // system status bar on real devices (no AppBar insets existed).
        bottom: false,
        child: pages[_tab],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.graphic_eq_rounded),
            label: 'Live',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_rounded),
            label: 'Sessions',
          ),
          NavigationDestination(
            icon: Icon(Icons.memory_rounded),
            label: 'Models',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
