import 'dart:convert';
import 'package:http/http.dart' as http;
import 'db.dart';
import 'nutrients.dart';

class HevyResult {
  final int added, updated, merged, unchanged;
  final String? error;
  const HevyResult({
    this.added = 0,
    this.updated = 0,
    this.merged = 0,
    this.unchanged = 0,
    this.error,
  });

  int get changes => added + updated + merged;

  String get summary => error ??
      (changes == 0
          ? 'Hevy: nothing new ($unchanged already up to date).'
          : 'Hevy: $added new workout(s), $updated updated, '
              '$merged merged with sessions from another source.');
}

/// Reads your workouts straight from Hevy's API (Hevy Pro is required for an
/// API key: hevy.com, Settings, Developer). Read-only.
class HevySync {
  static const _base = 'https://api.hevyapp.com';
  static bool _running = false;

  static bool get configured =>
      (AppDb.instance.getSetting('hevy_api_key') ?? '').trim().isNotEmpty;

  static Future<Map<String, dynamic>> _get(
      String path, Map<String, String> query, String key) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final res = await http.get(
        Uri.parse('$_base$path').replace(queryParameters: query),
        headers: {'api-key': key, 'accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));
      if (res.statusCode == 429 && attempt < 3) {
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        continue;
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw Exception(
            'Hevy rejected the API key. It needs an active Hevy Pro subscription.');
      }
      if (res.statusCode != 200) {
        throw Exception('Hevy answered with status ${res.statusCode}.');
      }
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw Exception('Hevy is busy (too many requests). Try again in a minute.');
  }

  static DateTime? _time(dynamic v) {
    if (v is String) return DateTime.tryParse(v)?.toLocal();
    if (v is num) {
      final n = v.toInt();
      return DateTime.fromMillisecondsSinceEpoch(n > 100000000000 ? n : n * 1000);
    }
    return null;
  }

  static double? _d(dynamic v) =>
      v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

  static String _wt(double v) => rawNum((v * 10).round() / 10);

  static Workout? _toWorkout(Map<String, dynamic> j) {
    final id = j['id']?.toString();
    final start = _time(j['start_time']);
    if (id == null || start == null) return null;
    final parsedEnd = _time(j['end_time']);
    final DateTime end = (parsedEnd != null && parsedEnd.isAfter(start))
        ? parsedEnd
        : start.add(const Duration(minutes: 60));

    var sets = 0;
    var totalReps = 0.0;
    var volume = 0.0;
    var distM = 0.0;
    final lines = <String>[];
    final exList = <Map<String, dynamic>>[];
    for (final exRaw in ((j['exercises'] as List?) ?? const [])) {
      final ex = (exRaw as Map).cast<String, dynamic>();
      final name = (ex['title'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final labels = <String>[];
      final setObjs = <Map<String, dynamic>>[];
      var warm = 0;
      for (final sRaw in ((ex['sets'] as List?) ?? const [])) {
        final s = (sRaw as Map).cast<String, dynamic>();
        final st = (s['type'] ?? 'normal').toString();
        final kg = _d(s['weight_kg']);
        final reps = _d(s['reps']);
        final dist = _d(s['distance_meters']);
        final sec = _d(s['duration_seconds']);
        setObjs.add({
          'type': st,
          if (kg != null) 'kg': kg,
          if (reps != null) 'reps': reps,
          if (dist != null) 'km': dist / 1000,
          if (sec != null) 'sec': sec,
        });
        if (st == 'warmup') {
          warm++;
          continue;
        }
        sets++;
        if (reps != null) totalReps += reps;
        if (kg != null && reps != null) volume += kg * reps;
        if (dist != null) distM += dist;
        String label;
        if (kg != null && kg > 0 && reps != null) {
          label = '${_wt(kg)}×${reps.round()}';
        } else if (reps != null && reps > 0) {
          label = '${reps.round()} reps';
        } else if (dist != null && dist > 0) {
          label = '${_wt(dist / 1000)} km';
        } else if (sec != null && sec > 0) {
          label = '${sec.round()} s';
        } else {
          label = 'set';
        }
        if (st == 'failure') {
          label += ' (F)';
        } else if (st == 'dropset') {
          label += ' (drop)';
        }
        labels.add(label);
      }
      lines.add('$name: ${labels.join(', ')}${warm > 0 ? ' (+$warm warm-up)' : ''}');
      exList.add({'name': name, 'sets': setObjs});
    }
    final summary =
        'Sets: $sets, volume: ${fmt(volume)} kg${distM > 0 ? ', distance: ${fmt(distM / 1000)} km' : ''}';
    final desc = (j['description'] ?? '').toString().trim();
    return Workout(
      id: 'hevy:$id',
      day: dayKey(start),
      startMs: start.millisecondsSinceEpoch,
      endMs: end.millisecondsSinceEpoch,
      type: 'STRENGTH_TRAINING',
      title: (j['title'] ?? '').toString().trim(),
      distanceM: distM > 0 ? distM : null,
      source: 'hevy',
      notes: [summary, ...lines, if (desc.isNotEmpty) 'Note: $desc'].join('\n'),
      metrics: {
        'sets': sets.toDouble(),
        'reps': totalReps,
        'volume_kg': volume,
      },
      exercises: exList,
    );
  }

  /// Workouts you deleted in Hevy since [since]. Best effort: if this part of
  /// the API fails, nothing happens.
  static Future<void> _applyDeletions(DateTime since, String key) async {
    try {
      var page = 1, pages = 1;
      while (page <= pages && page <= 20) {
        final data = await _get(
            '/v1/workouts/events',
            {
              'page': '$page',
              'pageSize': '10',
              'since': since.toUtc().toIso8601String(),
            },
            key);
        pages = (data['page_count'] as num?)?.toInt() ?? 1;
        for (final e in ((data['events'] as List?) ?? const [])) {
          final m = (e as Map).cast<String, dynamic>();
          if (m['type'] != 'deleted') continue;
          final id = 'hevy:${m['id']}';
          final w = AppDb.instance.loadWorkout(id);
          if (w != null && !w.deleted && w.source == 'hevy') {
            AppDb.instance.deleteWorkout(id);
          }
        }
        page++;
      }
    } catch (_) {}
  }

  /// First sync (or [full]): all workouts. Later syncs: only what changed.
  static Future<HevyResult> sync({bool full = false}) async {
    if (_running) return const HevyResult(error: 'A Hevy sync is already running.');
    final db = AppDb.instance;
    final key = (db.getSetting('hevy_api_key') ?? '').trim();
    if (key.isEmpty) return const HevyResult(error: 'No Hevy API key yet.');
    _running = true;
    try {
      final lastIso = full ? null : db.getSetting('hevy_last_sync');
      final last = lastIso == null ? null : DateTime.tryParse(lastIso)?.toLocal();
      final started = DateTime.now();
      var added = 0, updated = 0, merged = 0, same = 0;

      var page = 1, pages = 1;
      while (page <= pages) {
        final data = await _get(
            '/v1/workouts', {'page': '$page', 'pageSize': '10'}, key);
        pages = (data['page_count'] as num?)?.toInt() ?? 1;
        var anyChanged = false;
        for (final raw in ((data['workouts'] as List?) ?? const [])) {
          final j = (raw as Map).cast<String, dynamic>();
          final upd = _time(j['updated_at']);
          if (last != null &&
              upd != null &&
              !upd.isAfter(last.subtract(const Duration(minutes: 5)))) {
            same++;
            continue; // not changed since the last sync
          }
          anyChanged = true;
          final w = _toWorkout(j);
          if (w == null) continue;
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
        // Newest first: a page with nothing new means the rest is old too.
        if (last != null && !anyChanged) break;
        page++;
      }
      if (last != null) await _applyDeletions(last, key);
      db.setSetting('hevy_last_sync', started.toIso8601String());
      return HevyResult(added: added, updated: updated, merged: merged, unchanged: same);
    } catch (e) {
      return HevyResult(error: e.toString().replaceFirst('Exception: ', ''));
    } finally {
      _running = false;
    }
  }

  /// Quiet sync at app start. Returns the number of changes.
  static Future<int> auto() async {
    if (!configured) return 0;
    final r = await sync();
    return r.changes;
  }
}
