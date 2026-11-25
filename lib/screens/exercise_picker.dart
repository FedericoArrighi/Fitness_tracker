import 'package:flutter/material.dart';
import '../analysis.dart';
import '../exercise_library.dart';
import '../exercise_setup.dart';
import '../muscles.dart';

/// Bottom sheet of the gym logger: choose an exercise, or create your own.
/// Returns the name of the exercise.
Future<String?> pickExercise(
    BuildContext context, Map<String, List<LiftSession>> history) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: ExerciseBrowser(pick: true, history: history),
      ),
    ),
  );
}

/// The exercise library as its own page (Training, Overview).
class ExerciseLibraryScreen extends StatelessWidget {
  const ExerciseLibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Exercise library')),
      body: const ExerciseBrowser(pick: false),
    );
  }
}

String _equipmentFromName(String name) {
  final n = name.toLowerCase();
  if (n.contains('barbell')) return 'barbell';
  if (n.contains('dumbbell')) return 'dumbbell';
  if (n.contains('cable')) return 'cable';
  if (n.contains('kettlebell')) return 'kettlebell';
  if (n.contains('machine') || n.contains('smith')) return 'machine';
  return 'other';
}

/// Search box, filters and the list of exercises. With [pick] a tap returns
/// the exercise; without it a tap shows its details.
class ExerciseBrowser extends StatefulWidget {
  final bool pick;
  final Map<String, List<LiftSession>> history;
  const ExerciseBrowser({super.key, required this.pick, this.history = const {}});

  @override
  State<ExerciseBrowser> createState() => _ExerciseBrowserState();
}

class _ExerciseBrowserState extends State<ExerciseBrowser> {
  String _q = '';
  String? _muscle; // a key of muscleGroups
  String? _equip; // a key of exerciseEquipment
  List<LibExercise> _all = [];
  Map<String, int> _used = {}; // lower-case name -> how many times you did it

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    reloadCustomExercises();
    final over = loadMuscleOverrides();
    final used = <String, int>{};
    final names = <String, String>{};
    for (final l in widget.history.values) {
      if (l.isEmpty) continue;
      final k = l.first.name.toLowerCase();
      used[k] = l.length;
      names[k] = l.first.name;
    }
    final list = allExercises();
    final known = {for (final e in list) e.name.toLowerCase()};
    // exercises from your history (for example imported ones) that the
    // library does not know yet
    names.forEach((k, n) {
      if (known.add(k)) {
        list.add(LibExercise(n, _equipmentFromName(n), 'wr', muscleProfileOf(n, over)));
      }
    });
    list.sort((a, b) {
      final ua = used[a.name.toLowerCase()] ?? 0;
      final ub = used[b.name.toLowerCase()] ?? 0;
      if (ua != ub) return ub.compareTo(ua);
      if (a.custom != b.custom) return a.custom ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    _all = list;
    _used = used;
  }

  bool _matches(LibExercise e, List<String> words) {
    if (_muscle != null && !e.muscles.primary.contains(_muscle)) return false;
    if (_equip != null && e.equipment != _equip) return false;
    final hay =
        '${e.name} ${exerciseEquipment[e.equipment]} ${muscleNames(e.muscles.primary)}'
            .toLowerCase();
    return words.every(hay.contains);
  }

  String _subtitle(LibExercise e) {
    final parts = <String>[
      e.muscles.primary.isEmpty ? 'No strength muscles' : muscleNames(e.muscles.primary),
      exerciseEquipment[e.equipment] ?? e.equipment,
      exerciseKinds[e.kind] ?? e.kind,
    ];
    return parts.join(' · ');
  }

  Future<void> _create(String name) async {
    final e = await editExerciseDialog(context, name: name);
    if (!mounted) return;
    if (e != null && widget.pick) {
      Navigator.pop(context, e.name);
      return;
    }
    setState(_load);
  }

  Future<void> _edit(LibExercise e) async {
    await editExerciseDialog(context, existing: e);
    if (!mounted) return;
    setState(_load);
  }

  Future<void> _details(LibExercise e) async {
    final saved = loadExerciseSetup(e.name);
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(e.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Main muscles: ${e.muscles.primary.isEmpty ? '-' : muscleNames(e.muscles.primary)}'),
            Text('Also works: ${e.muscles.secondary.isEmpty ? '-' : muscleNames(e.muscles.secondary)}'),
            Text('Equipment: ${exerciseEquipment[e.equipment] ?? e.equipment}'),
            Text('Type: ${exerciseKinds[e.kind] ?? e.kind}'),
            if ((_used[e.name.toLowerCase()] ?? 0) > 0)
              Text('You did it ${_used[e.name.toLowerCase()]} times.'),
            Text(saved.isEmpty
                ? 'Machine and settings: not saved yet'
                : 'Machine and settings: ${saved.summary}'),
            const SizedBox(height: 8),
            Text(
                e.custom
                    ? 'This is your own exercise.'
                    : 'Built-in exercise. You can save your own version with different muscles or type; it replaces this one in your stats.',
                style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, 'close'),
              child: const Text('Close')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'setup'),
              child: const Text('Machine settings')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'change'),
              child: Text(e.custom ? 'Edit' : 'Change')),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'setup') {
      await editExerciseSetupDialog(context, e.name);
    } else if (action == 'change') {
      await _edit(e);
    }
  }

  Widget _chips(Map<String, String> items, String? selected, void Function(String?) onPick) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final e in items.entries)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(e.value),
                selected: selected == e.key,
                onSelected: (v) => onPick(v ? e.key : null),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim();
    final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final shown = [
      for (final e in _all)
        if (_matches(e, words)) e
    ];
    final exact = _all.any((e) => e.name.toLowerCase() == q.toLowerCase());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            autofocus: widget.pick,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search exercises',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _q = v),
            onSubmitted: (v) {
              if (widget.pick && shown.isNotEmpty) {
                Navigator.pop(context, shown.first.name);
              }
            },
          ),
        ),
        _chips({for (final m in muscleGroups) m: muscleLabels[m] ?? m}, _muscle,
            (v) => setState(() => _muscle = v)),
        _chips(exerciseEquipment, _equip, (v) => setState(() => _equip = v)),
        Expanded(
          child: ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: Text(q.isEmpty || exact ? 'Create your own exercise' : 'Create "$q"'),
                subtitle: const Text('With muscles, equipment and type'),
                onTap: () => _create(q.isEmpty || exact ? '' : q),
              ),
              if (widget.pick && q.isNotEmpty && !exact)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text('Just use "$q" this time'),
                  subtitle: const Text('Not saved in the library'),
                  onTap: () => Navigator.pop(context, q),
                ),
              for (final e in shown.take(150))
                ListTile(
                  leading: e.custom ? const Icon(Icons.person_outline) : null,
                  title: Text(e.name),
                  subtitle: Text(_subtitle(e)),
                  trailing: (_used[e.name.toLowerCase()] ?? 0) > 0
                      ? Text('${_used[e.name.toLowerCase()]}x',
                          style: const TextStyle(fontSize: 12))
                      : null,
                  onTap: widget.pick ? () => Navigator.pop(context, e.name) : () => _details(e),
                  onLongPress: e.custom ? () => _edit(e) : null,
                ),
              if (shown.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('Nothing found.')),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Creates or changes an exercise of your own. A built-in exercise passed as
