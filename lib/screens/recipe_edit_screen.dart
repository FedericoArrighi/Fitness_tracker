import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import '../widgets.dart';
import 'foods_screen.dart';

/// Pops with 'saved' or 'deleted'.
class RecipeEditScreen extends StatefulWidget {
  final Recipe? recipe; // null = new recipe
  const RecipeEditScreen({super.key, this.recipe});

  @override
  State<RecipeEditScreen> createState() => _RecipeEditScreenState();
}

class _RecipeEditScreenState extends State<RecipeEditScreen> {
  late final String _id;
  final _name = TextEditingController();
  final _servings = TextEditingController(text: '4');
  final _cooked = TextEditingController();
  final _steps = TextEditingController();
  final _notes = TextEditingController();
  final _tags = TextEditingController();
  List<RecipeIngredient> _ings = [];

  @override
  void initState() {
    super.initState();
    final r = widget.recipe;
    _id = r?.id ?? newId();
    if (r != null) {
      _name.text = r.name;
      _servings.text = rawNum(r.servings);
      if (r.cookedGrams != null) _cooked.text = rawNum(r.cookedGrams!);
      _steps.text = r.steps;
      _notes.text = r.notes;
      _tags.text = r.tags;
      _ings = List.of(r.ingredients);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _servings, _cooked, _steps, _notes, _tags]) {
      c.dispose();
    }
    super.dispose();
  }

  Recipe _draft() {
    final cooked = parseNum(_cooked.text);
    return Recipe(
      id: _id,
      name: _name.text.trim(),
      servings: parseNum(_servings.text) ?? 0,
      cookedGrams: (cooked != null && cooked > 0) ? cooked : null,
      steps: _steps.text.trim(),
      notes: _notes.text.trim(),
      tags: _tags.text.trim(),
      ingredients: _ings,
    );
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _addIngredient() async {
    final food = await Navigator.push<Food>(
      context,
      MaterialPageRoute(builder: (_) => const FoodsScreen(pickMode: true)),
    );
    if (food == null || !mounted) return;
    final g = await askGrams(context, food.name);
    if (g == null) return;
    setState(() => _ings.add(RecipeIngredient(food: food, grams: g)));
  }

  Future<void> _editGrams(int i) async {
    final g = await askGrams(context, _ings[i].food.name,
        initial: rawNum(_ings[i].grams));
    if (g == null) return;
    setState(() => _ings[i] = RecipeIngredient(food: _ings[i].food, grams: g));
  }

  void _save() {
    final r = _draft();
    if (r.name.isEmpty) return _snack('Enter a name for the recipe.');
    if (r.servings <= 0) return _snack('Servings must be greater than 0.');
    if (r.ingredients.isEmpty) return _snack('Add at least one ingredient.');
    AppDb.instance.saveRecipe(r);
    Navigator.pop(context, 'saved');
  }

  void _delete() {
    AppDb.instance.deleteRecipe(_id);
    Navigator.pop(context, 'deleted');
  }

  @override
  Widget build(BuildContext context) {
    final d = _draft();
    final kcal = d.servings > 0 ? d.perServing()['calories'] : null;
    final title = Theme.of(context).textTheme.titleMedium;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.recipe == null ? 'New recipe' : 'Edit recipe'),
        actions: [
          if (widget.recipe != null)
            IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete recipe',
                onPressed: _delete),
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
                labelText: 'Name', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          numField(
              controller: _servings,
              label: 'Servings',
              onChanged: (_) => setState(() {})),
          numField(
              controller: _cooked,
              label: 'Weight of finished dish (optional)',
              suffix: 'g',
              onChanged: (_) => setState(() {})),
          const Text(
              'If you leave the weight blank, the sum of the ingredients is used. '
              'Enter it if the dish loses or gains water when cooked.'),
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 4),
            child: Text('Ingredients', style: title),
          ),
          for (var i = 0; i < _ings.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_ings[i].food.name),
              subtitle: Text('${fmt(_ings[i].grams)} g'),
              onTap: () => _editGrams(i),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Remove',
                onPressed: () => setState(() => _ings.removeAt(i)),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addIngredient,
              icon: const Icon(Icons.add),
              label: const Text('Add ingredient'),
            ),
          ),
          if (_ings.isNotEmpty)
            Text(kcal == null
                ? 'Per serving: calories unknown (an ingredient has no calorie value).'
                : 'Per serving: ${fmt(kcal)} kcal'),
          const SizedBox(height: 16),
          TextField(
            controller: _steps,
            minLines: 4,
            maxLines: null,
            decoration: const InputDecoration(
                labelText: 'Steps', alignLabelWithHint: true, border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            minLines: 2,
            maxLines: null,
            decoration: const InputDecoration(
                labelText: 'Notes', alignLabelWithHint: true, border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
                labelText: 'Tags (comma separated)', border: OutlineInputBorder()),
          ),
        ],
      ),
    );
  }
}
