import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import '../workout_format.dart';
import '../workout_types.dart';
import 'workout_detail_screen.dart';

/// All workouts, with a filter by kind of activity.
class WorkoutsScreen extends StatefulWidget {
  const WorkoutsScreen({super.key});

  @override
  State<WorkoutsScreen> createState() => _WorkoutsScreenState();
}

class _WorkoutsScreenState extends State<WorkoutsScreen> {
  List<Workout> _all = [];
  Cat? _cat; // null = all
  int _limit = 100;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() => _all = AppDb.instance.loadAllWorkouts());
  }

  Future<void> _open(Workout w) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => WorkoutDetailScreen(workoutId: w.id)),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final present = Cat.values.where((c) => _all.any((w) => categoryOf(w.type) == c)).toList();
    final list = _cat == null ? _all : _all.where((w) => categoryOf(w.type) == _cat).toList();
    final totalMin = list.fold<double>(0, (s, w) => s + w.minutes);
    final totalKm = list.fold<double>(0, (s, w) => s + (w.distanceM ?? 0) / 1000);
    final sets = list.fold<double>(0, (s, w) => s + (w.metrics['sets'] ?? 0));
    final volume = list.fold<double>(0, (s, w) => s + (w.metrics['volume_kg'] ?? 0));

    final lines = <String>[
      '${list.length} workout(s), ${fmtDur(totalMin)} in total',
      if (totalKm > 0) '${fmt(totalKm)} km in total',
      if (totalKm > 0 &&
          (_cat == Cat.run || _cat == Cat.walk || _cat == Cat.hike))
        'average pace ${fmtPace(totalMin * 60 / totalKm)} /km',
      if (_cat == Cat.cycle && totalKm > 0)
        'average speed ${fmt(totalKm / (totalMin / 60))} km/h',
      if (sets > 0) '${sets.round()} sets, ${fmt(volume)} kg volume',
    ];
    final shown = list.take(_limit).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Workouts')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ChoiceChip(
                  label: Text('All (${_all.length})'),
                  selected: _cat == null,
                  onSelected: (_) => setState(() {
                    _cat = null;
                    _limit = 100;
                  }),
                ),
                for (final c in present) ...[
                  const SizedBox(width: 8),
                  ChoiceChip(
                    avatar: Icon(catIcon(c), size: 18),
                    label: Text(
                        '${catLabel(c)} (${_all.where((w) => categoryOf(w.type) == c).length})'),
                    selected: _cat == c,
                    onSelected: (_) => setState(() {
                      _cat = c;
                      _limit = 100;
                    }),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(lines.join('  |  '), style: const TextStyle(fontSize: 12)),
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('No workouts.'))
                : ListView.builder(
                    itemCount: shown.length + (list.length > shown.length ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == shown.length) {
                        return Padding(
                          padding: const EdgeInsets.all(12),
                          child: OutlinedButton(
                            onPressed: () => setState(() => _limit += 100),
                            child: const Text('Show more'),
                          ),
                        );
                      }
                      final w = shown[i];
                      return ListTile(
                        leading: Icon(catIcon(categoryOf(w.type))),
                        title: Text(workoutTitle(w)),
                        subtitle: Text(summaryLine(w)),
                        onTap: () => _open(w),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
