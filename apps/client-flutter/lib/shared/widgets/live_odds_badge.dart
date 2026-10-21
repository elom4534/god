import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';

/// Badge de cote réelle réactif.
///
/// Dès qu'une nouvelle cote arrive par le flux temps réel (`didUpdateWidget`),
/// le badge déclenche un flash lumineux de 700 ms : vert si la cote monte,
/// rouge si elle baisse, avec micro-flèche ▲ / ▼.
class LiveOddsBadge extends StatefulWidget {
  const LiveOddsBadge({super.key, required this.odds, this.size = 14});

  final double odds;
  final double size;

  @override
  State<LiveOddsBadge> createState() => _LiveOddsBadgeState();
}

class _LiveOddsBadgeState extends State<LiveOddsBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  int _direction = 0; // +1 montée, -1 baisse

  @override
  void didUpdateWidget(LiveOddsBadge old) {
    super.didUpdateWidget(old);
    if (old.odds != widget.odds) {
      _direction = widget.odds > old.odds ? 1 : -1;
      _flash.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final flashColor = _direction > 0 ? p.emerald : p.carmin;

    return AnimatedBuilder(
      animation: _flash,
      builder: (context, _) {
        final t = Curves.easeOut.transform(_flash.value);
        return Container(
          padding: EdgeInsets.symmetric(horizontal: 9 + t * 3, vertical: 5 + t * 2),
          decoration: BoxDecoration(
            color: Color.lerp(p.cyan.withOpacity(0.14), flashColor.withOpacity(0.35), t),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Color.lerp(p.cyan.withOpacity(0.45), flashColor, t)!,
            ),
            boxShadow: [
              if (t > 0.01)
                BoxShadow(
                  color: flashColor.withOpacity(0.45 * t),
                  blurRadius: 14 * t,
                  spreadRadius: 1.5 * t,
                ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.odds.toStringAsFixed(2),
                style: AppFonts.num(size: widget.size, weight: FontWeight.w800, color: p.textStrong),
              ),
              if (_direction != 0 && t > 0.01) ...[
                const SizedBox(width: 3),
                Opacity(
                  opacity: (1 - t).clamp(0.0, 1.0),
                  child: Text(
                    _direction > 0 ? '▲' : '▼',
                    style: AppFonts.num(
                      size: widget.size * 0.8,
                      weight: FontWeight.w800,
                      color: flashColor,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
