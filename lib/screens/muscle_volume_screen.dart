import 'package:flutter/material.dart';
import '../db.dart';
import '../muscles.dart';

DateTime _monday(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

String _dm(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

String _sets(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// Lets you choose the muscles of one exercise. Returns true if something
/// was saved or reset.
Future<bool> editMusclesDialog(
    BuildContext context, String name, Map<String, MuscleProfile> over) async {
  final key = name.trim().toLowerCase();
  final cur = muscleProfileOf(name, over);
  final p = <String>{...cur.primary};
  final s = <String>{...cur.secondary};
  final res = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setS) => AlertDialog(
        title: Text(name),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Main muscles (each set counts 1)'),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final m in muscleGroups)
                      FilterChip(
                        label: Text(muscleLabels[m]!),
                        selected: p.contains(m),
                        onSelected: (v) => setS(() {
                          if (v) {
                            p.add(m);
                            s.remove(m);
                          } else {
                            p.remove(m);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('Helping muscles (each set counts 0.5)'),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final m in muscleGroups)
                      FilterChip(
                        label: Text(muscleLabels[m]!),
                        selected: s.contains(m),
                        onSelected: (v) => setS(() {
                          if (v) {
                            s.add(m);
                            p.remove(m);
                          } else {
                            s.remove(m);
                          }
                        }),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          if (over.containsKey(key))
            TextButton(
                onPressed: () => Navigator.pop(context, 'reset'),
                child: const Text('Automatic')),
          TextButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (res == 'save') {
    over[key] = MuscleProfile([...p], [...s]);
    saveMuscleOverrides(over);
    return true;
  }
  if (res == 'reset') {
    over.remove(key);
    saveMuscleOverrides(over);
    return true;
  }
  return false;
}

/// Hard sets per week for each muscle group.
class MuscleVolumeScreen extends StatefulWidget {
  const MuscleVolumeScreen({super.key});

  @override
  State<MuscleVolumeScreen> createState() => _MuscleVolumeScreenState();
}

class _MuscleVolumeScreenState extends State<MuscleVolumeScreen> {
  int _weeks = 4;
  List<Workout> _ws = [];
  Map<String, MuscleProfile> _over = {};

  @override
  void initState() {
    super.initState();
    _ws = AppDb.instance.loadAllWorkouts(withEx: true);
    _over = loadMuscleOverrides();
  }

  /// Names of all exercises you did, with how often (lower-case key).
  Map<String, MapEntry<String, int>> _exerciseNames() {
    final out = <String, MapEntry<String, int>>{};
    for (final w in _ws) {
      for (final ex in w.exercises) {
        final n = (ex['name'] ?? '').toString().trim();
        if (n.isEmpty) continue;
        final k = n.toLowerCase();
        final old = out[k];
        out[k] = MapEntry(old?.key ?? n, (old?.value ?? 0) + 1);
      }
    }
    return out;
  }

  Widget _bar(double v) => LayoutBuilder(builder: (context, c) {
        const maxV = 24.0;
        final w = c.maxWidth;
        final cs = Theme.of(context).colorScheme;
        return SizedBox(
          height: 14,
          width: w,
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: cs.outlineVariant.withAlpha(70),
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
              // reference band: 10 to 20 sets
              Positioned(
                left: w * 10 / maxV,
                width: w * 10 / maxV,
                top: 0,
                bottom: 0,
                child: Container(color: cs.outline.withAlpha(50)),
              ),
              Positioned(
                left: 0,
                width: (v / maxV).clamp(0.0, 1.0) * w,
                top: 2,
                bottom: 2,
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ],
          ),
        );
      });

  Future<void> _detail(String muscle, MuscleResult period) async {
    final mon = _monday(DateTime.now());
    final weekLines = <String>[];
    for (var i = 7; i >= 0; i--) {
      final start = DateTime(mon.year, mon.month, mon.day - 7 * i);
      final end = i == 0 ? DateTime.now() : DateTime(start.year, start.month, start.day + 6);
      final r = muscleSets(_ws, dayKey(start), dayKey(end), _over);
      weekLines.add('${_dm(start)}${i == 0 ? '*' : ''}:  ${_sets(r.sets[muscle]!)} sets');
    }
    final ex = period.byExercise[muscle]!.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(muscleLabels[muscle]!),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Sets per week (week starting on Monday)',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              for (final l in weekLines) Text(l),
              const Text('* this week so far', style: TextStyle(fontSize: 11)),
              if (ex.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Exercises in the last $_weeks weeks',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                for (final e in ex.take(8))
                  Text('${e.key}: ${_sets(e.value)} sets in total'),
              ],
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  Future<void> _editAll() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const _AllExercisesScreen()),
    );
    if (mounted) setState(() => _over = loadMuscleOverrides());
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final mon = _monday(today);
    final from = DateTime(mon.year, mon.month, mon.day - 7 * _weeks);
    final to = DateTime(mon.year, mon.month, mon.day - 1);
    final period = muscleSets(_ws, dayKey(from), dayKey(to), _over);
    final week = muscleSets(_ws, dayKey(mon), dayKey(today), _over);
    final names = _exerciseNames();
    final unknown = [
      for (final e in names.entries)
        if (muscleProfileOf(e.value.key, _over).isEmpty) e.value
    ]..sort((a, b) => b.value.compareTo(a.value));
    final anyData = period.sets.values.any((v) => v > 0) || week.sets.values.any((v) => v > 0);

    return Scaffold(
      appBar: AppBar(title: const Text('Muscle groups')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 4, label: Text('4 weeks')),
              ButtonSegment(value: 8, label: Text('8 weeks')),
              ButtonSegment(value: 12, label: Text('12 weeks')),
            ],
            selected: {_weeks},
            onSelectionChanged: (s) => setState(() => _weeks = s.first),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Hard sets per week',
                      style: Theme.of(context).textTheme.titleMedium),
                  Text('Average over the last $_weeks finished weeks (${_dm(from)} to ${_dm(to)}), '
                      'and this week so far. Warm-up sets do not count. A set counts 1 for '
                      'the main muscles and 0.5 for helping muscles.',
                      style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  if (!anyData)
                    const Text('No gym sets in this period.')
                  else ...[
                    Row(
                      children: const [
                        SizedBox(width: 96),
                        Expanded(child: SizedBox()),
                        SizedBox(width: 46, child: Text('avg', textAlign: TextAlign.right, style: TextStyle(fontSize: 11))),
                        SizedBox(width: 62, child: Text('this week', textAlign: TextAlign.right, style: TextStyle(fontSize: 11))),
                      ],
                    ),
                    for (final m in muscleGroups)
                      InkWell(
                        onTap: () => _detail(m, period),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              SizedBox(width: 96, child: Text(muscleLabels[m]!)),
                              Expanded(child: _bar(period.sets[m]! / _weeks)),
                              SizedBox(
                                  width: 46,
                                  child: Text(_sets(period.sets[m]! / _weeks),
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(fontWeight: FontWeight.w600))),
                              SizedBox(
                                  width: 62,
                                  child: Text(_sets(week.sets[m]!),
                                      textAlign: TextAlign.right)),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 4),
                    const Text(
                        'The grey band marks 10 to 20 sets a week, a range often used for muscle '
                        'growth. It is only a reference. Tap a muscle for the weekly numbers and '
                        'the exercises behind it.',
                        style: TextStyle(fontSize: 11)),
                  ],
                ],
              ),
            ),
          ),
          if (unknown.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Exercises without a muscle group',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Text('These are not counted yet. Tap one to choose its muscles.',
                        style: TextStyle(fontSize: 12)),
                    for (final u in unknown.take(12))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(u.key),
                        subtitle: Text('${u.value} workout(s)'),
                        trailing: const Icon(Icons.edit_outlined, size: 18),
                        onTap: () async {
                          if (await editMusclesDialog(context, u.key, _over) && mounted) {
                            setState(() {});
                          }
                        },
                      ),
                    if (unknown.length > 12) Text('and ${unknown.length - 12} more...'),
                  ],
                ),
              ),
            ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Muscle groups of all exercises'),
              subtitle: const Text('Check or change what each exercise trains'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _editAll,
            ),
          ),
        ],
      ),
    );
  }
}

