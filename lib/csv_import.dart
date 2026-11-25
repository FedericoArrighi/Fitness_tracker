import 'dart:convert';
import 'dart:typed_data';
import 'db.dart';
import 'nutrients.dart';

/// Result of reading a CSV file: the workouts found, things worth telling the
/// user, or an error.
class CsvParseResult {
  final List<Workout> workouts;
  final List<String> warnings;
  final String? error;

  /// Examples of rows that could not be read, with the reason.
  final List<String> skips;
  const CsvParseResult(this.workouts, this.warnings,
      {this.error, this.skips = const []});
}

// ------------------------------------------------------------------
// generic helpers
// ------------------------------------------------------------------

String _delimiterOf(String line) {
  var best = ',';
  var bestN = -1;
  for (final d in [',', ';', '\t']) {
    final n = d.allMatches(line).length;
    if (n > bestN) {
      best = d;
      bestN = n;
    }
  }
  return best;
}

/// Small CSV reader: quotes, doubled quotes, comma / semicolon / tab,
/// line breaks inside quotes.
List<List<String>> parseCsv(String input) {
  var text = input;
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) text = text.substring(1);
  final nl = text.indexOf('\n');
  final delim = _delimiterOf(nl < 0 ? text : text.substring(0, nl));
  final rows = <List<String>>[];
  var row = <String>[];
  final sb = StringBuffer();
  var inQuotes = false;

  void endRow() {
    row.add(sb.toString());
    sb.clear();
    if (row.length > 1 || row[0].trim().isNotEmpty) rows.add(row);
    row = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        sb.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == delim) {
      row.add(sb.toString());
      sb.clear();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      endRow();
    } else {
      sb.write(ch);
    }
  }
  if (sb.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüßàèéìòù]'), '');

String _at(List<String> row, int? i) => (i != null && i < row.length) ? row[i] : '';

/// Numbers like 12.5, 12,5, 1,234, 1.234,5 or "5.2 km". Null for empty or "--".
double? _num(String? s) {
  if (s == null) return null;
  var t = s.trim();
  if (t.isEmpty || t == '--' || t == '-') return null;
  if (t.contains(',') && t.contains('.')) {
    if (t.lastIndexOf(',') > t.lastIndexOf('.')) {
      t = t.replaceAll('.', '').replaceAll(',', '.');
    } else {
      t = t.replaceAll(',', '');
    }
  } else if (RegExp(r'^\d{1,3}(,\d{3})+$').hasMatch(t)) {
    t = t.replaceAll(',', '');
  } else {
    t = t.replaceAll(',', '.');
  }
  final v = double.tryParse(t);
  if (v != null) return v;
  final m = RegExp(r'-?\d+(?:[.,]\d+)?').firstMatch(s);
  return m == null ? null : double.tryParse(m[0]!.replaceAll(',', '.'));
}

/// "1:05:30", "45:12" or plain seconds -> seconds
double? _seconds(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.isEmpty || t == '--') return null;
  final parts = t.split(':');
  if (parts.length < 2 || parts.length > 3) {
    return double.tryParse(t.replaceAll(',', '.'));
  }
  var total = 0.0;
  for (final p in parts) {
    final v = double.tryParse(p.replaceAll(',', '.'));
    if (v == null) return null;
    total = total * 60 + v;
  }
  return total;
}

String _canonType(String raw) => raw
    .trim()
    .toUpperCase()
    .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

// ------------------------------------------------------------------
// Garmin Connect "Export CSV" (list of activities)
// ------------------------------------------------------------------

DateTime? _garminDate(String s) {
  final t = s.trim();
  final iso = DateTime.tryParse(t.replaceFirst(' ', 'T'));
  if (iso != null) return iso;
  var m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})[ ,]+(\d{1,2}):(\d{2})(?::(\d{2}))?')
      .firstMatch(t);
  if (m != null) {
    return DateTime(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!),
        int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6] ?? '0'));
  }
  // 12/05/2024 07:15 or 05/12/2024 07:15: day first unless the numbers say otherwise
  m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})[ ,]+(\d{1,2}):(\d{2})(?::(\d{2}))?')
      .firstMatch(t);
  if (m != null) {
    final a = int.parse(m[1]!), b = int.parse(m[2]!);
    final day = (b > 12) ? b : a;
    final month = (b > 12) ? a : b;
    return DateTime(int.parse(m[3]!), month, day, int.parse(m[4]!),
        int.parse(m[5]!), int.parse(m[6] ?? '0'));
  }
  return null;
}

