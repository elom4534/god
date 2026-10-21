import 'dart:async';

import '../models/real_feed.dart';
import 'api_service.dart';

/// Flux temps réel : composition réelle relue périodiquement chez MegaPari.
///
/// Chargement en deux phases pour un rendu immédiat :
///   1. `fetchQuick`     → fenêtre du jour + sports (rapide),
///   2. `fetchFull`      → composition complète (cotes relues en direct).
/// Aucune valeur simulée : chaque émission vient des contrôleurs existants.
class FeedStream {
  FeedStream({this.period = const Duration(seconds: 30)});

  final Duration period;

  Stream<FeedSnapshot> watch({bool virtual = false}) async* {
    while (true) {
      yield await fetchFull(virtual: virtual);
      await Future<void>.delayed(period);
    }
  }

  /// Phase 1 — fenêtre + sports (aide à afficher les compteurs en < 2 s).
  static Future<FeedSnapshot> fetchQuick({int? sportId, bool virtual = false}) async {
    final scope = virtual ? 'Football Virtuel' : 'Football Réel';
    final sid = virtual ? (sportId ?? 40) : sportId;

    WindowStats? window;
    List<SportInfo> sports = const [];
    await Future.wait<void>([
      () async {
        try {
          window = await ApiService.window(sportId: sid);
        } catch (_) {}
      }(),
      () async {
        try {
          sports = await ApiService.sports();
        } catch (_) {}
      }(),
    ]);

    return FeedSnapshot(
      picks: const [],
      window: window,
      sports: sports,
      fetchedAt: DateTime.now(),
      scopeLabel: scope,
    );
  }

  /// Phase 2 — composition réelle complète (sélections, cotes, probabilités).
  static Future<FeedSnapshot> fetchFull({int? sportId, bool virtual = false, FeedSnapshot? quick}) async {
    final scope = virtual ? 'Football Virtuel' : 'Football Réel';
    final sid = virtual ? (sportId ?? 40) : sportId;

    WindowStats? window = quick?.window;
    List<SportInfo> sports = quick?.sports ?? const [];
    String? errorCode;

    if (window == null || sports.isEmpty) {
      await Future.wait<void>([
        () async {
          try {
            window ??= await ApiService.window(sportId: sid);
          } catch (_) {}
        }(),
        () async {
          try {
            if (sports.isEmpty) sports = await ApiService.sports();
          } catch (_) {}
        }(),
      ]);
    }

    List<RealPick> picks = const [];
    double? totalOdds;
    double? targetTotalOdds;
    double? gapPercent;
    bool exact = false;
    String? dayScope;
    String? oddsAsOf;

    // Échelle d'essais pilotée par les capacités réelles du moteur.
    final attempts = <({int n, double t})>[
      (n: 10, t: 16.0),
      (n: 8, t: 8.0),
      (n: 6, t: 3.0),
      (n: 5, t: 2.4),
      (n: 3, t: 1.8),
      (n: 2, t: 1.4),
    ];

    for (final a in attempts) {
      if (window != null && a.n > window!.maxMatches) continue;
      try {
        final d = await ApiService.generateCombined(
          numMatches: a.n,
          targetTotalOdds: a.t,
          sportId: sid,
        );
        final raw = (d['picks'] is List) ? d['picks'] as List : const [];
        picks = raw.whereType<Map>().map((e) => RealPick.fromApi(Map<String, dynamic>.from(e))).toList();
        totalOdds = (d['totalOdds'] as num?)?.toDouble();
        targetTotalOdds = (d['targetTotalOdds'] as num?)?.toDouble();
        gapPercent = (d['gapPercent'] as num?)?.toDouble();
        exact = d['exact'] == true;
        dayScope = d['day_scope']?.toString();
        oddsAsOf = (d['odds_as_of'] ?? d['asOf'])?.toString();
        errorCode = null;
        break;
      } on ApiException catch (e) {
        errorCode = e.code;
      }
    }

    return FeedSnapshot(
      picks: picks,
      window: window,
      sports: sports,
      fetchedAt: DateTime.now(),
      scopeLabel: scope,
      totalOdds: totalOdds,
      targetTotalOdds: targetTotalOdds,
      gapPercent: gapPercent,
      exact: exact,
      dayScope: dayScope,
      oddsAsOf: oddsAsOf,
      errorCode: picks.isEmpty ? (errorCode ?? 'EMPTY') : null,
    );
  }
}
