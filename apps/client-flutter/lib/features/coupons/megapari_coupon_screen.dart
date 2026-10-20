import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../widgets/coupon_code_card.dart';
import '../../widgets/responsible_gambling_banner.dart';

/// Écran complet: Générateur → affichage Code Coupon + DeepLink MegaPari
/// Utilise POST /api/v1/megapari/coupon/generate
class MegaPariCouponScreen extends StatefulWidget {
  const MegaPariCouponScreen({super.key});
  @override
  State<MegaPariCouponScreen> createState() => _MegaPariCouponScreenState();
}

class _MegaPariCouponScreenState extends State<MegaPariCouponScreen> {
  bool loading = false;
  String? couponCode;
  String? deepLink;
  String? error;
  String picksPreview = '1 pick: Over 2.5 (Premier League)';

  // Simule l'appel B2B — en prod: http.post(ApiBase + '/megapari/coupon/generate', body: {picks: [...]})
  Future<void> generateCoupon() async {
    setState(() { loading = true; error = null; couponCode = null; deepLink = null; });
    try {
      // TODO: Remplacer par vrai appel API
      // final res = await http.post(Uri.parse('${AppConfig.apiBase}/megapari/coupon/generate'),
      //   headers: {'Content-Type':'application/json','X-Country-Code':'TG'},
      //   body: jsonEncode({'picks': [...]}));

      // Mock: simule réponse B2B réelle {success, couponCode:"X9A1B", deepLink, message}
      await Future.delayed(const Duration(seconds: 1));
      // Exemple de vraie réponse vue en live: https://megapari.com/en?coupon-code=9V2XD
      const mockCode = 'X9A1B';
      const mockLink = 'https://megapari.com/en?coupon-code=X9A1B';

      setState(() {
        couponCode = mockCode;
        deepLink = mockLink;
        loading = false;
      });
    } catch (e) {
      setState(() { error = e.toString(); loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('MegaPari — Code Coupon')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ResponsibleGamblingBanner(),
            const SizedBox(height: 12),

            // Info picks
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sélections validées (1 par match, marge ≤5%)',
                        style: TextStyle(fontWeight: FontWeight.w600, color: cs.primary)),
                    const SizedBox(height: 6),
                    Text(picksPreview, style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 6),
                    Text('Le code sera généré via B2B MegaPari sharecoupon (ref=192) — Fail-Closed si marge >5%.',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // CTA Générer
            FilledButton.icon(
              onPressed: loading ? null : generateCoupon,
              icon: loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.confirmation_number),
              label: Text(loading ? 'Génération B2B...' : 'Générer le Code Coupon'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            ),

            if (error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(12)),
                child: Text(error!, style: TextStyle(color: cs.onErrorContainer, fontSize: 13)),
              ),
            ],

            if (couponCode != null && deepLink != null) ...[
              const SizedBox(height: 16),
              // Composant demandé: Code en gros + Copier + Ouvrir
              CouponCodeCard(
                couponCode: couponCode!,
                deepLink: deepLink!,
                message: 'Coupon généré avec succès — collez ce code dans MegaPari',
                onOpen: () {
                  Clipboard.setData(ClipboardData(text: deepLink!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Lien copié: $deepLink — ouvrez MegaPari et collez le code $couponCode')),
                  );
                },
              ),
              const SizedBox(height: 10),
              // Instructions
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.withOpacity(0.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('Comment utiliser:', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    SizedBox(height: 6),
                    Text('1. Copiez le code avec "Copier le code"', style: TextStyle(fontSize: 12)),
                    Text('2. Ouvrez MegaPari via le bouton "Ouvrir MegaPari"', style: TextStyle(fontSize: 12)),
                    Text('3. Dans MegaPari: Pari sportif → Coupon → Coller le code → Placer', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 14),
            Text(
              'Fail-Closed: si le marché est bloqué ou la marge >5% au moment du sharecoupon → aucun code généré.',
              style: TextStyle(fontSize: 10, color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
