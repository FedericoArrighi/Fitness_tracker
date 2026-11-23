import 'package:flutter/material.dart';
import 'db.dart';

/// A colour scheme the app can be dressed in. Every palette has a light and
/// a dark version.
class ThemePalette {
  final String id, name;
  final Color seed;
  const ThemePalette(this.id, this.name, this.seed);
}

/// Palette, light/dark/system and pure black. The choices are kept on this
/// device.
class AppTheme {
  static const palettes = [
    ThemePalette('forest', 'Forest', Color(0xFF2F6F5E)),
    ThemePalette('ocean', 'Ocean', Color(0xFF1E6091)),
    ThemePalette('sky', 'Sky', Color(0xFF0288D1)),
    ThemePalette('violet', 'Violet', Color(0xFF6750A4)),
    ThemePalette('berry', 'Berry', Color(0xFF9C2F6B)),
    ThemePalette('rose', 'Rose', Color(0xFFD6336C)),
    ThemePalette('sunset', 'Sunset', Color(0xFFE0662B)),
    ThemePalette('amber', 'Amber', Color(0xFFB8860B)),
    ThemePalette('lime', 'Lime', Color(0xFF6B8E23)),
    ThemePalette('graphite', 'Graphite', Color(0xFF546E7A)),
  ];

  static final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.system);
  static final ValueNotifier<String> palette = ValueNotifier('forest');
  static final ValueNotifier<bool> pureBlack = ValueNotifier(false);

  /// Anything in the app that should redraw when the look changes.
  static Listenable get changes => Listenable.merge([mode, palette, pureBlack]);

  /// Reads the saved choices (call once the database is open).
  static void load() {
    final db = AppDb.instance;
    final s = db.getSetting('theme_mode');
    mode.value = s == 'light'
        ? ThemeMode.light
        : (s == 'dark' ? ThemeMode.dark : ThemeMode.system);
    final p = db.getSetting('theme_palette');
    if (p != null && palettes.any((x) => x.id == p)) palette.value = p;
    pureBlack.value = db.getSetting('theme_black') == '1';
  }

  static void setMode(ThemeMode m) {
    mode.value = m;
    AppDb.instance.setSetting('theme_mode',
        m == ThemeMode.light ? 'light' : (m == ThemeMode.dark ? 'dark' : 'system'));
  }

  static void setPalette(String id) {
    palette.value = id;
    AppDb.instance.setSetting('theme_palette', id);
  }

  static void setPureBlack(bool v) {
    pureBlack.value = v;
    AppDb.instance.setSetting('theme_black', v ? '1' : '0');
  }

  static Color get seed =>
      palettes.firstWhere((p) => p.id == palette.value, orElse: () => palettes.first).seed;

  static ThemeData light() => ThemeData(
        useMaterial3: true,
        colorSchemeSeed: seed,
        brightness: Brightness.light,
      );

  static ThemeData dark() {
    if (!pureBlack.value) {
      return ThemeData(
        useMaterial3: true,
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
      );
    }
    // black background, good for OLED screens
    final cs = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark)
        .copyWith(surface: Colors.black);
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: Colors.black,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        surfaceTintColor: Colors.transparent,
      ),
      navigationBarTheme: const NavigationBarThemeData(backgroundColor: Colors.black),
    );
  }
}
