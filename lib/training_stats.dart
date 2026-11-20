import 'dart:math' as math;
import 'db.dart';
import 'nutrients.dart';
import 'workout_format.dart';
import 'workout_types.dart';

DateTime _day(String key) {
  final p = key.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

String _key(DateTime d) => dayKey(d);

/// Monday of the week containing [day] (as YYYY-MM-DD).
String weekKeyOf(String day) {
  final d = _day(day);
  return _key(DateTime(d.year, d.month, d.day - (d.weekday - 1)));
}

String _dmy(DateTime d) => '${d.day}.${d.month}.${d.year}';

class PeriodRange {
  final DateTime start;
  final DateTime endEx;
  const PeriodRange(this.start, this.endEx);

  bool contains(String day) =>
      day.compareTo(_key(start)) >= 0 && day.compareTo(_key(endEx)) < 0;
}

/// week / month / year / all, counted back [back] periods from today.
PeriodRange? periodRange(String period, DateTime today, {int back = 0}) {
  switch (period) {
    case 'week':
      final mon = DateTime(today.year, today.month, today.day - (today.weekday - 1) - 7 * back);
      return PeriodRange(mon, DateTime(mon.year, mon.month, mon.day + 7));
    case 'month':
      final s = DateTime(today.year, today.month - back, 1);
      return PeriodRange(s, DateTime(s.year, s.month + 1, 1));
    case 'year':
      final s = DateTime(today.year - back, 1, 1);
      return PeriodRange(s, DateTime(s.year + 1, 1, 1));
    default:
      return back == 0 ? PeriodRange(DateTime(1900), DateTime(2200)) : null;
  }
}

String periodLabel(String period, PeriodRange r) {
  switch (period) {
    case 'week':
      return '${_dmy(r.start)} - ${_dmy(DateTime(r.endEx.year, r.endEx.month, r.endEx.day - 1))}';
    case 'month':
      const m = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
      return '${m[r.start.month - 1]} ${r.start.year}';
    case 'year':
      return '${r.start.year}';
    default:
      return 'All time';
  }
}

class Totals {
  int count = 0;
  double minutes = 0, km = 0, elev = 0, kcal = 0, sets = 0, volume = 0;
}

Totals totalsOf(Iterable<Workout> ws) {
  final t = Totals();
  for (final w in ws) {
    t.count++;
    t.minutes += w.minutes;
    t.km += (w.distanceM ?? 0) / 1000;
    t.elev += w.metrics['ascent_m'] ?? 0;
    t.kcal += w.activeKcal ?? 0;
    t.sets += w.metrics['sets'] ?? 0;
    t.volume += w.metrics['volume_kg'] ?? 0;
  }
  return t;
}

/// One personal record. [w] is the workout to open (null for week and
/// month records, which add up several workouts).
class RecordItem {
  final String label;
  final String value;
  final String note;
  final Workout? w;
  const RecordItem(this.label, this.value, this.w, {this.note = ''});
}

String _hms(double seconds) {
  final t = seconds.round();
  final h = t ~/ 3600, m = (t % 3600) ~/ 60, s = t % 60;
  final mm = m.toString().padLeft(2, '0'), ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}

List<RecordItem> recordsFor(Cat? cat, List<Workout> all) {
  final ws = cat == null ? all : [for (final w in all) if (categoryOf(w.type) == cat) w];
  final out = <RecordItem>[];
  if (ws.isEmpty) return out;

  double? km(Workout w) => (w.distanceM ?? 0) > 0 ? w.distanceM! / 1000 : null;

  void best(
    String label,
    double? Function(Workout) score,
    String Function(Workout, double) text, {
    bool Function(Workout)? where,
    bool lowest = false,
  }) {
    Workout? bw;
    double? bs;
    for (final w in ws) {
      if (where != null && !where(w)) continue;
      final s = score(w);
      if (s == null) continue;
      if (bs == null || (lowest ? s < bs : s > bs)) {
        bs = s;
        bw = w;
      }
    }
    if (bw != null && bs != null) out.add(RecordItem(label, text(bw, bs), bw, note: bw.day));
  }

  final foot = cat == Cat.run || cat == Cat.walk || cat == Cat.hike;
  best('Longest workout', (w) => w.minutes, (w, s) => fmtDur(s));
  best('Longest distance', km, (w, s) => '${fmt(s)} km');
  best('Most elevation gain', (w) => w.metrics['ascent_m'], (w, s) => '${s.round()} m');

  if (foot) {
    const dists = [1.0, 3.0, 5.0, 10.0, 15.0, 21.0975, 30.0, 42.195];
    const names = ['1 km', '3 km', '5 km', '10 km', '15 km', 'half marathon', '30 km', 'marathon'];
    for (var i = 0; i < dists.length; i++) {
      final d = dists[i];
      best('Fastest average pace, ${names[i]} or longer',
          (w) => (km(w) ?? 0) >= d ? paceSecPerKm(w) : null,
          (w, s) => '${fmtPace(s)} /km  (${fmt(km(w)!)} km)',
          lowest: true);
    }
  } else if (cat == Cat.cycle) {
    for (final d in [10.0, 20.0, 50.0, 100.0]) {
      best('Fastest average speed, ${d.round()} km or longer',
          (w) => (km(w) ?? 0) >= d ? speedKmh(w) : null,
          (w, s) => '${fmt(s)} km/h  (${fmt(km(w)!)} km)');
    }
  } else if (cat == Cat.swim) {
    best('Longest swim', (w) => w.distanceM, (w, s) => '${s.round()} m');
    for (final d in [200.0, 500.0, 1000.0, 2000.0]) {
      best('Fastest pace, ${d.round()} m or longer',
          (w) => (w.distanceM ?? 0) >= d ? paceSecPer100m(w) : null,
          (w, s) => '${fmtPace(s)} /100 m  (${w.distanceM!.round()} m)',
          lowest: true);
    }
  } else if (cat == Cat.strength) {
    best('Most volume in a session', (w) => w.metrics['volume_kg'], (w, s) => '${fmt(s)} kg');
    best('Most sets in a session', (w) => w.metrics['sets'], (w, s) => '${s.round()} sets');
  }
  if (cat == null) {
    best('Most calories', (w) => w.activeKcal, (w, s) => '${fmt(s)} kcal');
  }

  // best week and month (adding up several workouts)
  final wMin = <String, double>{}, wKm = <String, double>{}, wCnt = <String, double>{};
  final mKm = <String, double>{}, mMin = <String, double>{};
  for (final w in ws) {
    final wk = weekKeyOf(w.day);
    wMin[wk] = (wMin[wk] ?? 0) + w.minutes;
    wKm[wk] = (wKm[wk] ?? 0) + (w.distanceM ?? 0) / 1000;
    wCnt[wk] = (wCnt[wk] ?? 0) + 1;
    final mk = w.day.substring(0, 7);
    mKm[mk] = (mKm[mk] ?? 0) + (w.distanceM ?? 0) / 1000;
    mMin[mk] = (mMin[mk] ?? 0) + w.minutes;
  }
  void bestKey(String label, Map<String, double> m, String Function(double) text, String Function(String) note) {
    String? bk;
    var bv = 0.0;
    m.forEach((k, v) {
      if (v > bv) {
        bv = v;
        bk = k;
      }
    });
    if (bk != null) out.add(RecordItem(label, text(bv), null, note: note(bk!)));
  }

  String weekNote(String k) => 'week of ${_dmy(_day(k))}';
  if (wKm.values.any((v) => v > 0)) {
    bestKey('Best week, distance', wKm, (v) => '${fmt(v)} km', weekNote);
    bestKey('Best month, distance', mKm, (v) => '${fmt(v)} km', (k) => k);
  }
  bestKey('Best week, time', wMin, (v) => fmtDur(v), weekNote);
  bestKey('Most workouts in a week', wCnt, (v) => '${v.round()}', weekNote);
  return out;
}

/// Race time estimates from your best effort of the last 12 months, with
/// Riegel's formula T2 = T1 * (D2 / D1) ^ 1.06.
List<MapEntry<String, String>> raceEstimates(List<Workout> all, DateTime today) {
  final cut = _key(DateTime(today.year - 1, today.month, today.day));
  final runs = [
    for (final w in all)
      if (categoryOf(w.type) == Cat.run &&
          w.day.compareTo(cut) >= 0 &&
          (w.distanceM ?? 0) >= 3000)
        w
  ];
  if (runs.isEmpty) return [];
  const targets = {'5 km': 5.0, '10 km': 10.0, 'Half marathon': 21.0975, 'Marathon': 42.195};
  final out = <MapEntry<String, String>>[];
  targets.forEach((name, d) {
    double? bestT;
    for (final w in runs) {
      final km = w.distanceM! / 1000;
      final secs = w.metrics['moving_s'] ?? w.minutes * 60;
      final t = (secs * math.pow(d / km, 1.06)).toDouble();
      if (bestT == null || t < bestT!) bestT = t;
    }
    if (bestT != null) out.add(MapEntry(name, _hms(bestT!)));
  });
  return out;
}
