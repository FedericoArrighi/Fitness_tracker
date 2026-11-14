import 'dart:async';
import 'package:flutter/material.dart';
import 'db.dart';
import 'screens/foods_screen.dart';
import 'screens/progress_screen.dart';
import 'screens/recipes_screen.dart';
import 'screens/targets_screen.dart';
import 'screens/today_screen.dart';
import 'health_import.dart';
import 'sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDb.init();
  runApp(const MacroApp());
}

class MacroApp extends StatelessWidget {
  const MacroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Macro Tracker',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2F6F5E),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  int _version = 0; // changes when a sync brought new data
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SyncService.dataChanged.addListener(_onSyncedData);
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => _autoSync());
    _autoSync(); // once at start
  }

  @override
  void dispose() {
    _timer?.cancel();
    SyncService.dataChanged.removeListener(_onSyncedData);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _autoSync() async {
    // Health Connect first, so new weights are included in the sync.
    final imported = await HealthImport.autoImport();
    if (imported > 0) _onSyncedData();
    if (SyncService.configured) await SyncService.run();
  }

  void _onSyncedData() {
    if (mounted) setState(() => _version++);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _autoSync();
  }

  @override
  Widget build(BuildContext context) {
    // Only the selected screen is built, so each tab reloads its data
    // from the database whenever you switch to it (or after a sync).
    final screens = <Widget>[
      const TodayScreen(),
      const FoodsScreen(),
      const RecipesScreen(),
      const ProgressScreen(),
      const TargetsScreen(),
    ];
    return Scaffold(
      body: KeyedSubtree(
        key: ValueKey('$_index-$_version'),
        child: screens[_index],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today), label: 'Today'),
          NavigationDestination(icon: Icon(Icons.restaurant), label: 'Foods'),
          NavigationDestination(icon: Icon(Icons.menu_book), label: 'Recipes'),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Progress'),
          NavigationDestination(icon: Icon(Icons.flag), label: 'Targets'),
        ],
      ),
    );
  }
}
