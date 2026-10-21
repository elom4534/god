import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import '../../widgets/coupon_code_card.dart';
import '../../widgets/responsible_gambling_banner.dart';

/// Écran « Combiné sur mesure ».
///
/// L'utilisateur choisit librement :
///   • le nombre de matchs (aucune limite produit — seule la disponibilité réelle compte),
///   • la côte totale visée (aucune limite),
///   • la discipline parmi les sports réels du bookmaker (ou « Tous les sports »).
///
/// Le backend cherche ensuite dans TOUS les marchés validés de chaque match la
/// combinaison dont le produit des cotes est le plus proche de la cible.
///
/// API :
///   GET  {base}/coupons/sports                     → sports réels + disponibilité
///   GET  {base}/coupons/value-picks/availability   → compteurs (filtrable par sport)
///   POST {base}/coupons/generate-combined          → composition + coupons
///   POST {base}/coupons/pick-code                  → code d'une sélection
class CustomCouponScreen extends StatefulWidget {
  const CustomCouponScreen({super.key});

  @override
  State<CustomCouponScreen> createState() => _CustomCouponScreenState();
}

class _CustomCouponScreenState extends State<CustomCouponScreen> {
  final _formKey = GlobalKey<FormState>();
  final _numCtrl = TextEditingController(text: '3');
  final _oddsCtrl = TextEditingController(text: '2.5');
  final _numFocus = FocusNode();
  final _oddsFocus = FocusNode();

  bool _loading = false;

  /// Message de progression (ex. attente du créneau MegaPari 1 code/minute).
  String? _progressMessage;
  String? _error;
  String? _errorCode;
  Map<String, dynamic>? _result;

  /// Codes générés à la demande, par sélection (un coupon MegaPari = un marché).
  final Map<String, _PickCodeState> _pickCodes = {};
  bool _bulkRunning = false;

  /// Sports réels proposés par le bookmaker (`{id, name, events, picks, available}`).
  List<Map<String, dynamic>> _sports = const [];
  bool _loadingSports = false;
  int? _selectedSportId; // null = tous les sports

  /// Compteurs pour la discipline sélectionnée.
  int? _availableEvents;
  // Fenêtre « aujourd'hui / demain » (source : GET /coupons/window, cotes live).
  int? _todayEvents;
  int? _tomorrowEvents;
  /// Plafond imposé par la fenêtre « aujourd'hui + demain » (cotes live).
  int? _windowMaxMatches;
  int _maxMatches = defaultMaxMatches;
  int? _availablePicks;

  static const _matchPresets = <int>[2, 3, 5, 7, 10];

  /// Limite produit par défaut : 50 matchs par combiné. La valeur réelle est
  /// lue sur `GET /coupons/sports` (`max_matches`) et sert de repli hors ligne.
  static const int defaultMaxMatches = 50;
  static const _oddsPresets = <double>[2.0, 2.5, 5.0, 10.0, 25.0, 50.0];

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _numCtrl.dispose();
    _oddsCtrl.dispose();
    _numFocus.dispose();
    _oddsFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- réseau --

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${AppConfig.effectiveApiBase}$path').replace(queryParameters: query);

  Future<void> _loadAll() async {
    await Future.wait([_loadSports(), _loadAvailability(), _loadWindow()]);
  }

