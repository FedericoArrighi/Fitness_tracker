import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import 'db.dart';

/// One synchronised record: a food (with its nutrients), a log entry, a
/// recipe (with its ingredients), a weight, or the targets.
class SyncRecord {
  final String tbl;
  final String id;
  final int updatedAt;
  final bool deleted;
  final Map<String, dynamic> data;
  SyncRecord(this.tbl, this.id, this.updatedAt, this.deleted, this.data);

  Map<String, dynamic> toJson() => {
        'tbl': tbl,
        'id': id,
        'updated_at': updatedAt,
        'deleted': deleted,
        'data': data,
      };

  factory SyncRecord.fromJson(Map<String, dynamic> j) => SyncRecord(
        j['tbl'] as String,
        j['id'] as String,
        (j['updated_at'] as num).toInt(),
        j['deleted'] == true || j['deleted'] == 1,
        (j['data'] as Map).cast<String, dynamic>(),
      );
}

/// Reads "what changed here" from the database and writes "what changed
/// elsewhere" into it. The table sync_meta remembers, per record, the
/// updated_at value the server already has; a record is "dirty" (needs
/// sending) when its updated_at is newer than that.
class SyncStore {
  static Database get _db => AppDb.instance.raw;

  static void ensureTables() {
    _db.execute('CREATE TABLE IF NOT EXISTS sync_meta ('
        'tbl TEXT NOT NULL, id TEXT NOT NULL, pushed_at INTEGER NOT NULL, '
        'PRIMARY KEY (tbl, id))');
  }

  static const _known = {
    'foods',
    'log_entries',
    'recipes',
    'weights',
    'targets',
    'daily_metrics',
    'workouts',
    'user_items',
  };

  // ------------------------------------------------------------------
  // collect what has to be sent
  // ------------------------------------------------------------------

