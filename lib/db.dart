import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'nutrients.dart';

/// Random 32-character id. Ids are text (not 1,2,3...) so that records made on
/// different devices never clash when we add sync later.
String newId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
}

int nowMs() => DateTime.now().millisecondsSinceEpoch;

String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class Food {
  final String id;
  final String name;

  /// nutrient key -> amount per 100 g. A missing key means "unknown".
  final Map<String, double> values;
  /// Only set for foods found online ('USDA', 'Open Food Facts').
  final String? source;
  /// True for the hidden food row that stands for a recipe.
  final bool isRecipe;
  Food({
    required this.id,
    required this.name,
    required this.values,
    this.source,
    this.isRecipe = false,
  });
}

class LogEntry {
  final String id;
  final String meal;
  final double grams;
  final String foodId;
  final String foodName;
  final Map<String, double> values; // per 100 g
  LogEntry({
    required this.id,
    required this.meal,
    required this.grams,
    required this.foodId,
    required this.foodName,
    required this.values,
  });
}

class RecipeIngredient {
  final Food food;
  final double grams;
  RecipeIngredient({required this.food, required this.grams});
}

class Recipe {
  final String id;
  String name;
  double servings;

  /// Weight of the finished dish. If null, the sum of the ingredients is used.
  double? cookedGrams;
  String steps;
  String notes;
  String tags; // comma separated
  List<RecipeIngredient> ingredients;

  Recipe({
    required this.id,
    required this.name,
    required this.servings,
    this.cookedGrams,
    this.steps = '',
    this.notes = '',
    this.tags = '',
    required this.ingredients,
  });

  double get rawGrams => ingredients.fold(0.0, (s, i) => s + i.grams);
  double get totalGrams => cookedGrams ?? rawGrams;
  double get gramsPerServing => servings > 0 ? totalGrams / servings : 0;

  /// Totals for the whole recipe. A nutrient is only included if EVERY
  /// ingredient has a value for it; otherwise it stays "unknown".
  Map<String, double> totals() {
    final out = <String, double>{};
    if (ingredients.isEmpty) return out;
    for (final n in nutrients) {
      var sum = 0.0;
      var known = true;
      for (final i in ingredients) {
        final v = i.food.values[n.key];
        if (v == null) {
          known = false;
          break;
        }
        sum += v * i.grams / 100;
      }
      if (known) out[n.key] = sum;
    }
    return out;
  }

  Map<String, double> perServing() => servings > 0
      ? {for (final e in totals().entries) e.key: e.value / servings}
      : {};

  Map<String, double> per100g() => totalGrams > 0
      ? {for (final e in totals().entries) e.key: e.value / totalGrams * 100}
      : {};
}

class WeightPoint {
  final String day; // YYYY-MM-DD
  final double kg;
  WeightPoint(this.day, this.kg);
}

/// Nutrient totals of one logged day. A nutrient is in [incomplete] if at
/// least one logged food of that day has no value for it.
class DayTotals {
  final Map<String, double> totals = {};
  final Set<String> incomplete = {};
}

class Workout {
  final String id;
  final String day; // local date of the start, YYYY-MM-DD
  final int startMs;
  final int endMs;
  final String type; // e.g. RUNNING or a free text for manual entries
  final String title;
  final double? distanceM;
  final double? activeKcal;
  final String source; // 'health_connect' or 'manual'
  final bool deleted;
  Workout({
    required this.id,
    required this.day,
    required this.startMs,
    required this.endMs,
    required this.type,
    this.title = '',
    this.distanceM,
    this.activeKcal,
    required this.source,
    this.deleted = false,
  });

  double get minutes => (endMs - startMs) / 60000.0;

  bool sameAs(Workout o) =>
      startMs == o.startMs &&
      endMs == o.endMs &&
      type == o.type &&
      ((distanceM ?? -1) - (o.distanceM ?? -1)).abs() < 1 &&
      ((activeKcal ?? -1) - (o.activeKcal ?? -1)).abs() < 0.5;
}