// column names (normalised) of the extra numbers in a Garmin export
const _garminMetricCols = <String, List<String>>{
  'te_aerobic': ['aerobicte'],
  'cadence_avg': ['avgruncadence', 'avgbikecadence'],
  'cadence_max': ['maxruncadence', 'maxbikecadence'],
  'ascent_m': ['totalascent'],
  'descent_m': ['totaldescent'],
  'stride_m': ['avgstridelength'],
  'vert_ratio': ['avgverticalratio'],
  'vert_osc': ['avgverticaloscillation'],
  'gct_ms': ['avggroundcontacttime'],
  'tss': ['trainingstressscore'],
  'power_avg': ['avgpower'],
  'power_max': ['maxpower'],
  'grit': ['grit'],
  'flow': ['flow'],
  'swolf': ['avgswolf'],
  'stroke_rate': ['avgstrokerate'],
  'reps': ['totalreps'],
  'sets': ['totalsets'],
  'laps': ['numberoflaps'],
  'elev_min': ['minelevation'],
  'elev_max': ['maxelevation'],
};

/// [miles] = the file was exported from an account that uses miles (and feet).
CsvParseResult parseGarminCsv(Uint8List bytes, {required bool miles}) {
  final rows = parseCsv(utf8.decode(bytes, allowMalformed: true));
  if (rows.length < 2) {
    return const CsvParseResult([], [], error: 'The file has no data rows.');
  }
  final header = rows.first.map(_norm).toList();
  final warnings = <String>[];
  final skips = <String>[];
  var assumed = false;

  int? find(List<String> names) {
    final i = header.indexWhere((h) => names.contains(h));
    return i >= 0 ? i : null;
  }

  int need(List<String> names, int fallback) {
    final i = find(names);
    if (i != null) return i;
    assumed = true;
    return fallback;
  }

  final iType = need(['activitytype', 'aktivitätstyp', 'aktivitaetstyp', 'tipodiattività'], 0);
  final iDate = need(['date', 'datum', 'data'], 1);
  final iTitle = need(['title', 'titel', 'titolo'], 3);
  final iDist = need(['distance', 'distanz', 'distanza'], 4);
  final iCal = need(['calories', 'kalorien', 'calorie'], 5);
  final iTime = find(['time', 'zeit', 'tempo', 'durata']) ??
      find(['elapsedtime']) ??
      find(['movingtime']) ??
      need([], 6);
  final iMoving = find(['movingtime']);
  final iElapsed = find(['elapsedtime']);
  final iBestLap = find(['bestlaptime']);
  final iAvgHr = find(['avghr', 'avgheartrate']);
  final iMaxHr = find(['maxhr', 'maxheartrate']);
  final metricCols = <String, int>{};
  _garminMetricCols.forEach((key, names) {
    final i = find(names);
    if (i != null) metricCols[key] = i;
  });
  if (assumed) {
    warnings.add('Some column names were not recognised, so the standard '
        'Garmin column order was assumed. Check the preview.');
  }
  if (metricCols.isEmpty && iAvgHr == null) {
    warnings.add('No detail columns (heart rate, cadence, ...) were recognised. '
        'This happens when the Garmin website is not set to English.');
  }

  final out = <Workout>[];
  var noDate = 0, noTime = 0, noType = 0;
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    String sample() => row.take(4).join(' | ');
    final start = _garminDate(_at(row, iDate));
    if (start == null) {
      noDate++;
      if (skips.length < 8) skips.add('Row ${r + 1}: no readable date (${sample()})');
      continue;
    }
    var secs = _seconds(_at(row, iTime));
    if (secs == null || secs <= 0) secs = _seconds(_at(row, iElapsed));
    if (secs == null || secs <= 0) secs = _seconds(_at(row, iMoving));
    if (secs == null || secs <= 0) {
      noTime++;
      if (skips.length < 8) skips.add('Row ${r + 1}: no duration (${sample()})');
      continue;
    }
    final type = _canonType(_at(row, iType));
    if (type.isEmpty) {
      noType++;
      if (skips.length < 8) skips.add('Row ${r + 1}: no activity type (${sample()})');
      continue;
    }

    double? meters;
    final d = _num(_at(row, iDist));
    if (d != null && d > 0) {
      if (type.contains('SWIM')) {
        // Swims are shown in meters (yards) in Garmin; below 20 it must be km (miles).
        meters = d < 20 ? d * (miles ? 1609.344 : 1000) : d * (miles ? 0.9144 : 1);
      } else {
        meters = d * (miles ? 1609.344 : 1000);
      }
    }

    final metrics = <String, double>{};
    void put(String k, double? v) {
      if (v != null) metrics[k] = v;
    }

    put('avg_hr', _num(_at(row, iAvgHr)));
    put('max_hr', _num(_at(row, iMaxHr)));
    metricCols.forEach((key, i) {
      var v = _num(_at(row, i));
      if (v != null && miles && (key == 'ascent_m' || key == 'descent_m' || key.startsWith('elev_'))) {
        v = v * 0.3048; // feet -> meters
      }
      put(key, v);
    });
    put('moving_s', _seconds(_at(row, iMoving)));
    put('elapsed_s', _seconds(_at(row, iElapsed)));
    put('best_lap_s', _seconds(_at(row, iBestLap)));

    out.add(Workout(
      id: 'gcsv:${_at(row, iDate).trim()}|$type',
      day: dayKey(start),
      startMs: start.millisecondsSinceEpoch,
      endMs: start.add(Duration(seconds: secs.round())).millisecondsSinceEpoch,
      type: type,
      title: _at(row, iTitle).trim(),
      distanceM: meters,
      activeKcal: _num(_at(row, iCal)),
      source: 'garmin_csv',
      metrics: metrics,
    ));
  }
  if (noDate > 0) warnings.add('$noDate row(s) skipped: no readable date.');
  if (noTime > 0) warnings.add('$noTime row(s) skipped: no duration.');
  if (noType > 0) warnings.add('$noType row(s) skipped: no activity type.');
  warnings.add('Calories in a Garmin file are total calories, including resting.');
  if (out.isEmpty) {
    return CsvParseResult([], warnings,
        error: 'No activities found. Columns in the file: ${rows.first.join(', ')}',
        skips: skips);
  }
  return CsvParseResult(out, warnings, skips: skips);
}

