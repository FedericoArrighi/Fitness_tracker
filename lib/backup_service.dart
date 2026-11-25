import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'db.dart';
import 'workout_types.dart';

class BackupFile {
  final String path;
  final int bytes;
  final DateTime modified;
  const BackupFile(this.path, this.bytes, this.modified);
  String get name => p.basename(path);
}

class ExportResult {
  final String folder;
  final Map<String, int> rows; // file name -> number of rows
  const ExportResult(this.folder, this.rows);
}

/// Copies of the database (made while the app is running), restoring one,
/// and an export of your data as CSV files that open in Excel.
class BackupService {
  static Future<Directory> folder() async {
    var base = (await getApplicationDocumentsDirectory()).path;
    if (Platform.isAndroid) {
      // visible from a computer over USB: Android/data/<app>/files
      final ext = await getExternalStorageDirectory();
      if (ext != null) base = ext.path;
    }
    final d = Directory(p.join(base, 'MacroTrackerBackups'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static String _stamp(DateTime d) {
    String t(int v) => v.toString().padLeft(2, '0');
    return '${d.year}${t(d.month)}${t(d.day)}_${t(d.hour)}${t(d.minute)}${t(d.second)}';
  }

  /// Makes a consistent copy of the database. [prefix] says why
  /// ('manual', 'auto', 'before_restore').
  static Future<String> backupNow({String prefix = 'manual'}) async {
    final dir = await folder();
    final target = p.join(dir.path, '${prefix}_macro_tracker_${_stamp(DateTime.now())}.db');
    final src = AppDb.instance.path;
    await Isolate.run(() {
      final db = sqlite3.open(src);
      try {
        try {
          db.execute('VACUUM INTO ?', [target]);
        } catch (_) {
          // an older SQLite: flush the log, then copy the file
          db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
          File(src).copySync(target);
        }
      } finally {
        db.close();
      }
    });
    return target;
  }

  /// One automatic copy per day; the 7 newest are kept.
  static Future<void> autoBackup() async {
    try {
      final db = AppDb.instance;
      final today = dayKey(DateTime.now());
      if (db.getSetting('auto_backup_day') == today) return;
      await backupNow(prefix: 'auto');
      db.setSetting('auto_backup_day', today);
      final autos = (await list()).where((b) => b.name.startsWith('auto_')).toList();
      for (final old in autos.skip(7)) {
        try {
          File(old.path).deleteSync();
        } catch (_) {}
      }
    } catch (_) {
      // a failed automatic backup must never disturb the app
    }
  }

  /// All backups, newest first.
  static Future<List<BackupFile>> list() async {
    final dir = await folder();
    final out = <BackupFile>[];
    for (final e in dir.listSync()) {
      if (e is File && e.path.endsWith('.db')) {
        final st = e.statSync();
        out.add(BackupFile(e.path, st.size, st.modified));
      }
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  static void delete(BackupFile b) {
    try {
      File(b.path).deleteSync();
    } catch (_) {}
  }

  /// Opens a folder in the file manager (desktop only).
  static Future<void> openFolder(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      }
    } catch (_) {}
  }

  // ---------- restore ----------

  static bool _looksRight(String path) {
    try {
      final db = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        final r = db.select(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('foods', 'workouts')");
        return r.length == 2;
      } finally {
        db.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Prepares a restore. The file is swapped in the next time the app starts
  /// (the database is open now). Returns an error text, or null if all is ready.
  static Future<String?> scheduleRestoreFromFile(String sourcePath) async {
    if (!_looksRight(sourcePath)) {
      return 'This file is not a Macro Tracker database backup.';
    }
    try {
      await backupNow(prefix: 'before_restore'); // safety copy of what you have now
      File(sourcePath).copySync('${AppDb.instance.path}.restore');
      return null;
    } catch (e) {
      return 'Could not prepare the restore: $e';
    }
  }

  static Future<String?> scheduleRestoreFromBytes(Uint8List bytes) async {
    try {
      final tmp = File(p.join((await folder()).path, 'incoming_restore.tmp'));
      tmp.writeAsBytesSync(bytes);
      final err = await scheduleRestoreFromFile(tmp.path);
      tmp.deleteSync();
      return err;
    } catch (e) {
      return 'Could not read the file: $e';
    }
  }

  static bool get restorePending => File('${AppDb.instance.path}.restore').existsSync();

  static void cancelRestore() {
    final f = File('${AppDb.instance.path}.restore');
    if (f.existsSync()) f.deleteSync();
  }

  // ---------- export ----------

  /// Writes CSV files of your data into a new folder next to the backups.
  static Future<ExportResult> exportCsv() async {
    final dir = await folder();
    final out = Directory(p.join(dir.path, 'export_${_stamp(DateTime.now())}'));
    out.createSync(recursive: true);
    final dbPath = AppDb.instance.path;
    final outPath = out.path;
    final rows = await Isolate.run(() => _writeCsvFiles(dbPath, outPath));
    return ExportResult(outPath, rows);
  }
}

String _csv(Object? v) {
  if (v == null) return '';
  final s = v is double
      ? (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(3))
      : v.toString();
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains(';')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

Map<String, int> _writeCsvFiles(String dbPath, String outPath) {
  AppDb.initAt(dbPath);
  final db = AppDb.instance;
  final counts = <String, int>{};

  void write(String name, List<String> header, List<List<Object?>> rows) {
    final sb = StringBuffer('\uFEFF'); // so that Excel reads the accents right
    sb.writeln(header.join(','));
    for (final r in rows) {
      sb.writeln(r.map(_csv).join(','));
    }
    File(p.join(outPath, name)).writeAsStringSync(sb.toString());
    counts[name] = rows.length;
  }

  // workouts
  final all = db.loadAllWorkouts(withEx: true);
  final wRows = <List<Object?>>[];
  final setRows = <List<Object?>>[];
  for (final w in all) {
    final m = w.metrics;
    wRows.add([
      w.id,
      w.day,
      DateTime.fromMillisecondsSinceEpoch(w.startMs).toIso8601String(),
      w.type,
      catLabel(categoryOf(w.type)),
      w.title,
      w.minutes,
      w.distanceM == null ? null : w.distanceM! / 1000,
      w.activeKcal,
      m['avg_hr'],
      m['max_hr'],
      m['rpe'],
      m['sets'],
      m['reps'],
      m['volume_kg'],
      m['ascent_m'],
      w.source,
    ]);
    for (final ex in w.exercises) {
      var n = 0;
      for (final s in ((ex['sets'] as List?) ?? const [])) {
        final sm = (s as Map).cast<String, dynamic>();
        n++;
        setRows.add([
          w.day,
          w.title,
          ex['name'],
          n,
          sm['type'] ?? 'normal',
          sm['kg'],
          sm['reps'],
          sm['rpe'],
        ]);
      }
    }
  }
  write('workouts.csv', [
    'id', 'day', 'start', 'type', 'category', 'title', 'minutes', 'distance_km',
    'active_kcal', 'avg_hr', 'max_hr', 'rpe', 'sets', 'reps', 'volume_kg',
    'ascent_m', 'source'
  ], wRows);
  write('gym_sets.csv',
      ['day', 'workout', 'exercise', 'set_no', 'set_type', 'kg', 'reps', 'rpe'], setRows);

  // laps (loaded one by one: they are not in the list view)
  final lapRows = <List<Object?>>[];
  for (final w in all) {
    if (categoryOf(w.type) == Cat.strength) continue;
    final full = db.loadWorkout(w.id);
    if (full == null) continue;
    for (final l in full.splits) {
      lapRows.add([w.day, w.title, w.type, l['i'], l['d'], l['s'], l['hr'], l['cd'], l['pw']]);
    }
  }
  write('laps.csv',
      ['day', 'workout', 'type', 'lap', 'distance_m', 'seconds', 'avg_hr', 'cadence', 'power_w'],
      lapRows);

  // weight
  write('weights.csv', ['day', 'kg'],
      [for (final w in db.loadWeights('1900-01-01')) [w.day, w.kg]]);

  // daily numbers (steps, sleep, ...): one column per kind of number
  final daily = db.loadDailyMetrics('1900-01-01', '9999-12-31');
  final keys = <String>{for (final m in daily.values) ...m.keys}.toList()..sort();
  final days = daily.keys.toList()..sort();
  write('daily_metrics.csv', ['day', ...keys],
      [for (final d in days) [d, for (final k in keys) daily[d]![k]]]);

  // food log with the main nutrients
  final foodRows = <List<Object?>>[];
  final rs = db.raw.select(
      'SELECT e.day, e.meal, f.name, e.grams, '
      "(SELECT amount FROM food_nutrients n WHERE n.food_id = f.id AND n.nutrient = 'calories') AS kcal, "
      "(SELECT amount FROM food_nutrients n WHERE n.food_id = f.id AND n.nutrient = 'protein') AS protein, "
      "(SELECT amount FROM food_nutrients n WHERE n.food_id = f.id AND n.nutrient = 'carbs') AS carbs, "
      "(SELECT amount FROM food_nutrients n WHERE n.food_id = f.id AND n.nutrient = 'fat') AS fat "
      'FROM log_entries e JOIN foods f ON f.id = e.food_id '
      'WHERE e.deleted = 0 ORDER BY e.day, e.rowid');
  for (final r in rs) {
    final g = (r['grams'] as num).toDouble();
    double? per(Object? v) => v == null ? null : (v as num).toDouble() * g / 100;
    foodRows.add([
      r['day'],
      r['meal'],
      r['name'],
      g,
      per(r['kcal']),
      per(r['protein']),
      per(r['carbs']),
      per(r['fat']),
    ]);
  }
  write('food_log.csv',
      ['day', 'meal', 'food', 'grams', 'kcal', 'protein_g', 'carbs_g', 'fat_g'], foodRows);
  return counts;
}
