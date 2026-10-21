import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/coupon_code_card.dart';
import '../../widgets/ui_kit.dart';

/// Écran « Combiné sur mesure ».
///
/// API :
///   GET  {base}/coupons/sports
///   GET  {base}/coupons/value-picks/availability
///   GET  {base}/coupons/window
///   POST {base}/coupons/generate-combined
///   POST {base}/coupons/pick-code
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
  String? _progressMessage;
  String? _error;
  Map<String, dynamic>? _result;

  /// Codes générés à la demande, par sélection.
  final Map<String, _PickCodeState> _pickCodes = {};
  bool _bulkRunning = false;

  List<Map<String, dynamic>> _sports = const [];
  bool _loadingSports = false;
  int? _selectedSportId; // null = tous les sports

  int? _availableEvents;
  int? _todayEvents;
  int? _tomorrowEvents;
  int? _windowMaxMatches;
  int _maxMatches = defaultMaxMatches;
  int? _availablePicks;

  static const _matchPresets = <int>[2, 3, 5, 7, 10];
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
    } catch (_) {}
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
    } catch (_) {}
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
      _result = null;
      _pickCodes.clear();
      _progressMessage = null;
    });

    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final outcome = await _postGenerate(numMatches, targetOdds);
      if (outcome.retryAfter != null && attempt < maxAttempts && outcome.retryAfter! <= 120) {
        var remaining = outcome.retryAfter!;
        while (remaining > 0 && mounted) {
          setState(() {
            _progressMessage = _isFr
                ? 'Nouvelle tentative dans $remaining s…'
                : 'Retrying in $remaining s…';
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
        _error = outcome.error;
      });
      return;
    }
  }

  bool get _isFr => Localizations.localeOf(context).languageCode == 'fr';

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
        error: _humanError(code, decoded),
        retryAfter: code == 'B2B_RATE_LIMITED' ? retryAfter : null,
      );
    } catch (_) {
      return _GenerateOutcome(
        error: _isFr
            ? 'Connexion impossible. Vérifie ta connexion puis réessaie.'
            : 'Connection failed. Check your connection and retry.',
      );
    }
  }

  /// Génère le code coupon d'une sélection.
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
          _snack(_isFr ? 'Code $code copié ✓' : 'Code $code copied ✓');
        }
        return;
      }

      final code = _extractReasonCode(decoded);
      setState(() => _pickCodes[key] = _PickCodeState(error: _humanError(code, decoded)));
    } catch (_) {
      setState(() => _pickCodes[key] = _PickCodeState(
          error: _isFr ? 'Connexion impossible — réessaie.' : 'Connection failed — retry.'));
    }
  }

  /// Génère les codes de toutes les sélections, une par une.
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

  /// Messages courts, orientés action — sans détail technique.
  String _humanError(String? code, dynamic decoded) {
    final fr = _isFr;
    switch (code) {
      case 'NO_VALUE_PICKS':
        return fr
            ? 'Aucun match disponible pour l\'instant. Essaie « Tous les sports » ou réessaie plus tard.'
            : 'No match available right now. Try “All sports” or retry later.';
      case 'NOT_ENOUGH_EVENTS':
        final d = (decoded is Map) ? decoded['details'] : null;
        final available = (d is Map ? d['available'] : null) ?? _availableEvents ?? '?';
        return fr
            ? 'Seulement $available matchs disponibles. Réduis le nombre de matchs.'
            : 'Only $available matches available. Reduce the number of matches.';
      case 'INVALID_TARGET_ODDS':
        return fr ? 'La côte visée doit être supérieure ou égale à 1.01.' : 'Target odds must be at least 1.01.';
      case 'INVALID_NUM_MATCHES':
        return fr ? 'Le nombre de matchs doit être supérieur ou égal à 1.' : 'Number of matches must be at least 1.';
      case 'TARGET_UNREACHABLE_AT_MIN_PROBABILITY':
      case 'TARGET_UNREACHABLE':
        final d = (decoded is Map) ? decoded['details'] : null;
        final maxOdds = (d is Map && d['max_reachable_odds'] is num)
            ? (d['max_reachable_odds'] as num).toDouble()
            : null;
        final suggested = (d is Map && d['suggested_matches'] is num)
            ? (d['suggested_matches'] as num).toInt()
            : null;
        return fr
            ? 'Cette côte est trop haute pour ce nombre de matchs.'
                '${maxOdds != null ? " Maximum : ×${maxOdds.toStringAsFixed(2)}." : ""}'
                '${suggested != null ? " Essaie $suggested matchs." : " Augmente le nombre de matchs ou réduis la cote."}'
            : 'Target odds too high for this number of matches.'
                '${maxOdds != null ? " Max: ×${maxOdds.toStringAsFixed(2)}." : ""}'
                '${suggested != null ? " Try $suggested matches." : " Add matches or lower the target."}';
      case 'NO_PICK_ABOVE_MIN_PROBABILITY':
        return fr
            ? 'Aucune sélection disponible pour le moment. Réessaie dans quelques minutes.'
            : 'No selection available right now. Retry in a few minutes.';
      case 'LIVE_FEED_UNAVAILABLE':
      case 'B2B_RATE_LIMITED_FEED':
        return fr
            ? 'Connexion à MegaPari indisponible. Réessaie dans un instant.'
            : 'MegaPari connection unavailable. Retry in a moment.';
      case 'B2B_RATE_LIMITED':
        final d = (decoded is Map) ? decoded['details'] : null;
        final retry = (d is Map && d['retry_after_seconds'] is num)
            ? (d['retry_after_seconds'] as num).toInt()
            : 60;
        return fr ? 'Réessaie dans $retry secondes.' : 'Retry in $retry seconds.';
      case 'SELECTION_NOT_AVAILABLE':
        return fr
            ? 'Cette sélection n\'est plus disponible. Relance la composition.'
            : 'This selection is no longer available. Rebuild the accumulator.';
      case 'B2B_UNAVAILABLE':
      case 'B2B_COUPON_FAILED':
      case 'B2B_SHARECOUPON_ERROR':
        return fr
            ? 'Le coupon n\'a pas pu être validé. Réessaie dans un instant.'
            : 'Coupon could not be validated. Retry in a moment.';
      case 'PROVIDER_NOT_SUPPORTED':
        return fr ? 'Service momentanément indisponible.' : 'Service temporarily unavailable.';
      default:
        return fr
            ? 'Une erreur est survenue. Réessaie dans un instant.'
            : 'Something went wrong. Retry in a moment.';
    }
  }

  // -------------------------------------------------------------- helpers ---

  static double _parseOdds(String raw) => double.parse(raw.trim().replaceAll(',', '.'));

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
    if (_selectedSportId == null) return _isFr ? 'Tous les sports' : 'All sports';
    for (final s in _sports) {
      if (s['id'] == _selectedSportId) return (s['name'] ?? '').toString();
    }
    return _isFr ? 'Tous les sports' : 'All sports';
  }

  // ----------------------------------------------------------------- build --

  @override
  Widget build(BuildContext context) {
    final isFr = Localizations.localeOf(context).languageCode == 'fr';

    return Scaffold(
      appBar: AppBar(
        title: Text(isFr ? 'Combiné sur mesure' : 'Custom accumulator'),
        actions: [
          IconButton(
            tooltip: isFr ? 'Actualiser' : 'Refresh',
            onPressed: _loadingSports ? null : _loadAll,
            icon: _loadingSports
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _availabilityStrip(isFr),
              const SizedBox(height: 12),
              _formCard(isFr),
              if (_error != null) ...[
                const SizedBox(height: 12),
                _errorBanner(isFr),
              ],
              if (_result != null) ...[
                const SizedBox(height: 16),
                _resultCard(isFr),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- sections ---

  Widget _availabilityStrip(bool isFr) {
    final t = _todayEvents ?? 0;
    final m = _tomorrowEvents ?? 0;
    final total = t + m;

    return SoftCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          IconBubble(
            icon: Icons.calendar_today_outlined,
            color: total > 0 ? AppColors.green : AppColors.orange,
            size: 38,
            iconSize: 17,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _loadingSports
                      ? (isFr ? 'Chargement…' : 'Loading…')
                      : '$_selectedSportLabel',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.ink),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    StatusBadge(
                      text: isFr ? '$t aujourd\'hui' : '$t today',
                      color: AppColors.green,
                      icon: Icons.today_outlined,
                    ),
                    const SizedBox(width: 6),
                    StatusBadge(
                      text: isFr ? '$m demain' : '$m tomorrow',
                      color: AppColors.orange,
                      icon: Icons.event_outlined,
                    ),
                    if (_availablePicks != null) ...[
                      const SizedBox(width: 6),
                      StatusBadge(
                        text: '$_availablePicks ${isFr ? "sélections" : "picks"}',
                        color: AppColors.primary,
                        icon: Icons.bolt,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sportSelector(bool isFr) {
    final items = <DropdownMenuItem<int?>>[
      DropdownMenuItem<int?>(
        value: null,
        child: Row(
          children: [
            const Icon(Icons.public, size: 18, color: AppColors.primary),
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
              Icon(_sportIcon(name), size: 18, color: available ? AppColors.primary : AppColors.muted),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  available ? '$name ($events)' : name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: available ? AppColors.ink : AppColors.muted),
                ),
              ),
            ],
          ),
        );
      }),
    ];

    return DropdownButtonFormField<int?>(
      value: _selectedSportId,
      isExpanded: true,
      items: items,
      onChanged: _loadingSports ? null : (v) => _onSportChanged(v),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.sports_soccer, size: 20),
        hintText: isFr ? 'Discipline' : 'Sport',
      ),
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

  Widget _formCard(bool isFr) {
    return SoftCard(
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const IconBubble(icon: Icons.tune, size: 36, iconSize: 17),
                const SizedBox(width: 10),
                Text(
                  isFr ? 'Configuration du combiné' : 'Accumulator settings',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: AppColors.ink),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _sportSelector(isFr),
            const SizedBox(height: 16),

            // ---- Nombre de matchs ----
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
                        ? '1 à $_maxMatches — $_availableEvents disponibles'
                        : '1 to $_maxMatches — $_availableEvents available')
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _matchPresets.map((v) {
                return PillChip(
                  label: '$v',
                  selected: int.tryParse(_numCtrl.text.trim()) == v,
                  onTap: () => _setMatches(v),
                );
              }).toList(),
            ),
            const SizedBox(height: 18),

            // ---- Côte totale visée ----
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
                    ? 'Cote moyenne par match : ×$_hintPerMatch'
                    : 'Average odds per match: ×$_hintPerMatch',
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _oddsPresets.map((v) {
                final selected =
                    double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.')) == v;
                return PillChip(
                  label: '×${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}',
                  selected: selected,
                  activeColor: AppColors.orange,
                  onTap: () => _setOdds(v),
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            _summaryStrip(isFr),
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
                      : (isFr ? 'Générer le code coupon' : 'Generate coupon code'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryStrip(bool isFr) {
    final n = int.tryParse(_numCtrl.text.trim());
    final t = double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.'));
    final valid = n != null && t != null && t >= 1.01;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.primarySoft.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(child: StatTile(value: valid ? '$n' : '—', label: isFr ? 'Matchs' : 'Matches')),
          Container(width: 1, height: 32, color: AppColors.border),
          Expanded(child: StatTile(value: valid ? '×${t.toStringAsFixed(2)}' : '—', label: isFr ? 'Côte visée' : 'Target odds', color: AppColors.orange)),
          Container(width: 1, height: 32, color: AppColors.border),
          Expanded(child: StatTile(value: '×$_hintPerMatch', label: isFr ? 'Cote / match' : 'Odds / match', color: AppColors.green)),
        ],
      ),
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
    );
  }

  Widget _errorBanner(bool isFr) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.redSoft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.red, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: AppColors.red, fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.35),
            ),
          ),
          IconButton(
            tooltip: isFr ? 'Réessayer' : 'Retry',
            onPressed: _loading ? null : _generate,
            icon: const Icon(Icons.refresh, color: AppColors.red, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(bool isFr) {
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
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const IconBubble(icon: Icons.check_circle_outline, color: AppColors.green, size: 38, iconSize: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label.isNotEmpty ? label : (isFr ? 'Combiné composé' : 'Accumulator built'),
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.ink),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          [
                            if (numMatches != null) '$numMatches ${isFr ? "matchs" : "matches"}',
                            _selectedSportLabel,
                            if (totalOdds != null) '×${totalOdds.toStringAsFixed(2)}',
                          ].join('  •  '),
                          style: const TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _targetVsAchieved(isFr, targetOdds: targetOdds, achieved: totalOdds, gap: gap, exact: exact),
              if (couponCode != null && couponCode.isNotEmpty && deepLink != null) ...[
                const SizedBox(height: 12),
                CouponCodeCard(
                  couponCode: couponCode,
                  deepLink: deepLink,
                  message: isFr ? 'À coller dans MegaPari → Coupon' : 'Paste in MegaPari → Bet slip',
                  onOpen: () => _openMegaPari(deepLink),
                ),
              ],
              const SizedBox(height: 14),
              if (picks.isEmpty)
                Text(
                  isFr ? 'Aucune sélection détaillée.' : 'No detailed selection.',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                )
              else
                ...picks.map((p) => _pickTile(p as Map<String, dynamic>, isFr, showCodeButton: couponCode == null)),
            ],
          ),
        ),
        if (couponCode == null || couponCode.isEmpty) ...[
          const SizedBox(height: 14),
          if (couponMode == 'PER_PICK' && picks.isNotEmpty)
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: _bulkRunning ? null : () => _fetchAllPickCodes(picks, isFr),
                icon: _bulkRunning
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.qr_code_2),
                label: Text(
                  _bulkRunning
                      ? (isFr ? 'Génération des codes…' : 'Generating codes…')
                      : (isFr ? 'Générer les ${picks.length} codes' : 'Generate all ${picks.length} codes'),
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                ),
              ),
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
    bool isFr, {
    required double? targetOdds,
    required double? achieved,
    required double? gap,
    required bool exact,
  }) {
    final ok = exact || (gap != null && gap <= 1.0);
    final color = exact ? AppColors.green : (ok ? AppColors.green : AppColors.orange);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
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
                      ? (isFr ? 'Côte cible atteinte' : 'Target odds reached')
                      : (isFr ? 'Cote la plus proche' : 'Closest odds'),
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (targetOdds != null) '${isFr ? "Visé" : "Target"} ×${targetOdds.toStringAsFixed(2)}',
                    if (achieved != null) '${isFr ? "Obtenu" : "Got"} ×${achieved.toStringAsFixed(2)}',
                    if (gap != null) '${isFr ? "Écart" : "Gap"} ${gap.toStringAsFixed(2)} %',
                  ].join('   •   '),
                  style: const TextStyle(fontSize: 11.5, color: AppColors.muted, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickTile(Map<String, dynamic> p, bool isFr, {bool showCodeButton = true}) {
    final home = (p['home'] ?? '').toString();
    final away = (p['away'] ?? '').toString();
    final league = (p['league'] ?? '').toString();
    final sportName = (p['sport_name'] ?? '').toString();
    final market = (p['market_type'] ?? '').toString();
    final line = p['line'];
    final selName = (p['selection_name'] ?? '').toString();
    final odds = (p['odds'] is num) ? (p['odds'] as num).toDouble() : null;
    final prob = (p['probability_percent'] is num) ? (p['probability_percent'] as num).toInt() : null;
    final day = (p['day'] ?? '').toString();
    final isTomorrow = day == 'TOMORROW';
    final dayLabel = isTomorrow
        ? (isFr ? 'Demain' : 'Tomorrow')
        : day == 'TODAY'
            ? (isFr ? "Aujourd'hui" : 'Today')
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconBubble(
                icon: isTomorrow ? Icons.event_outlined : Icons.sports_soccer,
                color: isTomorrow ? AppColors.orange : AppColors.green,
                size: 34,
                iconSize: 16,
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
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.ink),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitleParts.join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: AppColors.muted, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      odds != null ? odds.toStringAsFixed(2) : '—',
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: Colors.white),
                    ),
                  ),
                  if (prob != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: StatusBadge(
                        text: '$prob %',
                        color: confidenceColor(prob),
                        icon: Icons.bolt,
                      ),
                    ),
                ],
              ),
            ],
          ),
          if (showCodeButton) ...[
            const SizedBox(height: 8),
            if (codeState?.code != null)
              Row(
                children: [
                  const Icon(Icons.confirmation_number, size: 15, color: AppColors.green),
                  const SizedBox(width: 6),
                  Text(
                    codeState!.code!,
                    style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2, fontSize: 14, color: AppColors.ink),
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
                children: [
                  Expanded(
                    child: Text(
                      codeState!.error!,
                      style: const TextStyle(fontSize: 10.5, color: AppColors.red, height: 1.3, fontWeight: FontWeight.w600),
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

  Future<void> _openMegaPari(String deepLink) async {
    final uri = Uri.tryParse(deepLink);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
      if (ok) return;
    } catch (_) {}
    await Clipboard.setData(ClipboardData(text: deepLink));
    _snack(_isFr ? 'Lien copié ✓' : 'Link copied ✓');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

/// Résultat d'un appel à `generate-combined`.
class _GenerateOutcome {
  final Map<String, dynamic>? result;
  final String? error;
  final int? retryAfter;

  const _GenerateOutcome({this.result, this.error, this.retryAfter});
}

class _PickCodeState {
  final String? code;
  final String? deepLink;
  final String? error;
  final bool loading;

  const _PickCodeState({this.code, this.deepLink, this.error, this.loading = false});
}
