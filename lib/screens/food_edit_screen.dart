import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import '../widgets.dart';

class FoodEditScreen extends StatefulWidget {
  final Food? food; // null = creating a new food

  /// true = values come from an online search and are not saved yet.
  final bool isDraft;
  const FoodEditScreen({super.key, this.food, this.isDraft = false});

  @override
  State<FoodEditScreen> createState() => _FoodEditScreenState();
}

class _FoodEditScreenState extends State<FoodEditScreen> {
  final _name = TextEditingController();
  final Map<String, TextEditingController> _ctl = {
    for (final n in nutrients) n.key: TextEditingController()
  };

  @override
  void initState() {
    super.initState();
    final f = widget.food;
    if (f != null) {
      _name.text = f.name;
      for (final n in nutrients) {
        final v = f.values[n.key];
        if (v != null) _ctl[n.key]!.text = rawNum(v);
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a name for the food.')));
      return;
    }
    final values = <String, double>{};
    for (final n in nutrients) {
      final v = parseNum(_ctl[n.key]!.text);
      if (v != null) values[n.key] = v;
    }
    AppDb.instance.saveFood(
        Food(id: widget.food?.id ?? newId(), name: name, values: values));
    Navigator.pop(context, true);
  }

  void _delete() {
    AppDb.instance.deleteFood(widget.food!.id);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.food == null
            ? 'New food'
            : (widget.isDraft ? 'Review food' : 'Edit food')),
        actions: [
          if (widget.food != null && !widget.isDraft)
            IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete food',
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
          const SizedBox(height: 8),
          Text(widget.isDraft
              ? 'Imported values are per 100 g. Check them before saving; online data can contain mistakes. Blank means unknown.'
              : 'Values are per 100 g. Leave a field blank if unknown.'),
          for (final g in groups) ...[
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 4),
              child: Text(g, style: titleStyle),
            ),
            for (final n in nutrients.where((n) => n.group == g))
              numField(
                  controller: _ctl[n.key]!,
                  label: n.name,
                  suffix: '${n.unit} / 100 g'),
          ],
        ],
      ),
    );
  }
}
