/// Modèles Football Virtuel — 100 % flux Partner API MegaPari
/// (`/api/v1/virtual/*`). Aucune valeur simulée : chaque champ vient des
/// rounds réellement joués (FIFA_VIRTUAL / SEGA_VIRTUAL).
library virtual_feed;

class VirtualRound {
  VirtualRound({
    required this.roundId,
    required this.provider,
    required this.league,
    required this.homeTeam,
    required this.awayTeam,
    required this.scheduledStart,
    required this.status,
    this.startedAt,
    this.endedAt,
    this.homeScore,
    this.awayScore,
    this.timeSec,
    this.periodName,
    this.matchFormat,
  });

  final String roundId;
  final String provider; // FIFA_VIRTUAL | SEGA_VIRTUAL
  final String league;
  final String homeTeam;
  final String awayTeam;
  final DateTime? scheduledStart;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final String status; // SCHEDULED | LIVE | FINISHED | CANCELLED
  final int? homeScore;
  final int? awayScore;
  final int? timeSec;
  final String? periodName;
  final String? matchFormat;

  bool get isLive => status == 'LIVE';
  bool get isScheduled => status == 'SCHEDULED';

  /// Minute de jeu réelle (timeSec du flux).
  int? get minute => timeSec == null ? null : (timeSec! / 60).floor();

  String get matchup => '$homeTeam – $awayTeam';

  factory VirtualRound.fromApi(Map<String, dynamic> m) => VirtualRound(
        roundId: '${m['round_id'] ?? ''}',
        provider: '${m['provider'] ?? ''}',
        league: '${m['league'] ?? ''}',
        homeTeam: '${m['home_team'] ?? ''}',
        awayTeam: '${m['away_team'] ?? ''}',
        scheduledStart: DateTime.tryParse('${m['scheduled_start'] ?? ''}'),
        startedAt: DateTime.tryParse('${m['started_at'] ?? ''}'),
        endedAt: DateTime.tryParse('${m['ended_at'] ?? ''}'),
        status: '${m['status'] ?? 'SCHEDULED'}',
        homeScore: (m['home_score'] as num?)?.toInt(),
        awayScore: (m['away_score'] as num?)?.toInt(),
        timeSec: (m['time_sec'] as num?)?.toInt(),
        periodName: m['period_name']?.toString(),
        matchFormat: m['match_format']?.toString(),
      );
}

class VirtualOdd {
  VirtualOdd({
    required this.market,
    required this.selection,
    required this.odds,
    this.line,
    this.snapshotAt,
  });

  final String market;
  final String selection;
  final double odds;
  final double? line;
  final DateTime? snapshotAt;

  factory VirtualOdd.fromApi(Map<String, dynamic> m) => VirtualOdd(
        market: '${m['market'] ?? ''}',
        selection: '${m['selection'] ?? ''}',
        odds: (m['odds'] is num) ? (m['odds'] as num).toDouble() : 0,
        line: m['line'] is num ? (m['line'] as num).toDouble() : null,
        snapshotAt: DateTime.tryParse('${m['snapshot_at'] ?? ''}'),
      );
}

class VirtualResult {
  VirtualResult({
    required this.roundId,
    required this.provider,
    required this.league,
    required this.homeTeam,
    required this.awayTeam,
    required this.homeScore,
    required this.awayScore,
    required this.btts,
    required this.over25,
    required this.closedAt,
    this.halfTime,
  });

  final String roundId;
  final String provider;
  final String league;
  final String homeTeam;
  final String awayTeam;
  final int homeScore;
  final int awayScore;
  final bool btts;
  final bool over25;
  final DateTime? closedAt;
  final String? halfTime;

  factory VirtualResult.fromApi(Map<String, dynamic> m) => VirtualResult(
        roundId: '${m['round_id'] ?? ''}',
        provider: '${m['provider'] ?? ''}',
        league: '${m['league'] ?? ''}',
        homeTeam: '${m['home_team'] ?? ''}',
        awayTeam: '${m['away_team'] ?? ''}',
        homeScore: (m['home_score'] as num?)?.toInt() ?? 0,
        awayScore: (m['away_score'] as num?)?.toInt() ?? 0,
        btts: m['btts'] == true,
        over25: m['over_2_5'] == true,
        closedAt: DateTime.tryParse('${m['closed_at'] ?? ''}'),
        halfTime: m['half_time']?.toString(),
      );
}

class VirtualPrediction {
  VirtualPrediction({
    required this.round,
    required this.sampleSize,
    required this.captureHours,
    required this.calibrationInProgress,
    this.probabilities,
    this.valueBets = const [],
    this.latestOdds = const [],
  });

  final VirtualRound round;
  final int sampleSize;
  final double captureHours;
  final bool calibrationInProgress;
  final Map<String, dynamic>? probabilities;
  final List<Map<String, dynamic>> valueBets;
  final List<VirtualOdd> latestOdds;

  double? get pHome => (probabilities?['home'] as num?)?.toDouble();
  double? get pDraw => (probabilities?['draw'] as num?)?.toDouble();
  double? get pAway => (probabilities?['away'] as num?)?.toDouble();
  double? get pBttsYes => (probabilities?['btts_yes'] as num?)?.toDouble();
  double? get pOver25 => (probabilities?['over_2_5'] as num?)?.toDouble();

  /// Confiance dominante (0..1) pour l'anneau lumineux.
  double get dominantConfidence {
    final vals = [pHome ?? 0, pDraw ?? 0, pAway ?? 0];
    return vals.reduce((a, b) => a > b ? a : b);
  }

  factory VirtualPrediction.fromApi(Map<String, dynamic> m) {
    final oddsRaw = (m['latest_odds'] is List) ? m['latest_odds'] as List : const [];
    return VirtualPrediction(
      round: VirtualRound.fromApi(Map<String, dynamic>.from((m['round'] as Map?) ?? const {})),
      sampleSize: (m['sample_size'] as num?)?.toInt() ?? 0,
      captureHours: (m['capture_hours'] as num?)?.toDouble() ?? 0,
      calibrationInProgress: m['calibration_in_progress'] == true,
      probabilities: m['probabilities'] is Map
          ? Map<String, dynamic>.from(m['probabilities'] as Map)
          : null,
      valueBets: ((m['value_bets'] is List) ? m['value_bets'] as List : const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
      latestOdds: oddsRaw
          .whereType<Map>()
          .map((e) => VirtualOdd.fromApi(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class VirtualReliability {
  VirtualReliability({required this.message, required this.providers});

  final String message;
  final Map<String, Map<String, dynamic>> providers;

  factory VirtualReliability.fromApi(Map<String, dynamic> m) => VirtualReliability(
        message: '${m['message'] ?? ''}',
        providers: ((m['providers'] as Map?) ?? const {})
            .map((k, v) => MapEntry('$k', Map<String, dynamic>.from(v as Map))),
      );
}
