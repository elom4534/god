import 'package:flutter/material.dart';
import '../../widgets/responsible_gambling_banner.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final isFr = Localizations.localeOf(context).languageCode=='fr';
    return Scaffold(
      appBar: AppBar(title: Text(isFr ? 'Historique & performance' : 'History & Performance')),
      body: ListView(
        padding: EdgeInsets.all(16),
        children: [
          ResponsibleGamblingBanner(),
          SizedBox(height:12),
          Card(child: ListTile(title: Text(isFr ? 'Performance modèles (7j)' : 'Model performance (7d)'), subtitle: Text('Calibration: Brier 0.21 — Précision 58% — Seuil p_lower\nMarchés désactivés: CORNERS_OU (drift PSI 0.23)'))),
          Card(child: ListTile(title: Text(isFr ? 'Derniers coupons' : 'Recent coupons'), subtitle: Text('3 placés — 2 rejetés (marge >5% au re-scan) — fail-closed OK'))),
          ExpansionTile(title: Text(isFr ? 'Backtests par ligue' : 'Backtests per league'), children: [
            Padding(padding: EdgeInsets.all(12), child: Text('Premier League: ROI -1.2% (calibré)\nLa Liga: ROI +0.8%\nVirtuel: drift détecté le 15/10 → marché suspendu')),
          ]),
          SizedBox(height:8),
          Text(isFr ? 'Aucune promesse de gain. Probas indicatives.' : 'No win promise. Indicative probabilities.', style: TextStyle(fontSize:11, color:Colors.grey)),
        ],
      ),
    );
  }
}
