import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/real_feed.dart';
import '../../core/models/virtual_feed.dart';
import '../../core/services/api_service.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/bento_match_card.dart';
import '../../shared/widgets/countdown_clock.dart';
import '../../shared/widgets/glass_container.dart';
import '../../shared/widgets/glowing_confidence_ring.dart';
import '../../shared/widgets/live_odds_badge.dart';
import '../../shared/widgets/shimmer.dart';

/// Football Virtuel temps réel (FIFA Virtual & Sega Virtual).
///
/// Affichage répliqué depuis le flux Partner API MegaPari : heure de jeu,
/// minute, équipes, score et cotes. Rafraîchissement par flux périodique
/// UNIQUEMENT — aucun bouton manuel. Les prédictions restent masquées
/// (« Calibration en cours ») tant que la capture réelle < 24 h ou
/// l'échantillon < 100 rounds.
class VirtualLiveBoardScreen extends StatefulWidget {
  const VirtualLiveBoardScreen({super.key, required this.query});

  final String query;

  @override
  State<VirtualLiveBoardScreen> createState() => _VirtualLiveBoardScreenState();
}

class _VirtualLiveBoardScreenState extends State<VirtualLiveBoardScreen> {
  static const _providers = <(String, String, IconData)>[
    ('FIFA_VIRTUAL', 'FIFA Virtual', Icons.sports_soccer),
    ('SEGA_VIRTUAL', 'Sega Virtual', Icons.sports_esports),
  ];

  String _provider = 'FIFA_VIRTUAL';
  Timer? _refresh;
  bool _loading = true;
  String? _error;

  List<VirtualRound> _live = const [];
  List<VirtualRound> _upcoming = const [];
  List<VirtualResult> _results = const [];
  final Map<String, VirtualPrediction> _predictions = {};
  VirtualReliability? _reliability;

