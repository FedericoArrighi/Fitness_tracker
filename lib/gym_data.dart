import 'nutrients.dart';

/// Suggestions for the exercise picker (your own history comes first).
const builtinExercises = [
  'Bench Press (Barbell)', 'Incline Bench Press (Barbell)', 'Decline Bench Press (Barbell)',
  'Bench Press (Dumbbell)', 'Incline Bench Press (Dumbbell)', 'Chest Fly (Dumbbell)',
  'Chest Press (Machine)', 'Pec Deck (Machine)', 'Cable Fly', 'Push Up', 'Dip',
  'Squat (Barbell)', 'Front Squat (Barbell)', 'Goblet Squat (Dumbbell)', 'Hack Squat (Machine)',
  'Leg Press (Machine)', 'Leg Extension (Machine)', 'Lying Leg Curl (Machine)',
  'Seated Leg Curl (Machine)', 'Romanian Deadlift (Barbell)', 'Deadlift (Barbell)',
  'Sumo Deadlift (Barbell)', 'Trap Bar Deadlift', 'Hip Thrust (Barbell)', 'Glute Bridge',
  'Lunge (Dumbbell)', 'Walking Lunge (Dumbbell)', 'Bulgarian Split Squat (Dumbbell)',
  'Step Up (Dumbbell)', 'Standing Calf Raise (Machine)', 'Seated Calf Raise (Machine)',
  'Good Morning (Barbell)', 'Back Extension',
  'Overhead Press (Barbell)', 'Shoulder Press (Dumbbell)', 'Seated Shoulder Press (Machine)',
  'Arnold Press (Dumbbell)', 'Lateral Raise (Dumbbell)', 'Lateral Raise (Cable)',
  'Front Raise (Dumbbell)', 'Rear Delt Fly (Dumbbell)', 'Reverse Fly (Machine)',
  'Face Pull (Cable)', 'Upright Row (Barbell)', 'Shrug (Barbell)', 'Shrug (Dumbbell)',
  'Pull Up', 'Chin Up', 'Assisted Pull Up (Machine)', 'Lat Pulldown (Cable)',
  'Bent Over Row (Barbell)', 'Seated Row (Cable)', 'One Arm Row (Dumbbell)',
  'T-Bar Row', 'Inverted Row', 'Straight Arm Pulldown (Cable)',
  'Bicep Curl (Barbell)', 'Bicep Curl (Dumbbell)', 'Hammer Curl (Dumbbell)',
  'Preacher Curl (Barbell)', 'Concentration Curl (Dumbbell)', 'Cable Curl',
  'Triceps Pushdown (Cable)', 'Skullcrusher (Barbell)', 'Overhead Triceps Extension (Dumbbell)',
  'Close Grip Bench Press (Barbell)', 'Triceps Dip',
  'Plank', 'Side Plank', 'Crunch', 'Cable Crunch', 'Hanging Leg Raise', 'Leg Raise',
  'Russian Twist', 'Ab Wheel', 'Farmer\'s Walk', 'Kettlebell Swing',
  'Clean and Jerk (Barbell)', 'Snatch (Barbell)', 'Power Clean (Barbell)',
  'Box Jump', 'Burpee', 'Thruster (Barbell)',
];

String _w(double v) => rawNum((v * 10).round() / 10);

/// sets, repetitions and volume of a list of exercises
/// ([{name, sets: [{type, kg, reps}]}]); warm-up sets do not count.
Map<String, double> strengthMetrics(List<Map<String, dynamic>> exs) {
  var sets = 0.0, reps = 0.0, vol = 0.0, rpeSum = 0.0, rpeN = 0;
  for (final ex in exs) {
    for (final s in ((ex['sets'] as List?) ?? const [])) {
      final m = (s as Map).cast<String, dynamic>();
      if ((m['type'] ?? 'normal') == 'warmup') continue;
      final r = (m['reps'] as num?)?.toDouble() ?? 0;
      final kg = (m['kg'] as num?)?.toDouble() ?? 0;
      sets++;
      reps += r;
      vol += kg * r;
      final rpe = (m['rpe'] as num?)?.toDouble();
      if (rpe != null && rpe > 0) {
        rpeSum += rpe;
        rpeN++;
      }
    }
  }
  return {
    'sets': sets,
    'reps': reps,
    'volume_kg': vol,
    if (rpeN > 0) 'rpe': rpeSum / rpeN,
  };
}

