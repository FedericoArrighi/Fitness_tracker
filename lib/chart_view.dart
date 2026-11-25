import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'db.dart';
import 'metrics.dart';
import 'nutrients.dart';

enum Bucket { auto, day, week, month }

enum Compare { none, previous, lastYear, custom }

/// Everything the user can set on a chart. Copied when a chart is enlarged.
class ChartConfig {
  String metricId;
  DateTime from;
  DateTime to;
  Bucket bucket;
  Compare compare;
  DateTime? compareStart;
  bool showTrend;
  int trendDays; // window of the trend line: 7, 30 or 90 days
  int? preset; // days of the range button last pressed (null = custom range)
  bool? line; // null = the metric's default style
  AggMode? agg; // null = the metric's default (weeks and months)

  ChartConfig({
    required this.metricId,
    required this.from,
    required this.to,
    this.bucket = Bucket.auto,
    this.compare = Compare.none,
    this.compareStart,
    this.showTrend = false,
    this.trendDays = 7,
    this.preset,
    this.line,
    this.agg,
  });

  ChartConfig copy() => ChartConfig(
        metricId: metricId,
        from: from,
        to: to,
        bucket: bucket,
        compare: compare,
        compareStart: compareStart,
        showTrend: showTrend,
        trendDays: trendDays,
        preset: preset,
        line: line,
        agg: agg,
      );
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _wdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;

String _dm(DateTime d) => '${d.day}.${d.month}.';
String _dmy(DateTime d) => '${d.day}.${d.month}.${d.year}';

class _Bk {
  final DateTime start;
  final DateTime endEx; // exclusive
  const _Bk(this.start, this.endEx);
}

class _Stats {
  final double avg, min, max, total;
  final int n;
  const _Stats(this.avg, this.min, this.max, this.total, this.n);
}

/// Day, week (7 days from the start date) or calendar-month buckets.
List<_Bk> _buckets(DateTime from, DateTime to, Bucket b) {
  final out = <_Bk>[];
  final endEx = _addDays(to, 1);
  if (b == Bucket.week) {
    for (var d = from; d.isBefore(endEx); d = _addDays(d, 7)) {
      final e = _addDays(d, 7);
      out.add(_Bk(d, e.isAfter(endEx) ? endEx : e));
    }
  } else if (b == Bucket.month) {
    var d = from;
    while (d.isBefore(endEx)) {
      final next = DateTime(d.year, d.month + 1, 1);
      out.add(_Bk(d, next.isAfter(endEx) ? endEx : next));
      d = next;
    }
  } else {
    for (var d = from; d.isBefore(endEx); d = _addDays(d, 1)) {
      out.add(_Bk(d, _addDays(d, 1)));
    }
  }
  return out;
}

double? _valueOn(Map<String, double> daily, DateTime d, bool zeroFill, DateTime today) {
  final v = daily[dayKey(d)];
  if (v != null) return v;
  if (zeroFill && !d.isAfter(today)) return 0;
  return null;
}

/// Average, total or highest value of the days with a value in the bucket.
double? _aggregate(Map<String, double> daily, _Bk b, bool zeroFill,
    DateTime today, AggMode mode) {
  var sum = 0.0;
  var n = 0;
  double? top;
  for (var d = b.start; d.isBefore(b.endEx); d = _addDays(d, 1)) {
    final v = _valueOn(daily, d, zeroFill, today);
    if (v != null) {
      sum += v;
      n++;
      if (top == null || v > top) top = v;
    }
  }
  if (n == 0) return null;
  return switch (mode) {
    AggMode.sum => sum,
    AggMode.max => top,
    AggMode.avg => sum / n,
  };
}

/// Average of the days with a value in the [window] days up to and including [day].
double? _trailing(Map<String, double> daily, DateTime day, bool zeroFill,
    DateTime today, int window) {
  var sum = 0.0;
  var n = 0;
  for (var i = 0; i < window; i++) {
    final v = _valueOn(daily, _addDays(day, -i), zeroFill, today);
    if (v != null) {
      sum += v;
      n++;
    }
  }
  return n == 0 ? null : sum / n;
}

_Stats? _statsOf(Map<String, double> daily, DateTime a, DateTime b, bool zeroFill, DateTime today) {
  final vs = <double>[];
  for (var d = a; !d.isAfter(b); d = _addDays(d, 1)) {
    final v = _valueOn(daily, d, zeroFill, today);
    if (v != null) vs.add(v);
  }
  if (vs.isEmpty) return null;
  final total = vs.fold<double>(0, (s, v) => s + v);
  return _Stats(total / vs.length, vs.reduce((x, y) => x < y ? x : y),
      vs.reduce((x, y) => x > y ? x : y), total, vs.length);
}

// ====================================================================
// the widget
// ====================================================================

/// A chart of one metric with a metric picker, time range, aggregation
/// (day / week / month), bars or line, trend line, comparison with another
/// period, tooltips on hover or touch, and a full-screen view.
class MetricChart extends StatefulWidget {
  final List<MetricDef> metrics;
  final String? initialMetric;
  final int initialDays;

