import 'db.dart';
import 'nutrients.dart';
import 'workout_types.dart';

/// How days are combined when a chart shows weeks or months.
enum AggMode { avg, sum, max }

/// Something that can be charted per day.
class MetricDef {
  final String id; // unique, e.g. 'nut:calories'
  final String name;
  final String unit;
  final String source; // 'nut' | 'act' | 'weight' | 'workout'
  final String key; // nutrient key, daily_metrics key, ...
  final double scale; // stored value * scale = shown value
  final bool line; // default style: line (levels) instead of bars (amounts)
  final bool additive; // a total over the period makes sense
  final bool zeroFill; // days without a value count as 0 (e.g. workout time)
  final AggMode defaultAgg; // default for weeks and months
  const MetricDef(
    this.id,
    this.name,
    this.unit,
    this.source,
    this.key, {
    this.scale = 1,
    this.line = false,
    this.additive = false,
    this.zeroFill = false,
    this.defaultAgg = AggMode.avg,
  });
}

class DailyData {
  final Map<String, double> values; // YYYY-MM-DD -> value
  final Set<String> partial; // days with incomplete nutrition data
  DailyData(this.values, this.partial);
}

final List<MetricDef> nutritionMetrics = [
  for (final n in nutrients)
    MetricDef('nut:${n.key}', n.name, n.unit, 'nut', n.key, additive: true),
];

const weightMetrics = [
  MetricDef('weight', 'Weight', 'kg', 'weight', 'kg', line: true),
  MetricDef('act:body_fat', 'Body fat', '%', 'act', 'body_fat', line: true),
];

const activityMetrics = [
  MetricDef('act:steps', 'Steps', 'steps', 'act', 'steps', additive: true),
  MetricDef('act:active_kcal', 'Active calories', 'kcal', 'act', 'active_kcal',
      additive: true),
  MetricDef('act:distance_km', 'Distance', 'km', 'act', 'distance_km',
      additive: true),
  MetricDef('act:floors', 'Floors climbed', 'floors', 'act', 'floors',
      additive: true),
  MetricDef('act:resting_hr', 'Resting heart rate', 'bpm', 'act', 'resting_hr',
      line: true),
  MetricDef('act:sleep_total', 'Sleep', 'h', 'act', 'sleep_total',
      scale: 1 / 60),
  MetricDef('act:sleep_deep', 'Deep sleep', 'h', 'act', 'sleep_deep',
      scale: 1 / 60),
  MetricDef('act:sleep_light', 'Light sleep', 'h', 'act', 'sleep_light',
      scale: 1 / 60),
  MetricDef('act:sleep_rem', 'REM sleep', 'h', 'act', 'sleep_rem',
      scale: 1 / 60),
  MetricDef('act:sleep_score', 'Sleep score', '', 'act', 'sleep_score',
      line: true),
  MetricDef('act:vo2max', 'VO2 max', 'ml/kg/min', 'act', 'vo2max', line: true),
  MetricDef('act:sleep_awake', 'Awake during sleep', 'h', 'act', 'sleep_awake',
      scale: 1 / 60),
];

/// Charts for the Training tab: what makes sense depends on the activity.
List<MetricDef> trainingMetrics(Cat? cat) {
  final c = cat == null ? 'all' : cat.name;
  MetricDef d(String what, String name, String unit,
          {bool line = false, bool additive = false}) =>
      MetricDef('tr:$c:$what', name, unit, 'workout', 'cat:$c:$what',
          line: line,
          additive: additive,
          zeroFill: additive,
          defaultAgg: additive ? AggMode.sum : AggMode.avg);
  final time = d('min', 'Training time', 'min', additive: true);
  final count = d('count', 'Number of workouts', '', additive: true);
  final kcal = d('kcal', 'Calories', 'kcal', additive: true);
  final elev = d('elev', 'Elevation gain', 'm', additive: true);
  final hr = d('hr', 'Average heart rate', 'bpm', line: true);
  switch (cat) {
    case Cat.run:
    case Cat.walk:
    case Cat.hike:
      return [
        time,
        d('km', 'Distance', 'km', additive: true),
        d('pace', 'Pace', 'min/km', line: true),
        count,
        elev,
        d('rpe', 'RPE (effort)', '', line: true),
        hr,
        kcal,
      ];
    case Cat.cycle:
      return [
        time,
        d('km', 'Distance', 'km', additive: true),
        d('speed', 'Average speed', 'km/h', line: true),
        count,
        elev,
        hr,
        kcal,
      ];
    case Cat.swim:
      return [
        time,
        d('m', 'Distance', 'm', additive: true),
        d('pace100', 'Pace', 'min/100 m', line: true),
        count,
        hr,
        kcal,
      ];
    case Cat.strength:
      return [
        time,
        count,
        d('sets', 'Sets', '', additive: true),
        d('volume', 'Volume (weight x reps)', 'kg', additive: true),
        d('reps', 'Repetitions', '', additive: true),
        d('rpe', 'RPE (effort)', '', line: true),
        hr,
        kcal,
      ];
    case null:
      return [
        time,
        count,
        d('km', 'Distance', 'km', additive: true),
        elev,
        kcal,
        hr,
      ];
    default:
      return [time, count, kcal, hr];
  }
}

