import 'package:flutter/material.dart';
import '../db.dart';
import '../nutrients.dart';
import '../plates.dart';
import '../widgets.dart';

const _barChoices = [20.0, 15.0, 10.0];

Color _plateColor(double kg) {
  if (kg >= 25) return const Color(0xFFD64545); // red
  if (kg >= 20) return const Color(0xFF3B6FD6); // blue
  if (kg >= 15) return const Color(0xFFE0B72E); // yellow
  if (kg >= 10) return const Color(0xFF3FA05A); // green
  if (kg >= 5) return const Color(0xFFE8E8E8); // white
  if (kg >= 2.5) return const Color(0xFF444444); // black
  return const Color(0xFF9AA0A6); // grey
}

String _kgText(double v) => fmt(v);

/// Plates and loads are shown exactly (1.25, 2.5, 102.5).
String _plateText(double v) => rawNum((v * 100).round() / 100);

/// Which plates go on each side of the bar for a target weight.
class PlateCalculatorCard extends StatefulWidget {
  final double? initialKg;
  const PlateCalculatorCard({super.key, this.initialKg});

  @override
  State<PlateCalculatorCard> createState() => _PlateCalculatorCardState();
}

class _PlateCalculatorCardState extends State<PlateCalculatorCard> {
  late final TextEditingController _kg;
  double _bar = 20;
  Set<double> _plates = {25, 20, 15, 10, 5, 2.5, 1.25};

  @override
  void initState() {
    super.initState();
    final db = AppDb.instance;
    final b = double.tryParse(db.getSetting('plate_bar') ?? '');
    if (b != null && _barChoices.contains(b)) _bar = b;
    final saved = (db.getSetting('plate_set') ?? '')
        .split(',')
        .map((e) => double.tryParse(e))
        .whereType<double>()
        .where(knownPlates.contains)
        .toSet();
    if (saved.isNotEmpty) _plates = saved;
    final k = widget.initialKg;
    _kg = TextEditingController(text: (k != null && k > 0) ? rawNum(k) : '');
  }

  @override
  void dispose() {
    _kg.dispose();
    super.dispose();
  }

  void _saveSettings() {
    final db = AppDb.instance;
    db.setSetting('plate_bar', '$_bar');
    db.setSetting('plate_set', _plates.join(','));
  }

