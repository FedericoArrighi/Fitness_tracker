import 'package:flutter/material.dart';
import 'analysis.dart';

/// One measurement on a time axis.
class ScatterPoint {
  final DateTime t;
  final double y;
  final String tip; // shown when you tap or hover
  final bool star; // highlighted, e.g. the best one
  const ScatterPoint(this.t, this.y, this.tip, {this.star = false});
}

class ScatterSeries {
  final String label;
  final Color? color;
  final List<ScatterPoint> points; // oldest first
  final bool connect; // draw a line through the points
  final bool trend; // draw a straight trend line
  const ScatterSeries(this.label, this.points, {this.color, this.connect = false, this.trend = true});
}

class _Geo {
  static const double left = 58, right = 12, top = 10, bottom = 26;
  late final double w, h, x0, x1, y0, y1;

  _Geo(List<ScatterSeries> series, Size size) {
    w = size.width - left - right;
    h = size.height - top - bottom;
    final xs = <double>[], ys = <double>[];
    for (final s in series) {
      for (final p in s.points) {
        xs.add(p.t.millisecondsSinceEpoch.toDouble());
        ys.add(p.y);
      }
    }
    if (xs.isEmpty) {
      x0 = 0;
      x1 = 1;
      y0 = 0;
      y1 = 1;
      return;
    }
    var lo = xs.reduce((a, b) => a < b ? a : b), hi = xs.reduce((a, b) => a > b ? a : b);
    if (hi - lo < 86400000) {
      lo -= 43200000;
      hi += 43200000;
    }
    final pad = (hi - lo) * 0.03;
    x0 = lo - pad;
    x1 = hi + pad;
    final ylo = ys.reduce((a, b) => a < b ? a : b), yhi = ys.reduce((a, b) => a > b ? a : b);
    final span = yhi - ylo;
    final ypad = span == 0 ? (yhi.abs() * 0.05 + 1) : span * 0.12;
    y0 = ylo - ypad;
    y1 = yhi + ypad;
  }

  double xOf(DateTime t) => left + w * (t.millisecondsSinceEpoch - x0) / (x1 - x0);
  double yOf(double v) => top + h * (1 - (v - y0) / (y1 - y0));
}

const _palette = [Color(0xFF2F6F5E), Color(0xFFD9822B), Color(0xFF5B6FD6), Color(0xFFC0392B)];

/// Points over time, one or several series, with optional trend lines,
/// and a tooltip on tap or hover.
class TimeScatterChart extends StatefulWidget {
  final List<ScatterSeries> series;
  final String Function(double) yFormat;
  final double height;
  const TimeScatterChart({
    super.key,
    required this.series,
    required this.yFormat,
    this.height = 240,
  });

  @override
  State<TimeScatterChart> createState() => _TimeScatterChartState();
}

class _TimeScatterChartState extends State<TimeScatterChart> {
  int? _hs, _hi;

  Color _color(int i) => widget.series[i].color ?? _palette[i % _palette.length];

  void _pick(Offset pos, Size size) {
    final g = _Geo(widget.series, size);
    double best = 30;
    int? bs, bi;
    for (var s = 0; s < widget.series.length; s++) {
      final pts = widget.series[s].points;
      for (var i = 0; i < pts.length; i++) {
        final d = (Offset(g.xOf(pts[i].t), g.yOf(pts[i].y)) - pos).distance;
        if (d < best) {
          best = d;
          bs = s;
          bi = i;
        }
      }
    }
    setState(() {
      _hs = bs;
      _hi = bi;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(builder: (context, c) {
          final size = Size(c.maxWidth, widget.height);
          return MouseRegion(
            onHover: (e) => _pick(e.localPosition, size),
            onExit: (_) => setState(() => _hs = _hi = null),
            child: GestureDetector(
              onTapDown: (d) => _pick(d.localPosition, size),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: CustomPaint(
                  painter: _ScatterPainter(
                    series: widget.series,
                    colors: [for (var i = 0; i < widget.series.length; i++) _color(i)],
                    yFormat: widget.yFormat,
                    hs: _hs,
                    hi: _hi,
                    cs: cs,
                  ),
                ),
              ),
            ),
          );
        }),
        if (widget.series.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                for (var i = 0; i < widget.series.length; i++)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 12, height: 12, color: _color(i)),
                    const SizedBox(width: 6),
                    Text(widget.series[i].label, style: const TextStyle(fontSize: 12)),
                  ]),
              ],
            ),
          ),
      ],
    );
  }
}

