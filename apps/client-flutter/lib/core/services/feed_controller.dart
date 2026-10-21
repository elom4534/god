import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/real_feed.dart';
import 'feed_stream.dart';

/// Contrôleur partagé du flux temps réel — un seul polling pour toute
/// l'application, chaque widget se rafraîchit individuellement via
/// `ValueListenableBuilder` (aucun rechargement de page).
class FeedController extends ValueNotifier<FeedSnapshot?> {
  FeedController({this.period = const Duration(seconds: 30)}) : super(null);

  final Duration period;
  Timer? _timer;
  bool virtual = false;
  bool loading = true;

  /// Dernière sélection ouverte (panneau d'analyse du Command Center).
  final ValueNotifier<RealPick?> selected = ValueNotifier(null);

  /// Journal des alertes IA, 100 % dérivé des données réelles du flux.
  final ValueNotifier<List<FeedAlert>> alerts = ValueNotifier(const []);

  void start() {
    refresh();
    _timer?.cancel();
    _timer = Timer.periodic(period, (_) => refresh());
  }

  void disposeAll() {
    _timer?.cancel();
    selected.dispose();
    alerts.dispose();
    dispose();
  }

  /// Bascule Football Réel ⚡ Football Virtuel (rafraîchit le flux).
  void setVirtual(bool v) {
    if (v == virtual) return;
    virtual = v;
    loading = true;
    notifyListeners();
    refresh();
  }

  Future<void> refresh() async {
    try {
      // Phase 1 : fenêtre + sports → compteurs visibles immédiatement.
      // `loading` reste vrai tant que la composition n'est pas arrivée.
      final quick = await FeedStream.fetchQuick(virtual: virtual);
      value = quick;
      notifyListeners();

      // Phase 2 : composition complète (cotes relues en direct).
      final snap = await FeedStream.fetchFull(virtual: virtual, quick: quick);
      value = snap;
      loading = false;
      _pushAlerts(snap);
      notifyListeners();
    } catch (_) {
      loading = false;
      notifyListeners();
    }
  }

  void _pushAlerts(FeedSnapshot snap) {
    final out = <FeedAlert>[];
    for (final p in snap.valueBets.take(3)) {
      out.add(FeedAlert(
        kind: FeedAlertKind.valueBet,
        title: 'Value bet détecté',
        detail: '${p.matchup} · ${p.marketLabel} ${p.selectionName}',
        metric: '+${(p.valueEdge * 100).toStringAsFixed(1)} %',
        at: snap.fetchedAt,
      ));
    }
    for (final p in snap.topByConfidence.where((p) => p.probabilityPercent >= 80).take(3)) {
      out.add(FeedAlert(
        kind: FeedAlertKind.highConfidence,
        title: 'Haute confiance IA',
        detail: '${p.matchup} · ${p.marketLabel} ${p.selectionName}',
        metric: '${p.probabilityPercent} %',
        at: snap.fetchedAt,
      ));
    }
    if (snap.window != null) {
      out.add(FeedAlert(
        kind: FeedAlertKind.feed,
        title: 'Flux mis à jour',
        detail: '${snap.window!.validatedMarkets} marchés validés · ${snap.window!.eventsFetched} événements',
        metric: snap.window!.timezone,
        at: snap.fetchedAt,
      ));
    }
    alerts.value = [...out, ...alerts.value].take(24).toList();
  }
}

enum FeedAlertKind { valueBet, highConfidence, feed, risk }

class FeedAlert {
  const FeedAlert({
    required this.kind,
    required this.title,
    required this.detail,
    required this.metric,
    required this.at,
  });

  final FeedAlertKind kind;
  final String title;
  final String detail;
  final String metric;
  final DateTime at;
}
