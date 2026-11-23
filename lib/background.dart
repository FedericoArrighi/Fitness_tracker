import 'dart:isolate';
import 'dart:typed_data';
import 'csv_import.dart';
import 'db.dart';
import 'garmin_export.dart';

// Heavy work runs in a background isolate, so the app never freezes.

/// Reads a CSV file without blocking the screen.
Future<CsvParseResult> parseCsvInBackground({
  required bool garmin,
  required Uint8List bytes,
  required bool miles,
}) =>
    Isolate.run(() =>
        garmin ? parseGarminCsv(bytes, miles: miles) : parseHevyCsv(bytes));

class ImportCounts {
  final int added, updated, merged, unchanged;
  const ImportCounts(this.added, this.updated, this.merged, this.unchanged);
}

/// Stores workouts in one fast transaction, in a background isolate with its
/// own connection to the database file.
Future<ImportCounts> importWorkoutsInBackground(List<Workout> workouts) {
  final path = AppDb.instance.path;
  return Isolate.run(() {
    AppDb.initAt(path);
    final db = AppDb.instance;
    var added = 0, updated = 0, merged = 0, same = 0;
    db.transaction(() {
      for (final w in workouts) {
        switch (db.importWorkout(w)) {
          case 'added':
            added++;
            break;
          case 'updated':
            updated++;
            break;
          case 'merged':
            merged++;
            break;
          default:
            same++;
        }
      }
    });
    return ImportCounts(added, updated, merged, same);
  }).then((c) {
    AppDb.instance.invalidateWorkouts(); // the data changed behind our back
    return c;
  });
}

/// Reads the chosen Garmin export files without blocking the screen.
Future<GarminExportResult> parseGarminExportInBackground(
        Map<String, Uint8List> files) =>
    Isolate.run(() => parseGarminExport(files));

class GarminImportCounts {
  final ImportCounts workouts;
  final int daysAdded, daysFilled;
  const GarminImportCounts(this.workouts, this.daysAdded, this.daysFilled);
}

/// Stores workouts and daily numbers of a Garmin export. For a day that
/// already has data (e.g. from Health Connect), only keys that are still
/// missing are added; existing values are never overwritten.
Future<GarminImportCounts> importGarminExportInBackground(
    List<Workout> workouts, Map<String, Map<String, double>> days,
    {List<List<double>> kcalFixes = const []}) {
  final path = AppDb.instance.path;
  return Isolate.run(() {
    AppDb.initAt(path);
    final db = AppDb.instance;
    var added = 0, updated = 0, merged = 0, same = 0;
    var daysAdded = 0, daysFilled = 0;
    final existing = db.loadDailyMetrics('1900-01-01', '9999-12-31');
    final sources = <String, String>{
      for (final r in db.raw.select('SELECT day, source FROM daily_metrics'))
        r['day'] as String: r['source'] as String
    };
    db.transaction(() {
      // calories that the first version of this importer stored as kilojoules
      for (final f in kcalFixes) {
        db.raw.execute(
            'UPDATE workouts SET active_kcal = ?, updated_at = ? WHERE deleted = 0 '
            'AND start_ms < ? AND end_ms > ? AND active_kcal IS NOT NULL '
            'AND ABS(active_kcal - ?) < 0.01 AND ABS(active_kcal - ?) > 0.01',
            [f[3], nowMs(), f[1].toInt(), f[0].toInt(), f[2], f[3]]);
      }
      for (final w in workouts) {
        switch (db.importWorkout(w)) {
          case 'added':
            added++;
            break;
          case 'updated':
            updated++;
            break;
          case 'merged':
            merged++;
            break;
          default:
            same++;
        }
      }
      days.forEach((day, m) {
        final old = existing[day];
        if (old == null) {
          if (db.saveDailyMetrics(day, m, source: 'garmin_export')) daysAdded++;
        } else {
          final src = sources[day] ?? 'health_connect';
          final base = Map<String, double>.from(old);
          // impossible sleep (over 14 h) is dropped and replaced by the export
          if ((base['sleep_total'] ?? 0) > 840) {
            base.removeWhere((k, v) => k.startsWith('sleep_'));
          }
          // days made by this importer are refreshed, others only completed
          final next = src == 'garmin_export' ? {...base, ...m} : {...m, ...base};
          if (db.saveDailyMetrics(day, next, source: src)) daysFilled++;
        }
      });
      // days with impossible sleep that the export does not cover: drop it
      existing.forEach((day, old) {
        if (days.containsKey(day) || (old['sleep_total'] ?? 0) <= 840) return;
        final base = Map<String, double>.from(old)
          ..removeWhere((k, v) => k.startsWith('sleep_'));
        if (base.isEmpty) return;
        if (db.saveDailyMetrics(day, base, source: sources[day] ?? 'health_connect')) {
          daysFilled++;
        }
      });
    });
    return GarminImportCounts(
        ImportCounts(added, updated, merged, same), daysAdded, daysFilled);
  }).then((c) {
    AppDb.instance.invalidateWorkouts();
    return c;
  });
}
