import 'dart:convert';
import 'dart:typed_data';
import 'db.dart';
import 'workout_types.dart';

/// Result of reading files from a Garmin Connect "export all your data"
/// download: the workouts, the numbers per day (steps, sleep, ...) and
/// things worth telling the user.
class GarminExportResult {
  final List<Workout> workouts;

  /// day (YYYY-MM-DD) -> metric key -> value, same keys as Health Connect
  final Map<String, Map<String, double>> days;
  final List<String> warnings;
  final String? error;

  /// [startMs, endMs, kcal wrongly stored by the first importer, correct kcal]
  final List<List<double>> kcalFixes;
  const GarminExportResult(this.workouts, this.days, this.warnings,
      {this.error, this.kcalFixes = const []});
}

double? _d(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// All maps inside [d] that satisfy [isRec] (the wrapper lists around the
/// records differ from file to file, so we look for the records themselves).
List<Map> _findRecords(dynamic d, bool Function(Map) isRec, [int depth = 0]) {
  final out = <Map>[];
  if (depth > 5) return out;
  if (d is Map) {
    if (isRec(d)) return [d];
    for (final v in d.values) {
      if (v is Map || v is List) out.addAll(_findRecords(v, isRec, depth + 1));
    }
  } else if (d is List) {
    for (final v in d) {
      if (v is Map || v is List) out.addAll(_findRecords(v, isRec, depth + 1));
    }
  }
  return out;
}

DateTime? _time(dynamic v) {
  if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.round(), isUtc: true);
  if (v is String) return DateTime.tryParse(v);
  return null;
}

String _canon(String raw) => raw
    .trim()
    .toUpperCase()
    .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

