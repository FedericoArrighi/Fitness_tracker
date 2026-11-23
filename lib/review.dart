import 'analysis.dart';
import 'db.dart';
import 'fitness.dart';
import 'muscles.dart';
import 'workout_types.dart';

/// Numbers for one period (a week or a month).
class PeriodStats {
  int sessions = 0;
  double minutes = 0, activeKcal = 0, load = 0;

  int runs = 0;
  double runKm = 0, runMin = 0, longestRunKm = 0;

  int gyms = 0;
  double sets = 0, volume = 0;
  double _rpeSum = 0;
  int _rpeN = 0;
  int other = 0;

  // nutrition: averages over the days with food logged
  int foodDays = 0, proteinDays = 0;
  double kcal = 0, protein = 0, carbs = 0, fat = 0;

  double? weightFirst, weightLast;
  double? sleepMin, sleepScore, steps, restingHr, vo2max;
  int sleepNights = 0, stepDays = 0;

  double? get avgRpe => _rpeN == 0 ? null : _rpeSum / _rpeN;
  double get paceSecPerKm => runKm > 0.5 ? runMin * 60 / runKm : 0;
}

double? _avg(List<double> v) => v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;

/// The numbers of the days from [from] up to (not including) [toExclusive].
PeriodStats computePeriod(DateTime from, DateTime toExclusive, double maxHr) {
  final db = AppDb.instance;
  final s = PeriodStats();
  final a = dayKey(from), b = dayKey(toExclusive);
  final lastDay = dayKey(DateTime(toExclusive.year, toExclusive.month, toExclusive.day - 1));

  for (final w in db.loadAllWorkouts()) {
    if (w.day.compareTo(a) < 0 || w.day.compareTo(b) >= 0) continue;
    s.sessions++;
    s.minutes += w.minutes;
    s.activeKcal += w.activeKcal ?? 0;
    s.load += sessionLoad(w, maxHr);
    final cat = categoryOf(w.type);
    if (cat == Cat.run) {
      final km = (w.distanceM ?? 0) / 1000;
      s.runs++;
      s.runKm += km;
      s.runMin += w.minutes;
      if (km > s.longestRunKm) s.longestRunKm = km;
    } else if (cat == Cat.strength) {
      s.gyms++;
      s.sets += w.metrics['sets'] ?? 0;
      s.volume += w.metrics['volume_kg'] ?? 0;
      final r = w.metrics['rpe'];
      if (r != null && r > 0) {
        s._rpeSum += r;
        s._rpeN++;
      }
    } else {
      s.other++;
    }
  }

  final targets = db.loadTargets();
  final pt = targets['protein'];
  for (final t in db.dailyTotals(a, lastDay).values) {
    final k = t.totals['calories'];
    if (k == null || k <= 0) continue;
    s.foodDays++;
    s.kcal += k;
    final p = t.totals['protein'] ?? 0;
    s.protein += p;
    s.carbs += t.totals['carbs'] ?? 0;
    s.fat += t.totals['fat'] ?? 0;
    if (pt != null && pt > 0 && p >= pt * 0.9) s.proteinDays++;
  }
  if (s.foodDays > 0) {
    s.kcal /= s.foodDays;
    s.protein /= s.foodDays;
    s.carbs /= s.foodDays;
    s.fat /= s.foodDays;
  }

  final ws = [
    for (final w in db.loadWeights(a))
      if (w.day.compareTo(b) < 0) w
  ];
  if (ws.isNotEmpty) {
    s.weightFirst = ws.first.kg;
    s.weightLast = ws.last.kg;
  }

  final sleep = <double>[], score = <double>[], steps = <double>[], rhr = <double>[];
  double? vo2;
  final daily = db.loadDailyMetrics(a, lastDay);
  final days = daily.keys.toList()..sort();
  for (final d in days) {
    final m = daily[d]!;
    if ((m['sleep_total'] ?? 0) > 0 && m['sleep_total']! <= 840) sleep.add(m['sleep_total']!);
    if ((m['sleep_score'] ?? 0) > 0) score.add(m['sleep_score']!);
    if ((m['steps'] ?? 0) > 0) steps.add(m['steps']!);
    if ((m['resting_hr'] ?? 0) > 0) rhr.add(m['resting_hr']!);
    if ((m['vo2max'] ?? 0) > 0) vo2 = m['vo2max'];
  }
  s.sleepMin = _avg(sleep);
  s.sleepNights = sleep.length;
  s.sleepScore = _avg(score);
  s.steps = _avg(steps);
  s.stepDays = steps.length;
  s.restingHr = _avg(rhr);
  s.vo2max = vo2;
  return s;
}

