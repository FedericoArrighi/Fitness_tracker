import 'package:flutter/material.dart';
import '../health_import.dart';
import '../charts.dart';
import '../db.dart';
import '../nutrients.dart';
import 'activity_view.dart';
import '../widgets.dart';

DateTime _utc(String day) => DateTime.parse('${day}T00:00:00Z');

/// Average of all entries in the 7 days up to and including each entry.
List<double> movingAverage(List<WeightPoint> pts) {
  final out = <double>[];
  for (var i = 0; i < pts.length; i++) {
    final di = _utc(pts[i].day);
    var sum = 0.0;
    var n = 0;
    for (var j = 0; j <= i; j++) {
      if (di.difference(_utc(pts[j].day)).inDays <= 6) {
        sum += pts[j].kg;
        n++;
      }
    }
    out.add(sum / n);
  }
  return out;
}

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});

  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends State<ProgressScreen> {
  int _range = 30; // days shown
  String _nutrient = 'calories';
  DateTime _today = DateTime.now();
  Map<String, DayTotals> _totals = {};
  List<WeightPoint> _weights = []; // includes 6 extra days for the average
  Map<String, double> _targets = {};

  final _kg = TextEditingController();
  bool _importing = false;
  DateTime _weightDay = DateTime.now();

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

  DateTime get _firstDay =>
      DateTime(_today.year, _today.month, _today.day - (_range - 1));

  void _load() {
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, now.day - (_range - 1));
    final firstForAverage = DateTime(first.year, first.month, first.day - 6);
    setState(() {
      _today = now;
      _totals = AppDb.instance.dailyTotals(dayKey(first), dayKey(now));
      _weights = AppDb.instance.loadWeights(dayKey(firstForAverage));
      _targets = AppDb.instance.loadTargets();
    });
  }

  void _saveWeight() {
    final kg = parseNum(_kg.text);
    if (kg == null || kg < 20 || kg > 500) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a weight in kg (20 to 500).')));
      return;
    }
    AppDb.instance.saveWeight(dayKey(_weightDay), kg);
    _kg.clear();
    _load();
  }

  Future<void> _importHealth() async {
    setState(() => _importing = true);
    final r = await HealthImport.importAll();
    if (!mounted) return;
    setState(() => _importing = false);
    _load();
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(r.summary), duration: const Duration(seconds: 6)));
  }

  Future<void> _pickWeightDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _weightDay,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _weightDay = d);
  }

  void _deleteWeight(WeightPoint p) {
    AppDb.instance.deleteWeight(p.day);
    _load();
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
        },
      ),
    ));
  }

  Widget _rangeSelector() {
    return SegmentedButton<int>(
      segments: const [
        ButtonSegment(value: 7, label: Text('7 d')),
        ButtonSegment(value: 30, label: Text('30 d')),
        ButtonSegment(value: 90, label: Text('90 d')),
        ButtonSegment(value: 365, label: Text('1 y')),
      ],
      selected: {_range},
      onSelectionChanged: (s) {
        _range = s.first;
        _load();
      },
    );
  }

  Widget _nutritionCard() {
    final title = Theme.of(context).textTheme.titleMedium;
    final n = nutrients.firstWhere((x) => x.key == _nutrient);
    final days = [
      for (var i = 0; i < _range; i++)
        DateTime(_firstDay.year, _firstDay.month, _firstDay.day + i)
    ];
    final values = <double?>[
      for (final d in days) _totals[dayKey(d)]?.totals[_nutrient]
    ];
    final partial = <bool>[
      for (final d in days)
        _totals[dayKey(d)]?.incomplete.contains(_nutrient) ?? false
    ];
    final known = values.whereType<double>().toList();
    final avg =
        known.isEmpty ? null : known.reduce((a, b) => a + b) / known.length;
    final target = _targets[_nutrient];
    final anyPartial = partial.any((p) => p);

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
                Text('Intake per day', style: title),
                DropdownButton<String>(
                  value: _nutrient,
                  items: [
                    for (final x in nutrients)
                      DropdownMenuItem(
                          value: x.key, child: Text('${x.name} (${x.unit})')),
                  ],
                  onChanged: (v) => setState(() => _nutrient = v!),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DailyBarChart(
                days: days, values: values, partial: partial, target: target),
            const SizedBox(height: 8),
            Text(avg == null
                ? 'No data for ${n.name} in this period.'
                : 'Average on the ${known.length} logged day(s): ${fmt(avg)} ${n.unit}'
                    '${target != null ? '   (target ${fmt(target)} ${n.unit}, red dashed line)' : ''}'),
            if (anyPartial)
              const Text(
                  'Lighter bars: some foods that day have no value for this nutrient, so the bar is too low.',
                  style: TextStyle(fontSize: 12)),
            const Text('Days with no logged food, or no data for this nutrient, have no bar.',
                style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _weightCard() {
    final title = Theme.of(context).textTheme.titleMedium;
    final fromKey = dayKey(_firstDay);
    final avgAll = movingAverage(_weights);
    // only what falls inside the visible range is drawn
    final idx = [
      for (var i = 0; i < _weights.length; i++)
        if (_weights[i].day.compareTo(fromKey) >= 0) i
    ];
    final shown = [for (final i in idx) _weights[i]];
    final shownAvg = [for (final i in idx) avgAll[i]];

    String stats;
    if (shown.isEmpty) {
      stats = 'No weight entries in this period.';
    } else {
      final latest = shown.last.kg;
      final avgNow = shownAvg.last;
      stats = 'Latest: ${latest.toStringAsFixed(1)} kg   '
          '7-day average: ${avgNow.toStringAsFixed(1)} kg';
      if (shown.length > 1) {
        final change = avgNow - shownAvg.first;
        stats += '   Change over the period (7-day average): '
            '${change >= 0 ? '+' : ''}${change.toStringAsFixed(1)} kg';
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Weight', style: title),
            Row(
              children: [
                Expanded(
                  child: numField(
                    controller: _kg,
                    label: 'Weight',
                    suffix: 'kg',
                    onSubmitted: (_) => _saveWeight(),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                    onPressed: _pickWeightDay,
                    child: Text(dayKey(_weightDay))),
                const SizedBox(width: 4),
                FilledButton(onPressed: _saveWeight, child: const Text('Save')),
              ],
            ),
            if (HealthImport.supported)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _importing ? null : _importHealth,
                  icon: const Icon(Icons.health_and_safety_outlined),
                  label: Text(_importing
                      ? 'Importing...'
                      : 'Import from Health Connect'),
                ),
              ),
            const SizedBox(height: 8),
            WeightChart(
              days: [for (final p in shown) p.day],
              kgs: [for (final p in shown) p.kg],
              average: shownAvg,
              startDay: fromKey,
              endDay: dayKey(_today),
            ),
            const SizedBox(height: 4),
            const Text('Dots: your entries. Line: 7-day average.',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Text(stats),
            const SizedBox(height: 8),
            for (final p in shown.reversed.take(8))
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
                      onPressed: () => _deleteWeight(p),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Progress'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Intake'),
            Tab(text: 'Weight'),
            Tab(text: 'Activity'),
          ]),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: _rangeSelector(),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  ListView(
                      padding: const EdgeInsets.all(12),
                      children: [_nutritionCard()]),
                  ListView(
                      padding: const EdgeInsets.all(12),
                      children: [_weightCard()]),
                  ActivityView(range: _range),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
