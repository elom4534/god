/// Configuration centralisée — API dynamique selon environnement
class AppConfig {
  // En production (Alwaysdata), l'API est sur api.votre-domaine.alwaysdata.net
  // En dev, localhost:3000
  // On utilise --dart-define=API_BASE pour écraser à la compilation
  static const apiBase = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://localhost:3000/api/v1',
  );

  // Fallback runtime: si compilé sans API_BASE mais qu'on détecte le host Alwaysdata
  static String get effectiveApiBase {
    // Sur Alwaysdata, le Flutter Web est sur www.*.alwaysdata.net, l'API sur api.*.alwaysdata.net
    // On ne peut pas détecter le host en Dart pur sans dart:html, donc on garde apiBase
    return apiBase;
  }

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

  static bool get isProduction => effectiveApiBase.contains('alwaysdata.net');
}
