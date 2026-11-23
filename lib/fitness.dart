import 'db.dart';
import 'workout_types.dart';

/// Your maximum heart rate (set in the heart-rate card), 190 if not set.
double maxHrSetting() => double.tryParse(AppDb.instance.getSetting('max_hr') ?? '') ?? 190;

/// Zone 0 to 4 (zone 1 to 5) for a heart rate, or -1 below zone 1.
/// Zones are 50-60 %, 60-70 %, 70-80 %, 80-90 % and 90-100 % of the maximum.
int zoneIndex(double bpm, double maxHr) {
  if (maxHr <= 0) return -1;
  final f = bpm / maxHr;
  if (f >= 0.9) return 4;
  if (f >= 0.8) return 3;
  if (f >= 0.7) return 2;
  if (f >= 0.6) return 1;
  if (f >= 0.5) return 0;
  return -1;
}

class ZoneResult {
  final List<double> minutes; // five zones
  final bool fromLaps; // true: worked out from laps, so only approximate
  const ZoneResult(this.minutes, this.fromLaps);
  double get total => minutes.fold<double>(0, (a, b) => a + b);

  /// Share of the time in zones 1 and 2 (easy) and in zones 4 and 5 (hard).
  double get easyShare => total <= 0 ? 0 : (minutes[0] + minutes[1]) / total;
  double get hardShare => total <= 0 ? 0 : (minutes[3] + minutes[4]) / total;
}

/// Minutes in each zone. Uses the heart-rate series if the workout has one,
/// otherwise the laps (the average heart rate of each lap). The workout must
/// be a full one (loaded with loadWorkout).
ZoneResult zonesOf(Workout w, double maxHr) {
  final z = List<double>.filled(5, 0);
  final n = w.hr.length;
  if (n >= 2) {
    final gaps = [for (var i = 0; i < n - 1; i++) w.hr[i + 1][0] - w.hr[i][0]]..sort();
    final typical = gaps[gaps.length ~/ 2];
    for (var i = 0; i < n; i++) {
      final dt = i < n - 1
          ? (w.hr[i + 1][0] - w.hr[i][0]).clamp(0, typical * 3).toDouble()
          : typical;
      final k = zoneIndex(w.hr[i][1], maxHr);
      if (k >= 0) z[k] += dt;
    }
    return ZoneResult(z, false);
  }
  var any = false;
  for (final l in w.splits) {
    final hr = (l['hr'] as num?)?.toDouble();
    final s = (l['s'] as num?)?.toDouble();
    if (hr == null || s == null) continue;
    any = true;
    final k = zoneIndex(hr, maxHr);
    if (k >= 0) z[k] += s / 60;
  }
  return ZoneResult(z, any);
}

/// Time in zones over all endurance workouts with heart-rate data in a period.
ZoneResult zoneTotals(DateTime from, DateTime toExclusive, double maxHr) {
  final db = AppDb.instance;
  final a = dayKey(from), b = dayKey(toExclusive);
  final total = List<double>.filled(5, 0);
  var laps = false;
  for (final w in db.loadAllWorkouts()) {
    if (w.day.compareTo(a) < 0 || w.day.compareTo(b) >= 0) continue;
    if (categoryOf(w.type) == Cat.strength) continue;
    if (w.metrics['avg_hr'] == null) continue;
    final full = db.loadWorkout(w.id);
    if (full == null) continue;
    final r = zonesOf(full, maxHr);
    if (r.total <= 0) continue;
    if (r.fromLaps) laps = true;
    for (var i = 0; i < 5; i++) {
      total[i] += r.minutes[i];
    }
  }
  return ZoneResult(total, laps);
}

/// How hard a session was: minutes times effort. With an RPE it is the
/// "session RPE" method; without one the average heart rate stands in for it;
/// with neither, a moderate effort (5 of 10) is assumed.
double sessionLoad(Workout w, double maxHr) {
  final min = w.minutes;
  final rpe = w.metrics['rpe'];
  if (rpe != null && rpe > 0) return min * rpe;
  final hr = w.metrics['avg_hr'];
  if (hr != null && hr > 0 && maxHr > 0) {
    final f = (hr / maxHr).clamp(0.4, 1.0).toDouble();
    return min * f * 10;
  }
  return min * 5;
}

DateTime _monday(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));

class WeekLoad {
  final DateTime start;
  final double load, minutes;
  final int sessions;
  const WeekLoad(this.start, this.load, this.minutes, this.sessions);
}

/// Training load per week, oldest first; the last one is the current week.
List<WeekLoad> weeklyLoads(int weeks) {
  final maxHr = maxHrSetting();
  final cur = _monday(DateTime.now());
  final starts = [
    for (var i = weeks - 1; i >= 0; i--) DateTime(cur.year, cur.month, cur.day - 7 * i)
  ];
  final load = <String, double>{}, minutes = <String, double>{};
  final count = <String, int>{};
  for (final w in AppDb.instance.loadAllWorkouts()) {
    final d = DateTime.fromMillisecondsSinceEpoch(w.startMs);
    final k = dayKey(_monday(d));
    load[k] = (load[k] ?? 0) + sessionLoad(w, maxHr);
    minutes[k] = (minutes[k] ?? 0) + w.minutes;
    count[k] = (count[k] ?? 0) + 1;
  }
  return [
    for (final s in starts)
      WeekLoad(s, load[dayKey(s)] ?? 0, minutes[dayKey(s)] ?? 0, count[dayKey(s)] ?? 0)
  ];
}

