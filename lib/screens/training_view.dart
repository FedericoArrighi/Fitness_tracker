import 'package:flutter/material.dart';
import '../chart_view.dart';
import '../db.dart';
import '../metrics.dart';
import '../nutrients.dart';
import '../training_stats.dart';
import '../workout_format.dart';
import '../workout_types.dart';
import 'analysis_screen.dart';
import 'exercise_progress_screen.dart';
import 'gym_workout_screen.dart';
import 'workout_detail_screen.dart';

/// Statistics of your workouts: totals per week / month / year with
/// comparison, charts, records, heatmap and lift progress.
class TrainingView extends StatefulWidget {
  final int reloadToken;
  const TrainingView({super.key, this.reloadToken = 0});

  @override
  State<TrainingView> createState() => _TrainingViewState();
}

class _TrainingViewState extends State<TrainingView> {
  String _catKey = 'all'; // 'all' or a Cat name
  String _period = 'month';
  List<Workout> _all = [];

  Cat? get _cat => _catKey == 'all' ? null : Cat.values.byName(_catKey);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TrainingView old) {
    super.didUpdateWidget(old);
    if (old.reloadToken != widget.reloadToken) _load();
  }

  void _load() {
    setState(() => _all = AppDb.instance.loadAllWorkouts());
  }

  List<Workout> _filtered() =>
      _cat == null ? _all : [for (final w in _all) if (categoryOf(w.type) == _cat) w];

  Future<void> _open(Workout w) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WorkoutDetailScreen(workoutId: w.id)),
    );
    _load();
  }

  String _delta(double cur, double? prev) {
    if (prev == null || prev <= 0) return '';
    final pct = (cur - prev) / prev * 100;
    return '  (${pct >= 0 ? '+' : ''}${pct.round()} % vs previous)';
  }

  Widget _controls() {
    final present = Cat.values.where((c) => _all.any((w) => categoryOf(w.type) == c)).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButton<String>(
              isExpanded: true,
              value: _catKey,
              items: [
                const DropdownMenuItem(value: 'all', child: Text('All activities')),
                for (final c in present)
                  DropdownMenuItem(value: c.name, child: Text(catLabel(c))),
              ],
              onChanged: (v) => setState(() => _catKey = v ?? 'all'),
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'week', label: Text('Week')),
                ButtonSegment(value: 'month', label: Text('Month')),
                ButtonSegment(value: 'year', label: Text('Year')),
                ButtonSegment(value: 'all', label: Text('All')),
              ],
              selected: {_period},
              onSelectionChanged: (s) => setState(() => _period = s.first),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary() {
    final today = DateTime.now();
    final r = periodRange(_period, today)!;
    final pr = periodRange(_period, today, back: 1);
    final ws = _filtered();
    final cur = totalsOf(ws.where((w) => r.contains(w.day)));
    final prev = pr == null ? null : totalsOf(ws.where((w) => pr.contains(w.day)));
    final cat = _cat;
    final foot = cat == Cat.run || cat == Cat.walk || cat == Cat.hike;
    final rows = <MapEntry<String, String>>[
      MapEntry('Workouts', '${cur.count}${_delta(cur.count.toDouble(), prev?.count.toDouble())}'),
      MapEntry('Time', '${fmtDur(cur.minutes)}${_delta(cur.minutes, prev?.minutes)}'),
      if (cur.km > 0)
        MapEntry('Distance', '${fmt(cur.km)} km${_delta(cur.km, prev?.km)}'),
      if (foot && cur.km > 0)
        MapEntry('Average pace', '${fmtPace(cur.minutes * 60 / cur.km)} /km'),
      if (cat == Cat.cycle && cur.km > 0 && cur.minutes > 0)
        MapEntry('Average speed', '${fmt(cur.km / (cur.minutes / 60))} km/h'),
      if (cat == Cat.swim && cur.km > 0)
        MapEntry('Average pace', '${fmtPace(cur.minutes * 60 / (cur.km * 10))} /100 m'),
      if (cur.elev > 0) MapEntry('Elevation gain', '${cur.elev.round()} m${_delta(cur.elev, prev?.elev)}'),
      if (cur.sets > 0) MapEntry('Sets', '${cur.sets.round()}${_delta(cur.sets, prev?.sets)}'),
      if (cur.volume > 0) MapEntry('Volume', '${fmt(cur.volume)} kg${_delta(cur.volume, prev?.volume)}'),
      if (cur.kcal > 0) MapEntry('Calories', '${fmt(cur.kcal)} kcal${_delta(cur.kcal, prev?.kcal)}'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(periodLabel(_period, r), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final e in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(e.key), Flexible(child: Text(e.value, textAlign: TextAlign.right))],
                ),
              ),
            if (cur.count == 0) const Text('No workouts in this period.'),
          ],
        ),
      ),
    );
  }

  // time per kind of activity in the chosen period
  Widget _byType() {
    if (_cat != null) return const SizedBox.shrink();
    final r = periodRange(_period, DateTime.now())!;
    final mins = <Cat, double>{};
    for (final w in _all) {
      if (r.contains(w.day)) {
        final c = categoryOf(w.type);
        mins[c] = (mins[c] ?? 0) + w.minutes;
      }
    }
    if (mins.isEmpty) return const SizedBox.shrink();
    final total = mins.values.fold<double>(0, (a, b) => a + b);
    final order = mins.keys.toList()..sort((a, b) => mins[b]!.compareTo(mins[a]!));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Time by activity', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final c in order)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(children: [Icon(catIcon(c), size: 18), const SizedBox(width: 8), Text(catLabel(c))]),
                        Text('${fmtDur(mins[c]!)}  (${(mins[c]! / total * 100).round()} %)'),
                      ],
                    ),
                    LinearProgressIndicator(value: mins[c]! / total),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _records() {
    final cat = _cat;
    final recs = recordsFor(cat, _all);
    if (recs.isEmpty) return const SizedBox.shrink();
    final est = cat == Cat.run ? raceEstimates(_all, DateTime.now()) : <MapEntry<String, String>>[];
    final title = Theme.of(context).textTheme.titleMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Records', style: title),
                for (final r in recs)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.label),
                    subtitle: r.note.isEmpty ? null : Text(r.note),
                    trailing: Text(r.value),
                    onTap: r.w == null ? null : () => _open(r.w!),
                  ),
              ],
            ),
          ),
        ),
        if (est.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Estimated race times', style: title),
                  const Text('From your best run of the last 12 months (Riegel formula). A rough guide only.',
                      style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  for (final e in est)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [Text(e.key), Text(e.value)],
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = trainingMetrics(_cat);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: const Text('Start a gym workout'),
            subtitle: Text((AppDb.instance.getSetting('gym_draft') ?? '').isNotEmpty
                ? 'A workout is in progress. Tap to resume.'
                : 'Log sets and reps with the previous values, a rest timer and records'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await startGymWorkout(context);
              if (mounted) _load();
            },
          ),
        ),
        _controls(),
        _summary(),
        _byType(),
        MetricChart(
          key: ValueKey('train-$_catKey'),
          metrics: metrics,
          initialMetric: metrics.first.id,
          initialDays: 180,
          reloadToken: widget.reloadToken,
        ),
        _records(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Activity in the last year',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _Heatmap(workouts: _all),
              ],
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.compare_arrows),
            title: const Text('Performance analysis'),
            subtitle: const Text('Compare similar runs and similar lifts across all your data'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AnalysisScreen()),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.fitness_center),
            title: const Text('Lift progress'),
            subtitle: const Text('Heaviest sets, estimated 1RM, volume and history per exercise'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ExerciseListScreen()),
            ),
          ),
        ),
      ],
    );
  }
}