/// Every exercise with the muscles it counts for.
class _AllExercisesScreen extends StatefulWidget {
  const _AllExercisesScreen();

  @override
  State<_AllExercisesScreen> createState() => _AllExercisesScreenState();
}

class _AllExercisesScreenState extends State<_AllExercisesScreen> {
  Map<String, MuscleProfile> _over = {};
  List<MapEntry<String, int>> _names = [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    _over = loadMuscleOverrides();
    final seen = <String, MapEntry<String, int>>{};
    for (final w in AppDb.instance.loadAllWorkouts(withEx: true)) {
      for (final ex in w.exercises) {
        final n = (ex['name'] ?? '').toString().trim();
        if (n.isEmpty) continue;
        final old = seen[n.toLowerCase()];
        seen[n.toLowerCase()] = MapEntry(old?.key ?? n, (old?.value ?? 0) + 1);
      }
    }
    _names = seen.values.toList()..sort((a, b) => b.value.compareTo(a.value));
  }

  String _text(String name) {
    final p = muscleProfileOf(name, _over);
    if (p.isEmpty) return 'not assigned';
    final main = p.primary.map((m) => muscleLabels[m] ?? m).join(', ');
    final sec = p.secondary.map((m) => muscleLabels[m] ?? m).join(', ');
    return sec.isEmpty ? main : '$main  (also $sec)';
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = [
      for (final e in _names)
        if (q.isEmpty || e.key.toLowerCase().contains(q)) e
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Muscle groups of exercises')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: shown.length,
              itemBuilder: (context, i) {
                final e = shown[i];
                final edited = _over.containsKey(e.key.toLowerCase());
                return ListTile(
                  title: Text(e.key),
                  subtitle: Text(_text(e.key)),
                  trailing: edited ? const Icon(Icons.edit, size: 16) : null,
                  onTap: () async {
                    if (await editMusclesDialog(context, e.key, _over) && mounted) {
                      setState(() {});
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