  /// Changing this number makes the chart reload its data.
  final int reloadToken;
  final bool fullScreen;

  /// Settings to start from (kept by the parent between tab switches).
  final ChartConfig? config;
  final void Function(ChartConfig)? onConfigChanged;

  const MetricChart({
    super.key,
    required this.metrics,
    this.initialMetric,
    this.initialDays = 30,
    this.reloadToken = 0,
    this.fullScreen = false,
    this.config,
    this.onConfigChanged,
  });

  @override
  State<MetricChart> createState() => _MetricChartState();
}

class _MetricChartState extends State<MetricChart> {
  late ChartConfig _c;
  // The position under the finger or mouse. Only the chart itself is redrawn
  // when it changes, not the whole widget (this was slow on a desktop).
  final ValueNotifier<int?> _hoverN = ValueNotifier<int?>(null);
  set _hover(int? v) => _hoverN.value = v;

  @override
  void dispose() {
    _hoverN.dispose();
    super.dispose();
  }

  // computed by _compute()
  Bucket _eff = Bucket.day;
  AggMode _modeEff = AggMode.avg;
  int _len = 1;
  List<double?> _vals = [];
  List<bool> _partial = [];
  List<double?>? _cmp;
  List<double?>? _trend;
  List<String> _tips = [];
  List<String> _xl = [];
  double? _target;
  _Stats? _sa;
  _Stats? _sb;
  String _cmpText = '';

  MetricDef _def(String id) =>
      widget.metrics.firstWhere((x) => x.id == id, orElse: () => widget.metrics.first);

  MetricDef get _m => _def(_c.metricId);

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (widget.config != null) {
      _c = widget.config!.copy();
    } else {
      final id = widget.initialMetric ?? widget.metrics.first.id;
      _c = ChartConfig(
        metricId: id,
        from: _addDays(today, -(widget.initialDays - 1)),
        to: today,
        showTrend: _def(id).line,
      );
    }
    _compute();
  }

  @override
  void didUpdateWidget(covariant MetricChart old) {
    super.didUpdateWidget(old);
    if (old.reloadToken != widget.reloadToken) setState(_compute);
  }

  void _changed() {
    widget.onConfigChanged?.call(_c);
    setState(_compute);
  }

  String _label(_Bk b, Bucket eff) {
    if (eff == Bucket.week) return '${_dm(b.start)} - ${_dm(_addDays(b.endEx, -1))}';
    if (eff == Bucket.month) return '${_months[b.start.month - 1]} ${b.start.year}';
    return '${_wdays[b.start.weekday - 1]} ${_dmy(b.start)}';
  }