// ------------------------------------------------------------------
// Hevy "Export workouts" (one row per set)
// ------------------------------------------------------------------

DateTime? _hevyDate(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  const months = [
    'jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'
  ];
  // "27 Jul 2025, 18:57"
  var m = RegExp(r'^(\d{1,2})\s+([A-Za-z]{3})[A-Za-z]*\.?,?\s+(\d{4}),?\s+(\d{1,2}):(\d{2})')
      .firstMatch(t);
  if (m != null) {
    final mo = months.indexOf(m[2]!.toLowerCase());
    if (mo >= 0) {
      return DateTime(int.parse(m[3]!), mo + 1, int.parse(m[1]!),
          int.parse(m[4]!), int.parse(m[5]!));
    }
  }
  // "Jul 27, 2025, 18:57"
  m = RegExp(r'^([A-Za-z]{3})[A-Za-z]*\.?\s+(\d{1,2}),?\s+(\d{4}),?\s+(\d{1,2}):(\d{2})')
      .firstMatch(t);
  if (m != null) {
    final mo = months.indexOf(m[1]!.toLowerCase());
    if (mo >= 0) {
      return DateTime(int.parse(m[3]!), mo + 1, int.parse(m[2]!),
          int.parse(m[4]!), int.parse(m[5]!));
    }
  }
  return DateTime.tryParse(t.replaceFirst(' ', 'T'));
}

String _w(double v) => rawNum((v * 10).round() / 10);

