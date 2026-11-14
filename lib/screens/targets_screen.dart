import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import '../widgets.dart';
import 'sync_screen.dart';

/// Targets are always stored as calories + grams (macros) and absolute
/// amounts (other nutrients). The mode only changes how you edit the macros.
class TargetsScreen extends StatefulWidget {
  const TargetsScreen({super.key});

  @override
  State<TargetsScreen> createState() => _TargetsScreenState();
}

class _TargetsScreenState extends State<TargetsScreen> {
  String _mode = 'grams'; // 'grams' or 'percent'
  final _cal = TextEditingController();
  final _p = TextEditingController();
  final _c = TextEditingController();
  final _f = TextEditingController();
  final Map<String, TextEditingController> _other = {};

  @override
  void initState() {
    super.initState();
    final db = AppDb.instance;
    final t = db.loadTargets();
    _mode = db.getSetting('target_mode') ?? 'grams';
    for (final n in nutrients.where((n) => n.group != 'Macros')) {
      final v = t[n.key];
      _other[n.key] = TextEditingController(text: v == null ? '' : rawNum(v));
    }
    _fill(t['calories'] ?? 2000, t['protein'] ?? 0, t['carbs'] ?? 0, t['fat'] ?? 0);
  }

  // Put calories/grams into the text fields according to the current mode.
  void _fill(double cal, double p, double c, double f) {
    if (_mode == 'grams') {
      _p.text = fmt(p);
      _c.text = fmt(c);
      _f.text = fmt(f);
    } else {
      final k = cal > 0 ? cal : 1.0;
      _cal.text = fmt(cal);
      _p.text = fmt(p * 4 / k * 100);
      _c.text = fmt(c * 4 / k * 100);
      _f.text = fmt(f * 9 / k * 100);
    }
  }

  // Read the fields and return [calories, protein g, carbs g, fat g].
  List<double> _read() {
    final a = parseNum(_p.text) ?? 0;
    final b = parseNum(_c.text) ?? 0;
    final d = parseNum(_f.text) ?? 0;
    if (_mode == 'grams') {
      return [4 * a + 4 * b + 9 * d, a, b, d];
    }
    final cal = parseNum(_cal.text) ?? 0;
    return [cal, cal * a / 100 / 4, cal * b / 100 / 4, cal * d / 100 / 9];
  }

  void _setMode(String m) {
    final v = _read();
    setState(() {
      _mode = m;
      _fill(v[0], v[1], v[2], v[3]);
    });
  }

  void _save() {
    final v = _read();
    if (_mode == 'percent') {
      final sum = (parseNum(_p.text) ?? 0) +
          (parseNum(_c.text) ?? 0) +
          (parseNum(_f.text) ?? 0);
      if ((sum - 100).abs() > 0.5) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Percentages must add up to 100.')));
        return;
      }
    }
    final t = <String, double>{
      'calories': v[0],
      'protein': v[1],
      'carbs': v[2],
      'fat': v[3],
    };
    _other.forEach((key, ctl) {
      final x = parseNum(ctl.text);
      if (x != null) t[key] = x;
    });
    AppDb.instance.saveTargets(t);
    AppDb.instance.setSetting('target_mode', _mode);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Targets saved.')));
  }

  @override
  Widget build(BuildContext context) {
    final v = _read();
    final sum = (parseNum(_p.text) ?? 0) +
        (parseNum(_c.text) ?? 0) +
        (parseNum(_f.text) ?? 0);
    void refresh(String _) => setState(() {});
    final unit = _mode == 'grams' ? 'g' : '% of calories';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Targets'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Sync settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SyncScreen()),
            ),
          ),
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'grams', label: Text('Grams')),
              ButtonSegment(value: 'percent', label: Text('% of calories')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => _setMode(s.first),
          ),
          const SizedBox(height: 16),
          if (_mode == 'percent')
            numField(
                controller: _cal,
                label: 'Calories',
                suffix: 'kcal',
                onChanged: refresh),
          numField(controller: _p, label: 'Protein', suffix: unit, onChanged: refresh),
          numField(controller: _c, label: 'Carbohydrates', suffix: unit, onChanged: refresh),
          numField(controller: _f, label: 'Fat', suffix: unit, onChanged: refresh),
          const SizedBox(height: 8),
          if (_mode == 'grams')
            Text('Calories (from the grams above): ${fmt(v[0])} kcal')
          else
            Text('Total: ${fmt(sum)} %  =  ${fmt(v[1])} g protein, '
                '${fmt(v[2])} g carbs, ${fmt(v[3])} g fat'),
          const Divider(height: 32),
          Text('Other nutrients (leave blank for no target)',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final n in nutrients.where((n) => n.group != 'Macros'))
            numField(controller: _other[n.key]!, label: n.name, suffix: n.unit),
        ],
      ),
    );
  }
}
