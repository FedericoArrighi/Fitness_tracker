import 'package:flutter/material.dart';
import 'db.dart';

/// The exercises of a routine: for every exercise its sets with type, weight
/// and repetitions. Effort (RPE) is left out, it belongs to one session.
List<Map<String, dynamic>> routineExercises(List<Map<String, dynamic>> exs) {
  final out = <Map<String, dynamic>>[];
  for (final ex in exs) {
    final name = (ex['name'] ?? '').toString().trim();
    if (name.isEmpty) continue;
    final sets = <Map<String, dynamic>>[];
    for (final s in ((ex['sets'] as List?) ?? const [])) {
      final m = (s as Map).cast<String, dynamic>();
      final reps = (m['reps'] as num?)?.toDouble() ?? 0;
      final kg = (m['kg'] as num?)?.toDouble() ?? 0;
      if (reps <= 0 && kg <= 0) continue;
      sets.add({
        'type': (m['type'] ?? 'normal').toString(),
        'kg': kg,
        if (reps > 0) 'reps': reps,
      });
    }
    if (sets.isNotEmpty) {
      final note = (ex['note'] ?? '').toString().trim();
      out.add({
        'name': name,
        'sets': sets,
        if (ex['ss'] != null) 'ss': ex['ss'],
        if (note.isNotEmpty) 'note': note,
      });
    }
  }
  return out;
}

/// A routine as a workout without a date, which the gym logger can start from.
Workout routineToWorkout(UserItem r) => Workout(
      id: r.id,
      day: '',
      startMs: 0,
      endMs: 0,
      type: 'STRENGTH_TRAINING',
      source: 'routine',
      title: (r.data['name'] ?? '').toString(),
      exercises: [
        for (final e in ((r.data['exercises'] as List?) ?? const []))
          (e as Map).cast<String, dynamic>()
      ],
    );

List<Map<String, dynamic>> routineExercisesOf(UserItem r) => [
      for (final e in ((r.data['exercises'] as List?) ?? const []))
        (e as Map).cast<String, dynamic>()
    ];

/// Asks for a name and saves the routine. Returns its id, or null if nothing
/// was saved.
Future<String?> saveRoutineDialog(
  BuildContext context, {
  required String suggestedName,
  required List<Map<String, dynamic>> exercises,
}) async {
  final exs = routineExercises(exercises);
  if (exs.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Nothing to save yet: add exercises with weights or reps first.')));
    return null;
  }
  final name = TextEditingController(text: suggestedName);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Save as routine'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Routine name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text('${exs.length} exercise(s). You can start it later with these '
              'weights and reps filled in.',
              style: const TextStyle(fontSize: 12)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
      ],
    ),
  );
  final text = name.text.trim();
  if (ok != true || text.isEmpty) return null;
  final id = newId();
  AppDb.instance.saveItem('gym_template', id, {'name': text, 'exercises': exs});
  return id;
}
