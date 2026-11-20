import 'db.dart';
import 'workout_format.dart';
import 'workout_types.dart';

// ------------------------------------------------------------------
// helpers shared by the comparison screens
// ------------------------------------------------------------------

/// Estimated one-rep max (Epley formula). Only for 1 to 12 repetitions.
double? e1rm(double kg, double reps) {
  if (kg <= 0 || reps < 1 || reps > 12) return null;
  return reps == 1 ? kg : kg * (1 + reps / 30);
}

class Line {
  final double slope, intercept;
  const Line(this.slope, this.intercept);
  double at(double x) => slope * x + intercept;
}

/// Least-squares line through the points; null for fewer than 3 points.
Line? fitLine(List<double> xs, List<double> ys) {
  final n = xs.length;
  if (n < 3) return null;
  final mx = xs.reduce((a, b) => a + b) / n;
  final my = ys.reduce((a, b) => a + b) / n;
  var sxx = 0.0, sxy = 0.0;
  for (var i = 0; i < n; i++) {
    sxx += (xs[i] - mx) * (xs[i] - mx);
    sxy += (xs[i] - mx) * (ys[i] - my);
  }
  if (sxx == 0) return null;
  final slope = sxy / sxx;
  return Line(slope, my - slope * mx);
}

double? pctChange(double? now, double? before) {
  if (now == null || before == null || before == 0) return null;
  return (now - before) / before * 100;
}

String signed(double v, String text) => '${v >= 0 ? '+' : '-'}$text';

String hms(double seconds) {
  final t = seconds.round().abs();
  final h = t ~/ 3600, m = (t % 3600) ~/ 60, s = t % 60;
  final mm = m.toString().padLeft(2, '0'), ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}

// ------------------------------------------------------------------
// runs (or any activity with a distance)
// ------------------------------------------------------------------

/// Workouts of one category whose distance is within [tol] (0.1 = 10 %)
/// of [km], oldest first.
List<Workout> similarByDistance(List<Workout> all, Cat cat, double km, double tol) {
  final out = [
    for (final w in all)
      if (categoryOf(w.type) == cat &&
          (w.distanceM ?? 0) > 0 &&
          ((w.distanceM! / 1000) - km).abs() <= km * tol)
        w
  ];
  out.sort((a, b) => a.startMs.compareTo(b.startMs));
  return out;
}

/// Meters per heartbeat: how far you get with each beat. Higher = fitter.
double? efficiency(Workout w) {
  final hr = w.metrics['avg_hr'];
  final d = w.distanceM;
  if (hr == null || hr <= 0 || d == null || d <= 0) return null;
  final secs = w.metrics['moving_s'] ?? w.minutes * 60;
  if (secs <= 0) return null;
  return d / (secs / 60) / hr;
}

const runMetricLabels = <String, String>{
  'pace': 'Pace',
  'speed': 'Speed',
  'time': 'Time',
  'hr': 'Average heart rate',
  'maxhr': 'Maximum heart rate',
  'eff': 'Efficiency (m per heartbeat)',
  'cadence': 'Cadence',
  'power': 'Power',
  'elev': 'Elevation gain',
};

double? runMetric(String key, Workout w) {
  switch (key) {
    case 'pace':
      return paceSecPerKm(w);
    case 'speed':
      return speedKmh(w);
    case 'time':
      return w.metrics['moving_s'] ?? w.minutes * 60;
    case 'hr':
      return w.metrics['avg_hr'];
    case 'maxhr':
      return w.metrics['max_hr'];
    case 'eff':
      return efficiency(w);
    case 'cadence':
      return w.metrics['cadence_avg'];
    case 'power':
      return w.metrics['power_avg'];
    case 'elev':
      return w.metrics['ascent_m'];
  }
  return null;
}

/// With a unit, for text.
String runMetricText(String key, double v) {
  switch (key) {
    case 'pace':
      return '${fmtPace(v)} /km';
    case 'speed':
      return '${v.toStringAsFixed(1)} km/h';
    case 'time':
      return hms(v);
    case 'hr':
    case 'maxhr':
      return '${v.round()} bpm';
    case 'eff':
      return '${v.toStringAsFixed(2)} m/beat';
    case 'cadence':
      return '${v.round()} spm';
    case 'power':
      return '${v.round()} W';
    case 'elev':
      return '${v.round()} m';
  }
  return v.toStringAsFixed(1);
}

/// Without a unit, for chart axes.
String runMetricAxis(String key, double v) {
  switch (key) {
    case 'pace':
      return fmtPace(v);
    case 'time':
      return hms(v);
    case 'eff':
      return v.toStringAsFixed(2);
    case 'speed':
      return v.toStringAsFixed(1);
  }
  return v.round().toString();
}

/// For these, lower is better (so the best value is the lowest).
bool lowerIsBetter(String key) => key == 'pace' || key == 'time';

