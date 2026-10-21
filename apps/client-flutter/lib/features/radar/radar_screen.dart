import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/real_feed.dart';
import '../../core/services/feed_controller.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/bento_match_card.dart';
import '../../shared/widgets/glass_container.dart';
import '../../shared/widgets/glowing_confidence_ring.dart';
import '../../shared/widgets/shimmer.dart';
import '../match_detail/match_detail_panel.dart';
import '../settings/settings_screen.dart';

/// Radar IA — écran principal.
///
/// Sélecteur segmenté fluide « Football Réel ⚡ Football Virtuel »,
/// carrousel des Meilleures Décisions IA, grille des matchs du flux réel.
class RadarScreen extends StatelessWidget {
  const RadarScreen({
    super.key,
    required this.feed,
    required this.query,
    required this.locale,
    required this.onLocaleChange,
  });

  final FeedController feed;
  final String query;
  final Locale locale;
  final ValueChanged<Locale> onLocaleChange;

  @override
  Widget build(BuildContext context) {
    final isFr = locale.languageCode == 'fr';
    return ValueListenableBuilder<FeedSnapshot?>(
      valueListenable: feed,
      builder: (context, snap, _) {
        final picks = _filtered(snap);
        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _header(context, isFr)),
            SliverToBoxAdapter(child: _modeSelector(context, isFr)),
            SliverToBoxAdapter(child: _statsBand(context, snap, isFr)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
                child: Text(
                  isFr ? 'Meilleures Décisions IA' : 'Top AI Decisions',
                  style: AppFonts.title(size: 16, weight: FontWeight.w800),
                ),
              ),
            ),
            SliverToBoxAdapter(child: _topCarousel(context, snap, picks, isFr)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
                child: Text(
                  isFr ? 'Matchs du flux en direct' : 'Live feed matches',
                  style: AppFonts.title(size: 16, weight: FontWeight.w800),
                ),
              ),
            ),
            if (feed.loading && (snap == null || snap.picks.isEmpty))
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    ShimmerMatchCard(),
                    SizedBox(height: 12),
                    ShimmerMatchCard(),
                  ]),
                ),
              )
            else if (picks.isEmpty)
              SliverToBoxAdapter(child: _emptyState(context, isFr))
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList.separated(
                  itemCount: picks.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final p = picks[i];
                    return BentoMatchCard(
                      pick: p,
                      large: false,
                      selected: feed.selected.value?.selectionId == p.selectionId,
                      onOpen: () {
                        feed.selected.value = p;
                        MatchDetailPanel.open(context, p);
                      },
                      onTapRing: () {
                        feed.selected.value = p;
                        MatchDetailPanel.open(context, p);
                      },
                    );
                  },
                ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: MediaQuery.of(context).size.width < 768 ? 100 : 24)),
          ],
        );
      },
    );
  }

  List<RealPick> _filtered(FeedSnapshot? snap) {
    if (snap == null) return const [];
    var picks = snap.picks;
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      picks = picks
          .where((p) =>
              p.matchup.toLowerCase().contains(q) ||
              p.league.toLowerCase().contains(q) ||
              p.sportName.toLowerCase().contains(q))
          .toList();
    }
    return picks;
  }

  Widget _header(BuildContext context, bool isFr) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [p.cyan, p.violet]),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [BoxShadow(color: p.cyan.withOpacity(0.35), blurRadius: 18)],
            ),
            child: const Icon(Icons.radar, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isFr ? 'Radar IA' : 'AI Radar',
                    style: AppFonts.title(size: 20, weight: FontWeight.w800)),
                Text(
                  isFr ? 'Décisions en direct · MegaPari' : 'Live decisions · MegaPari',
                  style: AppFonts.caption(size: 11),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: isFr ? 'Actualiser le flux' : 'Refresh feed',
            onPressed: feed.loading ? null : feed.refresh,
            icon: feed.loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: isFr ? 'Réglages' : 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(locale: locale, onLocaleChange: onLocaleChange),
                ),
              );
            },
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
    );
  }

  /// Sélecteur segmenté fluide avec retour haptique.
  Widget _modeSelector(BuildContext context, bool isFr) {
    final p = context.palette;
    final virtual = feed.virtual;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: GestureDetector(
        onTapDown: (_) => HapticFeedback.lightImpact(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          height: 52,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: p.glass.withOpacity(p.isDark ? 0.9 : 1),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: (virtual ? p.violet : p.cyan).withOpacity(0.4)),
            boxShadow: [
              BoxShadow(
                color: (virtual ? p.violet : p.cyan).withOpacity(0.12),
                blurRadius: 22,
              ),
            ],
          ),
          child: Stack(
            children: [
              AnimatedAlign(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                alignment: virtual ? Alignment.centerRight : Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: 0.5,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: virtual
                            ? [p.violet, p.violet.withOpacity(0.75)]
                            : [p.cyan, p.emerald.withOpacity(0.8)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: (virtual ? p.violet : p.emerald).withOpacity(0.45),
                          blurRadius: 16,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: _modeHalf(
                      context,
                      icon: Icons.sports_soccer,
                      label: isFr ? 'Football Réel' : 'Real Football',
                      selected: !virtual,
                      onTap: () {
                        HapticFeedback.lightImpact();
                        feed.setVirtual(false);
                      },
                    ),
                  ),
                  Expanded(
                    child: _modeHalf(
                      context,
                      icon: Icons.bolt,
                      label: isFr ? 'Football Virtuel' : 'Virtual Football',
                      selected: virtual,
                      onTap: () {
                        HapticFeedback.lightImpact();
                        feed.setVirtual(true);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeHalf(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final p = context.palette;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 16,
            color: selected ? Colors.white : p.textSoft,
            shadows: selected ? [Shadow(color: Colors.black.withOpacity(0.25), blurRadius: 6)] : null,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.label(
                size: 12.5,
                weight: FontWeight.w800,
                color: selected ? Colors.white : p.textSoft,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Bandeau statistiques réelles (données du flux, jamais fictives).
  Widget _statsBand(BuildContext context, FeedSnapshot? snap, bool isFr) {
    final p = context.palette;
    final w = snap?.window;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: _stat(
              context,
              value: w != null ? '${w.todayEvents}' : '—',
              label: isFr ? "Matchs aujourd'hui" : 'Matches today',
              color: p.emerald,
              icon: Icons.today_outlined,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _stat(
              context,
              value: w != null ? '${w.tomorrowEvents}' : '—',
              label: isFr ? 'Matchs demain' : 'Matches tomorrow',
              color: p.violet,
              icon: Icons.event_outlined,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _stat(
              context,
              value: w != null ? '${w.validatedMarkets}' : '—',
              label: isFr ? 'Marchés validés' : 'Validated markets',
              color: p.cyan,
              icon: Icons.query_stats,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(
    BuildContext context, {
    required String value,
    required String label,
    required Color color,
    required IconData icon,
  }) {
    final p = context.palette;
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      radius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(height: 8),
          Text(value, style: AppFonts.num(size: 20, weight: FontWeight.w800, color: p.textStrong)),
          const SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppFonts.caption(size: 9.5)),
        ],
      ),
    );
  }

  /// Carrousel des meilleures décisions (anneaux de confiance lumineux).
  Widget _topCarousel(BuildContext context, FeedSnapshot? snap, List<RealPick> picks, bool isFr) {
    if (snap == null || picks.isEmpty) return const SizedBox.shrink();
    final top = [...picks]..sort((a, b) => b.probabilityPercent.compareTo(a.probabilityPercent));
    final items = top.take(6).toList();
    return SizedBox(
      height: 168,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final pick = items[i];
          final color = context.palette.confidence(pick.probabilityPercent / 100);
          return GestureDetector(
            onTap: () {
              feed.selected.value = pick;
              MatchDetailPanel.open(context, pick);
            },
            child: Container(
              width: 236,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    color.withOpacity(context.palette.isDark ? 0.16 : 0.10),
                    context.palette.glass.withOpacity(context.palette.isDark ? 0.88 : 1),
                  ],
                ),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: color.withOpacity(0.35)),
                boxShadow: [
                  BoxShadow(color: color.withOpacity(0.14), blurRadius: 24, offset: const Offset(0, 10)),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          pick.league.isNotEmpty ? pick.league : pick.sportName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.caption(size: 9.5),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          pick.matchup,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.title(size: 13, weight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.14),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            '${pick.marketLabel} · ${pick.selectionName}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.label(size: 10, weight: FontWeight.w700, color: color),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '× ${pick.odds.toStringAsFixed(2)}',
                          style: AppFonts.num(size: 14, weight: FontWeight.w800, color: context.palette.textStrong),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlowingConfidenceRing(value: pick.probabilityPercent / 100, size: 62),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _emptyState(BuildContext context, bool isFr) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: GlassContainer(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.satellite_alt_outlined, size: 38, color: p.cyan.withOpacity(0.7)),
            const SizedBox(height: 12),
            Text(
              isFr ? 'Flux en cours d\'analyse…' : 'Feed analysis in progress…',
              style: AppFonts.title(size: 14, weight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              isFr
                  ? 'Les opportunités apparaîtront ici dès qu\'elles seront disponibles.'
                  : 'Opportunities will appear here as soon as they are available.',
              textAlign: TextAlign.center,
              style: AppFonts.caption(size: 11),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: feed.refresh,
              icon: const Icon(Icons.refresh, size: 17),
              label: Text(isFr ? 'Actualiser' : 'Refresh'),
            ),
          ],
        ),
      ),
    );
  }
}
