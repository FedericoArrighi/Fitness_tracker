import 'package:flutter/material.dart';
import 'db.dart';
import 'nutrients.dart';

/// What the user chose: an amount (always converted to grams of the finished
/// dish) and, if asked for, a meal and a day.
class RecipeAmount {
  final double grams;
  final String? meal;
  final DateTime? day;
  const RecipeAmount(this.grams, this.meal, this.day);
}

// Remembers whether you last typed servings or grams.
String _lastMode = 'servings';

String _clean(double v) {
  var s = v.toStringAsFixed(2);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '');
    s = s.replaceAll(RegExp(r'\.$'), '');
  }
  return s;
}

/// Asks how much of a recipe to log: a number of servings OR an amount in
/// grams. Enter confirms. Returns null if cancelled.
Future<RecipeAmount?> askRecipeAmount(
  BuildContext context,
  Recipe r, {
  bool askMealAndDay = false,
  String? initialMeal,
  DateTime? initialDay,
}) {
  final gps = r.gramsPerServing; // grams in one serving
  final per100 = r.per100g();
  var mode = _lastMode;
  var meal = initialMeal ?? meals.first;
  var day = initialDay ?? DateTime.now();
  final ctl = TextEditingController(
      text: mode == 'servings' ? '1' : _clean(gps));
  ctl.selection = TextSelection(baseOffset: 0, extentOffset: ctl.text.length);
  final focus = FocusNode();

  return showDialog<RecipeAmount>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setS) {
        double? gramsNow() {
          final v = parseNum(ctl.text);
          if (v == null || v <= 0) return null;
          return mode == 'servings' ? v * gps : v;
        }

        void submit() {
          final g = gramsNow();
          if (g == null) return;
          _lastMode = mode;
          Navigator.pop(
              context,
              RecipeAmount(g, askMealAndDay ? meal : null,
                  askMealAndDay ? day : null));
        }

        String info() {
          final g = gramsNow();
          if (g == null) return 'Enter an amount.';
          final parts = <String>[
            '${_clean(g)} g',
            '${_clean(g / gps)} servings',
          ];
          String? v(String key) {
            final x = per100[key];
            return x == null ? null : fmt(x * g / 100);
          }

          final kcal = v('calories');
          parts.add(kcal == null ? 'calories unknown' : '$kcal kcal');
          final p = v('protein'), c = v('carbs'), f = v('fat');
          if (p != null && c != null && f != null) {
            parts.add('P $p  C $c  F $f');
          }
          return parts.join('  |  ');
        }

        return AlertDialog(
          title: Text(r.name),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'servings', label: Text('Servings')),
                    ButtonSegment(value: 'grams', label: Text('Grams')),
                  ],
                  selected: {mode},
                  onSelectionChanged: (sel) {
                    final next = sel.first;
                    final cur = parseNum(ctl.text);
                    if (cur != null && next != mode) {
                      final g = mode == 'servings' ? cur * gps : cur;
                      ctl.text = next == 'servings' ? _clean(g / gps) : _clean(g);
                      ctl.selection = TextSelection(
                          baseOffset: 0, extentOffset: ctl.text.length);
                    }
                    setS(() => mode = next);
                    focus.requestFocus();
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctl,
                  focusNode: focus,
                  autofocus: true,
                  onChanged: (_) => setS(() {}),
                  onSubmitted: (_) => submit(),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: mode == 'servings' ? 'Servings' : 'Amount',
                    suffixText: mode == 'servings' ? null : 'g',
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (mode == 'servings')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final s in [0.5, 1.0, 1.5, 2.0])
                          ActionChip(
                            label: Text(_clean(s)),
                            onPressed: () {
                              ctl.text = _clean(s);
                              setS(() {});
                              focus.requestFocus();
                            },
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Text('1 serving = ${_clean(gps)} g',
                    style: const TextStyle(fontSize: 12)),
                Text(info()),
                if (askMealAndDay) ...[
                  const SizedBox(height: 8),
                  DropdownButton<String>(
                    value: meal,
                    isExpanded: true,
                    items: [
                      for (final m in meals)
                        DropdownMenuItem(value: m, child: Text(m))
                    ],
                    onChanged: (v) => setS(() => meal = v!),
                  ),
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: day,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (d != null) setS(() => day = d);
                    },
                    child: Text('Date: ${dayKey(day)}'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            TextButton(onPressed: submit, child: const Text('Add')),
          ],
        );
      },
    ),
  );
}
