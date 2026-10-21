import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';

/// Effet shimmer brillant, adapté aux deux thèmes — remplace les
/// `CircularProgressIndicator` lors du chargement initial des flux.
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({super.key, this.width = double.infinity, this.height = 16, this.radius = 10});

  final double width;
  final double height;
  final double radius;

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final base = p.isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.05);
    final highlight = p.isDark ? Colors.white.withOpacity(0.14) : Colors.white.withOpacity(0.9);

    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(-1 + 2 * _c.value, 0),
            end: Alignment(1 + 2 * _c.value, 0),
            colors: [base, highlight, base],
            stops: const [0.25, 0.5, 0.75],
          ),
        ),
      ),
    );
  }
}

/// Carte de chargement shimmer complète (structure des bento cards).
class ShimmerMatchCard extends StatelessWidget {
  const ShimmerMatchCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.palette.glass.withOpacity(context.palette.isDark ? 0.88 : 1),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: context.palette.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          ShimmerBox(width: 120, height: 12),
          SizedBox(height: 14),
          ShimmerBox(width: 200, height: 18),
          SizedBox(height: 10),
          Row(
            children: [
              ShimmerBox(width: 64, height: 64, radius: 32),
              SizedBox(width: 12),
              Expanded(child: ShimmerBox(height: 40)),
            ],
          ),
          SizedBox(height: 14),
          ShimmerBox(width: double.infinity, height: 36),
        ],
      ),
    );
  }
}
