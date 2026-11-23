import 'dart:async';
import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'db.dart';
import 'backup_service.dart';
import 'screens/me_home.dart';
import 'screens/nutrition_home.dart';
import 'screens/training_home.dart';
import 'health_import.dart';
import 'hevy_api.dart';
import 'sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppDb.init();
  AppTheme.load();
  runApp(const MacroApp());
}

class MacroApp extends StatelessWidget {
  const MacroApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppTheme.changes,
      builder: (context, _) => MaterialApp(
        title: 'Macro Tracker',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: AppTheme.mode.value,
        home: const HomeShell(),
      ),
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
  int _version = 0; // goes up when a sync brought new data: all tabs are rebuilt
  Timer? _timer;
  bool _autoRunning = false;
  DateTime _lastAuto = DateTime.fromMillisecondsSinceEpoch(0);

  // A tab is built when it is first opened and then kept, so that switching
  // is instant. A tab that was left in the background is rebuilt (and reloads
  // its data) when you come back to it after data changed elsewhere.
  final Set<int> _built = {0};
  final List<int> _keys = [0, 0, 0];
  final List<int> _stamps = [AppDb.stamp, AppDb.stamp, AppDb.stamp];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SyncService.dataChanged.addListener(_onSyncedData);
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => _autoSync(reload: false));
    _autoSync(); // once at start
    // one automatic backup a day, a few seconds after start so it does not slow the start
    Future.delayed(const Duration(seconds: 8), BackupService.autoBackup);
  }

  @override
  void dispose() {
    _timer?.cancel();
    SyncService.dataChanged.removeListener(_onSyncedData);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// [reload]: also rebuild the tab you are looking at if something new came in.
  Future<void> _autoSync({bool reload = true}) async {
    if (_autoRunning) return;
    _autoRunning = true;
    try {
      // Health Connect first, so new weights are included in the sync.
      final imported = await HealthImport.autoImport();
      final hevy = await HevySync.auto();
      if (imported > 0 || hevy > 0) {
        AppDb.stamp++; // the other tabs reload when you open them
        if (reload) _onSyncedData();
      }
      if (SyncService.configured) await SyncService.run();
    } finally {
      _autoRunning = false;
      _lastAuto = DateTime.now();
    }
  }

  void _onSyncedData() {
    if (mounted) setState(() => _version++);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        DateTime.now().difference(_lastAuto) > const Duration(minutes: 3)) {
      _autoSync();
    }
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() {
      _stamps[_index] = AppDb.stamp; // the tab you leave is up to date as of now
      if (_built.contains(i) && _stamps[i] != AppDb.stamp) {
        _keys[i]++;
      }
      _stamps[i] = AppDb.stamp;
      _built.add(i);
      _index = i;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const TrainingHome(),
      const NutritionHome(),
      const MeHome(),
    ];
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < pages.length; i++)
            ExcludeFocus(
              excluding: i != _index,
              child: TickerMode(
                enabled: i == _index,
                child: _built.contains(i)
                    ? KeyedSubtree(
                        key: ValueKey('tab$i-${_keys[i]}-$_version'),
                        child: pages[i],
                      )
                    : const SizedBox.shrink(),
              ),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.fitness_center), label: 'Training'),
          NavigationDestination(icon: Icon(Icons.restaurant), label: 'Nutrition'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Me'),
        ],
      ),
    );
  }
}
