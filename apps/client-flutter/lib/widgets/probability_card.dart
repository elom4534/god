import 'package:flutter/material.dart';

class ProbabilityCard extends StatelessWidget {
  final String title;
  final double pLower;
  final double pModel;
  final String confidence;
  final List<Map<String,String>> factors;
  const ProbabilityCard({super.key, required this.title, required this.pLower, required this.pModel, required this.confidence, this.factors = const []});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pct = (pLower*100).toStringAsFixed(1);
    final confColor = confidence=='HIGH' ? Colors.green : confidence=='MEDIUM' ? Colors.orange : Colors.grey;
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(title, style: TextStyle(fontWeight: FontWeight.w600))),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: confColor.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                child: Text(confidence, style: TextStyle(color: confColor, fontWeight: FontWeight.bold, fontSize: 11)),
              )
            ]),
            SizedBox(height: 8),
            Row(children: [
              Text('$pct%', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: cs.primary)),
              SizedBox(width: 8),
              Text('borne basse prudente\nmodèle ${(pModel*100).toStringAsFixed(1)}%', style: TextStyle(fontSize: 11, color: Colors.grey)),
            ]),
            SizedBox(height: 4),
            LinearProgressIndicator(value: pLower, color: cs.primary, backgroundColor: cs.surfaceVariant),
            if (factors.isNotEmpty) ...[
              SizedBox(height: 8),
              Text('Facteurs clés:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ...factors.map((f) => Row(children: [Icon(Icons.circle, size:6, color: f['impact']!.startsWith('+')?Colors.green:Colors.red), Text(' ${f['name']} ${f['impact']}', style: TextStyle(fontSize:12))])),
            ],
          ],
        ),
      ),
    );
  }
}
