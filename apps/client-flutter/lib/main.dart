import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/models/real_feed.dart';
import 'core/services/feed_controller.dart';
import 'core/theme/app_palette.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/live/live_screen.dart';
import 'features/markets/markets_screen.dart';
import 'features/match_detail/match_detail_panel.dart';
import 'features/performance/performance_screen.dart';
import 'features/radar/radar_screen.dart';
import 'features/virtual/virtual_live_board_screen.dart';
import 'shared/widgets/adaptive_app_shell.dart';
import 'shared/widgets/glass_container.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final theme = ThemeController();
  // Thème initial : ?theme=light|dark (lien direct), sinon préférence persistée.
  try {
    final q = Uri.base.queryParameters['theme'];
    if (q == 'light') theme.value = ThemeMode.light;
    if (q == 'dark') theme.value = ThemeMode.dark;
  } catch (_) {}
  theme.load();
  runApp(PredApp(theme: theme));
}

class PredApp extends StatefulWidget {
  const PredApp({super.key, required this.theme});
  final ThemeController theme;

  @override
  State<PredApp> createState() => _PredAppState();
}

class _PredAppState extends State<PredApp> {
  late final FeedController _feed = FeedController();
  Locale _locale = const Locale('fr');
  int _nav = _tabFromUrl();
  String _query = '';

  static int _tabFromUrl() {
    try {
      final v = Uri.base.queryParameters['tab'];
      final n = int.tryParse(v ?? '');
      if (n != null && n >= 0 && n <= 4) return n;
    } catch (_) {}
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _feed.start();
  }

  @override
  void dispose() {
    _feed.disposeAll();
    super.dispose();
  }

  void _setLocale(Locale l) => setState(() => _locale = l);

  List<ShellDestination> _destinations() => [
        ShellDestination(
          icon: Icons.radar_outlined,
          activeIcon: Icons.radar,
          label: _locale.languageCode == 'fr' ? 'Radar IA' : 'AI Radar',
        ),
        ShellDestination(
          icon: Icons.sports_soccer_outlined,
          activeIcon: Icons.sports_soccer,
          label: _locale.languageCode == 'fr' ? 'Live' : 'Live',
        ),
        ShellDestination(
          icon: Icons.sports_esports_outlined,
          activeIcon: Icons.sports_esports,
          label: _locale.languageCode == 'fr' ? 'Virtuel' : 'Virtual',
        ),
        ShellDestination(
          icon: Icons.confirmation_number_outlined,
          activeIcon: Icons.confirmation_number,
          label: _locale.languageCode == 'fr' ? 'Marchés' : 'Markets',
        ),
        ShellDestination(
          icon: Icons.insights_outlined,
          activeIcon: Icons.insights,
          label: _locale.languageCode == 'fr' ? 'Perf.' : 'Perf.',
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final screens = [
      RadarScreen(feed: _feed, query: _query, locale: _locale, onLocaleChange: _setLocale),
      LiveScreen(feed: _feed, query: _query),
      VirtualLiveBoardScreen(query: _query),
      MarketsScreen(feed: _feed),
      PerformanceScreen(feed: _feed),
    ];

    return ThemeScope(
      controller: widget.theme,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: widget.theme,
        builder: (context, mode, _) {
          return MaterialApp(
            title: 'Pred — MegaPari',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: mode,
            locale: _locale,
            supportedLocales: const [Locale('fr'), Locale('en')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Scaffold(
              backgroundColor: mode == ThemeMode.light ? AppTheme.crystalBg : AppTheme.obsidianBg,
              body: AdaptiveAppShell(
                destinations: _destinations(),
                index: _nav,
                onIndex: (i) => setState(() => _nav = i),
                searchHint: _locale.languageCode == 'fr'
                    ? 'Rechercher une ligue, une équipe…'
                    : 'Search a league, a team…',
                onSearchChanged: (q) => setState(() => _query = q),
                panel: _AnalysisPanel(feed: _feed),
                child: SafeArea(
                  bottom: false,
                  child: IndexedStack(index: _nav, children: screens),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Colonne droite du Command Center : analyse du match sélectionné + alertes IA.
class _AnalysisPanel extends StatelessWidget {
  const _AnalysisPanel({required this.feed});
  final FeedController feed;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RealPick?>(
      valueListenable: feed.selected,
      builder: (context, pick, _) {
        return Column(
          children: [
            Expanded(
              flex: 3,
              child: pick == null
                  ? const _EmptyAnalysis()
                  : MatchDetailPanel(pick: pick, compact: true),
            ),
            const SizedBox(height: 12),
            Expanded(flex: 2, child: _AlertsFeed(feed: feed)),
          ],
        );
      },
    );
  }
}

class _EmptyAnalysis extends StatelessWidget {
  const _EmptyAnalysis();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GlassContainer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.touch_app_outlined, size: 34, color: p.cyan.withOpacity(0.7)),
          const SizedBox(height: 10),
          Text(
            'Sélectionne un match pour lancer\nl\'analyse IA complète',
            textAlign: TextAlign.center,
            style: AppFonts.label(size: 12.5, color: p.textSoft),
          ),
        ],
      ),
    );
  }
}

class _AlertsFeed extends StatelessWidget {
  const _AlertsFeed({required this.feed});
  final FeedController feed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GlassContainer(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bolt, size: 17, color: p.amber),
              const SizedBox(width: 8),
              Text('Alertes IA', style: AppFonts.title(size: 13, weight: FontWeight.w800, color: p.textStrong)),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ValueListenableBuilder<List<FeedAlert>>(
              valueListenable: feed.alerts,
              builder: (context, alerts, _) {
                if (alerts.isEmpty) {
                  return Center(
                    child: Text('En veille…', style: AppFonts.caption(size: 11, color: p.textSoft)),
                  );
                }
                return ListView.separated(
                  itemCount: alerts.length,
                  separatorBuilder: (_, __) => Divider(height: 14, color: p.glassBorder),
                  itemBuilder: (context, i) {
                    final a = alerts[i];
                    final color = switch (a.kind) {
                      FeedAlertKind.valueBet => p.emerald,
                      FeedAlertKind.highConfidence => p.cyan,
                      FeedAlertKind.risk => p.carmin,
                      FeedAlertKind.feed => p.violet,
                    };
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 3),
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(color: color.withOpacity(0.7), blurRadius: 6)],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.title,
                                  style: AppFonts.label(size: 11.5, weight: FontWeight.w700, color: p.textStrong)),
                              Text(a.detail,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppFonts.caption(size: 10, color: p.textSoft)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(a.metric,
                            style: AppFonts.num(size: 10.5, weight: FontWeight.w800, color: color)),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
