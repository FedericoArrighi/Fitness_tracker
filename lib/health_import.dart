import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'db.dart';

class HealthImportResult {
  final int weights; // weight entries added or changed
  final int days; // days with activity data added or changed
  final int workouts; // workouts added or changed
  final String? error;
  final String? note;
  const HealthImportResult({
    this.weights = 0,
    this.days = 0,
    this.workouts = 0,
    this.error,
    this.note,
  });

  int get total => weights + days + workouts;

  String get summary {
    if (error != null) return error!;
    final parts = <String>[
      if (weights > 0) '$weights weight(s)',
      if (days > 0) '$days day(s) of activity data',
      if (workouts > 0) '$workouts workout(s)',
    ];
    var s = parts.isEmpty
        ? 'Nothing new to import.'
        : 'Imported ${parts.join(', ')}.';
    if (note != null) s += ' $note';
    return s;
  }
}

class _Hr {
  final Map<String, double> metrics;
  final List<List<double>> series;
  const _Hr(this.metrics, this.series);
}

class _WindowResult {
  final int weights;
  final int days;
  final int workouts;
  final bool hadData;
  const _WindowResult(this.weights, this.days, this.workouts, this.hadData);
}

/// Reads weight, steps, sleep, calories, distance, floors, resting heart rate,
/// body fat and workouts from Android's Health Connect (where the Garmin
/// Connect app puts your watch data). Read-only: nothing is written back.
class HealthImport {
  static final Health _health = Health();
  static bool _configured = false;

  // Many small records per day: fetched in slices of a few days.
  static const _denseTypes = [
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.DISTANCE_DELTA,
    HealthDataType.FLIGHTS_CLIMBED,
  ];
  // Few records per day: fetched in bigger slices.
  static const _otherTypes = [
    HealthDataType.BODY_FAT_PERCENTAGE,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.SLEEP_AWAKE,
    HealthDataType.SLEEP_DEEP,
    HealthDataType.SLEEP_LIGHT,
    HealthDataType.SLEEP_REM,
    HealthDataType.SLEEP_SESSION,
    HealthDataType.WORKOUT,
  ];

  static List<HealthDataType> get _allTypes => [
        HealthDataType.WEIGHT,
        HealthDataType.STEPS,
        HealthDataType.HEART_RATE,
        ..._denseTypes,
        ..._otherTypes,
      ];

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> _ensureConfigured() async {
    if (!_configured) {
      await _health.configure();
      _configured = true;
    }
  }

  /// Asks for permission if needed, then imports the last [days] days, in
  /// windows of 90 days, newest first. [onProgress] gets short status texts.
  static Future<HealthImportResult> importAll(
          {int days = 30, void Function(String)? onProgress}) =>
      _run(days: days, request: true, onProgress: onProgress);

  /// Silent import at app start. Does nothing unless an import worked before.
  /// Returns the number of changes.
  static Future<int> autoImport() async {
    if (!supported || AppDb.instance.getSetting('hc_enabled') != '1') return 0;
    // Reading 14 days of Health Connect data is slow, so that is done twice a
    // day; in between only the last 3 days are read.
    final db = AppDb.instance;
    final last = int.tryParse(db.getSetting('hc_last_full') ?? '') ?? 0;
    final full = nowMs() - last > 12 * 3600 * 1000;
    final r = await _run(days: full ? 14 : 3, request: false);
    if (full) db.setSetting('hc_last_full', '${nowMs()}');
    return r.total;
  }

  static Future<List<HealthDataPoint>> _fetch(HealthDataType type,
      DateTime start, DateTime end, List<String> failures) async {
    try {
      return await _health.getHealthDataFromTypes(
          types: [type], startTime: start, endTime: end);
    } catch (e) {
      final m = e.toString();
      failures.add('${type.name}: ${m.length > 120 ? m.substring(0, 120) : m}');
      return [];
    }
  }

  static double? _num(HealthDataPoint p) {
    final v = p.value;
    return v is NumericHealthValue ? v.numericValue.toDouble() : null;
  }

