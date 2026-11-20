import 'package:flutter/material.dart';
import '../analysis.dart';
import '../db.dart';
import '../nutrients.dart';
import '../scatter_chart.dart';
import '../widgets.dart';
import '../workout_format.dart';
import '../workout_types.dart';
import 'workout_detail_screen.dart';

/// Compare workouts over about the same distance: pace or speed, heart rate,
/// efficiency, ... over time, between periods, or between two sessions.
class SimilarRunsScreen extends StatefulWidget {
  final Cat cat;
  final double km;
  final double tol; // 0.1 = 10 %
  const SimilarRunsScreen({super.key, this.cat = Cat.run, this.km = 5, this.tol = 0.10});

  @override
  State<SimilarRunsScreen> createState() => _SimilarRunsScreenState();
}

class _SimilarRunsScreenState extends State<SimilarRunsScreen> {
  late Cat _cat;
  late double _km;
  late double _tol;
  String _metric = 'pace';
  String _range = 'all'; // all | year | quarter
  int _cmpDays = 90;
  final List<String> _selected = []; // up to two workout ids
  List<Workout> _all = [];

  static const _footPresets = [1.0, 3.0, 5.0, 10.0, 15.0, 21.0975, 42.195];
  static const _footNames = ['1 km', '3 km', '5 km', '10 km', '15 km', 'Half marathon', 'Marathon'];
  static const _cyclePresets = [10.0, 20.0, 30.0, 50.0, 100.0, 150.0];

  @override
  void initState() {
    super.initState();
    _cat = widget.cat;
    _km = widget.km;
    _tol = widget.tol;
    _metric = _cat == Cat.cycle ? 'speed' : 'pace';
    _all = AppDb.instance.loadAllWorkouts();
  }

  List<double> get _presets => _cat == Cat.cycle ? _cyclePresets : _footPresets;

  String _presetName(int i) =>
      _cat == Cat.cycle ? '${_cyclePresets[i].round()} km' : _footNames[i];

  List<Workout> _allMatches() => similarByDistance(_all, _cat, _km, _tol);

  List<Workout> _matches() {
    final m = _allMatches();
    if (_range == 'all') return m;
    final days = _range == 'year' ? 365 : 90;
    final now = DateTime.now();
    final cut = dayKey(DateTime(now.year, now.month, now.day - days));
    return [for (final w in m) if (w.day.compareTo(cut) >= 0) w];
  }

