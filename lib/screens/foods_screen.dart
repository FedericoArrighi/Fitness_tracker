import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import '../online.dart';
import 'barcode_screen.dart';
import 'food_edit_screen.dart';
import 'online_search_screen.dart';

class _Out {
  final List<Food> foods;
  final String? error;
  _Out(this.foods, [this.error]);
}

Future<_Out> _guard(Future<List<Food>> Function() f) async {
  try {
    return _Out(await f());
  } catch (e) {
    return _Out([], e.toString().replaceFirst('Exception: ', ''));
  }
}

/// The food list with search-as-you-type. Your own foods appear instantly;
/// online results (USDA whole foods + Open Food Facts packaged products)
/// are added a moment later.
///
/// pickMode = true: used to choose a food for the log. Tapping an online
/// result saves it to your foods right away and returns it, so logging
/// takes two taps.
class FoodsScreen extends StatefulWidget {
  final bool pickMode;

  /// In pickMode, also list recipes (for logging, not for ingredients).
  final bool includeRecipes;
  const FoodsScreen({super.key, this.pickMode = false, this.includeRecipes = false});

  @override
  State<FoodsScreen> createState() => _FoodsScreenState();
}

class _FoodsScreenState extends State<FoodsScreen> {
  static final Map<String, List<Food>> _cache = {}; // query -> online results

  String _query = '';
  List<Food> _local = [];
  List<Food> _online = [];
  bool _loadingOnline = false;
  String? _onlineError;
  int _token = 0; // identifies the latest search; older answers are ignored
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _loadLocal() {
    setState(() {
      final withRecipes = widget.pickMode && widget.includeRecipes;
      var list = AppDb.instance.loadFoods(_query, withRecipes);
      if (widget.pickMode && _query.trim().isEmpty) {
        final recent = AppDb.instance.loadRecentFoods(15, withRecipes);
        final ids = recent.map((f) => f.id).toSet();
        list = [...recent, ...list.where((f) => !ids.contains(f.id))];
      }
      _local = list;
    });
  }

  void _onChanged(String v) {
    _query = v;
    _loadLocal(); // instant
    _debounce?.cancel();
    final q = v.trim();
    if (q.length < 3) {
      _token++;
      setState(() {
        _online = [];
        _loadingOnline = false;
        _onlineError = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _runOnline(q));
  }

  Future<void> _runOnline(String q) async {
    final cached = _cache[q.toLowerCase()];
    if (cached != null) {
      setState(() {
        _online = cached;
        _loadingOnline = false;
        _onlineError = null;
      });
      return;
    }
    final token = ++_token;
    setState(() {
      _loadingOnline = true;
      _onlineError = null;
    });

    List<Food> merged;
    String? error;
    if (RegExp(r'^\d{8,14}$').hasMatch(q)) {
      // typed barcode
      final r = await _guard(() async {
        final f = await lookupBarcode(q);
        return f == null ? <Food>[] : [f];
      });
      merged = r.foods;
      error = r.error;
    } else {
      final key = AppDb.instance.getSetting('usda_api_key');
      final results = await Future.wait([
        _guard(() => searchUsda(q, (key == null || key.isEmpty) ? 'DEMO_KEY' : key)),
        _guard(() => searchOpenFoodFacts(q)),
      ]);
      // Alternate between the two sources so both types show near the top.
      final a = results[0].foods, b = results[1].foods;
      merged = [];
      for (var i = 0; i < max(a.length, b.length); i++) {
        if (i < a.length) merged.add(a[i]);
        if (i < b.length) merged.add(b[i]);
      }
      error = results[0].error ?? results[1].error;
      if (merged.isNotEmpty && results[0].error == null && results[1].error == null) {
        _cache[q.toLowerCase()] = merged;
      }
    }

    if (!mounted || token != _token) return; // a newer search replaced this one
    setState(() {
      _online = merged;
      _loadingOnline = false;
      _onlineError = error;
    });
  }

  Future<void> _editLocal([Food? f]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => FoodEditScreen(food: f)),
    );
    if (changed == true) _loadLocal();
  }