class AppDb {
  AppDb._(this._db);
  final Database _db;
  static late AppDb instance;

  /// The raw database, used by the sync code.
  Database get raw => _db;

  static Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    final db = sqlite3.open(p.join(dir.path, 'macro_tracker.db'));
    db.execute('''
      CREATE TABLE IF NOT EXISTS foods (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS food_nutrients (
        food_id TEXT NOT NULL,
        nutrient TEXT NOT NULL,
        amount REAL NOT NULL,
        PRIMARY KEY (food_id, nutrient)
      );
      CREATE TABLE IF NOT EXISTS log_entries (
        id TEXT PRIMARY KEY,
        day TEXT NOT NULL,
        meal TEXT NOT NULL,
        food_id TEXT NOT NULL,
        grams REAL NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS targets (
        nutrient TEXT PRIMARY KEY,
        amount REAL NOT NULL
      );
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    // ---- Milestone 2: recipes ----
    db.execute('''
      CREATE TABLE IF NOT EXISTS recipes (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        servings REAL NOT NULL,
        cooked_grams REAL,
        steps TEXT NOT NULL DEFAULT '',
        notes TEXT NOT NULL DEFAULT '',
        tags TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS recipe_ingredients (
        recipe_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        food_id TEXT NOT NULL,
        grams REAL NOT NULL,
        PRIMARY KEY (recipe_id, position)
      );
    ''');
    // ---- Milestone 4: weight ----
    db.execute('''
      CREATE TABLE IF NOT EXISTS weights (
        day TEXT PRIMARY KEY,
        kg REAL NOT NULL,
        source TEXT NOT NULL DEFAULT 'manual',
        updated_at INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0
      );
    ''');
    // ---- Milestone 6: activity (steps, sleep, workouts, ...) ----
    db.execute('''
      CREATE TABLE IF NOT EXISTS daily_metrics (
        day TEXT PRIMARY KEY,
        data TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'health_connect',
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS workouts (
        id TEXT PRIMARY KEY,
        day TEXT NOT NULL,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        distance_m REAL,
        active_kcal REAL,
        source TEXT NOT NULL DEFAULT 'manual',
        updated_at INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0
      );
    ''');
    // Every recipe also has a hidden "food" row (same id) so it can be logged
    // like any food. This column marks those rows.
    final cols = db.select('PRAGMA table_info(foods)');
    if (!cols.any((c) => c['name'] == 'recipe_id')) {
      db.execute('ALTER TABLE foods ADD COLUMN recipe_id TEXT');
    }
    instance = AppDb._(db);

    // Placeholder macro targets on first run (edit them in the Targets tab).
    if (db.select('SELECT 1 FROM targets LIMIT 1').isEmpty) {
      instance.saveTargets({
        'calories': 2000,
        'protein': 150,
        'carbs': 200,
        'fat': 67,
      }, touch: false);
    }
  }

  // ---------- foods ----------

  Map<String, double> _values(String foodId) {
    final rs = _db.select(
        'SELECT nutrient, amount FROM food_nutrients WHERE food_id = ?',
        [foodId]);
    return {
      for (final r in rs) r['nutrient'] as String: (r['amount'] as num).toDouble()
    };
  }

  /// Every word of the query must appear in the name. Foods you log most
  /// often come first, then alphabetical. With [includeRecipes], recipes are
  /// listed among the foods (they are marked with isRecipe).
  List<Food> loadFoods([String query = '', bool includeRecipes = false]) {
    final words = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final cond = words.map((_) => 'name LIKE ?').join(' AND ');
    final sql = 'SELECT id, name, recipe_id FROM foods WHERE deleted = 0' +
        (includeRecipes ? '' : ' AND recipe_id IS NULL') +
        (cond.isEmpty ? '' : ' AND $cond') +
        ' ORDER BY (SELECT COUNT(*) FROM log_entries e '
            'WHERE e.food_id = foods.id AND e.deleted = 0) DESC, '
            'name COLLATE NOCASE';
    final rs = _db.select(sql, [for (final w in words) '%$w%']);
    return [
      for (final r in rs)
        Food(
          id: r['id'] as String,
          name: r['name'] as String,
          values: _values(r['id'] as String),
          isRecipe: r['recipe_id'] != null,
        )
    ];
  }

  /// Foods you logged most recently, newest first.
  List<Food> loadRecentFoods([int limit = 15, bool includeRecipes = false]) {
    final sql = 'SELECT f.id, f.name, f.recipe_id FROM foods f JOIN ('
            'SELECT food_id, MAX(updated_at) AS last FROM log_entries '
            'WHERE deleted = 0 GROUP BY food_id) l ON l.food_id = f.id '
            'WHERE f.deleted = 0' +
        (includeRecipes ? '' : ' AND f.recipe_id IS NULL') +
        ' ORDER BY l.last DESC LIMIT ?';
    final rs = _db.select(sql, [limit]);
    return [
      for (final r in rs)
        Food(
          id: r['id'] as String,
          name: r['name'] as String,
          values: _values(r['id'] as String),
          isRecipe: r['recipe_id'] != null,
        )
    ];
  }

  void saveFood(Food f) {
    _db.execute('BEGIN');
    try {
      _db.execute(
          'INSERT INTO foods(id, name, updated_at, deleted) VALUES(?, ?, ?, 0) '
          'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
          'updated_at = excluded.updated_at, deleted = 0',
          [f.id, f.name, nowMs()]);
      _db.execute('DELETE FROM food_nutrients WHERE food_id = ?', [f.id]);
      final st = _db.prepare(
          'INSERT INTO food_nutrients(food_id, nutrient, amount) VALUES(?, ?, ?)');
      for (final e in f.values.entries) {
        st.execute([f.id, e.key, e.value]);
      }
      st.dispose();
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _refreshRecipesUsing(f.id);
  }

  /// "Soft" delete: the row stays, flagged as deleted (needed later for sync).
  void deleteFood(String id) {
    _db.execute('UPDATE foods SET deleted = 1, updated_at = ? WHERE id = ?',
        [nowMs(), id]);
  }

  // ---------- log ----------

  List<LogEntry> loadDay(String day) {
    final rs = _db.select(
        'SELECT e.id, e.meal, e.grams, e.food_id, f.name '
        'FROM log_entries e JOIN foods f ON f.id = e.food_id '
        'WHERE e.day = ? AND e.deleted = 0 ORDER BY e.updated_at, e.rowid',
        [day]);
    return [
      for (final r in rs)
        LogEntry(
          id: r['id'] as String,
          meal: r['meal'] as String,
          grams: (r['grams'] as num).toDouble(),
          foodId: r['food_id'] as String,
          foodName: r['name'] as String,
          values: _values(r['food_id'] as String),
        )
    ];
  }

  /// Returns the id of the new entry (used for "undo").
  String addEntry(String day, String meal, String foodId, double grams) {
    final id = newId();
    _db.execute(
        'INSERT INTO log_entries(id, day, meal, food_id, grams, updated_at, deleted) '
        'VALUES(?, ?, ?, ?, ?, ?, 0)',
        [id, day, meal, foodId, grams, nowMs()]);
    return id;
  }

  void deleteEntry(String id) {
    _db.execute(
        'UPDATE log_entries SET deleted = 1, updated_at = ? WHERE id = ?',
        [nowMs(), id]);
  }

  // ---------- targets and settings ----------

  Map<String, double> loadTargets() {
    final rs = _db.select('SELECT nutrient, amount FROM targets');
    return {
      for (final r in rs) r['nutrient'] as String: (r['amount'] as num).toDouble()
    };
  }

  /// [touch] = false is used for the placeholder defaults, which must not
  /// count as a change that is synced.
  void saveTargets(Map<String, double> t, {bool touch = true}) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM targets');
      final st = _db.prepare('INSERT INTO targets(nutrient, amount) VALUES(?, ?)');
      for (final e in t.entries) {
        st.execute([e.key, e.value]);
      }
      st.dispose();
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    if (touch) setSetting('targets_updated_at', nowMs().toString());
  }

  String? getSetting(String key) {
    final rs = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rs.isEmpty ? null : rs.first['value'] as String;
  }

  void setSetting(String key, String value) {
    _db.execute(
        'INSERT INTO settings(key, value) VALUES(?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value]);
  }
  // ---------- recipes ----------

  Food? loadFood(String id) {
    final rs = _db.select('SELECT id, name FROM foods WHERE id = ?', [id]);
    if (rs.isEmpty) return null;
    return Food(id: id, name: rs.first['name'] as String, values: _values(id));
  }

  List<RecipeIngredient> _ingredients(String recipeId) {
    final rs = _db.select(
        'SELECT food_id, grams FROM recipe_ingredients '
        'WHERE recipe_id = ? ORDER BY position',
        [recipeId]);
    final out = <RecipeIngredient>[];
    for (final r in rs) {
      final food = loadFood(r['food_id'] as String);
      if (food != null) {
        out.add(RecipeIngredient(
            food: food, grams: (r['grams'] as num).toDouble()));
      }
    }
    return out;
  }

  Recipe _recipeFromRow(Row r) => Recipe(
        id: r['id'] as String,
        name: r['name'] as String,
        servings: (r['servings'] as num).toDouble(),
        cookedGrams: r['cooked_grams'] == null
            ? null
            : (r['cooked_grams'] as num).toDouble(),
        steps: r['steps'] as String,
        notes: r['notes'] as String,
        tags: r['tags'] as String,
        ingredients: _ingredients(r['id'] as String),
      );

  List<Recipe> loadRecipes([String query = '']) {
    final rs = _db.select(
        'SELECT * FROM recipes WHERE deleted = 0 AND name LIKE ? '
        'ORDER BY name COLLATE NOCASE',
        ['%$query%']);
    return [for (final r in rs) _recipeFromRow(r)];
  }

  Recipe? loadRecipe(String id) {
    final rs =
        _db.select('SELECT * FROM recipes WHERE id = ? AND deleted = 0', [id]);
    return rs.isEmpty ? null : _recipeFromRow(rs.first);
  }

  // Writes the hidden food row (nutrients per 100 g of the finished dish).
  // Must be called inside a transaction.
  void _writeShadowFood(Recipe r) {
    _db.execute(
        'INSERT INTO foods(id, name, updated_at, deleted, recipe_id) '
        'VALUES(?, ?, ?, 0, ?) '
        'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
        'updated_at = excluded.updated_at, deleted = 0, '
        'recipe_id = excluded.recipe_id',
        [r.id, r.name, nowMs(), r.id]);
    _db.execute('DELETE FROM food_nutrients WHERE food_id = ?', [r.id]);
    final st = _db.prepare(
        'INSERT INTO food_nutrients(food_id, nutrient, amount) VALUES(?, ?, ?)');
    for (final e in r.per100g().entries) {
      st.execute([r.id, e.key, e.value]);
    }
    st.dispose();
  }

  void saveRecipe(Recipe r) {
    _db.execute('BEGIN');
    try {
      _db.execute(
          'INSERT INTO recipes(id, name, servings, cooked_grams, steps, notes, '
          'tags, updated_at, deleted) VALUES(?, ?, ?, ?, ?, ?, ?, ?, 0) '
          'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
          'servings = excluded.servings, cooked_grams = excluded.cooked_grams, '
          'steps = excluded.steps, notes = excluded.notes, tags = excluded.tags, '
          'updated_at = excluded.updated_at, deleted = 0',
          [r.id, r.name, r.servings, r.cookedGrams, r.steps, r.notes, r.tags, nowMs()]);
      _db.execute('DELETE FROM recipe_ingredients WHERE recipe_id = ?', [r.id]);
      final st = _db.prepare(
          'INSERT INTO recipe_ingredients(recipe_id, position, food_id, grams) '
          'VALUES(?, ?, ?, ?)');
      for (var i = 0; i < r.ingredients.length; i++) {
        st.execute([r.id, i, r.ingredients[i].food.id, r.ingredients[i].grams]);
      }
      st.dispose();
      _writeShadowFood(r);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Past log entries of this recipe stay in the diary (the hidden food row
  /// is kept, just flagged as deleted).
  void deleteRecipe(String id) {
    final t = nowMs();
    _db.execute('UPDATE recipes SET deleted = 1, updated_at = ? WHERE id = ?', [t, id]);
    _db.execute('UPDATE foods SET deleted = 1, updated_at = ? WHERE id = ?', [t, id]);
  }

  // When a food changes, recipes that use it get their numbers recomputed.
  void _refreshRecipesUsing(String foodId) {
    final ids = _db.select(
        'SELECT DISTINCT recipe_id FROM recipe_ingredients WHERE food_id = ?',
        [foodId]);
    for (final row in ids) {
      final r = loadRecipe(row['recipe_id'] as String);
      if (r == null) continue;
      _db.execute('BEGIN');
      try {
        _writeShadowFood(r);
        _db.execute('COMMIT');
      } catch (e) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
  }
  // ---------- undo support ----------

  void restoreEntry(String id) {
    _db.execute(
        'UPDATE log_entries SET deleted = 0, updated_at = ? WHERE id = ?',
        [nowMs(), id]);
  }

  // ---------- weight ----------

  /// One weight per day; saving again for the same day replaces it.
  void saveWeight(String day, double kg, {String source = 'manual'}) {
    _db.execute(
        'INSERT INTO weights(day, kg, source, updated_at, deleted) '
        'VALUES(?, ?, ?, ?, 0) '
        'ON CONFLICT(day) DO UPDATE SET kg = excluded.kg, '
        'source = excluded.source, updated_at = excluded.updated_at, deleted = 0',
        [day, kg, source, nowMs()]);
  }

  void deleteWeight(String day) {
    _db.execute('UPDATE weights SET deleted = 1, updated_at = ? WHERE day = ?',
        [nowMs(), day]);
  }

  /// The stored weight row of a day (also if it was deleted), or null.
  Map<String, Object?>? weightRow(String day) {
    final rs = _db.select(
        'SELECT kg, source, deleted FROM weights WHERE day = ?', [day]);
    if (rs.isEmpty) return null;
    final r = rs.first;
    return {
      'kg': (r['kg'] as num).toDouble(),
      'source': r['source'] as String,
      'deleted': (r['deleted'] as int) == 1,
    };
  }

  /// Weights from [fromDay] on, oldest first.
  List<WeightPoint> loadWeights(String fromDay) {
    final rs = _db.select(
        'SELECT day, kg FROM weights WHERE deleted = 0 AND day >= ? ORDER BY day',
        [fromDay]);
    return [
      for (final r in rs) WeightPoint(r['day'] as String, (r['kg'] as num).toDouble())
    ];
  }

  // ---------- charts ----------

  /// Nutrient totals for every logged day between the two dates (inclusive).
  /// Days without any logged food are not in the result.
  Map<String, DayTotals> dailyTotals(String fromDay, String toDay) {
    final out = <String, DayTotals>{};
    final entryCount = <String, int>{};
    final counts = _db.select(
        'SELECT day, COUNT(*) AS n FROM log_entries '
        'WHERE deleted = 0 AND day BETWEEN ? AND ? GROUP BY day',
        [fromDay, toDay]);
    for (final r in counts) {
      final d = r['day'] as String;
      entryCount[d] = r['n'] as int;
      out[d] = DayTotals();
    }
    final rs = _db.select(
        'SELECT e.day AS day, fn.nutrient AS nutrient, '
        'SUM(fn.amount * e.grams / 100.0) AS total, COUNT(*) AS n '
        'FROM log_entries e JOIN food_nutrients fn ON fn.food_id = e.food_id '
        'WHERE e.deleted = 0 AND e.day BETWEEN ? AND ? '
        'GROUP BY e.day, fn.nutrient',
        [fromDay, toDay]);
    for (final r in rs) {
      final d = r['day'] as String;
      final nutrient = r['nutrient'] as String;
      final t = out[d];
      if (t == null) continue;
      t.totals[nutrient] = (r['total'] as num).toDouble();
      if ((r['n'] as int) < (entryCount[d] ?? 0)) t.incomplete.add(nutrient);
    }
    return out;
  }
  // ---------- activity ----------

  /// Stores the metrics of one day (steps, sleep_total, ...). Returns false
  /// if nothing changed, so unchanged days are not synced again.
  bool saveDailyMetrics(String day, Map<String, double> m,
      {String source = 'health_connect'}) {
    final rs = _db.select('SELECT data FROM daily_metrics WHERE day = ?', [day]);
    if (rs.isNotEmpty) {
      final old = (jsonDecode(rs.first['data'] as String) as Map)
          .map((k, v) => MapEntry(k as String, (v as num).toDouble()));
      var same = old.length == m.length;
      if (same) {
        for (final e in m.entries) {
          final o = old[e.key];
          if (o == null || (o - e.value).abs() > 0.001) {
            same = false;
            break;
          }
        }
      }
      if (same) return false;
    }
    _db.execute(
        'INSERT INTO daily_metrics(day, data, source, updated_at) '
        'VALUES(?, ?, ?, ?) ON CONFLICT(day) DO UPDATE SET '
        'data = excluded.data, source = excluded.source, '
        'updated_at = excluded.updated_at',
        [day, jsonEncode(m), source, nowMs()]);
    return true;
  }

  Map<String, Map<String, double>> loadDailyMetrics(String fromDay, String toDay) {
    final rs = _db.select(
        'SELECT day, data FROM daily_metrics WHERE day BETWEEN ? AND ?',
        [fromDay, toDay]);
    return {
      for (final r in rs)
        r['day'] as String: (jsonDecode(r['data'] as String) as Map)
            .map((k, v) => MapEntry(k as String, (v as num).toDouble()))
    };
  }

  Workout _workoutFromRow(Row r) => Workout(
        id: r['id'] as String,
        day: r['day'] as String,
        startMs: r['start_ms'] as int,
        endMs: r['end_ms'] as int,
        type: r['type'] as String,
        title: r['title'] as String,
        distanceM:
            r['distance_m'] == null ? null : (r['distance_m'] as num).toDouble(),
        activeKcal:
            r['active_kcal'] == null ? null : (r['active_kcal'] as num).toDouble(),
        source: r['source'] as String,
        deleted: (r['deleted'] as int) == 1,
      );

  /// Any workout row, also a deleted one.
  Workout? loadWorkout(String id) {
    final rs = _db.select('SELECT * FROM workouts WHERE id = ?', [id]);
    return rs.isEmpty ? null : _workoutFromRow(rs.first);
  }

  /// Workouts from [fromDay] on, newest first.
  List<Workout> loadWorkouts(String fromDay) {
    final rs = _db.select(
        'SELECT * FROM workouts WHERE deleted = 0 AND day >= ? '
        'ORDER BY start_ms DESC',
        [fromDay]);
    return [for (final r in rs) _workoutFromRow(r)];
  }

  void saveWorkout(Workout w) {
    _db.execute(
        'INSERT INTO workouts(id, day, start_ms, end_ms, type, title, '
        'distance_m, active_kcal, source, updated_at, deleted) '
        'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0) '
        'ON CONFLICT(id) DO UPDATE SET day = excluded.day, '
        'start_ms = excluded.start_ms, end_ms = excluded.end_ms, '
        'type = excluded.type, title = excluded.title, '
        'distance_m = excluded.distance_m, active_kcal = excluded.active_kcal, '
        'source = excluded.source, updated_at = excluded.updated_at, deleted = 0',
        [w.id, w.day, w.startMs, w.endMs, w.type, w.title, w.distanceM,
          w.activeKcal, w.source, nowMs()]);
  }

  void deleteWorkout(String id) {
    _db.execute('UPDATE workouts SET deleted = 1, updated_at = ? WHERE id = ?',
        [nowMs(), id]);
  }
}
