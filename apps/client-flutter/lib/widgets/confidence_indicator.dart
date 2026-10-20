import 'package:flutter/material.dart';

class ConfidenceIndicator extends StatelessWidget {
  final double value; // p_lower
  const ConfidenceIndicator({super.key, required this.value});
  @override
  Widget build(BuildContext context) {
    final label = value>=0.55 ? 'Élevée' : value>=0.50 ? 'Moyenne' : 'Faible';
    return Column(children: [
      LinearProgressIndicator(value: value, minHeight: 8, borderRadius: BorderRadius.circular(4)),
      SizedBox(height: 4),
      Text('$label — ${(value*100).toStringAsFixed(1)}%', style: TextStyle(fontSize: 11)),
    ]);
  }
}
