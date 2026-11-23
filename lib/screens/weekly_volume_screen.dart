import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../db.dart';
import '../workout_types.dart';

/// One calendar week (Monday to Sunday) of training.
class _Week {
  final DateTime start; // the Monday
  bool partial = false; // the current week is not finished yet
  int runs = 0;
  double runKm = 0, runMin = 0, runElev = 0, longRunKm = 0;
  int gyms = 0;
  double sets = 0, volume = 0, gymMin = 0, rpeSum = 0;
  int rpeN = 0;
  _Week(this.start);
}

/// Something that can be charted per week. [value] returns null for "no data
/// this week" (for example the pace of a week without runs).
class _Metric {
  final String name, unit;
  final int decimals;
  final bool pace; // shown as m:ss
  final bool additive; // a total (km, sets, ...) as opposed to an average
  final double? Function(_Week) value;
  _Metric(this.name, this.unit, this.decimals, this.value,
      {this.pace = false, this.additive = true});

  String f(double v) => pace
      ? fmtPace(v * 60)
      : (decimals == 0 ? v.round().toString() : v.toStringAsFixed(decimals));
  String fu(double v) => unit.isEmpty || pace ? f(v) : '${f(v)} $unit';
}

final List<_Metric> _runMetrics = [
  _Metric('Distance', 'km', 1, (w) => w.runKm),
  _Metric('Time', 'min', 0, (w) => w.runMin),
  _Metric('Runs', '', 0, (w) => w.runs.toDouble()),
  _Metric('Elevation gain', 'm', 0, (w) => w.runElev),
  _Metric('Longest run', 'km', 1, (w) => w.longRunKm, additive: false),
  _Metric('Pace', 'min/km', 0, (w) => w.runKm > 0.5 ? w.runMin / w.runKm : null,
      pace: true, additive: false),
];

final List<_Metric> _gymMetrics = [
  _Metric('Volume (weight x reps)', 'kg', 0, (w) => w.volume),
  _Metric('Sets', '', 0, (w) => w.sets),
  _Metric('Sessions', '', 0, (w) => w.gyms.toDouble()),
  _Metric('Time', 'min', 0, (w) => w.gymMin),
  _Metric('Sets per session', '', 1, (w) => w.gyms > 0 ? w.sets / w.gyms : null,
      additive: false),
  _Metric('Average RPE', '', 1, (w) => w.rpeN > 0 ? w.rpeSum / w.rpeN : null,
      additive: false),
];