/// Reads the files the user picked (name -> content). Files of kinds we do
/// not use are ignored.
GarminExportResult parseGarminExport(Map<String, Uint8List> files) {
  final warnings = <String>[];
  final acts = <String, Map>{}; // by activityId
  final days = <String, Map<String, double>>{};
  var actFiles = 0, sleepFiles = 0, dayFiles = 0, vo2Files = 0, ignored = 0;
  var sleepScaled = 0, sleepSkipped = 0;

  void put(String day, String key, double? v) {
    if (v == null || day.length != 10) return;
    days.putIfAbsent(day, () => <String, double>{})[key] = v;
  }

  for (final e in files.entries) {
    final name = e.key.toLowerCase();
    final isAct = name.contains('summarizedactivities');
    final isSleep = name.contains('sleepdata');
    final isUds = name.contains('udsfile');
    final isVo2 = name.contains('maxmetdata');
    if (!isAct && !isSleep && !isUds && !isVo2) {
      ignored++;
      continue;
    }
    dynamic data;
    try {
      data = jsonDecode(utf8.decode(e.value, allowMalformed: true));
    } catch (_) {
      warnings.add('Could not read ${e.key} as JSON.');
      continue;
    }

    if (isAct) {
      actFiles++;
      for (final r in _findRecords(
          data, (m) => m.containsKey('activityId') && m.containsKey('startTimeGmt'))) {
        acts['${r['activityId']}'] = r;
      }
    } else if (isSleep) {
      sleepFiles++;
      for (final r in _findRecords(data,
          (m) => m.containsKey('calendarDate') && m.containsKey('deepSleepSeconds'))) {
        final day = '${r['calendarDate']}';
        var deep = (_d(r['deepSleepSeconds']) ?? 0) / 60;
        var light = (_d(r['lightSleepSeconds']) ?? 0) / 60;
        var rem = (_d(r['remSleepSeconds']) ?? 0) / 60;
        final awake = (_d(r['awakeSleepSeconds']) ?? 0) / 60;
        var asleep = deep + light + rem;
        if (asleep <= 0) continue;
        // the stages cannot add up to more than the night itself
        final st = _time(r['sleepStartTimestampGMT']);
        final en = _time(r['sleepEndTimestampGMT']);
        if (st != null && en != null && en.isAfter(st)) {
          final window = en.difference(st).inMinutes.toDouble();
          if (asleep > window * 1.02) {
            final target = window - awake > 0 ? window - awake : window;
            final f = target / asleep;
            deep *= f;
            light *= f;
            rem *= f;
            asleep = deep + light + rem;
            sleepScaled++;
          }
        }
        if (asleep > 14 * 60) {
          sleepSkipped++;
          continue;
        }
        put(day, 'sleep_deep', deep);
        put(day, 'sleep_light', light);
        put(day, 'sleep_rem', rem);
        put(day, 'sleep_awake', awake);
        put(day, 'sleep_total', asleep);
        final sc = r['sleepScores'];
        if (sc is Map) put(day, 'sleep_score', _d(sc['overallScore']));
      }
    } else if (isUds) {
      dayFiles++;
      for (final r in _findRecords(
          data, (m) => m.containsKey('calendarDate') && m.containsKey('totalSteps'))) {
        final day = '${r['calendarDate']}';
        final steps = _d(r['totalSteps']);
        if (steps != null && steps > 0) put(day, 'steps', steps);
        final act = _d(r['activeKilocalories']);
        if (act != null && act > 0) put(day, 'active_kcal', act);
        final dist = _d(r['totalDistanceMeters']);
        if (dist != null && dist > 0) put(day, 'distance_km', dist / 1000);
        final fl = _d(r['floorsAscendedInMeters']);
        if (fl != null && fl > 0) put(day, 'floors', (fl / 3.048).roundToDouble());
        final rhr = _d(r['restingHeartRate']);
        if (rhr != null && rhr > 0) put(day, 'resting_hr', rhr);
      }
    } else if (isVo2) {
      vo2Files++;
      // several sports per day are possible: running wins
      final best = <String, double>{};
      final isRun = <String, bool>{};
      for (final r in _findRecords(
          data, (m) => m.containsKey('calendarDate') && m.containsKey('vo2MaxValue'))) {
        final day = '${r['calendarDate']}';
        final v = _d(r['vo2MaxValue']);
        if (v == null || v <= 0) continue;
        final run = '${r['sport']}'.toUpperCase().contains('RUN');
        if (!best.containsKey(day) || (run && isRun[day] != true)) {
          best[day] = v;
          isRun[day] = run;
        }
      }
      best.forEach((day, v) => put(day, 'vo2max', v));
    }
  }

  // ---- distances: centimetres in the Garmin export (checked on the runs) ----
  final speeds = <double>[];
  for (final a in acts.values) {
    final t = _typeOf(a);
    final dist = _d(a['distance']);
    final dur = _d(a['duration']);
    if (t.contains('RUN') && dist != null && dist > 0 && dur != null && dur > 0) {
      speeds.add(dist / (dur / 1000));
    }
  }
  var scale = 0.01;
  if (speeds.isNotEmpty) {
    speeds.sort();
    final med = speeds[speeds.length ~/ 2];
    if (med < 60) scale = 1.0; // already metres per second
    warnings.add(scale == 0.01
        ? 'Distances and elevations are read as centimetres (median running speed '
            '${(med / 100 * 3.6).toStringAsFixed(1)} km/h). If that is not about right, '
            'tell me.'
        : 'Distances and elevations are read as metres (median running speed '
            '${(med * 3.6).toStringAsFixed(1)} km/h).');
  } else {
    warnings.add('No runs found to check the distance unit, centimetres assumed.');
  }

  // ---- activities ----
  final workouts = <Workout>[];
  final kcalFixes = <List<double>>[];
  var bad = 0;
  for (final a in acts.values) {
    try {
      final w = _workoutFrom(a, scale);
      if (w == null) {
        bad++;
      } else {
        workouts.add(w);
        final kj = _activeKj(a);
        if (kj != null && w.activeKcal != null) {
          kcalFixes.add([w.startMs.toDouble(), w.endMs.toDouble(), kj, w.activeKcal!]);
        }
      }
    } catch (_) {
      bad++;
    }
  }
  if (bad > 0) warnings.add('$bad activit${bad == 1 ? 'y' : 'ies'} skipped (no time or duration).');

  if (actFiles + sleepFiles + dayFiles + vo2Files == 0) {
    return GarminExportResult([], {}, warnings,
        error: 'None of the chosen files is a kind I read. I need the files named '
            '..._summarizedActivities.json, ..._sleepData.json, UDSFile_... and '
            'MetricsMaxMetData_... from the export.');
  }
  warnings.add('Read: $actFiles activity file(s), $sleepFiles sleep, '
      '$dayFiles daily summary, $vo2Files VO2 max'
      '${ignored > 0 ? ' ($ignored other file(s) ignored)' : ''}.');
  if (sleepScaled > 0) {
    warnings.add('$sleepScaled night(s) had sleep stages longer than the night itself '
        'and were scaled down to fit.');
  }
  if (sleepSkipped > 0) warnings.add('$sleepSkipped night(s) skipped: more than 14 h of sleep.');
  warnings.add('Calories of an activity are active calories (total minus resting). '
      'GPS tracks, splits and per-second heart rate are not in these files.');
  return GarminExportResult(workouts, days, warnings, kcalFixes: kcalFixes);
}

