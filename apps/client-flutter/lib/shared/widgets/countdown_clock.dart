import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';

/// Compte à rebours synchronisé sur l'heure de coup d'envoi réelle
/// (`scheduled_start` du flux Partner API). Rafraîchissement automatique
/// chaque seconde — aucun bouton manuel.
class CountdownClock extends StatefulWidget {
  const CountdownClock({super.key, required this.target, this.compact = false});

  final DateTime? target;
  final bool compact;

  @override
  State<CountdownClock> createState() => _CountdownClockState();
}

class _CountdownClockState extends State<CountdownClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final target = widget.target;
    if (target == null) {
      return Text('--:--', style: AppFonts.num(size: widget.compact ? 16 : 28, weight: FontWeight.w800, color: p.textSoft));
    }
    final now = DateTime.now().toUtc();
    final start = target.isUtc ? target : target.toUtc();
    final diff = start.difference(now);

    String text;
    Color color;
    if (diff.isNegative) {
      final elapsed = -diff;
      text = 'EN DIRECT ${elapsed.inMinutes.toString().padLeft(2, '0')}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
      color = p.carmin;
    } else if (diff.inHours >= 1) {
      text = '${diff.inHours.toString().padLeft(2, '0')}:${(diff.inMinutes % 60).toString().padLeft(2, '0')}:${(diff.inSeconds % 60).toString().padLeft(2, '0')}';
      color = p.textStrong;
    } else {
      text = '${diff.inMinutes.toString().padLeft(2, '0')}:${(diff.inSeconds % 60).toString().padLeft(2, '0')}';
      color = diff.inMinutes < 2 ? p.amber : p.textStrong;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_outlined, size: widget.compact ? 14 : 18, color: color),
        const SizedBox(width: 6),
        Text(
          text,
          style: AppFonts.num(
            size: widget.compact ? 15 : 28,
            weight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }
}