  Future<void> _tapOnline(Food f) async {
    if (widget.pickMode) {
      AppDb.instance.saveFood(f); // keep it for next time
      if (!mounted) return;
      Navigator.pop(context, f);
      return;
    }
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => FoodEditScreen(food: f, isDraft: true)),
    );
    if (saved == true) _loadLocal();
  }

  Future<void> _scan() async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BarcodeScreen()),
    );
    if (code == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
        content: Text('Looking up $code ...'), duration: const Duration(seconds: 2)));
    try {
      final f = await lookupBarcode(code);
      if (!mounted) return;
      if (f == null) {
        messenger.showSnackBar(SnackBar(
            content: Text('The barcode $code is not in Open Food Facts.'),
            duration: const Duration(seconds: 4)));
        return;
      }
      await _tapOnline(f);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text('Lookup failed: $e'), duration: const Duration(seconds: 4)));
    }
  }

  Future<void> _openSearchScreen() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const OnlineSearchScreen()),
    );
    if (saved == true) _loadLocal();
  }

  // Online results that are not already among your own foods.
  List<Food> _visibleOnline() {
    final localNames = _local.map((f) => f.name.toLowerCase()).toSet();
    return _online
        .where((f) => !localNames.contains(f.name.toLowerCase()))
        .toList();
  }

  // Enter in the picker: take the top result (your own foods first).
  void _submit(String _) {
    if (!widget.pickMode || _query.trim().isEmpty) return;
    if (_local.isNotEmpty) {
      Navigator.pop(context, _local.first);
      return;
    }
    final online = _visibleOnline();
    if (online.isNotEmpty) _tapOnline(online.first);
  }

  String _summary(Food f) {
    String v(String key) {
      final x = f.values[key];
      return x == null ? '?' : fmt(x);
    }

    return '${v('calories')} kcal  P ${v('protein')}  C ${v('carbs')}  F ${v('fat')}'
        '  per 100 g  (${f.values.length}/${nutrients.length} values)';
  }

  @override
  Widget build(BuildContext context) {
    final online = _visibleOnline();
    final nothing = _local.isEmpty && online.isEmpty && !_loadingOnline;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pickMode ? 'Choose a food' : 'Foods'),
        actions: [
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: 'Scan a barcode',
              onPressed: _scan,
            ),
          IconButton(
            icon: const Icon(Icons.travel_explore),
            tooltip: 'Online search by source',
            onPressed: _openSearchScreen,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _editLocal(),
        tooltip: 'New food',
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              autofocus: widget.pickMode,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: widget.pickMode && widget.includeRecipes
                    ? 'Search foods, recipes and online'
                    : 'Search your foods and online',
                border: const OutlineInputBorder(),
              ),
              onChanged: _onChanged,
              onSubmitted: _submit,
            ),
          ),
          if (_loadingOnline) const LinearProgressIndicator(),
          if (_onlineError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Text('Online search: $_onlineError',
                  style: TextStyle(
                      fontSize: 12, color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(
            child: nothing
                ? Center(
                    child: Text(_query.trim().length < 3
                        ? 'No foods yet. Tap + or type to search online.'
                        : 'No results.'))
                : ListView(
                    children: [
                      for (final f in _local)
                        ListTile(
                          leading: f.isRecipe
                              ? const Icon(Icons.menu_book_outlined)
                              : null,
                          title: Text(f.name),
                          subtitle: Text((f.isRecipe ? 'Recipe - ' : '') +
                              (f.values['calories'] == null
                                  ? 'No calorie value'
                                  : '${fmt(f.values['calories']!)} kcal / 100 g')),
                          onTap: () => widget.pickMode
                              ? Navigator.pop(context, f)
                              : _editLocal(f),
                        ),
                      if (online.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                          child: Text('Online results',
                              style: Theme.of(context).textTheme.titleSmall),
                        ),
                      for (final f in online)
                        ListTile(
                          leading: Icon(f.source == 'USDA'
                              ? Icons.eco_outlined
                              : Icons.inventory_2_outlined),
                          title: Text(f.name),
                          subtitle: Text('${f.source} - ${_summary(f)}'),
                          onTap: () => _tapOnline(f),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