  List<String> _metricKeys(List<Workout> ms) {
    final order = _cat == Cat.cycle
        ? ['speed', 'time', 'hr', 'eff', 'power', 'elev', 'maxhr']
        : ['pace', 'time', 'hr', 'eff', 'cadence', 'elev', 'maxhr'];
    return [for (final k in order) if (ms.any((w) => runMetric(k, w) != null)) k];
  }

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
        if (_selected.length > 2) _selected.removeAt(0);
      }
    });
  }

  Future<void> _open(Workout w) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WorkoutDetailScreen(workoutId: w.id)),
    );
    setState(() => _all = AppDb.instance.loadAllWorkouts());
  }

  Future<void> _customDistance() async {
    final ctl = TextEditingController(text: rawNum(_km));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Distance'),
        content: numField(
          controller: ctl,
          label: 'Distance',
          suffix: 'km',
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('OK')),
        ],
      ),
    );
    final v = parseNum(ctl.text);
    if (ok == true && v != null && v > 0.2 && v < 1000) {
      setState(() {
        _km = v;
        _selected.clear();
      });
    }
  }

  String _unitOf(String m) =>
      const {'speed': 'km/h', 'hr': 'bpm', 'maxhr': 'bpm', 'eff': 'm/beat', 'cadence': 'spm', 'power': 'W', 'elev': 'm'}[m] ?? '';

  // a difference, as text
  String _delta(String key, double? a, double? b) {
    if (a == null || b == null) return '';
    final d = a - b;
    if (key == 'pace' || key == 'time') {
      return signed(d, key == 'pace' ? fmtPace(d.abs()) : hms(d.abs()));
    }
    return signed(d, d.abs().toStringAsFixed(key == 'eff' ? 2 : 1));
  }

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    final ms = _matches();
    final keys = _metricKeys(ms);
    final metric = keys.contains(_metric) ? _metric : (keys.isEmpty ? 'time' : keys.first);
    final cats = [Cat.run, Cat.walk, Cat.hike, Cat.cycle]
        .where((c) => _all.any((w) => categoryOf(w.type) == c && (w.distanceM ?? 0) > 0))
        .toList();
    if (!cats.contains(_cat)) cats.add(_cat);

    // chart data
    final vals = [for (final w in ms) if (runMetric(metric, w) != null) w];
    double? bestV;
    if (vals.isNotEmpty) {
      final v = [for (final w in vals) runMetric(metric, w)!];
      if (lowerIsBetter(metric)) bestV = v.reduce((a, b) => a < b ? a : b);
      if (higherIsBetter(metric)) bestV = v.reduce((a, b) => a > b ? a : b);
    }
    final points = [
      for (final w in vals)
        ScatterPoint(
          DateTime.fromMillisecondsSinceEpoch(w.startMs),
          runMetric(metric, w)!,
          '${w.day}\n${runMetricText(metric, runMetric(metric, w)!)}\n${fmt((w.distanceM ?? 0) / 1000)} km',
          star: bestV != null && runMetric(metric, w) == bestV,
        )
    ];

    // summary text
    final summary = <String>[];
    if (points.isNotEmpty) {
      final v = [for (final p in points) p.y];
      final avg = v.reduce((a, b) => a + b) / v.length;
      summary.add('${points.length} workout(s) with this data. '
          'Average ${runMetricText(metric, avg)}, latest ${runMetricText(metric, v.last)}.');
      if (bestV != null) summary.add('Best: ${runMetricText(metric, bestV)}.');
      if (v.length > 1) {
        final ch = pctChange(v.last, v.first);
        if (ch != null) {
          summary.add('First to latest: ${runMetricText(metric, v.first)} to ${runMetricText(metric, v.last)} '
              '(${ch >= 0 ? '+' : ''}${ch.toStringAsFixed(1)} %).');
        }
      }
      final line = fitLine(
          [for (final p in points) p.t.millisecondsSinceEpoch / 86400000.0], v);
      if (line != null) {
        final perYear = line.slope * 365;
        final txt = (metric == 'pace')
            ? '${signed(perYear, fmtPace(perYear.abs()))} /km'
            : (metric == 'time')
                ? signed(perYear, hms(perYear.abs()))
                : '${signed(perYear, perYear.abs().toStringAsFixed(metric == 'eff' ? 2 : 1))} ${_unitOf(metric)}';
        summary.add('Trend line: $txt per year.');
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Compare similar workouts')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButton<Cat>(
                    value: _cat,
                    items: [for (final c in cats) DropdownMenuItem(value: c, child: Text(catLabel(c)))],
                    onChanged: (c) {
                      if (c == null) return;
                      setState(() {
                        _cat = c;
                        _km = c == Cat.cycle ? 20 : 5;
                        _metric = c == Cat.cycle ? 'speed' : 'pace';
                        _selected.clear();
                      });
                    },
                  ),
                  const Text('Distance'),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (var i = 0; i < _presets.length; i++)
                        ChoiceChip(
                          label: Text(_presetName(i)),
                          selected: (_km - _presets[i]).abs() < 0.001,
                          onSelected: (_) => setState(() {
                            _km = _presets[i];
                            _selected.clear();
                          }),
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.edit, size: 16),
                        label: Text('Other (${fmt(_km)} km)'),
                        onPressed: _customDistance,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('Counts as similar when within'),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final t in [0.05, 0.10, 0.20])
                        ChoiceChip(
                          label: Text('± ${(t * 100).round()} %'),
                          selected: (_tol - t).abs() < 0.001,
                          onSelected: (_) => setState(() {
                            _tol = t;
                            _selected.clear();
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final r in {'all': 'All time', 'year': 'Last 12 months', 'quarter': 'Last 90 days'}.entries)
                        ChoiceChip(
                          label: Text(r.value),
                          selected: _range == r.key,
                          onSelected: (_) => setState(() => _range = r.key),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${ms.length} workout(s) within ± ${(_tol * 100).round()} % of ${fmt(_km)} km',
                      style: title),
                  if (keys.isNotEmpty)
                    DropdownButton<String>(
                      value: metric,
                      items: [
                        for (final k in keys)
                          DropdownMenuItem(value: k, child: Text(runMetricLabels[k] ?? k)),
                      ],
                      onChanged: (v) => setState(() => _metric = v ?? metric),
                    ),
                  if (points.length < 2)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Not enough data for a chart. Try a wider distance range or another period.'),
                    )
                  else
                    TimeScatterChart(
                      series: [ScatterSeries(runMetricLabels[metric] ?? metric, points, connect: points.length < 40)],
                      yFormat: (v) => runMetricAxis(metric, v),
                    ),
                  const SizedBox(height: 8),
                  for (final line in summary) Text(line),
                  if (points.length >= 2)
                    const Text('Ringed point: your best. Straight line: trend. Tap a point for details.',
                        style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
          _periodCard(keys),
          _pairCard(),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Workouts', style: title),
                  const Text('Tick two to compare them side by side.', style: TextStyle(fontSize: 12)),
                  for (final w in ms.reversed.take(60))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Checkbox(
                        value: _selected.contains(w.id),
                        onChanged: (_) => _toggle(w.id),
                      ),
                      title: Text('${w.day}  ${workoutTitle(w)}'),
                      subtitle: Text([
                        '${fmt((w.distanceM ?? 0) / 1000)} km',
                        for (final k in ['time', _cat == Cat.cycle ? 'speed' : 'pace', 'hr', 'eff'])
                          if (runMetric(k, w) != null) runMetricText(k, runMetric(k, w)!),
                      ].join('  |  ')),
                      trailing: IconButton(
                        icon: const Icon(Icons.open_in_new),
                        tooltip: 'Open',
                        onPressed: () => _open(w),
                      ),
                      onTap: () => _toggle(w.id),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Recent period against the period before it, for the matching workouts.
  Widget _periodCard(List<String> keys) {
    final all = _allMatches();
    final now = DateTime.now();
    String d(int n) => dayKey(DateTime(now.year, now.month, now.day - n));
    final recent = [for (final w in all) if (w.day.compareTo(d(_cmpDays)) >= 0) w];
    final prev = [
      for (final w in all)
        if (w.day.compareTo(d(2 * _cmpDays)) >= 0 && w.day.compareTo(d(_cmpDays)) < 0) w
    ];
    final title = Theme.of(context).textTheme.titleMedium;
    final rows = <TableRow>[
      TableRow(children: [
        const SizedBox.shrink(),
        const Text('Recent', style: TextStyle(fontWeight: FontWeight.w600)),
        const Text('Before', style: TextStyle(fontWeight: FontWeight.w600)),
        const Text('Change', style: TextStyle(fontWeight: FontWeight.w600)),
      ]),
      TableRow(children: [
        const Text('Workouts'),
        Text('${recent.length}'),
        Text('${prev.length}'),
        Text(signed((recent.length - prev.length).toDouble(), '${(recent.length - prev.length).abs()}')),
      ]),
      for (final k in keys)
        if (averageOf(recent, k) != null || averageOf(prev, k) != null)
          TableRow(children: [
            Text(runMetricLabels[k] ?? k, style: const TextStyle(fontSize: 12)),
            Text(averageOf(recent, k) == null ? '-' : runMetricText(k, averageOf(recent, k)!),
                style: const TextStyle(fontSize: 12)),
            Text(averageOf(prev, k) == null ? '-' : runMetricText(k, averageOf(prev, k)!),
                style: const TextStyle(fontSize: 12)),
            Text(_delta(k, averageOf(recent, k), averageOf(prev, k)),
                style: const TextStyle(fontSize: 12)),
          ]),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Period against period', style: title),
            DropdownButton<int>(
              value: _cmpDays,
              items: [
                for (final n in [30, 90, 180, 365])
                  DropdownMenuItem(value: n, child: Text('Last $n days against the $n days before')),
              ],
              onChanged: (v) => setState(() => _cmpDays = v ?? _cmpDays),
            ),
            const SizedBox(height: 4),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(2.2),
                1: FlexColumnWidth(1.6),
                2: FlexColumnWidth(1.6),
                3: FlexColumnWidth(1.4),
              },
              children: rows,
            ),
            const Text('Averages of the matching workouts in each period.',
                style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  /// Two ticked workouts side by side.
  Widget _pairCard() {
    if (_selected.length != 2) return const SizedBox.shrink();
    final found = [for (final id in _selected) _all.where((w) => w.id == id)]
        .where((l) => l.isNotEmpty)
        .map((l) => l.first)
        .toList();
    if (found.length != 2) return const SizedBox.shrink();
    found.sort((a, b) => a.startMs.compareTo(b.startMs));
    final a = AppDb.instance.loadWorkout(found[0].id) ?? found[0];
    final b = AppDb.instance.loadWorkout(found[1].id) ?? found[1];
    final order = _cat == Cat.cycle
        ? ['time', 'speed', 'hr', 'maxhr', 'eff', 'power', 'elev']
        : ['time', 'pace', 'hr', 'maxhr', 'eff', 'cadence', 'power', 'elev'];
    final rows = <TableRow>[
      TableRow(children: [
        const SizedBox.shrink(),
        Text(a.day, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(b.day, style: const TextStyle(fontWeight: FontWeight.w600)),
        const Text('Change', style: TextStyle(fontWeight: FontWeight.w600)),
      ]),
      TableRow(children: [
        const Text('Distance', style: TextStyle(fontSize: 12)),
        Text('${fmt((a.distanceM ?? 0) / 1000)} km', style: const TextStyle(fontSize: 12)),
        Text('${fmt((b.distanceM ?? 0) / 1000)} km', style: const TextStyle(fontSize: 12)),
        const SizedBox.shrink(),
      ]),
      for (final k in order)
        if (runMetric(k, a) != null || runMetric(k, b) != null)
          TableRow(children: [
            Text(runMetricLabels[k] ?? k, style: const TextStyle(fontSize: 12)),
            Text(runMetric(k, a) == null ? '-' : runMetricText(k, runMetric(k, a)!),
                style: const TextStyle(fontSize: 12)),
            Text(runMetric(k, b) == null ? '-' : runMetricText(k, runMetric(k, b)!),
                style: const TextStyle(fontSize: 12)),
            Text(_delta(k, runMetric(k, b), runMetric(k, a)), style: const TextStyle(fontSize: 12)),
          ]),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Side by side', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(2.2),
                1: FlexColumnWidth(1.6),
                2: FlexColumnWidth(1.6),
                3: FlexColumnWidth(1.4),
              },
              children: rows,
            ),
            if (a.hr.length > 1 && b.hr.length > 1) ...[
              const SizedBox(height: 12),
              const Text('Heart rate during the workout'),
              OverlayChart(series: [
                OverlaySeries(a.day, a.hr),
                OverlaySeries(b.day, b.hr),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