/// Progress of one lift (name as written in the workouts).
List<MetricDef> exerciseMetrics(String name) => [
      MetricDef('ex:1rm', 'Estimated 1RM', 'kg', 'exercise', '1rm|$name',
          line: true, defaultAgg: AggMode.max),
      MetricDef('ex:maxkg', 'Heaviest set', 'kg', 'exercise', 'maxkg|$name',
          line: true, defaultAgg: AggMode.max),
      MetricDef('ex:volume', 'Volume per session', 'kg', 'exercise',
          'volume|$name',
          additive: true, zeroFill: true, defaultAgg: AggMode.sum),
      MetricDef('ex:rpe', 'Average RPE per session', '', 'exercise',
          'rpe|$name',
          line: true),
      MetricDef('ex:reps', 'Repetitions per session', '', 'exercise',
          'reps|$name',
          additive: true, zeroFill: true, defaultAgg: AggMode.sum),
    ];

/// Daily values of one metric between two dates (inclusive).
DailyData loadDailyData(MetricDef m, DateTime from, DateTime to) {
  final db = AppDb.instance;
  final f = dayKey(from);
  final t = dayKey(to);
  final values = <String, double>{};
  final partial = <String>{};
  switch (m.source) {
    case 'nut':
      db.dailyTotals(f, t).forEach((day, d) {
        final v = d.totals[m.key];
        if (v != null) {
          values[day] = v;
          if (d.incomplete.contains(m.key)) partial.add(day);
        }
      });
      break;
    case 'act':
      db.loadDailyMetrics(f, t).forEach((day, mm) {
        final v = mm[m.key];
        // more than 14 h of sleep in a day is wrong data (duplicate records)
        if (v != null && !(v > 840 && m.key.startsWith('sleep_'))) {
          values[day] = v * m.scale;
        }
      });
      break;
    case 'weight':
      for (final w in db.loadWeights(f)) {
        if (w.day.compareTo(t) <= 0) values[w.day] = w.kg;
      }
      break;
    case 'workout':
      values.addAll(_workoutValues(m.key, f, t));
      break;
    case 'exercise':
      values.addAll(_exerciseValues(m.key, f, t));
      break;
  }
  return DailyData(values, partial);
}

