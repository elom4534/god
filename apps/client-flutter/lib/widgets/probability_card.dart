import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import 'ui_kit.dart';

/// Carte de probabilité d'un pick : titre, pourcentage, barre, facteurs.
class ProbabilityCard extends StatelessWidget {
  final String title;
  final double pLower;
  final double pModel;
  final String confidence;
  final List<Map<String,String>> factors;
  const ProbabilityCard({super.key, required this.title, required this.pLower, required this.pModel, required this.confidence, this.factors = const []});

  @override
  Widget build(BuildContext context) {
    final pct = (pLower * 100).round();
    final color = confidenceColor(pct);
    final confLabel = confidence == 'HIGH'
        ? 'Élevée'
        : confidence == 'MEDIUM'
            ? 'Moyenne'
            : 'Faible';
    return SoftCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: AppColors.ink))),
            StatusBadge(text: confLabel, color: color),
          ]),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('$pct%', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: color, height: 1, letterSpacing: -0.5)),
              const SizedBox(width: 10),
              Expanded(child: SoftProgress(value: pLower, color: color)),
            ],
          ),
          if (factors.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: factors.map((f) {
                final positive = (f['impact'] ?? '').startsWith('+');
                return StatusBadge(
                  text: '${f['name']} ${f['impact']}',
                  color: positive ? AppColors.green : AppColors.red,
                  icon: positive ? Icons.trending_up : Icons.trending_down,
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}
