import 'db.dart';
import 'muscles.dart';

/// The ways a set can be logged. The code is what is stored.
const exerciseKinds = {
  'wr': 'Weight and reps',
  'br': 'Bodyweight reps',
  'wb': 'Weighted bodyweight',
  'ab': 'Assisted bodyweight',
  'du': 'Duration',
  'dw': 'Duration and weight',
  'dd': 'Distance and duration',
  'wd': 'Weight and distance',
};

const exerciseEquipment = {
  'barbell': 'Barbell',
  'dumbbell': 'Dumbbell',
  'machine': 'Machine',
  'cable': 'Cable',
  'bodyweight': 'Bodyweight',
  'kettlebell': 'Kettlebell',
  'band': 'Band',
  'other': 'Other',
};

/// One exercise of the library (built in or created by you).
class LibExercise {
  final String name;
  final String equipment; // a key of exerciseEquipment
  final String kind; // a key of exerciseKinds
  final MuscleProfile muscles;
  final bool custom;
  final String id; // only for your own exercises
  const LibExercise(this.name, this.equipment, this.kind, this.muscles,
      {this.custom = false, this.id = ''});
}

// One exercise per line: name | equipment | type | primary muscles |
// secondary muscles. The muscle groups are the ones of the weekly volume.
// Names follow Hevy ("Bench Press (Barbell)") so imported workouts match.
const _catalog = <String>[
  // ---- chest ----
  'Bench Press (Barbell)|barbell|wr|chest|triceps,shoulders',
  'Incline Bench Press (Barbell)|barbell|wr|chest|triceps,shoulders',
  'Decline Bench Press (Barbell)|barbell|wr|chest|triceps,shoulders',
  'Close Grip Bench Press (Barbell)|barbell|wr|triceps|chest,shoulders',
  'Floor Press (Barbell)|barbell|wr|chest|triceps,shoulders',
  'Bench Press (Smith Machine)|machine|wr|chest|triceps,shoulders',
  'Incline Bench Press (Smith Machine)|machine|wr|chest|triceps,shoulders',
  'Bench Press (Dumbbell)|dumbbell|wr|chest|triceps,shoulders',
  'Incline Bench Press (Dumbbell)|dumbbell|wr|chest|triceps,shoulders',
  'Decline Bench Press (Dumbbell)|dumbbell|wr|chest|triceps,shoulders',
  'Floor Press (Dumbbell)|dumbbell|wr|chest|triceps,shoulders',
  'Chest Fly (Dumbbell)|dumbbell|wr|chest|',
  'Incline Chest Fly (Dumbbell)|dumbbell|wr|chest|',
  'Chest Press (Machine)|machine|wr|chest|triceps,shoulders',
  'Incline Chest Press (Machine)|machine|wr|chest|triceps,shoulders',
  'Pec Deck (Machine)|machine|wr|chest|',
  'Chest Fly (Machine)|machine|wr|chest|',
  'Cable Fly|cable|wr|chest|',
  'Low Cable Fly|cable|wr|chest|',
  'Cable Crossover|cable|wr|chest|',
  'Push Up|bodyweight|br|chest|triceps,shoulders',
  'Incline Push Up|bodyweight|br|chest|triceps,shoulders',
  'Decline Push Up|bodyweight|br|chest|triceps,shoulders',
  'Diamond Push Up|bodyweight|br|triceps|chest,shoulders',
  'Weighted Push Up|bodyweight|wb|chest|triceps,shoulders',
  'Chest Dip|bodyweight|br|chest|triceps,shoulders',
  'Chest Dip (Weighted)|bodyweight|wb|chest|triceps,shoulders',
  'Chest Dip (Assisted)|machine|ab|chest|triceps,shoulders',
  'Svend Press (Plate)|other|wr|chest|',
  // ---- back ----
  'Pull Up|bodyweight|br|back|biceps',
  'Pull Up (Weighted)|bodyweight|wb|back|biceps',
  'Pull Up (Assisted)|machine|ab|back|biceps',
  'Chin Up|bodyweight|br|back|biceps',
  'Chin Up (Weighted)|bodyweight|wb|back|biceps',
  'Chin Up (Assisted)|machine|ab|back|biceps',
  'Neutral Grip Pull Up|bodyweight|br|back|biceps',
  'Lat Pulldown (Cable)|cable|wr|back|biceps',
  'Lat Pulldown - Close Grip (Cable)|cable|wr|back|biceps',
  'Lat Pulldown (Machine)|machine|wr|back|biceps',
  'Single Arm Lat Pulldown|cable|wr|back|biceps',
  'Straight Arm Lat Pulldown (Cable)|cable|wr|back|',
  'Dumbbell Pullover|dumbbell|wr|back|',
  'Bent Over Row (Barbell)|barbell|wr|back|biceps',
  'Pendlay Row (Barbell)|barbell|wr|back|biceps',
  'Bent Over Row (Dumbbell)|dumbbell|wr|back|biceps',
  'One Arm Row (Dumbbell)|dumbbell|wr|back|biceps',
  'Seal Row|barbell|wr|back|biceps',
  'T-Bar Row|barbell|wr|back|biceps',
  'Seated Cable Row|cable|wr|back|biceps',
  'Seated Cable Row - Bar Wide Grip|cable|wr|back|biceps',
  'Seated Row (Machine)|machine|wr|back|biceps',
  'Iso-Lateral Row (Machine)|machine|wr|back|biceps',
  'Chest Supported Row (Machine)|machine|wr|back|biceps',
  'Chest Supported Incline Row (Dumbbell)|dumbbell|wr|back|biceps',
  'Inverted Row|bodyweight|br|back|biceps',
  'Meadows Row (Barbell)|barbell|wr|back|biceps',
  'Face Pull (Cable)|cable|wr|shoulders|back',
  'Shrug (Barbell)|barbell|wr|back|forearms',
  'Shrug (Dumbbell)|dumbbell|wr|back|forearms',
  'Shrug (Machine)|machine|wr|back|forearms',
  'Back Extension|bodyweight|br|back|glutes,hamstrings',
  'Back Extension (Weighted)|bodyweight|wb|back|glutes,hamstrings',
  'Back Extension (Machine)|machine|wr|back|glutes,hamstrings',
  'Reverse Hyperextension|machine|wr|back|glutes,hamstrings',
  'Rack Pull (Barbell)|barbell|wr|back|glutes,hamstrings,forearms',
  // ---- legs ----
  'Squat (Barbell)|barbell|wr|quads|glutes,hamstrings',
  'Front Squat (Barbell)|barbell|wr|quads|glutes,hamstrings',
  'Box Squat (Barbell)|barbell|wr|quads|glutes,hamstrings',
  'Squat (Smith Machine)|machine|wr|quads|glutes,hamstrings',
  'Squat (Dumbbell)|dumbbell|wr|quads|glutes,hamstrings',
  'Goblet Squat (Kettlebell)|kettlebell|wr|quads|glutes,hamstrings',
  'Goblet Squat (Dumbbell)|dumbbell|wr|quads|glutes,hamstrings',
  'Bodyweight Squat|bodyweight|br|quads|glutes,hamstrings',
  'Pistol Squat|bodyweight|br|quads|glutes,hamstrings',
  'Hack Squat (Machine)|machine|wr|quads|glutes,hamstrings',
  'Leg Press (Machine)|machine|wr|quads|glutes,hamstrings',
  'Single Leg Press (Machine)|machine|wr|quads|glutes,hamstrings',
  'Sled Leg Press|machine|wr|quads|glutes,hamstrings',
  'Leg Extension (Machine)|machine|wr|quads|',
  'Single Leg Extension (Machine)|machine|wr|quads|',
  'Lying Leg Curl (Machine)|machine|wr|hamstrings|',
  'Seated Leg Curl (Machine)|machine|wr|hamstrings|',
  'Standing Leg Curl (Machine)|machine|wr|hamstrings|',
  'Nordic Hamstring Curl|bodyweight|br|hamstrings|',
  'Romanian Deadlift (Barbell)|barbell|wr|hamstrings|glutes,back',
  'Romanian Deadlift (Dumbbell)|dumbbell|wr|hamstrings|glutes,back',
  'Single Leg Romanian Deadlift (Dumbbell)|dumbbell|wr|hamstrings|glutes,back',
  'Stiff Leg Deadlift (Barbell)|barbell|wr|hamstrings|glutes,back',
  'Good Morning (Barbell)|barbell|wr|hamstrings|glutes,back',
  'Deadlift (Barbell)|barbell|wr|hamstrings,glutes|back,quads,forearms',
  'Deadlift (Dumbbell)|dumbbell|wr|hamstrings,glutes|back,quads,forearms',
  'Sumo Deadlift (Barbell)|barbell|wr|hamstrings,glutes|back,quads,forearms',
  'Trap Bar Deadlift|barbell|wr|hamstrings,glutes|back,quads,forearms',
  'Deficit Deadlift (Barbell)|barbell|wr|hamstrings,glutes|back,quads,forearms',
  'Hip Thrust (Barbell)|barbell|wr|glutes|hamstrings',
  'Hip Thrust (Machine)|machine|wr|glutes|hamstrings',
  'Single Leg Hip Thrust|bodyweight|br|glutes|hamstrings',
  'Glute Bridge|bodyweight|br|glutes|hamstrings',
  'Glute Bridge (Barbell)|barbell|wr|glutes|hamstrings',
  'Glute Kickback (Machine)|machine|wr|glutes|hamstrings',
  'Cable Kickback|cable|wr|glutes|hamstrings',
  'Hip Abduction (Machine)|machine|wr|glutes|hamstrings',
  'Hip Adduction (Machine)|machine|wr|quads|',
  'Lunge (Barbell)|barbell|wr|quads|glutes,hamstrings',
  'Lunge (Dumbbell)|dumbbell|wr|quads|glutes,hamstrings',
  'Walking Lunge (Dumbbell)|dumbbell|wr|quads|glutes,hamstrings',
  'Reverse Lunge (Dumbbell)|dumbbell|wr|quads|glutes,hamstrings',
  'Bulgarian Split Squat (Dumbbell)|dumbbell|wr|quads|glutes,hamstrings',
  'Bulgarian Split Squat|bodyweight|br|quads|glutes,hamstrings',
  'Split Squat (Dumbbell)|dumbbell|wr|quads|glutes,hamstrings',
  'Step Up (Dumbbell)|dumbbell|wr|quads|glutes,hamstrings',
  'Step Up|bodyweight|br|quads|glutes,hamstrings',
  'Standing Calf Raise (Machine)|machine|wr|calves|',
  'Standing Calf Raise (Smith Machine)|machine|wr|calves|',
  'Standing Calf Raise (Dumbbell)|dumbbell|wr|calves|',
  'Seated Calf Raise (Machine)|machine|wr|calves|',
  'Calf Press (Machine)|machine|wr|calves|',
  'Calf Raise (Bodyweight)|bodyweight|br|calves|',
  'Single Leg Calf Raise|bodyweight|br|calves|',
  'Kettlebell Swing|kettlebell|wr|glutes,hamstrings|back',
  // ---- shoulders ----
  'Overhead Press (Barbell)|barbell|wr|shoulders|triceps',
  'Seated Overhead Press (Barbell)|barbell|wr|shoulders|triceps',
  'Push Press|barbell|wr|shoulders|triceps',
  'Shoulder Press (Dumbbell)|dumbbell|wr|shoulders|triceps',
  'Seated Shoulder Press (Dumbbell)|dumbbell|wr|shoulders|triceps',
  'Shoulder Press (Machine)|machine|wr|shoulders|triceps',
  'Shoulder Press (Smith Machine)|machine|wr|shoulders|triceps',
  'Arnold Press (Dumbbell)|dumbbell|wr|shoulders|triceps',
  'Landmine Press|barbell|wr|shoulders|triceps',
  'Handstand Push Up|bodyweight|br|shoulders|triceps',
  'Lateral Raise (Dumbbell)|dumbbell|wr|shoulders|',
  'Lateral Raise (Cable)|cable|wr|shoulders|',
  'Lateral Raise (Machine)|machine|wr|shoulders|',
  'Front Raise (Dumbbell)|dumbbell|wr|shoulders|',
  'Front Raise (Cable)|cable|wr|shoulders|',
  'Front Raise (Barbell)|barbell|wr|shoulders|',
  'Rear Delt Reverse Fly (Dumbbell)|dumbbell|wr|shoulders|back',
  'Rear Delt Reverse Fly (Cable)|cable|wr|shoulders|back',
  'Rear Delt Reverse Fly (Machine)|machine|wr|shoulders|back',
  'Upright Row (Barbell)|barbell|wr|shoulders|back',
  'Upright Row (Dumbbell)|dumbbell|wr|shoulders|back',
  'Upright Row (Cable)|cable|wr|shoulders|back',
  // ---- arms ----
  'Bicep Curl (Barbell)|barbell|wr|biceps|forearms',
  'EZ Bar Biceps Curl|barbell|wr|biceps|forearms',
  'Bicep Curl (Dumbbell)|dumbbell|wr|biceps|forearms',
  'Bicep Curl (Cable)|cable|wr|biceps|forearms',
  'Bicep Curl (Machine)|machine|wr|biceps|forearms',
  'Hammer Curl (Dumbbell)|dumbbell|wr|biceps|forearms',
  'Hammer Curl (Cable)|cable|wr|biceps|forearms',
  'Incline Curl (Dumbbell)|dumbbell|wr|biceps|forearms',
  'Preacher Curl (Barbell)|barbell|wr|biceps|forearms',
  'Preacher Curl (Dumbbell)|dumbbell|wr|biceps|forearms',
  'Preacher Curl (Machine)|machine|wr|biceps|forearms',
  'Concentration Curl (Dumbbell)|dumbbell|wr|biceps|forearms',
  'Spider Curl (Dumbbell)|dumbbell|wr|biceps|forearms',
  'Reverse Curl (Barbell)|barbell|wr|biceps|forearms',
  'Zottman Curl (Dumbbell)|dumbbell|wr|biceps|forearms',
  'Triceps Pushdown (Cable)|cable|wr|triceps|chest,shoulders',
  'Triceps Rope Pushdown|cable|wr|triceps|chest,shoulders',
  'Triceps Extension (Cable)|cable|wr|triceps|chest,shoulders',
  'Overhead Triceps Extension (Cable)|cable|wr|triceps|chest,shoulders',
  'Overhead Triceps Extension (Dumbbell)|dumbbell|wr|triceps|chest,shoulders',
  'Triceps Extension (Dumbbell)|dumbbell|wr|triceps|chest,shoulders',
  'Triceps Extension (Machine)|machine|wr|triceps|chest,shoulders',
  'Skullcrusher (Barbell)|barbell|wr|triceps|chest,shoulders',
  'Skullcrusher (Dumbbell)|dumbbell|wr|triceps|chest,shoulders',
  'Triceps Dip|bodyweight|br|triceps|chest,shoulders',
  'Triceps Dip (Weighted)|bodyweight|wb|triceps|chest,shoulders',
  'Triceps Dip (Assisted)|machine|ab|triceps|chest,shoulders',
  'Bench Dip|bodyweight|br|triceps|chest,shoulders',
  'Triceps Kickback (Dumbbell)|dumbbell|wr|triceps|chest,shoulders',
  'Wrist Curl (Barbell)|barbell|wr|forearms|',
  'Wrist Curl (Dumbbell)|dumbbell|wr|forearms|',
  'Reverse Wrist Curl (Barbell)|barbell|wr|forearms|',
  "Farmer's Walk|other|wd|forearms|core",
  'Dead Hang|bodyweight|du|forearms|back',
  // ---- core ----
  'Plank|bodyweight|du|core|',
  'Side Plank|bodyweight|du|core|',
  'Crunch|bodyweight|br|core|',
  'Crunch (Machine)|machine|wr|core|',
  'Cable Crunch|cable|wr|core|',
  'Sit Up|bodyweight|br|core|',
  'Decline Sit Up|bodyweight|br|core|',
  'Hanging Leg Raise|bodyweight|br|core|',
  'Hanging Knee Raise|bodyweight|br|core|',
  'Leg Raise|bodyweight|br|core|',
  'Toes to Bar|bodyweight|br|core|',
  'Captains Chair Leg Raise|bodyweight|br|core|',
  'Russian Twist|bodyweight|br|core|',
  'Russian Twist (Weighted)|other|wr|core|',
  'Ab Wheel|other|br|core|',
  'Dead Bug|bodyweight|br|core|',
  'Mountain Climber|bodyweight|du|core|',
  'Hollow Hold|bodyweight|du|core|',
  'V Up|bodyweight|br|core|',
  'Bicycle Crunch|bodyweight|br|core|',
  'Pallof Press|cable|wr|core|',
  'Wood Chop (Cable)|cable|wr|core|',
  'Torso Rotation (Machine)|machine|wr|core|',
  // ---- full body, kettlebell, olympic ----
  'Clean and Jerk (Barbell)|barbell|wr|quads,glutes|back,shoulders',
  'Power Clean (Barbell)|barbell|wr|quads,glutes|back,shoulders',
  'Hang Clean (Barbell)|barbell|wr|quads,glutes|back,shoulders',
  'Snatch (Barbell)|barbell|wr|quads,glutes|back,shoulders',
  'Thruster (Barbell)|barbell|wr|quads,shoulders|glutes',
  'Thruster (Kettlebell)|kettlebell|wr|quads,shoulders|glutes',
  'Turkish Get Up (Kettlebell)|kettlebell|wr|shoulders,core|glutes',
  'Box Jump|bodyweight|br|quads,glutes|back,shoulders',
  'Burpee|bodyweight|br|quads,glutes|back,shoulders',
  'Jump Squat|bodyweight|br|quads|glutes,hamstrings',
  'Sled Push|other|wd|quads|glutes,hamstrings',
  // ---- cardio (no strength muscles) ----
  'Running (Outdoor)|other|dd||',
  'Running (Treadmill)|machine|dd||',
  'Walking|other|dd||',
  'Cycling (Outdoor)|other|dd||',
  'Cycling (Stationary)|machine|dd||',
  'Rowing Machine|machine|dd||',
  'Elliptical Trainer|machine|dd||',
  'Stair Machine|machine|dd||',
  'Swimming|other|dd||',
  'Jump Rope|other|du||',
  'Stretching|bodyweight|du||',
];

