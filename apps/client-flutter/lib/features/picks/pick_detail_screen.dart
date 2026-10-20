import 'package:flutter/material.dart';
import '../../widgets/probability_card.dart';
import '../../widgets/responsible_gambling_banner.dart';

class PickDetailScreen extends StatelessWidget {
  final Map<String,dynamic> pick;
  const PickDetailScreen({super.key, required this.pick});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Détail pick')),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            ProbabilityCard(
              title: pick['title'] ?? 'Pick',
              pLower: (pick['p_lower'] as double?) ?? 0.5,
              pModel: (pick['p_model'] as double?) ?? 0.55,
              confidence: pick['confidence'] ?? 'MEDIUM',
              factors: (pick['factors'] as List?)?.cast<Map<String,String>>() ?? [],
            ),
            SizedBox(height:12),
            ResponsibleGamblingBanner(),
            SizedBox(height:12),
            Text('Modèle: ${pick['model_version'] ?? 'v0.3.0'} — as_of: ${pick['as_of'] ?? '-'}', style: TextStyle(fontSize:11, color:Colors.grey)),
          ],
        ),
      ),
    );
  }
}