/// [existing] is saved as your own version with the same name. Returns the
/// saved exercise, or null if nothing was saved (or it was deleted).
Future<LibExercise?> editExerciseDialog(BuildContext context,
    {LibExercise? existing, String name = ''}) async {
  final nameC = TextEditingController(text: existing?.name ?? name);
  var equip = existing?.equipment ?? 'other';
  var kind = existing?.kind ?? 'wr';
  final p = <String>{...?existing?.muscles.primary};
  final s = <String>{...?existing?.muscles.secondary};
  // your own exercise that is being changed (null for a new one or a built-in)
  final own = (existing != null && existing.custom) ? existing : null;
  final isOwn = own != null;
  final res = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setS) => AlertDialog(
        title: Text(isOwn ? 'Edit exercise' : 'New exercise'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameC,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    helperText: isOwn ? 'Past workouts keep the old name.' : null,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Equipment  '),
                    DropdownButton<String>(
                      value: equip,
                      items: [
                        for (final e in exerciseEquipment.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setS(() => equip = v ?? equip),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Text('Type  '),
                    Expanded(
                      child: DropdownButton<String>(
                        value: kind,
                        isExpanded: true,
                        items: [
                          for (final e in exerciseKinds.entries)
                            DropdownMenuItem(value: e.key, child: Text(e.value)),
                        ],
                        onChanged: (v) => setS(() => kind = v ?? kind),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('Main muscles', style: TextStyle(fontWeight: FontWeight.w600)),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final m in muscleGroups)
                      FilterChip(
                        label: Text(muscleLabels[m] ?? m),
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
                const SizedBox(height: 8),
                const Text('Also works', style: TextStyle(fontWeight: FontWeight.w600)),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final m in muscleGroups)
                      FilterChip(
                        label: Text(muscleLabels[m] ?? m),
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
          if (isOwn)
            TextButton(
                onPressed: () => Navigator.pop(context, 'delete'),
                child: const Text('Delete')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('Save')),
        ],
      ),
    ),
  );
  final text = nameC.text.trim();
  // the dialog is still fading out for a moment, so dispose a little later
  Future.delayed(const Duration(seconds: 1), nameC.dispose);
  if (res == 'delete' && own != null) {
    deleteCustomExercise(own.id);
    return null;
  }
  if (res != 'save' || text.isEmpty) return null;
  // the same name as another exercise of yours: change that one
  var id = own != null ? own.id : '';
  if (own == null) {
    for (final c in loadCustomExercises()) {
      if (c.name.toLowerCase() == text.toLowerCase()) id = c.id;
    }
  }
  final e = LibExercise(text, equip, kind, MuscleProfile(p.toList(), s.toList()),
      custom: true, id: id);
  saveCustomExercise(e);
  return e;
}
