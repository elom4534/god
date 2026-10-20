import 'package:flutter/material.dart';

class ResponsibleGamblingBanner extends StatelessWidget {
  const ResponsibleGamblingBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final isFr = Localizations.localeOf(context).languageCode == 'fr';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 8),
          Expanded(child: Text(
            isFr
              ? 'Jeu responsable — probabilités indicatives, pas de garantie de gain. 18+ uniquement. Fixez vos limites.'
              : 'Responsible gambling — indicative probabilities, no win guarantee. 18+ only. Set your limits.',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onErrorContainer),
          )),
        ],
      ),
    );
  }
}
