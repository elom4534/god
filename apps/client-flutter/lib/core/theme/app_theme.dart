import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_palette.dart';

/// Design System « Obsidian Glow » (dark) & « Pure Crystal » (light).
///
/// Typographie :
///  - Interface & titres : Plus Jakarta Sans.
///  - Scores, cotes, pourcentages IA : Space Grotesk + `FontFeature.tabularFigures()`
///    → aucune secousse visuelle quand les valeurs rafraîchissent en direct.
class AppFonts {
  AppFonts._();

  static const tabular = [FontFeature.tabularFigures()];

  /// Nombre haute précision (cotes, scores, %, chronos).
  static TextStyle num({
    double size = 16,
    FontWeight weight = FontWeight.w700,
    Color? color,
    double? letterSpacing,
  }) =>
      GoogleFonts.spaceGrotesk(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
        fontFeatures: tabular,
      );

  /// Titre d'interface.
  static TextStyle title({double size = 16, FontWeight weight = FontWeight.w700, Color? color}) =>
      GoogleFonts.plusJakartaSans(fontSize: size, fontWeight: weight, color: color);

  /// Libellé courant.
  static TextStyle label({double size = 13, FontWeight weight = FontWeight.w500, Color? color}) =>
      GoogleFonts.plusJakartaSans(fontSize: size, fontWeight: weight, color: color);

  /// Légende secondaire.
  static TextStyle caption({double size = 11, Color? color}) =>
      GoogleFonts.plusJakartaSans(fontSize: size, fontWeight: FontWeight.w500, color: color);
}

abstract class AppTheme {
  /// Palette « Obsidian Glow » — noir profond bleuté, verre sombre translucide.
  static const obsidianBg = Color(0xFF07090E);
  static const obsidianGlass = Color(0xFF111623);

  /// Palette « Pure Crystal » — blanc nacré, surfaces blanches brillantes.
  static const crystalBg = Color(0xFFF4F7FB);
  static const crystalGlass = Color(0xFFFFFFFF);

  static const _darkPalette = AppPalette(
    emerald: Color(0xFF00F59B),
    cyan: Color(0xFF00D8FF),
    violet: Color(0xFF8B5CF6),
    amber: Color(0xFFFFB800),
    carmin: Color(0xFFFF2E63),
    textStrong: Color(0xFFFFFFFF),
    textSoft: Color(0xFF94A3B8),
    glass: obsidianGlass,
    glassBorder: Color(0x17FFFFFF), // blanc 9 %
    shadow: Color(0xFF000000),
    isDark: true,
  );

  static const _lightPalette = AppPalette(
    emerald: Color(0xFF00C97B),
    cyan: Color(0xFF00B8E6),
    violet: Color(0xFF7C3AED),
    amber: Color(0xFFE6A700),
    carmin: Color(0xFFEE2B58),
    textStrong: Color(0xFF0F172A),
    textSoft: Color(0xFF64748B),
    glass: crystalGlass,
    glassBorder: Color(0xFFE2E8F0),
    shadow: Color(0xFF0F172A),
    isDark: false,
  );

  static ThemeData dark() => _base(
        brightness: Brightness.dark,
        palette: _darkPalette,
        scaffold: obsidianBg,
      );

  static ThemeData light() => _base(
        brightness: Brightness.light,
        palette: _lightPalette,
        scaffold: crystalBg,
      );

