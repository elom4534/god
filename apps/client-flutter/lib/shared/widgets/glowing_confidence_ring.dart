import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';

/// Anneau circulaire de confiance IA — dégradé `SweepGradient`, lueur néon
/// dessinée au `Canvas` (`MaskFilter.blur`), compteur central animé.
///
/// La couleur suit le score réel : Émeraude ≥ 80 %, Ambre 65–79 %, Carmin < 65 %.
/// Au clic → ouverture du détail (décision & raisonnement IA).
class GlowingConfidenceRing extends StatelessWidget {
  const GlowingConfidenceRing({
    super.key,
    required this.value,
    this.size = 64,
    this.strokeWidth = 6,
    this.onTap,
    this.label,
    this.centerText,
  });

  /// Score réel du modèle, entre 0 et 1 (ou 0–100).
  final double value;
  final double size;
  final double strokeWidth;
  final VoidCallback? onTap;
  final String? label;

  /// Texte central (par défaut : pourcentage réel).
  final String? centerText;

  double get _normalized => (value <= 1 ? value : value / 100).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = p.confidence(_normalized);
    final percent = (_normalized * 100).round();

    final ring = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: _normalized),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => CustomPaint(
        size: Size.square(size),
        painter: _RingPainter(progress: t, color: color, strokeWidth: strokeWidth),
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: Text(
              centerText ?? '$percent%',
              style: AppFonts.num(
                size: size * 0.26,
                weight: FontWeight.w800,
                color: p.textStrong,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ),
      ),
    );

    if (onTap == null) return ring;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size / 2),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ring,
            if (label != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(label!, style: AppFonts.caption(size: 9.5, color: p.textSoft)),
              ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color, required this.strokeWidth});

  final double progress;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;

    // Piste de fond.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color.withOpacity(0.12),
    );

    if (progress <= 0.001) return;

    final rect = Rect.fromCircle(center: center, radius: radius);
    const start = -math.pi / 2;
    final sweep = 2 * math.pi * progress;

    // Lueur néon.
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth + 5
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
      ..color = color.withOpacity(0.55);
    canvas.drawArc(rect, start, sweep, false, glowPaint);

    // Anneau principal avec dégradé dynamique.
    final mainPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: start,
        endAngle: start + 2 * math.pi,
        colors: [color.withOpacity(0.45), color],
        stops: [0, math.max(0.01, progress).clamp(0.0, 1.0)],
        transform: const GradientRotation(start),
      ).createShader(rect);
    canvas.drawArc(rect, start, sweep, false, mainPaint);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color || old.strokeWidth != strokeWidth;
}