/// `minutes` or `cat:<category|all>:<what>` -> value per day.
Map<String, double> _workoutValues(String key, String f, String t) {
  final ws = AppDb.instance
      .loadAllWorkouts()
      .where((w) => w.day.compareTo(f) >= 0 && w.day.compareTo(t) <= 0);
  Cat? cat;
  String what;
  if (key == 'minutes') {
    what = 'min';
  } else {
    final parts = key.split(':');
    cat = parts[1] == 'all' ? null : Cat.values.byName(parts[1]);
    what = parts[2];
  }
  final min = <String, double>{};
  final km = <String, double>{};
  final cnt = <String, double>{};
  final elev = <String, double>{};
  final kcal = <String, double>{};
  final sets = <String, double>{};
  final vol = <String, double>{};
  final reps = <String, double>{};
  final hrW = <String, double>{};
  final hrM = <String, double>{};
  final rpeW = <String, double>{};
  final rpeM = <String, double>{};
  void add(Map<String, double> m, String d, double v) => m[d] = (m[d] ?? 0) + v;
  for (final w in ws) {
    if (cat != null && categoryOf(w.type) != cat) continue;
    add(min, w.day, w.minutes);
    add(cnt, w.day, 1);
    if (w.distanceM != null) add(km, w.day, w.distanceM! / 1000);
    add(elev, w.day, w.metrics['ascent_m'] ?? 0);
    add(kcal, w.day, w.activeKcal ?? 0);
    add(sets, w.day, w.metrics['sets'] ?? 0);
    add(vol, w.day, w.metrics['volume_kg'] ?? 0);
    add(reps, w.day, w.metrics['reps'] ?? 0);
    final hr = w.metrics['avg_hr'];
    if (hr != null) {
      add(hrW, w.day, hr * w.minutes);
      add(hrM, w.day, w.minutes);
    }
    final rpe = w.metrics['rpe'];
    if (rpe != null && rpe > 0) {
      add(rpeW, w.day, rpe);
      add(rpeM, w.day, 1);
    }
  }
  final out = <String, double>{};
  void positive(Map<String, double> m, [double factor = 1]) {
    m.forEach((d, v) {
      if (v > 0) out[d] = v * factor;
    });
  }

  switch (what) {
    case 'min':
      out.addAll(min);
      break;
    case 'count':
      out.addAll(cnt);
      break;
    case 'km':
      positive(km);
      break;
    case 'm':
      positive(km, 1000);
      break;
    case 'pace': // minutes per km (decimal)
      km.forEach((d, v) {
        if (v > 0) out[d] = (min[d] ?? 0) / v;
      });
      break;
    case 'pace100': // minutes per 100 m (decimal)
      km.forEach((d, v) {
        if (v > 0) out[d] = (min[d] ?? 0) / (v * 10);
      });
      break;
    case 'speed':
      km.forEach((d, v) {
        final mm = min[d] ?? 0;
        if (v > 0 && mm > 0) out[d] = v / (mm / 60);
      });
      break;
    case 'elev':
      positive(elev);
      break;
    case 'kcal':
      positive(kcal);
      break;
    case 'sets':
      positive(sets);
      break;
    case 'volume':
      positive(vol);
      break;
    case 'reps':
      positive(reps);
      break;
    case 'rpe':
      rpeW.forEach((d, v) {
        final n = rpeM[d] ?? 0;
        if (n > 0) out[d] = v / n;
      });
      break;
    case 'hr':
      hrW.forEach((d, v) {
        final mm = hrM[d] ?? 0;
        if (mm > 0) out[d] = v / mm;
      });
      break;
  }
  return out;
}

/// `<kind>|<exercise name>` -> value per day (kind: 1rm, maxkg, volume, reps).
Map<String, double> _exerciseValues(String key, String f, String t) {
  final i = key.indexOf('|');
  final kind = key.substring(0, i);
  final name = key.substring(i + 1).trim().toLowerCase();
  final out = <String, double>{};
  final rpeN = <String, double>{};
  for (final w in AppDb.instance.loadAllWorkouts(withEx: true)) {
    if (w.day.compareTo(f) < 0 || w.day.compareTo(t) > 0) continue;
    for (final ex in w.exercises) {
      if ((ex['name'] ?? '').toString().trim().toLowerCase() != name) continue;
      for (final s in ((ex['sets'] as List?) ?? const [])) {
        final m = (s as Map).cast<String, dynamic>();
        if ((m['type'] ?? 'normal') == 'warmup') continue;
        final kg = (m['kg'] as num?)?.toDouble();
        final reps = (m['reps'] as num?)?.toDouble();
        switch (kind) {
          case '1rm':
            if (kg != null && kg > 0 && reps != null && reps >= 1 && reps <= 12) {
              final e = reps == 1 ? kg : kg * (1 + reps / 30); // Epley
              if (e > (out[w.day] ?? 0)) out[w.day] = e;
            }
            break;
          case 'maxkg':
            if (kg != null && kg > (out[w.day] ?? 0)) out[w.day] = kg;
            break;
          case 'volume':
            if (kg != null && reps != null) {
              out[w.day] = (out[w.day] ?? 0) + kg * reps;
            }
            break;
          case 'reps':
            if (reps != null) out[w.day] = (out[w.day] ?? 0) + reps;
            break;
          case 'rpe':
            final r = (m['rpe'] as num?)?.toDouble();
            if (r != null && r > 0) {
              out[w.day] = (out[w.day] ?? 0) + r;
              rpeN[w.day] = (rpeN[w.day] ?? 0) + 1;
            }
            break;
        }
      }
    }
  }
  if (kind == 'rpe') {
    rpeN.forEach((d, n) => out[d] = out[d]! / n);
  }
  return out;
}
