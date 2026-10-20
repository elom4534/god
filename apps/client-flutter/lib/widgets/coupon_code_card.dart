import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Widget premium: Code Coupon MegaPari en gros + 2 actions
/// - "Copier le code" (copie dans presse-papier + SnackBar)
/// - "Ouvrir MegaPari" (deepLink)
class CouponCodeCard extends StatelessWidget {
  final String couponCode; // ex: X9A1B
  final String deepLink;   // ex: https://megapari.com/en?coupon-code=X9A1B
  final String? message;
  final VoidCallback? onOpen;
  const CouponCodeCard({
    super.key,
    required this.couponCode,
    required this.deepLink,
    this.message,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.confirmation_number, color: cs.primary),
                const SizedBox(width: 8),
                Text('Code Coupon MegaPari',
                    style: TextStyle(fontWeight: FontWeight.w700, color: cs.primary)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(children: const [
                    Icon(Icons.verified, size: 14, color: Colors.green),
                    SizedBox(width: 4),
                    Text('Prêt à coller', style: TextStyle(fontSize: 11, color: Colors.green, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Code en gros — style ticket
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withOpacity(0.6),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cs.primary.withOpacity(0.25), width: 1.4),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      couponCode,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 32,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w900,
                        color: cs.primary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Bouton copier compact à côté du code
                  _CopyButton(couponCode: couponCode),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message ?? 'Copiez ce code et collez-le manuellement dans MegaPari (Pari sportif → Coupon → Code).',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),

            // Actions: Copier + Ouvrir
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copy(context),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copier le code'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(color: cs.primary),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onOpen ?? () => _openDeepLink(context),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Ouvrir MegaPari'),
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // DeepLink preview (tronqué, copiable)
            GestureDetector(
              onTap: () => _copyLink(context),
              child: Text(
                deepLink,
                style: TextStyle(fontSize: 10, color: cs.primary, decoration: TextDecoration.underline),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _copy(BuildContext ctx) async {
    await Clipboard.setData(ClipboardData(text: couponCode));
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text('Code $couponCode copié ✓'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  void _copyLink(BuildContext ctx) async {
    await Clipboard.setData(ClipboardData(text: deepLink));
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Lien copié ✓')));
    }
  }

  void _openDeepLink(BuildContext ctx) {
    // En prod: url_launcher launchUrl(Uri.parse(deepLink))
    // Ici on copie le lien et informe (évite dépendance url_launcher en démo)
    Clipboard.setData(ClipboardData(text: deepLink));
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text('Lien MegaPari copié: $deepLink'),
        action: SnackBarAction(label: 'OK', onPressed: () {}),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  final String couponCode;
  const _CopyButton({required this.couponCode});
  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: couponCode));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copié: $couponCode')));
        }
      },
      icon: const Icon(Icons.copy_all, size: 16),
      label: const Text('Copier'),
      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
    );
  }
}

/// Variante compacte pour listes / bottom sheet
class CouponCodeCompact extends StatelessWidget {
  final String couponCode;
  final String deepLink;
  const CouponCodeCompact({super.key, required this.couponCode, required this.deepLink});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(child: Text(couponCode, style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 18))),
          IconButton(onPressed: () => Clipboard.setData(ClipboardData(text: couponCode)), icon: const Icon(Icons.copy)),
          FilledButton(onPressed: () => Clipboard.setData(ClipboardData(text: deepLink)), child: const Text('Ouvrir')),
        ],
      ),
    );
  }
}
