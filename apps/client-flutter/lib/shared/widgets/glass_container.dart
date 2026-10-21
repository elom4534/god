import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';

/// Surface « verre » signature.
///
/// Dark (Obsidian Glow) : verre sombre translucide + blur 14 + bordure
/// lumineuse blanche 9 %. Light (Pure Crystal) : blanc pur + bordure
/// `#E2E8F0` + ombre douce diffuse.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.radius = 22,
    this.borderColor,
    this.glow = 0,
    this.glowColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Color? borderColor;

  /// Lueur de survol / sélection (0 → 1), idéale avec MouseRegion (Web).
  final double glow;
  final Color? glowColor;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final border = borderColor ?? p.glassBorder;
    final glowC = glowColor ?? p.cyan;

    final surface = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: p.isDark ? p.glass.withOpacity(0.88) : p.glass,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: glow > 0 ? Color.lerp(border, glowC, glow * 0.55)! : border,
          width: 1.0,
        ),
        boxShadow: [
          if (!p.isDark)
            BoxShadow(
              color: p.shadow.withOpacity(0.06 + glow * 0.05),
              blurRadius: 28 + glow * 16,
              offset: const Offset(0, 12),
            ),
          if (glow > 0)
            BoxShadow(
              color: glowC.withOpacity((p.isDark ? 0.16 : 0.10) * glow),
              blurRadius: 24 + glow * 18,
              spreadRadius: glow * 1.2,
            ),
        ],
      ),
      child: child,
    );

    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: p.isDark
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: surface,
            )
          : surface,
    );

    if (margin != null) return Padding(padding: margin!, child: clipped);
    return clipped;
  }
}
