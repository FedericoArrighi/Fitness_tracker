import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import '../widgets.dart';
import 'gym_workout_screen.dart';
import '../workout_format.dart';
import '../workout_types.dart';

const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _hms(double s) {
  final t = s.round();
  final h = t ~/ 3600, m = (t % 3600) ~/ 60, sec = t % 60;
  final mm = m.toString().padLeft(2, '0'), ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}

String _sourceLabel(String s) => switch (s) {
      'health_connect' => 'Health Connect (from the Garmin Connect app)',
      'garmin_csv' => 'Garmin CSV file',
      'hevy' => 'Hevy',
      'manual' => 'Entered or edited by you',
      'app' => 'Logged in this app',
      _ => s,
    };

/// All the details of one workout; the numbers shown depend on the kind of
/// activity (running, cycling, swimming, gym, ...).
class WorkoutDetailScreen extends StatefulWidget {
  final String workoutId;
  const WorkoutDetailScreen({super.key, required this.workoutId});

  @override
  State<WorkoutDetailScreen> createState() => _WorkoutDetailScreenState();
}

class _WorkoutDetailScreenState extends State<WorkoutDetailScreen> {
  Workout? _w;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() => _w = AppDb.instance.loadWorkout(widget.workoutId));
  }

  Future<void> _edit() async {
    final w = _w!;
    var cat = categoryOf(w.type);
    final title = TextEditingController(text: w.title);
    final notes = TextEditingController(text: w.notes);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setS) => AlertDialog(
          title: const Text('Edit workout'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Type'),
                  DropdownButton<Cat>(
                    isExpanded: true,
                    value: cat,
                    items: [
                      for (final c in Cat.values)
                        DropdownMenuItem(value: c, child: Text(catLabel(c))),
                    ],
                    onChanged: (v) => setS(() => cat = v!),
                  ),
                  TextField(
                    controller: title,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  TextField(
                    controller: notes,
                    minLines: 2,
                    maxLines: 6,
                    decoration: const InputDecoration(labelText: 'Notes'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                      'Once you edit a workout, later imports will leave it unchanged.',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final typeChanged = categoryOf(w.type) != cat;
    AppDb.instance.saveWorkout(w.copyWith(
      type: typeChanged ? catTypes[cat]! : w.type,
      title: title.text.trim(),
      notes: notes.text,
      source: 'manual',
    ));
    _load();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this workout?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    AppDb.instance.deleteWorkout(widget.workoutId);
    if (mounted) Navigator.pop(context, true);
  }

  Widget _tile(String label, String value) => SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: Theme.of(context).textTheme.titleLarge),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      );

  String _metricText(String key, double v) {
    if (key == 'moving_s' || key == 'elapsed_s') return _hms(v);
    final l = metricLabels[key];
    final num = (l == null || l.decimals == 0) ? v.round().toString() : v.toStringAsFixed(l.decimals);
    return (l == null || l.unit.isEmpty) ? num : '$num ${l.unit}';
  }

  @override
  Widget build(BuildContext context) {
    final w = _w;
    if (w == null || w.deleted) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Workout not found.')),
      );
    }
    final cat = categoryOf(w.type);
    final start = DateTime.fromMillisecondsSinceEpoch(w.startMs);
    final end = DateTime.fromMillisecondsSinceEpoch(w.endMs);
    String hm(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final km = (w.distanceM != null && w.distanceM! > 0) ? w.distanceM! / 1000 : null;
    final title = Theme.of(context).textTheme.titleMedium;

    // the main numbers, depending on the kind of activity
    final tiles = <MapEntry<String, String>>[
      MapEntry('Duration', fmtDur(w.minutes)),
    ];
    switch (cat) {
      case Cat.run:
      case Cat.walk:
      case Cat.hike:
        if (km != null) tiles.add(MapEntry('Distance', '${fmt(km)} km'));
        final p = paceSecPerKm(w);
        if (p != null) tiles.add(MapEntry('Pace', '${fmtPace(p)} /km'));
        final s = speedKmh(w);
        if (s != null) tiles.add(MapEntry('Speed', '${fmt(s)} km/h'));
        break;
      case Cat.cycle:
        if (km != null) tiles.add(MapEntry('Distance', '${fmt(km)} km'));
        final s = speedKmh(w);
        if (s != null) tiles.add(MapEntry('Average speed', '${fmt(s)} km/h'));
        break;
      case Cat.swim:
        if (w.distanceM != null && w.distanceM! > 0) {
          tiles.add(MapEntry('Distance', '${w.distanceM!.round()} m'));
        }
        final p = paceSecPer100m(w);
        if (p != null) tiles.add(MapEntry('Pace', '${fmtPace(p)} /100 m'));
        break;
      case Cat.strength:
        final sets = w.metrics['sets'];
        final reps = w.metrics['reps'];
        final vol = w.metrics['volume_kg'];
        if (sets != null) tiles.add(MapEntry('Sets', '${sets.round()}'));
        if (reps != null) tiles.add(MapEntry('Repetitions', '${reps.round()}'));
        if (vol != null) tiles.add(MapEntry('Volume', '${fmt(vol)} kg'));
        break;
      default:
        if (km != null) tiles.add(MapEntry('Distance', '${fmt(km)} km'));
    }
    if (w.activeKcal != null) tiles.add(MapEntry('Calories', '${fmt(w.activeKcal!)} kcal'));
    final avgHr = w.metrics['avg_hr'];
    if (avgHr != null) tiles.add(MapEntry('Avg heart rate', '${avgHr.round()} bpm'));

    // the other numbers, in a useful order
    final shown = <String>{'sets', 'reps', 'volume_kg', 'avg_hr'};
    final keys = <String>[
      ...metricOrder(cat).where((k) => w.metrics.containsKey(k) && !shown.contains(k)),
      ...w.metrics.keys.where((k) =>
          !metricOrder(cat).contains(k) && !shown.contains(k) && metricLabels.containsKey(k)),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(workoutTitle(w)),
        actions: [
          if (cat == Cat.strength)
            IconButton(
              icon: const Icon(Icons.fitness_center),
              tooltip: 'Edit sets',
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => GymWorkoutScreen(editing: w)),
                );
                _load();
              },
            ),
          IconButton(icon: const Icon(Icons.edit_outlined), tooltip: 'Edit', onPressed: _edit),
          IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete', onPressed: _delete),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Icon(catIcon(cat), size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(catLabel(cat), style: title),
                    Text('${_wd[start.weekday - 1]} ${start.day}.${start.month}.${start.year}  '
                        '${hm(start)} - ${hm(end)}'),
                    Text(_sourceLabel(w.source), style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [for (final t in tiles) _tile(t.key, t.value)],
          ),
          if (keys.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('More data', style: title),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    for (final k in keys)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(metricLabels[k]?.label ?? k),
                            Text(_metricText(k, w.metrics[k]!)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (w.hr.length > 1) ...[
            const SizedBox(height: 20),
            Text('Heart rate', style: title),
            const SizedBox(height: 8),
            SizedBox(
              height: 180,
              child: CustomPaint(
                painter: _HrPainter(w.hr, Theme.of(context).colorScheme),
                size: Size.infinite,
              ),
            ),
            if (w.metrics['avg_hr'] != null)
              Text('Average ${w.metrics['avg_hr']!.round()} bpm'
                  '${w.metrics['max_hr'] != null ? ', maximum ${w.metrics['max_hr']!.round()} bpm' : ''}'
                  '${w.metrics['min_hr'] != null ? ', minimum ${w.metrics['min_hr']!.round()} bpm' : ''}',
                  style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 16),
            _zonesCard(w),
          ],
          if (w.exercises.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Exercises', style: title),
            for (final ex in w.exercises) _exercise(ex),
          ] else if (w.notes.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Notes', style: title),
            const SizedBox(height: 4),
            Text(w.notes),
          ],
          if (w.exercises.isNotEmpty && w.notes.isNotEmpty && !w.notes.startsWith('Sets:')) ...[
            const SizedBox(height: 20),
            Text('Notes', style: title),
            const SizedBox(height: 4),
            Text(w.notes),
          ],
        ],
      ),
    );
  }

  // minutes in each of five zones (50-60 %, ... 90-100 % of the maximum heart rate)
  List<double> _zoneMinutes(Workout w, double maxHr) {
    final z = List<double>.filled(5, 0);
    final n = w.hr.length;
    if (n < 2) return z;
    final gaps = [for (var i = 0; i < n - 1; i++) w.hr[i + 1][0] - w.hr[i][0]]..sort();
    final typical = gaps[gaps.length ~/ 2];
    for (var i = 0; i < n; i++) {
      final dt = i < n - 1
          ? (w.hr[i + 1][0] - w.hr[i][0]).clamp(0, typical * 3).toDouble()
          : typical;
      final f = w.hr[i][1] / maxHr;
      final k = f >= 0.9 ? 4 : (f >= 0.8 ? 3 : (f >= 0.7 ? 2 : (f >= 0.6 ? 1 : (f >= 0.5 ? 0 : -1))));
      if (k >= 0) z[k] += dt;
    }
    return z;
  }

  Future<void> _setMaxHr() async {
    final ctl = TextEditingController(
        text: AppDb.instance.getSetting('max_hr') ?? '190');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Maximum heart rate'),
        content: numField(
          controller: ctl,
          label: 'Maximum heart rate',
          suffix: 'bpm',
          onSubmitted: (_) => Navigator.pop(context, true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    final v = parseNum(ctl.text);
    if (ok == true && v != null && v >= 120 && v <= 230) {
      AppDb.instance.setSetting('max_hr', v.round().toString());
      setState(() {});
    }
  }

  Widget _zonesCard(Workout w) {
    final maxHr = double.tryParse(AppDb.instance.getSetting('max_hr') ?? '') ?? 190;
    final z = _zoneMinutes(w, maxHr);
    final total = z.fold<double>(0, (a, b) => a + b);
    const names = ['Zone 1   50-60 %', 'Zone 2   60-70 %', 'Zone 3   70-80 %', 'Zone 4   80-90 %', 'Zone 5   90-100 %'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text('Heart rate zones',
                        style: Theme.of(context).textTheme.titleMedium)),
                TextButton(
                    onPressed: _setMaxHr,
                    child: Text('Max ${maxHr.round()} bpm')),
              ],
            ),
            if (total <= 0)
              const Text('The heart rate stayed below zone 1.',
                  style: TextStyle(fontSize: 12))
            else
              for (var i = 0; i < 5; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(names[i], style: const TextStyle(fontSize: 12)),
                          Text('${fmtDur(z[i])}  (${(z[i] / total * 100).round()} %)',
                              style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                      LinearProgressIndicator(value: z[i] / total),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _exercise(Map<String, dynamic> ex) {
    final name = (ex['name'] ?? '').toString();
    final sets = ((ex['sets'] as List?) ?? const [])
        .map((s) => (s as Map).cast<String, dynamic>())
        .toList();
    double? best1rm;
    String bestSet = '';
    var n = 0;
    final rows = <Widget>[];
    for (final s in sets) {
      final type = (s['type'] ?? 'normal').toString();
      final kg = (s['kg'] as num?)?.toDouble();
      final reps = (s['reps'] as num?)?.toDouble();
      final km = (s['km'] as num?)?.toDouble();
      final sec = (s['sec'] as num?)?.toDouble();
      String text;
      if (kg != null && kg > 0 && reps != null) {
        text = '${rawNum((kg * 10).round() / 10)} kg × ${reps.round()}';
      } else if (reps != null && reps > 0) {
        text = '${reps.round()} reps';
      } else if (km != null && km > 0) {
        text = '${fmt(km)} km';
      } else if (sec != null && sec > 0) {
        text = '${sec.round()} s';
      } else {
        text = 'set';
      }
      final isWarm = type == 'warmup';
      if (!isWarm) {
        n++;
        if (kg != null && kg > 0 && reps != null && reps > 0) {
          final e = kg * (1 + reps / 30); // Epley estimate of the one-rep max
          if (best1rm == null || e > best1rm) {
            best1rm = e;
            bestSet = text;
          }
        }
      }
      final label = isWarm ? 'warm-up' : (type == 'normal' ? '#$n' : '#$n ($type)');
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 90, child: Text(label, style: const TextStyle(fontSize: 12))),
            Text(text),
          ],
        ),
      ));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            ...rows,
            if (best1rm != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Best set: $bestSet  (estimated 1RM ${fmt(best1rm)} kg)',
                    style: const TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}

