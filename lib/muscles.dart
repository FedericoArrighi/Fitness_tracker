import 'dart:convert';
import 'db.dart';

/// The muscle groups used for the weekly volume.
const muscleGroups = [
  'chest',
  'back',
  'shoulders',
  'biceps',
  'triceps',
  'forearms',
  'quads',
  'hamstrings',
  'glutes',
  'calves',
  'core',
];

const muscleLabels = {
  'chest': 'Chest',
  'back': 'Back',
  'shoulders': 'Shoulders',
  'biceps': 'Biceps',
  'triceps': 'Triceps',
  'forearms': 'Forearms',
  'quads': 'Quadriceps',
  'hamstrings': 'Hamstrings',
  'glutes': 'Glutes',
  'calves': 'Calves',
  'core': 'Abs and core',
};

/// The muscles an exercise trains. Every hard set counts 1 for each primary
/// muscle and 0.5 for each secondary muscle.
class MuscleProfile {
  final List<String> primary;
  final List<String> secondary;
  const MuscleProfile(this.primary, [this.secondary = const []]);

  bool get isEmpty => primary.isEmpty;

  Map<String, dynamic> toJson() => {'p': primary, 's': secondary};

  static MuscleProfile fromJson(Map m) => MuscleProfile(
        [for (final x in ((m['p'] as List?) ?? const [])) x.toString()],
        [for (final x in ((m['s'] as List?) ?? const [])) x.toString()],
      );
}

class _Rule {
  final List<String> words; // any of these in the name
  final List<String> not; // but none of these
  final MuscleProfile profile;
  const _Rule(this.words, this.profile, [this.not = const []]);
}

// The first rule that matches wins, so the order matters.
const _rules = <_Rule>[
  _Rule(['leg curl', 'hamstring curl', 'nordic'], MuscleProfile(['hamstrings'])),
  _Rule(['leg extension'], MuscleProfile(['quads'])),
  _Rule(['leg raise', 'knee raise'], MuscleProfile(['core'])),
  _Rule(['hip thrust', 'glute', 'hip abduction'],
      MuscleProfile(['glutes'], ['hamstrings'])),
  _Rule(['calf', 'calves'], MuscleProfile(['calves'])),
  _Rule(['romanian', 'stiff leg', 'stiff-leg', 'good morning'],
      MuscleProfile(['hamstrings'], ['glutes', 'back'])),
  _Rule(['deadlift'],
      MuscleProfile(['hamstrings', 'glutes'], ['back', 'quads', 'forearms'])),
  _Rule(['back extension', 'hyperextension', 'reverse hyper'],
      MuscleProfile(['back'], ['glutes', 'hamstrings'])),
  _Rule(['swing'], MuscleProfile(['glutes', 'hamstrings'], ['back'])),
  _Rule(['lunge', 'split squat', 'step up', 'step-up', 'bulgarian'],
      MuscleProfile(['quads'], ['glutes', 'hamstrings'])),
  _Rule(['squat', 'leg press', 'hack'],
      MuscleProfile(['quads'], ['glutes', 'hamstrings'])),
  _Rule(['thruster'], MuscleProfile(['quads', 'shoulders'], ['glutes'])),
  _Rule(['clean', 'snatch', 'box jump', 'burpee'],
      MuscleProfile(['quads', 'glutes'], ['back', 'shoulders'])),
  _Rule(['wrist curl', 'forearm', 'farmer', 'dead hang', 'gripper', 'grip strength'],
      MuscleProfile(['forearms'])),
  _Rule([
    'triceps',
    'tricep',
    'skullcrusher',
    'skull crusher',
    'pushdown',
    'push down',
    'close grip bench',
    'close-grip bench',
    'french press',
    'jm press',
  ], MuscleProfile(['triceps'], ['chest', 'shoulders'])),
  _Rule(['curl'], MuscleProfile(['biceps'], ['forearms'])),
  _Rule(['rear delt', 'reverse fly', 'reverse pec', 'face pull', 'rear fly'],
      MuscleProfile(['shoulders'], ['back'])),
  _Rule(['overhead press', 'shoulder press', 'military press', 'arnold', 'push press', 'ohp', 'landmine press'],
      MuscleProfile(['shoulders'], ['triceps'])),
  _Rule(['lateral raise', 'side raise', 'front raise', 'y raise'],
      MuscleProfile(['shoulders'])),
  _Rule(['upright row'], MuscleProfile(['shoulders'], ['back'])),
  _Rule(['bench press', 'chest press', 'push up', 'push-up', 'pushup', 'incline press', 'decline press', 'floor press'],
      MuscleProfile(['chest'], ['triceps', 'shoulders'])),
  _Rule(['fly', 'flye', 'pec deck', 'crossover', 'cable cross'],
      MuscleProfile(['chest'])),
  _Rule([' dip'], MuscleProfile(['chest'], ['triceps', 'shoulders'])),
  _Rule(['shrug'], MuscleProfile(['back'], ['forearms'])),
  _Rule(['pull up', 'pull-up', 'pullup', 'chin up', 'chin-up', 'chinup', 'pulldown', 'pull down', 'lat '],
      MuscleProfile(['back'], ['biceps'])),
  _Rule([' row'], MuscleProfile(['back'], ['biceps']), ['rowing']),
  _Rule(['straight arm', 'pullover'], MuscleProfile(['back'])),
  _Rule(['plank', 'crunch', 'sit up', 'sit-up', 'situp', 'russian twist', 'ab wheel', 'wood chop', 'woodchop', 'core', 'hanging', 'toes to bar', 'v-up', 'dead bug', 'pallof'],
      MuscleProfile(['core'])),
];

