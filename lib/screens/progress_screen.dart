import 'package:flutter/material.dart';
import '../chart_view.dart';
import '../db.dart';
import '../health_import.dart';
import '../metrics.dart';
import '../nutrients.dart';
import '../widgets.dart';
import 'activity_view.dart';
import 'training_view.dart';

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  int _v = 0; // bumped when data changed, so the charts reload
  // chart settings are kept here, so they survive switching tabs
  ChartConfig? _intakeCfg, _weightCfg, _activityCfg;

  void _bump() => setState(() => _v++);

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Progress'),
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: 'Intake'),
            Tab(text: 'Weight'),
            Tab(text: 'Activity'),
            Tab(text: 'Training'),
          ]),
        ),
        body: TabBarView(
          children: [
            ListView(
              padding: const EdgeInsets.all(12),
              children: [
                MetricChart(
                  metrics: nutritionMetrics,
                  initialMetric: 'nut:calories',
                  reloadToken: _v,
                  config: _intakeCfg,
                  onConfigChanged: (c) => _intakeCfg = c,
                ),
              ],
            ),
            ListView(
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
            ListView(
              padding: const EdgeInsets.all(12),
              children: [
                MetricChart(
                  metrics: activityMetrics,
                  initialMetric: 'act:steps',
                  reloadToken: _v,
                  config: _activityCfg,
                  onConfigChanged: (c) => _activityCfg = c,
                ),
                ActivityPanel(onChanged: _bump),
              ],
            ),
            ListView(
              padding: const EdgeInsets.all(12),
              children: [TrainingView(reloadToken: _v)],
            ),
          ],
        ),
      ),
    );
  }
}

/// Typing in a weight, importing from Health Connect, recent entries.
class WeightPanel extends StatefulWidget {
  final VoidCallback onChanged;
  const WeightPanel({super.key, required this.onChanged});

  @override
  State<WeightPanel> createState() => _WeightPanelState();
}

class _WeightPanelState extends State<WeightPanel> {
  final _kg = TextEditingController();
  DateTime _day = DateTime.now();
  bool _importing = false;
  List<WeightPoint> _recent = []; // oldest first

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _kg.dispose();
    super.dispose();
  }

  void _load() {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day - 60);
    setState(() => _recent = AppDb.instance.loadWeights(dayKey(from)));
  }

  void _save() {
    final kg = parseNum(_kg.text);
    if (kg == null || kg < 20 || kg > 500) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a weight in kg (20 to 500).')));
      return;
    }
    AppDb.instance.saveWeight(dayKey(_day), kg);
    _kg.clear();
    _load();
    widget.onChanged();
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _day = d);
  }

  void _delete(WeightPoint p) {
    AppDb.instance.deleteWeight(p.day);
    _load();
    widget.onChanged();
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text('Removed weight of ${p.day}.'),
      persist: false,
      duration: const Duration(seconds: 3),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          AppDb.instance.saveWeight(p.day, p.kg);
          _load();
          widget.onChanged();
        },
      ),
    ));
  }

  Future<void> _importHealth() async {
    setState(() => _importing = true);
    final r = await HealthImport.importAll();
    if (!mounted) return;
    setState(() => _importing = false);
    _load();
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(r.summary), duration: const Duration(seconds: 6)));
  }

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    String stats = 'No weight entries in the last 60 days.';
    if (_recent.isNotEmpty) {
      final now = DateTime.now();
      final cut = dayKey(DateTime(now.year, now.month, now.day - 6));
      final week = _recent.where((p) => p.day.compareTo(cut) >= 0).toList();
      stats = 'Latest: ${_recent.last.kg.toStringAsFixed(1)} kg (${_recent.last.day})';
      if (week.isNotEmpty) {
        final avg = week.fold<double>(0, (s, p) => s + p.kg) / week.length;
        stats += '   Average of the last 7 days: ${avg.toStringAsFixed(1)} kg';
      }
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add weight', style: title),
            Row(
              children: [
                Expanded(
                  child: numField(
                    controller: _kg,
                    label: 'Weight',
                    suffix: 'kg',
                    onSubmitted: (_) => _save(),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: _pickDay, child: Text(dayKey(_day))),
                const SizedBox(width: 4),
                FilledButton(onPressed: _save, child: const Text('Save')),
              ],
            ),
            if (HealthImport.supported)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _importing ? null : _importHealth,
                  icon: const Icon(Icons.health_and_safety_outlined),
                  label: Text(_importing ? 'Importing...' : 'Import from Health Connect'),
                ),
              ),
            const SizedBox(height: 8),
            Text(stats),
            const SizedBox(height: 8),
            for (final p in _recent.reversed.take(8))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(p.day),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${p.kg.toStringAsFixed(1)} kg'),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete',
                      onPressed: () => _delete(p),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
