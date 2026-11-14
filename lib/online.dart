import 'dart:convert';
import 'package:http/http.dart' as http;
import 'db.dart';

// Looks foods up on the internet and converts them to our own format:
// amounts per 100 g, in the units from nutrients.dart.

const _userAgent = 'MacroTracker/0.1 (personal project)';
const _timeout = Duration(seconds: 20);

// ------------------------------------------------------------------
// Open Food Facts (packaged products, barcodes)
// ------------------------------------------------------------------

/// Text search. Tries Open Food Facts' newer search service first (built for
/// search-as-you-type) and falls back to the older search if it fails.
Future<List<Food>> searchOpenFoodFacts(String query) async {
  try {
    final r = await _searchALicious(query);
    if (r.isNotEmpty) return r;
  } catch (_) {}
  return _searchLegacy(query);
}

Future<List<Food>> _searchALicious(String query) async {
  final uri = Uri.https('search.openfoodfacts.org', '/search', {
    'q': query,
    'page_size': '15',
    'fields': 'code,product_name,brands,nutriments',
  });
  final res =
      await http.get(uri, headers: {'User-Agent': _userAgent}).timeout(_timeout);
  if (res.statusCode != 200) {
    throw Exception('status ${res.statusCode}');
  }
  final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final hits = (data['hits'] as List?) ?? (data['products'] as List?) ?? [];
  final out = <Food>[];
  for (final p in hits) {
    final f = _offFood(p as Map<String, dynamic>);
    if (f != null) out.add(f);
  }
  return out;
}

Future<List<Food>> _searchLegacy(String query) async {
  final uri = Uri.https('world.openfoodfacts.org', '/cgi/search.pl', {
    'search_terms': query,
    'search_simple': '1',
    'action': 'process',
    'json': '1',
    'page_size': '15',
    'fields': 'code,product_name,brands,nutriments',
  });
  final res =
      await http.get(uri, headers: {'User-Agent': _userAgent}).timeout(_timeout);
  if (res.statusCode != 200) {
    throw Exception('Open Food Facts answered with status ${res.statusCode}');
  }
  final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final products = (data['products'] as List?) ?? [];
  final out = <Food>[];
  for (final p in products) {
    final f = _offFood(p as Map<String, dynamic>);
    if (f != null) out.add(f);
  }
  return out;
}

/// Returns null if the barcode is not in the database.
Future<Food?> lookupBarcode(String code) async {
  final uri = Uri.https('world.openfoodfacts.org', '/api/v2/product/$code.json',
      {'fields': 'code,product_name,brands,nutriments'});
  final res =
      await http.get(uri, headers: {'User-Agent': _userAgent}).timeout(_timeout);
  if (res.statusCode == 404) return null;
  if (res.statusCode != 200) {
    throw Exception('Open Food Facts answered with status ${res.statusCode}');
  }
  final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  if (data['status'] != 1 || data['product'] == null) return null;
  return _offFood(data['product'] as Map<String, dynamic>);
}

Food? _offFood(Map<String, dynamic> p) {
  final name = (p['product_name']?.toString() ?? '').trim();
  if (name.isEmpty) return null;
  final b = p['brands'];
  final brandRaw = b is List
      ? (b.isEmpty ? '' : b.first.toString().trim())
      : (b is String ? b.split(',').first.trim() : '');
  final n = (p['nutriments'] as Map?)?.cast<String, dynamic>() ?? {};

  // Open Food Facts gives most values in grams per 100 g, so mg and µg
  // nutrients are multiplied by 1000 and 1,000,000.
  double? g(String key, [double factor = 1]) {
    final v = n[key];
    final d = v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
    return d == null ? null : d * factor;
  }

  final values = <String, double>{};
  void put(String key, double? v) {
    if (v != null) values[key] = v;
  }

  var kcal = g('energy-kcal_100g');
  if (kcal == null) {
    final kj = g('energy_100g'); // kilojoules
    if (kj != null) kcal = kj / 4.184;
  }
  var sodiumMg = g('sodium_100g', 1000);
  if (sodiumMg == null) {
    final salt = g('salt_100g'); // salt is about 40 % sodium
    if (salt != null) sodiumMg = salt * 0.4 * 1000;
  }

  put('calories', kcal);
  put('protein', g('proteins_100g'));
  put('carbs', g('carbohydrates_100g'));
  put('fat', g('fat_100g'));
  put('fibre', g('fiber_100g'));
  put('sugar', g('sugars_100g'));
  put('sat_fat', g('saturated-fat_100g'));
  put('sodium', sodiumMg);
  put('omega3', g('omega-3-fat_100g'));
  put('omega6', g('omega-6-fat_100g'));
  put('magnesium', g('magnesium_100g', 1000));
  put('potassium', g('potassium_100g', 1000));
  put('iron', g('iron_100g', 1000));
  put('zinc', g('zinc_100g', 1000));
  put('vitamin_c', g('vitamin-c_100g', 1000));
  put('vitamin_d', g('vitamin-d_100g', 1000000));
  put('vitamin_b6', g('vitamin-b6_100g', 1000));
  put('vitamin_b12', g('vitamin-b12_100g', 1000000));

  if (values.isEmpty) return null;
  final full = brandRaw.isEmpty ? name : '$name ($brandRaw)';
  return Food(
      id: newId(), name: full, values: values, source: 'Open Food Facts');
}

