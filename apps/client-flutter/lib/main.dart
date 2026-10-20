import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'core/theme/app_theme.dart';
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
  int _nav = 0;

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
      title: 'Pred — 1xBet / Méga Pari',
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
        body: IndexedStack(index: _nav, children: screens),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _nav,
          onDestinationSelected: (i) => setState(() => _nav = i),
          destinations: [
            NavigationDestination(icon: Icon(Icons.home_outlined), label: _locale.languageCode=='fr' ? 'Accueil' : 'Home'),
            NavigationDestination(icon: Icon(Icons.confirmation_number_outlined), label: _locale.languageCode=='fr' ? 'Coupons' : 'Coupons'),
            NavigationDestination(icon: Icon(Icons.history), label: _locale.languageCode=='fr' ? 'Historique' : 'History'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), label: _locale.languageCode=='fr' ? 'Réglages' : 'Settings'),
          ],
        ),
      ),
    );
  }
}