  void _compute() {
    final m = _m;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = _c.from;
    final to = _c.to;
    final len = _daysBetween(from, to) + 1;
    final eff = _c.bucket != Bucket.auto
        ? _c.bucket
        : (len <= 62 ? Bucket.day : (len <= 400 ? Bucket.week : Bucket.month));
    final bk = _buckets(from, to, eff);

    // extra days before the range, so the trend line is complete from the first day
    final data = loadDailyData(m, _addDays(from, -(math.max(7, _c.trendDays) - 1)), to);
    final mode = eff == Bucket.day ? AggMode.avg : (_c.agg ?? m.defaultAgg);
    final suffix = eff == Bucket.day
        ? ''
        : (mode == AggMode.sum ? ' (total)' : (mode == AggMode.max ? ' (highest)' : ' (avg per day)'));
    List<double?> aggregate(Map<String, double> daily, List<_Bk> bks) =>
        [for (final b in bks) _aggregate(daily, b, m.zeroFill, today, mode)];

    final vals = aggregate(data.values, bk);
    final partial = [
      for (final b in bk)
        () {
          for (var d = b.start; d.isBefore(b.endEx); d = _addDays(d, 1)) {
            if (data.partial.contains(dayKey(d))) return true;
          }
          return false;
        }()
    ];

    List<double?>? trend;
    // The trend is an average per day, so it only fits bars/lines that show an
    // average (not totals or highest values). Per bucket it ends on the last day.
    if (_c.showTrend && mode == AggMode.avg) {
      trend = [
        for (final b in bk)
          _trailing(data.values, _addDays(b.endEx, -1), m.zeroFill, today, _c.trendDays)
      ];
    }

    // comparison period of the same length
    List<double?>? cmp;
    List<_Bk>? cbk;
    _Stats? sb;
    var cmpText = '';
    if (_c.compare != Compare.none) {
      DateTime cFrom;
      if (_c.compare == Compare.previous) {
        cFrom = _addDays(from, -len);
      } else if (_c.compare == Compare.lastYear) {
        cFrom = DateTime(from.year - 1, from.month, from.day);
      } else {
        cFrom = _c.compareStart ?? _addDays(from, -len);
      }
      final cTo = _addDays(cFrom, len - 1);
      final cdata = loadDailyData(m, cFrom, cTo);
      cbk = _buckets(cFrom, cTo, eff);
      final cv = aggregate(cdata.values, cbk);
      cmp = [for (var i = 0; i < bk.length; i++) i < cv.length ? cv[i] : null];
      sb = _statsOf(cdata.values, cFrom, cTo, m.zeroFill, today);
      cmpText = 'Comparison: ${_dmy(cFrom)} - ${_dmy(cTo)}';
    }

    final tips = <String>[];
    for (var i = 0; i < bk.length; i++) {
      final v = vals[i];
      final lines = <String>[
        _label(bk[i], eff),
        v == null
            ? 'No data'
            : '${fmt(v)} ${m.unit}$suffix${partial[i] ? '  (incomplete)' : ''}',
      ];
      if (cmp != null && cbk != null && i < cbk.length) {
        final cv = cmp[i];
        lines.add('${_label(cbk[i], eff)}: ${cv == null ? 'no data' : '${fmt(cv)} ${m.unit}$suffix'}');
      }
      final t = trend == null ? null : trend[i];
      if (t != null) lines.add('${_c.trendDays}-day trend: ${fmt(t)} ${m.unit}');
      tips.add(lines.join('\n'));
    }

    final step = math.max(1, (bk.length / 4).ceil());
    final xl = <String>[
      for (var i = 0; i < bk.length; i++)
        i % step != 0
            ? ''
            : (eff == Bucket.month
                ? '${_months[bk[i].start.month - 1]} ${bk[i].start.year % 100}'
                : _dm(bk[i].start))
    ];

    _eff = eff;
    _modeEff = mode;
    _len = len;
    _vals = vals;
    _partial = partial;
    _cmp = cmp;
    _trend = trend;
    _tips = tips;
    _xl = xl;
    _target = m.source == 'nut' ? AppDb.instance.loadTargets()[m.key] : null;
    _sa = _statsOf(data.values, from, to, m.zeroFill, today);
    _sb = sb;
    _cmpText = cmpText;
    _hover = null;
  }

  // ---------- user actions ----------

  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// First day of a range button ("90 d", "5 y", ...). If the metric has no
  /// data before that day, the range starts at its first day with data.
  DateTime _presetStart(int days) {
    final from = _addDays(_today, -(days - 1));
    final inRange = loadDailyData(_m, from, _today).values;
    if (inRange.isEmpty) return from;
    final first = inRange.keys.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
    if (first.compareTo(dayKey(from)) <= 0) return from;
    final before = loadDailyData(_m, DateTime(2015), _addDays(from, -1)).values;
    if (before.isNotEmpty) return from;
    final p = DateTime.parse(first);
    return DateTime(p.year, p.month, p.day);
  }

  void _applyPreset(int days) {
    _c.to = _today;
    _c.from = _presetStart(days);
    _c.preset = days;
  }

  void _setPreset(int days) {
    _applyPreset(days);
    _changed();
  }

