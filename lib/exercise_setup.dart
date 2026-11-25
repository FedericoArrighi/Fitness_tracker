import 'package:flutter/material.dart';
import 'db.dart';

/// The machine and the settings you use for one exercise: seat height, pin,
/// incline, elevation, ... It is remembered per exercise and filled in again
/// the next time you add that exercise to a workout.
class ExerciseSetup {
  final String machine; // brand and model
  final List<List<String>> settings; // [name, value] pairs
  const ExerciseSetup(this.machine, this.settings);

  bool get isEmpty => machine.trim().isEmpty && settings.isEmpty;

  /// One line, for example "Technogym Chest Press · Seat 5 · Pin 12".
  String get summary {
    final parts = <String>[
      if (machine.trim().isNotEmpty) machine.trim(),
      for (final p in settings)
        if (p[0].trim().isNotEmpty || p[1].trim().isNotEmpty)
          [p[0].trim(), p[1].trim()].where((x) => x.isNotEmpty).join(' '),
    ];
    return parts.join(' · ');
  }
}

/// The settings as stored in a workout or a saved setup: a list of
/// {k: name, v: value}.
List<List<String>> settingsFromJson(dynamic raw) {
  final out = <List<String>>[];
  if (raw is List) {
    for (final e in raw) {
      if (e is Map) {
        final k = (e['k'] ?? '').toString().trim();
        final v = (e['v'] ?? '').toString().trim();
        if (k.isNotEmpty || v.isNotEmpty) out.add([k, v]);
      }
    }
  }
  return out;
}

List<Map<String, String>> settingsToJson(List<List<String>> s) {
  final out = <Map<String, String>>[];
  for (final p in s) {
    final k = p[0].trim();
    final v = p[1].trim();
    if (k.isNotEmpty || v.isNotEmpty) out.add({'k': k, 'v': v});
  }
  return out;
}

String _setupId(String exercise) => 'xcfg:${exercise.trim().toLowerCase()}';

/// What you saved for this exercise (empty if nothing).
ExerciseSetup loadExerciseSetup(String exercise) {
  final id = _setupId(exercise);
  for (final i in AppDb.instance.loadItems('exercise_setup')) {
    if (i.id == id) {
      return ExerciseSetup(
          (i.data['mach'] ?? '').toString(), settingsFromJson(i.data['cfg']));
    }
  }
  return const ExerciseSetup('', []);
}

void saveExerciseSetup(String exercise, ExerciseSetup s) {
  final id = _setupId(exercise);
  if (s.isEmpty) {
    AppDb.instance.deleteItem(id);
    return;
  }
  AppDb.instance.saveItem('exercise_setup', id, {
    'name': exercise.trim(),
    'mach': s.machine.trim(),
    'cfg': settingsToJson(s.settings),
  });
}

/// The machines you used before (for quick choosing).
List<String> _knownMachines() {
  final out = <String>{};
  for (final i in AppDb.instance.loadItems('exercise_setup')) {
    final m = (i.data['mach'] ?? '').toString().trim();
    if (m.isNotEmpty) out.add(m);
  }
  final list = out.toList()..sort();
  return list;
}

const _commonSettings = [
  'Seat height',
  'Backrest',
  'Pin / weight',
  'Incline',
  'Elevation',
  'Handle position',
  'Foot position',
  'Grip width',
  'Pad position',
  'Range limiter',
  'Bench angle',
  'Rack height',
];

/// Asks for the machine and the settings of an exercise and saves them for
/// next time. [current] is what the workout has now (otherwise the saved
/// setup is shown). Returns the new setup, or null if cancelled.
Future<ExerciseSetup?> editExerciseSetupDialog(BuildContext context, String exercise,
    {ExerciseSetup? current}) async {
  final start = current ?? loadExerciseSetup(exercise);
  final machineC = TextEditingController(text: start.machine);
  final keys = <TextEditingController>[];
  final vals = <TextEditingController>[];
  final removed = <TextEditingController>[]; // disposed together with the rest
  void addRow([String k = '', String v = '']) {
    keys.add(TextEditingController(text: k));
    vals.add(TextEditingController(text: v));
  }

  // a quick-add name goes into the empty row, if there is one
  void addNamed(String k) {
    if (keys.isNotEmpty &&
        keys.last.text.trim().isEmpty &&
        vals.last.text.trim().isEmpty) {
      keys.last.text = k;
    } else {
      addRow(k);
    }
  }

  for (final p in start.settings) {
    addRow(p[0], p[1]);
  }
  if (keys.isEmpty) addRow();
  final machines = _knownMachines();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setS) => AlertDialog(
        title: Text('Machine and settings: $exercise'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: machineC,
                  decoration: const InputDecoration(
                    labelText: 'Machine (brand, model)',
                    hintText: 'for example Technogym Chest Press',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (machines.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 6,
                      children: [
                        for (final m in machines.take(6))
                          ActionChip(
                            label: Text(m),
                            onPressed: () => setS(() => machineC.text = m),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                const Text('Settings', style: TextStyle(fontWeight: FontWeight.w600)),
                for (var i = 0; i < keys.length; i++)
                  Row(
                    key: ObjectKey(keys[i]),
                    children: [
                      Expanded(
                        flex: 5,
                        child: TextField(
                          controller: keys[i],
                          decoration: const InputDecoration(hintText: 'Setting', isDense: true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: vals[i],
                          decoration: const InputDecoration(hintText: 'Value', isDense: true),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Remove',
                        onPressed: () => setS(() {
                          removed.add(keys.removeAt(i));
                          removed.add(vals.removeAt(i));
                        }),
                      ),
                    ],
                  ),
                TextButton.icon(
                  onPressed: () => setS(() => addRow()),
                  icon: const Icon(Icons.add),
                  label: const Text('Add setting'),
                ),
                const Text('Quick add', style: TextStyle(fontSize: 12)),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final k in _commonSettings)
                      if (!keys.any((c) => c.text.trim().toLowerCase() == k.toLowerCase()))
                        ActionChip(
                          label: Text(k),
                          onPressed: () => setS(() => addNamed(k)),
                        ),
                  ],
                ),
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
  final settings = <List<String>>[
    for (var i = 0; i < keys.length; i++)
      if (keys[i].text.trim().isNotEmpty || vals[i].text.trim().isNotEmpty)
        [keys[i].text.trim(), vals[i].text.trim()]
  ];
  final machine = machineC.text.trim();
  // the dialog is still fading out for a moment, so dispose a little later
  final all = [machineC, ...keys, ...vals, ...removed];
  Future.delayed(const Duration(seconds: 1), () {
    for (final c in all) {
      c.dispose();
    }
  });
  if (ok != true) return null;
  final result = ExerciseSetup(machine, settings);
  saveExerciseSetup(exercise, result);
  return result;
}
