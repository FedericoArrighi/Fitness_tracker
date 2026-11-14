import 'package:flutter/material.dart';
import '../charts.dart';
import '../db.dart';
import '../health_import.dart';
import '../nutrients.dart';
import '../widgets.dart';

class _Metric {
  final String key;
  final String name;
  final String unit;
  final double scale; // stored value * scale = shown value
  const _Metric(this.key, this.name, this.unit, [this.scale = 1]);
}

const _metrics = [
  _Metric('steps', 'Steps', 'steps'),
  _Metric('active_kcal', 'Active calories', 'kcal'),
  _Metric('distance_km', 'Distance', 'km'),
  _Metric('floors', 'Floors climbed', 'floors'),
  _Metric('resting_hr', 'Resting heart rate', 'bpm'),
  _Metric('sleep_total', 'Sleep', 'h', 1 / 60),
  _Metric('sleep_deep', 'Deep sleep', 'h', 1 / 60),
  _Metric('sleep_light', 'Light sleep', 'h', 1 / 60),
  _Metric('sleep_rem', 'REM sleep', 'h', 1 / 60),
  _Metric('sleep_awake', 'Awake during sleep', 'h', 1 / 60),
  _Metric('body_fat', 'Body fat', '%'),
];

String _pretty(String t) {
  final s = t.replaceAll('_', ' ').toLowerCase();
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// Steps, sleep, calories, ... per day, plus the list of workouts.
class ActivityView extends StatefulWidget {
  final int range; // days shown
  const ActivityView({super.key, required this.range});

  @override
  State<ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends State<ActivityView> {
  String _metric = 'steps';
  Map<String, Map<String, double>> _daily = {};
  List<Workout> _workouts = [];
  bool _importing = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ActivityView old) {
    super.didUpdateWidget(old);
    if (old.range != widget.range) _load();
  }

  DateTime get _first {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day - (widget.range - 1));
  }

  void _load() {
    final now = DateTime.now();
    setState(() {
      _daily = AppDb.instance.loadDailyMetrics(dayKey(_first), dayKey(now));
      _workouts = AppDb.instance.loadWorkouts(dayKey(_first));
    });
  }

  Future<void> _import(int days) async {
    setState(() {
      _importing = true;
      _status = 'Importing...';
    });
    final r = await HealthImport.importAll(days: days);
    if (!mounted) return;
    setState(() {
      _importing = false;
      _status = r.summary;
    });
    _load();
  }

  Future<void> _importOlder() async {
    final days = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Import how far back?'),
        children: [
          for (final d in [30, 90, 180, 365])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, d),
              child: Text(d == 365 ? '1 year' : '$d days'),
            ),
        ],
      ),
    );
    if (days != null) _import(days);
  }

  Future<void> _addWorkout() async {
    final type = TextEditingController(text: 'Strength training');
    final mins = TextEditingController();
    final kcal = TextEditingController();
    var day = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setS) {
          void submit() {
            final m = parseNum(mins.text);
            if (type.text.trim().isEmpty || m == null || m <= 0) return;
            Navigator.pop(context, true);
          }

          return AlertDialog(
            title: const Text('Add workout'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: type,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Type'),
                  ),
                  numField(
                      controller: mins,
                      label: 'Duration',
                      suffix: 'min',
                      onSubmitted: (_) => submit()),
                  numField(
                      controller: kcal,
                      label: 'Active calories (optional)',
                      suffix: 'kcal',
                      onSubmitted: (_) => submit()),
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: day,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (d != null) setS(() => day = d);
                    },
                    child: Text('Date: ${dayKey(day)}'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              TextButton(onPressed: submit, child: const Text('Add')),
            ],
          );
        },
      ),
    );
    final m = parseNum(mins.text);
    if (ok != true || m == null || m <= 0) return;
    final start = DateTime(day.year, day.month, day.day, 12);
    AppDb.instance.saveWorkout(Workout(
      id: newId(),
      day: dayKey(day),
      startMs: start.millisecondsSinceEpoch,
      endMs: start.add(Duration(minutes: m.round())).millisecondsSinceEpoch,
      type: type.text.trim(),
      activeKcal: parseNum(kcal.text),
      source: 'manual',
    ));
    _load();
  }

  Widget _metricCard() {
    final title = Theme.of(context).textTheme.titleMedium;
    final m = _metrics.firstWhere((x) => x.key == _metric);
    final days = [
      for (var i = 0; i < widget.range; i++)
        DateTime(_first.year, _first.month, _first.day + i)
    ];
    final values = <double?>[
      for (final d in days)
        (_daily[dayKey(d)]?[m.key] == null)
            ? null
            : _daily[dayKey(d)]![m.key]! * m.scale
    ];
    final known = values.whereType<double>().toList();
    final avg =
        known.isEmpty ? null : known.reduce((a, b) => a + b) / known.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              children: [
                Text('Per day', style: title),
                DropdownButton<String>(
                  value: _metric,
                  items: [
                    for (final x in _metrics)
                      DropdownMenuItem(
                          value: x.key, child: Text('${x.name} (${x.unit})')),
                  ],
                  onChanged: (v) => setState(() => _metric = v!),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DailyBarChart(
              days: days,
              values: values,
              partial: List.filled(days.length, false),
            ),
            const SizedBox(height: 8),
            Text(avg == null
                ? 'No ${m.name.toLowerCase()} data in this period.'
                : 'Average on the ${known.length} day(s) with data: '
                    '${fmt(avg)} ${m.unit}'),
          ],
        ),
      ),
    );
  }

  Widget _workoutCard() {
    final title = Theme.of(context).textTheme.titleMedium;
    final totalMin = _workouts.fold<double>(0, (s, w) => s + w.minutes);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Workouts', style: title)),
                TextButton.icon(
                  onPressed: _addWorkout,
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ],
            ),
            Text(_workouts.isEmpty
                ? 'No workouts in this period.'
                : '${_workouts.length} workout(s), ${fmt(totalMin / 60)} h in total'),
            for (final w in _workouts.take(40))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(w.title.isNotEmpty ? w.title : _pretty(w.type)),
                subtitle: Text([
                  w.day,
                  '${fmt(w.minutes)} min',
                  if (w.distanceM != null && w.distanceM! > 0)
                    '${fmt(w.distanceM! / 1000)} km',
                  if (w.activeKcal != null) '${fmt(w.activeKcal!)} kcal',
                ].join('  |  ')),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () {
                    AppDb.instance.deleteWorkout(w.id);
                    _load();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (HealthImport.supported)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'Your Garmin watch data reaches Health Connect through the '
                      'Garmin Connect app. This imports it here.',
                      style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _importing ? null : () => _import(30),
                        icon: const Icon(Icons.health_and_safety_outlined),
                        label: const Text('Import last 30 days'),
                      ),
                      OutlinedButton(
                        onPressed: _importing ? null : _importOlder,
                        child: const Text('Older data...'),
                      ),
                    ],
                  ),
                  if (_importing)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(),
                    ),
                  if (_status.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_status),
                    ),
                ],
              ),
            ),
          ),
        _metricCard(),
        _workoutCard(),
      ],
    );
  }
}
