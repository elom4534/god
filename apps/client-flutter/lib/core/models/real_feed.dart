/// Modèles des données 100 % réelles renvoyées par l'API NestJS
/// (`/api/v1/coupons/*`). Aucune valeur fictive : chaque champ vient du
/// moteur de composition branché sur MegaPari en direct.
library real_feed;

class RealPick {
  RealPick({
    required this.eventId,
    required this.home,
    required this.away,
    required this.league,
    required this.sportName,
    required this.marketType,
    required this.selectionId,
    required this.selectionName,
    required this.line,
    required this.odds,
    required this.marginPercent,
    required this.probabilityPercent,
    required this.day,
    required this.startTime,
    required this.isEngineChoice,
  });

  final String eventId;
  final String home;
  final String away;
  final String league;
  final String sportName;
  final String marketType;
  final String selectionId;
  final String selectionName;
  final double? line;
  final double odds;
  final double? marginPercent;
  final int probabilityPercent;
  final String day; // TODAY | TOMORROW
  final DateTime? startTime;

  /// Sélection retenue par le moteur de composition.
  final bool isEngineChoice;

  /// Probabilité implicite brute issue de la cote réelle.
  double get impliedProb => odds > 1 ? 1 / odds : 0;

  /// Écart de valeur réel : cote × probabilité du modèle − 1.
  double get valueEdge => odds * (probabilityPercent / 100) - 1;

  bool get isTomorrow => day == 'TOMORROW';

  /// Match en cours selon l'heure de coup d'envoi réelle.
  bool get isLiveNow {
    final start = startTime;
    if (start == null) return false;
    final now = DateTime.now().toUtc();
    return now.isAfter(start) && now.difference(start).inMinutes < 150;
  }

  String get marketLabel {
    switch (marketType) {
      case '1X2':
        return '1X2';
      case 'DOUBLE_CHANCE':
        return 'Double Chance';
      case 'OVER_UNDER':
        return line != null ? 'Over/Under $line' : 'Over/Under';
      case 'BTTS':
        return 'BTTS';
      case 'HANDICAP':
        return line != null ? 'Handicap $line' : 'Handicap';
      case 'CORNERS_OU':
        return line != null ? 'Corners $line' : 'Corners';
      default:
        return marketType;
    }
  }

  String get matchup => home.isNotEmpty || away.isNotEmpty ? '$home – $away' : '#$eventId';

  factory RealPick.fromApi(Map<String, dynamic> m, {bool isEngineChoice = true}) {
    return RealPick(
      eventId: '${m['event_id'] ?? ''}',
      home: '${m['home'] ?? ''}',
      away: '${m['away'] ?? ''}',
      league: '${m['league'] ?? ''}',
      sportName: '${m['sport_name'] ?? m['sport'] ?? ''}',
      marketType: '${m['market_type'] ?? ''}',
      selectionId: '${m['selection_id'] ?? ''}',
      selectionName: '${m['selection_name'] ?? ''}',
      line: m['line'] is num ? (m['line'] as num).toDouble() : double.tryParse('${m['line'] ?? ''}'),
      odds: (m['odds'] is num) ? (m['odds'] as num).toDouble() : double.tryParse('${m['odds']}') ?? 0,
      marginPercent: m['margin_percent'] is num ? (m['margin_percent'] as num).toDouble() : null,
      probabilityPercent: (m['probability_percent'] is num)
          ? (m['probability_percent'] as num).round()
          : (m['prob'] is num ? ((m['prob'] as num) * 100).round() : 0),
      day: '${m['day'] ?? ''}',
      startTime: DateTime.tryParse('${m['start_time'] ?? ''}'),
      isEngineChoice: isEngineChoice,
    );
  }
}

class WindowStats {
  WindowStats({
    required this.todayEvents,
    required this.tomorrowEvents,
    required this.maxMatches,
    required this.picksToday,
    required this.picksTomorrow,
    required this.eventsFetched,
    required this.validatedMarkets,
    required this.minProbability,
    required this.minLeadMinutes,
    required this.timezone,
    required this.asOf,
  });

  final int todayEvents;
  final int tomorrowEvents;
  final int maxMatches;
  final int picksToday;
  final int picksTomorrow;
  final int eventsFetched;
  final int validatedMarkets;
  final int minProbability;
  final int minLeadMinutes;
  final String timezone;
  final String? asOf;

  factory WindowStats.fromApi(Map<String, dynamic> m) {
    final picks = (m['picks'] is Map) ? m['picks'] as Map : const {};
    return WindowStats(
      todayEvents: (m['today_events'] as num?)?.toInt() ?? 0,
      tomorrowEvents: (m['tomorrow_events'] as num?)?.toInt() ?? 0,
      maxMatches: (m['max_matches'] as num?)?.toInt() ?? 0,
      picksToday: (picks['TODAY'] as num?)?.toInt() ?? 0,
      picksTomorrow: (picks['TOMORROW'] as num?)?.toInt() ?? 0,
      eventsFetched: (m['events_fetched'] as num?)?.toInt() ?? 0,
      validatedMarkets: (m['validated_markets'] as num?)?.toInt() ?? 0,
      minProbability: (m['min_probability'] as num?)?.toInt() ?? 70,
      minLeadMinutes: (m['min_lead_minutes'] as num?)?.toInt() ?? 30,
      timezone: '${m['timezone'] ?? 'Africa/Lome'}',
      asOf: m['as_of']?.toString(),
    );
  }
}

class SportInfo {
  SportInfo({required this.id, required this.name, required this.events, required this.picks, required this.available});
  final int id;
  final String name;
  final int events;
  final int picks;
  final bool available;

  factory SportInfo.fromApi(Map<String, dynamic> m) => SportInfo(
        id: (m['id'] as num?)?.toInt() ?? 0,
        name: '${m['name'] ?? ''}',
        events: (m['events'] as num?)?.toInt() ?? 0,
        picks: (m['picks'] as num?)?.toInt() ?? 0,
        available: m['available'] == true,
      );
}

/// Instantané complet du flux temps réel — 100 % issu de l'API.
class FeedSnapshot {
  FeedSnapshot({
    required this.picks,
    required this.window,
    required this.sports,
    required this.fetchedAt,
    required this.scopeLabel,
    this.totalOdds,
    this.targetTotalOdds,
    this.gapPercent,
    this.exact = false,
    this.dayScope,
    this.oddsAsOf,
    this.errorCode,
  });

  final List<RealPick> picks;
  final WindowStats? window;
  final List<SportInfo> sports;
  final DateTime fetchedAt;
  final String scopeLabel;

  /// Cote totale réelle de la composition (donnée du moteur).
  final double? totalOdds;
  final double? targetTotalOdds;
  final double? gapPercent;
  final bool exact;
  final String? dayScope;
  final String? oddsAsOf;

  /// Code d'erreur moteur court si la composition a échoué.
  final String? errorCode;

  bool get hasData => picks.isNotEmpty;

  /// Opportunités triées par confiance décroissante (données réelles).
  List<RealPick> get topByConfidence {
    final sorted = [...picks]..sort((a, b) => b.probabilityPercent.compareTo(a.probabilityPercent));
    return sorted;
  }

  /// Value bets réels (cote × proba du modèle > 1).
  List<RealPick> get valueBets => picks.where((p) => p.valueEdge > 0).toList()
    ..sort((a, b) => b.valueEdge.compareTo(a.valueEdge));

  /// Ligues réellement présentes dans le flux.
  Set<String> get leagues => picks.map((p) => p.league).where((l) => l.isNotEmpty).toSet();
}
