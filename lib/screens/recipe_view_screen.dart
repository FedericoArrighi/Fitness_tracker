import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import '../recipe_dialog.dart';
import 'recipe_edit_screen.dart';

class RecipeViewScreen extends StatefulWidget {
  final String recipeId;
  const RecipeViewScreen({super.key, required this.recipeId});

  @override
  State<RecipeViewScreen> createState() => _RecipeViewScreenState();
}

class _RecipeViewScreenState extends State<RecipeViewScreen> {
  Recipe? _r;
  double _servings = 1; // only used to scale the ingredient list

  @override
  void initState() {
    super.initState();
    _load(resetServings: true);
  }

  void _load({bool resetServings = false}) {
    final r = AppDb.instance.loadRecipe(widget.recipeId);
    setState(() {
      _r = r;
      if (r != null && resetServings) _servings = r.servings;
    });
  }

  Future<void> _edit() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => RecipeEditScreen(recipe: _r)),
    );
    if (!mounted) return;
    if (result == 'deleted') {
      Navigator.pop(context, true);
    } else if (result == 'saved') {
      _load(resetServings: true);
    }
  }

  Future<void> _log() async {
    final r = _r!;
    final res = await askRecipeAmount(context, r, askMealAndDay: true);
    if (res == null || !mounted) return;
    final day = dayKey(res.day!);
    final id = AppDb.instance.addEntry(day, res.meal!, r.id, res.grams);
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text('Added to ${res.meal} on $day.'),
      persist: false,
      duration: const Duration(seconds: 3),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => AppDb.instance.deleteEntry(id),
      ),
    ));
  }

  Widget _row(Nutrient n, Map<String, double> per) {
    final v = per[n.key];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(n.name),
          Text(v == null ? 'unknown' : '${fmt(v)} ${n.unit}'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    if (r == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Recipe not found.')),
      );
    }
    final scale = r.servings > 0 ? _servings / r.servings : 1.0;
    final per = r.perServing();
    final title = Theme.of(context).textTheme.titleMedium;
    final tags = r.tags
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(r.name),
        actions: [
          IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit',
              onPressed: _edit),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _log,
        icon: const Icon(Icons.add),
        label: const Text('Add to log'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          if (tags.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [for (final t in tags) Chip(label: Text(t))],
            ),
          Row(
            children: [
              Text('Ingredients for', style: title),
              IconButton(
                icon: const Icon(Icons.remove),
                onPressed: _servings > 1
                    ? () => setState(() => _servings -= 1)
                    : null,
              ),
              Text('${fmt(_servings)} servings', style: title),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => setState(() => _servings += 1),
              ),
            ],
          ),
          for (final i in r.ingredients)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(i.food.name),
              trailing: Text('${fmt(i.grams * scale)} g'),
            ),
          const SizedBox(height: 16),
          Text('Nutrition per serving', style: title),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                      '1 serving = ${fmt(r.gramsPerServing)} g of the finished dish',
                      style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  for (final n in nutrients.where((n) => n.group == 'Macros'))
                    _row(n, per),
                  ExpansionTile(
                    title: const Text('Other nutrients'),
                    tilePadding: EdgeInsets.zero,
                    children: [
                      for (final n in nutrients.where((n) => n.group != 'Macros'))
                        _row(n, per),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Text(
              '"Unknown" means at least one ingredient has no value for that nutrient. '
              'Fill it in on the food (enter 0 if it truly contains none).',
              style: TextStyle(fontSize: 12)),
          if (r.steps.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Steps', style: title),
            const SizedBox(height: 4),
            Text(r.steps),
          ],
          if (r.notes.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Notes', style: title),
            const SizedBox(height: 4),
            Text(r.notes),
          ],
        ],
      ),
    );
  }
}
