import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'nutrients.dart';
import 'workout_types.dart';

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

/// Something you saved yourself: a gym routine ('gym_template'), a meal
/// template ('meal_template') or a favourite food ('favorite_food').
class UserItem {
  final String id, kind;
  final Map<String, dynamic> data;
  final int updatedAt;
  const UserItem(this.id, this.kind, this.data, this.updatedAt);
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
  final String source; // 'health_connect', 'manual', 'hevy', 'garmin_csv'
  final String notes; // free text
  /// Which app wrote it into Health Connect (empty for other sources).
  final String origin;
  /// Extra numbers by key: avg_hr, max_hr, ascent_m, cadence_avg, swolf, sets, ...
  final Map<String, double> metrics;
  /// Heart rate over time: [minutes since start, bpm]
  final List<List<double>> hr;
  /// Gym sessions: [{name, sets: [{type, kg, reps, km, sec}]}]
  final List<Map<String, dynamic>> exercises;

  /// Laps / splits of a run, ride or swim (from the Garmin export):
  /// [{i, d (m), s (s), hr, hm, cd, pw, up, dn, gc, st, vo}]
  final List<Map<String, dynamic>> splits;
  final bool deleted;

  /// true when loaded without the heart rate series / exercises (fast lists).
  /// Saving such a workout leaves those two columns untouched.
  final bool light;

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
    this.notes = '',
    this.origin = '',
    this.metrics = const {},
    this.hr = const [],
    this.exercises = const [],
    this.splits = const [],
    this.deleted = false,
    this.light = false,
  });

  double get minutes => (endMs - startMs) / 60000.0;

  /// A copy with some fields replaced. A null argument keeps the old value.
  Workout copyWith({
    String? type,
    String? title,
    double? distanceM,
    double? activeKcal,
    String? source,
    String? notes,
    String? origin,
    Map<String, double>? metrics,
    List<List<double>>? hr,
    List<Map<String, dynamic>>? exercises,
    List<Map<String, dynamic>>? splits,
  }) =>
      Workout(
        id: id,
        day: day,
        startMs: startMs,
        endMs: endMs,
        type: type ?? this.type,
        title: title ?? this.title,
        distanceM: distanceM ?? this.distanceM,
        activeKcal: activeKcal ?? this.activeKcal,
        source: source ?? this.source,
        notes: notes ?? this.notes,
        origin: origin ?? this.origin,
        metrics: metrics ?? this.metrics,
        hr: hr ?? this.hr,
        exercises: exercises ?? this.exercises,
        splits: splits ?? this.splits,
        deleted: deleted,
        light: light,
      );

  /// origin and metrics (small; stored in the column "extra")
  String get coreJson => jsonEncode({
        if (origin.isNotEmpty) 'o': origin,
        if (metrics.isNotEmpty) 'm': metrics,
      });

  /// heart rate series and exercises, each in its own column (large)
  String get hrJson => hr.isEmpty ? '' : jsonEncode(hr);
  String get exJson => exercises.isEmpty ? '' : jsonEncode(exercises);
  String get splitsJson => splits.isEmpty ? '' : jsonEncode(splits);

  /// everything together, for comparing two versions of a workout
  String get extraJson => jsonEncode({
        if (origin.isNotEmpty) 'o': origin,
        if (metrics.isNotEmpty) 'm': metrics,
        if (hr.isNotEmpty) 'hr': hr,
        if (exercises.isNotEmpty) 'ex': exercises,
        if (splits.isNotEmpty) 'sp': splits,
      });

  /// Same basic data (ignores notes and extras).
  bool sameAs(Workout o) =>
      startMs == o.startMs &&
      endMs == o.endMs &&
      type == o.type &&
      title == o.title &&
      ((distanceM ?? -1) - (o.distanceM ?? -1)).abs() < 1 &&
      ((activeKcal ?? -1) - (o.activeKcal ?? -1)).abs() < 0.5;
}