String _typeOf(Map a) {
  final t = a['activityType'];
  if (t is Map) return _canon('${t['typeKey'] ?? ''}');
  return _canon('${t ?? ''}');
}

Workout? _workoutFrom(Map a, double scale) {
  final gmt = _d(a['startTimeGmt']) ?? _d(a['beginTimestamp']);
  final durMs = _d(a['duration']) ?? _d(a['elapsedDuration']);
  if (gmt == null || durMs == null || durMs <= 0) return null;
  final type = _typeOf(a);
  if (type.isEmpty) return null;

  final startMs = gmt.round();
  final endMs = startMs + durMs.round();
  // startTimeLocal is the wall-clock time stored as if it were UTC
  final loc = _d(a['startTimeLocal']);
  final localDt = loc != null
      ? DateTime.fromMillisecondsSinceEpoch(loc.round(), isUtc: true)
      : DateTime.fromMillisecondsSinceEpoch(startMs);

  final metrics = <String, double>{};
  void m(String key, double? v, [double mult = 1]) {
    if (v != null) metrics[key] = v * mult;
  }

  m('avg_hr', _d(a['avgHr']));
  m('max_hr', _d(a['maxHr']));
  m('min_hr', _d(a['minHr']));
  m('te_aerobic', _d(a['aerobicTrainingEffect']));
  final up = _d(a['elevationGain']);
  final down = _d(a['elevationLoss']);
  if (up != null && up > 0) m('ascent_m', up, scale);
  if (down != null && down > 0) m('descent_m', down, scale);
  m('elev_min', _d(a['minElevation']), scale);
  m('elev_max', _d(a['maxElevation']), scale);
  m('cadence_avg', _d(a['avgDoubleCadence']) ?? _d(a['avgRunCadence']));
  m('cadence_max', _d(a['maxDoubleCadence']) ?? _d(a['maxRunCadence']));
  final stride = _d(a['avgStrideLength']);
  if (stride != null) m('stride_m', stride > 10 ? stride / 100 : stride);
  final osc = _d(a['avgVerticalOscillation']);
  if (osc != null) m('vert_osc', osc > 30 ? osc / 10 : osc);
  m('vert_ratio', _d(a['avgVerticalRatio']));
  m('gct_ms', _d(a['avgGroundContactTime']));
  m('power_avg', _d(a['avgPower']));
  m('power_max', _d(a['maxPower']));
  m('swolf', _d(a['avgSwolf']));
  m('stroke_rate', _d(a['avgSwimCadence']));
  m('laps', _d(a['lapCount']));
  m('reps', _d(a['totalReps']));
  m('sets', _d(a['activeSets']) ?? _d(a['totalSets']));
  m('steps', _d(a['steps']));
  final rpe = _d(a['workoutRpe']); // Garmin stores 0-100 in steps of 10
  if (rpe != null && rpe > 0) m('rpe', rpe / 10);
  final mov = _d(a['movingDuration']);
  final ela = _d(a['elapsedDuration']);
  if (mov != null && mov > 0) m('moving_s', mov / 1000);
  if (ela != null && ela > 0) m('elapsed_s', ela / 1000);
  // drop zeros that only mean "not measured"
  for (final k in ['ascent_m', 'descent_m', 'cadence_avg', 'cadence_max', 'power_avg', 'power_max', 'steps', 'reps', 'sets', 'laps']) {
    if (metrics[k] == 0) metrics.remove(k);
  }

  final dist = _d(a['distance']);
  // the export stores energy in kilojoules (also when the field says calories)
  final kj = _activeKj(a);
  final double? active = kj == null ? null : kj / 4.184;
  final desc = a['description'];

  return Workout(
    id: 'garmin:${a['activityId']}',
    day: dayKey(localDt),
    startMs: startMs,
    endMs: endMs,
    type: type,
    title: '${a['name'] ?? ''}'.trim(),
    distanceM: (dist != null && dist > 0) ? dist * scale : null,
    activeKcal: active,
    source: 'garmin_export',
    notes: desc is String ? desc.trim() : '',
    metrics: metrics,
    splits: categoryOf(type) == Cat.strength ? const [] : _splitsFrom(a),
  );
}