/// Lifts with a new best estimated 1RM in the period.
List<String> newRecords(DateTime from, DateTime toExclusive) {
  final a = dayKey(from), b = dayKey(toExclusive);
  final before = <String, double>{}, within = <String, double>{};
  final names = <String, String>{};
  for (final w in AppDb.instance.loadAllWorkouts(withEx: true)) {
    final prior = w.day.compareTo(a) < 0;
    final inside = !prior && w.day.compareTo(b) < 0;
    if (!prior && !inside) continue;
    for (final ex in w.exercises) {
      final name = (ex['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      names.putIfAbsent(key, () => name);
      for (final st in ((ex['sets'] as List?) ?? const [])) {
        final m = (st as Map).cast<String, dynamic>();
        if ((m['type'] ?? 'normal') == 'warmup') continue;
        final v = e1rm((m['kg'] as num?)?.toDouble() ?? 0, (m['reps'] as num?)?.toDouble() ?? 0);
        if (v == null) continue;
        final target = prior ? before : within;
        if (v > (target[key] ?? 0)) target[key] = v;
      }
    }
  }
  final out = <String>[];
  for (final e in within.entries) {
    final old = before[e.key];
    if (old != null && e.value > old + 0.05) {
      out.add('${names[e.key]}: estimated 1RM ${e.value.toStringAsFixed(1)} kg '
          '(was ${old.toStringAsFixed(1)} kg)');
    }
  }
  out.sort();
  return out;
}

class ReviewResult {
  final DateTime from, toExclusive;
  final bool partial; // the period is not over yet
  final PeriodStats cur, prev;
  final ZoneResult zones;
  final List<String> records, highlights, focus;
  const ReviewResult({
    required this.from,
    required this.toExclusive,
    required this.partial,
    required this.cur,
    required this.prev,
    required this.zones,
    required this.records,
    required this.highlights,
    required this.focus,
  });
}

String _pct(double cur, double prev) {
  if (prev <= 0) return '';
  final p = ((cur / prev - 1) * 100).round();
  return ' (${p >= 0 ? '+' : ''}$p % against the period before)';
}

String _hm(double minutes) => '${minutes ~/ 60} h ${(minutes % 60).round().toString().padLeft(2, '0')} min';

/// Reviews the days from [from] to [periodEnd] (not included). A period that
/// is not over yet is compared with the same number of days of the period
/// before, which starts on [prevFrom].
ReviewResult computeReview(DateTime from, DateTime periodEnd, DateTime prevFrom) {
  final now = DateTime.now();
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final partial = periodEnd.isAfter(tomorrow);
  final toEx = partial ? tomorrow : periodEnd;
  final days = (toEx.difference(from).inHours / 24).round();
  final prevTo = DateTime(prevFrom.year, prevFrom.month, prevFrom.day + days);
  final maxHr = maxHrSetting();

  final cur = computePeriod(from, toEx, maxHr);
  final prev = computePeriod(prevFrom, prevTo.isAfter(from) ? from : prevTo, maxHr);
  final zones = zoneTotals(from, toEx, maxHr);
  final records = newRecords(from, toEx);

  final hi = <String>[];
  if (cur.sessions == 0) {
    hi.add('No workouts in this period.');
  } else {
    hi.add('${cur.sessions} workout(s), ${_hm(cur.minutes)} in total${_pct(cur.minutes, prev.minutes)}.');
  }
  if (cur.runs > 0) {
    hi.add('Ran ${cur.runKm.toStringAsFixed(1)} km in ${cur.runs} run(s)'
        '${_pct(cur.runKm, prev.runKm)}. The longest was ${cur.longestRunKm.toStringAsFixed(1)} km.');
  }
  if (cur.gyms > 0) {
    hi.add('${cur.gyms} gym session(s) with ${cur.sets.round()} sets and '
        '${cur.volume.round()} kg of volume${_pct(cur.volume, prev.volume)}.');
  }
  for (final r in records) {
    hi.add('New best: $r.');
  }
  if (zones.total > 0) {
    hi.add('${(zones.easyShare * 100).round()} % of the endurance time was easy (zones 1 and 2), '
        '${(zones.hardShare * 100).round()} % hard (zones 4 and 5).');
  }
  if (cur.foodDays > 0) {
    var t = 'Food logged on ${cur.foodDays} day(s), on average ${cur.kcal.round()} kcal and '
        '${cur.protein.round()} g protein.';
    if (AppDb.instance.loadTargets()['protein'] != null) {
      t += ' Protein was reached on ${cur.proteinDays} of them.';
    }
    hi.add(t);
  }
  if (cur.weightFirst != null && cur.weightLast != null && cur.weightFirst != cur.weightLast) {
    final d = cur.weightLast! - cur.weightFirst!;
    hi.add('Weight went from ${cur.weightFirst!.toStringAsFixed(1)} to '
        '${cur.weightLast!.toStringAsFixed(1)} kg (${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)} kg).');
  }
  if (cur.sleepMin != null) {
    hi.add('Slept ${_hm(cur.sleepMin!)} on average over ${cur.sleepNights} night(s).');
  }
  if (cur.steps != null) hi.add('${cur.steps!.round()} steps a day on average.');

  final focus = <String>[];
  if (cur.sleepMin != null && cur.sleepNights >= 3 && cur.sleepMin! < 420) {
    focus.add('Sleep averaged under 7 hours. Protect your sleep before you add more training.');
  }
  if (prev.runKm > 0 && cur.runKm > prev.runKm * 1.3) {
    focus.add('Running volume rose by ${((cur.runKm / prev.runKm - 1) * 100).round()} %. '
        'Keep the next period similar or a little easier.');
  } else if (prev.load > 0 && cur.load > prev.load * 1.3) {
    focus.add('Training load rose by ${((cur.load / prev.load - 1) * 100).round()} %. '
        'Make sure there is time to recover.');
  }
  if (zones.total >= 60 && zones.hardShare > 0.3) {
    focus.add('A lot of time was in the hard zones (${(zones.hardShare * 100).round()} %). '
        'Most endurance training is usually kept easy, with a few hard sessions.');
  }
  final target = AppDb.instance.loadTargets()['protein'];
  if (target != null && target > 0 && cur.foodDays >= 3 && cur.proteinDays * 2 < cur.foodDays) {
    focus.add('The protein target was reached on only ${cur.proteinDays} of ${cur.foodDays} days.');
  }
  if (!partial && days >= 5 && cur.foodDays * 2 < days) {
    focus.add('Food was logged on few days. Logging more often makes these numbers more useful.');
  }
  if (cur.gyms >= 2) {
    final ws = AppDb.instance.loadAllWorkouts(withEx: true);
    final m = muscleSets(ws, dayKey(from), dayKey(DateTime(toEx.year, toEx.month, toEx.day - 1)),
        loadMuscleOverrides());
    final missing = [
      for (final g in muscleGroups)
        if ((m.sets[g] ?? 0) == 0) muscleLabels[g]!.toLowerCase()
    ];
    if (missing.isNotEmpty && missing.length <= 5) {
      focus.add('No hard sets for: ${missing.join(', ')}.');
    }
  }
  if (!partial && cur.gyms == 0 && prev.gyms > 0) {
    focus.add('No gym session this period, the one before had ${prev.gyms}.');
  }
  if (focus.isEmpty) focus.add('Nothing stands out. Keep going as you are.');

  return ReviewResult(
    from: from,
    toExclusive: toEx,
    partial: partial,
    cur: cur,
    prev: prev,
    zones: zones,
    records: records,
    highlights: hi,
    focus: focus,
  );
}
