/// Nutrient definitions. All food values are stored PER 100 g.
class Nutrient {
  final String key;
  final String name;
  final String unit;
  final String group;
  const Nutrient(this.key, this.name, this.unit, this.group);
}

const groups = ['Macros', 'Other', 'Fatty acids', 'Minerals', 'Vitamins'];

const nutrients = <Nutrient>[
  Nutrient('calories', 'Calories', 'kcal', 'Macros'),
  Nutrient('protein', 'Protein', 'g', 'Macros'),
  Nutrient('carbs', 'Carbohydrates', 'g', 'Macros'),
  Nutrient('fat', 'Fat', 'g', 'Macros'),
  Nutrient('fibre', 'Fibre', 'g', 'Other'),
  Nutrient('sugar', 'Sugar', 'g', 'Other'),
  Nutrient('sat_fat', 'Saturated fat', 'g', 'Other'),
  Nutrient('sodium', 'Sodium', 'mg', 'Other'),
  Nutrient('omega3', 'Omega-3', 'g', 'Fatty acids'),
  Nutrient('omega6', 'Omega-6', 'g', 'Fatty acids'),
  Nutrient('magnesium', 'Magnesium', 'mg', 'Minerals'),
  Nutrient('potassium', 'Potassium', 'mg', 'Minerals'),
  Nutrient('iron', 'Iron', 'mg', 'Minerals'),
  Nutrient('zinc', 'Zinc', 'mg', 'Minerals'),
  Nutrient('vitamin_c', 'Vitamin C', 'mg', 'Vitamins'),
  Nutrient('vitamin_d', 'Vitamin D', 'µg', 'Vitamins'),
  Nutrient('vitamin_b6', 'Vitamin B6', 'mg', 'Vitamins'),
  Nutrient('vitamin_b12', 'Vitamin B12', 'µg', 'Vitamins'),
];

const meals = ['Breakfast', 'Lunch', 'Dinner', 'Snacks'];

/// Parses user input ("12,5" or "12.5"). Returns null if empty or invalid.
double? parseNum(String s) {
  final t = s.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  return double.tryParse(t);
}

/// Short display format for numbers.
String fmt(double v) {
  if (v == 0) return '0';
  if (v.abs() >= 100) return v.toStringAsFixed(0);
  if (v.abs() >= 1) return v.toStringAsFixed(1);
  return v.toStringAsFixed(2);
}

/// Exact format for text fields (keeps what the user typed).
String rawNum(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
