import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import '../widgets.dart';

/// Asks for type, duration and date, and saves a manual workout.
/// Returns true if one was added.
Future<bool> showAddWorkoutDialog(BuildContext context) async {
  final type = TextEditingController(text: 'Strength training');
  final mins = TextEditingController();
  final kcal = TextEditingController();
  var day = DateTime.now();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setS) {
        void submit() {
          final m = parseNum(mins.text);
          if (type.text.trim().isEmpty || m == null || m <= 0) return;
          Navigator.pop(context, true);
        }

        return AlertDialog(
          title: const Text('Add workout'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: type,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Type'),
                ),
                numField(
                    controller: mins,
                    label: 'Duration',
                    suffix: 'min',
                    onSubmitted: (_) => submit()),
                numField(
                    controller: kcal,
                    label: 'Active calories (optional)',
                    suffix: 'kcal',
                    onSubmitted: (_) => submit()),
                TextButton(
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: day,
                      firstDate: DateTime(2015),
                      lastDate: DateTime(2100),
                    );
                    if (d != null) setS(() => day = d);
                  },
                  child: Text('Date: ${dayKey(day)}'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            TextButton(onPressed: submit, child: const Text('Add')),
          ],
        );
      },
    ),
  );
  final m = parseNum(mins.text);
  if (ok != true || m == null || m <= 0) return false;
  final start = DateTime(day.year, day.month, day.day, 12);
  AppDb.instance.saveWorkout(Workout(
    id: newId(),
    day: dayKey(day),
    startMs: start.millisecondsSinceEpoch,
    endMs: start.add(Duration(minutes: m.round())).millisecondsSinceEpoch,
    type: type.text.trim(),
    activeKcal: parseNum(kcal.text),
    source: 'manual',
  ));
  return true;
}