DateTime _monday(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

String _dm(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

/// [n] full weeks plus the current (unfinished) one, oldest first.
List<_Week> _buildWeeks(List<Workout> all, int n) {
  final cur = _monday(DateTime.now());
  final weeks = <_Week>[
    for (var i = n; i >= 0; i--) _Week(DateTime(cur.year, cur.month, cur.day - 7 * i))
  ];
  weeks.last.partial = true;
  final byKey = {for (final w in weeks) dayKey(w.start): w};
  for (final w in all) {
    final d = DateTime.fromMillisecondsSinceEpoch(w.startMs);
    final wk = byKey[dayKey(_monday(d))];
    if (wk == null) continue;
    final cat = categoryOf(w.type);
    if (cat == Cat.run) {
      final km = (w.distanceM ?? 0) / 1000;
      wk.runs++;
      wk.runKm += km;
      wk.runMin += w.minutes;
      wk.runElev += w.metrics['ascent_m'] ?? 0;
      if (km > wk.longRunKm) wk.longRunKm = km;
    } else if (cat == Cat.strength) {
      wk.gyms++;
      wk.sets += w.metrics['sets'] ?? 0;
      wk.volume += w.metrics['volume_kg'] ?? 0;
      wk.gymMin += w.minutes;
      final r = w.metrics['rpe'];
      if (r != null && r > 0) {
        wk.rpeSum += r;
        wk.rpeN++;
      }
    }
  }
  return weeks;
}

class _Stats {
  int n = 0;
  double mean = 0, median = 0, sd = 0, min = 0, max = 0;
  String maxWeek = '';
  double slope = 0, intercept = 0, r2 = 0, t = 0;
  double? last, prev4, ratio, change4;
  double activePct = 0;
}

/// Statistics over the finished weeks only (the current week is left out).
_Stats? _computeStats(List<_Week> complete, _Metric m, bool run) {
  final xs = <double>[], ys = <double>[];
  for (var i = 0; i < complete.length; i++) {
    final v = m.value(complete[i]);
    if (v != null) {
      xs.add(i.toDouble());
      ys.add(v);
    }
  }
  final n = ys.length;
  if (n < 4) return null;
  final s = _Stats()..n = n;
  s.mean = ys.reduce((a, b) => a + b) / n;
  final sorted = [...ys]..sort();
  s.median = n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
  s.min = sorted.first;
  s.max = sorted.last;
  var ss = 0.0;
  for (final y in ys) {
    ss += (y - s.mean) * (y - s.mean);
  }
  s.sd = math.sqrt(ss / (n - 1));
  final maxIdx = ys.indexOf(s.max);
  s.maxWeek = _dm(complete[xs[maxIdx].toInt()].start);

  // least-squares line
  final mx = xs.reduce((a, b) => a + b) / n;
  var sxx = 0.0, sxy = 0.0;
  for (var i = 0; i < n; i++) {
    sxx += (xs[i] - mx) * (xs[i] - mx);
    sxy += (xs[i] - mx) * (ys[i] - s.mean);
  }
  s.slope = sxx > 0 ? sxy / sxx : 0;
  s.intercept = s.mean - s.slope * mx;
  if (ss > 0 && sxx > 0) {
    final r = sxy / math.sqrt(sxx * ss);
    s.r2 = r * r;
    s.t = s.r2 < 0.999999 ? r * math.sqrt((n - 2) / (1 - s.r2)) : 0;
  }

  // last finished week against the 4 weeks before it
  final all = [for (final w in complete) m.value(w)];
  s.last = all.last;
  if (all.length >= 5) {
    final prev = [for (final v in all.sublist(all.length - 5, all.length - 1)) if (v != null) v];
    if (prev.isNotEmpty) {
      s.prev4 = prev.reduce((a, b) => a + b) / prev.length;
      if (s.last != null && s.prev4! > 0) s.ratio = s.last! / s.prev4!;
    }
  }
  // last 4 weeks against the 4 weeks before those
  if (all.length >= 8) {
    final a = [for (final v in all.sublist(all.length - 4)) if (v != null) v];
    final b = [for (final v in all.sublist(all.length - 8, all.length - 4)) if (v != null) v];
    if (a.isNotEmpty && b.isNotEmpty) {
      final ma = a.reduce((x, y) => x + y) / a.length;
      final mb = b.reduce((x, y) => x + y) / b.length;
      if (mb > 0) s.change4 = (ma / mb - 1) * 100;
    }
  }
  final active = complete.where((w) => run ? w.runs > 0 : w.gyms > 0).length;
  s.activePct = active * 100 / complete.length;
  return s;
}

class WeeklyVolumeScreen extends StatefulWidget {
  const WeeklyVolumeScreen({super.key});

  @override
  State<WeeklyVolumeScreen> createState() => _WeeklyVolumeScreenState();
}

class _WeeklyVolumeScreenState extends State<WeeklyVolumeScreen> {
  bool _run = true;
  int _metricIdx = 0;
  int _weeks = 26;
  List<Workout> _all = [];

  @override
  void initState() {
    super.initState();
    _all = AppDb.instance.loadAllWorkouts();
  }

  List<_Metric> get _metrics => _run ? _runMetrics : _gymMetrics;

  @override
  Widget build(BuildContext context) {
    final metric = _metrics[_metricIdx];
    final weeks = _buildWeeks(_all, _weeks);
    final complete = weeks.sublist(0, weeks.length - 1);
    final stats = _computeStats(complete, metric, _run);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Weekly volume')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Running'), icon: Icon(Icons.directions_run)),
              ButtonSegment(value: false, label: Text('Gym'), icon: Icon(Icons.fitness_center)),
            ],
            selected: {_run},
            onSelectionChanged: (s) => setState(() {
              _run = s.first;
              _metricIdx = 0;
            }),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 0,
            children: [
              for (var i = 0; i < _metrics.length; i++)
                ChoiceChip(
                  label: Text(_metrics[i].name),
                  selected: i == _metricIdx,
                  onSelected: (_) => setState(() => _metricIdx = i),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 12, label: Text('12 weeks')),
              ButtonSegment(value: 26, label: Text('26 weeks')),
              ButtonSegment(value: 52, label: Text('1 year')),
            ],
            selected: {_weeks},
            onSelectionChanged: (s) => setState(() => _weeks = s.first),
          ),
          const SizedBox(height: 12),
          Text('${metric.name}${metric.unit.isEmpty || metric.pace ? '' : ' (${metric.unit})'}'
              '${metric.pace ? ' (min/km)' : ''} per week',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          SizedBox(
            height: 230,
            child: CustomPaint(
              size: Size.infinite,
              painter: _WeeklyChartPainter(
                weeks: weeks,
                metric: metric,
                stats: stats,
                barColor: scheme.primary,
                avgColor: scheme.tertiary,
                trendColor: scheme.error,
                textColor: scheme.onSurface,
                gridColor: scheme.outlineVariant,
              ),
            ),
          ),
          Wrap(
            spacing: 12,
            children: [
              _legend(scheme.primary, 'week'),
              _legend(scheme.tertiary, '4-week average'),
              _legend(scheme.error, 'trend line'),
            ],
          ),
          const SizedBox(height: 4),
          const Text('The pale bar on the right is the current week, which is not '
              'finished yet. It is not used in the statistics.',
              style: TextStyle(fontSize: 11)),
          const SizedBox(height: 12),
          _statsCard(metric, stats, complete.length),
          const SizedBox(height: 12),
          _table(weeks),
        ],
      ),
    );
  }

  Widget _legend(Color c, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 12, height: 4, color: c),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 11)),
        ],
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _statsCard(_Metric m, _Stats? s, int nWeeks) {
    if (s == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('Not enough data for ${m.name.toLowerCase()} in this period '
              '(at least 4 finished weeks with a value are needed).'),
        ),
      );
    }
    final pct = s.mean != 0 ? s.slope * (nWeeks - 1) / s.mean * 100 : 0.0;
    final sign = s.slope >= 0 ? '+' : '-';
    final clear = s.t.abs() >= 2;
    final notes = <String>[];
    final dir = s.slope > 0 ? 'rising' : (s.slope < 0 ? 'falling' : 'flat');
    notes.add(clear
        ? 'The trend is $dir and clearly more than normal week-to-week noise.'
        : 'The trend looks $dir, but it is within normal week-to-week noise.');
    if (s.ratio != null && m.additive) {
      final r = s.ratio!;
      if (r > 1.3) {
        notes.add('Last week was ${((r - 1) * 100).round()}% above your previous '
            '4-week average. A common rule of thumb is to avoid big jumps in a '
            'single week.');
      } else if (r < 0.6) {
        notes.add('Last week was well below your previous 4-week average.');
      }
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Statistics (finished weeks)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            _row('Average', m.fu(s.mean)),
            _row('Median', m.fu(s.median)),
            _row('Standard deviation', m.fu(s.sd)),
            _row('Lowest week', m.fu(s.min)),
            _row('Highest week', '${m.fu(s.max)}  (week of ${s.maxWeek})'),
            if (s.last != null) _row('Last finished week', m.fu(s.last!)),
            if (s.prev4 != null) _row('Previous 4 weeks, average', m.fu(s.prev4!)),
            if (s.ratio != null)
              _row('Last week / previous 4 weeks', '${(s.ratio! * 100).round()}%'),
            if (s.change4 != null)
              _row('Last 4 weeks vs the 4 before',
                  '${s.change4! >= 0 ? '+' : ''}${s.change4!.toStringAsFixed(0)}%'),
            _row('Trend per week',
                '$sign${m.pace ? fmtPace(s.slope.abs() * 60) : m.f(s.slope.abs())}'
                '${m.unit.isEmpty || m.pace ? '' : ' ${m.unit}'}'),
            _row('Trend over the period', '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(0)}%'),
            _row('Trend fit (R²)', s.r2.toStringAsFixed(2)),
            _row('Weeks with a ${_run ? 'run' : 'gym session'}',
                '${s.activePct.round()}%'),
            const SizedBox(height: 6),
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(n, style: const TextStyle(fontSize: 12)),
              ),
            const SizedBox(height: 4),
            const Text('Weeks without training count as 0 for totals, and are left '
                'out for averages such as pace or RPE. The trend is a straight line '
                'fitted through the weeks; "clear" means its t-value is above 2.',
                style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _table(List<_Week> weeks) {
    final last = weeks.reversed.take(10).toList();
    String lbl(_Week w) => '${_dm(w.start)}${w.partial ? '*' : ''}';
    final List<DataColumn> cols;
    final List<DataRow> rows;
    if (_run) {
      cols = const [
        DataColumn(label: Text('Week')),
        DataColumn(label: Text('km'), numeric: true),
        DataColumn(label: Text('min'), numeric: true),
        DataColumn(label: Text('Runs'), numeric: true),
        DataColumn(label: Text('Long'), numeric: true),
        DataColumn(label: Text('Pace'), numeric: true),
      ];
      rows = [
        for (final w in last)
          DataRow(cells: [
            DataCell(Text(lbl(w))),
            DataCell(Text(w.runKm.toStringAsFixed(1))),
            DataCell(Text(w.runMin.round().toString())),
            DataCell(Text('${w.runs}')),
            DataCell(Text(w.longRunKm.toStringAsFixed(1))),
            DataCell(Text(w.runKm > 0.5 ? fmtPace(w.runMin / w.runKm * 60) : '-')),
          ]),
      ];
    } else {
      cols = const [
        DataColumn(label: Text('Week')),
        DataColumn(label: Text('Sessions'), numeric: true),
        DataColumn(label: Text('Sets'), numeric: true),
        DataColumn(label: Text('Volume kg'), numeric: true),
        DataColumn(label: Text('RPE'), numeric: true),
      ];
      rows = [
        for (final w in last)
          DataRow(cells: [
            DataCell(Text(lbl(w))),
            DataCell(Text('${w.gyms}')),
            DataCell(Text(w.sets.round().toString())),
            DataCell(Text(w.volume.round().toString())),
            DataCell(Text(w.rpeN > 0 ? (w.rpeSum / w.rpeN).toStringAsFixed(1) : '-')),
          ]),
      ];
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Last weeks', style: Theme.of(context).textTheme.titleMedium),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(columnSpacing: 20, columns: cols, rows: rows),
            ),
            const Text('* current week, not finished', style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _WeeklyChartPainter extends CustomPainter {
  final List<_Week> weeks; // the last one is the current week
  final _Metric metric;
  final _Stats? stats;
  final Color barColor, avgColor, trendColor, textColor, gridColor;
  _WeeklyChartPainter({
    required this.weeks,
    required this.metric,
    required this.stats,
    required this.barColor,
    required this.avgColor,
    required this.trendColor,
    required this.textColor,
    required this.gridColor,
  });

  void _text(Canvas c, String s, Offset at, {bool right = false, bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: 10, color: textColor)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = at.dx;
    if (right) dx -= tp.width;
    if (center) dx -= tp.width / 2;
    tp.paint(c, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 46.0, bottom = 22.0, top = 8.0, right = 8.0;
    final plotW = size.width - left - right;
    final plotH = size.height - top - bottom;
    if (plotW <= 0 || plotH <= 0) return;
    final n = weeks.length;
    final vals = [for (final w in weeks) metric.value(w)];
    final nComplete = n - 1;

    // 4-week moving average over finished weeks
    final avg = List<double?>.filled(n, null);
    for (var i = 0; i < nComplete; i++) {
      final win = <double>[];
      for (var j = math.max(0, i - 3); j <= i; j++) {
        final v = vals[j];
        if (v != null) win.add(v);
      }
      if (win.isNotEmpty) avg[i] = win.reduce((a, b) => a + b) / win.length;
    }

    var maxY = 0.0;
    for (final v in vals) {
      if (v != null && v > maxY) maxY = v;
    }
    for (final v in avg) {
      if (v != null && v > maxY) maxY = v;
    }
    if (stats != null) {
      for (final i in [0, nComplete - 1]) {
        final y = stats!.intercept + stats!.slope * i;
        if (y > maxY) maxY = y;
      }
    }
    if (maxY <= 0) maxY = 1;
    maxY *= 1.1;

    double xAt(int i) => left + plotW * (i + 0.5) / n;
    double yAt(double v) => top + plotH * (1 - v / maxY);

    // grid and y labels
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var k = 0; k <= 4; k++) {
      final v = maxY * k / 4;
      final y = yAt(v);
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), grid);
      _text(canvas, metric.f(v), Offset(left - 4, y), right: true);
    }

    // bars
    final slot = plotW / n;
    final bw = slot * 0.66;
    for (var i = 0; i < n; i++) {
      final v = vals[i];
      if (v == null || v <= 0) continue;
      final p = Paint()..color = i == n - 1 ? barColor.withAlpha(90) : barColor.withAlpha(200);
      final y = yAt(v);
      canvas.drawRect(Rect.fromLTRB(xAt(i) - bw / 2, y, xAt(i) + bw / 2, top + plotH), p);
    }

    // moving average
    final linePaint = Paint()
      ..color = avgColor
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    final path = Path();
    var started = false;
    for (var i = 0; i < nComplete; i++) {
      final v = avg[i];
      if (v == null) continue;
      final o = Offset(xAt(i), yAt(v));
      if (started) {
        path.lineTo(o.dx, o.dy);
      } else {
        path.moveTo(o.dx, o.dy);
        started = true;
      }
    }
    canvas.drawPath(path, linePaint);

    // trend line (least squares through the finished weeks)
    if (stats != null && nComplete >= 2) {
      final tp = Paint()
        ..color = trendColor
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke;
      double clampY(double v) => math.max(v, 0);
      canvas.drawLine(
        Offset(xAt(0), yAt(clampY(stats!.intercept))),
        Offset(xAt(nComplete - 1),
            yAt(clampY(stats!.intercept + stats!.slope * (nComplete - 1)))),
        tp,
      );
    }

    // x labels
    final step = (n / 7).ceil();
    for (var i = n - 1; i >= 0; i -= step) {
      _text(canvas, _dm(weeks[i].start), Offset(xAt(i), size.height - bottom / 2 + 2),
          center: true);
    }
  }

  @override
  bool shouldRepaint(covariant _WeeklyChartPainter old) => true;
}
