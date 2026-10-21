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

/// Football Virtuel (FIFA / Sega) — univers Violet Néon, flux haute fréquence.
class VirtualScreen extends StatelessWidget {
  const VirtualScreen({super.key, required this.feed, required this.query});

  final FeedController feed;
  final String query;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FeedSnapshot?>(
      valueListenable: feed,
      builder: (context, snap, _) {
        final p = context.palette;
        final all = snap?.picks ?? const <RealPick>[];
        final q = query.trim().toLowerCase();
        final picks = all
            .where((x) =>
                q.isEmpty ||
                x.matchup.toLowerCase().contains(q) ||
                x.league.toLowerCase().contains(q))
            .toList();

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [p.violet, p.violet.withOpacity(0.6)]),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [BoxShadow(color: p.violet.withOpacity(0.4), blurRadius: 18)],
                      ),
                      child: const Icon(Icons.sports_esports, color: Colors.white, size: 21),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Football Virtuel', style: AppFonts.title(size: 19, weight: FontWeight.w800)),
                          Text('FIFA · Sega — flux haute fréquence', style: AppFonts.caption(size: 10.5)),
                        ],
                      ),
                    ),
                    _liveChip(context),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _vStat(context, value: '${picks.length}', label: 'Sélections', color: p.violet),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _vStat(
                        context,
                        value: snap?.window != null ? '${snap!.window!.validatedMarkets}' : '—',
                        label: 'Marchés actifs',
                        color: p.cyan,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _vStat(
                        context,
                        value: snap != null ? '${snap.topByConfidence.isNotEmpty ? snap.topByConfidence.first.probabilityPercent : 0}%' : '—',
                        label: 'Meilleure confiance',
                        color: p.emerald,
                      ),
                    ),
                  ],
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
              SliverToBoxAdapter(child: _empty(context, p))
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                sliver: SliverList.separated(
                  itemCount: picks.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final pick = picks[i];
                    return BentoMatchCard(
                      pick: pick,
                      selected: feed.selected.value?.selectionId == pick.selectionId,
                      onOpen: () {
                        feed.selected.value = pick;
                        MatchDetailPanel.open(context, pick);
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

  Widget _liveChip(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: p.violet.withOpacity(0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.violet.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: p.violet,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: p.violet.withOpacity(0.9), blurRadius: 8)],
            ),
          ),
          const SizedBox(width: 6),
          Text('HAUTE FRÉQ.', style: AppFonts.num(size: 9.5, weight: FontWeight.w800, color: p.violet)),
        ],
      ),
    );
  }

  Widget _vStat(BuildContext context, {required String value, required String label, required Color color}) {
    return GlassContainer(
      borderColor: color.withOpacity(0.25),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      radius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: AppFonts.num(size: 19, weight: FontWeight.w800, color: color)),
          const SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppFonts.caption(size: 9.5)),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, AppPalette p) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: GlassContainer(
        borderColor: p.violet.withOpacity(0.3),
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            GlowingConfidenceRing(value: 0.42, size: 72),
            const SizedBox(height: 14),
            Text('Aucun match virtuel disponible.', style: AppFonts.title(size: 14, weight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'Les rencontres FIFA / Sega apparaîtront ici dès leur ouverture.',
              textAlign: TextAlign.center,
              style: AppFonts.caption(size: 11),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () {
                HapticFeedback.lightImpact();
                feed.refresh();
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Actualiser'),
            ),
          ],
        ),
      ),
    );
  }
}
