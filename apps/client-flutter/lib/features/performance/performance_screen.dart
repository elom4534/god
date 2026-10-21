import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/models/real_feed.dart';
import '../../core/services/coupon_history_store.dart';
import '../../core/services/feed_controller.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/glass_container.dart';
import '../../shared/widgets/shimmer.dart';

/// Performance — indicateurs réels du modèle et graphiques en direct.
class PerformanceScreen extends StatelessWidget {
  const PerformanceScreen({super.key, required this.feed});
  final FeedController feed;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FeedSnapshot?>(
      valueListenable: feed,
      builder: (context, snap, _) {
        final p = context.palette;
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Performance', style: AppFonts.title(size: 19, weight: FontWeight.w800)),
              Text('Indicateurs réels du moteur', style: AppFonts.caption(size: 10.5)),
              const SizedBox(height: 14),
              if (snap == null)
                const ShimmerMatchCard()
              else ...[
                _statsGrid(p, snap),
                const SizedBox(height: 12),
                _confidenceChart(p, snap),
                const SizedBox(height: 12),
                _dayChart(p, snap),
                const SizedBox(height: 12),
                _historyCard(p),
              ],
              SizedBox(height: MediaQuery.of(context).size.width < 768 ? 100 : 24),
            ],
          ),
        );
      },
    );
  }

  Widget _statsGrid(AppPalette p, FeedSnapshot snap) {
    final w = snap.window;
    final valueBets = snap.valueBets.length;
    final highConf = snap.picks.where((x) => x.probabilityPercent >= 80).length;
    return Row(
      children: [
        Expanded(
          child: _stat(p, '${w?.eventsFetched ?? 0}', 'Événements lus', p.cyan),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _stat(p, '${w?.validatedMarkets ?? 0}', 'Marchés validés', p.violet),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _stat(p, '$valueBets', 'Value bets', p.emerald),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _stat(p, '$highConf', 'Haute confiance', p.amber),
        ),
      ],
    );
  }

  Widget _stat(AppPalette p, String value, String label, Color color) {
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 13),
      radius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: AppFonts.num(size: 18, weight: FontWeight.w800, color: color)),
          const SizedBox(height: 3),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppFonts.caption(size: 9)),
        ],
      ),
    );
  }

  /// Répartition réelle des confiances du flux (données courantes).
  Widget _confidenceChart(AppPalette p, FeedSnapshot snap) {
    final high = snap.picks.where((x) => x.probabilityPercent >= 80).length.toDouble();
    final mid = snap.picks.where((x) => x.probabilityPercent >= 65 && x.probabilityPercent < 80).length.toDouble();
    final low = snap.picks.where((x) => x.probabilityPercent < 65).length.toDouble();
    final maxY = [high, mid, low, 1.0].reduce((a, b) => a > b ? a : b);

    return GlassContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Confiance IA — répartition', style: AppFonts.title(size: 13.5, weight: FontWeight.w800)),
          const SizedBox(height: 14),
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
                        const labels = ['≥ 80 %', '65–79 %', '< 65 %'];
                        final i = v.toInt();
                        if (i < 0 || i >= labels.length) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(labels[i], style: AppFonts.caption(size: 9.5, color: p.textSoft)),
                        );
                      },
                    ),
                  ),
                ),
                maxY: maxY * 1.2,
                barGroups: [
                  _bar(0, high, p.emerald),
                  _bar(1, mid, p.amber),
                  _bar(2, low, p.carmin),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  BarChartGroupData _bar(int x, double y, Color color) => BarChartGroupData(
        x: x,
        barRods: [
          BarChartRodData(
            toY: y == 0 ? 0.2 : y,
            width: 30,
            color: color,
            borderRadius: BorderRadius.circular(8),
            backDrawRodData: BackgroundBarChartRodData(
              show: true,
              toY: 1,
              color: color.withOpacity(0.08),
            ),
          ),
        ],
      );

  /// Répartition réelle aujourd'hui / demain.
  Widget _dayChart(AppPalette p, FeedSnapshot snap) {
    final today = (snap.window?.picksToday ?? 0).toDouble();
    final tomorrow = (snap.window?.picksTomorrow ?? 0).toDouble();
    return GlassContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sélections par jour', style: AppFonts.title(size: 13.5, weight: FontWeight.w800)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: today.toInt() == 0 && tomorrow.toInt() == 0 ? 1 : (today.toInt() < 1 ? 1 : today.toInt()),
                child: _dayBar(p, "Aujourd'hui", today.toInt(), p.cyan),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: today.toInt() == 0 && tomorrow.toInt() == 0 ? 1 : (tomorrow.toInt() < 1 ? 1 : tomorrow.toInt()),
                child: _dayBar(p, 'Demain', tomorrow.toInt(), p.violet),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dayBar(AppPalette p, String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppFonts.caption(size: 10)),
          const SizedBox(height: 4),
          Text('$count', style: AppFonts.num(size: 18, weight: FontWeight.w800, color: color)),
        ],
      ),
    );
  }

  /// Historique local des coupons réellement générés.
  Widget _historyCard(AppPalette p) {
    return GlassContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Mes coupons générés', style: AppFonts.title(size: 13.5, weight: FontWeight.w800)),
          const SizedBox(height: 12),
          FutureBuilder<List<CouponRecord>>(
            future: CouponHistoryStore.load(),
            builder: (context, snap) {
              final records = snap.data ?? const <CouponRecord>[];
              if (records.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text('Aucun coupon généré pour le moment.',
                      style: AppFonts.caption(size: 11.5)),
                );
              }
              return Column(
                children: records.take(8).map((r) {
                  final dt = r.createdAt;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(Icons.confirmation_number_outlined, size: 16, color: p.emerald),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${r.numMatches} matchs · ×${r.totalOdds.toStringAsFixed(2)}',
                            style: AppFonts.label(size: 12, weight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} '
                          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}',
                          style: AppFonts.num(size: 10, color: p.textSoft),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}