Map<String, dynamic> parseExtra(Object? raw) {
  try {
    final d = jsonDecode((raw as String?) ?? '{}');
    return d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

class AppDb {
  AppDb._(this._db, this.path);
  final Database _db;

  /// The database file (background isolates open their own connection to it).
  final String path;
  static late AppDb instance;

  /// The raw database, used by the sync code.
  Database get raw => _db;

  static Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'macro_tracker.db');
    _applyPendingRestore(path);
    initAt(path);
  }

  /// A restore (see backup_service.dart) leaves a file next to the database;
  /// it is swapped in here, before the database is opened.
  static void _applyPendingRestore(String path) {
    final restore = File('$path.restore');
    if (!restore.existsSync()) return;
    final keep = File('$path.replaced'); // the database that is being replaced
    try {
      if (keep.existsSync()) keep.deleteSync();
      final old = File(path);
      if (old.existsSync()) old.renameSync(keep.path);
      for (final ext in ['-wal', '-shm']) {
        final f = File('$path$ext');
        if (f.existsSync()) f.deleteSync();
      }
      restore.renameSync(path);
    } catch (_) {
      // put the old database back if something went wrong
      try {
        if (!File(path).existsSync() && keep.existsSync()) keep.renameSync(path);
      } catch (_) {}
    }
  }

  /// Opens (and if needed creates) the database file. Also used by
  /// background isolates, which work with their own connection.
  static void initAt(String path) {
    final db = sqlite3.open(path);
    // WAL: readers are not blocked while another connection writes.
    db.select('PRAGMA journal_mode = WAL');
    db.select('PRAGMA busy_timeout = 5000');
    // Faster and still safe in WAL mode: no disk flush after every commit.
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA temp_store = MEMORY');
    db.execute('PRAGMA cache_size = -16000');
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
    // ---- your own saved things: routines, meal templates, favourite foods ----
    db.execute('''
      CREATE TABLE IF NOT EXISTS user_items (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        data TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0
      );
    ''');
    db.execute(
        'CREATE INDEX IF NOT EXISTS idx_user_items_kind ON user_items(kind, deleted)');
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
    final wcols = db.select('PRAGMA table_info(workouts)');
    if (!wcols.any((c) => c['name'] == 'notes')) {
      db.execute("ALTER TABLE workouts ADD COLUMN notes TEXT NOT NULL DEFAULT ''");
    }
    if (!wcols.any((c) => c['name'] == 'extra')) {
      db.execute("ALTER TABLE workouts ADD COLUMN extra TEXT NOT NULL DEFAULT '{}'");
    }
    if (!wcols.any((c) => c['name'] == 'hr_json')) {
      db.execute("ALTER TABLE workouts ADD COLUMN hr_json TEXT NOT NULL DEFAULT ''");
    }
    if (!wcols.any((c) => c['name'] == 'ex_json')) {
      db.execute("ALTER TABLE workouts ADD COLUMN ex_json TEXT NOT NULL DEFAULT ''");
    }
    if (!wcols.any((c) => c['name'] == 'splits_json')) {
      db.execute("ALTER TABLE workouts ADD COLUMN splits_json TEXT NOT NULL DEFAULT ''");
    }
    // One time: move the big parts (heart rate series, exercises) out of "extra",
    // so that lists of workouts load fast.
    if (db.select("SELECT 1 FROM settings WHERE key = 'workout_extra_split'").isEmpty) {
      db.execute('BEGIN IMMEDIATE');
      try {
        final rows = db
            .select(r'''SELECT id, extra FROM workouts WHERE extra LIKE '%"hr"%' OR extra LIKE '%"ex"%' ''')
            .toList();
        for (final r in rows) {
          final m = parseExtra(r['extra']);
          final hr = m.remove('hr');
          final ex = m.remove('ex');
          db.execute('UPDATE workouts SET extra = ?, hr_json = ?, ex_json = ? WHERE id = ?', [
            jsonEncode(m),
            hr == null ? '' : jsonEncode(hr),
            ex == null ? '' : jsonEncode(ex),
            r['id'],
          ]);
        }
        db.execute("INSERT INTO settings(key, value) VALUES('workout_extra_split', '1')");
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
    // Indexes: much faster day views, charts and searches.
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_log_day ON log_entries(day);
      CREATE INDEX IF NOT EXISTS idx_log_food ON log_entries(food_id);
      CREATE INDEX IF NOT EXISTS idx_workouts_day ON workouts(day);
      CREATE INDEX IF NOT EXISTS idx_workouts_start ON workouts(start_ms);
    ''');
    // Every recipe also has a hidden "food" row (same id) so it can be logged
    // like any food. This column marks those rows.
    final cols = db.select('PRAGMA table_info(foods)');
    if (!cols.any((c) => c['name'] == 'recipe_id')) {
      db.execute('ALTER TABLE foods ADD COLUMN recipe_id TEXT');
    }
    instance = AppDb._(db, path);

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
  List<Food> loadFoods([String query = '', bool includeRecipes = false, int limit = 200]) {
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
            'name COLLATE NOCASE LIMIT $limit';
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

  /// The foods with these ids (for the favourites), by name.
  List<Food> loadFoodsByIds(Iterable<String> ids, [bool includeRecipes = false]) {
    final list = ids.toList();
    if (list.isEmpty) return [];
    final marks = List.filled(list.length, '?').join(', ');
    final rs = _db.select(
        'SELECT id, name, recipe_id FROM foods WHERE deleted = 0 AND id IN ($marks)' +
            (includeRecipes ? '' : ' AND recipe_id IS NULL') +
            ' ORDER BY name COLLATE NOCASE',
        list);
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

  // ---------- routines, meal templates, favourites ----------

  List<UserItem> loadItems(String kind) {
    final rs = _db.select(
        'SELECT id, kind, data, updated_at FROM user_items '
        'WHERE kind = ? AND deleted = 0 ORDER BY updated_at DESC',
        [kind]);
    final out = <UserItem>[];
    for (final r in rs) {
      try {
        out.add(UserItem(
          r['id'] as String,
          r['kind'] as String,
          (jsonDecode(r['data'] as String) as Map).cast<String, dynamic>(),
          r['updated_at'] as int,
        ));
      } catch (_) {
        // a damaged item is skipped
      }
    }
    return out;
  }

  void saveItem(String kind, String id, Map<String, dynamic> data) {
    _db.execute(
        'INSERT INTO user_items(id, kind, data, updated_at, deleted) '
        'VALUES(?, ?, ?, ?, 0) ON CONFLICT(id) DO UPDATE SET '
        'kind = excluded.kind, data = excluded.data, '
        'updated_at = excluded.updated_at, deleted = 0',
        [id, kind, jsonEncode(data), nowMs()]);
  }

  void deleteItem(String id) {
    _db.execute('UPDATE user_items SET deleted = 1, updated_at = ? WHERE id = ?',
        [nowMs(), id]);
  }

  /// The ids of the foods you marked as favourites.
  Set<String> favoriteFoodIds() => {
        for (final i in loadItems('favorite_food'))
          if (i.data['food_id'] is String) i.data['food_id'] as String
      };

  void setFavorite(String foodId, bool favorite) {
    if (favorite) {
      saveItem('favorite_food', 'fav:$foodId', {'food_id': foodId});
    } else {
      deleteItem('fav:$foodId');
    }
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
    stamp++;
    _db.execute(
        'INSERT INTO weights(day, kg, source, updated_at, deleted) '
        'VALUES(?, ?, ?, ?, 0) '
        'ON CONFLICT(day) DO UPDATE SET kg = excluded.kg, '
        'source = excluded.source, updated_at = excluded.updated_at, deleted = 0',
        [day, kg, source, nowMs()]);
  }

  void deleteWeight(String day) {
    stamp++;
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
    stamp++;
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

  // the cheap columns (no heart rate series, no exercises)
  static const _wCols = 'id, day, start_ms, end_ms, type, title, distance_m, '
      'active_kcal, source, notes, extra, deleted';

  Workout _workoutFromRow(Row r,
      {bool withHr = false, bool withEx = false, bool withSplits = false}) {
    final core = parseExtra(r['extra']); // small
    Object? hrData;
    Object? exData;
    Object? spData;
    if (withSplits) {
      final t = (r['splits_json'] as String?) ?? '';
      spData = t.isNotEmpty ? jsonDecode(t) : null;
    }
    if (withHr) {
      final t = (r['hr_json'] as String?) ?? '';
      hrData = t.isNotEmpty ? jsonDecode(t) : core['hr'];
    }
    if (withEx) {
      final t = (r['ex_json'] as String?) ?? '';
      exData = t.isNotEmpty ? jsonDecode(t) : core['ex'];
    }
    return Workout(
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
      notes: (r['notes'] as String?) ?? '',
      origin: (core['o'] as String?) ?? '',
      metrics: {
        for (final e in ((core['m'] as Map?) ?? const {}).entries)
          e.key as String: (e.value as num).toDouble()
      },
      hr: [
        for (final p in ((hrData as List?) ?? const []))
          [((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()]
      ],
      exercises: [
        for (final e in ((exData as List?) ?? const []))
          (e as Map).cast<String, dynamic>()
      ],
      splits: [
        for (final e in ((spData as List?) ?? const []))
          (e as Map).cast<String, dynamic>()
      ],
      deleted: (r['deleted'] as int) == 1,
      light: !(withHr && withEx && withSplits),
    );
  }

  // ----- cache of all workouts (invalidated by every change) -----
  int _wVer = 0;
  List<Workout>? _allLight;
  List<Workout>? _allEx;
  int _allLightVer = -1, _allExVer = -1;

  /// Call after workouts were changed by another connection (a background
  /// isolate, a sync).
  void invalidateWorkouts() {
    _wVer++;
    stamp++;
  }

  /// Goes up whenever data that several tabs show was changed. The main
  /// screen uses it to reload a tab that was left in the background.
  static int stamp = 0;

  /// All workouts, newest first. Cached: do not modify the returned list.
  /// With [withEx] the exercises of gym sessions are included.
  List<Workout> loadAllWorkouts({bool withEx = false}) {
    if (withEx) {
      if (_allEx == null || _allExVer != _wVer) {
        _allEx = loadWorkouts('1900-01-01', withEx: true);
        _allExVer = _wVer;
      }
      return _allEx!;
    }
    if (_allLight == null || _allLightVer != _wVer) {
      _allLight = loadWorkouts('1900-01-01');
      _allLightVer = _wVer;
    }
    return _allLight!;
  }

  /// Runs [body] as ONE transaction: much faster for many writes, and all
  /// or nothing.
  T transaction<T>(T Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final r = body();
      _db.execute('COMMIT');
      return r;
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  int countWorkouts() {
    final rs = _db.select('SELECT COUNT(*) AS n FROM workouts WHERE deleted = 0');
    return rs.first['n'] as int;
  }

  /// Any workout row, also a deleted one, with everything (heart rate, exercises).
  Workout? loadWorkout(String id) {
    final rs = _db.select('SELECT * FROM workouts WHERE id = ?', [id]);
    return rs.isEmpty ? null : _workoutFromRow(rs.first,
            withHr: true, withEx: true, withSplits: true);
  }

  /// Workouts from [fromDay] on, newest first. Without heart rate series;
  /// exercises only with [withEx].
  List<Workout> loadWorkouts(String fromDay, {int? limit, bool withEx = false}) {
    final rs = _db.select(
        'SELECT $_wCols${withEx ? ', ex_json' : ''} FROM workouts '
        'WHERE deleted = 0 AND day >= ? '
        'ORDER BY start_ms DESC${limit != null ? ' LIMIT $limit' : ''}',
        [fromDay]);
    return [for (final r in rs) _workoutFromRow(r, withEx: withEx)];
  }

  void saveWorkout(Workout w) {
    invalidateWorkouts();
    const head = 'INSERT INTO workouts(id, day, start_ms, end_ms, type, title, '
        'distance_m, active_kcal, source, notes, extra, ';
    const common = 'ON CONFLICT(id) DO UPDATE SET day = excluded.day, '
        'start_ms = excluded.start_ms, end_ms = excluded.end_ms, '
        'type = excluded.type, title = excluded.title, '
        'distance_m = excluded.distance_m, active_kcal = excluded.active_kcal, '
        'source = excluded.source, notes = excluded.notes, '
        'extra = excluded.extra, updated_at = excluded.updated_at, deleted = 0';
    final base = [
      w.id, w.day, w.startMs, w.endMs, w.type, w.title, w.distanceM,
      w.activeKcal, w.source, w.notes, w.coreJson,
    ];
    if (w.light) {
      // loaded without the big columns: leave those as they are
      _db.execute(
          '${head}updated_at, deleted) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0) $common',
          [...base, nowMs()]);
    } else {
      _db.execute(
          '${head}hr_json, ex_json, splits_json, updated_at, deleted) '
          'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0) $common, '
          'hr_json = excluded.hr_json, ex_json = excluded.ex_json, '
          'splits_json = excluded.splits_json',
          [...base, w.hrJson, w.exJson, w.splitsJson, nowMs()]);
    }
  }

  /// Adds an imported workout (Health Connect, Garmin CSV, Hevy CSV).
  /// Returns 'added', 'updated', 'merged' or 'unchanged'.
  /// If ANOTHER source already recorded the same session (same kind of
  /// activity, overlapping in time), the two are merged instead of listed
  /// twice. Entries of the same source are never merged.
  String importWorkout(Workout w) {
    final old = loadWorkout(w.id);
    if (old != null) {
      if (old.deleted || old.source == 'manual') return 'unchanged';
      final next = w.copyWith(
        title: w.title.isNotEmpty ? w.title : old.title,
        notes: w.notes.isNotEmpty ? w.notes : old.notes,
        metrics: {...old.metrics, ...w.metrics},
        hr: w.hr.isNotEmpty ? w.hr : old.hr,
        exercises: w.exercises.isNotEmpty ? w.exercises : old.exercises,
        splits: w.splits.isNotEmpty ? w.splits : old.splits,
      );
      if (old.sameAs(next) &&
          old.notes == next.notes &&
          old.extraJson == next.extraJson) {
        return 'unchanged';
      }
      saveWorkout(next);
      return 'updated';
    }

    final rs = _db.select(
        'SELECT $_wCols FROM workouts WHERE deleted = 0 AND start_ms < ? AND end_ms > ?',
        [w.endMs, w.startMs]);
    Workout? best;
    var bestOverlap = 0;
    final wc = categoryOf(w.type);
    for (final r in rs) {
      final o = _workoutFromRow(r);
      if (o.source == 'manual') continue;
      // Same source is only merged when two different apps wrote the same
      // session into Health Connect (for example Hevy and Garmin Connect).
      final differentApp = o.origin.isNotEmpty &&
          w.origin.isNotEmpty &&
          o.origin != w.origin;
      if (o.source == w.source && !differentApp) continue;
      final oc = categoryOf(o.type);
      if (oc != wc && oc != Cat.other && wc != Cat.other) continue;
      final ov = (o.endMs < w.endMs ? o.endMs : w.endMs) -
          (o.startMs > w.startMs ? o.startMs : w.startMs);
      final shorter = (o.endMs - o.startMs) < (w.endMs - w.startMs)
          ? (o.endMs - o.startMs)
          : (w.endMs - w.startMs);
      if (shorter > 0 && ov >= shorter * 0.5 && ov > bestOverlap) {
        best = o;
        bestOverlap = ov;
      }
    }
    if (best == null) {
      saveWorkout(w);
      return 'added';
    }
    final full = loadWorkout(best.id) ?? best;
    final merged = full.copyWith(
      title: (w.source == 'hevy' && w.title.isNotEmpty)
          ? w.title
          : (full.title.isNotEmpty ? full.title : w.title),
      distanceM: full.distanceM == null ? w.distanceM : null,
      activeKcal: full.activeKcal == null ? w.activeKcal : null,
      notes: full.notes.isNotEmpty ? full.notes : w.notes,
      metrics: {...w.metrics, ...full.metrics},
      hr: full.hr.isNotEmpty ? full.hr : w.hr,
      exercises: full.exercises.isNotEmpty ? full.exercises : w.exercises,
      splits: full.splits.isNotEmpty ? full.splits : w.splits,
    );
    if (merged.title == full.title &&
        merged.distanceM == full.distanceM &&
        merged.activeKcal == full.activeKcal &&
        merged.notes == full.notes &&
        merged.extraJson == full.extraJson) {
      return 'unchanged';
    }
    saveWorkout(merged);
    return 'merged';
  }

  void deleteWorkout(String id) {
    invalidateWorkouts();
    _db.execute('UPDATE workouts SET deleted = 1, updated_at = ? WHERE id = ?',
        [nowMs(), id]);
  }
}