/// The text shown in lists: first line = summary, then one line per exercise.
String strengthNotes(List<Map<String, dynamic>> exs) {
  final mt = strengthMetrics(exs);
  final lines = <String>[
    'Sets: ${mt['sets']!.round()}, volume: ${fmt(mt['volume_kg']!)} kg',
  ];
  for (final ex in exs) {
    final labels = <String>[];
    var warm = 0;
    for (final s in ((ex['sets'] as List?) ?? const [])) {
      final m = (s as Map).cast<String, dynamic>();
      final type = (m['type'] ?? 'normal').toString();
      if (type == 'warmup') {
        warm++;
        continue;
      }
      final kg = (m['kg'] as num?)?.toDouble() ?? 0;
      final reps = (m['reps'] as num?)?.toDouble() ?? 0;
      var label = kg > 0 ? '${_w(kg)}×${reps.round()}' : '${reps.round()} reps';
      final rpe = (m['rpe'] as num?)?.toDouble();
      if (rpe != null && rpe > 0) label += ' @${_w(rpe)}';
      if (type == 'failure') label += ' (F)';
      if (type == 'dropset') label += ' (drop)';
      labels.add(label);
    }
    lines.add('${ex['name']}: ${labels.join(', ')}${warm > 0 ? ' (+$warm warm-up)' : ''}');
  }
  return lines.join('\n');
}

/// A suggestion for one set, from the same set in your last session.
class SetHint {
  final double kg, reps;
  final String why;
  const SetHint(this.kg, this.reps, this.why);
}

/// Smallest sensible step up in weight for a load of [kg].
double weightStep(double kg) => kg < 20 ? 1.0 : (kg < 100 ? 2.5 : 5.0);

/// Rule of thumb ("double progression" with an RPE check):
///  - felt easy (RPE up to 6.5): add weight, same reps;
///  - RPE 7 to 8: one more rep, or at 12+ reps add weight and go back to 8;
///  - RPE 8.5 or more: repeat last time;
///  - no RPE logged: judged by the reps alone (8 to 12 range).
/// Bodyweight sets (no weight) only get a rep suggestion.
SetHint? progressionHint(double prevKg, double prevReps, double? prevRpe) {
  if (prevReps <= 0) return null;
  final bodyweight = prevKg <= 0;
  final step = weightStep(prevKg);
  SetHint up(String why) => bodyweight
      ? SetHint(0, prevReps + 1, why)
      : SetHint(prevKg + step, prevReps, why);
  SetHint more(String why) => SetHint(prevKg, prevReps + 1, why);
  SetHint repeat(String why) => SetHint(prevKg, prevReps, why);
  SetHint jump(String why) =>
      SetHint(prevKg + step, prevReps >= 12 ? 8 : prevReps, why);

  if (prevRpe != null) {
    if (prevRpe <= 6.5) {
      return up('it felt easy (RPE ${_w(prevRpe)}), so add weight');
    }
    if (prevRpe <= 8) {
      if (!bodyweight && prevReps >= 12) {
        return jump('top of the rep range at RPE ${_w(prevRpe)}: add weight, back to 8 reps');
      }
      return more('RPE ${_w(prevRpe)}: aim for one more rep');
    }
    return repeat('it was hard (RPE ${_w(prevRpe)}): match it again');
  }
  if (bodyweight) return more('aim for one more rep');
  if (prevReps >= 12) return jump('12+ reps last time: add weight, back to 8 reps');
  return more('aim for one more rep, at 12 reps add weight');
}

/// One warm-up set.
class WarmupSet {
  final double kg;
  final int reps;
  const WarmupSet(this.kg, this.reps);
}

/// Warm-up sets leading up to a working weight: lighter and more reps for the
/// first sets, fewer reps close to the working weight. Weights are rounded to
/// 2.5 kg and never below the empty bar. Very light weights need none.
List<WarmupSet> warmupScheme(double working, {double bar = 20}) {
  if (working <= bar * 1.5) return const [];
  final List<List<num>> steps = working >= 100
      ? [[0.4, 8], [0.6, 5], [0.75, 3], [0.9, 1]]
      : (working >= 60 ? [[0.5, 8], [0.7, 4], [0.85, 2]] : [[0.5, 8], [0.75, 4]]);
  final out = <WarmupSet>[];
  for (final st in steps) {
    var kg = ((working * st[0]) / 2.5).round() * 2.5;
    if (kg < bar) kg = bar;
    if (kg >= working) continue;
    if (out.isNotEmpty && out.last.kg >= kg) continue;
    out.add(WarmupSet(kg, st[1].toInt()));
  }
  return out;
}
