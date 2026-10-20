import 'package:flutter/foundation.dart' show kIsWeb;

/// Configuration centralisée — API dynamique selon environnement.
///
/// Priorité :
///  1. `--dart-define=API_BASE=...` (build explicite, CI)
///  2. Web servi par l'edge Alwaysdata → même origine que la page (`/api/v1`)
///  3. Fallback dev : http://localhost:3000/api/v1
class AppConfig {
  /// Base fournie à la compilation. Vide par défaut : on ne fige pas
  /// l'hôte dans le binaire, sinon un build « localhost » partirait en prod.
  static const apiBaseOverride = String.fromEnvironment('API_BASE', defaultValue: '');

  /// Base effective utilisée par tous les services HTTP.
  ///
  /// Sur le web, l'application est servie par le même domaine que l'API
  /// (edge FastAPI qui proxifie `/api/v1/*` vers NestJS). On utilise donc
  /// une URL relative à l'origine courante : aucun problème de CORS, et le
  /// build fonctionne aussi bien sur `god.alwaysdata.net` que sur un aperçu.
  static String get effectiveApiBase {
    if (apiBaseOverride.isNotEmpty) return _clean(apiBaseOverride);
    if (kIsWeb) {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty && origin != 'null') return '$origin/api/v1';
      return '/api/v1';
    }
    return 'http://localhost:3000/api/v1';
  }

  static String _clean(String v) =>
      v.endsWith('/') ? v.substring(0, v.length - 1) : v;

  static const appName = 'Pred — MegaPari';
  static const appVersion = '0.3.0';

  // DeepLink MegaPari (ref=192)
  static const megapariDeepLinkBase = 'https://megapari.com';
  static const megapariRef = 192;

  // Live Football API (pour debug Flutter si besoin)
  static const liveFootballBase = 'https://live-football-api.com';

  static const allowedLeagues = [
    'Premier League',
    'La Liga',
    'Serie A',
    'Bundesliga',
    'Ligue 1',
    'Eredivisie',
  ];

  static const responsibleGamblingUrl = 'https://www.begambleaware.org/';

  /// Aucune limite produit sur le nombre de matchs ni sur la cote :
  /// seule la disponibilité réelle des marchés contraint le résultat.
  static const minMatches = 1;
  static const minOdds = 1.01;

  static bool get isProduction => effectiveApiBase.contains('alwaysdata.net');
}
