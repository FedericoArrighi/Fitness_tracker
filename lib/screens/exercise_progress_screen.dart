import 'package:flutter/material.dart';
import '../analysis.dart';
import '../chart_view.dart';
import '../db.dart';
import '../metrics.dart';
import '../nutrients.dart';
import '../scatter_chart.dart';
import 'workout_detail_screen.dart';

double? _e1rm(double kg, double reps) {
  if (kg <= 0 || reps < 1 || reps > 12) return null;
  return reps == 1 ? kg : kg * (1 + reps / 30); // Epley formula
}

List<Map<String, dynamic>> _workingSets(Map<String, dynamic> ex) => [
      for (final s in ((ex['sets'] as List?) ?? const []))
        if (((s as Map)['type'] ?? 'normal') != 'warmup') s.cast<String, dynamic>()
    ];

String _setText(Map<String, dynamic> s) {
  final kg = (s['kg'] as num?)?.toDouble();
  final reps = (s['reps'] as num?)?.toDouble();
  final rpe = (s['rpe'] as num?)?.toDouble();
  final at = (rpe != null && rpe > 0) ? ' @${rawNum((rpe * 10).round() / 10)}' : '';
  if (kg != null && kg > 0 && reps != null) {
    return '${rawNum((kg * 10).round() / 10)}×${reps.round()}$at';
  }
  if (reps != null && reps > 0) return '${reps.round()} reps$at';
  return 'set';
}

class _ExStat {
  final String name;
  int sessions = 0;
  String last = '';
  double best1rm = 0;
  double maxKg = 0;
  _ExStat(this.name);
}

/// All exercises you have done, most frequent first.
class ExerciseListScreen extends StatefulWidget {
  /// true when it sits inside another screen (no app bar of its own)
  final bool embedded;
  const ExerciseListScreen({super.key, this.embedded = false});

  @override
  State<ExerciseListScreen> createState() => _ExerciseListScreenState();
}