CsvParseResult parseHevyCsv(Uint8List bytes) {
  final rows = parseCsv(utf8.decode(bytes, allowMalformed: true));
  if (rows.length < 2) {
    return const CsvParseResult([], [], error: 'The file has no data rows.');
  }
  final header = rows.first.map(_norm).toList();
  int? idx(List<String> names) {
    final i = header.indexWhere((h) => names.contains(h));
    return i < 0 ? null : i;
  }

  final iTitle = idx(['title']);
  final iStart = idx(['starttime']);
  final iEnd = idx(['endtime']);
  final iEx = idx(['exercisetitle']);
  final iSetType = idx(['settype']);
  final iKg = idx(['weightkg']);
  final iLb = idx(['weightlbs']);
  final iReps = idx(['reps']);
  final iKm = idx(['distancekm']);
  final iMi = idx(['distancemiles']);
  final iSec = idx(['durationseconds']);
  final iRpe = idx(['rpe']);
  if (iTitle == null || iStart == null || iEx == null) {
    return CsvParseResult([], [],
        error: 'This does not look like a Hevy export. Columns in the file: ${rows.first.join(', ')}');
  }

  // one workout = all rows with the same start time and title
  final groups = <String, List<List<String>>>{};
  for (var r = 1; r < rows.length; r++) {
    final row = rows[r];
    final key = '${_at(row, iStart).trim()}|${_at(row, iTitle).trim()}';
    groups.putIfAbsent(key, () => []).add(row);
  }

  final out = <Workout>[];
  final skips = <String>[];
  var badDate = 0;
  groups.forEach((key, gr) {
    final first = gr.first;
    final start = _hevyDate(_at(first, iStart));
    if (start == null) {
      badDate++;
      if (skips.length < 8) skips.add('Workout "${_at(first, iTitle)}": unreadable start time "${_at(first, iStart)}"');
      return;
    }
    final parsedEnd = iEnd == null ? null : _hevyDate(_at(first, iEnd));
    final DateTime end = (parsedEnd != null && parsedEnd.isAfter(start))
        ? parsedEnd
        : start.add(const Duration(minutes: 60));

    final order = <String>[];
    final exSets = <String, List<String>>{};
    final exData = <String, List<Map<String, dynamic>>>{};
    final warm = <String, int>{};
    var sets = 0;
    var totalReps = 0.0;
    var volume = 0.0;
    var distKm = 0.0;
    var rpeSum = 0.0, rpeN = 0;
    for (final row in gr) {
      final ex = _at(row, iEx).trim();
      if (ex.isEmpty) continue;
      if (!exSets.containsKey(ex)) {
        order.add(ex);
        exSets[ex] = [];
        exData[ex] = [];
      }
      final st = _at(row, iSetType).trim().toLowerCase();
      var kg = _num(_at(row, iKg));
      if (kg == null) {
        final lb = _num(_at(row, iLb));
        if (lb != null) kg = lb * 0.45359237;
      }
      final reps = _num(_at(row, iReps));
      var km = _num(_at(row, iKm));
      if (km == null) {
        final mi = _num(_at(row, iMi));
        if (mi != null) km = mi * 1.609344;
      }
      final sec = _num(_at(row, iSec));
      final rpe = _num(_at(row, iRpe));
      exData[ex]!.add({
        'type': st.isEmpty ? 'normal' : st,
        'kg': ?kg,
        'reps': ?reps,
        'km': ?km,
        'sec': ?sec,
        if (rpe != null && rpe > 0) 'rpe': rpe,
      });
      if (st == 'warmup') {
        warm[ex] = (warm[ex] ?? 0) + 1;
        continue;
      }
      sets++;
      if (reps != null) totalReps += reps;
      if (kg != null && reps != null) volume += kg * reps;
      if (km != null) distKm += km;
      if (rpe != null && rpe > 0) {
        rpeSum += rpe;
        rpeN++;
      }
      String label;
      if (kg != null && kg > 0 && reps != null) {
        label = '${_w(kg)}×${reps.round()}';
      } else if (reps != null && reps > 0) {
        label = '${reps.round()} reps';
      } else if (km != null && km > 0) {
        label = '${_w(km)} km';
      } else if (sec != null && sec > 0) {
        label = '${sec.round()} s';
      } else {
        label = 'set';
      }
      if (rpe != null && rpe > 0) label += ' @${_w(rpe)}';
      if (st == 'failure') {
        label += ' (F)';
      } else if (st == 'dropset') {
        label += ' (drop)';
      }
      exSets[ex]!.add(label);
    }

    final lines = <String>[
      'Sets: $sets, volume: ${fmt(volume)} kg${distKm > 0 ? ', distance: ${fmt(distKm)} km' : ''}',
      for (final ex in order)
        '$ex: ${exSets[ex]!.join(', ')}${(warm[ex] ?? 0) > 0 ? ' (+${warm[ex]} warm-up)' : ''}',
    ];
    out.add(Workout(
      id: 'hevy:$key',
      day: dayKey(start),
      startMs: start.millisecondsSinceEpoch,
      endMs: end.millisecondsSinceEpoch,
      type: 'STRENGTH_TRAINING',
      title: _at(first, iTitle).trim(),
      distanceM: distKm > 0 ? distKm * 1000 : null,
      source: 'hevy',
      notes: lines.join('\n'),
      metrics: {
        'sets': sets.toDouble(),
        'reps': totalReps,
        'volume_kg': volume,
        if (rpeN > 0) 'rpe': rpeSum / rpeN,
      },
      exercises: [
        for (final ex in order) {'name': ex, 'sets': exData[ex]!}
      ],
    ));
  });

  final warnings = <String>[
    if (badDate > 0) '$badDate workout(s) skipped: unreadable start time.',
    'Weights are read as kg, or converted from lbs if the file uses lbs.',
    'Warm-up sets are listed but not counted in sets and volume.',
  ];
  if (out.isEmpty) {
    return CsvParseResult([], warnings,
        error: 'No workouts found in this file.', skips: skips);
  }
  return CsvParseResult(out, warnings, skips: skips);
}
