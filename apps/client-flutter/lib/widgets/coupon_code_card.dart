import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_theme.dart';
import 'ui_kit.dart';

/// Carte code coupon MegaPari : code en gros + copier / ouvrir.
class CouponCodeCard extends StatelessWidget {
  final String couponCode;
  final String deepLink;
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
    return SoftCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const IconBubble(icon: Icons.confirmation_number, color: AppColors.green, size: 36, iconSize: 17),
              const SizedBox(width: 10),
              Text('Code Coupon MegaPari', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: AppColors.ink)),
              const Spacer(),
              const StatusBadge(text: 'Prêt', color: AppColors.green, icon: Icons.verified),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    couponCode,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 30,
                      letterSpacing: 5,
                      fontWeight: FontWeight.w900,
                      color: AppColors.primary,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _CopyButton(couponCode: couponCode),
              ],
            ),
          ),
          if (message != null && message!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(message!, style: const TextStyle(fontSize: 11.5, color: AppColors.muted), textAlign: TextAlign.center),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _copy(context),
                  icon: const Icon(Icons.copy, size: 17),
                  label: const Text('Copier'),
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new, size: 17),
                  label: const Text('Ouvrir MegaPari'),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext ctx) async {
    await Clipboard.setData(ClipboardData(text: couponCode));
    if (ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(content: Text('Code $couponCode copié ✓')),
      );
    }
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
      icon: const Icon(Icons.copy_all, size: 15),
      label: const Text('Copier'),
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.primary,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}
