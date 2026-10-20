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
/// L'utilisateur choisit le nombre de matchs et la côte totale visée ; le backend
/// compose le combiné à partir des Value Picks (marge <= 5 %) et renvoie le code
/// coupon MegaPari B2B + le deep link d'affiliation.
///
/// API : POST {base}/coupons/generate-combined
///       GET  {base}/coupons/value-picks/availability
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
  String? _error;
  String? _errorCode;
  Map<String, dynamic>? _result;

  /// Codes générés à la demande, par sélection (mode PER_PICK / NONE).
  final Map<String, _PickCodeState> _pickCodes = {};

  /// Disponibilité renvoyée par le backend (null = pas encore chargée).
  Map<String, dynamic>? _availability;
  bool _loadingAvailability = false;

  static const _matchPresets = <int>[2, 3, 5, 7, 10];

  /// Plafond réel imposé par le backend (MAX_COUPON_SELECTIONS), 10 par défaut.
  int get _maxMatches {
    final m = _availability?['max_matches'];
    if (m is int && m > 0) return m;
    return AppConfig.maxMatches;
  }
  static const _oddsPresets = <double>[2.0, 2.5, 5.0, 10.0, 25.0];

  @override
  void initState() {
    super.initState();
    _loadAvailability();
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

  Uri _uri(String path) => Uri.parse('${AppConfig.effectiveApiBase}$path');

  Future<void> _loadAvailability() async {
    setState(() => _loadingAvailability = true);
    try {
      final res = await http
          .get(_uri('/coupons/value-picks/availability'), headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body);
        if (data is Map<String, dynamic>) {
          setState(() {
            _availability = data;
            _loadingAvailability = false;
          });
          return;
        }
      }
      setState(() => _loadingAvailability = false);
    } catch (_) {
      if (mounted) setState(() => _loadingAvailability = false);
    }
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
    });

    try {
      final res = await http
          .post(
            _uri('/coupons/generate-combined'),
            headers: const {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({
              'num_matches': numMatches,
              'target_total_odds': targetOdds,
            }),
          )
          .timeout(const Duration(seconds: 45));

      final decoded = _safeDecode(res.body);

      if (res.statusCode >= 200 && res.statusCode < 300 && decoded is Map<String, dynamic>) {
        setState(() {
          _result = decoded;
          _loading = false;
        });
        // Erreur uniquement quand la création du coupon (mono-sélection) échoue :
        // en mode composition (N > 1) l'absence de code n'est pas une erreur.
        if (decoded['success'] == false && decoded['couponMode'] == 'SINGLE') {
          setState(() {
            _errorCode = 'B2B_UNAVAILABLE';
            _error = (decoded['message'] ?? 'Coupon non généré par MegaPari.').toString();
          });
        }
        return;
      }

      final code = _extractReasonCode(decoded);
      setState(() {
        _errorCode = code;
        _error = _humanError(code, decoded);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _errorCode = 'NETWORK';
        _error = 'Connexion impossible. Vérifie ta connexion puis réessaie.\n($e)';
        _loading = false;
      });
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
        return 'Aucune Value Pick disponible pour le moment (marge > ${_marginText()} %). '
            'Lance un scan des marchés, puis réessaie dans quelques minutes.';
      case 'NOT_ENOUGH_EVENTS':
        final d = (decoded is Map) ? decoded['details'] : null;
        final available = (d is Map ? d['available'] : null) ?? _availability?['events'] ?? '?';
        return 'Pas assez de matchs éligibles : $available disponibles. Réduis le nombre de matchs.';
      case 'TOO_MANY_MATCHES':
        final d = (decoded is Map) ? decoded['details'] : null;
        final max = (d is Map ? d['max'] : null) ?? AppConfig.maxMatches;
        return 'Nombre de matchs trop élevé (maximum $max par coupon).';
      case 'INVALID_TARGET_ODDS':
        return 'La côte totale visée doit être supérieure ou égale à 1.01.';
      case 'INVALID_NUM_MATCHES':
        return 'Le nombre de matchs doit être un entier supérieur ou égal à 1.';
      case 'B2B_RATE_LIMITED':
        final d = (decoded is Map) ? decoded['details'] : null;
        final retry = (d is Map && d['retry_after_seconds'] is num)
            ? (d['retry_after_seconds'] as num).toInt()
            : 90;
        return 'MegaPari limite temporairement la création de codes coupon. Réessaie dans $retry secondes.';
      case 'SELECTION_NOT_AVAILABLE':
        return 'Cette sélection n\'est plus disponible (cote changée ou marché fermé). Relance la composition.';
      case 'B2B_UNAVAILABLE':
      case 'B2B_COUPON_FAILED':
      case 'B2B_SHARECOUPON_ERROR':
        return 'La composition est prête mais MegaPari n\'a pas validé le coupon. '
            'Les cotes ont peut-être bougé : réessaie dans un instant.';
      case 'PROVIDER_NOT_SUPPORTED':
        return 'Seul MegaPari est disponible pour la génération de coupons.';
      default:
        if (decoded is Map && decoded['message'] is String) return decoded['message'] as String;
        return 'Une erreur est survenue lors de la génération du coupon.';
    }
  }

  String _marginText() {
    final m = _availability?['margin_threshold'];
    if (m is num) return m.toStringAsFixed(0);
    return '5';
  }

  // -------------------------------------------------------------- helpers ---

  static double _parseOdds(String raw) => double.parse(raw.trim().replaceAll(',', '.'));

  String get _hintPerMatch {
    final n = int.tryParse(_numCtrl.text.trim());
    final t = double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.'));
    if (n == null || n < 1 || t == null || t <= 0) return '—';
    return math.pow(t, 1 / n).toDouble().toStringAsFixed(2);
  }

  bool get _canGenerate {
    if (_loading) return false;
    final n = int.tryParse(_numCtrl.text.trim());
    final t = double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.'));
    if (n == null || n < AppConfig.minMatches || n > _maxMatches) return false;
    if (t == null || t < AppConfig.minOdds || t > AppConfig.maxOdds) return false;
    final available = _availability?['events'];
    if (available is int && available < n) return false;
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
            tooltip: isFr ? 'Actualiser la disponibilité' : 'Refresh availability',
            onPressed: _loadingAvailability ? null : _loadAvailability,
            icon: _loadingAvailability
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
                    ? 'Fail-Closed : si une cote est bloquée ou si la marge dépasse le seuil au moment de l\'envoi, aucun coupon n\'est généré.'
                    : 'Fail-Closed: if a market is suspended or the margin exceeds the threshold at sending time, no coupon is generated.',
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
    final events = _availability?['events'];
    final picks = _availability?['picks'];
    final maxMatches = _availability?['max_matches'] ?? AppConfig.maxMatches;

    final String text;
    final Color color;
    final IconData icon;

    if (_loadingAvailability) {
      text = isFr ? 'Analyse des marchés en cours…' : 'Scanning markets…';
      color = cs.primary;
      icon = Icons.hourglass_top;
    } else if (events is int) {
      if (events == 0) {
        text = isFr
            ? 'Aucun match éligible pour l\'instant (marge ≤ ${_marginText()} %).'
            : 'No eligible match right now (margin ≤ ${_marginText()} %).';
        color = Colors.orange;
        icon = Icons.info_outline;
      } else {
        text = isFr
            ? '$events matchs éligibles • $picks sélections value (max $maxMatches matchs/coupon)'
            : '$events eligible matches • $picks value selections (max $maxMatches matches/coupon)';
        color = Colors.green;
        icon = Icons.check_circle_outline;
      }
    } else {
      text = isFr ? 'Disponibilité indisponible — tu peux tout de même essayer.' : 'Availability unavailable — you can still try.';
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
            child: Text(text, style: TextStyle(fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
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

              // ---- Nombre de matchs ----
              TextFormField(
                controller: _numCtrl,
                focusNode: _numFocus,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                onFieldSubmitted: (_) => _oddsFocus.requestFocus(),
                decoration: _fieldDecoration(
                  label: isFr ? 'Nombre de matchs' : 'Number of matches',
                  hint: '3',
                  icon: Icons.sports_soccer,
                  helper: isFr ? 'Entre 1 et $_maxMatches matchs' : 'Between 1 and $_maxMatches',
                ),
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  if (n == null) return isFr ? 'Saisis un nombre' : 'Enter a number';
                  if (n < AppConfig.minMatches) return isFr ? 'Minimum ${AppConfig.minMatches}' : 'Min ${AppConfig.minMatches}';
                  if (n > _maxMatches) return isFr ? 'Maximum $_maxMatches' : 'Max $_maxMatches';
                  final available = _availability?['events'];
                  if (available is int && available > 0 && n > available) {
                    return isFr ? 'Seulement $available matchs disponibles' : 'Only $available matches available';
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
                  helper: isFr ? 'Cote par match estimée : $_hintPerMatch' : 'Estimated odds per match: $_hintPerMatch',
                  suffix: 'x',
                ),
                validator: (v) {
                  final d = double.tryParse((v ?? '').trim().replaceAll(',', '.'));
                  if (d == null) return isFr ? 'Saisis une cote' : 'Enter odds';
                  if (d < AppConfig.minOdds) return isFr ? 'Côte minimale ${AppConfig.minOdds}' : 'Min odds ${AppConfig.minOdds}';
                  if (d > AppConfig.maxOdds) return isFr ? 'Côte maximale ${AppConfig.maxOdds.toInt()}' : 'Max odds ${AppConfig.maxOdds.toInt()}';
                  return null;
                },
              ),
              const SizedBox(height: 10),
              _presetChips<double>(
                values: _oddsPresets,
                selected: double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.')),
                labelOf: (v) => '×${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2)}',
                onSelected: _setOdds,
              ),
              const SizedBox(height: 14),
              _summaryStrip(isFr, cs),
              const SizedBox(height: 16),

              // ---- CTA ----
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
                        ? (isFr ? 'Composition et envoi à MegaPari…' : 'Building and sending to MegaPari…')
                        : (isFr ? 'Générer le Code Coupon' : 'Generate Coupon Code'),
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
    final valid = n != null && t != null && t >= AppConfig.minOdds;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _miniStat(
              label: isFr ? 'Matchs' : 'Matches',
              value: valid ? '$n' : '—',
              cs: cs,
            ),
          ),
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

  /// Génère (à la demande) le code coupon d'une sélection.
  /// BetB2B ne sait créer qu'un coupon par marché : chaque sélection a donc
  /// son propre code, que l'on colle dans MegaPari avant de valider le combiné.
  Future<void> _fetchPickCode(String eventId, String selectionId) async {
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
        final link = decoded['deepLink']?.toString();
        setState(() => _pickCodes[key] = _PickCodeState(code: code, deepLink: link));
        if (code != null) {
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

  Widget _resultCard(bool isFr, ColorScheme cs) {
    final r = _result!;
    final label = (r['label'] ?? '').toString();
    final totalOdds = (r['totalOdds'] is num) ? (r['totalOdds'] as num).toDouble() : null;
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
                              if (totalOdds != null) '×${totalOdds.toStringAsFixed(2)}',
                              if (numMatches != null) '$numMatches ${isFr ? "matchs" : "matches"}',
                            ].join('  •  '),
                            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (picks.isEmpty)
                  Text(
                    isFr ? 'Aucune sélection détaillée.' : 'No detailed selection.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  )
                else
                  ...picks.map((p) => _pickTile(p as Map<String, dynamic>, cs, isFr: isFr)),
              ],
            ),
          ),
        ),
        if (couponCode != null && couponCode.isNotEmpty && deepLink != null) ...[
          const SizedBox(height: 14),
          CouponCodeCard(
            couponCode: couponCode,
            deepLink: deepLink,
            message: (r['message'] ?? '').toString().isNotEmpty
                ? r['message'].toString()
                : (isFr ? 'Coupon généré — colle ce code dans MegaPari' : 'Coupon generated — paste this code in MegaPari'),
            onOpen: () => _openMegaPari(deepLink),
          ),
          const SizedBox(height: 12),
          _howToCard(isFr),
        ] else if (couponMode != 'SINGLE') ...[
          const SizedBox(height: 14),
          _multiCouponNotice(isFr),
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

  Widget _pickTile(Map<String, dynamic> p, ColorScheme cs, {required bool isFr}) {
    final home = (p['home'] ?? '').toString();
    final away = (p['away'] ?? '').toString();
    final league = (p['league'] ?? '').toString();
    final market = (p['market_type'] ?? '').toString();
    final line = p['line'];
    final selName = (p['selection_name'] ?? '').toString();
    final odds = (p['odds'] is num) ? (p['odds'] as num).toDouble() : null;
    final margin = (p['margin_percent'] is num) ? (p['margin_percent'] as num).toDouble() : null;
    final eventId = (p['event_id'] ?? '').toString();
    final selectionId = (p['selection_id'] ?? '').toString();
    final key = '$eventId|$selectionId';
    final codeState = _pickCodes[key];

    final title = home.isNotEmpty || away.isNotEmpty ? '$home – $away' : '#$eventId';
    final subtitleParts = <String>[
      if (league.isNotEmpty) league,
      if (market.isNotEmpty) _marketLabel(market, line),
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
                decoration: BoxDecoration(color: Colors.green.withOpacity(0.12), shape: BoxShape.circle),
                child: const Icon(Icons.check, size: 15, color: Colors.green),
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
                  if (margin != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'marge ${margin.toStringAsFixed(1)}%',
                        style: TextStyle(fontSize: 9.5, color: Colors.grey[600]),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          // --- Code coupon de CETTE sélection (MegaPari : 1 code par marché) ---
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
      ),
    );
  }

  /// Note honnête sur la limite MegaPari : pas de code « combiné » côté B2B.
  Widget _multiCouponNotice(bool isFr) {
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
                ? 'MegaPari n\'autorise la création que d\'un code par marché. Compose ton combiné en ajoutant chaque sélection dans l\'app, ou utilise la cote et le libellé ci-dessus comme référence.'
                : 'MegaPari only lets us create one code per market. Build your accumulator by adding each selection in the app, or use the odds and label above as reference.',
            style: TextStyle(fontSize: 11.5, height: 1.35, color: Colors.grey[800]),
          ),
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
class _PickCodeState {
  final String? code;
  final String? deepLink;
  final String? error;
  final bool loading;

  const _PickCodeState({this.code, this.deepLink, this.error, this.loading = false});
}