  static List<SyncRecord> collectDirty() {
    final out = <SyncRecord>[];

    // foods, including the hidden food rows of recipes
    for (final r in _db.select(
        'SELECT f.id, f.name, f.updated_at, f.deleted, f.recipe_id FROM foods f '
        "LEFT JOIN sync_meta m ON m.tbl = 'foods' AND m.id = f.id "
        'WHERE m.pushed_at IS NULL OR f.updated_at > m.pushed_at')) {
      final id = r['id'] as String;
      final values = <String, dynamic>{};
      for (final n in _db.select(
          'SELECT nutrient, amount FROM food_nutrients WHERE food_id = ?',
          [id])) {
        values[n['nutrient'] as String] = (n['amount'] as num).toDouble();
      }
      out.add(SyncRecord('foods', id, r['updated_at'] as int,
          (r['deleted'] as int) == 1, {
        'name': r['name'],
        'recipe_id': r['recipe_id'],
        'values': values,
      }));
    }

    // log entries
    for (final r in _db.select(
        'SELECT e.id, e.day, e.meal, e.food_id, e.grams, e.updated_at, e.deleted '
        'FROM log_entries e '
        "LEFT JOIN sync_meta m ON m.tbl = 'log_entries' AND m.id = e.id "
        'WHERE m.pushed_at IS NULL OR e.updated_at > m.pushed_at')) {
      out.add(SyncRecord('log_entries', r['id'] as String,
          r['updated_at'] as int, (r['deleted'] as int) == 1, {
        'day': r['day'],
        'meal': r['meal'],
        'food_id': r['food_id'],
        'grams': (r['grams'] as num).toDouble(),
      }));
    }

    // recipes
    for (final r in _db.select(
        'SELECT c.id, c.name, c.servings, c.cooked_grams, c.steps, c.notes, '
        'c.tags, c.updated_at, c.deleted FROM recipes c '
        "LEFT JOIN sync_meta m ON m.tbl = 'recipes' AND m.id = c.id "
        'WHERE m.pushed_at IS NULL OR c.updated_at > m.pushed_at')) {
      final id = r['id'] as String;
      final ings = <Map<String, dynamic>>[];
      for (final i in _db.select(
          'SELECT food_id, grams FROM recipe_ingredients '
          'WHERE recipe_id = ? ORDER BY position',
          [id])) {
        ings.add({
          'food_id': i['food_id'],
          'grams': (i['grams'] as num).toDouble(),
        });
      }
      out.add(SyncRecord('recipes', id, r['updated_at'] as int,
          (r['deleted'] as int) == 1, {
        'name': r['name'],
        'servings': (r['servings'] as num).toDouble(),
        'cooked_grams': r['cooked_grams'],
        'steps': r['steps'],
        'notes': r['notes'],
        'tags': r['tags'],
        'ingredients': ings,
      }));
    }

    // weights (the day is the id)
    for (final r in _db.select(
        'SELECT w.day, w.kg, w.source, w.updated_at, w.deleted FROM weights w '
        "LEFT JOIN sync_meta m ON m.tbl = 'weights' AND m.id = w.day "
        'WHERE m.pushed_at IS NULL OR w.updated_at > m.pushed_at')) {
      out.add(SyncRecord('weights', r['day'] as String, r['updated_at'] as int,
          (r['deleted'] as int) == 1, {
        'kg': (r['kg'] as num).toDouble(),
        'source': r['source'],
      }));
    }

    // daily activity metrics (the day is the id)
    for (final r in _db.select(
        'SELECT d.day, d.data, d.source, d.updated_at FROM daily_metrics d '
        "LEFT JOIN sync_meta m ON m.tbl = 'daily_metrics' AND m.id = d.day "
        'WHERE m.pushed_at IS NULL OR d.updated_at > m.pushed_at')) {
      out.add(SyncRecord('daily_metrics', r['day'] as String,
          r['updated_at'] as int, false, {
        'metrics': jsonDecode(r['data'] as String),
        'source': r['source'],
      }));
    }

    // routines, meal templates and favourite foods
    for (final r in _db.select(
        'SELECT i.id, i.kind, i.data, i.updated_at, i.deleted FROM user_items i '
        "LEFT JOIN sync_meta m ON m.tbl = 'user_items' AND m.id = i.id "
        'WHERE m.pushed_at IS NULL OR i.updated_at > m.pushed_at')) {
      Object? data;
      try {
        data = jsonDecode(r['data'] as String);
      } catch (_) {
        continue;
      }
      out.add(SyncRecord('user_items', r['id'] as String, r['updated_at'] as int,
          (r['deleted'] as int) == 1, {'kind': r['kind'], 'data': data}));
    }

    // workouts
    for (final r in _db.select(
        'SELECT w.id, w.day, w.start_ms, w.end_ms, w.type, w.title, '
        'w.distance_m, w.active_kcal, w.source, w.notes, w.extra, w.hr_json, w.ex_json, '
        'w.splits_json, '
        'w.updated_at, w.deleted '
        'FROM workouts w '
        "LEFT JOIN sync_meta m ON m.tbl = 'workouts' AND m.id = w.id "
        'WHERE m.pushed_at IS NULL OR w.updated_at > m.pushed_at')) {
      out.add(SyncRecord('workouts', r['id'] as String, r['updated_at'] as int,
          (r['deleted'] as int) == 1, {
        'day': r['day'],
        'start_ms': r['start_ms'],
        'end_ms': r['end_ms'],
        'type': r['type'],
        'title': r['title'],
        'distance_m': r['distance_m'],
        'active_kcal': r['active_kcal'],
        'source': r['source'],
        'notes': r['notes'],
        'extra': _fullExtra(r),
      }));
    }

    // targets: one record for all of them
    final db = AppDb.instance;
    final tu = int.tryParse(db.getSetting('targets_updated_at') ?? '') ?? 0;
    if (tu > 0) {
      final m = _db.select(
          "SELECT pushed_at FROM sync_meta WHERE tbl = 'targets' AND id = 'targets'");
      final pushed = m.isEmpty ? null : m.first['pushed_at'] as int;
      if (pushed == null || tu > pushed) {
        out.add(SyncRecord('targets', 'targets', tu, false, {
          'targets': db.loadTargets(),
          'mode': db.getSetting('target_mode') ?? 'grams',
        }));
      }
    }
    return out;
  }

  /// metrics + heart rate + exercises as one map (the format of the sync records)
  static Map<String, dynamic> _fullExtra(Row r) {
    final m = Map<String, dynamic>.from(
        jsonDecode((r['extra'] as String?) ?? '{}') as Map);
    final hr = (r['hr_json'] as String?) ?? '';
    final ex = (r['ex_json'] as String?) ?? '';
    if (hr.isNotEmpty) m['hr'] = jsonDecode(hr);
    if (ex.isNotEmpty) m['ex'] = jsonDecode(ex);
    final sp = (r['splits_json'] as String?) ?? '';
    if (sp.isNotEmpty) m['sp'] = jsonDecode(sp);
    return m;
  }

