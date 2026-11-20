import 'package:flutter/material.dart';

/// Activity categories. The raw type text of a workout (RUNNING, "Pool Swim",
/// STRENGTH_TRAINING, ...) is mapped to one of these.
enum Cat { run, walk, hike, cycle, swim, strength, climb, yoga, cardio, other }

Cat categoryOf(String type) {
  final t = type.toUpperCase();
  bool has(List<String> ks) => ks.any((k) => t.contains(k));
  if (has(['SWIM', 'SCHWIMM', 'NUOT', 'NATACI'])) return Cat.swim;
  if (t.contains('STAIR')) return Cat.cardio;
  if (has(['BOULDER', 'CLIMB', 'KLETTER', 'ARRAMPIC'])) return Cat.climb;
  if (has(['STRENGTH', 'WEIGHT', 'GYM', 'KRAFT', 'FORZA', 'MUSCULA', 'CROSSFIT'])) {
    return Cat.strength;
  }
  if (has(['RUN', 'JOG', 'LAUF', 'CORS', 'TREADMILL'])) return Cat.run;
  if (has(['HIK', 'WANDER', 'ESCURS', 'TREKK'])) return Cat.hike;
  if (has(['WALK', 'GEHEN', 'SPAZIER', 'CAMMIN'])) return Cat.walk;
  if (has(['BIK', 'CYCL', 'RADFAHR', 'CICLI', 'SPINNING', 'MOUNTAIN'])) {
    return Cat.cycle;
  }
  if (has(['YOGA', 'PILATES', 'STRETCH', 'MEDIT', 'TAI_CHI'])) return Cat.yoga;
  if (has(['CARDIO', 'ELLIPT', 'ROWING', 'HIIT', 'AEROBIC', 'DANC', 'INTERVAL', 'FITNESS'])) {
    return Cat.cardio;
  }
  return Cat.other;
}

String catLabel(Cat c) => switch (c) {
      Cat.run => 'Running',
      Cat.walk => 'Walking',
      Cat.hike => 'Hiking',
      Cat.cycle => 'Cycling',
      Cat.swim => 'Swimming',
      Cat.strength => 'Gym / strength',
      Cat.climb => 'Climbing / bouldering',
      Cat.yoga => 'Yoga / stretching',
      Cat.cardio => 'Other cardio',
      Cat.other => 'Other',
    };

IconData catIcon(Cat c) => switch (c) {
      Cat.run => Icons.directions_run,
      Cat.walk => Icons.directions_walk,
      Cat.hike => Icons.terrain,
      Cat.cycle => Icons.directions_bike,
      Cat.swim => Icons.pool,
      Cat.strength => Icons.fitness_center,
      Cat.climb => Icons.landscape,
      Cat.yoga => Icons.self_improvement,
      Cat.cardio => Icons.favorite_border,
      Cat.other => Icons.sports,
    };

/// The type text stored when you change the category of a workout.
const catTypes = <Cat, String>{
  Cat.run: 'RUNNING',
  Cat.walk: 'WALKING',
  Cat.hike: 'HIKING',
  Cat.cycle: 'BIKING',
  Cat.swim: 'SWIMMING',
  Cat.strength: 'STRENGTH_TRAINING',
  Cat.climb: 'CLIMBING',
  Cat.yoga: 'YOGA',
  Cat.cardio: 'CARDIO',
  Cat.other: 'OTHER',
};

String prettyType(String t) {
  final s = t.replaceAll('_', ' ').toLowerCase();
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

String fmtDur(double minutes) {
  final m = minutes.round();
  if (m >= 60) return '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
  return '$m min';
}

/// seconds -> "m:ss"
String fmtPace(double seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class MetricLabel {
  final String label;
  final String unit;
  final int decimals;
  const MetricLabel(this.label, this.unit, [this.decimals = 0]);
}

const metricLabels = <String, MetricLabel>{
  'avg_hr': MetricLabel('Average heart rate', 'bpm'),
  'max_hr': MetricLabel('Maximum heart rate', 'bpm'),
  'min_hr': MetricLabel('Minimum heart rate', 'bpm'),
  'te_aerobic': MetricLabel('Aerobic training effect', '', 1),
  'ascent_m': MetricLabel('Elevation gain', 'm'),
  'descent_m': MetricLabel('Elevation loss', 'm'),
  'elev_min': MetricLabel('Lowest elevation', 'm'),
  'elev_max': MetricLabel('Highest elevation', 'm'),
  'cadence_avg': MetricLabel('Average cadence', 'spm'),
  'cadence_max': MetricLabel('Maximum cadence', 'spm'),
  'stride_m': MetricLabel('Average stride length', 'm', 2),
  'vert_ratio': MetricLabel('Vertical ratio', '%', 1),
  'vert_osc': MetricLabel('Vertical oscillation', 'cm', 1),
  'gct_ms': MetricLabel('Ground contact time', 'ms'),
  'power_avg': MetricLabel('Average power', 'W'),
  'power_max': MetricLabel('Maximum power', 'W'),
  'tss': MetricLabel('Training stress score', '', 0),
  'grit': MetricLabel('Grit', '', 1),
  'flow': MetricLabel('Flow', '', 1),
  'swolf': MetricLabel('Average SWOLF', ''),
  'stroke_rate': MetricLabel('Average stroke rate', 'spm'),
  'laps': MetricLabel('Laps', ''),
  'best_lap_s': MetricLabel('Best lap time', 's', 1),
  'steps': MetricLabel('Steps', ''),
  'sets': MetricLabel('Sets', ''),
  'reps': MetricLabel('Repetitions', ''),
  'volume_kg': MetricLabel('Volume (weight x reps)', 'kg'),
  'moving_s': MetricLabel('Moving time', 's'),
  'elapsed_s': MetricLabel('Elapsed time', 's'),
};

/// Order in which the extra numbers are shown for each category.
List<String> metricOrder(Cat c) {
  switch (c) {
    case Cat.run:
    case Cat.walk:
    case Cat.hike:
      return ['avg_hr', 'max_hr', 'ascent_m', 'descent_m', 'cadence_avg', 'cadence_max', 'stride_m', 'power_avg', 'power_max', 'vert_osc', 'vert_ratio', 'gct_ms', 'te_aerobic', 'tss', 'grit', 'flow', 'steps', 'elev_min', 'elev_max'];
    case Cat.cycle:
      return ['avg_hr', 'max_hr', 'ascent_m', 'descent_m', 'power_avg', 'power_max', 'cadence_avg', 'cadence_max', 'te_aerobic', 'tss', 'grit', 'flow', 'elev_min', 'elev_max'];
    case Cat.swim:
      return ['avg_hr', 'max_hr', 'swolf', 'stroke_rate', 'laps', 'best_lap_s', 'te_aerobic'];
    case Cat.strength:
      return ['sets', 'reps', 'volume_kg', 'avg_hr', 'max_hr', 'te_aerobic'];
    case Cat.climb:
      return ['avg_hr', 'max_hr', 'ascent_m', 'descent_m', 'reps', 'te_aerobic', 'grit', 'flow'];
    default:
      return ['avg_hr', 'max_hr', 'te_aerobic', 'steps'];
  }
}