/// For these, higher is better. Heart rate has no "better" direction here.
bool higherIsBetter(String key) => key == 'speed' || key == 'eff' || key == 'power';

double? averageOf(Iterable<Workout> ws, String key) {
  final v = [for (final w in ws) if (runMetric(key, w) != null) runMetric(key, w)!];
  if (v.isEmpty) return null;
  return v.reduce((a, b) => a + b) / v.length;
}

// ------------------------------------------------------------------
// lifts
// ------------------------------------------------------------------

class LiftSet {
  final double kg, reps;
  const LiftSet(this.kg, this.reps);
}

/// All working sets of one exercise in one workout.
class LiftSession {
  final Workout w;
  final String name;
  final List<LiftSet> sets;
  LiftSession(this.w, this.name, this.sets);

  double get volume => sets.fold(0.0, (s, e) => s + e.kg * e.reps);
  double get totalReps => sets.fold(0.0, (s, e) => s + e.reps);
  double get maxKg => sets.fold(0.0, (s, e) => e.kg > s ? e.kg : s);

  double? get best1rm {
    double? b;
    for (final s in sets) {
      final e = e1rm(s.kg, s.reps);
      if (e != null && (b == null || e > b)) b = e;
    }
    return b;
  }

  LiftSet? get bestSet {
    LiftSet? b;
    var be = -1.0;
    for (final s in sets) {
      final e = e1rm(s.kg, s.reps) ?? s.kg * 0.0 + s.reps * 0.001;
      if (e > be) {
        be = e;
        b = s;
      }
    }
    return b;
  }

  String setText(LiftSet s) => s.kg > 0
      ? '${_trim(s.kg)}×${s.reps.round()}'
      : '${s.reps.round()} reps';
}

String _trim(double v) {
  final r = (v * 10).round() / 10;
  return r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toString();
}

List<LiftSet> _workingSets(Map<String, dynamic> ex) {
  final out = <LiftSet>[];
  for (final s in ((ex['sets'] as List?) ?? const [])) {
    final m = (s as Map).cast<String, dynamic>();
    if ((m['type'] ?? 'normal') == 'warmup') continue;
    final reps = (m['reps'] as num?)?.toDouble() ?? 0;
    if (reps <= 0) continue;
    out.add(LiftSet((m['kg'] as num?)?.toDouble() ?? 0, reps));
  }
  return out;
}

/// Every exercise with its sessions, oldest first. Key = lower-case name.
Map<String, List<LiftSession>> allLiftSessions(List<Workout> all) {
  final ws = [...all]..sort((a, b) => a.startMs.compareTo(b.startMs));
  final out = <String, List<LiftSession>>{};
  for (final w in ws) {
    for (final ex in w.exercises) {
      final name = (ex['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final sets = _workingSets(ex);
      if (sets.isEmpty) continue;
      out.putIfAbsent(name.toLowerCase(), () => []).add(LiftSession(w, name, sets));
    }
  }
  return out;
}

List<LiftSession> liftSessionsFor(List<Workout> all, String name) =>
    allLiftSessions(all)[name.trim().toLowerCase()] ?? [];

class LiftSummary {
  final String name;
  final List<LiftSession> sessions;
  final double? best1rm;
  final double? start1rm; // average of the first three sessions
  final double? current1rm; // average of the last three sessions
  final double? rec90; // best estimated 1RM in the last 90 days
  final double? prev90; // ... and in the 90 days before that
  final double vol90, volPrev90;
  const LiftSummary(this.name, this.sessions, this.best1rm, this.start1rm,
      this.current1rm, this.rec90, this.prev90, this.vol90, this.volPrev90);
}

LiftSummary summarizeLift(List<LiftSession> ss, DateTime today) {
  final vals = [for (final s in ss) if (s.best1rm != null) s.best1rm!];
  double? avg(Iterable<double> v) {
    final l = v.toList();
    return l.isEmpty ? null : l.reduce((a, b) => a + b) / l.length;
  }

  final cut90 = dayKey(DateTime(today.year, today.month, today.day - 90));
  final cut180 = dayKey(DateTime(today.year, today.month, today.day - 180));
  double? rec, prev;
  var vol = 0.0, volPrev = 0.0;
  for (final s in ss) {
    final e = s.best1rm;
    if (s.w.day.compareTo(cut90) >= 0) {
      vol += s.volume;
      if (e != null && (rec == null || e > rec)) rec = e;
    } else if (s.w.day.compareTo(cut180) >= 0) {
      volPrev += s.volume;
      if (e != null && (prev == null || e > prev)) prev = e;
    }
  }
  return LiftSummary(
    ss.first.name,
    ss,
    vals.isEmpty ? null : vals.reduce((a, b) => a > b ? a : b),
    avg(vals.take(3)),
    avg(vals.skip(vals.length > 3 ? vals.length - 3 : 0)),
    rec,
    prev,
    vol,
    volPrev,
  );
}