  @override
  void initState() {
    super.initState();
    _load();
    // Flux temps réel : rafraîchissement périodique automatique.
    _refresh = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  /// Repli : prédiction neutre en « Calibration en cours » (jamais de valeur inventée).
  VirtualPrediction _calibratingPrediction(String id) => VirtualPrediction(
        round: VirtualRound(
          roundId: id,
          provider: _provider,
          league: '',
          homeTeam: '',
          awayTeam: '',
          scheduledStart: null,
          status: 'SCHEDULED',
        ),
        sampleSize: 0,
        captureHours: 0,
        calibrationInProgress: true,
      );

  Future<void> _load() async {
    try {
      final results = await Future.wait<dynamic>([
        ApiService.virtualRounds(provider: _provider, status: 'LIVE', limit: 20),
        ApiService.virtualUpcoming(provider: _provider, limit: 30),
        ApiService.virtualRecentResults(provider: _provider, limit: 20),
        ApiService.virtualReliability(),
      ]);
      final live = (results[0] as List).whereType<VirtualRound>().toList();
      final upcoming = (results[1] as List).whereType<VirtualRound>().toList();
      final recent = (results[2] as List).whereType<VirtualResult>().toList();
      final reliability = results[3] as VirtualReliability;

      // Prédictions : uniquement pour les rounds visibles (les plus proches).
      final targets = <String>[for (final r in live) r.roundId, for (final r in upcoming.take(4)) r.roundId];
      final preds = await Future.wait([
        for (final id in targets)
          ApiService.virtualPrediction(id).catchError((_) => _calibratingPrediction(id)),
      ]);

      if (!mounted) return;
      setState(() {
        _live = live;
        _upcoming = upcoming;
        _results = recent;
        _reliability = reliability;
        _predictions
          ..clear()
          ..addEntries(preds.map((p) => MapEntry(p.round.roundId, p)));
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Flux virtuel momentanément indisponible.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final q = widget.query.trim().toLowerCase();
    bool match(VirtualRound r) =>
        q.isEmpty ||
        r.homeTeam.toLowerCase().contains(q) ||
        r.awayTeam.toLowerCase().contains(q) ||
        r.league.toLowerCase().contains(q);

    final live = _live.where(match).toList();
    final upcoming = _upcoming.where(match).toList();

    return RefreshIndicator(
      onRefresh: _load,
      color: p.violet,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          SliverToBoxAdapter(child: _header(context)),
          if (_error != null)
            SliverToBoxAdapter(child: _statusBanner(context, _error!, p.carmin)),
          SliverToBoxAdapter(child: _providerSelector(context)),
          if (_loading && _live.isEmpty && _upcoming.isEmpty)
            SliverToBoxAdapter(child: _skeletons())
          else ...[
            if (upcoming.isNotEmpty) SliverToBoxAdapter(child: _nextRound(context, upcoming.first)),
            if (live.isNotEmpty) ...[
              SliverToBoxAdapter(child: _sectionTitle(context, 'En direct', p.carmin, Icons.sports_score)),
              SliverList.list(children: [for (final r in live) _liveCard(context, r)]),
            ],
            SliverToBoxAdapter(child: _sectionTitle(context, 'Prochains rounds', p.violet, Icons.upcoming)),
            if (upcoming.isEmpty)
              SliverToBoxAdapter(child: _statusBanner(context, 'Aucun round programmé pour le moment.', p.textSoft))
            else
              SliverList.list(children: [for (final r in upcoming.take(12)) _upcomingTile(context, r)]),
            SliverToBoxAdapter(child: _sectionTitle(context, '20 derniers résultats', p.emerald, Icons.emoji_events_outlined)),
            if (_results.isEmpty)
              SliverToBoxAdapter(child: _statusBanner(context, 'Capture en cours — résultats en accumulation.', p.textSoft))
            else
              SliverList.list(children: [for (final r in _results) _resultTile(context, r)]),
            SliverToBoxAdapter(child: _reliabilityPanel(context)),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ header
  Widget _header(BuildContext context) {
    final p = context.palette;
    return Padding(
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
            child: const Icon(Icons.sports_soccer, color: Colors.white, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Football Virtuel', style: AppFonts.title(size: 19, weight: FontWeight.w800)),
                Text('FIFA · Sega — rounds et cotes en temps réel', style: AppFonts.caption(size: 10.5)),
              ],
            ),
          ),
          _liveChip(context),
        ],
      ),
    );
  }

  Widget _liveChip(BuildContext context) {
    final p = context.palette;
    final n = _live.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: (n > 0 ? p.carmin : p.textSoft).withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: (n > 0 ? p.carmin : p.textSoft).withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: n > 0 ? p.carmin : p.textSoft,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            n > 0 ? '$n EN DIRECT' : "À L'AFFÛT",
            style: AppFonts.caption(size: 10, color: n > 0 ? p.carmin : p.textSoft),
          ),
        ],
      ),
    );
  }

  Widget _providerSelector(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: p.glass,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: p.glassBorder),
        ),
        child: Row(
          children: [
            for (final (id, label, icon) in _providers)
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    if (_provider == id) return;
                    setState(() {
                      _provider = id;
                      _loading = true;
                      _predictions.clear();
                    });
                    _load();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: _provider == id ? p.violet.withOpacity(0.18) : Colors.transparent,
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: _provider == id ? p.violet.withOpacity(0.55) : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 15, color: _provider == id ? p.violet : p.textSoft),
                        const SizedBox(width: 7),
                        Text(
                          label,
                          style: AppFonts.label(
                            size: 12.5,
                            weight: _provider == id ? FontWeight.w700 : FontWeight.w500,
                            color: _provider == id ? p.textStrong : p.textSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- next round
  Widget _nextRound(BuildContext context, VirtualRound round) {
    final p = context.palette;
    final pred = _predictions[round.roundId];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: GlassContainer(
        glow: 0.5,
        glowColor: p.violet,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.schedule, size: 14, color: p.violet),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'PROCHAIN ROUND — ${round.league}',
                    style: AppFonts.caption(size: 10, color: p.textSoft),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                CountdownClock(target: round.scheduledStart, compact: true),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(round.homeTeam, style: AppFonts.title(size: 15, weight: FontWeight.w700), maxLines: 2),
                      const SizedBox(height: 6),
                      Text(round.awayTeam, style: AppFonts.title(size: 15, weight: FontWeight.w700), maxLines: 2),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _confidenceBlock(context, round, pred),
              ],
            ),
            const SizedBox(height: 12),
            Center(child: CountdownClock(target: round.scheduledStart)),
            const SizedBox(height: 12),
            _oddsRow(context, pred),
          ],
        ),
      ),
    );
  }

  Widget _confidenceBlock(BuildContext context, VirtualRound round, VirtualPrediction? pred) {
    final p = context.palette;
    final calibrating = pred == null || pred.calibrationInProgress;
    return Column(
      children: [
        GlowingConfidenceRing(
          value: calibrating ? 0 : pred.dominantConfidence,
          size: 72,
          centerText: calibrating ? '—' : '${(pred.dominantConfidence * 100).round()}%',
        ),
        const SizedBox(height: 6),
        Text(
          calibrating ? 'Calibration en cours' : 'Confiance modèle',
          style: AppFonts.caption(size: 9.5, color: calibrating ? p.amber : p.textSoft),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _oddsRow(BuildContext context, VirtualPrediction? pred) {
    final p = context.palette;
    final odds = pred?.latestOdds ?? const <VirtualOdd>[];
    VirtualOdd? pick(String sel) {
      for (final o in odds) {
        if (o.market == '1X2' && o.selection == sel) return o;
      }
      return null;
    }

    final w1 = pick('1');
    final x = pick('X');
    final w2 = pick('2');
    if (w1 == null && x == null && w2 == null) {
      return Text('Cotes en cours de capture…', style: AppFonts.caption(size: 10.5, color: p.textSoft));
    }
    return Row(
      children: [
        Expanded(child: _oddCell(context, '1', w1)),
        const SizedBox(width: 8),
        Expanded(child: _oddCell(context, 'X', x)),
        const SizedBox(width: 8),
        Expanded(child: _oddCell(context, '2', w2)),
      ],
    );
  }

  Widget _oddCell(BuildContext context, String label, VirtualOdd? odd) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        color: p.glass,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.glassBorder),
      ),
      child: Column(
        children: [
          Text(label, style: AppFonts.caption(size: 10, color: p.textSoft)),
          const SizedBox(height: 3),
          if (odd != null)
            LiveOddsBadge(odds: odd.odds, size: 15)
          else
            Text('—', style: AppFonts.num(size: 14, color: p.textSoft)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------- live
  Widget _liveCard(BuildContext context, VirtualRound round) {
    final p = context.palette;
    final pred = _predictions[round.roundId];
    final minute = round.minute;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: GlassContainer(
        borderColor: p.carmin.withOpacity(0.35),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: p.carmin.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    minute != null ? "${round.periodName ?? ''} $minute'" : (round.periodName ?? 'EN DIRECT'),
                    style: AppFonts.caption(size: 10, color: p.carmin),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(round.league, style: AppFonts.caption(size: 10, color: p.textSoft), overflow: TextOverflow.ellipsis),
                ),
                if (pred != null && !pred.calibrationInProgress)
                  SizedBox(
                    width: 42,
                    height: 42,
                    child: GlowingConfidenceRing(value: pred.dominantConfidence, size: 42, strokeWidth: 4),
                  )
                else
                  Text('Calibration en cours', style: AppFonts.caption(size: 9, color: p.amber)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(round.homeTeam, style: AppFonts.label(size: 13, weight: FontWeight.w600), maxLines: 2),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: p.violet.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${round.homeScore ?? 0} : ${round.awayScore ?? 0}',
                    style: AppFonts.num(size: 17, weight: FontWeight.w800, color: p.textStrong),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(round.awayTeam, style: AppFonts.label(size: 13, weight: FontWeight.w600), textAlign: TextAlign.end, maxLines: 2),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _oddsRow(context, pred),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- upcoming
  Widget _upcomingTile(BuildContext context, VirtualRound round) {
    final p = context.palette;
    final pred = _predictions[round.roundId];

    // BentoMatchCard dès qu'une cote 1X2 réelle est capturée pour le round.
    final odds = pred?.latestOdds ?? const <VirtualOdd>[];
    VirtualOdd? best;
    for (final o in odds) {
      if (o.market == '1X2' && (best == null || o.odds > best.odds)) best = o;
    }
    if (best != null) {
      final start = round.scheduledStart;
      final pick = RealPick(
        eventId: round.roundId,
        home: round.homeTeam,
        away: round.awayTeam,
        league: round.league,
        sportName: round.provider == 'SEGA_VIRTUAL' ? 'Sega Virtual' : 'FIFA Virtual',
        marketType: '1X2',
        selectionId: '1X2_main',
        selectionName: best.selection == '1'
            ? 'Victoire ${round.homeTeam}'
            : best.selection == 'X'
                ? 'Match nul'
                : 'Victoire ${round.awayTeam}',
        line: null,
        odds: best.odds,
        marginPercent: null,
        probabilityPercent: pred != null && !pred.calibrationInProgress
            ? (pred.dominantConfidence * 100).round()
            : 0,
        day: _dayLabel(start),
        startTime: start,
        isEngineChoice: false,
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: BentoMatchCard(pick: pick),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: GlassContainer(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(round.matchup, style: AppFonts.label(size: 12.5, weight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  Text(round.league, style: AppFonts.caption(size: 9.5, color: p.textSoft), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            CountdownClock(target: round.scheduledStart, compact: true),
          ],
        ),
      ),
    );
  }

  String _dayLabel(DateTime? start) {
    if (start == null) return 'TODAY';
    final now = DateTime.now().toUtc();
    final s = start.isUtc ? start : start.toUtc();
    return s.year == now.year && s.month == now.month && s.day == now.day ? 'TODAY' : 'TOMORROW';
  }

  // ---------------------------------------------------------------- results
  Widget _resultTile(BuildContext context, VirtualResult r) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
      child: GlassContainer(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${r.homeTeam} – ${r.awayTeam}',
                      style: AppFonts.label(size: 12, weight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(r.league, style: AppFonts.caption(size: 9, color: p.textSoft), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: p.violet.withOpacity(0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text('${r.homeScore} : ${r.awayScore}',
                  style: AppFonts.num(size: 14, weight: FontWeight.w800, color: p.textStrong)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: (r.btts ? p.emerald : p.textSoft).withOpacity(0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                r.btts ? 'BTTS OUI' : 'BTTS NON',
                style: AppFonts.caption(size: 9, color: r.btts ? p.emerald : p.textSoft),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- reliability
  Widget _reliabilityPanel(BuildContext context) {
    final p = context.palette;
    final rel = _reliability;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: GlassContainer(
        glow: 0.35,
        glowColor: p.violet,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified_user_outlined, size: 17, color: p.violet),
                const SizedBox(width: 8),
                Text('Fiabilité Virtuel', style: AppFonts.title(size: 15, weight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 12),
            Text(rel?.message ?? '', style: AppFonts.label(size: 12, weight: FontWeight.w500, color: p.textSoft)),
            const SizedBox(height: 14),
            if (rel != null)
              for (final entry in rel.providers.entries) _reliabilityStat(context, entry.key, entry.value),
          ],
        ),
      ),
    );
  }

  Widget _reliabilityStat(BuildContext context, String provider, Map<String, dynamic> stats) {
    final p = context.palette;
    final label = provider == 'SEGA_VIRTUAL' ? 'Sega Virtual' : 'FIFA Virtual';
    final sample = (stats['sample_size'] as num?)?.toInt() ?? 0;
    final hours = (stats['capture_hours'] as num?)?.toDouble() ?? 0;
    final calibrating = stats['calibration_in_progress'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 108, child: Text(label, style: AppFonts.label(size: 11.5, weight: FontWeight.w600))),
          Expanded(
            child: Text(
              '$sample rounds observés · ${hours.toStringAsFixed(1)} h de capture',
              style: AppFonts.caption(size: 10, color: p.textSoft),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: (calibrating ? p.amber : p.emerald).withOpacity(0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              calibrating ? 'Calibration en cours' : 'Calibré',
              style: AppFonts.caption(size: 9.5, color: calibrating ? p.amber : p.emerald),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ divers
  Widget _sectionTitle(BuildContext context, String title, Color color, IconData icon) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 7),
          Text(title, style: AppFonts.title(size: 14, weight: FontWeight.w800)),
          const Spacer(),
          Text('flux partenaire · temps réel', style: AppFonts.caption(size: 9, color: p.textSoft)),
        ],
      ),
    );
  }

  Widget _statusBanner(BuildContext context, String text, Color color) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.30)),
        ),
        child: Text(text, style: AppFonts.caption(size: 11.5, color: p.textSoft), textAlign: TextAlign.center),
      ),
    );
  }

  Widget _skeletons() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: const [
          ShimmerBox(height: 120, radius: 22),
          SizedBox(height: 12),
          ShimmerBox(height: 92, radius: 18),
          SizedBox(height: 12),
          ShimmerBox(height: 92, radius: 18),
        ],
      ),
    );
  }
}
