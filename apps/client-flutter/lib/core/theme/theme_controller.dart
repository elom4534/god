import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Thème actif, basculé instantanément (sans redémarrage) et persisté.
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController() : super(ThemeMode.dark);

  static const _key = 'pred_theme_mode';

  /// Charge la préférence utilisateur (défaut : Obsidian Glow).
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == 'light') value = ThemeMode.light;
      if (raw == 'dark') value = ThemeMode.dark;
    } catch (_) {
      /* défaut : Obsidian Glow */
    }
  }

  bool get isDark => value != ThemeMode.light;

  Future<void> setMode(ThemeMode mode) async {
    value = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, mode == ThemeMode.light ? 'light' : 'dark');
    } catch (_) {}
  }

  Future<void> toggle() => setMode(isDark ? ThemeMode.light : ThemeMode.dark);
}