  static void _setMeta(String tbl, String id, int at) {
    _db.execute(
        'INSERT INTO sync_meta(tbl, id, pushed_at) VALUES(?, ?, ?) '
        'ON CONFLICT(tbl, id) DO UPDATE SET pushed_at = excluded.pushed_at',
        [tbl, id, at]);
  }

  /// Call after the server accepted the records.
  static void markPushed(List<SyncRecord> recs) {
    if (recs.isEmpty) return;
    _db.execute('BEGIN');
    try {
      for (final r in recs) {
        _setMeta(r.tbl, r.id, r.updatedAt);
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ------------------------------------------------------------------
  // apply what other devices changed
  // ------------------------------------------------------------------

  /// Returns how many records changed this device's data.
  static int applyRemote(List<SyncRecord> recs) {
    if (recs.isEmpty) return 0;
    var applied = 0;
    _db.execute('BEGIN');
    try {
      for (final r in recs) {
        if (_applyOne(r)) applied++;
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    AppDb.instance.invalidateWorkouts();
    return applied;
  }

  static int? _localUpdatedAt(SyncRecord r) {
    String? sql;
    switch (r.tbl) {
      case 'foods':
        sql = 'SELECT updated_at FROM foods WHERE id = ?';
        break;
      case 'log_entries':
        sql = 'SELECT updated_at FROM log_entries WHERE id = ?';
        break;
      case 'recipes':
        sql = 'SELECT updated_at FROM recipes WHERE id = ?';
        break;
      case 'weights':
        sql = 'SELECT updated_at FROM weights WHERE day = ?';
        break;
      case 'daily_metrics':
        sql = 'SELECT updated_at FROM daily_metrics WHERE day = ?';
        break;
      case 'workouts':
        sql = 'SELECT updated_at FROM workouts WHERE id = ?';
        break;
      case 'user_items':
        sql = 'SELECT updated_at FROM user_items WHERE id = ?';
        break;
      case 'targets':
        return int.tryParse(
            AppDb.instance.getSetting('targets_updated_at') ?? '');
    }
    if (sql == null) return null;
    final rs = _db.select(sql, [r.id]);
    return rs.isEmpty ? null : rs.first['updated_at'] as int;
  }

  static bool _applyOne(SyncRecord r) {
    if (!_known.contains(r.tbl)) return false;
    final local = _localUpdatedAt(r);
    if (local != null && local > r.updatedAt) return false; // ours is newer
    if (local != null && local == r.updatedAt) {
      _setMeta(r.tbl, r.id, r.updatedAt); // already identical
      return false;
    }
    final d = r.data;
    final del = r.deleted ? 1 : 0;

    if (r.tbl == 'foods') {
      _db.execute(
          'INSERT INTO foods(id, name, updated_at, deleted, recipe_id) '
          'VALUES(?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
          'name = excluded.name, updated_at = excluded.updated_at, '
          'deleted = excluded.deleted, recipe_id = excluded.recipe_id',
          [r.id, d['name'], r.updatedAt, del, d['recipe_id']]);
      _db.execute('DELETE FROM food_nutrients WHERE food_id = ?', [r.id]);
      final vals = (d['values'] as Map?)?.cast<String, dynamic>() ?? {};
      for (final e in vals.entries) {
        _db.execute(
            'INSERT INTO food_nutrients(food_id, nutrient, amount) VALUES(?, ?, ?)',
            [r.id, e.key, (e.value as num).toDouble()]);
      }
    } else if (r.tbl == 'log_entries') {
      _db.execute(
          'INSERT INTO log_entries(id, day, meal, food_id, grams, updated_at, deleted) '
          'VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
          'day = excluded.day, meal = excluded.meal, food_id = excluded.food_id, '
          'grams = excluded.grams, updated_at = excluded.updated_at, '
          'deleted = excluded.deleted',
          [r.id, d['day'], d['meal'], d['food_id'],
            (d['grams'] as num).toDouble(), r.updatedAt, del]);
    } else if (r.tbl == 'recipes') {
      _db.execute(
          'INSERT INTO recipes(id, name, servings, cooked_grams, steps, notes, '
          'tags, updated_at, deleted) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
          'servings = excluded.servings, cooked_grams = excluded.cooked_grams, '
          'steps = excluded.steps, notes = excluded.notes, tags = excluded.tags, '
          'updated_at = excluded.updated_at, deleted = excluded.deleted',
          [r.id, d['name'], (d['servings'] as num).toDouble(),
            d['cooked_grams'], d['steps'] ?? '', d['notes'] ?? '',
            d['tags'] ?? '', r.updatedAt, del]);
      _db.execute('DELETE FROM recipe_ingredients WHERE recipe_id = ?', [r.id]);
      final ings = (d['ingredients'] as List?) ?? [];
      for (var i = 0; i < ings.length; i++) {
        final m = (ings[i] as Map).cast<String, dynamic>();
        _db.execute(
            'INSERT INTO recipe_ingredients(recipe_id, position, food_id, grams) '
            'VALUES(?, ?, ?, ?)',
            [r.id, i, m['food_id'], (m['grams'] as num).toDouble()]);
      }
    } else if (r.tbl == 'weights') {
      _db.execute(
          'INSERT INTO weights(day, kg, source, updated_at, deleted) '
          'VALUES(?, ?, ?, ?, ?) ON CONFLICT(day) DO UPDATE SET '
          'kg = excluded.kg, source = excluded.source, '
          'updated_at = excluded.updated_at, deleted = excluded.deleted',
          [r.id, (d['kg'] as num).toDouble(), d['source'] ?? 'manual',
            r.updatedAt, del]);
    } else if (r.tbl == 'daily_metrics') {
      _db.execute(
          'INSERT INTO daily_metrics(day, data, source, updated_at) '
          'VALUES(?, ?, ?, ?) ON CONFLICT(day) DO UPDATE SET '
          'data = excluded.data, source = excluded.source, '
          'updated_at = excluded.updated_at',
          [r.id, jsonEncode(d['metrics'] ?? {}),
            d['source'] ?? 'health_connect', r.updatedAt]);
    } else if (r.tbl == 'user_items') {
      _db.execute(
          'INSERT INTO user_items(id, kind, data, updated_at, deleted) '
          'VALUES(?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
          'kind = excluded.kind, data = excluded.data, '
          'updated_at = excluded.updated_at, deleted = excluded.deleted',
          [r.id, d['kind'] ?? '', jsonEncode(d['data'] ?? {}), r.updatedAt, del]);
    } else if (r.tbl == 'workouts') {
      final extra = Map<String, dynamic>.from((d['extra'] as Map?) ?? {});
      final hr = extra.remove('hr');
      final ex = extra.remove('ex');
      final sp = extra.remove('sp');
      _db.execute(
          'INSERT INTO workouts(id, day, start_ms, end_ms, type, title, '
          'distance_m, active_kcal, source, notes, extra, hr_json, ex_json, '
          'splits_json, updated_at, deleted) '
          'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET day = excluded.day, '
          'start_ms = excluded.start_ms, end_ms = excluded.end_ms, '
          'type = excluded.type, title = excluded.title, '
          'distance_m = excluded.distance_m, active_kcal = excluded.active_kcal, '
          'source = excluded.source, notes = excluded.notes, '
          'extra = excluded.extra, hr_json = excluded.hr_json, '
          'ex_json = excluded.ex_json, splits_json = excluded.splits_json, '
          'updated_at = excluded.updated_at, deleted = excluded.deleted',
          [r.id, d['day'], d['start_ms'], d['end_ms'], d['type'],
            d['title'] ?? '', d['distance_m'], d['active_kcal'],
            d['source'] ?? 'manual', d['notes'] ?? '', jsonEncode(extra),
            hr == null ? '' : jsonEncode(hr), ex == null ? '' : jsonEncode(ex),
            sp == null ? '' : jsonEncode(sp), r.updatedAt, del]);
    } else if (r.tbl == 'targets') {
      _db.execute('DELETE FROM targets');
      final t = (d['targets'] as Map?)?.cast<String, dynamic>() ?? {};
      for (final e in t.entries) {
        _db.execute('INSERT INTO targets(nutrient, amount) VALUES(?, ?)',
            [e.key, (e.value as num).toDouble()]);
      }
      const upsert = 'INSERT INTO settings(key, value) VALUES(?, ?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value';
      final mode = d['mode'] as String?;
      if (mode != null) _db.execute(upsert, ['target_mode', mode]);
      _db.execute(upsert, ['targets_updated_at', r.updatedAt.toString()]);
    }

    _setMeta(r.tbl, r.id, r.updatedAt);
    return true;
  }
}
