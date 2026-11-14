import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import '../online.dart';
import 'food_edit_screen.dart';

/// Search Open Food Facts or USDA. Tapping a result opens the food form
/// pre-filled, so you can check the values before saving. Pops true if a
/// food was saved.
class OnlineSearchScreen extends StatefulWidget {
  const OnlineSearchScreen({super.key});

  @override
  State<OnlineSearchScreen> createState() => _OnlineSearchScreenState();
}

class _OnlineSearchScreenState extends State<OnlineSearchScreen> {
  final _ctl = TextEditingController();
  String _source = 'off'; // 'off' = Open Food Facts, 'usda'
  List<Food> _results = [];
  bool _loading = false;
  bool _searched = false;
  String? _error;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _ctl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      List<Food> r;
      if (_source == 'off') {
        if (RegExp(r'^\d{8,14}$').hasMatch(q)) {
          final f = await lookupBarcode(q); // typed barcode number
          r = f == null ? [] : [f];
        } else {
          r = await searchOpenFoodFacts(q);
        }
      } else {
        final key = AppDb.instance.getSetting('usda_api_key') ?? 'DEMO_KEY';
        r = await searchUsda(q, key);
      }
      if (!mounted) return;
      setState(() {
        _results = r;
        _searched = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(Food f) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => FoodEditScreen(food: f, isDraft: true)),
    );
    if (saved == true && mounted) Navigator.pop(context, true);
  }

  Future<void> _editKey() async {
    final ctl =
        TextEditingController(text: AppDb.instance.getSetting('usda_api_key') ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('USDA API key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Without a key the shared DEMO_KEY is used, which allows only a few searches per hour. '
                'A personal key is free: sign up at fdc.nal.usda.gov/api-key-signup.'),
            TextField(
              controller: ctl,
              decoration: const InputDecoration(labelText: 'API key'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      AppDb.instance.setSetting('usda_api_key', ctl.text.trim());
    }
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search online'),
        actions: [
          if (_source == 'usda')
            IconButton(
                icon: const Icon(Icons.key),
                tooltip: 'USDA API key',
                onPressed: _editKey),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'off', label: Text('Packaged')),
                ButtonSegment(value: 'usda', label: Text('Whole foods')),
              ],
              selected: {_source},
              onSelectionChanged: (s) => setState(() {
                _source = s.first;
                _results = [];
                _searched = false;
                _error = null;
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _ctl,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: _source == 'off'
                    ? 'Product name or barcode number'
                    : 'For example: salmon, raw',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                    icon: const Icon(Icons.search), onPressed: _search),
              ),
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(_searched
                        ? 'No results with nutrition data.'
                        : 'Search to see results.'))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, i) {
                      final f = _results[i];
                      return ListTile(
                        title: Text(f.name),
                        subtitle: Text(_summary(f)),
                        onTap: () => _open(f),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
