import 'dart:isolate';
import 'dart:typed_data';
import 'csv_import.dart';
import 'db.dart';

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