class _ExerciseListScreenState extends State<ExerciseListScreen> {
  List<_ExStat> _stats = [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    final map = <String, _ExStat>{};
    for (final w in AppDb.instance.loadAllWorkouts(withEx: true)) {
      for (final ex in w.exercises) {
        final name = (ex['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        final st = map.putIfAbsent(name.toLowerCase(), () => _ExStat(name));
        st.sessions++;
        if (w.day.compareTo(st.last) > 0) st.last = w.day;
        for (final s in _workingSets(ex)) {
          final kg = (s['kg'] as num?)?.toDouble() ?? 0;
          final reps = (s['reps'] as num?)?.toDouble() ?? 0;
          if (kg > st.maxKg) st.maxKg = kg;
          final e = _e1rm(kg, reps);
          if (e != null && e > st.best1rm) st.best1rm = e;
        }
      }
    }
    _stats = map.values.toList()..sort((a, b) => b.sessions.compareTo(a.sessions));
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = q.isEmpty ? _stats : [for (final s in _stats) if (s.name.toLowerCase().contains(q)) s];
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Lift progress')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search exercises',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? const Center(
                    child: Text('No exercises yet. Import your Hevy workouts first.'))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final s = list[i];
                      return ListTile(
                        title: Text(s.name),
                        subtitle: Text('${s.sessions} session(s), last ${s.last}'
                            '${s.maxKg > 0 ? ', heaviest ${fmt(s.maxKg)} kg' : ''}'
                            '${s.best1rm > 0 ? ', est. 1RM ${fmt(s.best1rm)} kg' : ''}'),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ExerciseDetailScreen(name: s.name)),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Session {
  final Workout w;
  final List<Map<String, dynamic>> sets; // working sets
  _Session(this.w, this.sets);
}

/// Records, progress charts (with comparison of periods) and history of
/// one exercise.
class ExerciseDetailScreen extends StatelessWidget {
  final String name;
  const ExerciseDetailScreen({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    final key = name.trim().toLowerCase();
    final all = AppDb.instance.loadAllWorkouts(withEx: true);
    final ls = liftSessionsFor(all, name);
    final sessions = <_Session>[];
    for (final w in all) {
      for (final ex in w.exercises) {
        if ((ex['name'] ?? '').toString().trim().toLowerCase() == key) {
          sessions.add(_Session(w, _workingSets(ex)));
        }
      }
    }

    // records
    double maxKg = 0, best1rm = 0, bestVol = 0, totalVol = 0;
    String maxKgText = '', maxKgDay = '', best1rmDay = '', bestVolDay = '';
    const repLevels = [1, 2, 3, 5, 8, 10, 12];
    final repBest = <int, double>{};
    final repDay = <int, String>{};
    for (final s in sessions) {
      var vol = 0.0;
      for (final set in s.sets) {
        final kg = (set['kg'] as num?)?.toDouble() ?? 0;
        final reps = (set['reps'] as num?)?.toDouble() ?? 0;
        vol += kg * reps;
        if (kg > maxKg) {
          maxKg = kg;
          maxKgText = _setText(set);
          maxKgDay = s.w.day;
        }
        final e = _e1rm(kg, reps);
        if (e != null && e > best1rm) {
          best1rm = e;
          best1rmDay = s.w.day;
        }
        for (final r in repLevels) {
          if (reps >= r && kg > (repBest[r] ?? 0)) {
            repBest[r] = kg;
            repDay[r] = s.w.day;
          }
        }
      }
      totalVol += vol;
      if (vol > bestVol) {
        bestVol = vol;
        bestVolDay = s.w.day;
      }
    }
    final title = Theme.of(context).textTheme.titleMedium;
    final metrics = exerciseMetrics(name);

    Widget tile(String label, String value, String note) => SizedBox(
          width: 150,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: Theme.of(context).textTheme.titleLarge),
              Text(label, style: const TextStyle(fontSize: 12)),
              if (note.isNotEmpty) Text(note, style: const TextStyle(fontSize: 11)),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  tile('Sessions', '${sessions.length}', ''),
                  if (maxKg > 0) tile('Heaviest set', '$maxKgText kg', maxKgDay),
                  if (best1rm > 0)
                    tile('Best estimated 1RM', '${fmt(best1rm)} kg', best1rmDay),
                  if (bestVol > 0)
                    tile('Most volume', '${fmt(bestVol)} kg', bestVolDay),
                  if (totalVol > 0) tile('Total volume', '${fmt(totalVol)} kg', ''),
                ],
              ),
            ),
          ),
          if (repBest.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Heaviest weight for at least ... repetitions', style: title),
                    const SizedBox(height: 8),
                    for (final r in repLevels)
                      if (repBest.containsKey(r))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('$r rep${r > 1 ? 's' : ''}'),
                              Text('${fmt(repBest[r]!)} kg   ${repDay[r]}'),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ),
          _SimilarSetsCard(sessions: ls),
          MetricChart(
            key: ValueKey('lift-$name'),
            metrics: metrics,
            initialMetric: 'ex:1rm',
            initialDays: 365,
          ),
          _SessionCompareCard(sessions: ls),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('History', style: title),
                  for (final s in sessions.take(40))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${s.w.day}  ${s.w.title}'),
                      subtitle: Text(s.sets.map(_setText).join(',  ')),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => WorkoutDetailScreen(workoutId: s.w.id)),
                      ),
                    ),
                  if (sessions.length > 40)
                    const Text('Showing the 40 most recent sessions.',
                        style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}


// ====================================================================
// same weight / same repetitions
// ====================================================================

class _SimilarSetsCard extends StatefulWidget {
  final List<LiftSession> sessions;
  const _SimilarSetsCard({required this.sessions});

  @override
  State<_SimilarSetsCard> createState() => _SimilarSetsCardState();
}

class _SimilarSetsCardState extends State<_SimilarSetsCard> {
  String _mode = 'weight'; // weight | reps
  double? _weight;
  int _reps = 5;
  double _tol = 1.25;
  bool _atLeast = false;
  List<double> _weights = [];