List<String> _split(String s) =>
    s.isEmpty ? <String>[] : [for (final x in s.split(',')) x.trim()];

List<LibExercise>? _builtIn;

/// All built-in exercises (read once from the table above).
List<LibExercise> builtinLibrary() {
  final cached = _builtIn;
  if (cached != null) return cached;
  final out = <LibExercise>[];
  for (final line in _catalog) {
    final p = line.split('|');
    if (p.length < 5) continue;
    out.add(LibExercise(
      p[0].trim(),
      p[1].trim(),
      p[2].trim(),
      MuscleProfile(_split(p[3]), _split(p[4])),
    ));
  }
  _builtIn = out;
  return out;
}

Map<String, LibExercise>? _builtInByName;
Map<String, LibExercise> _customByName = {};
bool _customLoaded = false;

String _key(String name) => name.trim().toLowerCase();

/// Reads your own exercises again (call it when you open a screen that
/// uses them; they can change through sync).
void reloadCustomExercises() {
  _customByName = {for (final c in loadCustomExercises()) _key(c.name): c};
  _customLoaded = true;
}

/// Your own exercises, newest first.
List<LibExercise> loadCustomExercises() {
  final out = <LibExercise>[];
  for (final i in AppDb.instance.loadItems('custom_exercise')) {
    final d = i.data;
    final name = (d['name'] ?? '').toString().trim();
    if (name.isEmpty) continue;
    final kind = (d['kind'] ?? 'wr').toString();
    final equipment = (d['equipment'] ?? 'other').toString();
    out.add(LibExercise(
      name,
      exerciseEquipment.containsKey(equipment) ? equipment : 'other',
      exerciseKinds.containsKey(kind) ? kind : 'wr',
      MuscleProfile(
        [for (final x in ((d['p'] as List?) ?? const [])) x.toString()],
        [for (final x in ((d['s'] as List?) ?? const [])) x.toString()],
      ),
      custom: true,
      id: i.id,
    ));
  }
  return out;
}

