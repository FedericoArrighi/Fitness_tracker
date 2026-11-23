import 'package:flutter/material.dart';
import '../db.dart';
import '../fitness.dart';
import '../nutrients.dart';
import '../widgets.dart';

String _dm(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

/// A coloured bar for the time in each heart-rate zone.
Widget zoneBars(BuildContext context, ZoneResult z) {
  const names = ['Zone 1  50-60 %', 'Zone 2  60-70 %', 'Zone 3  70-80 %', 'Zone 4  80-90 %', 'Zone 5  90-100 %'];
  const colors = [
    Color(0xFF8AB4F8),
    Color(0xFF81C995),
    Color(0xFFFDD663),
    Color(0xFFF6A15B),
    Color(0xFFE5675E),
  ];
  final total = z.total;
  if (total <= 0) {
    return const Text('No heart-rate data in this period.', style: TextStyle(fontSize: 12));
  }
  String dur(double m) => m >= 60 ? '${(m ~/ 60)} h ${(m % 60).round()} min' : '${m.round()} min';
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
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
                  Text('${dur(z.minutes[i])}  (${(z.minutes[i] * 100 / total).round()} %)',
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: z.minutes[i] / total,
                  minHeight: 8,
                  color: colors[i],
                  backgroundColor: Theme.of(context).colorScheme.outlineVariant.withAlpha(70),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 4),
      Text(
        'Easy (zones 1 and 2): ${(z.easyShare * 100).round()} %,  '
        'hard (zones 4 and 5): ${(z.hardShare * 100).round()} %'
        '${z.fromLaps ? '\nPart of this comes from laps, so it is approximate.' : ''}',
        style: const TextStyle(fontSize: 12),
      ),
    ],
  );
}

/// Recovery, heart-rate zones and training load.
class FitnessView extends StatefulWidget {
  const FitnessView({super.key});

  @override
  State<FitnessView> createState() => _FitnessViewState();
}

class _FitnessViewState extends State<FitnessView> {
  bool _week = true; // zones: this week or the last 4 weeks
  late RecoveryStatus _rec;
  late ZoneResult _zones;
  late List<WeekLoad> _loads;

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime get _mondayNow {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day - (n.weekday - 1));
  }

  void _load() {
    final now = DateTime.now();
    final mon = _mondayNow;
    final maxHr = maxHrSetting();
    _rec = computeRecovery(now);
    final from = _week ? mon : DateTime(now.year, now.month, now.day - 27);
    _zones = zoneTotals(from, DateTime(now.year, now.month, now.day + 1), maxHr);
    _loads = weeklyLoads(8);
  }

  Future<void> _setMaxHr() async {
    var observed = 0.0;
    for (final w in AppDb.instance.loadAllWorkouts()) {
      final m = w.metrics['max_hr'];
      if (m != null && m > observed && m < 230) observed = m;
    }
    final ctl = TextEditingController(text: rawNum(maxHrSetting()));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Maximum heart rate'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            numField(controller: ctl, label: 'Maximum heart rate', suffix: 'bpm'),
            if (observed > 0)
              Text('The highest value in your workouts is ${observed.round()} bpm.',
                  style: const TextStyle(fontSize: 12)),
            const Text('The zones are percentages of this number.',
                style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    final v = parseNum(ctl.text);
    if (ok == true && v != null && v >= 120 && v <= 230) {
      AppDb.instance.setSetting('max_hr', v.round().toString());
      setState(_load);
    }
  }

  Widget _recoveryCard() {
    final cs = Theme.of(context).colorScheme;
    String label;
    Color color;
    IconData icon;
    switch (_rec.level) {
      case 'good':
        label = 'Well recovered';
        color = Colors.green;
        icon = Icons.battery_full;
        break;
      case 'okay':
        label = 'Okay, train as planned';
        color = Colors.orange;
        icon = Icons.battery_4_bar;
        break;
      case 'low':
        label = 'Take it easy today';
        color = cs.error;
        icon = Icons.battery_2_bar;
        break;
      default:
        label = 'Not enough data yet';
        color = cs.outline;
        icon = Icons.battery_unknown;
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(label,
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(color: color, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_rec.factors.isEmpty)
              const Text('This needs resting heart rate, sleep and a few weeks of workouts. '
                  'Import them from Health Connect or the Garmin export.'),
            for (final f in _rec.factors)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      f.points > 0
                          ? Icons.arrow_upward
                          : (f.points < 0 ? Icons.arrow_downward : Icons.remove),
                      size: 16,
                      color: f.points > 0
                          ? Colors.green
                          : (f.points < 0 ? cs.error : cs.outline),
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(f.text, style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            const Text(
                'A rough guide from your own numbers, not medical advice. '
                'Arrows show what helps (up) or hurts (down) your recovery.',
                style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _zonesCard() {
    final maxHr = maxHrSetting();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text('Heart-rate zones',
                        style: Theme.of(context).textTheme.titleMedium)),
                TextButton(onPressed: _setMaxHr, child: Text('Max ${maxHr.round()} bpm')),
              ],
            ),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('This week')),
                ButtonSegment(value: false, label: Text('Last 4 weeks')),
              ],
              selected: {_week},
              onSelectionChanged: (s) => setState(() {
                _week = s.first;
                _load();
              }),
            ),
            const SizedBox(height: 8),
            zoneBars(context, _zones),
          ],
        ),
      ),
    );
  }

  Widget _loadCard() {
    var maxLoad = 0.0;
    for (final l in _loads) {
      if (l.load > maxLoad) maxLoad = l.load;
    }
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Training load per week', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (var i = 0; i < _loads.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                        width: 56,
                        child: Text('${_dm(_loads[i].start)}${i == _loads.length - 1 ? '*' : ''}',
                            style: const TextStyle(fontSize: 12))),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: maxLoad <= 0 ? 0 : _loads[i].load / maxLoad,
                          minHeight: 10,
                          color: i == _loads.length - 1 ? cs.primary.withAlpha(120) : cs.primary,
                          backgroundColor: cs.outlineVariant.withAlpha(70),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 96,
                      child: Text(
                        '${_loads[i].load.round()}  (${_loads[i].sessions}x)',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            const Text(
                'Load = minutes x effort of each session. Effort is your RPE if you gave one, '
                'otherwise the average heart rate stands in for it. * = this week so far.',
                style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [_recoveryCard(), _zonesCard(), _loadCard()],
    );
  }
}