double _meters(String unit, double v) {
  switch (unit) {
    case 'METER':
      return v;
    case 'KILOMETER':
      return v * 1000;
    case 'MILLIMETER':
      return v / 1000;
    default: // CENTIMETER, the unit the export uses
      return v / 100;
  }
}

double _seconds(String unit, double v) => unit == 'SECOND' ? v : v / 1000;

double _r2(double v) => (v * 100).round() / 100;

/// The laps / splits of an activity. Each one has a list of "measurements"
/// with a field name and a unit; they are converted to metres, seconds and
/// so on here. Strength activities are skipped (their splits are sets).
List<Map<String, dynamic>> _splitsFrom(Map a) {
  final raw = a['splits'];
  if (raw is! List || raw.length < 2) return const [];
  final out = <Map<String, dynamic>>[];
  var n = 0;
  for (final s in raw) {
    if (s is! Map) continue;
    final ms = s['measurements'];
    if (ms is! List) continue;
    final v = <String, double>{}; // field -> value as in the file
    final u = <String, String>{}; // field -> unit
    for (final m in ms) {
      if (m is! Map || m['valid'] == false) continue;
      final x = _d(m['value']);
      if (x == null) continue;
      v['${m['fieldEnum']}'] = x;
      u['${m['fieldEnum']}'] = '${m['unitEnum']}';
    }
    double? len(String f) => v[f] == null ? null : _meters(u[f] ?? '', v[f]!);
    double? sec(String f) => v[f] == null ? null : _seconds(u[f] ?? '', v[f]!);

    var secs = sec('SUM_DURATION') ?? sec('SUM_ELAPSEDDURATION');
    if (secs == null) {
      final st = _d(s['startTimeGMT']), en = _d(s['endTimeGMT']);
      if (st != null && en != null && en > st) secs = (en - st) / 1000;
    }
    if (secs == null || secs <= 0) continue;
    n++;
    final dist = len('SUM_DISTANCE');
    final item = <String, dynamic>{'i': n, 's': _r2(secs)};
    void put(String key, double? x) {
      if (x != null && x > 0) item[key] = _r2(x);
    }

    put('d', dist);
    put('hr', v['WEIGHTED_MEAN_HEARTRATE']);
    put('hm', v['MAX_HEARTRATE']);
    put('cd', v['WEIGHTED_MEAN_DOUBLE_CADENCE']);
    put('pw', v['WEIGHTED_MEAN_POWER']);
    put('up', len('GAIN_ELEVATION'));
    put('dn', len('LOSS_ELEVATION'));
    put('gc', v['WEIGHTED_MEAN_GROUND_CONTACT_TIME']);
    put('st', len('WEIGHTED_MEAN_STRIDE_LENGTH'));
    put('vo', v['WEIGHTED_MEAN_VERTICAL_OSCILLATION']); // cm
    out.add(item);
  }
  return out.length < 2 ? const [] : out;
}

/// Active energy of an activity in kilojoules: total minus resting (BMR).
double? _activeKj(Map a) {
  final cal = _d(a['calories']);
  final bmr = _d(a['bmrCalories']);
  if (cal == null || cal <= 0) return null;
  return (bmr != null && bmr > 0 && bmr < cal) ? cal - bmr : cal;
}

// ---------------------------------------------------------------------------
// Garmin Connect (direct sync)
// ---------------------------------------------------------------------------