  void _shift(int dir) {
    var step = _len;
    if (dir > 0) {
      step = math.min(_len, _daysBetween(_c.to, _today));
      if (step <= 0) return;
    }
    _c.from = _addDays(_c.from, dir * step);
    _c.to = _addDays(_c.to, dir * step);
    _c.preset = null;
    _changed();
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2015),
      lastDate: _today,
      initialDateRange: DateTimeRange(start: _c.from, end: _c.to),
    );
    if (r == null) return;
    _c.from = DateTime(r.start.year, r.start.month, r.start.day);
    _c.to = DateTime(r.end.year, r.end.month, r.end.day);
    _c.preset = null;
    _changed();
  }

  Future<void> _setCompare(Compare v) async {
    if (v == Compare.custom) {
      final d = await showDatePicker(
        context: context,
        helpText: 'First day of the comparison period',
        initialDate: _c.compareStart ?? _addDays(_c.from, -_len),
        firstDate: DateTime(2015),
        lastDate: _today,
      );
      if (d == null) return;
      _c.compareStart = DateTime(d.year, d.month, d.day);
    }
    _c.compare = v;
    _changed();
  }

  void _openFull() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(_m.name)),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              MetricChart(
                metrics: widget.metrics,
                fullScreen: true,
                config: _c.copy(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- building ----------

  String _bucketName(Bucket b) => switch (b) {
        Bucket.auto => 'Auto (${_eff.name})',
        Bucket.day => 'Per day',
        Bucket.week => 'Per week',
        Bucket.month => 'Per month',
      };

  Widget _legendItem(Color color, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 14, height: 4, color: color),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 12)),
        ],
      );

  String _statLine(String name, _Stats? s, MetricDef m) {
    if (s == null) return '$name: no data';
    return '$name: average ${fmt(s.avg)} ${m.unit}, min ${fmt(s.min)}, max ${fmt(s.max)}, '
        '${s.n} day(s) with data'
        '${m.additive ? ', total ${fmt(s.total)} ${m.unit}' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = _m;
    final isLine = _c.line ?? m.line;
    final chartH =
        widget.fullScreen ? math.max(320.0, MediaQuery.of(context).size.height * 0.5) : 240.0;
    final labels = {7: '7 d', 30: '30 d', 90: '90 d', 365: '1 y', 1825: '5 y'};

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // metric + enlarge
        Row(
          children: [
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                value: m.id,
                items: [
                  for (final x in widget.metrics)
                    DropdownMenuItem(
                        value: x.id,
                        child: Text(x.unit.isEmpty ? x.name : '${x.name} (${x.unit})')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  _c.metricId = v;
                  _c.showTrend = _def(v).line;
                  _c.line = null;
                  // keep the range button, but start at the first data of the new metric
                  if (_c.preset != null && _c.to == _today) _applyPreset(_c.preset!);
                  _changed();
                },
              ),
            ),
            if (!widget.fullScreen)
              IconButton(
                icon: const Icon(Icons.open_in_full),
                tooltip: 'Enlarge',
                onPressed: _openFull,
              ),
          ],
        ),
        // time range
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Earlier',
                onPressed: () => _shift(-1)),
            IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Later',
                onPressed: () => _shift(1)),
            for (final e in labels.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: _c.to == _today &&
                    (_c.preset == null ? _len == e.key : _c.preset == e.key),
                onSelected: (_) => _setPreset(e.key),
              ),
            ActionChip(
              avatar: const Icon(Icons.date_range, size: 18),
              label: const Text('Custom'),
              onPressed: _pickRange,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text('${_dmy(_c.from)} - ${_dmy(_c.to)}  ($_len days)',
              style: const TextStyle(fontSize: 12)),
        ),
        // view options
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<Bucket>(
              value: _c.bucket,
              items: [
                for (final b in Bucket.values)
                  DropdownMenuItem(value: b, child: Text(_bucketName(b))),
              ],
              onChanged: (v) {
                if (v == null) return;
                _c.bucket = v;
                _changed();
              },
            ),
            ChoiceChip(
              label: const Text('Bars'),
              selected: !isLine,
              onSelected: (_) {
                _c.line = false;
                _changed();
              },
            ),
            ChoiceChip(
              label: const Text('Line'),
              selected: isLine,
              onSelected: (_) {
                _c.line = true;
                _changed();
              },
            ),
            if (_eff != Bucket.day)
              for (final e in {
                AggMode.avg: 'Average',
                AggMode.sum: 'Total',
                AggMode.max: 'Highest',
              }.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: _modeEff == e.key,
                  onSelected: (_) {
                    _c.agg = e.key;
                    _changed();
                  },
                ),
            for (final n in const [7, 30, 90])
              FilterChip(
                label: Text('$n-day trend'),
                selected: _c.showTrend && _c.trendDays == n && _modeEff == AggMode.avg,
                onSelected: _modeEff == AggMode.avg
                    ? (v) {
                        _c.showTrend = v;
                        if (v) _c.trendDays = n;
                        _changed();
                      }
                    : null,
              ),
            DropdownButton<Compare>(
              value: _c.compare,
              items: const [
                DropdownMenuItem(value: Compare.none, child: Text('No comparison')),
                DropdownMenuItem(value: Compare.previous, child: Text('vs previous period')),
                DropdownMenuItem(value: Compare.lastYear, child: Text('vs same period last year')),
                DropdownMenuItem(value: Compare.custom, child: Text('vs custom period...')),
              ],
              onChanged: (v) {
                if (v != null) _setCompare(v);
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        // the chart
        LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          int? indexAt(double dx) {
            final n = _vals.length;
            if (n == 0) return null;
            final plotW = w - _ChartPainter.left - _ChartPainter.right;
            if (plotW <= 0) return null;
            final i = ((dx - _ChartPainter.left) / (plotW / n)).floor();
            return i.clamp(0, n - 1).toInt();
          }

          return MouseRegion(
            onHover: (e) => _hover = indexAt(e.localPosition.dx),
            onExit: (_) => _hover = null,
            child: GestureDetector(
              onTapDown: (d) => _hover = indexAt(d.localPosition.dx),
              onHorizontalDragUpdate: (d) => _hover = indexAt(d.localPosition.dx),
              child: SizedBox(
                height: chartH,
                width: w,
                child: RepaintBoundary(
                  child: ValueListenableBuilder<int?>(
                    valueListenable: _hoverN,
                    builder: (context, hover, _) => CustomPaint(
                      painter: _ChartPainter(
                        values: _vals,
                        partial: _partial,
                        cmp: _cmp,
                        trend: _trend,
                        xLabels: _xl,
                        isLine: isLine,
                        target: _target,
                        hover: hover,
                        tips: _tips,
                        cs: cs,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 8),
        // legend
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _legendItem(cs.primary, 'Selected period'),
            if (_cmp != null) _legendItem(cs.tertiary, 'Comparison'),
            if (_trend != null) _legendItem(cs.secondary, '${_c.trendDays}-day trend'),
            if (_target != null) _legendItem(cs.error, 'Target'),
          ],
        ),
        const SizedBox(height: 8),
        Text(_statLine('Selected', _sa, m)),
        if (_cmp != null) ...[
          Text(_cmpText),
          Text(_statLine('Comparison', _sb, m)),
          if (_sa != null && _sb != null)
            Text(() {
              final diff = _sa!.avg - _sb!.avg;
              final pct = _sb!.avg != 0 ? ' (${diff >= 0 ? '+' : ''}${fmt(diff / _sb!.avg * 100)} %)' : '';
              return 'Difference in average: ${diff >= 0 ? '+' : ''}${fmt(diff)} ${m.unit}$pct';
            }()),
        ],
        if (_partial.any((p) => p))
          const Text('Lighter bars: some foods that day have no value for this nutrient.',
              style: TextStyle(fontSize: 12)),
        const Text('Tap or hover over the chart for exact values.',
            style: TextStyle(fontSize: 12)),
      ],
    );

    return widget.fullScreen
        ? content
        : Card(child: Padding(padding: const EdgeInsets.all(16), child: content));
  }
}

// ====================================================================
// the painter
// ====================================================================

class _ChartPainter extends CustomPainter {
  static const double left = 50, right = 10, top = 10, bottom = 26;

  final List<double?> values;
  final List<bool> partial;
  final List<double?>? cmp;
  final List<double?>? trend;
  final List<String> xLabels;
  final bool isLine;
  final double? target;
  final int? hover;
  final List<String> tips;
  final ColorScheme cs;

  _ChartPainter({
    required this.values,
    required this.partial,
    required this.cmp,
    required this.trend,
    required this.xLabels,
    required this.isLine,
    required this.target,
    required this.hover,
    required this.tips,
    required this.cs,
  });

  void _text(Canvas c, String s, double x, double y, {String align = 'left'}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = x;
    if (align == 'right') dx = x - tp.width;
    if (align == 'center') dx = x - tp.width / 2;
    tp.paint(c, Offset(dx, y));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width - left - right;
    final h = size.height - top - bottom;
    final n = values.length;
    if (w <= 0 || h <= 0 || n == 0) return;

    final known = <double>[
      ...values.whereType<double>(),
      if (cmp != null) ...cmp!.whereType<double>(),
      if (trend != null) ...trend!.whereType<double>(),
      ?target,
    ];
    if (known.isEmpty) {
      _text(canvas, 'No data in this period', left + w / 2, top + h / 2 - 6,
          align: 'center');
      return;
    }
    final hi = known.reduce((a, b) => a > b ? a : b);
    final lo = known.reduce((a, b) => a < b ? a : b);
    double minV, maxV;
    if (isLine) {
      final span = hi - lo;
      final pad = span == 0 ? (hi.abs() * 0.05 + 1) : span * 0.12;
      minV = lo - pad;
      maxV = hi + pad;
    } else {
      minV = 0;
      maxV = hi <= 0 ? 1 : hi * 1.1;
    }
    final slot = w / n;
    double xOf(int i) => left + slot * (i + 0.5);
    double yOf(double v) => top + h * (1 - (v - minV) / (maxV - minV));

    // grid and y labels
    final grid = Paint()
      ..color = cs.outlineVariant
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = top + h * (1 - i / 4);
      canvas.drawLine(Offset(left, y), Offset(left + w, y), grid);
      final v = minV + (maxV - minV) * i / 4;
      final label = v.abs() >= 100
          ? v.toStringAsFixed(0)
          : (v.abs() >= 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(2));
      _text(canvas, label, left - 6, y - 7, align: 'right');
    }

    void polyline(List<double?> vs, Color color, double width, {bool dots = false}) {
      final path = Path();
      var started = false;
      for (var i = 0; i < vs.length; i++) {
        final v = vs[i];
        if (v == null) continue;
        final p = Offset(xOf(i), yOf(v));
        if (!started) {
          path.moveTo(p.dx, p.dy);
          started = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeJoin = StrokeJoin.round,
      );
      if (dots) {
        final dot = Paint()..color = color;
        for (var i = 0; i < vs.length; i++) {
          final v = vs[i];
          if (v != null) canvas.drawCircle(Offset(xOf(i), yOf(v)), 3, dot);
        }
      }
    }

    // the selected period
    if (isLine) {
      polyline(values, cs.primary, 2.5, dots: n <= 120);
    } else {
      final bw = (slot * 0.72).clamp(1.0, 36.0).toDouble();
      for (var i = 0; i < n; i++) {
        final v = values[i];
        if (v == null) continue;
        canvas.drawRect(
          Rect.fromLTRB(xOf(i) - bw / 2, yOf(v), xOf(i) + bw / 2, top + h),
          Paint()..color = partial[i] ? cs.primary.withValues(alpha: 0.4) : cs.primary,
        );
      }
    }
    // comparison and trend
    if (cmp != null) polyline(cmp!, cs.tertiary, 2.2, dots: n <= 60);
    if (trend != null) polyline(trend!, cs.secondary, 2.5);

    // target (dashed)
    if (target != null) {
      final y = yOf(target!);
      final p = Paint()
        ..color = cs.error
        ..strokeWidth = 1.5;
      for (var x = left; x < left + w; x += 10) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, left + w), y), p);
      }
    }

    // x labels
    for (var i = 0; i < n; i++) {
      if (xLabels[i].isEmpty) continue;
      _text(canvas, xLabels[i], xOf(i), top + h + 6, align: 'center');
    }

    // tooltip
    final hv = hover;
    if (hv != null && hv >= 0 && hv < n) {
      final x = xOf(hv);
      canvas.drawLine(
          Offset(x, top),
          Offset(x, top + h),
          Paint()
            ..color = cs.outline
            ..strokeWidth = 1);
      final v = values[hv];
      if (v != null) canvas.drawCircle(Offset(x, yOf(v)), 4, Paint()..color = cs.primary);
      final tp = TextPainter(
        text: TextSpan(
            text: tips[hv],
            style: TextStyle(color: cs.onInverseSurface, fontSize: 12, height: 1.3)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 260);
      final bw = tp.width + 16;
      final bh = tp.height + 12;
      var bx = x + 12;
      if (bx + bw > size.width - 4) bx = x - 12 - bw;
      if (bx < 4) bx = 4;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(bx, top + 4, bw, bh), const Radius.circular(8)),
        Paint()..color = cs.inverseSurface,
      );
      tp.paint(canvas, Offset(bx + 8, top + 10));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
