import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import '../workout_format.dart';
import '../workout_types.dart';
import 'workout_detail_screen.dart';

const _weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _weekdayLong = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
];
const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December'
];

const _foodColor = Color(0xFFEF8F2D);
const _sleepColor = Color(0xFF6A5ACD);

/// A month with a dot for food, training and sleep on each day. Tap a day
/// to see everything about it.
class CalendarView extends StatefulWidget {
  const CalendarView({super.key});

  @override
  State<CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends State<CalendarView> {
  late DateTime _month; // the first day of the month on show
  Map<String, DayTotals> _food = {};
  Map<String, Map<String, double>> _daily = {};
  final Map<String, List<Workout>> _workouts = {};

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _load();
  }

  void _load() {
    final from = dayKey(_month);
    final to = dayKey(DateTime(_month.year, _month.month + 1, 0));
    final db = AppDb.instance;
    _food = db.dailyTotals(from, to);
    _daily = db.loadDailyMetrics(from, to);
    _workouts.clear();
    for (final w in db.loadAllWorkouts()) {
      if (w.day.compareTo(from) >= 0 && w.day.compareTo(to) <= 0) {
        (_workouts[w.day] ??= []).add(w);
      }
    }
  }

  void _shift(int months) {
    setState(() {
      _month = DateTime(_month.year, _month.month + months);
      _load();
    });
  }

  Future<void> _open(DateTime d) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DayDetailScreen(day: d)),
    );
    if (mounted) setState(_load);
  }

  Widget _dot(Color c) => Container(
        width: 6,
        height: 6,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );

  Widget _cell(DateTime? d) {
    if (d == null) return const Expanded(child: SizedBox(height: 54));
    final key = dayKey(d);
    final now = DateTime.now();
    final isToday = d.year == now.year && d.month == now.month && d.day == now.day;
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _open(d),
        child: Container(
          height: 54,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: isToday ? Border.all(color: cs.primary, width: 2) : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${d.day}',
                  style: TextStyle(
                      fontWeight: isToday ? FontWeight.w700 : FontWeight.normal)),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_food.containsKey(key)) _dot(_foodColor),
                  if ((_workouts[key] ?? const []).isNotEmpty) _dot(cs.primary),
                  if (_daily[key]?['sleep_total'] != null) _dot(_sleepColor),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summary() {
    var workoutCount = 0;
    var workoutMin = 0.0;
    _workouts.forEach((_, l) {
      workoutCount += l.length;
      for (final w in l) {
        workoutMin += w.minutes;
      }
    });
    final kcal = [
      for (final t in _food.values)
        if (t.totals['calories'] != null) t.totals['calories']!
    ];
    final steps = [
      for (final m in _daily.values)
        if ((m['steps'] ?? 0) > 0) m['steps']!
    ];
    final sleep = [
      for (final m in _daily.values)
        if (m['sleep_total'] != null) m['sleep_total']!
    ];
    double avg(List<double> l) => l.reduce((a, b) => a + b) / l.length;
    final lines = <String>[
      if (workoutCount > 0) '$workoutCount workout(s), ${fmtDur(workoutMin)} in total',
      if (kcal.isNotEmpty) 'Food logged on ${kcal.length} day(s), average ${fmt(avg(kcal))} kcal',
      if (steps.isNotEmpty) 'Average ${avg(steps).round()} steps a day',
      if (sleep.isNotEmpty) 'Average sleep ${fmtDur(avg(sleep))}',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_monthNames[_month.month - 1]} ${_month.year}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (lines.isEmpty) const Text('Nothing recorded this month.'),
            for (final l in lines) Text(l),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final first = _month;
    final daysInMonth = DateTime(first.year, first.month + 1, 0).day;
    final offset = first.weekday - 1; // empty cells before the 1st
    final cells = <DateTime?>[
      for (var i = 0; i < offset; i++) null,
      for (var d = 1; d <= daysInMonth; d++) DateTime(first.year, first.month, d),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            IconButton(
                icon: const Icon(Icons.chevron_left), onPressed: () => _shift(-1)),
            Expanded(
              child: Center(
                child: Text('${_monthNames[first.month - 1]} ${first.year}',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
            ),
            IconButton(
                icon: const Icon(Icons.chevron_right), onPressed: () => _shift(1)),
            TextButton(
              onPressed: () {
                final n = DateTime.now();
                setState(() {
                  _month = DateTime(n.year, n.month);
                  _load();
                });
              },
              child: const Text('Today'),
            ),
          ],
        ),
        Row(
          children: [
            for (final w in _weekdayShort)
              Expanded(
                child: Center(
                  child: Text(w, style: const TextStyle(fontSize: 12)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var r = 0; r < cells.length ~/ 7; r++)
          Row(children: [for (var c = 0; c < 7; c++) _cell(cells[r * 7 + c])]),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              _dot(_foodColor),
              const Text(' food logged', style: TextStyle(fontSize: 12)),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              _dot(cs.primary),
              const Text(' training', style: TextStyle(fontSize: 12)),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              _dot(_sleepColor),
              const Text(' sleep recorded', style: TextStyle(fontSize: 12)),
            ]),
          ],
        ),
        const SizedBox(height: 12),
        _summary(),
      ],
    );
  }
}

