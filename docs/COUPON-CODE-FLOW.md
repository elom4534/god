# Flow Code Coupon MegaPari — B2B + Flutter

## Séquence
```
Flutter (Copier code) → NestJS POST /api/v1/megapari/coupon/generate {picks: [{sportEventId, type, oddsMarket, parameter}]}
  → Validation 1 pick/match (STRICT_RULE_VIOLATION si doublon)
  → getAccessToken() OAuth2 client_credentials (cache Redis 1h)
  → GET https://cpservm.com/gateway/marketing/datafeed/directories/api/v1/sharecoupon?ref=192&sportEventId=...&type=...&oddsMarket=...&kind=3&parameter=...&lng=en
  → "https://megapari.com/en?coupon-code=9V2XD" → extraction couponCode=9V2XD
  → Retour {success:true, couponCode:"9V2XD", deepLink:"https://megapari.com/en?coupon-code=9V2XD", message:"Coupon généré avec succès"}
  → Flutter CouponCodeCard: code en gros + Copier + Ouvrir MegaPari
```

## API Request (Flutter)
```dart
final res = await http.post(
  Uri.parse('$apiBase/megapari/coupon/generate'),
  headers: {'Content-Type':'application/json', 'X-Country-Code':'TG'},
  body: jsonEncode({
    'picks': [
      {
        'event_id': '763041519',
        'market_id': '763041519_9_2.5',
        'selection_id': 'over',
        'market_type': 'OVER_UNDER',
        'sportEventId': 763041519,
        'b2b_type': 9,
        'b2b_oddsMarket': 1.95,
        'b2b_parameter': 2.5,
        'b2b_kind': 3,
      }
    ]
  }),
);
final couponCode = jsonDecode(res.body)['couponCode']; // "X9A1B"
```

## Réponse B2B réelle testée
```
GET /sharecoupon?ref=192&sportEventId=762967433&type=7&oddsMarket=1.952&kind=3&parameter=-1.0&lng=en
→ "https://megapari.com/en?coupon-code=9V2XD"
```

## UI Flutter
- `widgets/coupon_code_card.dart` → `CouponCodeCard(couponCode, deepLink)`
  - Code en 32pt + lettre espacée + bouton Copier à côté
  - Boutons: [Copier le code] [Ouvrir MegaPari]
  - SnackBar confirmation
- `features/coupons/megapari_coupon_screen.dart` → écran complet avec flow B2B

## Gestion combiné (multi-picks)
- B2B sharecoupon ne prend qu'1 marché → service boucle sur chaque pick et combine
- Pour vrai combiné multi-sélections, demander au manager l'endpoint accumulator (non documenté dans openapi.yaml) — fallback: 1er couponCode + deepLink combiné

## Env
```
MEGAPARI_REF=192
MEGAPARI_CLIENT_ID=partners-c2b75a07c454fcd96f0453a0f79e1ead
MEGAPARI_CLIENT_SECRET=***
MEGAPARI_AFFILIATE_TAG=s_23283m_355c_
BOOKMAKER_API_BASE=https://cpservm.com/gateway/marketing
```