  @override
  void initState() {
    super.initState();
    final counts = <double, int>{};
    for (final s in widget.sessions) {
      final seen = <double>{};
      for (final set in s.sets) {
        if (set.kg <= 0) continue;
        final k = (set.kg * 4).round() / 4;
        if (seen.add(k)) counts[k] = (counts[k] ?? 0) + 1;
      }
    }
    final top = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    _weights = (top.take(10).toList()..sort());
    if (top.isNotEmpty) {
      _weight = top.first;
    } else {
      _mode = 'reps';
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    final entries = <MapEntry<LiftSession, MapEntry<double, LiftSet>>>[];
    for (final s in widget.sessions) {
      double? v;
      LiftSet? bs;
      for (final set in s.sets) {
        if (_mode == 'weight') {
          final w = _weight;
          if (w == null || (set.kg - w).abs() > _tol) continue;
          if (v == null || set.reps > v) {
            v = set.reps;
            bs = set;
          }
        } else {
          final ok = set.kg > 0 && (_atLeast ? set.reps >= _reps : set.reps == _reps);
          if (!ok) continue;
          if (v == null || set.kg > v) {
            v = set.kg;
            bs = set;
          }
        }
      }
      if (v != null && bs != null) entries.add(MapEntry(s, MapEntry(v, bs)));
    }
    double? best;
    if (entries.isNotEmpty) {
      best = entries.map((e) => e.value.key).reduce((a, b) => a > b ? a : b);
    }
    final points = [
      for (final e in entries)
        ScatterPoint(
          DateTime.fromMillisecondsSinceEpoch(e.key.w.startMs),
          e.value.key,
          '${e.key.w.day}\n${e.key.setText(e.value.value)}',
          star: best != null && e.value.key == best,
        )
    ];
    final unit = _mode == 'weight' ? 'reps' : 'kg';
    final summary = <String>[];
    if (points.isNotEmpty) {
      final v = [for (final p in points) p.y];
      summary.add('${points.length} session(s). First ${fmt(v.first)} $unit, latest ${fmt(v.last)} $unit, best ${fmt(best!)} $unit.');
      final ch = pctChange(v.last, v.first);
      if (points.length > 1 && ch != null) {
        summary.add('First to latest: ${ch >= 0 ? '+' : ''}${ch.toStringAsFixed(1)} %.');
      }
      final line = fitLine([for (final p in points) p.t.millisecondsSinceEpoch / 86400000.0], v);
      if (line != null) {
        final perYear = line.slope * 365;
        summary.add('Trend line: ${signed(perYear, perYear.abs().toStringAsFixed(1))} $unit per year.');
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Compare similar sets', style: title),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                    value: 'weight',
                    enabled: _weights.isNotEmpty,
                    label: const Text('Same weight')),
                const ButtonSegment(value: 'reps', label: Text('Same reps')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 8),
            if (_mode == 'weight') ...[
              const Text('Weight (most used)'),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final w in _weights)
                    ChoiceChip(
                      label: Text('${rawNum(w)} kg'),
                      selected: _weight == w,
                      onSelected: (_) => setState(() => _weight = w),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: [
                  const Padding(padding: EdgeInsets.only(top: 8), child: Text('Tolerance')),
                  for (final t in [0.0, 1.25, 2.5])
                    ChoiceChip(
                      label: Text(t == 0 ? 'exact' : '± ${rawNum(t)} kg'),
                      selected: _tol == t,
                      onSelected: (_) => setState(() => _tol = t),
                    ),
                ],
              ),
              const Text('Shows the most repetitions you did at that weight in each session.',
                  style: TextStyle(fontSize: 12)),
            ] else ...[
              Row(
                children: [
                  const Text('Repetitions  '),
                  DropdownButton<int>(
                    value: _reps,
                    items: [for (var r = 1; r <= 15; r++) DropdownMenuItem(value: r, child: Text('$r'))],
                    onChanged: (v) => setState(() => _reps = v ?? _reps),
                  ),
                  const SizedBox(width: 12),
                  FilterChip(
                    label: const Text('or more'),
                    selected: _atLeast,
                    onSelected: (v) => setState(() => _atLeast = v),
                  ),
                ],
              ),
              const Text('Shows the heaviest weight you lifted for that number of repetitions in each session.',
                  style: TextStyle(fontSize: 12)),
            ],
            const SizedBox(height: 8),
            if (points.length < 2)
              Text(points.isEmpty
                  ? 'No matching sets. Try another weight, a tolerance, or another number of repetitions.'
                  : 'Only one matching session so far.')
            else
              TimeScatterChart(
                series: [ScatterSeries(unit, points, connect: true)],
                yFormat: (v) => _mode == 'weight' ? v.round().toString() : fmt(v),
              ),
            for (final line in summary) Text(line),
          ],
        ),
      ),
    );
  }
}

