import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/ui_kit.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final isFr = Localizations.localeOf(context).languageCode=='fr';
    return Scaffold(
      appBar: AppBar(title: Text(isFr ? 'Historique' : 'History')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          // Performance — chiffres clés
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isFr ? 'Performance des modèles (7 j)' : 'Model performance (7d)', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.ink)),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: StatTile(value: '0.21', label: 'Brier', color: AppColors.primary, leading: const IconBubble(icon: Icons.show_chart, size: 38, iconSize: 18))),
                    Container(width: 1, height: 36, color: AppColors.border),
                    Expanded(child: StatTile(value: '58 %', label: isFr ? 'Précision' : 'Accuracy', color: AppColors.green, leading: const IconBubble(icon: Icons.check_circle_outline, color: AppColors.green, size: 38, iconSize: 18))),
                    Container(width: 1, height: 36, color: AppColors.border),
                    Expanded(child: StatTile(value: '3', label: isFr ? 'Coupons placés' : 'Coupons placed', color: AppColors.orange, leading: const IconBubble(icon: Icons.confirmation_number_outlined, color: AppColors.orange, size: 38, iconSize: 18))),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isFr ? 'Derniers coupons' : 'Recent coupons', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.ink)),
                const SizedBox(height: 12),
                _couponRow(isFr ? 'Combiné 3 matchs — ×1.86' : '3-fold accumulator — ×1.86', AppColors.green, isFr ? 'Généré' : 'Generated'),
                _couponRow(isFr ? 'Combiné 5 matchs — ×2.40' : '5-fold accumulator — ×2.40', AppColors.green, isFr ? 'Généré' : 'Generated'),
                _couponRow(isFr ? 'Combiné 6 matchs — ×3.00' : '6-fold accumulator — ×3.00', AppColors.red, isFr ? 'Rejeté' : 'Rejected'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isFr ? 'Backtests par ligue' : 'Backtests per league', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.ink)),
                const SizedBox(height: 12),
                _leagueRow('Premier League', 'ROI −1.2 %', AppColors.red),
                _leagueRow('La Liga', 'ROI +0.8 %', AppColors.green),
                _leagueRow('Serie A', 'ROI +0.3 %', AppColors.green),
                _leagueRow('Bundesliga', 'ROI −0.4 %', AppColors.orange),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _couponRow(String title, Color color, String badge) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.confirmation_number_outlined, size: 17, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.ink))),
          StatusBadge(text: badge, color: color),
        ],
      ),
    );
  }

  static Widget _leagueRow(String league, String roi, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.emoji_events_outlined, size: 17, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(league, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.ink))),
          StatusBadge(text: roi, color: color),
        ],
      ),
    );
  }
}
