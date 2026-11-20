import 'package:flutter/material.dart';
import '../analysis.dart';
import '../db.dart';
import '../nutrients.dart';
import '../scatter_chart.dart';
import '../widgets.dart';
import '../workout_format.dart';
import '../workout_types.dart';
import 'exercise_progress_screen.dart';
import 'similar_runs_screen.dart';

/// Performance analysis across all your data: runs by distance and lifts.
class AnalysisScreen extends StatelessWidget {
  const AnalysisScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Performance analysis'),
          bottom: const TabBar(tabs: [Tab(text: 'Runs'), Tab(text: 'Lifts')]),
        ),
        body: const TabBarView(children: [_RunsTab(), _LiftsTab()]),
      ),
    );
  }
}

// ====================================================================
// runs
// ====================================================================

class _RunsTab extends StatefulWidget {
  const _RunsTab();

  @override
  State<_RunsTab> createState() => _RunsTabState();
}

class _RunsTabState extends State<_RunsTab> {
  List<Workout> _all = [];

  static const _dists = [1.0, 3.0, 5.0, 10.0, 15.0, 21.0975, 42.195];
  static const _names = ['1 km', '3 km', '5 km', '10 km', '15 km', 'Half marathon', 'Marathon'];

  @override
  void initState() {
    super.initState();
    _all = AppDb.instance.loadAllWorkouts();
  }

