import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../chart_view.dart';
import '../metrics.dart';
import '../widgets.dart';
import 'activity_view.dart';
import 'backup_panel.dart';
import 'calendar_view.dart';
import 'review_view.dart';
import 'sync_screen.dart';
import 'weight_panel.dart';

/// Personal and fitness information: calendar with the details of each day,
/// weight, sleep and activity, and the data side (imports, backup, sync).
class MeHome extends StatefulWidget {
  const MeHome({super.key});

  @override
  State<MeHome> createState() => _MeHomeState();
}

class _MeHomeState extends State<MeHome> {
  int _v = 0; // goes up when data changed, so the charts reload
  // chart settings are kept here, so they survive switching tabs
  ChartConfig? _weightCfg, _activityCfg;

  void _bump() => setState(() => _v++);

  @override
  Widget build(BuildContext context) {
    return SectionTabs(
      title: 'Me',
      tabs: const ['Calendar', 'Review', 'Weight', 'Sleep and activity', 'Data'],
      pages: [
        (_) => const CalendarView(),
        (_) => const ReviewView(),
        (_) => ListView(
              padding: const EdgeInsets.all(12),
              children: [
                MetricChart(
                  metrics: weightMetrics,
                  initialMetric: 'weight',
                  initialDays: 90,
                  reloadToken: _v,
                  config: _weightCfg,
                  onConfigChanged: (c) => _weightCfg = c,
                ),
                WeightPanel(onChanged: _bump),
              ],
            ),
        (_) => ListView(
              padding: const EdgeInsets.all(12),
              children: [
                MetricChart(
                  metrics: activityMetrics,
                  initialMetric: 'act:steps',
                  reloadToken: _v,
                  config: _activityCfg,
                  onConfigChanged: (c) => _activityCfg = c,
                ),
              ],
            ),
        (_) => ListView(
              padding: const EdgeInsets.all(12),
              children: [
                const _AppearanceCard(),
                ActivityPanel(onChanged: _bump),
                const BackupPanel(),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.sync),
                    title: const Text('Sync between devices'),
                    subtitle: const Text('Server address and sync now'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SyncScreen()),
                    ),
                  ),
                ),
              ],
            ),
      ],
    );
  }
}

/// Light, dark or system theme.
class _AppearanceCard extends StatefulWidget {
  const _AppearanceCard();

  @override
  State<_AppearanceCard> createState() => _AppearanceCardState();
}

class _AppearanceCardState extends State<_AppearanceCard> {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto)),
                ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode)),
                ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode)),
              ],
              selected: {AppTheme.mode.value},
              onSelectionChanged: (s) {
                AppTheme.setMode(s.first);
                setState(() {});
              },
            ),
            const SizedBox(height: 16),
            const Text('Colours'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                for (final p in AppTheme.palettes)
                  InkWell(
                    borderRadius: BorderRadius.circular(28),
                    onTap: () {
                      AppTheme.setPalette(p.id);
                      setState(() {});
                    },
                    child: SizedBox(
                      width: 60,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 20,
                            backgroundColor: p.seed,
                            child: AppTheme.palette.value == p.id
                                ? const Icon(Icons.check, color: Colors.white)
                                : null,
                          ),
                          const SizedBox(height: 2),
                          Text(p.name, style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Pure black in dark mode'),
              subtitle: const Text('Saves battery on OLED screens'),
              value: AppTheme.pureBlack.value,
              onChanged: (v) {
                AppTheme.setPureBlack(v);
                setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }
}
