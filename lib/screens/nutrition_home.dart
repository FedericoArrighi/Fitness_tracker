import 'package:flutter/material.dart';
import '../chart_view.dart';
import '../db.dart';
import '../metrics.dart';
import 'foods_screen.dart';
import 'recipes_screen.dart';
import 'targets_screen.dart';
import 'today_screen.dart';

/// The nutrition part of the app: the day's log, foods, recipes, the intake
/// chart and the targets. A row of chips at the top switches between them.
class NutritionHome extends StatefulWidget {
  const NutritionHome({super.key});

  @override
  State<NutritionHome> createState() => _NutritionHomeState();
}

class _NutritionHomeState extends State<NutritionHome> {
  static const _labels = ['Today', 'Foods', 'Recipes', 'Intake', 'Targets'];
  static const _icons = [
    Icons.today,
    Icons.restaurant,
    Icons.menu_book,
    Icons.show_chart,
    Icons.flag,
  ];
  int _i = 0;
  final Set<int> _built = {0};
  final List<int> _keys = List.filled(5, 0);
  int _stamp = AppDb.stamp;
  ChartConfig? _intakeCfg;

  void _select(int i) {
    if (i == _i) return;
    setState(() {
      // Today and the chart show what was edited in Foods, Recipes or Targets
      final editedBefore = const {1, 2, 4}.contains(_i);
      if (_built.contains(i) &&
          (i == 0 || i == 3) &&
          (editedBefore || _stamp != AppDb.stamp)) {
        _keys[i]++;
      }
      _stamp = AppDb.stamp;
      _i = i;
      _built.add(i);
    });
  }

  Widget _page(int i) {
    switch (i) {
      case 0:
        return TodayScreen(key: ValueKey('today${_keys[0]}'));
      case 1:
        return const FoodsScreen();
      case 2:
        return const RecipesScreen();
      case 3:
        return Scaffold(
          key: ValueKey('intake${_keys[3]}'),
          appBar: AppBar(title: const Text('Intake')),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              MetricChart(
                metrics: nutritionMetrics,
                initialMetric: 'nut:calories',
                config: _intakeCfg,
                onConfigChanged: (c) => _intakeCfg = c,
              ),
            ],
          ),
        );
      default:
        return const TargetsScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SafeArea(
          bottom: false,
          child: SizedBox(
            height: 54,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (var i = 0; i < _labels.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      avatar: Icon(_icons[i], size: 18),
                      label: Text(_labels[i]),
                      selected: _i == i,
                      onSelected: (_) => _select(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          // the chips already cover the status bar
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: IndexedStack(
              index: _i,
              children: [
                for (var i = 0; i < _labels.length; i++)
                  ExcludeFocus(
                    excluding: i != _i,
                    child: TickerMode(
                      enabled: i == _i,
                      child: _built.contains(i) ? _page(i) : const SizedBox.shrink(),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