/// Reads what garmin_sync.py on the sync server fetched from Garmin Connect
/// (the "inbox"): activities with their laps, and sleep and daily numbers per
/// day. Sleep and daily numbers go through the same, already checked code as
/// the full export. Only the activities are read here, because Garmin Connect
/// sends seconds, metres and kcal where the export has milliseconds,
/// centimetres and kilojoules.
GarminExportResult parseGarminInbox(Map inbox) {
  final warnings = <String>[];
  final workouts = <Workout>[];
  final vo2 = <String, double>{};
  final vo2Run = <String>{};
  var bad = 0;

  final acts = inbox['activities'];
  if (acts is List) {
    for (final a in acts) {
      if (a is! Map) continue;
      try {
        final w = _workoutFromConnect(a);
        if (w == null) {
          bad++;
          continue;
        }
        workouts.add(w);
        final v = _d(a['vO2MaxValue']);
        if (v != null && v > 0) {
          final isRun = w.type.contains('RUN');
          if (!vo2.containsKey(w.day) || (isRun && !vo2Run.contains(w.day))) {
            vo2[w.day] = v;
            if (isRun) vo2Run.add(w.day);
          }
        }
      } catch (_) {
        bad++;
      }
    }
  }
  if (bad > 0) {
    warnings.add('$bad activit${bad == 1 ? 'y' : 'ies'} skipped (no time or duration).');
  }

  // sleep and daily numbers: through the export code (same field names)
  final sleep = <Map>[];
  final stats = <Map>[];
  final d = inbox['days'];
  if (d is Map) {
    for (final e in d.values) {
      if (e is! Map) continue;
      final s = e['sleep'];
      if (s is Map) sleep.add(s);
      final t = e['stats'];
      if (t is Map) stats.add(t);
    }
  }
  Uint8List bytes(Object o) => Uint8List.fromList(utf8.encode(jsonEncode(o)));
  final r = parseGarminExport({
    'sleepData_connect.json': bytes(sleep),
    'UDSFile_connect.json': bytes(stats),
  });
  if (r.error != null) {
    return GarminExportResult(workouts, const {}, warnings, error: r.error);
  }
  final days = <String, Map<String, double>>{
    for (final e in r.days.entries) e.key: Map<String, double>.from(e.value),
  };
  vo2.forEach((day, v) {
    days.putIfAbsent(day, () => <String, double>{})['vo2max'] = v;
  });
  // only the sleep notes of the export code are of interest here
  for (final msg in r.warnings) {
    if (msg.contains('night(s)')) warnings.add(msg);
  }
  return GarminExportResult(workouts, days, warnings);
}

/// Start of an activity in milliseconds (UTC) from "2026-11-23 08:25:55"
/// (GMT) or from the timestamp.
int? _startOfConnect(Map a) {
  final gmt = a['startTimeGMT'];
  if (gmt is String) {
    final t = DateTime.tryParse('${gmt.trim().replaceFirst(' ', 'T')}Z');
    if (t != null) return t.millisecondsSinceEpoch;
  }
  return _d(a['beginTimestamp'])?.round();
}