/// Minutes of training per day for the last 53 weeks (like the Garmin and
/// GitHub calendars). Darker = more time.
class _Heatmap extends StatelessWidget {
  final List<Workout> workouts;
  const _Heatmap({required this.workouts});

  @override
  Widget build(BuildContext context) {
    final minutes = <String, double>{};
    for (final w in workouts) {
      minutes[w.day] = (minutes[w.day] ?? 0) + w.minutes;
    }
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true, // start at the most recent weeks
      child: CustomPaint(
        size: const Size(53 * 14.0 + 4, 7 * 14.0 + 22),
        painter: _HeatPainter(minutes, cs),
      ),
    );
  }
}

class _HeatPainter extends CustomPainter {
  final Map<String, double> minutes;
  final ColorScheme cs;
  _HeatPainter(this.minutes, this.cs);

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final thisMonday = DateTime(today.year, today.month, today.day - (today.weekday - 1));
    final first = DateTime(thisMonday.year, thisMonday.month, thisMonday.day - 52 * 7);
    const cell = 14.0, gap = 2.0;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    int lastMonth = -1;
    for (var wk = 0; wk < 53; wk++) {
      for (var dow = 0; dow < 7; dow++) {
        final d = DateTime(first.year, first.month, first.day + wk * 7 + dow);
        if (d.isAfter(today)) continue;
        final m = minutes[dayKey(d)] ?? 0;
        final a = m <= 0 ? 0.0 : (m < 30 ? 0.3 : (m < 60 ? 0.55 : (m < 90 ? 0.8 : 1.0)));
        final paint = Paint()
          ..color = a == 0 ? cs.outlineVariant.withValues(alpha: 0.5) : cs.primary.withValues(alpha: a);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(wk * (cell) + 2, 18 + dow * cell, cell - gap, cell - gap),
              const Radius.circular(2)),
          paint,
        );
        if (dow == 0 && d.month != lastMonth && d.day <= 7) {
          lastMonth = d.month;
          final tp = TextPainter(
            text: TextSpan(text: months[d.month - 1], style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, Offset(wk * cell + 2, 2));
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