/// Saves a new or changed exercise of your own. [id] is empty for a new one.
void saveCustomExercise(LibExercise e) {
  AppDb.instance.saveItem('custom_exercise', e.id.isEmpty ? newId() : e.id, {
    'name': e.name.trim(),
    'equipment': e.equipment,
    'kind': e.kind,
    'p': e.muscles.primary,
    's': e.muscles.secondary,
  });
  reloadCustomExercises();
}

void deleteCustomExercise(String id) {
  AppDb.instance.deleteItem(id);
  reloadCustomExercises();
}

/// The library entry of an exercise name (yours first), or null.
LibExercise? findExercise(String name) {
  if (!_customLoaded) reloadCustomExercises();
  final k = _key(name);
  final mine = _customByName[k];
  if (mine != null) return mine;
  final map = _builtInByName ??= {for (final e in builtinLibrary()) _key(e.name): e};
  return map[k];
}

/// Built-in and own exercises together, own first.
List<LibExercise> allExercises() {
  final mine = loadCustomExercises();
  final taken = {for (final c in mine) _key(c.name)};
  return [
    ...mine,
    for (final b in builtinLibrary())
      if (!taken.contains(_key(b.name))) b,
  ];
}

String muscleNames(List<String> keys) =>
    keys.map((k) => muscleLabels[k] ?? k).join(', ');
