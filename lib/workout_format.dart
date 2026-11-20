import 'db.dart';
import 'nutrients.dart';
import 'workout_types.dart';

String workoutTitle(Workout w) =>
    w.title.isNotEmpty ? w.title : prettyType(w.type);

double? _km(Workout w) =>
    (w.distanceM != null && w.distanceM! > 0) ? w.distanceM! / 1000 : null;

/// Time used for pace and speed: moving time if known.
double _seconds(Workout w) => w.metrics['moving_s'] ?? w.minutes * 60;

/// seconds per km
double? paceSecPerKm(Workout w) {
  final km = _km(w);
  return km == null ? null : _seconds(w) / km;
}

double? speedKmh(Workout w) {
  final km = _km(w);
  final s = _seconds(w);
  return (km == null || s <= 0) ? null : km / (s / 3600);
}

/// seconds per 100 m
double? paceSecPer100m(Workout w) {
  final m = w.distanceM;
  return (m == null || m <= 0) ? null : _seconds(w) / (m / 100);
}

/// One line with the numbers that matter for this kind of activity.
String summaryLine(Workout w) {
  final c = categoryOf(w.type);
  final parts = <String>[w.day, fmtDur(w.minutes)];
  final km = _km(w);
  switch (c) {
    case Cat.run:
    case Cat.walk:
    case Cat.hike:
      if (km != null) parts.add('${fmt(km)} km');
      final p = paceSecPerKm(w);
      if (p != null) parts.add('${fmtPace(p)} /km');
      break;
    case Cat.cycle:
      if (km != null) parts.add('${fmt(km)} km');
      final s = speedKmh(w);
      if (s != null) parts.add('${fmt(s)} km/h');
      break;
    case Cat.swim:
      if (w.distanceM != null && w.distanceM! > 0) parts.add('${w.distanceM!.round()} m');
      final p = paceSecPer100m(w);
      if (p != null) parts.add('${fmtPace(p)} /100 m');
      break;
    case Cat.strength:
      final sets = w.metrics['sets'];
      final vol = w.metrics['volume_kg'];
      if (sets != null) parts.add('${sets.round()} sets');
      if (vol != null) parts.add('${fmt(vol)} kg');
      break;
    default:
      if (km != null) parts.add('${fmt(km)} km');
  }
  final hr = w.metrics['avg_hr'];
  if (hr != null) parts.add('${hr.round()} bpm');
  if (w.activeKcal != null && c != Cat.strength) parts.add('${fmt(w.activeKcal!)} kcal');
  return parts.join('  |  ');
}
