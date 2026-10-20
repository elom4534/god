import 'package:flutter/material.dart';

class AppTheme {
  static const seed = Color(0xFF0E4DA4);
  static const accent = Color(0xFF00C2A8);
  static final light = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
  );
  static final dark = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
  );
}
