# Client Flutter — Web + iOS + Android

## Démarrage

```bash
cd apps/client-flutter
flutter pub get
flutter run -d chrome   # Web
flutter run -d ios      # iOS
flutter run -d android  # Android

# Build web prod (WASM)
flutter build web --wasm
```

Config API:
```bash
flutter run -d chrome --dart-define=API_BASE=http://localhost:3000/api/v1
```

## Structure

- `lib/main.dart` — tabs Home/Coupons/History/Settings
- `lib/features/home/home_screen.dart` — picks du jour (pré-calcul Redis), filtres Réel/Virtuel/Mix, cartes proba sans cotes
- `lib/features/coupons/coupon_screen.dart` — choix mode + format SINGLE/COMBINE/SYSTEM(k,n), draft + placement avec revalidation
- `lib/features/picks/pick_detail_screen.dart` — proba, confiance, facteurs, warnings
- `lib/features/history/history_screen.dart` — perf modèles, backtests, marchés désactivés
- `lib/features/settings/settings_screen.dart` — langue FR/EN, pays (Country Gate), profil risque, limite RG
- `lib/widgets/responsible_gambling_banner.dart` — obligatoire partout
- `lib/widgets/probability_card.dart` — affiche p_lower + confiance, jamais de cotes

## i18n

Ajouter clés dans `lib/core/l10n/app_fr.arb` et `app_en.arb`, puis `flutter gen-l10n`.

## Thème

`lib/core/theme/app_theme.dart` — seed color #0E4DA4, Material 3.