  /// Average, maximum and a thinned-out series of the heart rate during a workout.
  static Future<_Hr?> _heartRate(Workout w, List<String> failures) async {
    final start = DateTime.fromMillisecondsSinceEpoch(w.startMs);
    final end = DateTime.fromMillisecondsSinceEpoch(w.endMs);
    final pts = await _fetch(HealthDataType.HEART_RATE, start, end, failures);
    final samples = <List<double>>[]; // [minute, bpm]
    for (final p in pts) {
      final v = _num(p);
      if (v == null || v < 25 || v > 250) continue;
      final minute = p.dateFrom.difference(start).inSeconds / 60.0;
      if (minute < -1 || minute > w.minutes + 1) continue;
      samples.add([minute < 0 ? 0 : minute, v]);
    }
    if (samples.isEmpty) return null;
    samples.sort((a, b) => a[0].compareTo(b[0]));
    final bpms = samples.map((s) => s[1]).toList();
    final avg = bpms.fold<double>(0, (a, b) => a + b) / bpms.length;
    final max = bpms.reduce((a, b) => a > b ? a : b);
    final min = bpms.reduce((a, b) => a < b ? a : b);
    // thin out to about 100 points (average per time slot)
    final slot = (w.minutes / 100).clamp(0.5, 600.0).toDouble();
    final sums = <int, List<double>>{};
    for (final s in samples) {
      final k = (s[0] / slot).floor();
      final e = sums.putIfAbsent(k, () => [0, 0]);
      e[0] += s[1];
      e[1] += 1;
    }
    final keys = sums.keys.toList()..sort();
    final series = [
      for (final k in keys)
        [double.parse((k * slot).toStringAsFixed(2)), (sums[k]![0] / sums[k]![1]).roundToDouble()]
    ];
    return _Hr({'avg_hr': avg.roundToDouble(), 'max_hr': max, 'min_hr': min}, series);
  }

