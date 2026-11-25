import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../db.dart';
import '../nutrients.dart';
import '../recipe_dialog.dart';
import '../widgets.dart';
import 'foods_screen.dart';

class _ClipItem {
  final String foodId;
  final double grams;
  final String meal;
  const _ClipItem(this.foodId, this.grams, this.meal);
}

/// One undoable step: entries it added and entries it removed.
class _Action {
  final String label;
  final String day;
  final List<String> added;
  final List<String> removed;
  const _Action(this.label, this.day, this.added, this.removed);
}

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  // Static, so they survive switching tabs (the screen is rebuilt each time).
  static List<_ClipItem> _clip = [];
  static String _clipLabel = '';
  static final List<_Action> _undoStack = [];
  static final List<_Action> _redoStack = [];

  final FocusNode _focus = FocusNode();
  String? _selected; // the meal selected with a click, if any

  DateTime _date = DateTime.now();
  List<LogEntry> _entries = [];
  Map<String, double> _targets = {};

  bool get _isDesktop => const [
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS
      ].contains(defaultTargetPlatform);

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _load() {
    setState(() {
      _entries = AppDb.instance.loadDay(dayKey(_date));
      _targets = AppDb.instance.loadTargets();
    });
  }

  void _goTo(String day) {
    final p = day.split('-').map(int.parse).toList();
    _date = DateTime(p[0], p[1], p[2]);
    _load();
  }

  void _shiftDay(int days) {
    _date = DateTime(_date.year, _date.month, _date.day + days);
    _load();
  }

  /// A swipe with the finger: to the left shows the next day, to the right
  /// the day before.
  void _onSwipe(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v > 300) {
      _shiftDay(-1);
    } else if (v < -300) {
      _shiftDay(1);
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      _date = d;
      _load();
    }
  }

  void _select(String meal) {
    setState(() => _selected = _selected == meal ? null : meal);
    _focus.requestFocus();
  }

  // ---------- undo / redo ----------

  void _snack(String msg, {bool undo = false}) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(msg),
      persist: false,
      duration: Duration(seconds: undo ? 3 : 2),
      action: undo ? SnackBarAction(label: 'Undo', onPressed: _undo) : null,
    ));
  }

  void _record(String label,
      {List<String> added = const [],
      List<String> removed = const [],
      bool notify = false}) {
    _undoStack.add(_Action(label, dayKey(_date), added, removed));
    _redoStack.clear();
    _load();
    if (notify) _snack(label, undo: true);
  }

  void _undo() {
    if (_undoStack.isEmpty) {
      _snack('Nothing to undo.');
      return;
    }
    final a = _undoStack.removeLast();
    for (final id in a.added) {
      AppDb.instance.deleteEntry(id);
    }
    for (final id in a.removed) {
      AppDb.instance.restoreEntry(id);
    }
    _redoStack.add(a);
    _goTo(a.day);
    _snack('Undid: ${a.label}.');
  }

  void _redo() {
    if (_redoStack.isEmpty) {
      _snack('Nothing to redo.');
      return;
    }
    final a = _redoStack.removeLast();
    for (final id in a.added) {
      AppDb.instance.restoreEntry(id);
    }
    for (final id in a.removed) {
      AppDb.instance.deleteEntry(id);
    }
    _undoStack.add(a);
    _goTo(a.day);
    _snack('Redid: ${a.label}.');
  }

  // ---------- adding and removing ----------

  Future<void> _add(String meal, {bool favorites = false}) async {
    setState(() => _selected = meal);
    final food = await Navigator.push<Food>(
      context,
      MaterialPageRoute(
          builder: (_) => FoodsScreen(
              pickMode: true,
              includeRecipes: true,
              initialFavorites: favorites,
              meal: meal)),
    );
    if (food == null || !mounted) return;
    double? grams;
    final recipe = food.isRecipe ? AppDb.instance.loadRecipe(food.id) : null;
    if (recipe != null) {
      // servings or grams of the finished dish
      grams = (await askRecipeAmount(context, recipe))?.grams;
    } else {
      grams = await askGrams(context, food.name);
    }
    if (grams == null) return;
    final id = AppDb.instance.addEntry(dayKey(_date), meal, food.id, grams);
    _record('Added ${food.name}', added: [id]);
    if (mounted) _focus.requestFocus();
  }

  void _removeEntry(LogEntry e) {
    AppDb.instance.deleteEntry(e.id);
    _record('Removed ${e.foodName}', removed: [e.id], notify: true);
  }

  // ---------- copy / cut / paste ----------

  List<_ClipItem> _itemsOf(Iterable<LogEntry> es) =>
      [for (final e in es) _ClipItem(e.foodId, e.grams, e.meal)];

  void _copyMeal(String meal) {
    final es = _entries.where((e) => e.meal == meal).toList();
    if (es.isEmpty) {
      _snack('$meal is empty, nothing to copy.');
      return;
    }
    setState(() {
      _clip = _itemsOf(es);
      _clipLabel = meal;
    });
    _snack('Copied ${es.length} item(s) from $meal.');
  }

  void _copyDay() {
    if (_entries.isEmpty) {
      _snack('Nothing logged on this day.');
      return;
    }
    setState(() {
      _clip = _itemsOf(_entries);
      _clipLabel = 'whole day';
    });
    _snack('Copied ${_entries.length} item(s) from the whole day.');
  }

  void _cutMeal(String meal) {
    final es = _entries.where((e) => e.meal == meal).toList();
    if (es.isEmpty) {
      _snack('$meal is empty, nothing to cut.');
      return;
    }
    _clip = _itemsOf(es);
    _clipLabel = meal;
    for (final e in es) {
      AppDb.instance.deleteEntry(e.id);
    }
    _record('Cut ${es.length} item(s) from $meal',
        removed: [for (final e in es) e.id], notify: true);
  }

  void _clearMeal(String meal) {
    final es = _entries.where((e) => e.meal == meal).toList();
    if (es.isEmpty) return;
    for (final e in es) {
      AppDb.instance.deleteEntry(e.id);
    }
    _record('Cleared $meal (${es.length} item(s))',
        removed: [for (final e in es) e.id], notify: true);
  }

  // Paste everything into one meal.
  void _pasteInto(String meal) {
    if (_clip.isEmpty) {
      _snack('The clipboard is empty.');
      return;
    }
    final day = dayKey(_date);
    final ids = [
      for (final c in _clip) AppDb.instance.addEntry(day, meal, c.foodId, c.grams)
    ];
    _record('Pasted ${ids.length} item(s) into $meal', added: ids, notify: true);
  }

  // Paste each item into the meal it was copied from.
  void _pasteDay() {
    if (_clip.isEmpty) {
      _snack('The clipboard is empty.');
      return;
    }
    final day = dayKey(_date);
    final ids = [
      for (final c in _clip) AppDb.instance.addEntry(day, c.meal, c.foodId, c.grams)
    ];
    _record('Pasted ${ids.length} item(s), each into its own meal',
        added: ids, notify: true);
  }

  void _copyYesterday() {
    final prev = DateTime(_date.year, _date.month, _date.day - 1);
    final items = AppDb.instance.loadDay(dayKey(prev));
    if (items.isEmpty) {
      _snack('Nothing was logged the day before.');
      return;
    }
    final day = dayKey(_date);
    final ids = [
      for (final e in items) AppDb.instance.addEntry(day, e.meal, e.foodId, e.grams)
    ];
    _record('Copied ${ids.length} item(s) from the day before',
        added: ids, notify: true);
  }

  /// Copies the meals of any day to the day on show.
  Future<void> _copyFromDay() async {
    final d = await showDatePicker(
      context: context,
      helpText: 'Copy the meals of which day?',
      initialDate: DateTime(_date.year, _date.month, _date.day - 1),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    final items = AppDb.instance.loadDay(dayKey(d));
    if (items.isEmpty) {
      _snack('Nothing was logged on ${d.day}.${d.month}.${d.year}.');
      return;
    }
    final day = dayKey(_date);
    final ids = [
      for (final e in items) AppDb.instance.addEntry(day, e.meal, e.foodId, e.grams)
    ];
    _record('Copied ${ids.length} item(s) from ${d.day}.${d.month}.${d.year}',
        added: ids, notify: true);
  }

  /// Copies one meal of any day into this meal of the day on show.
  Future<void> _copyMealFromDay(String meal) async {
    final d = await showDatePicker(
      context: context,
      helpText: 'Copy a meal from which day?',
      initialDate: DateTime(_date.year, _date.month, _date.day - 1),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    final label = '${d.day}.${d.month}.${d.year}';
    final items = AppDb.instance.loadDay(dayKey(d));
    final present = [
      for (final m in meals)
        if (items.any((e) => e.meal == m)) m
    ];
    if (present.isEmpty) {
      _snack('Nothing was logged on $label.');
      return;
    }
    final String from;
    if (present.length == 1) {
      from = present.first;
    } else {
      // the same meal of that day comes first
      final ordered = [
        if (present.contains(meal)) meal,
        ...present.where((m) => m != meal),
      ];
      final pick = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text('Which meal of $label?'),
          children: [
            for (final m in ordered)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, m),
                child: Text('$m (${items.where((e) => e.meal == m).length} items)'),
              ),
          ],
        ),
      );
      if (pick == null || !mounted) return;
      from = pick;
    }
    final day = dayKey(_date);
    final ids = [
      for (final e in items)
        if (e.meal == from) AppDb.instance.addEntry(day, meal, e.foodId, e.grams)
    ];
    _record('Copied ${ids.length} item(s) of $from from $label into $meal',
        added: ids, notify: true);
  }

  // ---------- meal templates and favourites ----------

  Future<String?> _askMeal() => showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Which meal?'),
          children: [
            for (final m in meals)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, m),
                child: Text(m),
              ),
          ],
        ),
      );

  Future<void> _saveMealTemplate(String meal) async {
    final es = _entries.where((e) => e.meal == meal).toList();
    if (es.isEmpty) {
      _snack('$meal is empty, nothing to save.');
      return;
    }
    final c = TextEditingController(text: meal);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save as meal template'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: c,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Template name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text('${es.length} item(s) with their amounts.',
                style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    final name = c.text.trim();
    if (ok != true || name.isEmpty) return;
    AppDb.instance.saveItem('meal_template', newId(), {
      'name': name,
      'meal': meal,
      'items': [
        for (final e in es) {'food_id': e.foodId, 'grams': e.grams}
      ],
    });
    _snack('Saved the template "$name".');
  }

  double _templateKcal(UserItem t) {
    var kcal = 0.0;
    for (final it in ((t.data['items'] as List?) ?? const [])) {
      final m = (it as Map).cast<String, dynamic>();
      final food = AppDb.instance.loadFood((m['food_id'] ?? '').toString());
      final g = (m['grams'] as num?)?.toDouble() ?? 0;
      kcal += (food?.values['calories'] ?? 0) * g / 100;
    }
    return kcal;
  }

  Future<UserItem?> _pickTemplate() async {
    var items = AppDb.instance.loadItems('meal_template');
    if (items.isEmpty) {
      _snack('No meal templates yet. Open the menu of a meal and choose "Save as template".');
      return null;
    }
    return showDialog<UserItem>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setS) => SimpleDialog(
          title: const Text('Meal templates'),
          children: [
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No templates left.'),
              ),
            for (final t in items)
              ListTile(
                title: Text((t.data['name'] ?? '').toString()),
                subtitle: Text(
                    '${((t.data['items'] as List?) ?? const []).length} item(s), '
                    '${fmt(_templateKcal(t))} kcal'),
                onTap: () => Navigator.pop(context, t),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete the template',
                  onPressed: () {
                    AppDb.instance.deleteItem(t.id);
                    setS(() => items = AppDb.instance.loadItems('meal_template'));
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _applyTemplate(UserItem t, String meal) {
    final day = dayKey(_date);
    final ids = <String>[];
    for (final it in ((t.data['items'] as List?) ?? const [])) {
      final m = (it as Map).cast<String, dynamic>();
      final fid = (m['food_id'] ?? '').toString();
      final g = (m['grams'] as num?)?.toDouble() ?? 0;
      if (fid.isEmpty || g <= 0 || AppDb.instance.loadFood(fid) == null) continue;
      ids.add(AppDb.instance.addEntry(day, meal, fid, g));
    }
    if (ids.isEmpty) {
      _snack('Nothing could be added: the foods of this template no longer exist.');
      return;
    }
    _record('Added ${t.data['name']} to $meal', added: ids, notify: true);
  }

  Future<void> _addTemplateTo(String meal) async {
    final t = await _pickTemplate();
    if (t != null && mounted) _applyTemplate(t, meal);
  }

  /// From the quick bar: the template goes into the meal it was saved from.
  Future<void> _quickTemplate() async {
    final t = await _pickTemplate();
    if (t == null || !mounted) return;
    var meal = (t.data['meal'] ?? '').toString();
    if (!meals.contains(meal)) {
      final asked = await _askMeal();
      if (asked == null) return;
      meal = asked;
    }
    _applyTemplate(t, meal);
  }

  Future<void> _quickFavorites() async {
    final meal = _selected ?? await _askMeal();
    if (meal == null || !mounted) return;
    await _add(meal, favorites: true);
  }

  // ---------- keyboard shortcuts ----------

  void _copySelected() =>
      _selected != null ? _copyMeal(_selected!) : _copyDay();

  void _cutSelected() {
    if (_selected == null) {
      _snack('Click a meal name first, then press Ctrl+X.');
    } else {
      _cutMeal(_selected!);
    }
  }

  void _pasteSelected() =>
      _selected != null ? _pasteInto(_selected!) : _pasteDay();

  void _clearSelected() {
    if (_selected != null) _clearMeal(_selected!);
  }

  // ---------- display ----------

  Widget _bar(Nutrient n, Map<String, double> totals, Set<String> incomplete) {
    final v = totals[n.key] ?? 0;
    final t = _targets[n.key];
    final star = incomplete.contains(n.key) ? '*' : '';
    final target = t != null ? ' / ${fmt(t)}' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(n.name),
              Text('${fmt(v)}$star$target ${n.unit}'),
            ],
          ),
          if (t != null && t > 0)
            LinearProgressIndicator(value: (v / t).clamp(0.0, 1.0).toDouble()),
        ],
      ),
    );
  }

  Widget _mealSection(String meal) {
    final es = _entries.where((e) => e.meal == meal).toList();
    final kcal = es.fold<double>(
        0, (s, e) => s + (e.values['calories'] ?? 0) * e.grams / 100);
    final selected = _selected == meal;
    return Card(
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: Column(
        children: [
          ListTile(
            selected: selected,
            onTap: () => _select(meal),
            title: Text(meal, style: Theme.of(context).textTheme.titleMedium),
            subtitle: Text('${fmt(kcal)} kcal'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PopupMenuButton<String>(
                  tooltip: 'Copy, cut or paste',
                  onSelected: (v) {
                    if (v == 'copy') _copyMeal(meal);
                    if (v == 'cut') _cutMeal(meal);
                    if (v == 'paste') _pasteInto(meal);
                    if (v == 'copyfrom') _copyMealFromDay(meal);
                    if (v == 'savetpl') _saveMealTemplate(meal);
                    if (v == 'addtpl') _addTemplateTo(meal);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'copy',
                        enabled: es.isNotEmpty,
                        child: const Text('Copy this meal')),
                    PopupMenuItem(
                        value: 'cut',
                        enabled: es.isNotEmpty,
                        child: const Text('Cut this meal')),
                    PopupMenuItem(
                        value: 'paste',
                        enabled: _clip.isNotEmpty,
                        child: Text(_clip.isEmpty
                            ? 'Paste'
                            : 'Paste $_clipLabel (${_clip.length} items)')),
                    const PopupMenuItem(
                        value: 'copyfrom',
                        child: Text('Copy a meal from another day...')),
                    PopupMenuItem(
                        value: 'savetpl',
                        enabled: es.isNotEmpty,
                        child: const Text('Save as template...')),
                    const PopupMenuItem(
                        value: 'addtpl', child: Text('Add a template...')),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add food to $meal',
                  onPressed: () => _add(meal),
                ),
              ],
            ),
          ),
          for (final e in es)
            ListTile(
              dense: true,
              title: Text(e.foodName),
              subtitle: Text('${fmt(e.grams)} g'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${fmt((e.values['calories'] ?? 0) * e.grams / 100)} kcal'),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove',
                    onPressed: () => _removeEntry(e),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totals = <String, double>{};
    final incomplete = <String>{};
    for (final e in _entries) {
      for (final n in nutrients) {
        final v = e.values[n.key];
        if (v == null) {
          incomplete.add(n.key);
        } else {
          totals[n.key] = (totals[n.key] ?? 0) + v * e.grams / 100;
        }
      }
    }
    final macros = nutrients.where((n) => n.group == 'Macros');
    final others = nutrients.where((n) => n.group != 'Macros');

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): _copySelected,
        const SingleActivator(LogicalKeyboardKey.keyX, control: true): _cutSelected,
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): _pasteSelected,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): _redo,
        const SingleActivator(LogicalKeyboardKey.delete): _clearSelected,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _shiftDay(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _shiftDay(1),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            setState(() => _selected = null),
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            centerTitle: true,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => _shiftDay(-1)),
                TextButton(
                  onPressed: _pickDate,
                  child: Text(
                      '${_weekdays[_date.weekday - 1]} ${_date.day}.${_date.month}.${_date.year}'),
                ),
                IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => _shiftDay(1)),
              ],
            ),
            actions: [
              PopupMenuButton<String>(
                tooltip: 'Day actions',
                onSelected: (v) {
                  if (v == 'copyday') _copyDay();
                  if (v == 'pasteday') _pasteDay();
                  if (v == 'yesterday') _copyYesterday();
                  if (v == 'copyfrom') _copyFromDay();
                  if (v == 'undo') _undo();
                  if (v == 'redo') _redo();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'undo',
                      enabled: _undoStack.isNotEmpty,
                      child: const Text('Undo (Ctrl+Z)')),
                  PopupMenuItem(
                      value: 'redo',
                      enabled: _redoStack.isNotEmpty,
                      child: const Text('Redo (Ctrl+Y)')),
                  PopupMenuItem(
                      value: 'copyday',
                      enabled: _entries.isNotEmpty,
                      child: const Text('Copy whole day')),
                  PopupMenuItem(
                      value: 'pasteday',
                      enabled: _clip.isNotEmpty,
                      child: const Text('Paste into this day (keeps meals)')),
                  const PopupMenuItem(
                      value: 'yesterday',
                      child: Text("Copy the day before's meals here")),
                  const PopupMenuItem(
                      value: 'copyfrom', child: Text('Copy the meals of another day...')),
                ],
              ),
            ],
          ),
          body: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: _isDesktop ? null : _onSwipe,
            child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (_isDesktop)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                    'Click a meal name to select it.  Ctrl+C copy, Ctrl+X cut, Ctrl+V paste, '
                    'Del clear, Ctrl+Z undo, Ctrl+Y redo, Esc deselect. '
                    'With no meal selected, Ctrl+C copies the whole day.',
                    style: TextStyle(fontSize: 12)),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 0,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.content_copy, size: 18),
                        label: const Text('Copy yesterday'),
                        onPressed: _copyYesterday,
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.event, size: 18),
                        label: const Text('Copy from a day...'),
                        onPressed: _copyFromDay,
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.bookmark_border, size: 18),
                        label: const Text('Meal templates'),
                        onPressed: _quickTemplate,
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.star_border, size: 18),
                        label: const Text('Favourites'),
                        onPressed: _quickFavorites,
                      ),
                    ],
                  ),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      for (final n in macros) _bar(n, totals, incomplete),
                      ExpansionTile(
                        title: const Text('Other nutrients'),
                        tilePadding: EdgeInsets.zero,
                        children: [
                          for (final n in others) _bar(n, totals, incomplete),
                        ],
                      ),
                      if (incomplete.isNotEmpty)
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                              '* Some foods have no value for this nutrient, so the total is incomplete.',
                              style: TextStyle(fontSize: 12)),
                        ),
                    ],
                  ),
                ),
              ),
              for (final m in meals) _mealSection(m),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