  Widget _picture(List<double> perSide) {
    return SizedBox(
      height: 64,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(width: 28, height: 8, color: Colors.blueGrey),
          Container(width: 6, height: 24, color: Colors.blueGrey.shade700),
          for (final p in perSide)
            Container(
              width: p >= 5 ? 14 : 8,
              height: 26 + (p * 1.4).clamp(0, 36).toDouble(),
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                color: _plateColor(p),
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: Colors.black26),
              ),
            ),
          Container(width: 40, height: 8, color: Colors.blueGrey),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final target = parseNum(_kg.text);
    final available = _plates.toList();
    PlateResult? r;
    if (target != null && target > 0 && available.isNotEmpty) {
      r = platesFor(target, _bar, available);
    }
    final smallest = available.isEmpty ? null : available.reduce((a, b) => a < b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        numField(
          controller: _kg,
          label: 'Weight on the bar',
          suffix: 'kg',
          onChanged: (_) => setState(() {}),
        ),
        const Text('Bar', style: TextStyle(fontSize: 12)),
        Wrap(
          spacing: 8,
          children: [
            for (final b in _barChoices)
              ChoiceChip(
                label: Text('${_plateText(b)} kg'),
                selected: _bar == b,
                onSelected: (_) {
                  setState(() => _bar = b);
                  _saveSettings();
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        const Text('Plates you have (one pair of each size or more)',
            style: TextStyle(fontSize: 12)),
        Wrap(
          spacing: 6,
          children: [
            for (final p in knownPlates)
              FilterChip(
                label: Text(_plateText(p)),
                selected: _plates.contains(p),
                onSelected: (v) {
                  setState(() {
                    if (v) {
                      _plates.add(p);
                    } else {
                      _plates.remove(p);
                    }
                  });
                  _saveSettings();
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (r == null)
          const Text('Enter a weight to see the plates.')
        else if (target! <= _bar)
          Text('The bar alone weighs ${_plateText(_bar)} kg.')
        else ...[
          _picture(r.perSide),
          const SizedBox(height: 4),
          Text(
            r.perSide.isEmpty
                ? 'No plates fit.'
                : 'Each side: ${r.perSide.map(_plateText).join(' + ')} kg',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          Text('Total on the bar: ${_plateText(r.total)} kg'),
          if (!r.exact)
            Text(
              'Not exactly possible with these plates: ${_plateText(r.total)} kg is the '
              'closest load below ${_plateText(target)} kg'
              '${smallest != null ? ' (the next step up is ${_plateText(r.total + 2 * smallest)} kg)' : ''}.',
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
            ),
        ],
      ],
    );
  }
}

/// Estimated one-rep max from a set, and what other percentages mean.
class OneRmCard extends StatefulWidget {
  final double? initialKg;
  final double? initialReps;
  const OneRmCard({super.key, this.initialKg, this.initialReps});

  @override
  State<OneRmCard> createState() => _OneRmCardState();
}

class _OneRmCardState extends State<OneRmCard> {
  late final TextEditingController _kg;
  late final TextEditingController _reps;

  @override
  void initState() {
    super.initState();
    final k = widget.initialKg, r = widget.initialReps;
    _kg = TextEditingController(text: (k != null && k > 0) ? rawNum(k) : '');
    _reps = TextEditingController(text: (r != null && r > 0) ? rawNum(r) : '');
  }

  @override
  void dispose() {
    _kg.dispose();
    _reps.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kg = parseNum(_kg.text);
    final reps = parseNum(_reps.text);
    final est = (kg != null && reps != null) ? oneRepMaxEstimates(kg, reps) : <String, double>{};
    final avg = est.isEmpty ? null : est.values.reduce((a, b) => a + b) / est.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: numField(
                controller: _kg,
                label: 'Weight',
                suffix: 'kg',
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: numField(
                controller: _reps,
                label: 'Reps',
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        if (avg == null)
          const Text('Enter the weight and the repetitions of a hard set.')
        else ...[
          Text('Estimated 1RM: ${_kgText(avg)} kg',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          const SizedBox(height: 2),
          Text(
              est.entries.map((e) => '${e.key} ${_kgText(e.value)}').join('   '),
              style: const TextStyle(fontSize: 12)),
          if ((reps ?? 0) > 12)
            const Text('Above 12 reps the estimate is less reliable.',
                style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          const Text('Percent of your 1RM', style: TextStyle(fontWeight: FontWeight.w600)),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 24,
              headingRowHeight: 32,
              columns: const [
                DataColumn(label: Text('%')),
                DataColumn(label: Text('Weight'), numeric: true),
                DataColumn(label: Text('About reps'), numeric: true),
              ],
              rows: [
                for (final p in [100, 95, 90, 85, 80, 75, 70, 65, 60, 50])
                  DataRow(cells: [
                    DataCell(Text('$p')),
                    DataCell(Text('${_kgText(avg * p / 100)} kg')),
                    DataCell(Text(repsAtPercent(p.toDouble()).round().toString())),
                  ]),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

Future<void> showPlateCalculator(BuildContext context, {double? kg}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Plate calculator'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(child: PlateCalculatorCard(initialKg: kg)),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ),
  );
}

Future<void> showOneRmCalculator(BuildContext context, {double? kg, double? reps}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('1RM calculator'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(child: OneRmCard(initialKg: kg, initialReps: reps)),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ),
  );
}

/// Both calculators on one screen.
class LiftToolsScreen extends StatelessWidget {
  const LiftToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(title: const Text('Lifting tools')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Plate calculator', style: title),
                  const SizedBox(height: 8),
                  const PlateCalculatorCard(),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('1RM calculator', style: title),
                  const SizedBox(height: 8),
                  const OneRmCard(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
