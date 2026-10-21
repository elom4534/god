import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/real_feed.dart';
import '../../core/services/api_service.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/glass_container.dart';
import '../../shared/widgets/glowing_confidence_ring.dart';
import '../../shared/widgets/live_odds_badge.dart';
import '../../shared/widgets/shimmer.dart';

/// Vue détaillée d'un match — tous les marchés réels, graphiques,
/// raisonnement IA et calculateur de mise.
///
/// Affichée en panneau coulissant fixe sur Web / ≥ 768 px,
/// en BottomSheet plein écran en verre dépoli sur mobile.
class MatchDetailPanel extends StatefulWidget {
  const MatchDetailPanel({super.key, required this.pick, this.compact = false});

  final RealPick pick;
  final bool compact;

  /// Ouvre le détail : bottom sheet en verre dépoli sur mobile/tablette,
  /// panneau d'analyse fixe sur Web grand écran (≥ 1200 px) — le panneau
  /// droit se met à jour via `FeedController.selected`, sans changement
  /// brusque d'écran.
  static void open(BuildContext context, RealPick pick) {
    if (MediaQuery.sizeOf(context).width >= 1200) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.6,
        maxChildSize: 0.98,
        expand: false,
        builder: (context, scroll) => Container(
          decoration: BoxDecoration(
            color: context.palette.glass.withOpacity(context.palette.isDark ? 0.96 : 1),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: context.palette.glassBorder),
          ),
          child: MatchDetailPanel(pick: pick, compact: true),
        ),
      ),
    );
  }

  @override
  State<MatchDetailPanel> createState() => _MatchDetailPanelState();
}

