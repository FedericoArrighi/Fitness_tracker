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
  var sets = 0.0, reps = 0.0, vol = 0.0;
  for (final ex in exs) {
    for (final s in ((ex['sets'] as List?) ?? const [])) {
      final m = (s as Map).cast<String, dynamic>();
      if ((m['type'] ?? 'normal') == 'warmup') continue;
      final r = (m['reps'] as num?)?.toDouble() ?? 0;
      final kg = (m['kg'] as num?)?.toDouble() ?? 0;
      sets++;
      reps += r;
      vol += kg * r;
    }
  }
  return {'sets': sets, 'reps': reps, 'volume_kg': vol};
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
      if (type == 'failure') label += ' (F)';
      if (type == 'dropset') label += ' (drop)';
      labels.add(label);
    }
    lines.add('${ex['name']}: ${labels.join(', ')}${warm > 0 ? ' (+$warm warm-up)' : ''}');
  }
  return lines.join('\n');
}