  static Future<_WindowResult> _importWindow(
    AppDb db,
    DateTime startDay,
    DateTime endDayExclusive,
    DateTime now,
    List<String> failures,
    Set<String> seen,
  ) async {
    // one extra day before, because a night belongs to the day you wake up
    final fetchStart =
        DateTime(startDay.year, startDay.month, startDay.day - 1);
    final fetchEnd = endDayExclusive.isAfter(now) ? now : endDayExclusive;
    final firstKey = dayKey(startDay);
    final endKey = dayKey(endDayExclusive);

    final agg = <String, Map<String, double>>{};
    void add(String day, String key, double v) {
      final m = agg.putIfAbsent(day, () => {});
      m[key] = (m[key] ?? 0) + v;
    }

    void put(String day, String key, double v) {
      agg.putIfAbsent(day, () => {})[key] = v;
    }

    String sleepDay(DateTime t) =>
        dayKey(t.add(const Duration(hours: 9))); // night -> wake-up day

    final workouts = <Workout>[];
    var oddWorkouts = 0;
    // sleep records per night and stage as [from, to] in ms. Garmin can write
    // the same night more than once; overlapping records are counted once.
    final sleepIv = <String, Map<String, List<List<int>>>>{};

    void process(HealthDataType type, List<HealthDataPoint> points) {
      points.sort((a, b) => a.dateFrom.compareTo(b.dateFrom));
      for (final p in points) {
        // Sleep stages of one night share one uuid, so the times are part of the key.
        if (!seen.add(
            '${type.name}:${p.uuid}:${p.dateFrom.millisecondsSinceEpoch}:${p.dateTo.millisecondsSinceEpoch}')) {
          continue;
        }
        if (type == HealthDataType.WORKOUT) {
          final v = p.value;
          if (v is! WorkoutHealthValue) {
            oddWorkouts++;
            continue;
          }
          workouts.add(Workout(
            id: 'hc:${p.uuid}',
            day: dayKey(p.dateFrom.toLocal()),
            startMs: p.dateFrom.millisecondsSinceEpoch,
            endMs: p.dateTo.millisecondsSinceEpoch,
            type: v.workoutActivityType.name,
            distanceM: v.totalDistance?.toDouble(),
            activeKcal: v.totalEnergyBurned?.toDouble(),
            source: 'health_connect',
            origin: p.sourceId,
            metrics: {
              if (v.totalSteps != null && v.totalSteps! > 0)
                'steps': v.totalSteps!.toDouble(),
            },
          ));
          continue;
        }
        final n = _num(p);
        final day = dayKey(p.dateFrom.toLocal());
        if (type == HealthDataType.ACTIVE_ENERGY_BURNED && n != null) {
          add(day, 'active_kcal', n);
        } else if (type == HealthDataType.DISTANCE_DELTA && n != null) {
          add(day, 'distance_km', n / 1000);
        } else if (type == HealthDataType.FLIGHTS_CLIMBED && n != null) {
          add(day, 'floors', n);
        } else if (type == HealthDataType.BODY_FAT_PERCENTAGE && n != null) {
          put(day, 'body_fat', n);
        } else if (type == HealthDataType.RESTING_HEART_RATE && n != null) {
          put(day, 'resting_hr', n);
        } else if (type.name.startsWith('SLEEP_')) {
          final minutes = p.dateTo.difference(p.dateFrom).inMinutes.toDouble();
          final key = {
            HealthDataType.SLEEP_DEEP: 'sleep_deep',
            HealthDataType.SLEEP_LIGHT: 'sleep_light',
            HealthDataType.SLEEP_REM: 'sleep_rem',
            HealthDataType.SLEEP_AWAKE: 'sleep_awake',
            HealthDataType.SLEEP_ASLEEP: 'sleep_unspecified',
            HealthDataType.SLEEP_SESSION: 'sleep_session',
          }[type];
          if (key != null && minutes > 0) {
            sleepIv
                .putIfAbsent(sleepDay(p.dateFrom.toLocal()), () => {})
                .putIfAbsent(key, () => [])
                .add([p.dateFrom.millisecondsSinceEpoch, p.dateTo.millisecondsSinceEpoch]);
          }
        }
      }
    }

    DateTime nextSlice(DateTime s, int n) => DateTime(s.year, s.month, s.day + n);

    // dense types: slices of 7 days
    for (final type in _denseTypes) {
      for (var s = fetchStart; s.isBefore(fetchEnd); s = nextSlice(s, 7)) {
        final e = nextSlice(s, 7);
        process(type, await _fetch(type, s, e.isAfter(fetchEnd) ? fetchEnd : e, failures));
      }
    }
    // other types: the whole window at once
    for (final type in _otherTypes) {
      process(type, await _fetch(type, fetchStart, fetchEnd, failures));
    }

    // steps: one total per day (Health Connect removes double counting)
    var d0 = startDay;
    while (d0.isBefore(endDayExclusive) && d0.isBefore(now)) {
      final d1 = DateTime(d0.year, d0.month, d0.day + 1);
      try {
        final steps =
            await _health.getTotalStepsInInterval(d0, d1.isAfter(now) ? now : d1);
        if (steps != null && steps > 0) put(dayKey(d0), 'steps', steps.toDouble());
      } catch (e) {
        if (failures.length < 3) failures.add('steps: $e');
        break;
      }
      d0 = d1;
    }

    // minutes covered by a set of [from, to] intervals (overlaps count once)
    double unionMin(List<List<int>> iv) {
      final sorted = [...iv]..sort((x, y) => x[0].compareTo(y[0]));
      var total = 0;
      var curS = -1, curE = -1;
      for (final r in sorted) {
        if (curE < 0 || r[0] > curE) {
          if (curE >= 0) total += curE - curS;
          curS = r[0];
          curE = r[1];
        } else if (r[1] > curE) {
          curE = r[1];
        }
      }
      if (curE >= 0) total += curE - curS;
      return total / 60000.0;
    }

    // sleep total = all sleeping stages together, each minute counted once
    for (final e in sleepIv.entries) {
      final m = agg.putIfAbsent(e.key, () => {});
      final asleep = <List<int>>[];
      double? session;
      for (final kv in e.value.entries) {
        final mins = unionMin(kv.value);
        if (kv.key == 'sleep_session') {
          session = mins; // whole night, incl. awake
          continue;
        }
        if (kv.key != 'sleep_unspecified') m[kv.key] = mins;
        if (kv.key != 'sleep_awake') asleep.addAll(kv.value);
      }
      final sess = session;
      if (asleep.isNotEmpty) {
        m['sleep_total'] = unionMin(asleep);
      } else if (sess != null && sess > 0) {
        // no stages recorded: use the length of the session
        m['sleep_total'] = sess;
      }
    }

    // Everything that needs the phone (heart rate, weight) first ...
    final prepared = <Workout>[];
    for (final w in workouts) {
      if (w.day.compareTo(firstKey) < 0 || w.day.compareTo(endKey) >= 0) continue;
      var toSave = w;
      final stored = db.loadWorkout(w.id);
      if (stored == null ||
          (stored.source == 'health_connect' && stored.hr.isEmpty && !stored.deleted)) {
        final hr = await _heartRate(w, failures);
        if (hr != null) {
          toSave = w.copyWith(
            metrics: {...w.metrics, ...hr.metrics},
            hr: hr.series,
          );
        }
      }
      prepared.add(toSave);
    }
    final wPoints = await _fetch(HealthDataType.WEIGHT, fetchStart, fetchEnd, failures);
    final latest = <String, HealthDataPoint>{};
    for (final p in wPoints) {
      if (_num(p) == null) continue;
      final day = dayKey(p.dateFrom.toLocal());
      final prev = latest[day];
      if (prev == null || p.dateFrom.isAfter(prev.dateFrom)) latest[day] = p;
    }

    // ... then all the writes in ONE transaction (fast, keeps the app responsive).
    var hadData = false;
    var dayChanges = 0, workoutChanges = 0, weightChanges = 0;
    db.transaction(() {
      for (final e in agg.entries) {
        if (e.key.compareTo(firstKey) < 0 || e.key.compareTo(endKey) >= 0) continue;
        if (e.value.isEmpty) continue;
        hadData = true;
        // The Garmin export wins: a day that came from the export keeps its
        // values and Health Connect only adds what is still missing.
        final old = db.loadDailyMetrics(e.key, e.key)[e.key];
        final srcRows = db.raw
            .select('SELECT source FROM daily_metrics WHERE day = ?', [e.key]);
        final fromGarmin =
            srcRows.isNotEmpty && srcRows.first['source'] == 'garmin_export';
        Map<String, double> merged;
        if (old == null) {
          merged = e.value;
        } else if (fromGarmin) {
          final extra = Map<String, double>.from(e.value);
          // sleep is never mixed: if the export has this night, ignore ours
          if (old.containsKey('sleep_total')) {
            extra.removeWhere((k, v) => k.startsWith('sleep_'));
          }
          merged = {...extra, ...old};
        } else {
          merged = {...old, ...e.value};
        }
        if (db.saveDailyMetrics(e.key, merged,
            source: fromGarmin ? 'garmin_export' : 'health_connect')) {
          dayChanges++;
        }
      }
      for (final w in prepared) {
        hadData = true;
        if (db.importWorkout(w) != 'unchanged') workoutChanges++;
      }
      for (final e in latest.entries) {
        if (e.key.compareTo(firstKey) < 0 || e.key.compareTo(endKey) >= 0) continue;
        hadData = true;
        final kg = _num(e.value)!;
        if (kg < 20 || kg > 500) continue;
        final row = db.weightRow(e.key);
        if (row != null) {
          if (row['deleted'] == true) continue; // you deleted it: keep it deleted
          if (row['source'] == 'manual') continue; // never overwrite typed entries
          if (((row['kg'] as double) - kg).abs() < 0.05) continue;
        }
        db.saveWeight(e.key, kg, source: 'health_connect');
        weightChanges++;
      }
    });

    if (oddWorkouts > 0 && failures.length < 5) {
      failures.add('$oddWorkouts workout record(s) had an unexpected format and were skipped');
    }
    return _WindowResult(weightChanges, dayChanges, workoutChanges, hadData);
  }