// ====================================================================
// two sessions side by side
// ====================================================================

class _SessionCompareCard extends StatefulWidget {
  final List<LiftSession> sessions; // oldest first
  const _SessionCompareCard({required this.sessions});

  @override
  State<_SessionCompareCard> createState() => _SessionCompareCardState();
}

class _SessionCompareCardState extends State<_SessionCompareCard> {
  int _a = 1, _b = 0; // indices in the newest-first list

  @override
  Widget build(BuildContext context) {
    final ss = widget.sessions.reversed.toList();
    if (ss.length < 2) return const SizedBox.shrink();
    final a = ss[_a.clamp(0, ss.length - 1)];
    final b = ss[_b.clamp(0, ss.length - 1)];
    String label(LiftSession s) =>
        '${s.w.day}  ${s.bestSet == null ? '' : s.setText(s.bestSet!)}';
    String delta(double? x, double? y, {int dec = 0}) {
      if (x == null || y == null) return '';
      final d = y - x;
      final pct = x != 0 ? '  (${d >= 0 ? '+' : ''}${(d / x * 100).toStringAsFixed(1)} %)' : '';
      return '${d >= 0 ? '+' : '-'}${d.abs().toStringAsFixed(dec)}$pct';
    }

    final avgA = a.totalReps > 0 ? a.volume / a.totalReps : null;
    final avgB = b.totalReps > 0 ? b.volume / b.totalReps : null;
    TableRow row(String name, String x, String y, String d) => TableRow(children: [
          Text(name, style: const TextStyle(fontSize: 12)),
          Text(x, style: const TextStyle(fontSize: 12)),
          Text(y, style: const TextStyle(fontSize: 12)),
          Text(d, style: const TextStyle(fontSize: 12)),
        ]);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Compare two sessions', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final pair in [('First', true), ('Second', false)])
              Row(
                children: [
                  SizedBox(width: 60, child: Text(pair.$1)),
                  Expanded(
                    child: DropdownButton<int>(
                      isExpanded: true,
                      value: (pair.$2 ? _a : _b).clamp(0, ss.length - 1),
                      items: [
                        for (var i = 0; i < ss.length && i < 100; i++)
                          DropdownMenuItem(value: i, child: Text(label(ss[i]))),
                      ],
                      onChanged: (v) => setState(() {
                        if (pair.$2) {
                          _a = v ?? _a;
                        } else {
                          _b = v ?? _b;
                        }
                      }),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 4),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(1.8),
                1: FlexColumnWidth(1.5),
                2: FlexColumnWidth(1.5),
                3: FlexColumnWidth(2),
              },
              children: [
                row('', a.w.day, b.w.day, 'Change'),
                row('Sets', '${a.sets.length}', '${b.sets.length}',
                    delta(a.sets.length.toDouble(), b.sets.length.toDouble())),
                row('Total reps', '${a.totalReps.round()}', '${b.totalReps.round()}',
                    delta(a.totalReps, b.totalReps)),
                row('Volume', '${fmt(a.volume)} kg', '${fmt(b.volume)} kg', delta(a.volume, b.volume)),
                row('Heaviest set', '${fmt(a.maxKg)} kg', '${fmt(b.maxKg)} kg',
                    delta(a.maxKg, b.maxKg, dec: 1)),
                row('Est. 1RM', a.best1rm == null ? '-' : '${fmt(a.best1rm!)} kg',
                    b.best1rm == null ? '-' : '${fmt(b.best1rm!)} kg', delta(a.best1rm, b.best1rm, dec: 1)),
                row('Average weight / rep', avgA == null ? '-' : '${fmt(avgA)} kg',
                    avgB == null ? '-' : '${fmt(avgB)} kg', delta(avgA, avgB, dec: 1)),
              ],
            ),
            const SizedBox(height: 8),
            Text('${a.w.day}:  ${a.sets.map(a.setText).join(',  ')}', style: const TextStyle(fontSize: 12)),
            Text('${b.w.day}:  ${b.sets.map(b.setText).join(',  ')}', style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