class _HrPainter extends CustomPainter {
  final List<List<double>> pts; // [minute, bpm]
  final ColorScheme cs;
  _HrPainter(this.pts, this.cs);

  void _text(Canvas c, String s, double x, double y, {String align = 'left'}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = x;
    if (align == 'right') dx = x - tp.width;
    tp.paint(c, Offset(dx, y));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 40.0, right = 8.0, top = 6.0, bottom = 22.0;
    final w = size.width - left - right;
    final h = size.height - top - bottom;
    if (w <= 0 || h <= 0 || pts.length < 2) return;
    final xs = pts.map((p) => p[0]).toList();
    final ys = pts.map((p) => p[1]).toList();
    final x1 = xs.reduce((a, b) => a > b ? a : b);
    final lo = ys.reduce((a, b) => a < b ? a : b) - 5;
    final hi = ys.reduce((a, b) => a > b ? a : b) + 5;
    final xmax = x1 <= 0 ? 1.0 : x1;
    double xOf(double v) => left + w * (v / xmax);
    double yOf(double v) => top + h * (1 - (v - lo) / (hi - lo));

    final grid = Paint()
      ..color = cs.outlineVariant
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = top + h * (1 - i / 3);
      canvas.drawLine(Offset(left, y), Offset(left + w, y), grid);
      _text(canvas, (lo + (hi - lo) * i / 3).round().toString(), left - 6, y - 7, align: 'right');
    }
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final p = Offset(xOf(pts[i][0]), yOf(pts[i][1]));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = cs.error
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    _text(canvas, '0 min', left, top + h + 5);
    _text(canvas, '${x1.round()} min', left + w, top + h + 5, align: 'right');
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
