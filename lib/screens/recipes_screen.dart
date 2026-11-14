import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import 'recipe_edit_screen.dart';
import 'recipe_view_screen.dart';

class RecipesScreen extends StatefulWidget {
  const RecipesScreen({super.key});

  @override
  State<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends State<RecipesScreen> {
  String _query = '';
  List<Recipe> _recipes = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() => _recipes = AppDb.instance.loadRecipes(_query));
  }

  Future<void> _create() async {
    await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const RecipeEditScreen()),
    );
    _load();
  }

  Future<void> _open(Recipe r) async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => RecipeViewScreen(recipeId: r.id)),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recipes')),
      floatingActionButton: FloatingActionButton(
        onPressed: _create,
        tooltip: 'New recipe',
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search recipes',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) {
                _query = v;
                _load();
              },
            ),
          ),
          Expanded(
            child: _recipes.isEmpty
                ? const Center(child: Text('No recipes yet. Tap + to add one.'))
                : ListView.builder(
                    itemCount: _recipes.length,
                    itemBuilder: (context, i) {
                      final r = _recipes[i];
                      final kcal = r.perServing()['calories'];
                      final kcalText = kcal == null
                          ? 'calories unknown'
                          : '${fmt(kcal)} kcal per serving';
                      return ListTile(
                        title: Text(r.name),
                        subtitle: Text('${fmt(r.servings)} servings, $kcalText'),
                        onTap: () => _open(r),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