/// Guess from the name of the exercise (empty profile = not recognised).
MuscleProfile detectMuscles(String name) {
  final n = ' ${name.toLowerCase()} ';
  for (final r in _rules) {
    if (r.words.any(n.contains) && !r.not.any(n.contains)) return r.profile;
  }
  return const MuscleProfile([]);
}

const _settingKey = 'muscle_map';

/// What you changed by hand, by lower-case exercise name.
Map<String, MuscleProfile> loadMuscleOverrides() {
  try {
    final m = jsonDecode(AppDb.instance.getSetting(_settingKey) ?? '{}') as Map;
    return {
      for (final e in m.entries)
        e.key as String: MuscleProfile.fromJson(e.value as Map)
    };
  } catch (_) {
    return {};
  }
}

void saveMuscleOverrides(Map<String, MuscleProfile> o) {
  AppDb.instance.setSetting(
      _settingKey, jsonEncode({for (final e in o.entries) e.key: e.value.toJson()}));
}

MuscleProfile muscleProfileOf(String name, Map<String, MuscleProfile> overrides) =>
    overrides[name.trim().toLowerCase()] ?? detectMuscles(name);

/// Hard sets per muscle between two days (YYYY-MM-DD, both included), and
/// which exercises added to each muscle.
class MuscleResult {
  final Map<String, double> sets = {for (final m in muscleGroups) m: 0.0};
  final Map<String, Map<String, double>> byExercise = {
    for (final m in muscleGroups) m: <String, double>{}
  };
}

MuscleResult muscleSets(List<Workout> workouts, String fromDay, String toDay,
    Map<String, MuscleProfile> overrides) {
  final r = MuscleResult();
  for (final w in workouts) {
    if (w.day.compareTo(fromDay) < 0 || w.day.compareTo(toDay) > 0) continue;
    for (final ex in w.exercises) {
      final name = (ex['name'] ?? '').toString();
      if (name.isEmpty) continue;
      var n = 0;
      for (final s in ((ex['sets'] as List?) ?? const [])) {
        final m = (s as Map).cast<String, dynamic>();
        if ((m['type'] ?? 'normal') == 'warmup') continue;
        if (((m['reps'] as num?)?.toDouble() ?? 0) <= 0) continue;
        n++;
      }
      if (n == 0) continue;
      final p = muscleProfileOf(name, overrides);
      void add(String muscle, double f) {
        if (!r.sets.containsKey(muscle)) return;
        r.sets[muscle] = r.sets[muscle]! + n * f;
        final by = r.byExercise[muscle]!;
        by[name] = (by[name] ?? 0) + n * f;
      }

      for (final m in p.primary) {
        add(m, 1);
      }
      for (final m in p.secondary) {
        add(m, 0.5);
      }
    }
  }
  return r;
}
