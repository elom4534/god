import 'package:flutter/material.dart';

import '../../core/models/real_feed.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';
import 'glass_container.dart';
import 'glowing_confidence_ring.dart';
import 'live_odds_badge.dart';

/// Carte de match vivante « Bento » — 100 % données réelles.
///
/// En-tête : compétition, heure de coup d'envoi (tabulaire) ou badge LIVE
/// avec point vert pulsant. Corps : équipes, marché retenu par l'IA, cote
/// réelle (flash ▲/▼ au changement), écart de valeur et anneau de confiance.
class BentoMatchCard extends StatefulWidget {
  const BentoMatchCard({
    super.key,
    required this.pick,
    this.onOpen,
    this.onTapRing,
    this.selected = false,
    this.large = false,
  });

  final RealPick pick;
  final VoidCallback? onOpen;
  final VoidCallback? onTapRing;
  final bool selected;
  final bool large;

  @override
  State<BentoMatchCard> createState() => _BentoMatchCardState();
}

class _BentoMatchCardState extends State<BentoMatchCard> with SingleTickerProviderStateMixin {
  double _hover = 0;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pick = widget.pick;
    final confColor = p.confidence(pick.probabilityPercent / 100);
    final valuePositive = pick.valueEdge > 0.005;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = 1),
      onExit: (_) => setState(() => _hover = 0),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          child: GlassContainer(
            glow: _hover * 0.5 + (widget.selected ? 0.6 : 0),
            glowColor: confColor,
            borderColor: widget.selected ? confColor.withOpacity(0.6) : null,
            padding: EdgeInsets.all(widget.large ? 18 : 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(p, pick, confColor),
                const SizedBox(height: 10),
                _matchup(p, pick),
                const SizedBox(height: 12),
                _decision(p, pick, confColor, valuePositive),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(AppPalette p, RealPick pick, Color confColor) {
    final kickoff = pick.startTime?.toLocal();
    final time = kickoff == null
        ? ''
        : '${kickoff.hour.toString().padLeft(2, '0')}:${kickoff.minute.toString().padLeft(2, '0')}';
    return Row(
      children: [
        Expanded(
          child: Text(
            pick.league.isNotEmpty ? pick.league : pick.sportName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.caption(size: 11, color: p.textSoft),
          ),
        ),
        if (pick.isLiveNow)
          FadeTransition(
            opacity: Tween(begin: 0.35, end: 1.0).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: p.emerald.withOpacity(0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: p.emerald, shape: BoxShape.circle, boxShadow: [
                      BoxShadow(color: p.emerald.withOpacity(0.8), blurRadius: 6),
                    ]),
                  ),
                  const SizedBox(width: 5),
                  Text('LIVE', style: AppFonts.num(size: 10, weight: FontWeight.w800, color: p.emerald)),
                ],
              ),
            ),
          )
        else ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (pick.isTomorrow ? p.violet : p.cyan).withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              time.isEmpty ? (pick.isTomorrow ? 'Demain' : "Aujourd'hui") : time,
              style: AppFonts.num(
                size: 10.5,
                weight: FontWeight.w700,
                color: pick.isTomorrow ? p.violet : p.cyan,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _matchup(AppPalette p, RealPick pick) {
    return Row(
      children: [
        _Monogram(name: pick.home, color: p.cyan),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pick.home.isNotEmpty ? pick.home : '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.title(size: widget.large ? 15 : 13.5, weight: FontWeight.w700, color: p.textStrong),
              ),
              const SizedBox(height: 2),
              Text(
                pick.away.isNotEmpty ? pick.away : '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.title(size: widget.large ? 15 : 13.5, weight: FontWeight.w700, color: p.textSoft),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _decision(AppPalette p, RealPick pick, Color confColor, bool valuePositive) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: confColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: confColor.withOpacity(0.35)),
                ),
                child: Text(
                  '${pick.marketLabel} · ${pick.selectionName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.label(size: 11, weight: FontWeight.w700, color: confColor),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  LiveOddsBadge(odds: pick.odds),
                  const SizedBox(width: 8),
                  if (valuePositive)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: p.emerald.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        'Valeur +${(pick.valueEdge * 100).toStringAsFixed(1)} %',
                        style: AppFonts.num(size: 10.5, weight: FontWeight.w700, color: p.emerald),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        GlowingConfidenceRing(
          value: pick.probabilityPercent / 100,
          size: widget.large ? 72 : 58,
          onTap: widget.onTapRing ?? widget.onOpen,
        ),
      ],
    );
  }
}

/// Pastille monogramme (initiales des équipes) — pas de logo externe requis.
class _Monogram extends StatelessWidget {
  const _Monogram({required this.name, required this.color});
  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final initials = name
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withOpacity(0.22), color.withOpacity(0.08)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        initials.isEmpty ? '·' : initials,
        style: AppFonts.num(size: 12, weight: FontWeight.w800, color: color),
      ),
    );
  }
}