  static Future<HealthImportResult> _run(
      {required int days,
      required bool request,
      void Function(String)? onProgress}) async {
    if (!supported) {
      return const HealthImportResult(
          error: 'Health Connect is only available on Android.');
    }
    try {
      await _ensureConfigured();
      String? note;
      if (request) {
        final types = _allTypes;
        final perms = List.filled(types.length, HealthDataAccess.READ);
        final granted =
            await _health.requestAuthorization(types, permissions: perms);
        if (!granted) {
          note = 'Not every permission was granted, so some data was skipped.';
        }
        // Without this, Health Connect only gives the last 30 days.
        try {
          if (!await _health.isHealthDataHistoryAuthorized()) {
            await _health.requestHealthDataHistoryAuthorization();
          }
        } catch (_) {}
        AppDb.instance.setSetting('hc_enabled', '1');
      }

      final db = AppDb.instance;
      final now = DateTime.now();
      final firstDay = DateTime(now.year, now.month, now.day - (days - 1));
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      final failures = <String>[];
      final seen = <String>{};

      // windows of 90 days, newest first, so recent data arrives first and a
      // very long import can be stopped without losing what is already stored
      const windowDays = 90;
      final windows = <List<DateTime>>[];
      var end = tomorrow;
      while (end.isAfter(firstDay)) {
        var start = DateTime(end.year, end.month, end.day - windowDays);
        if (start.isBefore(firstDay)) start = firstDay;
        windows.add([start, end]);
        end = start;
      }

      var weights = 0, dayChanges = 0, workoutChanges = 0, emptyStreak = 0;
      String? stoppedAt;
      for (var i = 0; i < windows.length; i++) {
        final start = windows[i][0], endEx = windows[i][1];
        onProgress?.call(
            'Importing ${dayKey(start)} to ${dayKey(endEx)}  (${i + 1} of ${windows.length})');
        final r = await _importWindow(db, start, endEx, now, failures, seen);
        weights += r.weights;
        dayChanges += r.days;
        workoutChanges += r.workouts;
        emptyStreak = r.hadData ? 0 : emptyStreak + 1;
        // Going back in time: after a year without any data, stop.
        if (emptyStreak >= 4 && i < windows.length - 1) {
          stoppedAt = dayKey(start);
          break;
        }
      }
      if (stoppedAt != null) {
        note = '${note ?? ''} No data found before $stoppedAt, so the import stopped there.'
            .trim();
      }
      if (request && failures.isNotEmpty) {
        note = '${note ?? ''} ${failures.length} request(s) failed, first: ${failures.first}'
            .trim();
      }
      return HealthImportResult(
        weights: weights,
        days: dayChanges,
        workouts: workoutChanges,
        note: note,
      );
    } catch (e) {
      return HealthImportResult(error: 'Health Connect import failed: $e');
    }
  }
}
