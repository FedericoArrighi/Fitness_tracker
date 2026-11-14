import 'dart:math';
import 'package:flutter/material.dart';

// Two small hand-drawn charts (no extra packages needed).

void _drawText(Canvas c, String s, double x, double y, Color color,
    {double size = 11, String align = 'left'}) {
  final tp = TextPainter(
    text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
    textDirection: TextDirection.ltr,
  )..layout();
  var dx = x;
  if (align == 'right') dx = x - tp.width;
  if (align == 'center') dx = x - tp.width / 2;
  tp.paint(c, Offset(dx, y));
}

String _axisNum(double v) {
  if (v.abs() >= 10) return v.toStringAsFixed(0);
  if (v.abs() >= 1) return v.toStringAsFixed(1);
  return v.toStringAsFixed(2);
}

String _dm(DateTime d) => '${d.day}.${d.month}.';

DateTime _utc(String day) => DateTime.parse('${day}T00:00:00Z');

String _dmFromKey(String day) {
  final d = _utc(day);
  return '${d.day}.${d.month}.';
}

// ---------------------------------------------------------------
// Bars: one bar per day. null = no value that day.
// ---------------------------------------------------------------
class DailyBarChart extends StatelessWidget {
  final List<DateTime> days;
  final List<double?> values;
  final List<bool> partial; // lighter bar: some foods lacked this nutrient
  final double? target;
  final double height;

  const DailyBarChart({
    super.key,
    required this.days,
    required this.values,
    required this.partial,
    this.target,
    this.height = 220,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _BarPainter(
          days: days,
          values: values,
          partial: partial,
          target: target,
          barColor: cs.primary,
          partialColor: cs.primary.withValues(alpha: 0.4),
          targetColor: cs.error,
          gridColor: cs.outlineVariant,
          textColor: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  final List<DateTime> days;
  final List<double?> values;
  final List<bool> partial;
  final double? target;
  final Color barColor, partialColor, targetColor, gridColor, textColor;

  _BarPainter({
    required this.days,
    required this.values,
    required this.partial,
    required this.target,
    required this.barColor,
    required this.partialColor,
    required this.targetColor,
    required this.gridColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0, right = 8.0, top = 8.0, bottom = 22.0;
    final w = size.width - left - right;
    final h = size.height - top - bottom;
    if (w <= 0 || h <= 0 || values.isEmpty) return;

    var maxV = 0.0;
    for (final v in values) {
      if (v != null && v > maxV) maxV = v;
    }
    if (target != null && target! > maxV) maxV = target!;
    if (maxV <= 0) maxV = 1;
    maxV *= 1.1;

    // grid and y labels
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = top + h * (1 - i / 4);
      canvas.drawLine(Offset(left, y), Offset(left + w, y), grid);
      _drawText(canvas, _axisNum(maxV * i / 4), left - 6, y - 7, textColor,
          align: 'right');
    }

    // bars
    final n = values.length;
    final slot = w / n;
    final bw = max(1.0, slot * 0.7);
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v == null) continue;
      final barH = h * v / maxV;
      final rect = Rect.fromLTWH(
          left + slot * i + (slot - bw) / 2, top + h - barH, bw, barH);
      canvas.drawRect(
          rect, Paint()..color = partial[i] ? partialColor : barColor);
    }

    // target line (dashed)
    if (target != null && target! > 0) {
      final y = top + h * (1 - target! / maxV);
      final p = Paint()
        ..color = targetColor
        ..strokeWidth = 1.5;
      for (var x = left; x < left + w; x += 10) {
        canvas.drawLine(Offset(x, y), Offset(min(x + 5, left + w), y), p);
      }
    }

    // x labels: first, middle, last day
    _drawText(canvas, _dm(days.first), left, top + h + 5, textColor);
    if (n > 2) {
      _drawText(canvas, _dm(days[n ~/ 2]), left + w / 2, top + h + 5,
          textColor, align: 'center');
    }
    _drawText(canvas, _dm(days.last), left + w, top + h + 5, textColor,
        align: 'right');
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ---------------------------------------------------------------
// Weight: dots for each entry, line for the 7-day average.
// ---------------------------------------------------------------
class WeightChart extends StatelessWidget {
  final List<String> days; // YYYY-MM-DD of each entry
  final List<double> kgs;
  final List<double> average; // same length as days
  final String startDay, endDay; // x axis range
  final double height;

  const WeightChart({
    super.key,
    required this.days,
    required this.kgs,
    required this.average,
    required this.startDay,
    required this.endDay,
    this.height = 220,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _LinePainter(
          days: days,
          kgs: kgs,
          average: average,
          startDay: startDay,
          endDay: endDay,
          lineColor: cs.primary,
          dotColor: cs.primary.withValues(alpha: 0.45),
          gridColor: cs.outlineVariant,
          textColor: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  final List<String> days;
  final List<double> kgs, average;
  final String startDay, endDay;
  final Color lineColor, dotColor, gridColor, textColor;

  _LinePainter({
    required this.days,
    required this.kgs,
    required this.average,
    required this.startDay,
    required this.endDay,
    required this.lineColor,
    required this.dotColor,
    required this.gridColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const left = 44.0, right = 10.0, top = 8.0, bottom = 22.0;
    final w = size.width - left - right;
    final h = size.height - top - bottom;
    if (w <= 0 || h <= 0 || kgs.isEmpty) return;

    var minY = kgs.reduce((a, b) => a < b ? a : b);
    var maxY = kgs.reduce((a, b) => a > b ? a : b);
    if (maxY - minY < 1) {
      final mid = (minY + maxY) / 2;
      minY = mid - 0.5;
      maxY = mid + 0.5;
    } else {
      final pad = (maxY - minY) * 0.1;
      minY -= pad;
      maxY += pad;
    }

    final total =
        max(1, _utc(endDay).difference(_utc(startDay)).inDays).toDouble();
    double xOf(String day) =>
        left + w * (_utc(day).difference(_utc(startDay)).inDays / total);
    double yOf(double v) => top + h * (1 - (v - minY) / (maxY - minY));

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = top + h * (1 - i / 4);
      canvas.drawLine(Offset(left, y), Offset(left + w, y), grid);
      _drawText(canvas, (minY + (maxY - minY) * i / 4).toStringAsFixed(1),
          left - 6, y - 7, textColor,
          align: 'right');
    }

    // average line
    final path = Path();
    for (var i = 0; i < days.length; i++) {
      final p = Offset(xOf(days[i]), yOf(average[i]));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = lineColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);

    // raw entries
    final dot = Paint()..color = dotColor;
    for (var i = 0; i < days.length; i++) {
      canvas.drawCircle(Offset(xOf(days[i]), yOf(kgs[i])), 3.5, dot);
    }

    _drawText(canvas, _dmFromKey(startDay), left, top + h + 5, textColor);
    _drawText(canvas, _dmFromKey(endDay), left + w, top + h + 5, textColor,
        align: 'right');
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