  /// Nombre de matchs réellement composables aujourd'hui / demain.
  /// Sert aussi de plafond au champ « Nombre de matchs ».
  Future<void> _loadWindow() async {
    try {
      final res = await http
          .get(
            _uri('/coupons/window',
                _selectedSportId != null ? {'sport_id': '$_selectedSportId'} : null),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 40));
      if (!mounted) return;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final d = jsonDecode(res.body);
        if (d is Map<String, dynamic>) {
          setState(() {
            _todayEvents = (d['today_events'] is num) ? (d['today_events'] as num).toInt() : null;
            _tomorrowEvents = (d['tomorrow_events'] is num) ? (d['tomorrow_events'] as num).toInt() : null;
            final max = (d['max_matches'] is num) ? (d['max_matches'] as num).toInt() : null;
            if (max != null && max > 0) {
              _windowMaxMatches = max;
              _maxMatches = math.min(_maxMatches, max);
            }
            if (max != null) _availableEvents = max;
          });
        }
      }
    } catch (_) {
      /* purement indicatif */
    }
  }

  Future<void> _loadSports() async {
    setState(() => _loadingSports = true);
    try {
      final res = await http
          .get(_uri('/coupons/sports'), headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        final list = (decoded is Map && decoded['sports'] is List) ? decoded['sports'] as List : const [];
        setState(() {
          _sports = list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
          final mm = decoded['max_matches'];
          if (mm is num && mm > 0) {
            _maxMatches = _windowMaxMatches == null
                ? mm.toInt()
                : math.min(mm.toInt(), _windowMaxMatches!);
          }
          _loadingSports = false;
        });
        return;
      }
      setState(() => _loadingSports = false);
    } catch (_) {
      if (mounted) setState(() => _loadingSports = false);
    }
  }

  Future<void> _loadAvailability() async {
    try {
      final res = await http
          .get(
            _uri('/coupons/value-picks/availability',
                _selectedSportId != null ? {'sport_id': '$_selectedSportId'} : null),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) {
          setState(() {
            _availableEvents = (decoded['events'] is num) ? (decoded['events'] as num).toInt() : null;
            _availablePicks = (decoded['picks'] is num) ? (decoded['picks'] as num).toInt() : null;
          });
        }
      }
    } catch (_) {
      /* disponibilité purement indicative : l'échec ne bloque pas la saisie */
    }
  }

  Future<void> _onSportChanged(int? sportId) async {
    setState(() {
      _selectedSportId = sportId;
      _result = null;
      _error = null;
      _pickCodes.clear();
      _availableEvents = null;
      _availablePicks = null;
      _todayEvents = null;
      _tomorrowEvents = null;
      _windowMaxMatches = null;
    });
    await Future.wait([_loadAvailability(), _loadWindow()]);
  }

  Future<void> _generate() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final numMatches = int.parse(_numCtrl.text.trim());
    final targetOdds = _parseOdds(_oddsCtrl.text);

    setState(() {
      _loading = true;
      _error = null;
      _errorCode = null;
      _result = null;
      _pickCodes.clear();
      _progressMessage = null;
    });

    // MegaPari n'accepte qu'**un code coupon par minute**. Quand le créneau est
    // occupé, l'API répond en < 1 s avec `retry_after_seconds` : on attends le
    // délai indiqué en affichant un compte à rebours, puis on relance
    // automatiquement. Aucune requête HTTP longue → pas de coupure proxy.
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final outcome = await _postGenerate(numMatches, targetOdds);
      if (outcome.retryAfter != null && attempt < maxAttempts && outcome.retryAfter! <= 120) {
        var remaining = outcome.retryAfter!;
        while (remaining > 0 && mounted) {
          setState(() {
            _progressMessage = _isFr
                ? 'MegaPari autorise 1 code coupon par minute — nouvelle tentative dans $remaining s'
                : 'MegaPari allows 1 coupon code per minute — retrying in $remaining s';
          });
          await Future.delayed(const Duration(seconds: 1));
          remaining--;
        }
        continue;
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _progressMessage = null;
        _result = outcome.result;
        _errorCode = outcome.errorCode;
        _error = outcome.error;
      });
      final mode = (outcome.result?['couponMode'] ?? '').toString();
      if (outcome.result != null && outcome.result!['success'] == false && mode == 'SINGLE') {
        setState(() {
          _errorCode = 'B2B_UNAVAILABLE';
          _error = (outcome.result!['message'] ?? 'Coupon non généré par MegaPari.').toString();
        });
      }
      return;
    }
  }

  bool get _isFr => Localizations.localeOf(context).languageCode == 'fr';

  /// Un appel HTTP à `generate-combined`, traduit en résultat exploitable.
  Future<_GenerateOutcome> _postGenerate(int numMatches, double targetOdds) async {
    try {
      final res = await http
          .post(
            _uri('/coupons/generate-combined'),
            headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({
              'num_matches': numMatches,
              'target_total_odds': targetOdds,
              if (_selectedSportId != null) 'sport_id': _selectedSportId,
            }),
          )
          .timeout(const Duration(seconds: 60));

      final decoded = _safeDecode(res.body);

      if (res.statusCode >= 200 && res.statusCode < 300 && decoded is Map<String, dynamic>) {
        // MegaPari peut refuser le créneau : la réponse (200) porte alors
        // `retry_after_seconds`, qu'on utilise pour relancer automatiquement.
        final ra = int.tryParse((decoded['retry_after_seconds'] ?? '').toString());
        return _GenerateOutcome(
          result: decoded,
          retryAfter: decoded['success'] == false && ra != null ? ra : null,
        );
      }

      final code = _extractReasonCode(decoded);
      final retryAfter = int.tryParse(
        ((decoded is Map ? decoded['details'] : null) is Map
                ? (decoded['details'] as Map)['retry_after_seconds']
                : null)
            .toString(),
      );
      return _GenerateOutcome(
        errorCode: code,
        error: _humanError(code, decoded),
        retryAfter: code == 'B2B_RATE_LIMITED' ? retryAfter : null,
      );
    } catch (e) {
      return _GenerateOutcome(
        errorCode: 'NETWORK',
        error: 'Connexion impossible. Vérifie ta connexion puis réessaie.\n($e)',
      );
    }
  }

  /// Génère le code coupon d'une sélection (MegaPari : 1 coupon = 1 marché).
  Future<void> _fetchPickCode(String eventId, String selectionId, {bool silent = false}) async {
    final key = '$eventId|$selectionId';
    if (_pickCodes[key]?.loading == true) return;
    setState(() => _pickCodes[key] = const _PickCodeState(loading: true));

    try {
      final res = await http
          .post(
            _uri('/coupons/pick-code'),
            headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({'event_id': eventId, 'selection_id': selectionId}),
          )
          .timeout(const Duration(seconds: 50));

      final decoded = _safeDecode(res.body);
      if (res.statusCode >= 200 && res.statusCode < 300 && decoded is Map<String, dynamic>) {
        final code = decoded['couponCode']?.toString();
        setState(() => _pickCodes[key] = _PickCodeState(
              code: code,
              deepLink: decoded['deepLink']?.toString(),
            ));
        if (code != null && !silent) {
          await Clipboard.setData(ClipboardData(text: code));
          _snack(Localizations.localeOf(context).languageCode == 'fr'
              ? 'Code $code copié ✓'
              : 'Code $code copied ✓');
        }
        return;
      }

      final code = _extractReasonCode(decoded);
      setState(() => _pickCodes[key] = _PickCodeState(error: _humanError(code, decoded)));
    } catch (e) {
      setState(() => _pickCodes[key] = _PickCodeState(error: 'Réseau : $e'));
    }
  }

  /// Génère les codes de toutes les sélections, une par une.
  ///
  /// L'API partenaire MegaPari ne crée un coupon que pour UNE sélection : un
  /// combiné de N matchs donne N codes. La passerelle accepte environ un code
  /// toutes les 6 s (mesuré), d'où l'espacement — au-delà, elle répond 400
  /// « LiveBetService returned 200 » et il faut attendre une minute.
  Future<void> _fetchAllPickCodes(List<dynamic> picks, bool isFr) async {
    if (_bulkRunning) return;
    setState(() => _bulkRunning = true);
    try {
      for (final raw in picks) {
        final m = raw as Map<String, dynamic>;
        final key = '${m['event_id']}|${m['selection_id']}';
        if (_pickCodes[key]?.code != null) continue;
        if (!mounted) return;
        await _fetchPickCode('${m['event_id']}', '${m['selection_id']}', silent: true);
        if (!mounted) return;
        await Future.delayed(const Duration(milliseconds: 6500));
      }
      if (mounted) {
        _snack(isFr ? 'Codes générés ✓' : 'Codes generated ✓');
      }
    } finally {
      if (mounted) setState(() => _bulkRunning = false);
    }
  }

  static dynamic _safeDecode(String body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  static String? _extractReasonCode(dynamic decoded) {
    if (decoded is Map) {
      final rc = decoded['reason_code'] ?? decoded['error'];
      if (rc is String && rc.isNotEmpty) return rc;
      final msg = decoded['message'];
      if (msg is String && msg.isNotEmpty) return msg;
      if (msg is List && msg.isNotEmpty) return msg.first.toString();
    }
    return null;
  }

  String _humanError(String? code, dynamic decoded) {
    switch (code) {
      case 'NO_VALUE_PICKS':
        return _selectedSportId != null
            ? 'Aucun match disponible dans cette discipline pour l\'instant. Choisis « Tous les sports » ou réessaie plus tard.'
            : 'Aucune Value Pick disponible (marge au-dessus du seuil). Lance un scan puis réessaie dans quelques minutes.';
      case 'NOT_ENOUGH_EVENTS':
        final d = (decoded is Map) ? decoded['details'] : null;
        final available = (d is Map ? d['available'] : null) ?? _availableEvents ?? '?';
        return 'Pas assez de matchs disponibles : $available seulement. Réduis le nombre de matchs ou change de discipline.';
      case 'INVALID_TARGET_ODDS':
        return 'La côte totale visée doit être supérieure ou égale à 1.01.';
      case 'INVALID_NUM_MATCHES':
        return 'Le nombre de matchs doit être un entier supérieur ou égal à 1.';
      case 'TARGET_UNREACHABLE_AT_MIN_PROBABILITY':
      case 'TARGET_UNREACHABLE':
        final d = (decoded is Map) ? decoded['details'] : null;
        final maxOdds = (d is Map && d['max_reachable_odds'] is num)
            ? (d['max_reachable_odds'] as num).toDouble()
            : null;
        final suggested = (d is Map && d['suggested_matches'] is num)
            ? (d['suggested_matches'] as num).toInt()
            : null;
        return 'Chaque sélection doit avoir au moins 70 % de chances de passer. '
            '${maxOdds != null ? "Avec ce nombre de matchs, la cote plafonne à ×${maxOdds.toStringAsFixed(2)}. " : ""}'
            '${suggested != null ? "Augmente le nombre de matchs à $suggested pour viser cette côte." : "Augmente le nombre de matchs ou réduis la côte visée."}';
      case 'NO_PICK_ABOVE_MIN_PROBABILITY':
        final d = (decoded is Map) ? decoded['details'] : null;
        final best = (d is Map && d['best_probability'] is num)
            ? (d['best_probability'] as num).toInt()
            : null;
        return 'Aucune sélection n\'atteint 70 % de chances de passer en ce moment'
            '${best != null ? " (meilleure : $best %)" : ""}. Réessaie dans quelques minutes.';
      case 'LIVE_FEED_UNAVAILABLE':
        return 'Impossible de lire les cotes en direct chez MegaPari. Vérifie ta connexion puis réessaie — aucune cote périmée ne sera utilisée.';
      case 'B2B_RATE_LIMITED_FEED':
        return 'MegaPari limite les lectures de cotes : réessaie dans quelques secondes.';
      case 'B2B_RATE_LIMITED':
        final d = (decoded is Map) ? decoded['details'] : null;
        final retry = (d is Map && d['retry_after_seconds'] is num)
            ? (d['retry_after_seconds'] as num).toInt()
            : 60;
        return 'MegaPari limite temporairement la création de codes coupon. Réessaie dans $retry secondes.';
      case 'SELECTION_NOT_AVAILABLE':
        return 'Cette sélection n\'est plus disponible (cote changée ou marché fermé). Relance la composition.';
      case 'B2B_UNAVAILABLE':
      case 'B2B_COUPON_FAILED':
      case 'B2B_SHARECOUPON_ERROR':
        return 'La composition est prête mais MegaPari n\'a pas validé le coupon. Les cotes ont peut-être bougé : réessaie dans un instant.';
      case 'PROVIDER_NOT_SUPPORTED':
        return 'Seul MegaPari est disponible pour la génération de coupons.';
      default:
        if (decoded is Map && decoded['message'] is String) return decoded['message'] as String;
        return 'Une erreur est survenue lors de la génération du coupon.';
    }
  }

  // -------------------------------------------------------------- helpers ---

  static double _parseOdds(String raw) => double.parse(raw.trim().replaceAll(',', '.'));

  /// Cote moyenne nécessaire par match pour atteindre la cible.
  String get _hintPerMatch {
    final n = int.tryParse(_numCtrl.text.trim());
    final t = double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.'));
    if (n == null || n < 1 || t == null || t <= 0) return '—';
    final per = math.pow(t, 1 / n).toDouble();
    if (!per.isFinite) return '—';
    return per.toStringAsFixed(2);
  }

  bool get _canGenerate {
    if (_loading) return false;
    final n = int.tryParse(_numCtrl.text.trim());
    final t = double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.'));
    if (n == null || n < 1 || n > _maxMatches) return false;
    if (t == null || t < 1.01) return false;
    if (_availableEvents != null && _availableEvents! > 0 && n > _availableEvents!) return false;
    return true;
  }

  void _setMatches(int n) {
    setState(() => _numCtrl.text = n.toString());
    _formKey.currentState?.validate();
  }

  void _setOdds(double o) {
    setState(() => _oddsCtrl.text = o == o.roundToDouble() ? o.toStringAsFixed(0) : o.toString());
    _formKey.currentState?.validate();
  }

  String get _selectedSportLabel {
    if (_selectedSportId == null) return 'Tous les sports';
    for (final s in _sports) {
      if (s['id'] == _selectedSportId) return (s['name'] ?? '').toString();
    }
    return 'Tous les sports';
  }

  // ----------------------------------------------------------------- build --

  @override
  Widget build(BuildContext context) {
    final isFr = Localizations.localeOf(context).languageCode == 'fr';
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(isFr ? 'Combiné sur mesure' : 'Custom accumulator'),
        actions: [
          IconButton(
            tooltip: isFr ? 'Actualiser' : 'Refresh',
            onPressed: _loadingSports ? null : _loadAll,
            icon: _loadingSports
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ResponsibleGamblingBanner(),
              const SizedBox(height: 12),
              _availabilityBanner(isFr, cs),
              const SizedBox(height: 12),
              _formCard(isFr, cs),
              if (_error != null) ...[
                const SizedBox(height: 12),
                _errorBanner(isFr, cs),
              ],
              if (_result != null) ...[
                const SizedBox(height: 16),
                _resultCard(isFr, cs),
              ],
              const SizedBox(height: 16),
              Text(
                isFr
                    ? 'Cotes relues EN DIRECT chez MegaPari à chaque clic. Seules les sélections ayant au moins 70 % de chances de passer sont retenues. Les matchs sont ceux d\'aujourd\'hui, complétés par demain si nécessaire — jamais au-delà — et leur coup d\'envoi doit être à plus de 30 min (sinon le coupon serait déjà en live chez MegaPari). Un code par match (limite de l\'API partenaire MegaPari).'
                    : 'Odds fetched LIVE from MegaPari on every click. Only selections with at least 70% chance of winning are kept. Matches are today\'s only; if the selection cannot be built, tomorrow is used — never beyond. One code per match (MegaPari partner API limit).',
                style: TextStyle(fontSize: 10.5, color: Colors.grey[600], height: 1.35),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- sections ---

  Widget _availabilityBanner(bool isFr, ColorScheme cs) {
    final String text;
    final Color color;
    final IconData icon;

    if (_loadingSports) {
      text = isFr ? 'Chargement des disciplines…' : 'Loading sports…';
      color = cs.primary;
      icon = Icons.hourglass_top;
    } else if (_todayEvents != null || _tomorrowEvents != null) {
      final t = _todayEvents ?? 0;
      final m = _tomorrowEvents ?? 0;
      text = isFr
          ? '$t match(s) aujourd\'hui · $m demain — « $_selectedSportLabel » (cotes live, sélections ≥ 70 %, coup d\'envoi dans ≥ 30 min)'
          : '$t match(es) today · $m tomorrow — “$_selectedSportLabel” (live odds, picks ≥ 70%, kick-off in ≥ 30 min)';
      color = (t + m) > 0 ? Colors.green : Colors.orange;
      icon = (t + m) > 0 ? Icons.check_circle_outline : Icons.info_outline;
    } else if (_availableEvents != null) {
      if (_availableEvents == 0) {
        text = isFr
            ? 'Aucun match éligible dans « $_selectedSportLabel » pour l\'instant.'
            : 'No eligible match in “$_selectedSportLabel” right now.';
        color = Colors.orange;
        icon = Icons.info_outline;
      } else {
        text = isFr
            ? '$_availableEvents matchs · $_availablePicks sélections disponibles dans « $_selectedSportLabel »'
            : '$_availableEvents matches · $_availablePicks selections in “$_selectedSportLabel”';
        color = Colors.green;
        icon = Icons.check_circle_outline;
      }
    } else {
      text = isFr
          ? 'Disponibilité inconnue — tu peux tout de même générer.'
          : 'Availability unknown — you can still generate.';
      color = Colors.grey;
      icon = Icons.cloud_off;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.09),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sportSelector(bool isFr, ColorScheme cs) {
    final items = <DropdownMenuItem<int?>>[
      DropdownMenuItem<int?>(
        value: null,
        child: Row(
          children: [
            const Icon(Icons.public, size: 18),
            const SizedBox(width: 8),
            Text(isFr ? 'Tous les sports' : 'All sports', style: const TextStyle(fontSize: 13.5)),
          ],
        ),
      ),
      ..._sports.map((s) {
        final id = s['id'] is num ? (s['id'] as num).toInt() : null;
        final name = (s['name'] ?? '').toString();
        final events = s['events'] is num ? (s['events'] as num).toInt() : 0;
        final available = s['available'] == true || events > 0;
        return DropdownMenuItem<int?>(
          value: id,
          child: Row(
            children: [
              Icon(
                _sportIcon(name),
                size: 18,
                color: available ? cs.primary : Colors.grey,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  available ? '$name ($events)' : name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: available ? null : Colors.grey,
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isFr ? 'Discipline' : 'Sport',
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.grey[700]),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<int?>(
          value: _selectedSportId,
          isExpanded: true,
          items: items,
          onChanged: _loadingSports ? null : (v) => _onSportChanged(v),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.sports_soccer, size: 20),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: cs.primary, width: 1.8),
            ),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            helperText: isFr
                ? 'Sports réels proposés par le bookmaker — le combiné reste dans cette discipline.'
                : 'Real sports offered by the bookmaker — the accumulator stays within it.',
            helperMaxLines: 2,
          ),
        ),
      ],
    );
  }

  static IconData _sportIcon(String name) {
    final n = name.toLowerCase();
    if (n.contains('foot')) return Icons.sports_soccer;
    if (n.contains('basket')) return Icons.sports_basketball;
    if (n.contains('tennis') || n.contains('table')) return Icons.sports_tennis;
    if (n.contains('hockey')) return Icons.sports_hockey;
    if (n.contains('volley')) return Icons.sports_volleyball;
    if (n.contains('handball')) return Icons.sports_handball;
    if (n.contains('rugby') || n.contains('american')) return Icons.sports_football;
    if (n.contains('boxe') || n.contains('mma') || n.contains('fight')) return Icons.sports_mma;
    if (n.contains('cricket')) return Icons.sports_cricket;
    if (n.contains('golf')) return Icons.sports_golf;
    if (n.contains('motor') || n.contains('formula') || n.contains('racing')) return Icons.sports_motorsports;
    if (n.contains('baseball')) return Icons.sports_baseball;
    if (n.contains('esport') || n.contains('fifa') || n.contains('sega') || n.contains('dota')) return Icons.sports_esports;
    return Icons.emoji_events_outlined;
  }

  Widget _formCard(bool isFr, ColorScheme cs) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.tune, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    isFr ? 'Configuration du combiné' : 'Accumulator settings',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: cs.primary),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              _sportSelector(isFr, cs),
              const SizedBox(height: 16),

              // ---- Nombre de matchs : LIBRE ----
              TextFormField(
                controller: _numCtrl,
                focusNode: _numFocus,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                onFieldSubmitted: (_) => _oddsFocus.requestFocus(),
                decoration: _fieldDecoration(
                  label: isFr ? 'Nombre de matchs' : 'Number of matches',
                  hint: '3',
                  icon: Icons.sports_soccer,
                  helper: _availableEvents != null
                      ? (isFr
                          ? '1 à $_maxMatches matchs — $_availableEvents disponibles'
                          : '1 to $_maxMatches matches — $_availableEvents available')
                      : (isFr ? '1 à $_maxMatches matchs' : '1 to $_maxMatches matches'),
                ),
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  if (n == null) return isFr ? 'Saisis un nombre' : 'Enter a number';
                  if (n < 1) return isFr ? 'Au moins 1 match' : 'At least 1 match';
                  if (n > _maxMatches) return isFr ? 'Maximum $_maxMatches matchs' : 'Max $_maxMatches matches';
                  if (_availableEvents != null && _availableEvents! > 0 && n > _availableEvents!) {
                    return isFr
                        ? 'Seulement $_availableEvents matchs disponibles'
                        : 'Only $_availableEvents matches available';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 10),
              _presetChips<int>(
                values: _matchPresets,
                selected: int.tryParse(_numCtrl.text.trim()),
                labelOf: (v) => '$v',
                onSelected: _setMatches,
              ),
              const SizedBox(height: 18),

              // ---- Côte totale visée : LIBRE ----
              TextFormField(
                controller: _oddsCtrl,
                focusNode: _oddsFocus,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                onChanged: (_) => setState(() {}),
                onFieldSubmitted: (_) => _canGenerate ? _generate() : null,
                decoration: _fieldDecoration(
                  label: isFr ? 'Côte totale visée' : 'Target total odds',
                  hint: '2.5',
                  icon: Icons.trending_up,
                  helper: isFr
                      ? 'Sans limite • cote moyenne par match : ×$_hintPerMatch'
                      : 'No limit • average odds per match: ×$_hintPerMatch',
                  suffix: 'x',
                ),
                validator: (v) {
                  final d = double.tryParse((v ?? '').trim().replaceAll(',', '.'));
                  if (d == null) return isFr ? 'Saisis une cote' : 'Enter odds';
                  if (!d.isFinite || d < 1.01) {
                    return isFr ? 'Côte minimale 1.01' : 'Minimum odds 1.01';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 10),
              _presetChips<double>(
                values: _oddsPresets,
                selected: double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.')),
                labelOf: (v) => '×${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}',
                onSelected: _setOdds,
              ),
              const SizedBox(height: 14),
              _summaryStrip(isFr, cs),
              const SizedBox(height: 16),

              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: _canGenerate ? _generate : null,
                  icon: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                        )
                      : const Icon(Icons.auto_awesome),
                  label: Text(
                    _loading
                        ? (_progressMessage ??
                            (isFr ? 'Recherche de la meilleure combinaison…' : 'Searching best combination…'))
                        : (isFr ? 'Générer le Code Coupon' : 'Generate Coupon Code'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryStrip(bool isFr, ColorScheme cs) {
    final n = int.tryParse(_numCtrl.text.trim());
    final t = double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.'));
    final valid = n != null && t != null && t >= 1.01;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(child: _miniStat(label: isFr ? 'Matchs' : 'Matches', value: valid ? '$n' : '—', cs: cs)),
          Container(width: 1, height: 32, color: cs.outlineVariant),
          Expanded(
            child: _miniStat(
              label: isFr ? 'Côte visée' : 'Target odds',
              value: valid ? '×${t.toStringAsFixed(2)}' : '—',
              cs: cs,
            ),
          ),
          Container(width: 1, height: 32, color: cs.outlineVariant),
          Expanded(
            child: _miniStat(
              label: isFr ? 'Cote / match' : 'Odds / match',
              value: '×$_hintPerMatch',
              cs: cs,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniStat({required String label, required String value, required ColorScheme cs}) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: cs.primary, height: 1.1)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant), textAlign: TextAlign.center),
      ],
    );
  }

  Widget _presetChips<T>({
    required List<T> values,
    required T? selected,
    required String Function(T) labelOf,
    required void Function(T) onSelected,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: values.map((v) {
        final isSelected = selected == v;
        return ChoiceChip(
          label: Text(labelOf(v), style: const TextStyle(fontSize: 12.5)),
          selected: isSelected,
          onSelected: (_) => onSelected(v),
          visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
          showCheckmark: false,
        );
      }).toList(),
    );
  }

  InputDecoration _fieldDecoration({
    required String label,
    required String hint,
    required IconData icon,
    String? helper,
    String? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      suffixText: suffix,
      prefixIcon: Icon(icon, size: 20),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 1.8),
      ),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      helperMaxLines: 2,
    );
  }

  Widget _errorBanner(bool isFr, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.error.withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: cs.onErrorContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isFr ? 'Génération impossible' : 'Generation failed',
                  style: TextStyle(fontWeight: FontWeight.w700, color: cs.onErrorContainer, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(_error!, style: TextStyle(color: cs.onErrorContainer, fontSize: 12.5, height: 1.35)),
                if (_errorCode != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Code : $_errorCode',
                    style: TextStyle(color: cs.onErrorContainer.withOpacity(0.75), fontSize: 10.5),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: isFr ? 'Réessayer' : 'Retry',
            onPressed: _loading ? null : _generate,
            icon: Icon(Icons.refresh, color: cs.onErrorContainer, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(bool isFr, ColorScheme cs) {
    final r = _result!;
    final label = (r['label'] ?? '').toString();
    final totalOdds = (r['totalOdds'] is num) ? (r['totalOdds'] as num).toDouble() : null;
    final targetOdds = (r['targetTotalOdds'] is num) ? (r['targetTotalOdds'] as num).toDouble() : null;
    final gap = (r['gapPercent'] is num) ? (r['gapPercent'] as num).toDouble() : null;
    final exact = r['exact'] == true;
    final numMatches = (r['numMatches'] is num) ? (r['numMatches'] as num).toInt() : null;
    final couponCode = r['couponCode']?.toString();
    final deepLink = r['deepLink']?.toString();
    final couponMode = (r['couponMode'] ?? 'NONE').toString();
    final picks = (r['picks'] is List) ? (r['picks'] as List) : const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: cs.primary.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.playlist_add_check_circle, color: cs.primary, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label.isNotEmpty ? label : (isFr ? 'Combiné composé' : 'Accumulator built'),
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (numMatches != null) '$numMatches ${isFr ? "matchs" : "matches"}',
                              if (_selectedSportLabel.isNotEmpty) _selectedSportLabel,
                            ].join('  •  '),
                            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                          ),
                          if (couponMode == 'COMBO' && couponCode != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                isFr
                                    ? 'Un seul code pour les $numMatches sélections'
                                    : 'One single code for all $numMatches selections',
                                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.green),
                              ),
                            ),
                          if ((r['source'] ?? '') == 'live')
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Row(
                                children: [
                                  const Icon(Icons.bolt, size: 13, color: Colors.blue),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      isFr
                                          ? 'Cotes lues en direct chez MegaPari · sélections ≥ ${r['min_probability'] ?? 70} % de chances'
                                          : 'Odds fetched live from MegaPari · picks ≥ ${r['min_probability'] ?? 70}% chance',
                                      style: const TextStyle(fontSize: 10.5, color: Colors.blueGrey),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _targetVsAchieved(isFr, cs, targetOdds: targetOdds, achieved: totalOdds, gap: gap, exact: exact),
                // Le code coupon est placé AVANT la liste des sélections :
                // avec 50 matchs, l'utilisateur ne doit pas faire défiler
                // 50 lignes pour récupérer son code.
                if (couponCode != null && couponCode.isNotEmpty && deepLink != null) ...[
                  const SizedBox(height: 12),
                  CouponCodeCard(
                    couponCode: couponCode,
                    deepLink: deepLink,
                    message: (r['message'] ?? '').toString().isNotEmpty
                        ? r['message'].toString()
                        : (isFr ? 'Coupon généré — colle ce code dans MegaPari' : 'Coupon generated — paste this code in MegaPari'),
                    onOpen: () => _openMegaPari(deepLink),
                  ),
                ],
                const SizedBox(height: 14),
                if (picks.isEmpty)
                  Text(
                    isFr ? 'Aucune sélection détaillée.' : 'No detailed selection.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  )
                else
                  ...picks.map((p) => _pickTile(p as Map<String, dynamic>, cs, isFr: isFr, showCodeButton: couponCode == null)),
              ],
            ),
          ),
        ),
        if (couponCode != null && couponCode.isNotEmpty && deepLink != null) ...[
          const SizedBox(height: 12),
          _howToCard(isFr),
        ] else if (couponMode == 'NONE' || couponMode == 'PER_PICK') ...[
          const SizedBox(height: 14),
          _multiCouponNotice(
            isFr,
            count: picks.length,
            onGenerateAll: couponMode == 'PER_PICK' && picks.isNotEmpty
                ? () => _fetchAllPickCodes(picks, isFr)
                : null,
            running: _bulkRunning,
          ),
          if (deepLink != null) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _openMegaPari(deepLink),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(isFr ? 'Ouvrir MegaPari' : 'Open MegaPari'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13)),
            ),
          ],
        ],
      ],
    );
  }

  /// Bandeau « cible demandée / cote obtenue / écart ».
  Widget _targetVsAchieved(
    bool isFr,
    ColorScheme cs, {
    required double? targetOdds,
    required double? achieved,
    required double? gap,
    required bool exact,
  }) {
    final ok = exact || (gap != null && gap <= 1.0);
    final color = exact ? Colors.green : (ok ? Colors.green.shade600 : Colors.orange);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(exact ? Icons.check_circle : Icons.adjust, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  exact
                      ? (isFr ? 'Côte cible atteinte exactement' : 'Target odds matched exactly')
                      : (isFr ? 'Cote la plus proche trouvée' : 'Closest odds found'),
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (targetOdds != null) '${isFr ? "Visé" : "Target"} ×${targetOdds.toStringAsFixed(2)}',
                    if (achieved != null) '${isFr ? "Obtenu" : "Achieved"} ×${achieved.toStringAsFixed(2)}',
                    if (gap != null) '${isFr ? "Écart" : "Gap"} ${gap.toStringAsFixed(2)} %',
                  ].join('   •   '),
                  style: TextStyle(fontSize: 11.5, color: Colors.grey[800]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickTile(Map<String, dynamic> p, ColorScheme cs, {required bool isFr, bool showCodeButton = true}) {
    final home = (p['home'] ?? '').toString();
    final away = (p['away'] ?? '').toString();
    final league = (p['league'] ?? '').toString();
    final sportName = (p['sport_name'] ?? '').toString();
    final market = (p['market_type'] ?? '').toString();
    final line = p['line'];
    final selName = (p['selection_name'] ?? '').toString();
    final odds = (p['odds'] is num) ? (p['odds'] as num).toDouble() : null;
    final margin = (p['margin_percent'] is num) ? (p['margin_percent'] as num).toDouble() : null;
    final prob = (p['probability_percent'] is num) ? (p['probability_percent'] as num).toInt() : null;
    final day = (p['day'] ?? '').toString();
    final dayLabel = day == 'TODAY'
        ? (isFr ? "Aujourd'hui" : 'Today')
        : day == 'TOMORROW'
            ? (isFr ? 'Demain' : 'Tomorrow')
            : '';
    String kickoff = '';
    final rawStart = (p['start_time'] ?? '').toString();
    if (rawStart.isNotEmpty) {
      final dt = DateTime.tryParse(rawStart);
      if (dt != null) {
        final l = dt.toLocal();
        kickoff = '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
      }
    }
    final eventId = (p['event_id'] ?? '').toString();
    final selectionId = (p['selection_id'] ?? '').toString();
    final key = '$eventId|$selectionId';
    final codeState = _pickCodes[key];

    final title = home.isNotEmpty || away.isNotEmpty ? '$home – $away' : '#$eventId';
    // Le libellé renvoyé par le bookmaker contient déjà la ligne
    // (« Handicap 2 (1.5) », « Total (2.5) Over ») : on n'affiche alors que lui.
    final marketLabel = _marketLabel(market, line);
    final redundantLabel = selName.isNotEmpty &&
        (selName.toLowerCase().startsWith(marketLabel.toLowerCase().split(' ').first) ||
            selName.toLowerCase().contains(marketLabel.toLowerCase()));
    final subtitleParts = <String>[
      if (dayLabel.isNotEmpty) kickoff.isNotEmpty ? '$dayLabel $kickoff' : dayLabel,
      if (league.isNotEmpty) league,
      if (sportName.isNotEmpty) sportName,
      if (market.isNotEmpty && !redundantLabel) marketLabel,
      if (selName.isNotEmpty) selName,
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: (day == 'TOMORROW' ? Colors.amber : Colors.green).withOpacity(0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  day == 'TOMORROW' ? Icons.event : Icons.check,
                  size: 15,
                  color: day == 'TOMORROW' ? Colors.orange : Colors.green,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitleParts.join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: Colors.grey[700]),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      odds != null ? odds.toStringAsFixed(2) : '—',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: cs.primary),
                    ),
                  ),
                  if (prob != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${prob}% de chance',
                        style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: Colors.green),
                      ),
                    ),
                  if (margin != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        'marge ${margin.toStringAsFixed(1)}%',
                        style: TextStyle(fontSize: 9.5, color: Colors.grey[600]),
                      ),
                    ),
                ],
              ),
            ],
          ),
          if (!showCodeButton) const SizedBox.shrink() else ...[
          const SizedBox(height: 6),
          if (codeState?.code != null)
            Row(
              children: [
                const Icon(Icons.confirmation_number, size: 15, color: Colors.green),
                const SizedBox(width: 6),
                Text(
                  codeState!.code!,
                  style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2, fontSize: 14),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: codeState.code!));
                    _snack(isFr ? 'Code copié ✓' : 'Code copied ✓');
                  },
                  icon: const Icon(Icons.copy, size: 15),
                  label: Text(isFr ? 'Copier' : 'Copy', style: const TextStyle(fontSize: 11.5)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            )
          else if (codeState?.error != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    codeState!.error!,
                    style: TextStyle(fontSize: 10.5, color: cs.error, height: 1.3),
                  ),
                ),
                TextButton(
                  onPressed: () => _fetchPickCode(eventId, selectionId),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(isFr ? 'Réessayer' : 'Retry', style: const TextStyle(fontSize: 11.5)),
                ),
              ],
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: codeState?.loading == true ? null : () => _fetchPickCode(eventId, selectionId),
                icon: codeState?.loading == true
                    ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.qr_code_2, size: 16),
                label: Text(
                  codeState?.loading == true
                      ? (isFr ? 'Génération…' : 'Generating…')
                      : (isFr ? 'Obtenir le code' : 'Get code'),
                  style: const TextStyle(fontSize: 11.5),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _marketLabel(String market, dynamic line) {
    switch (market) {
      case '1X2':
        return '1X2';
      case 'OVER_UNDER':
        return line != null ? 'Plus / Moins $line' : 'Plus / Moins';
      case 'BTTS':
        return 'Les deux équipes marquent';
      case 'DOUBLE_CHANCE':
        return 'Double chance';
      case 'HANDICAP':
        return line != null ? 'Handicap $line' : 'Handicap';
      case 'CORNERS_OU':
        return line != null ? 'Corners $line' : 'Corners';
      default:
        return market;
    }
  }

  Widget _multiCouponNotice(
    bool isFr, {
    int count = 0,
    VoidCallback? onGenerateAll,
    bool running = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity(0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  isFr ? 'Combiné : un code par sélection' : 'Accumulator: one code per selection',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            isFr
                ? 'L\'API partenaire de MegaPari ne crée un coupon que pour UN match à la fois : un code unique pour $count sélections est techniquement impossible (les paramètres sont scalaires côté bookmaker). Chaque code ci-dessous ouvre exactement son match — ajoute-les l\'un après l\'autre au coupon MegaPari.'
                : 'MegaPari\'s partner API creates a coupon for ONE match at a time: a single code for $count selections is technically impossible (the bookmaker\'s parameters are scalar). Each code below opens exactly its match — add them one after another to the MegaPari coupon.',
            style: TextStyle(fontSize: 11.5, height: 1.35, color: Colors.grey[800]),
          ),
          if (onGenerateAll != null) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: running ? null : onGenerateAll,
              icon: running
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.qr_code_2, size: 18),
              label: Text(
                running
                    ? (isFr ? 'Génération… (1 code / 6 s)' : 'Generating… (1 code / 6 s)')
                    : (isFr ? 'Générer les $count codes' : 'Generate all $count codes'),
              ),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _howToCard(bool isFr) {
    final items = isFr
        ? const [
            'Copie le code avec « Copier le code ».',
            'Ouvre MegaPari avec « Ouvrir MegaPari ».',
            'Pari sportif → Coupon → Colle le code → Valide.',
          ]
        : const [
            'Copy the code with “Copy code”.',
            'Open MegaPari with “Open MegaPari”.',
            'Sports → Bet slip → Paste the code → Confirm.',
          ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.withOpacity(0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isFr ? 'Comment utiliser le code' : 'How to use the code',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
          const SizedBox(height: 8),
          ...List.generate(
            items.length,
            (i) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${i + 1}. ', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  Expanded(child: Text(items[i], style: const TextStyle(fontSize: 12, height: 1.3))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openMegaPari(String deepLink) async {
    final isFr = Localizations.localeOf(context).languageCode == 'fr';
    final uri = Uri.tryParse(deepLink);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
      if (ok) return;
    } catch (_) {
      // on retombe sur la copie ci-dessous
    }
    await Clipboard.setData(ClipboardData(text: deepLink));
    _snack(isFr ? 'Lien copié : $deepLink' : 'Link copied: $deepLink');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}

/// État de génération du code coupon d'une sélection.
/// Résultat d'un appel à `generate-combined` : soit un combiné, soit une
/// erreur — avec l'éventuel délai avant nouvelle tentative (1 code / minute).
class _GenerateOutcome {
  final Map<String, dynamic>? result;
  final String? errorCode;
  final String? error;
  final int? retryAfter;

  const _GenerateOutcome({this.result, this.errorCode, this.error, this.retryAfter});
}

class _PickCodeState {
  final String? code;
  final String? deepLink;
  final String? error;
  final bool loading;

  const _PickCodeState({this.code, this.deepLink, this.error, this.loading = false});
}
