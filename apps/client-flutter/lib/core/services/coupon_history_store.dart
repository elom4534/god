import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Historique local des coupons réellement générés (aucune donnée fictive :
/// chaque entrée correspond à une composition réelle du moteur).
class CouponRecord {
  CouponRecord({
    required this.createdAt,
    required this.numMatches,
    required this.totalOdds,
    required this.targetOdds,
    required this.codes,
    required this.scopeLabel,
    required this.dayToday,
    required this.dayTomorrow,
  });

  final DateTime createdAt;
  final int numMatches;
  final double totalOdds;
  final double targetOdds;
  final List<String> codes;
  final String scopeLabel;
  final int dayToday;
  final int dayTomorrow;

  Map<String, dynamic> toJson() => {
        'at': createdAt.toIso8601String(),
        'n': numMatches,
        'total': totalOdds,
        'target': targetOdds,
        'codes': codes,
        'scope': scopeLabel,
        'd1': dayToday,
        'd2': dayTomorrow,
      };

  factory CouponRecord.fromJson(Map<String, dynamic> m) => CouponRecord(
        createdAt: DateTime.tryParse('${m['at']}') ?? DateTime.now(),
        numMatches: (m['n'] as num?)?.toInt() ?? 0,
        totalOdds: (m['total'] as num?)?.toDouble() ?? 0,
        targetOdds: (m['target'] as num?)?.toDouble() ?? 0,
        codes: (m['codes'] is List) ? (m['codes'] as List).map((e) => '$e').toList() : const [],
        scopeLabel: '${m['scope'] ?? ''}',
        dayToday: (m['d1'] as num?)?.toInt() ?? 0,
        dayTomorrow: (m['d2'] as num?)?.toInt() ?? 0,
      );
}

class CouponHistoryStore {
  static const _key = 'pred_coupon_history';

  static Future<List<CouponRecord>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key) ?? const [];
      return raw
          .map((e) {
            try {
              return CouponRecord.fromJson(jsonDecode(e) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<CouponRecord>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> add(CouponRecord record) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key) ?? const [];
      raw.insert(0, jsonEncode(record.toJson()));
      await prefs.setStringList(_key, raw.take(50).toList());
    } catch (_) {}
  }
}