  Future<void> _open(double km) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SimilarRunsScreen(cat: Cat.run, km: km)),
    );
    setState(() => _all = AppDb.instance.loadAllWorkouts());
  }

  Future<void> _other() async {
    final ctl = TextEditingController(text: '8');
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
    if (ok == true && v != null && v > 0.2 && v < 1000) _open(v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = Theme.of(context).textTheme.titleMedium;
    final now = DateTime.now();
    String d(int n) => dayKey(DateTime(now.year, now.month, now.day - n));

    // all runs over time, grouped by distance
    final runs = [
      for (final w in _all)
        if (categoryOf(w.type) == Cat.run && (w.distanceM ?? 0) >= 1000 && paceSecPerKm(w) != null) w
    ]..sort((a, b) => a.startMs.compareTo(b.startMs));
    const labels = ['under 4 km', '4 to 8 km', '8 to 15 km', '15 km and more'];
    const lows = [0.0, 4.0, 8.0, 15.0];
    const highs = [4.0, 8.0, 15.0, 100000.0];
    final series = <ScatterSeries>[];
    for (var g = 0; g < 4; g++) {
      final pts = [
        for (final w in runs)
          if (w.distanceM! / 1000 >= lows[g] && w.distanceM! / 1000 < highs[g])
            ScatterPoint(
              DateTime.fromMillisecondsSinceEpoch(w.startMs),
              paceSecPerKm(w)!,
              '${w.day}\n${fmtPace(paceSecPerKm(w)!)} /km\n${fmt(w.distanceM! / 1000)} km',
            )
      ];
      if (pts.isNotEmpty) series.add(ScatterSeries(labels[g], pts));
    }

    // table by distance
    final rows = <Widget>[];
    for (var i = 0; i < _dists.length; i++) {
      final ms = similarByDistance(_all, Cat.run, _dists[i], 0.10);
      if (ms.isEmpty) continue;
      final paces = [for (final w in ms) if (paceSecPerKm(w) != null) paceSecPerKm(w)!];
      final recent = [for (final w in ms) if (w.day.compareTo(d(90)) >= 0) w];
      final before = [for (final w in ms) if (w.day.compareTo(d(180)) >= 0 && w.day.compareTo(d(90)) < 0) w];
      final rp = averageOf(recent, 'pace');
      final bp = averageOf(before, 'pace');
      final ch = pctChange(rp, bp);
      final hr = averageOf(ms, 'hr');
      final eff = averageOf(ms, 'eff');
      rows.add(ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('${_names[i]}   (${ms.length} run${ms.length > 1 ? 's' : ''})'),
        subtitle: Text([
          if (paces.isNotEmpty) 'best ${fmtPace(paces.reduce((a, b) => a < b ? a : b))} /km',
          if (paces.isNotEmpty) 'average ${fmtPace(paces.reduce((a, b) => a + b) / paces.length)} /km',
          if (hr != null) 'heart rate ${hr.round()} bpm',
          if (eff != null) '${eff.toStringAsFixed(2)} m/beat',
        ].join('  |  ')),
        trailing: ch == null
            ? null
            : Text(
                '${ch >= 0 ? '+' : ''}${ch.toStringAsFixed(1)} %\npace, 90 d',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, color: ch < 0 ? cs.primary : cs.error),
              ),
        onTap: () => _open(_dists[i]),
      ));
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pace of all runs', style: title),
                const Text('Each dot is a run, coloured by distance. Lines show the trend per group.',
                    style: TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                if (series.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('No runs with a distance yet.'),
                  )
                else
                  TimeScatterChart(series: series, yFormat: fmtPace),
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
                Text('By distance', style: title),
                const Text('Tap a distance to compare those runs in detail. '
                    'The change compares the last 90 days with the 90 days before (negative = faster).',
                    style: TextStyle(fontSize: 12)),
                ...rows,
                if (rows.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No runs yet.')),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _other,
                    icon: const Icon(Icons.edit),
                    label: const Text('Another distance...'),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const SimilarRunsScreen(cat: Cat.cycle, km: 20)),
                    ),
                    icon: const Icon(Icons.directions_bike),
                    label: const Text('Compare bike rides instead'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ====================================================================
// lifts
// ====================================================================

class _LiftsTab extends StatefulWidget {
  const _LiftsTab();

  @override
  State<_LiftsTab> createState() => _LiftsTabState();
}

class _LiftsTabState extends State<_LiftsTab> {
  Map<String, List<LiftSession>> _sessions = {};
  List<LiftSummary> _sums = [];
  final List<String> _pick = ['', '', '']; // lower-case exercise names
  bool _relative = true;
  String _sort = 'sessions';

  @override
  void initState() {
    super.initState();
    _sessions = allLiftSessions(AppDb.instance.loadAllWorkouts(withEx: true));
    final today = DateTime.now();
    _sums = [for (final e in _sessions.values) summarizeLift(e, today)];
    _sums.sort((a, b) => b.sessions.length.compareTo(a.sessions.length));
    final good = [for (final s in _sums) if (s.sessions.length >= 2 && s.best1rm != null) s];
    for (var i = 0; i < 3 && i < good.length; i++) {
      _pick[i] = good[i].name.toLowerCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    final cs = Theme.of(context).colorScheme;

    // compare lifts
    final series = <ScatterSeries>[];
    for (final key in _pick) {
      final ss = _sessions[key];
      if (key.isEmpty || ss == null) continue;
      final vals = [for (final s in ss) if (s.best1rm != null) MapEntry(s, s.best1rm!)];
      if (vals.isEmpty) continue;
      final first3 = vals.take(3).map((e) => e.value).toList();
      final base = first3.reduce((a, b) => a + b) / first3.length;
      series.add(ScatterSeries(
        ss.first.name,
        [
          for (final e in vals)
            ScatterPoint(
              DateTime.fromMillisecondsSinceEpoch(e.key.w.startMs),
              _relative ? (e.value / base * 100 - 100) : e.value,
              '${ss.first.name}\n${e.key.w.day}\nest. 1RM ${fmt(e.value)} kg  (${e.key.setText(e.key.bestSet!)})',
            )
        ],
        connect: true,
        trend: false,
      ));
    }

    // progress of every lift
    final sums = [..._sums];
    int cmp(num? a, num? b) => (b ?? double.negativeInfinity).compareTo(a ?? double.negativeInfinity);
    switch (_sort) {
      case 'change':
        sums.sort((a, b) => cmp(pctChange(a.rec90, a.prev90), pctChange(b.rec90, b.prev90)));
        break;
      case 'best':
        sums.sort((a, b) => cmp(a.best1rm, b.best1rm));
        break;
      case 'recent':
        sums.sort((a, b) => b.sessions.last.w.day.compareTo(a.sessions.last.w.day));
        break;
      default:
        sums.sort((a, b) => b.sessions.length.compareTo(a.sessions.length));
    }

    final names = [for (final s in _sums) s.name];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Compare lifts', style: title),
                const Text('Best estimated 1RM of each session, up to three exercises.',
                    style: TextStyle(fontSize: 12)),
                for (var i = 0; i < 3; i++)
                  DropdownButton<String>(
                    isExpanded: true,
                    value: names.any((n) => n.toLowerCase() == _pick[i]) ? _pick[i] : '',
                    items: [
                      const DropdownMenuItem(value: '', child: Text('(none)')),
                      for (final n in names)
                        DropdownMenuItem(value: n.toLowerCase(), child: Text(n)),
                    ],
                    onChanged: (v) => setState(() => _pick[i] = v ?? ''),
                  ),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Change in %'),
                      selected: _relative,
                      onSelected: (_) => setState(() => _relative = true),
                    ),
                    ChoiceChip(
                      label: const Text('Weight in kg'),
                      selected: !_relative,
                      onSelected: (_) => setState(() => _relative = false),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (series.isEmpty)
                  const Text('Pick at least one exercise with sets of 1 to 12 repetitions.')
                else
                  TimeScatterChart(
                    series: series,
                    yFormat: (v) => _relative ? '${v >= 0 ? '+' : ''}${v.round()} %' : v.round().toString(),
                  ),
                if (_relative && series.isNotEmpty)
                  const Text('% change is relative to the average of the first three sessions, '
                      'so lifts with different weights can be compared.',
                      style: TextStyle(fontSize: 12)),
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
                Text('Progress of all lifts', style: title),
                DropdownButton<String>(
                  value: _sort,
                  items: const [
                    DropdownMenuItem(value: 'sessions', child: Text('Most sessions')),
                    DropdownMenuItem(value: 'change', child: Text('Biggest change, last 90 days')),
                    DropdownMenuItem(value: 'best', child: Text('Highest estimated 1RM')),
                    DropdownMenuItem(value: 'recent', child: Text('Most recently done')),
                  ],
                  onChanged: (v) => setState(() => _sort = v ?? 'sessions'),
                ),
                if (sums.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('No exercises yet. Import your Hevy workouts first.'),
                  ),
                for (final s in sums.take(60))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(s.name),
                    subtitle: Text([
                      '${s.sessions.length} sessions',
                      if (s.best1rm != null) 'best ${fmt(s.best1rm!)} kg',
                      if (s.start1rm != null && s.current1rm != null)
                        'start ${fmt(s.start1rm!)} to now ${fmt(s.current1rm!)} kg',
                      if (s.rec90 != null && s.prev90 != null)
                        'last 90 d ${fmt(s.rec90!)} kg vs ${fmt(s.prev90!)} kg before',
                    ].join('  |  ')),
                    trailing: pctChange(s.rec90, s.prev90) == null
                        ? null
                        : Text(
                            '${pctChange(s.rec90, s.prev90)! >= 0 ? '+' : ''}${pctChange(s.rec90, s.prev90)!.toStringAsFixed(1)} %',
                            style: TextStyle(
                              color: pctChange(s.rec90, s.prev90)! >= 0 ? cs.primary : cs.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ExerciseDetailScreen(name: s.name)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