// ------------------------------------------------------------------
// USDA FoodData Central (whole foods)
// ------------------------------------------------------------------

Future<List<Food>> searchUsda(String query, String apiKey) async {
  final uri = Uri.https(
      'api.nal.usda.gov', '/fdc/v1/foods/search', {'api_key': apiKey});
  final res = await http
      .post(
        uri,
        headers: {'Content-Type': 'application/json', 'User-Agent': _userAgent},
        body: jsonEncode({
          'query': query,
          'dataType': ['Foundation', 'SR Legacy'],
          'pageSize': 25,
        }),
      )
      .timeout(_timeout);
  if (res.statusCode == 429) {
    throw Exception(
        'USDA rate limit reached. Get a free API key and enter it in the app.');
  }
  if (res.statusCode == 403) {
    throw Exception('USDA rejected the API key.');
  }
  if (res.statusCode != 200) {
    throw Exception('USDA answered with status ${res.statusCode}');
  }
  final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final foods = (data['foods'] as List?) ?? [];
  final out = <Food>[];
  for (final f in foods) {
    final food = _usdaFood(f as Map<String, dynamic>);
    if (food != null) out.add(food);
  }
  return out;
}

Food? _usdaFood(Map<String, dynamic> f) {
  final name = ((f['description'] as String?) ?? '').trim();
  if (name.isEmpty) return null;

  // USDA nutrient number (as text) -> amount per 100 g
  final byNumber = <String, double>{};
  for (final fn in (f['foodNutrients'] as List?) ?? []) {
    final m = fn as Map<String, dynamic>;
    final number = m['nutrientNumber']?.toString();
    final v = m['value'];
    if (number != null && v is num) byNumber[number] = v.toDouble();
  }

  double? one(String number) => byNumber[number];
  // Sum of several components; null if none of them is present.
  double? sum(List<String> numbers) {
    var any = false;
    var total = 0.0;
    for (final nr in numbers) {
      final v = byNumber[nr];
      if (v != null) {
        any = true;
        total += v;
      }
    }
    return any ? total : null;
  }

  final values = <String, double>{};
  void put(String key, double? v) {
    if (v != null) values[key] = v;
  }

  // 208 = energy (kcal); newer "Foundation" foods may only have the
  // Atwater energy values 957 / 958.
  put('calories', one('208') ?? one('957') ?? one('958'));
  put('protein', one('203'));
  put('carbs', one('205'));
  put('fat', one('204'));
  put('fibre', one('291'));
  put('sugar', one('269'));
  put('sat_fat', one('606'));
  put('sodium', one('307'));
  put('magnesium', one('304'));
  put('potassium', one('306'));
  put('iron', one('303'));
  put('zinc', one('309'));
  put('vitamin_c', one('401'));
  put('vitamin_d', one('328'));
  put('vitamin_b6', one('415'));
  put('vitamin_b12', one('418'));
  // Omega-3 = ALA + EPA + DPA + DHA. Omega-6 = linoleic + arachidonic acid.
  // USDA has no single "omega-3 / omega-6" total, so these are approximations.
  put('omega3', sum(['851', '629', '631', '621']));
  put('omega6', sum(['675', '620']));

  if (values.isEmpty) return null;
  return Food(id: newId(), name: name, values: values, source: 'USDA');
}
