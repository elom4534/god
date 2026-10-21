import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/real_feed.dart';

/// Client unique des API réelles du moteur (NestJS).
///
/// Endpoints existants utilisés tels quels :
///   GET  /coupons/sports
///   GET  /coupons/window
///   GET  /coupons/value-picks/availability
///   POST /coupons/generate-combined
///   POST /coupons/pick-code
///   POST /scan                    (relance d'analyse réelle)
class ApiService {
  static Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${AppConfig.effectiveApiBase}$path').replace(queryParameters: query);

  static Map<String, String> get _headers => const {'Accept': 'application/json'};

  static Future<Map<String, dynamic>> _get(String path, {Map<String, String>? query, Duration timeout = const Duration(seconds: 40)}) async {
    final res = await http.get(_uri(path, query), headers: _headers).timeout(timeout);
    return _decodeOrThrow(res);
  }

  static Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, {Duration timeout = const Duration(seconds: 60)}) async {
    final res = await http
        .post(
          _uri(path),
          headers: {'Content-Type': 'application/json', ..._headers},
          body: jsonEncode(body),
        )
        .timeout(timeout);
    return _decodeOrThrow(res);
  }

  static Map<String, dynamic> _decodeOrThrow(http.Response res) {
    dynamic decoded;
    try {
      decoded = jsonDecode(res.body);
    } catch (_) {
      decoded = null;
    }
    if (res.statusCode >= 200 && res.statusCode < 300 && decoded is Map<String, dynamic>) {
      return decoded;
    }
    final details = (decoded is Map && decoded['details'] is Map)
        ? Map<String, dynamic>.from(decoded['details'] as Map)
        : const <String, dynamic>{};
    final rawRetry = details['retry_after_seconds'] ?? (decoded is Map ? decoded['retry_after_seconds'] : null);
    final retry = int.tryParse('$rawRetry');
    throw ApiException(_extractCode(decoded), _extractMessage(decoded), details: details, retryAfter: retry);
  }

  static String _extractCode(dynamic decoded) {
    if (decoded is Map) {
      final rc = decoded['reason_code'] ?? decoded['error'];
      if (rc is String && rc.isNotEmpty) return rc;
    }
    return 'ERROR';
  }

  static String _extractMessage(dynamic decoded) {
    if (decoded is Map) {
      final msg = decoded['message'];
      if (msg is String && msg.isNotEmpty) return msg;
      if (msg is List && msg.isNotEmpty) return msg.first.toString();
    }
    return 'Une erreur est survenue.';
  }

  // ------------------------------------------------------------ endpoints --

  static Future<List<SportInfo>> sports({String language = 'fr'}) async {
    final d = await _get('/coupons/sports', query: {'language': language});
    final list = (d['sports'] is List) ? d['sports'] as List : const [];
    return list.whereType<Map>().map((e) => SportInfo.fromApi(Map<String, dynamic>.from(e))).toList();
  }

  static Future<WindowStats> window({int? sportId}) async {
    final d = await _get('/coupons/window', query: {if (sportId != null) 'sport_id': '$sportId'});
    return WindowStats.fromApi(d);
  }

  static Future<({int events, int picks, double marginThreshold})> availability({int? sportId}) async {
    final d = await _get('/coupons/value-picks/availability', query: {if (sportId != null) 'sport_id': '$sportId'});
    return (
      events: (d['events'] as num?)?.toInt() ?? 0,
      picks: (d['picks'] as num?)?.toInt() ?? 0,
      marginThreshold: (d['margin_threshold'] as num?)?.toDouble() ?? 5,
    );
  }

  /// Composition réelle (appel moteur → cotes relues chez MegaPari).
  static Future<Map<String, dynamic>> generateCombined({
    required int numMatches,
    required double targetTotalOdds,
    int? sportId,
    String language = 'fr',
    bool includeIndividualCodes = false,
  }) {
    return _post('/coupons/generate-combined', {
      'num_matches': numMatches,
      'target_total_odds': targetTotalOdds,
      if (sportId != null) 'sport_id': sportId,
      'language': language,
      if (includeIndividualCodes) 'include_individual_codes': true,
    });
  }

  /// Code coupon MegaPari pour une sélection précise.
  static Future<Map<String, dynamic>> pickCode({
    required String eventId,
    required String selectionId,
    String language = 'fr',
  }) {
    return _post('/coupons/pick-code', {
      'event_id': eventId,
      'selection_id': selectionId,
      'language': language,
    }, timeout: const Duration(seconds: 50));
  }

  /// Relance l'analyse réelle (ETL) — remplissage du pool de sélections.
  static Future<void> scan() async {
    await _post('/scan', {});
  }

  /// Détail multi-marchés d'un match — toutes les sélections validées,
  /// relues en direct chez MegaPari (contrôleur `coupons/match-picks`).
  static Future<List<RealPick>> matchPicks({required String eventId}) async {
    final d = await _get('/coupons/match-picks', query: {'event_id': eventId});
    final raw = (d['picks'] is List) ? d['picks'] as List : const [];
    return raw
        .whereType<Map>()
        .map((e) => RealPick.fromApi(Map<String, dynamic>.from(e), isEngineChoice: false))
        .toList();
  }
}

/// Erreur API avec code court (jamais de détail technique affiché).
class ApiException implements Exception {
  ApiException(this.code, this.message, {this.details = const {}, this.retryAfter});
  final String code;
  final String message;
  final Map<String, dynamic> details;
  final int? retryAfter;

  double? get maxReachableOdds =>
      details['max_reachable_odds'] is num ? (details['max_reachable_odds'] as num).toDouble() : null;
  int? get suggestedMatches =>
      details['suggested_matches'] is num ? (details['suggested_matches'] as num).toInt() : null;
  int? get available =>
      details['available'] is num ? (details['available'] as num).toInt() : null;

  /// Message utilisateur court, orienté action.
  String get userMessage {
    switch (code) {
      case 'NO_VALUE_PICKS':
      case 'NO_PICK_ABOVE_MIN_PROBABILITY':
      case 'NO_MATCH_IN_WINDOW':
      case 'NO_MATCH_TODAY_OR_TOMORROW':
        return 'Aucune opportunité disponible pour le moment.';
      case 'NOT_ENOUGH_EVENTS':
        return 'Pas assez de matchs disponibles.';
      case 'INVALID_TARGET_ODDS':
        return 'La côte visée doit être supérieure ou égale à 1.01.';
      case 'INVALID_NUM_MATCHES':
        return 'Le nombre de matchs doit être supérieur ou égal à 1.';
      case 'TARGET_UNREACHABLE':
      case 'TARGET_UNREACHABLE_AT_MIN_PROBABILITY':
        return 'Cette côte est trop haute pour ce nombre de matchs.';
      case 'SELECTION_NOT_AVAILABLE':
        return 'Cette sélection n\'est plus disponible.';
      case 'B2B_RATE_LIMITED':
      case 'B2B_RATE_LIMITED_FEED':
        return 'Merci de patienter quelques secondes.';
      case 'NETWORK':
        return 'Connexion impossible. Réessaie.';
      default:
        return 'Une erreur est survenue. Réessaie dans un instant.';
    }
  }

  @override
  String toString() => userMessage;
}
