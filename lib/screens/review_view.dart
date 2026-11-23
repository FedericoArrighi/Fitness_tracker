import 'package:flutter/material.dart';
import '../review.dart';
import '../workout_types.dart';
import 'fitness_view.dart';

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December'
];

String _dmy(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

/// The review of a week or a month, with the one before for comparison.
class ReviewView extends StatefulWidget {
  const ReviewView({super.key});

  @override
  State<ReviewView> createState() => _ReviewViewState();
}

class _ReviewViewState extends State<ReviewView> {
  bool _month = false;
  int _offset = 0; // 0 = this period, -1 = the one before, ...
  late ReviewResult _r;
  late String _label;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final now = DateTime.now();
    DateTime from, end, prevFrom;
    if (_month) {
      from = DateTime(now.year, now.month + _offset, 1);
      end = DateTime(from.year, from.month + 1, 1);
      prevFrom = DateTime(from.year, from.month - 1, 1);
      _label = '${_monthNames[from.month - 1]} ${from.year}';
    } else {
      final mon = DateTime(now.year, now.month, now.day - (now.weekday - 1));
      from = DateTime(mon.year, mon.month, mon.day + 7 * _offset);
      end = DateTime(from.year, from.month, from.day + 7);
      prevFrom = DateTime(from.year, from.month, from.day - 7);
      _label = '${_dmy(from)} to ${_dmy(DateTime(end.year, end.month, end.day - 1))}';
    }
    _r = computeReview(from, end, prevFrom);
  }

  Widget _card(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  Widget _bullet(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 6, right: 8),
              child: Icon(Icons.circle, size: 6),
            ),
            Expanded(child: Text(t)),
          ],
        ),
      );

  Widget _row(String label, String now, String before) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            SizedBox(
                width: 84,
                child: Text(now,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w600))),
            SizedBox(
                width: 84,
                child: Text(before,
                    textAlign: TextAlign.right,
                    style: TextStyle(color: Theme.of(context).hintColor))),
          ],
        ),
      );

  String _n(double v, [int d = 0]) => d == 0 ? v.round().toString() : v.toStringAsFixed(d);
  String _h(double min) => min <= 0 ? '-' : '${min ~/ 60} h ${(min % 60).round().toString().padLeft(2, '0')}';

  List<Widget> _numbers() {
    final c = _r.cur, p = _r.prev;
    final rows = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            const Expanded(child: SizedBox()),
            SizedBox(
                width: 84,
                child: Text(_r.partial ? 'so far' : 'this',
                    textAlign: TextAlign.right, style: const TextStyle(fontSize: 11))),
            const SizedBox(
                width: 84,
                child: Text('before', textAlign: TextAlign.right, style: TextStyle(fontSize: 11))),
          ],
        ),
      ),
    ];
    void add(String label, String a, String b, {bool show = true}) {
      if (show) rows.add(_row(label, a, b));
    }

    add('Workouts', '${c.sessions}', '${p.sessions}');
    add('Training time', _h(c.minutes), _h(p.minutes));
    add('Training load', _n(c.load), _n(p.load), show: c.load > 0 || p.load > 0);
    add('Running, km', _n(c.runKm, 1), _n(p.runKm, 1), show: c.runKm > 0 || p.runKm > 0);
    add('Runs', '${c.runs}', '${p.runs}', show: c.runs > 0 || p.runs > 0);
    add('Run pace /km', c.paceSecPerKm > 0 ? fmtPace(c.paceSecPerKm) : '-',
        p.paceSecPerKm > 0 ? fmtPace(p.paceSecPerKm) : '-',
        show: c.paceSecPerKm > 0 || p.paceSecPerKm > 0);
    add('Gym sessions', '${c.gyms}', '${p.gyms}', show: c.gyms > 0 || p.gyms > 0);
    add('Gym sets', _n(c.sets), _n(p.sets), show: c.sets > 0 || p.sets > 0);
    add('Gym volume, kg', _n(c.volume), _n(p.volume), show: c.volume > 0 || p.volume > 0);
    add('Average RPE (gym)', c.avgRpe == null ? '-' : _n(c.avgRpe!, 1),
        p.avgRpe == null ? '-' : _n(p.avgRpe!, 1),
        show: c.avgRpe != null || p.avgRpe != null);
    add('Days with food logged', '${c.foodDays}', '${p.foodDays}', show: c.foodDays > 0 || p.foodDays > 0);
    add('Calories a day', c.foodDays > 0 ? _n(c.kcal) : '-', p.foodDays > 0 ? _n(p.kcal) : '-',
        show: c.foodDays > 0 || p.foodDays > 0);
    add('Protein a day, g', c.foodDays > 0 ? _n(c.protein) : '-', p.foodDays > 0 ? _n(p.protein) : '-',
        show: c.foodDays > 0 || p.foodDays > 0);
    add('Carbohydrates a day, g', c.foodDays > 0 ? _n(c.carbs) : '-', p.foodDays > 0 ? _n(p.carbs) : '-',
        show: c.foodDays > 0 || p.foodDays > 0);
    add('Fat a day, g', c.foodDays > 0 ? _n(c.fat) : '-', p.foodDays > 0 ? _n(p.fat) : '-',
        show: c.foodDays > 0 || p.foodDays > 0);
    add('Weight at the end, kg', c.weightLast == null ? '-' : _n(c.weightLast!, 1),
        p.weightLast == null ? '-' : _n(p.weightLast!, 1),
        show: c.weightLast != null || p.weightLast != null);
    add('Sleep a night', c.sleepMin == null ? '-' : _h(c.sleepMin!),
        p.sleepMin == null ? '-' : _h(p.sleepMin!),
        show: c.sleepMin != null || p.sleepMin != null);
    add('Sleep score', c.sleepScore == null ? '-' : _n(c.sleepScore!),
        p.sleepScore == null ? '-' : _n(p.sleepScore!),
        show: c.sleepScore != null || p.sleepScore != null);
    add('Steps a day', c.steps == null ? '-' : _n(c.steps!), p.steps == null ? '-' : _n(p.steps!),
        show: c.steps != null || p.steps != null);
    add('Resting heart rate', c.restingHr == null ? '-' : _n(c.restingHr!),
        p.restingHr == null ? '-' : _n(p.restingHr!),
        show: c.restingHr != null || p.restingHr != null);
    add('VO2 max', c.vo2max == null ? '-' : _n(c.vo2max!, 1), p.vo2max == null ? '-' : _n(p.vo2max!, 1),
        show: c.vo2max != null || p.vo2max != null);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Week'), icon: Icon(Icons.view_week)),
            ButtonSegment(value: true, label: Text('Month'), icon: Icon(Icons.calendar_month)),
          ],
          selected: {_month},
          onSelectionChanged: (s) => setState(() {
            _month = s.first;
            _offset = 0;
            _load();
          }),
        ),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(() {
                _offset--;
                _load();
              }),
            ),
            Expanded(
              child: Column(
                children: [
                  Text(_label, style: Theme.of(context).textTheme.titleMedium),
                  if (_r.partial)
                    const Text('not over yet, compared with the same days before',
                        style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: _offset >= 0
                  ? null
                  : () => setState(() {
                        _offset++;
                        _load();
                      }),
            ),
          ],
        ),
        _card('Highlights', [for (final t in _r.highlights) _bullet(t)]),
        _card('For the next ${_month ? 'month' : 'week'}', [for (final t in _r.focus) _bullet(t)]),
        _card('The numbers', _numbers()),
        if (_r.zones.total > 0) _card('Heart-rate zones', [zoneBars(context, _r.zones)]),
      ],
    );
  }
}