Workout? _workoutFromConnect(Map a) {
  final id = a['activityId'];
  final startMs = _startOfConnect(a);
  final dur = _d(a['duration']) ?? _d(a['elapsedDuration']); // seconds
  if (id == null || startMs == null || dur == null || dur <= 0) return null;
  final type = _typeOf(a);
  if (type.isEmpty) return null;

  // startTimeLocal is the wall-clock time of the place where it happened
  final loc = a['startTimeLocal'];
  final day = (loc is String && loc.length >= 10)
      ? loc.substring(0, 10)
      : dayKey(DateTime.fromMillisecondsSinceEpoch(startMs));

  final metrics = <String, double>{};
  void m(String key, double? v) {
    if (v != null) metrics[key] = v;
  }

  m('avg_hr', _d(a['averageHR']));
  m('max_hr', _d(a['maxHR']));
  m('te_aerobic', _d(a['aerobicTrainingEffect']));
  final up = _d(a['elevationGain']);
  final down = _d(a['elevationLoss']);
  if (up != null && up > 0) m('ascent_m', up);
  if (down != null && down > 0) m('descent_m', down);
  m('elev_min', _d(a['minElevation']));
  m('elev_max', _d(a['maxElevation']));
  m(
      'cadence_avg',
      _d(a['averageRunningCadenceInStepsPerMinute']) ??
          _d(a['avgDoubleCadence']) ??
          _d(a['avgRunCadence']));
  m(
      'cadence_max',
      _d(a['maxRunningCadenceInStepsPerMinute']) ??
          _d(a['maxDoubleCadence']) ??
          _d(a['maxRunCadence']));
  final stride = _d(a['avgStrideLength']); // centimetres
  if (stride != null) m('stride_m', stride > 10 ? stride / 100 : stride);
  final osc = _d(a['avgVerticalOscillation']); // centimetres
  if (osc != null) m('vert_osc', osc > 30 ? osc / 10 : osc);
  m('vert_ratio', _d(a['avgVerticalRatio']));
  m('gct_ms', _d(a['avgGroundContactTime']));
  m('power_avg', _d(a['avgPower']));
  m('power_max', _d(a['maxPower']));
  m('laps', _d(a['lapCount']));
  m('reps', _d(a['totalReps']));
  m('sets', _d(a['activeSets']) ?? _d(a['totalSets']));
  m('steps', _d(a['steps']));
  final mov = _d(a['movingDuration']);
  final ela = _d(a['elapsedDuration']);
  if (mov != null && mov > 0) m('moving_s', mov);
  if (ela != null && ela > 0) m('elapsed_s', ela);
  // drop zeros that only mean "not measured"
  for (final k in ['ascent_m', 'descent_m', 'cadence_avg', 'cadence_max', 'power_avg', 'power_max', 'steps', 'reps', 'sets', 'laps']) {
    if (metrics[k] == 0) metrics.remove(k);
  }

  final dist = _d(a['distance']); // metres
  final desc = a['description'];
  return Workout(
    id: 'garmin:$id',
    day: day,
    startMs: startMs,
    endMs: startMs + (dur * 1000).round(),
    type: type,
    title: '${a['activityName'] ?? ''}'.trim(),
    distanceM: (dist != null && dist > 0) ? dist : null,
    // calories minus resting energy; Garmin Connect sends kcal already
    activeKcal: _activeKj(a),
    source: 'garmin_connect',
    notes: desc is String ? desc.trim() : '',
    metrics: metrics,
    splits: categoryOf(type) == Cat.strength
        ? const []
        : _lapsFromConnect(a['laps'], dist, dur),
  );
}

/// The laps of a run, ride or swim. They are only used when they add up to
/// the whole activity (distance and time within 10 percent); otherwise the
/// laps are left out rather than risk wrong numbers.
List<Map<String, dynamic>> _lapsFromConnect(dynamic raw, double? totalDist, double totalSecs) {
  if (raw is! List || raw.length < 2) return const [];
  final out = <Map<String, dynamic>>[];
  var sumD = 0.0, sumS = 0.0;
  var n = 0;
  for (final l in raw) {
    if (l is! Map) continue;
    final secs = _d(l['duration']) ?? _d(l['elapsedDuration']);
    if (secs == null || secs <= 0) continue;
    n++;
    sumS += secs;
    final item = <String, dynamic>{'i': n, 's': _r2(secs)};
    void put(String key, double? x, [double lo = 0, double hi = 1e9]) {
      if (x != null && x > lo && x < hi) item[key] = _r2(x);
    }

    final dist = _d(l['distance']);
    if (dist != null && dist > 0) sumD += dist;
    put('d', dist);
    put('hr', _d(l['averageHR']), 25, 250);
    put('hm', _d(l['maxHR']), 25, 250);
    put(
        'cd',
        _d(l['averageRunCadence']) ??
            _d(l['averageRunningCadenceInStepsPerMinute']) ??
            _d(l['avgDoubleCadence']),
        100,
        260);
    put('pw', _d(l['averagePower']) ?? _d(l['avgPower']));
    put('up', _d(l['elevationGain']));
    put('dn', _d(l['elevationLoss']));
    put('gc', _d(l['groundContactTime']) ?? _d(l['avgGroundContactTime']), 100, 600);
    final st = _d(l['strideLength']) ?? _d(l['avgStrideLength']); // centimetres
    if (st != null) put('st', st > 10 ? st / 100 : st);
    final vo = _d(l['verticalOscillation']) ?? _d(l['avgVerticalOscillation']); // centimetres
    if (vo != null) put('vo', vo > 30 ? vo / 10 : vo);
    out.add(item);
  }
  if (out.length < 2) return const [];
  if (sumS < totalSecs * 0.9 || sumS > totalSecs * 1.1) return const [];
  if (totalDist != null && totalDist > 0 && (sumD < totalDist * 0.9 || sumD > totalDist * 1.1)) {
    return const [];
  }
  return out;
}