class RecoveryFactor {
  final String text;
  final int points; // -2 bad ... +1 good
  const RecoveryFactor(this.text, this.points);
}

class RecoveryStatus {
  final String level; // good | okay | low | unknown
  final List<RecoveryFactor> factors;
  const RecoveryStatus(this.level, this.factors);
}

String _hm(double minutes) {
  final h = minutes ~/ 60;
  final m = (minutes % 60).round();
  return '$h h ${m.toString().padLeft(2, '0')} min';
}

double? _median(List<double> v) {
  if (v.isEmpty) return null;
  final s = [...v]..sort();
  return s.length.isOdd ? s[s.length ~/ 2] : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
}

/// A rough guide to how recovered you are, from three things: resting heart
/// rate against your usual, last night's sleep, and the load of the last
/// week against the weeks before. It is not medical advice.
RecoveryStatus computeRecovery(DateTime today) {
  final db = AppDb.instance;
  final maxHr = maxHrSetting();
  final from = DateTime(today.year, today.month, today.day - 45);
  final daily = db.loadDailyMetrics(dayKey(from), dayKey(today));
  double? value(String key, int daysAgo) =>
      daily[dayKey(DateTime(today.year, today.month, today.day - daysAgo))]?[key];

  final factors = <RecoveryFactor>[];

  // resting heart rate: the latest value of the last 2 days against the
  // median of the 28 days before
  double? rhr;
  for (var i = 0; i <= 2 && rhr == null; i++) {
    final v = value('resting_hr', i);
    if (v != null && v > 0) rhr = v;
  }
  final baseList = <double>[];
  for (var i = 3; i <= 31; i++) {
    final v = value('resting_hr', i);
    if (v != null && v > 0) baseList.add(v);
  }
  final base = baseList.length >= 7 ? _median(baseList) : null;
  if (rhr != null && base != null) {
    final d = rhr - base;
    final pts = d >= 6 ? -2 : (d >= 3 ? -1 : (d <= -3 ? 1 : 0));
    final dir = d.abs() < 1 ? 'in line with' : (d > 0 ? '${d.round()} above' : '${(-d).round()} below');
    factors.add(RecoveryFactor(
        'Resting heart rate ${rhr.round()} bpm, $dir your usual ${base.round()} bpm.', pts));
  }

  // sleep: last night against the 2 weeks before
  double? sleep;
  var sleepAgo = 0;
  for (var i = 0; i <= 1 && sleep == null; i++) {
    final v = value('sleep_total', i);
    if (v != null && v > 0) {
      sleep = v;
      sleepAgo = i;
    }
  }
  if (sleep != null) {
    final prev = <double>[];
    for (var i = sleepAgo + 1; i <= sleepAgo + 14; i++) {
      final v = value('sleep_total', i);
      if (v != null && v > 0) prev.add(v);
    }
    final avg = prev.length >= 5 ? prev.reduce((a, b) => a + b) / prev.length : null;
    var pts = sleep < 360 ? -2 : (sleep < 420 ? -1 : (sleep >= 450 ? 1 : 0));
    if (avg != null && sleep <= avg - 60) pts -= 1;
    final when = sleepAgo == 0 ? 'last night' : 'the night before';
    factors.add(RecoveryFactor(
        'Slept ${_hm(sleep)} $when'
        '${avg != null ? ' (your 2-week average is ${_hm(avg)})' : ''}.',
        pts.clamp(-2, 1).toInt()));
  }

  // load: the last 7 days against the 4 weeks before
  var acute = 0.0, chronic = 0.0;
  var chronicSessions = 0;
  final t0 = DateTime(today.year, today.month, today.day);
  for (final w in db.loadAllWorkouts()) {
    final d = DateTime.fromMillisecondsSinceEpoch(w.startMs);
    final ago = t0.difference(DateTime(d.year, d.month, d.day)).inDays;
    if (ago < 0) continue;
    final l = sessionLoad(w, maxHr);
    if (ago <= 6) {
      acute += l;
    } else if (ago <= 34) {
      chronic += l;
      chronicSessions++;
    }
  }
  final weekly = chronic / 4;
  if (chronicSessions >= 4 && weekly > 0) {
    final r = acute / weekly;
    final pts = r > 1.5 ? -2 : (r > 1.3 ? -1 : 0);
    final what = r > 1.3
        ? 'clearly more than you are used to'
        : (r < 0.7 ? 'less than you are used to' : 'about what you are used to');
    factors.add(RecoveryFactor(
        'Training load of the last 7 days is ${r.toStringAsFixed(1)} times your usual: $what.',
        pts));
  }

  if (factors.isEmpty) return const RecoveryStatus('unknown', []);
  final score = factors.fold<int>(0, (a, f) => a + f.points);
  final level = score >= 1 ? 'good' : (score >= -1 ? 'okay' : 'low');
  return RecoveryStatus(level, factors);
}