  static ThemeData _base({
    required Brightness brightness,
    required AppPalette palette,
    required Color scaffold,
  }) {
    final isDark = brightness == Brightness.dark;
    final textTheme = TextTheme(
      headlineLarge: AppFonts.title(size: 28, weight: FontWeight.w800, color: palette.textStrong),
      headlineMedium: AppFonts.title(size: 22, weight: FontWeight.w800, color: palette.textStrong),
      titleLarge: AppFonts.title(size: 18, weight: FontWeight.w700, color: palette.textStrong),
      titleMedium: AppFonts.title(size: 15, weight: FontWeight.w700, color: palette.textStrong),
      titleSmall: AppFonts.title(size: 13, weight: FontWeight.w600, color: palette.textSoft),
      bodyLarge: AppFonts.label(size: 15, color: palette.textStrong),
      bodyMedium: AppFonts.label(size: 13, color: palette.textStrong),
      bodySmall: AppFonts.caption(size: 11.5, color: palette.textSoft),
      labelLarge: AppFonts.label(size: 13, weight: FontWeight.w700, color: palette.textStrong),
      labelMedium: AppFonts.label(size: 11, weight: FontWeight.w600, color: palette.textSoft),
      labelSmall: AppFonts.caption(size: 10, color: palette.textSoft),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: scaffold,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: isDark ? const Color(0xFF00D8FF) : const Color(0xFF00B8E6),
        onPrimary: isDark ? const Color(0xFF07090E) : Colors.white,
        secondary: palette.violet,
        onSecondary: Colors.white,
        error: palette.carmin,
        onError: Colors.white,
        surface: palette.glass,
        onSurface: palette.textStrong,
        surfaceContainerHighest: isDark ? const Color(0xFF1A2130) : const Color(0xFFEDF1F7),
        outline: palette.glassBorder,
        onSurfaceVariant: palette.textSoft,
        shadow: palette.shadow,
      ),
      extensions: [palette],
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: palette.textStrong),
        titleTextStyle: AppFonts.title(size: 18, weight: FontWeight.w800, color: palette.textStrong),
      ),
      cardTheme: CardTheme(
        color: palette.glass,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: palette.shadow.withOpacity(isDark ? 0.5 : 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: palette.glassBorder),
        ),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(color: palette.glassBorder, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF0C111B) : Colors.white,
        hintStyle: AppFonts.caption(size: 13, color: palette.textSoft),
        labelStyle: AppFonts.caption(size: 13, color: palette.textSoft),
        helperStyle: AppFonts.caption(size: 10.5, color: palette.textSoft),
        prefixIconColor: palette.textSoft,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: _roundedBorder(palette.glassBorder),
        enabledBorder: _roundedBorder(palette.glassBorder),
        focusedBorder: _roundedBorder(palette.cyan, width: 1.6),
        errorBorder: _roundedBorder(palette.carmin),
        focusedErrorBorder: _roundedBorder(palette.carmin, width: 1.6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.cyan,
          foregroundColor: isDark ? const Color(0xFF07090E) : Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          textStyle: AppFonts.label(size: 14, weight: FontWeight.w800),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.cyan,
          side: BorderSide(color: palette.cyan.withOpacity(0.6), width: 1.4),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          textStyle: AppFonts.label(size: 13, weight: FontWeight.w700),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.cyan,
          textStyle: AppFonts.label(size: 13, weight: FontWeight.w700),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? const Color(0xFF0C111B) : Colors.white,
        selectedColor: palette.cyan.withOpacity(0.18),
        labelStyle: AppFonts.label(size: 12, weight: FontWeight.w600, color: palette.textStrong),
        side: BorderSide(color: palette.glassBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        showCheckmark: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.glass,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: palette.cyan.withOpacity(0.16),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => AppFonts.label(
            size: 11,
            weight: FontWeight.w700,
            color: states.contains(WidgetState.selected) ? palette.cyan : palette.textSoft,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected) ? palette.cyan : palette.textSoft,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? const Color(0xFF1A2130) : const Color(0xFF0F172A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentTextStyle: AppFonts.label(size: 13, color: Colors.white),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: palette.cyan),
      sliderTheme: SliderThemeData(
        activeTrackColor: palette.cyan,
        inactiveTrackColor: palette.cyan.withOpacity(0.18),
        thumbColor: palette.cyan,
        trackHeight: 5,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? palette.cyan : palette.textSoft,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.cyan.withOpacity(0.3)
              : palette.glassBorder,
        ),
      ),
    );
  }

  static OutlineInputBorder _roundedBorder(Color color, {double width = 1}) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: color, width: width),
      );
}
