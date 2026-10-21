import 'package:flutter/material.dart';

import '../../core/models/real_feed.dart';
import '../../core/services/feed_controller.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/bento_match_card.dart';
import '../../shared/widgets/glass_container.dart';
import '../../shared/widgets/shimmer.dart';
import '../match_detail/match_detail_panel.dart';

/// Matchs en direct — flux réel, cotes rafraîchies en continu
/// (flash ▲/▼ automatique sur chaque badge de cote).
class LiveScreen extends StatelessWidget {
  const LiveScreen({super.key, required this.feed, required this.query});

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
            .toList()
          ..sort((a, b) {
            // Les matchs en cours d'abord, puis par heure de coup d'envoi.
            final la = a.isLiveNow ? 0 : 1;
            final lb = b.isLiveNow ? 0 : 1;
            if (la != lb) return la - lb;
            return (a.startTime ?? DateTime(2100)).compareTo(b.startTime ?? DateTime(2100));
          });

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Icon(Icons.sports_soccer, color: p.cyan, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Football Réel — Live', style: AppFonts.title(size: 19, weight: FontWeight.w800)),
                          Text(
                            snap?.window?.asOf != null
                                ? 'Mis à jour à ${_hhmm(DateTime.tryParse(snap!.window!.asOf!) ?? snap.fetchedAt)}'
                                : 'Flux temps réel',
                            style: AppFonts.caption(size: 10.5),
                          ),
                        ],
                      ),
                    ),
                    if (snap != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: p.emerald.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${picks.length} matchs',
                          style: AppFonts.num(size: 11, weight: FontWeight.w700, color: p.emerald),
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
                    SizedBox(height: 12),
                    ShimmerMatchCard(),
                  ]),
                ),
              )
            else if (picks.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: GlassContainer(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Icon(Icons.hourglass_top, size: 34, color: p.cyan.withOpacity(0.7)),
                        const SizedBox(height: 10),
                        Text('Aucun match pour le moment.', style: AppFonts.title(size: 14, weight: FontWeight.w700)),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: feed.refresh,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Actualiser'),
                        ),
                      ],
                    ),
                  ),
                ),
              )
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

  static String _hhmm(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}