class _MatchDetailPanelState extends State<MatchDetailPanel> {
  List<RealPick>? _markets;
  String? _error;
  int _tab = 0;
  final _stakeCtrl = TextEditingController(text: '1000');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MatchDetailPanel old) {
    super.didUpdateWidget(old);
    if (old.pick.eventId != widget.pick.eventId) {
      setState(() {
        _markets = null;
        _tab = 0;
        _error = null;
      });
      _load();
    }
  }

  @override
  void dispose() {
    _stakeCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final markets = await ApiService.matchPicks(eventId: widget.pick.eventId);
      if (!mounted) return;
      setState(() => _markets = markets);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is ApiException ? e.userMessage : 'Réessaie dans un instant.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final pick = widget.pick;
    return Column(
      children: [
        if (widget.compact)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(color: p.glassBorder, borderRadius: BorderRadius.circular(2)),
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            children: [
              _header(p, pick),
              const SizedBox(height: 14),
              _marketsSection(p, pick),
              const SizedBox(height: 14),
              _reasoning(p, pick),
              const SizedBox(height: 14),
              _stakeCalculator(p, pick),
            ],
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- blocs --

  Widget _header(AppPalette p, RealPick pick) {
    return GlassContainer(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pick.league.isNotEmpty ? pick.league : pick.sportName,
                  style: AppFonts.caption(size: 11, color: p.textSoft),
                ),
                const SizedBox(height: 4),
                Text(
                  pick.matchup,
                  style: AppFonts.title(size: 17, weight: FontWeight.w800, color: p.textStrong),
                ),
                const SizedBox(height: 4),
                Text(
                  _whenLabel(pick),
                  style: AppFonts.num(size: 11.5, weight: FontWeight.w600, color: pick.isTomorrow ? p.violet : p.cyan),
                ),
              ],
            ),
          ),
          GlowingConfidenceRing(value: pick.probabilityPercent / 100, size: 64),
        ],
      ),
    );
  }

  String _whenLabel(RealPick pick) {
    final s = pick.startTime?.toLocal();
    if (s == null) return pick.isTomorrow ? 'Demain' : "Aujourd'hui";
    final day = pick.isTomorrow ? 'Demain' : "Aujourd'hui";
    return '$day ${s.hour.toString().padLeft(2, '0')}:${s.minute.toString().padLeft(2, '0')}';
  }

  /// Onglets de marchés couvrant les marchés réellement présents dans les
  /// données du match (1X2, Double Chance, O/U, BTTS, Handicaps, Corners…).
  Widget _marketsSection(AppPalette p, RealPick pick) {
    if (_error != null) {
      return GlassContainer(
        child: Column(
          children: [
            Text(_error!, style: AppFonts.label(size: 13, color: p.carmin)),
            const SizedBox(height: 8),
            TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh, size: 16), label: const Text('Réessayer')),
          ],
        ),
      );
    }
    if (_markets == null) {
      return const GlassContainer(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            ShimmerBox(width: 160, height: 14),
            SizedBox(height: 12),
            ShimmerBox(width: double.infinity, height: 96),
            SizedBox(height: 10),
            ShimmerBox(width: double.infinity, height: 96),
          ],
        ),
      );
    }

    // Regroupement réel par marché, puis par sélection.
    final byMarket = <String, List<RealPick>>{};
    for (final m in _markets!) {
      byMarket.putIfAbsent(m.marketType, () => []).add(m);
    }
    final marketTypes = byMarket.keys.toList()..sort();
    if (marketTypes.isEmpty) {
      return GlassContainer(
        child: Text('Aucun marché disponible pour ce match.',
            style: AppFonts.label(size: 13, color: p.textSoft)),
      );
    }
    final current = marketTypes[_tab.clamp(0, marketTypes.length - 1)];
    final sels = byMarket[current]!;

    return GlassContainer(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: marketTypes.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final selected = i == _tab;
                final color = selected ? p.cyan : p.textSoft;
                return GestureDetector(
                  onTap: () => setState(() => _tab = i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: selected ? p.cyan.withOpacity(0.16) : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected ? p.cyan.withOpacity(0.6) : p.glassBorder,
                      ),
                    ),
                    child: Text(
                      _marketLabel(marketTypes[i], sels),
                      style: AppFonts.label(size: 11.5, weight: FontWeight.w700, color: color),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          ...sels.map((s) => _selectionRow(p, s)),
          const SizedBox(height: 12),
          _probChart(p, sels),
        ],
      ),
    );
  }

  static String _marketLabel(String marketType, List<RealPick> sels) {
    final line = sels.isNotEmpty ? sels.first.line : null;
    switch (marketType) {
      case '1X2':
        return '1X2';
      case 'DOUBLE_CHANCE':
        return 'Double Chance';
      case 'OVER_UNDER':
        return line != null ? 'O/U $line' : 'Over/Under';
      case 'BTTS':
        return 'BTTS';
      case 'HANDICAP':
        return line != null ? 'Handicap $line' : 'Handicap';
      case 'CORNERS_OU':
        return line != null ? 'Corners $line' : 'Corners';
      default:
        return marketType;
    }
  }

  Widget _selectionRow(AppPalette p, RealPick s) {
    final isChoice = s.selectionId == widget.pick.selectionId;
    final color = p.confidence(s.probabilityPercent / 100);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: isChoice ? p.cyan.withOpacity(0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: isChoice ? p.cyan.withOpacity(0.45) : p.glassBorder),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.selectionName,
                  style: AppFonts.label(size: 12.5, weight: FontWeight.w700, color: p.textStrong),
                ),
              ),
              if (isChoice)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: p.emerald.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('Choix IA', style: AppFonts.num(size: 9.5, weight: FontWeight.w800, color: p.emerald)),
                ),
              LiveOddsBadge(odds: s.odds, size: 12.5),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: (s.probabilityPercent / 100).clamp(0.0, 1.0),
                    minHeight: 7,
                    color: color,
                    backgroundColor: color.withOpacity(0.12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${s.probabilityPercent} %',
                style: AppFonts.num(size: 12, weight: FontWeight.w800, color: color),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Graphique dynamique : probabilité IA vs probabilité implicite (réelles).
  Widget _probChart(AppPalette p, List<RealPick> sels) {
    final groups = <BarChartGroupData>[];
    for (var i = 0; i < sels.length && i < 6; i++) {
      final s = sels[i];
      groups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: s.probabilityPercent.toDouble(),
              width: 12,
              color: p.cyan,
              borderRadius: BorderRadius.circular(5),
            ),
            BarChartRodData(
              toY: (s.impliedProb * 100),
              width: 12,
              color: p.violet.withOpacity(0.75),
              borderRadius: BorderRadius.circular(5),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _legendDot(p.cyan, 'Probabilité IA'),
            const SizedBox(width: 12),
            _legendDot(p.violet, 'Probabilité implicite'),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 130,
          child: BarChart(
            BarChartData(
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (v) => FlLine(color: p.glassBorder, strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    getTitlesWidget: (v, meta) {
                      final i = v.toInt();
                      if (i < 0 || i >= sels.length) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          sels[i].selectionName.length > 6
                              ? '${sels[i].selectionName.substring(0, 5)}…'
                              : sels[i].selectionName,
                          style: AppFonts.caption(size: 9, color: p.textSoft),
                        ),
                      );
                    },
                  ),
                ),
              ),
              barGroups: groups,
              maxY: 100,
            ),
          ),
        ),
      ],
    );
  }

  Widget _legendDot(Color color, String label) {
    final p = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label, style: AppFonts.caption(size: 10, color: p.textSoft)),
      ],
    );
  }

  /// Bloc « Décision & Raisonnement IA » — facteurs dérivés des données réelles.
  Widget _reasoning(AppPalette p, RealPick pick) {
    final factors = <({String label, String value, Color color})>[
      (
        label: 'Confiance IA',
        value: '${pick.probabilityPercent} %',
        color: p.confidence(pick.probabilityPercent / 100),
      ),
      (
        label: 'Cote réelle',
        value: pick.odds.toStringAsFixed(2),
        color: p.cyan,
      ),
      if (pick.marginPercent != null)
        (
          label: 'Marge bookmaker',
          value: '${pick.marginPercent!.toStringAsFixed(1)} %',
          color: pick.marginPercent! <= 5 ? p.emerald : p.carmin,
        ),
      (
        label: 'Écart de valeur',
        value: '${pick.valueEdge >= 0 ? '+' : ''}${(pick.valueEdge * 100).toStringAsFixed(1)} %',
        color: pick.valueEdge > 0 ? p.emerald : p.carmin,
      ),
      (
        label: 'Créneau',
        value: pick.isTomorrow ? 'Demain' : "Aujourd'hui",
        color: pick.isTomorrow ? p.violet : p.cyan,
      ),
    ];

    return GlassContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.psychology_alt_outlined, size: 18, color: p.violet),
              const SizedBox(width: 8),
              Text('Décision & Raisonnement IA', style: AppFonts.title(size: 14, weight: FontWeight.w800, color: p.textStrong)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${pick.marketLabel} · ${pick.selectionName}',
            style: AppFonts.label(size: 13, weight: FontWeight.w800, color: p.cyan),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: factors
                .map(
                  (f) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      color: f.color.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: f.color.withOpacity(0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${f.label} : ', style: AppFonts.caption(size: 10.5, color: p.textSoft)),
                        Text(f.value, style: AppFonts.num(size: 11, weight: FontWeight.w800, color: f.color)),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  /// Calculateur de mise temps réel (calcul sur cotes réelles).
  Widget _stakeCalculator(AppPalette p, RealPick pick) {
    return GlassContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calculate_outlined, size: 18, color: p.emerald),
              const SizedBox(width: 8),
              Text('Calculateur de mise', style: AppFonts.title(size: 14, weight: FontWeight.w800, color: p.textStrong)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _stakeCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Mise (XOF)',
                    prefixIcon: const Icon(Icons.payments_outlined, size: 18),
                  ),
                  style: AppFonts.num(size: 15, weight: FontWeight.w700, color: p.textStrong),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                  decoration: BoxDecoration(
                    color: p.emerald.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: p.emerald.withOpacity(0.35)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Gain potentiel', style: AppFonts.caption(size: 10, color: p.textSoft)),
                      const SizedBox(height: 3),
                      Text(
                        _potentialGain(pick),
                        style: AppFonts.num(size: 17, weight: FontWeight.w800, color: p.emerald),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _potentialGain(RealPick pick) {
    final stake = double.tryParse(_stakeCtrl.text.trim()) ?? 0;
    final gain = stake * pick.odds;
    final formatted = gain >= 1000
        ? '${(gain / 1000).toStringAsFixed(gain >= 100000 ? 0 : 1)} k'
        : gain.toStringAsFixed(0);
    return '$formatted XOF';
  }
}
