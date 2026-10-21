import 'package:flutter/material.dart';

/// Palette d'accents vifs et électriques — portée par un [ThemeExtension]
/// pour être disponible dans les deux thèmes (Obsidian Glow / Pure Crystal).
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.emerald,
    required this.cyan,
    required this.violet,
    required this.amber,
    required this.carmin,
    required this.textStrong,
    required this.textSoft,
    required this.glass,
    required this.glassBorder,
    required this.shadow,
    required this.isDark,
  });

  /// Vert Émeraude Vif — haute confiance IA (≥ 80 %), value bets, gains.
  final Color emerald;

  /// Cyan Lumineux — analyse IA en cours, matchs en direct, performance.
  final Color cyan;

  /// Violet Néon — univers Football Virtuel, flux haute fréquence.
  final Color violet;

  /// Ambre Solaire — confiance intermédiaire (65 % – 79 %).
  final Color amber;

  /// Rouge Carmin Vif — alerte de risque, baisse brutale, match instable.
  final Color carmin;

  /// Texte principal (blanc pur / anthracite).
  final Color textStrong;

  /// Texte secondaire (gris acier / gris ardoise).
  final Color textSoft;

  /// Fond des cartes en verre.
  final Color glass;

  /// Bordure fine des surfaces.
  final Color glassBorder;

  /// Couleur des ombres portées.
  final Color shadow;

  final bool isDark;

  /// Couleur de confiance selon le score réel du modèle (0..1).
  Color confidence(double value) {
    final pct = value <= 1 ? value * 100 : value;
    if (pct >= 80) return emerald;
    if (pct >= 65) return amber;
    return carmin;
  }

  @override
  AppPalette copyWith({
    Color? emerald,
    Color? cyan,
    Color? violet,
    Color? amber,
    Color? carmin,
    Color? textStrong,
    Color? textSoft,
    Color? glass,
    Color? glassBorder,
    Color? shadow,
    bool? isDark,
  }) {
    return AppPalette(
      emerald: emerald ?? this.emerald,
      cyan: cyan ?? this.cyan,
      violet: violet ?? this.violet,
      amber: amber ?? this.amber,
      carmin: carmin ?? this.carmin,
      textStrong: textStrong ?? this.textStrong,
      textSoft: textSoft ?? this.textSoft,
      glass: glass ?? this.glass,
      glassBorder: glassBorder ?? this.glassBorder,
      shadow: shadow ?? this.shadow,
      isDark: isDark ?? this.isDark,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      emerald: Color.lerp(emerald, other.emerald, t)!,
      cyan: Color.lerp(cyan, other.cyan, t)!,
      violet: Color.lerp(violet, other.violet, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      carmin: Color.lerp(carmin, other.carmin, t)!,
      textStrong: Color.lerp(textStrong, other.textStrong, t)!,
      textSoft: Color.lerp(textSoft, other.textSoft, t)!,
      glass: Color.lerp(glass, other.glass, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }

  /// Accès pratique : `Theme.of(context).palette`.
  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>()!;
}

extension PaletteX on BuildContext {
  AppPalette get palette => AppPalette.of(this);
}
