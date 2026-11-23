import 'dart:math';

/// Which plates to put on each side of a barbell.
class PlateResult {
  final List<double> perSide; // largest first
  final double total; // what the bar weighs with these plates
  final double target;
  const PlateResult(this.perSide, this.total, this.target);

  /// Can the target be loaded exactly?
  bool get exact => (total - target).abs() < 0.001;
}

/// Plates that are commonly found in a gym (kg).
const knownPlates = [25.0, 20.0, 15.0, 10.0, 5.0, 2.5, 1.25, 1.0, 0.5];

/// The plates per side for [target] kg on a bar of [bar] kg, using the
/// [available] plates (as many of each as needed). If the target cannot be
/// reached exactly, the heaviest load that is not above it is returned.
PlateResult platesFor(double target, double bar, List<double> available) {
  final plates = [...available]..sort((a, b) => b.compareTo(a));
  var rest = (target - bar) / 2;
  final out = <double>[];
  if (rest > 0) {
    for (final p in plates) {
      if (p <= 0) continue;
      while (rest + 1e-9 >= p) {
        out.add(p);
        rest -= p;
      }
    }
  }
  final total = bar + 2 * out.fold<double>(0, (a, b) => a + b);
  return PlateResult(out, total, target);
}

/// One-rep-max estimates by three common formulas. Reps from 1 to 12 give
/// the most reliable numbers.
Map<String, double> oneRepMaxEstimates(double kg, double reps) {
  if (kg <= 0 || reps < 1) return {};
  if (reps == 1) return {'Epley': kg, 'Brzycki': kg, 'Lombardi': kg};
  final out = <String, double>{'Epley': kg * (1 + reps / 30)};
  if (reps < 37) out['Brzycki'] = kg * 36 / (37 - reps);
  out['Lombardi'] = kg * pow(reps, 0.10).toDouble();
  return out;
}

/// Roughly how many reps you can do with [pct] percent of your 1RM
/// (the Epley formula turned around).
double repsAtPercent(double pct) => pct >= 100 ? 1 : 30 * (100 / pct - 1);
