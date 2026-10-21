import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'core/theme/app_theme.dart';
import 'widgets/ui_kit.dart';
import 'features/home/home_screen.dart';
import 'features/coupons/custom_coupon_screen.dart';
import 'features/history/history_screen.dart';
import 'features/settings/settings_screen.dart';

void main() {
  runApp(const PredApp());
}

class PredApp extends StatefulWidget {
  const PredApp({super.key});
  @override
  State<PredApp> createState() => _PredAppState();
}

class _PredAppState extends State<PredApp> {
  Locale _locale = const Locale('fr');
  // Onglet initial : ?tab=0..3 (permet le lien direct vers un écran)
  int _nav = _tabFromUrl();

  static int _tabFromUrl() {
    try {
      final v = Uri.base.queryParameters['tab'];
      final n = int.tryParse(v ?? '');
      if (n != null && n >= 0 && n <= 3) return n;
    } catch (_) {}
    return 0;
  }

  void setLocale(Locale l) => setState(() => _locale = l);

  @override
  Widget build(BuildContext context) {
    final screens = [
      HomeScreen(onLocaleChange: setLocale),
      const CustomCouponScreen(),
      const HistoryScreen(),
      SettingsScreen(currentLocale: _locale, onLocaleChange: setLocale),
    ];
    return MaterialApp(
      title: 'Pred — MegaPari',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      locale: _locale,
      supportedLocales: const [Locale('fr'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        // IndexedStack : conserve l'état du formulaire quand on change d'onglet
        body: Responsive(
          child: IndexedStack(index: _nav, children: screens),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _nav,
          onDestinationSelected: (i) => setState(() => _nav = i),
          destinations: [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: _locale.languageCode=='fr' ? 'Accueil' : 'Home'),
            NavigationDestination(icon: Icon(Icons.confirmation_number_outlined), selectedIcon: Icon(Icons.confirmation_number), label: 'Coupons'),
            NavigationDestination(icon: Icon(Icons.history_outlined), selectedIcon: Icon(Icons.history), label: _locale.languageCode=='fr' ? 'Historique' : 'History'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: _locale.languageCode=='fr' ? 'Réglages' : 'Settings'),
          ],
        ),
      ),
    );
  }
}
