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
    HealthDataType.WORKOUT,
  ];

  static List<HealthDataType> get _allTypes => [
        HealthDataType.WEIGHT,
        HealthDataType.STEPS,
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

  /// Asks for permission if needed, then imports the last [days] days.
  static Future<HealthImportResult> importAll({int days = 30}) =>
      _run(days: days, request: true);

  /// Silent import at app start. Does nothing unless an import worked before.
  /// Returns the number of changes.
  static Future<int> autoImport() async {
    if (!supported || AppDb.instance.getSetting('hc_enabled') != '1') return 0;
    final r = await _run(days: 14, request: false);
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

  static Future<HealthImportResult> _run(
      {required int days, required bool request}) async {
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
      final startDay = DateTime(now.year, now.month, now.day - (days - 1));
      // one extra day before, because a night belongs to the day you wake up
      final fetchStart = DateTime(startDay.year, startDay.month, startDay.day - 1);
      final failures = <String>[];
      final seen = <String>{};

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

      void process(HealthDataType type, List<HealthDataPoint> points) {
        points.sort((a, b) => a.dateFrom.compareTo(b.dateFrom));
        for (final p in points) {
          if (!seen.add('${type.name}:${p.uuid}')) continue; // slice overlap
          if (type == HealthDataType.WORKOUT) {
            final v = p.value;
            if (v is! WorkoutHealthValue) continue;
            workouts.add(Workout(
              id: 'hc:${p.uuid}',
              day: dayKey(p.dateFrom),
              startMs: p.dateFrom.millisecondsSinceEpoch,
              endMs: p.dateTo.millisecondsSinceEpoch,
              type: v.workoutActivityType.name,
              distanceM: v.totalDistance?.toDouble(),
              activeKcal: v.totalEnergyBurned?.toDouble(),
              source: 'health_connect',
            ));
            continue;
          }
          final n = _num(p);
          final day = dayKey(p.dateFrom);
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
            }[type];
            if (key != null && minutes > 0) add(sleepDay(p.dateFrom), key, minutes);
          }
        }
      }

      DateTime nextSlice(DateTime s, int n) => DateTime(s.year, s.month, s.day + n);

      // dense types: slices of 7 days
      for (final type in _denseTypes) {
        for (var s = fetchStart; s.isBefore(now); s = nextSlice(s, 7)) {
          final e = nextSlice(s, 7);
          process(type, await _fetch(type, s, e.isAfter(now) ? now : e, failures));
        }
      }
      // other types: slices of 60 days
      for (final type in _otherTypes) {
        for (var s = fetchStart; s.isBefore(now); s = nextSlice(s, 60)) {
          final e = nextSlice(s, 60);
          process(type, await _fetch(type, s, e.isAfter(now) ? now : e, failures));
        }
      }

      // steps: one total per day (Health Connect removes double counting)
      for (var i = 0; i < days; i++) {
        final d0 = DateTime(startDay.year, startDay.month, startDay.day + i);
        final d1 = DateTime(d0.year, d0.month, d0.day + 1);
        try {
          final steps =
              await _health.getTotalStepsInInterval(d0, d1.isAfter(now) ? now : d1);
          if (steps != null && steps > 0) put(dayKey(d0), 'steps', steps.toDouble());
        } catch (e) {
          if (failures.length < 3) failures.add('steps: $e');
          break;
        }
      }

      // sleep total = all sleeping stages
      for (final m in agg.values) {
        final unspecified = m.remove('sleep_unspecified') ?? 0;
        if (m.containsKey('sleep_deep') ||
            m.containsKey('sleep_light') ||
            m.containsKey('sleep_rem') ||
            unspecified > 0) {
          m['sleep_total'] = (m['sleep_deep'] ?? 0) +
              (m['sleep_light'] ?? 0) +
              (m['sleep_rem'] ?? 0) +
              unspecified;
        }
      }

      // store (only days inside the requested window)
      final firstKey = dayKey(startDay);
      var dayChanges = 0;
      for (final e in agg.entries) {
        if (e.key.compareTo(firstKey) < 0 || e.value.isEmpty) continue;
        if (db.saveDailyMetrics(e.key, e.value)) dayChanges++;
      }
      var workoutChanges = 0;
      for (final w in workouts) {
        if (w.day.compareTo(firstKey) < 0) continue;
        final old = db.loadWorkout(w.id);
        if (old != null && (old.deleted || old.source == 'manual')) continue;
        if (old != null && old.sameAs(w)) continue;
        db.saveWorkout(w);
        workoutChanges++;
      }

      // weight: the last measurement of each day
      var weightChanges = 0;
      final wPoints = await _fetch(HealthDataType.WEIGHT, fetchStart, now, failures);
      final latest = <String, HealthDataPoint>{};
      for (final p in wPoints) {
        if (_num(p) == null) continue;
        final day = dayKey(p.dateFrom);
        final prev = latest[day];
        if (prev == null || p.dateFrom.isAfter(prev.dateFrom)) latest[day] = p;
      }
      for (final e in latest.entries) {
        if (e.key.compareTo(firstKey) < 0) continue;
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

      if (request && failures.isNotEmpty) {
        note = '${note ?? ''} ${failures.length} request(s) failed, first: ${failures.first}'.trim();
      }
      return HealthImportResult(
        weights: weightChanges,
        days: dayChanges,
        workouts: workoutChanges,
        note: note,
      );
    } catch (e) {
      return HealthImportResult(error: 'Health Connect import failed: $e');
    }
  }
}