class _ScatterPainter extends CustomPainter {
  final List<ScatterSeries> series;
  final List<Color> colors;
  final String Function(double) yFormat;
  final int? hs, hi;
  final ColorScheme cs;
  _ScatterPainter({
    required this.series,
    required this.colors,
    required this.yFormat,
    required this.hs,
    required this.hi,
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
    final g = _Geo(series, size);
    if (g.w <= 0 || g.h <= 0) return;
    final total = series.fold<int>(0, (a, s) => a + s.points.length);
    if (total == 0) {
      _text(canvas, 'No data', _Geo.left + g.w / 2, _Geo.top + g.h / 2, align: 'center');
      return;
    }
    final grid = Paint()
      ..color = cs.outlineVariant
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = _Geo.top + g.h * (1 - i / 4);
      canvas.drawLine(Offset(_Geo.left, y), Offset(_Geo.left + g.w, y), grid);
      _text(canvas, yFormat(g.y0 + (g.y1 - g.y0) * i / 4), _Geo.left - 6, y - 7, align: 'right');
    }
    String date(double ms) {
      final d = DateTime.fromMillisecondsSinceEpoch(ms.round());
      return '${d.day}.${d.month}.${d.year % 100}';
    }

    _text(canvas, date(g.x0), _Geo.left, _Geo.top + g.h + 6);
    _text(canvas, date((g.x0 + g.x1) / 2), _Geo.left + g.w / 2, _Geo.top + g.h + 6, align: 'center');
    _text(canvas, date(g.x1), _Geo.left + g.w, _Geo.top + g.h + 6, align: 'right');

    for (var s = 0; s < series.length; s++) {
      final pts = series[s].points;
      if (pts.isEmpty) continue;
      final color = colors[s];
      if (series[s].connect && pts.length > 1) {
        final path = Path();
        for (var i = 0; i < pts.length; i++) {
          final p = Offset(g.xOf(pts[i].t), g.yOf(pts[i].y));
          if (i == 0) {
            path.moveTo(p.dx, p.dy);
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        canvas.drawPath(
            path,
            Paint()
              ..color = color.withValues(alpha: 0.6)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5);
      }
      if (series[s].trend && pts.length >= 3) {
        final xs = [for (final p in pts) p.t.millisecondsSinceEpoch / 86400000.0];
        final line = fitLine(xs, [for (final p in pts) p.y]);
        if (line != null) {
          final a = Offset(g.xOf(pts.first.t), g.yOf(line.at(xs.first)));
          final b = Offset(g.xOf(pts.last.t), g.yOf(line.at(xs.last)));
          canvas.drawLine(
              a,
              b,
              Paint()
                ..color = color
                ..strokeWidth = 2.5);
        }
      }
      for (var i = 0; i < pts.length; i++) {
        final p = Offset(g.xOf(pts[i].t), g.yOf(pts[i].y));
        canvas.drawCircle(p, pts[i].star ? 6 : 3.5, Paint()..color = color.withValues(alpha: pts[i].star ? 1 : 0.7));
        if (pts[i].star) {
          canvas.drawCircle(
              p,
              9,
              Paint()
                ..color = color
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2);
        }
      }
    }

    final s = hs, i = hi;
    if (s != null && i != null && s < series.length && i < series[s].points.length) {
      final pt = series[s].points[i];
      final p = Offset(g.xOf(pt.t), g.yOf(pt.y));
      canvas.drawCircle(
          p,
          8,
          Paint()
            ..color = cs.onSurface
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      final tp = TextPainter(
        text: TextSpan(text: pt.tip, style: TextStyle(color: cs.onInverseSurface, fontSize: 12, height: 1.3)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 240);
      final bw = tp.width + 16, bh = tp.height + 12;
      var bx = p.dx + 12;
      if (bx + bw > size.width - 4) bx = p.dx - 12 - bw;
      if (bx < 4) bx = 4;
      var by = p.dy - bh - 8;
      if (by < 2) by = p.dy + 12;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(8)),
        Paint()..color = cs.inverseSurface,
      );
      tp.paint(canvas, Offset(bx + 8, by + 6));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Lines over a common x axis (for example heart rate during two runs).
class OverlaySeries {
  final String label;
  final List<List<double>> pts; // [x, y]
  const OverlaySeries(this.label, this.pts);
}

class OverlayChart extends StatelessWidget {
  final List<OverlaySeries> series;
  final String xUnit;
  final double height;
  const OverlayChart({super.key, required this.series, this.xUnit = 'min', this.height = 180});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(painter: _OverlayPainter(series, xUnit, cs)),
        ),
        Wrap(
          spacing: 16,
          children: [
            for (var i = 0; i < series.length; i++)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 12, height: 4, color: _palette[i % _palette.length]),
                const SizedBox(width: 6),
                Text(series[i].label, style: const TextStyle(fontSize: 12)),
              ]),
          ],
        ),
      ],
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final List<OverlaySeries> series;
  final String xUnit;
  final ColorScheme cs;
  _OverlayPainter(this.series, this.xUnit, this.cs);

  void _text(Canvas c, String s, double x, double y, {bool right = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset(right ? x - tp.width : x, y));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 40.0, right = 8.0, top = 6.0, bottom = 22.0;
    final w = size.width - left - right, h = size.height - top - bottom;
    final all = [for (final s in series) ...s.pts];
    if (w <= 0 || h <= 0 || all.length < 2) return;
    final xmax = all.map((p) => p[0]).reduce((a, b) => a > b ? a : b);
    final lo = all.map((p) => p[1]).reduce((a, b) => a < b ? a : b) - 5;
    final hi = all.map((p) => p[1]).reduce((a, b) => a > b ? a : b) + 5;
    final xm = xmax <= 0 ? 1.0 : xmax;
    double xOf(double v) => left + w * v / xm;
    double yOf(double v) => top + h * (1 - (v - lo) / (hi - lo));
    final grid = Paint()
      ..color = cs.outlineVariant
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = top + h * (1 - i / 3);
      canvas.drawLine(Offset(left, y), Offset(left + w, y), grid);
      _text(canvas, (lo + (hi - lo) * i / 3).round().toString(), left - 6, y - 7, right: true);
    }
    for (var s = 0; s < series.length; s++) {
      final pts = series[s].pts;
      if (pts.length < 2) continue;
      final path = Path();
      for (var i = 0; i < pts.length; i++) {
        final p = Offset(xOf(pts[i][0]), yOf(pts[i][1]));
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = _palette[s % _palette.length]
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
    _text(canvas, '0 $xUnit', left, top + h + 5);
    _text(canvas, '${xmax.round()} $xUnit', left + w, top + h + 5, right: true);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