/// Everything about one day: food, training, sleep, steps, weight.
class DayDetailScreen extends StatefulWidget {
  final DateTime day;
  const DayDetailScreen({super.key, required this.day});

  @override
  State<DayDetailScreen> createState() => _DayDetailScreenState();
}

class _DayDetailScreenState extends State<DayDetailScreen> {
  late DateTime _d;

  @override
  void initState() {
    super.initState();
    _d = DateTime(widget.day.year, widget.day.month, widget.day.day);
  }

  void _go(int days) => setState(() => _d = DateTime(_d.year, _d.month, _d.day + days));

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(label), Flexible(child: Text(value, textAlign: TextAlign.right))],
        ),
      );

  Widget _card(String title, IconData icon, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
              ]),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  Widget _foodCard(String key, Map<String, double> targets) {
    final entries = AppDb.instance.loadDay(key);
    if (entries.isEmpty) {
      return _card('Nutrition', Icons.restaurant, [const Text('No food logged.')]);
    }
    double total(String n, [Iterable<LogEntry>? from]) {
      var t = 0.0;
      for (final e in (from ?? entries)) {
        t += (e.values[n] ?? 0) * e.grams / 100;
      }
      return t;
    }

    Widget bar(String n, String label, String unit) {
      final v = total(n);
      final t = targets[n];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label),
                Text('${fmt(v)} $unit${t != null && t > 0 ? ' / ${fmt(t)}' : ''}'),
              ],
            ),
            if (t != null && t > 0)
              LinearProgressIndicator(value: (v / t).clamp(0.0, 1.0)),
          ],
        ),
      );
    }

    return _card('Nutrition', Icons.restaurant, [
      bar('calories', 'Calories', 'kcal'),
      bar('protein', 'Protein', 'g'),
      bar('carbs', 'Carbohydrates', 'g'),
      bar('fat', 'Fat', 'g'),
      const SizedBox(height: 8),
      for (final m in meals)
        if (entries.any((e) => e.meal == m))
          _row(m,
              '${fmt(total('calories', entries.where((e) => e.meal == m)))} kcal, '
              '${entries.where((e) => e.meal == m).length} item(s)'),
    ]);
  }

  Widget _trainingCard(List<Workout> ws) {
    if (ws.isEmpty) {
      return _card('Training', Icons.fitness_center, [const Text('No workout. A rest day.')]);
    }
    final min = ws.fold<double>(0, (s, w) => s + w.minutes);
    final kcal = ws.fold<double>(0, (s, w) => s + (w.activeKcal ?? 0));
    return _card('Training', Icons.fitness_center, [
      for (final w in ws)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(catIcon(categoryOf(w.type))),
          title: Text(workoutTitle(w)),
          subtitle: Text(summaryLine(w).split('  |  ').skip(1).join('  |  ')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => WorkoutDetailScreen(workoutId: w.id)),
            );
            if (mounted) setState(() {});
          },
        ),
      if (ws.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Total: ${fmtDur(min)}${kcal > 0 ? ', ${fmt(kcal)} kcal active' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
    ]);
  }

  Widget? _sleepCard(Map<String, double> m) {
    final total = m['sleep_total'];
    if (total == null) return null;
    String part(String k) => m[k] == null ? '-' : fmtDur(m[k]!);
    return _card('Sleep', Icons.bedtime_outlined, [
      _row('Total sleep', fmtDur(total)),
      if (m['sleep_deep'] != null) _row('Deep', part('sleep_deep')),
      if (m['sleep_light'] != null) _row('Light', part('sleep_light')),
      if (m['sleep_rem'] != null) _row('REM', part('sleep_rem')),
      if (m['sleep_awake'] != null) _row('Awake', part('sleep_awake')),
      if (m['sleep_score'] != null) _row('Sleep score', '${m['sleep_score']!.round()}'),
      const Text('The night that ended this morning.', style: TextStyle(fontSize: 11)),
    ]);
  }

  Widget? _activityCard(Map<String, double> m) {
    final rows = <Widget>[
      if ((m['steps'] ?? 0) > 0) _row('Steps', '${m['steps']!.round()}'),
      if ((m['distance_km'] ?? 0) > 0) _row('Distance', '${fmt(m['distance_km']!)} km'),
      if ((m['floors'] ?? 0) > 0) _row('Floors climbed', '${m['floors']!.round()}'),
      if ((m['active_kcal'] ?? 0) > 0) _row('Active energy', '${fmt(m['active_kcal']!)} kcal'),
      if ((m['resting_hr'] ?? 0) > 0) _row('Resting heart rate', '${m['resting_hr']!.round()} bpm'),
      if ((m['vo2max'] ?? 0) > 0) _row('VO2 max', fmt(m['vo2max']!)),
    ];
    if (rows.isEmpty) return null;
    return _card('Activity and health', Icons.directions_walk, rows);
  }

  Widget? _weightCard(String key) {
    final from = dayKey(DateTime(_d.year, _d.month, _d.day - 60));
    WeightPoint? best;
    for (final w in AppDb.instance.loadWeights(from)) {
      if (w.day.compareTo(key) <= 0) best = w;
    }
    if (best == null) return null;
    return _card('Weight', Icons.monitor_weight_outlined, [
      _row('Weight', '${fmt(best.kg)} kg'),
      if (best.day != key)
        Text('Last measured on ${best.day}', style: const TextStyle(fontSize: 11)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final db = AppDb.instance;
    final key = dayKey(_d);
    final targets = db.loadTargets();
    final ws = [
      for (final w in db.loadAllWorkouts())
        if (w.day == key) w
    ]..sort((a, b) => a.startMs.compareTo(b.startMs));
    final metrics = db.loadDailyMetrics(key, key)[key] ?? <String, double>{};
    final sleep = _sleepCard(metrics);
    final activity = _activityCard(metrics);
    final weight = _weightCard(key);

    return Scaffold(
      appBar: AppBar(
        title: Text('${_weekdayLong[_d.weekday - 1]} ${_d.day}.${_d.month}.${_d.year}'),
        actions: [
          IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Day before',
              onPressed: () => _go(-1)),
          IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next day',
              onPressed: () => _go(1)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _foodCard(key, targets),
          _trainingCard(ws),
          if (sleep != null) sleep,
          if (activity != null) activity,
          if (weight != null) weight,
        ],
      ),
    );
  }
}
