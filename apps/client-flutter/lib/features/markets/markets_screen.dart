import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/real_feed.dart';
import '../../core/services/api_service.dart';
import '../../core/services/coupon_history_store.dart';
import '../../core/services/feed_controller.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/glass_container.dart';
import '../../shared/widgets/glowing_confidence_ring.dart';
import '../../shared/widgets/live_odds_badge.dart';
import '../match_detail/match_detail_panel.dart';

/// Marchés — générateur de combiné sur mesure (moteur 100 % réel).
///
/// POST /coupons/generate-combined → composition temps réel
/// POST /coupons/pick-code         → un code MegaPari par sélection
class MarketsScreen extends StatefulWidget {
  const MarketsScreen({super.key, required this.feed});
  final FeedController feed;

  @override
  State<MarketsScreen> createState() => _MarketsScreenState();
}

class _MarketsScreenState extends State<MarketsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _numCtrl = TextEditingController(text: '3');
  final _oddsCtrl = TextEditingController(text: '2.5');
  final _stakeCtrl = TextEditingController(text: '1000');

  bool _loading = false;
  String? _progress;
  String? _error;
  Map<String, dynamic>? _result;
  final Map<String, _PickCodeState> _pickCodes = {};
  bool _bulkRunning = false;

  int _maxMatches = 50;
  int? _availableEvents;

  static const _matchPresets = <int>[2, 3, 5, 7, 10];
  static const _oddsPresets = <double>[2.0, 2.5, 5.0, 10.0, 25.0, 50.0];

  @override
  void initState() {
    super.initState();
    _loadBounds();
  }

  @override
  void dispose() {
    _numCtrl.dispose();
    _oddsCtrl.dispose();
    _stakeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBounds() async {
    try {
      final w = await ApiService.window();
      if (!mounted) return;
      setState(() {
        _maxMatches = math.min(50, math.max(1, w.maxMatches));
        _availableEvents = w.todayEvents + w.tomorrowEvents;
      });
    } catch (_) {}
  }

  // ------------------------------------------------------------- actions --

  Future<void> _generate() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final n = int.parse(_numCtrl.text.trim());
    final t = double.parse(_oddsCtrl.text.trim().replaceAll(',', '.'));

    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _pickCodes.clear();
      _progress = null;
    });

    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final d = await ApiService.generateCombined(numMatches: n, targetTotalOdds: t);
        if (!mounted) return;
        if (d['success'] == false) {
          final ra = int.tryParse('${d['retry_after_seconds'] ?? ''}');
          if (ra != null && attempt < maxAttempts && ra <= 120) {
            for (var remaining = ra; remaining > 0 && mounted; remaining--) {
              setState(() => _progress = 'Nouvelle tentative dans $remaining s…');
              await Future.delayed(const Duration(seconds: 1));
            }
            continue;
          }
        }
        setState(() {
          _loading = false;
          _progress = null;
          _result = d;
        });
        _saveHistory(d, n, t);
        return;
      } on ApiException catch (e) {
        if (e.retryAfter != null && attempt < maxAttempts && e.retryAfter! <= 120) {
          for (var remaining = e.retryAfter!; remaining > 0 && mounted; remaining--) {
            setState(() => _progress = 'Nouvelle tentative dans $remaining s…');
            await Future.delayed(const Duration(seconds: 1));
          }
          continue;
        }
        if (!mounted) return;
        setState(() {
          _loading = false;
          _progress = null;
          _error = _shortError(e);
        });
        return;
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Connexion impossible. Réessaie.';
        });
        return;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  String _shortError(ApiException e) {
    final max = e.maxReachableOdds;
    final suggested = e.suggestedMatches;
    if (e.code.startsWith('TARGET_UNREACHABLE')) {
      return 'Cette côte est trop haute pour ce nombre de matchs.'
          '${max != null ? " Maximum : ×${max.toStringAsFixed(2)}." : ""}'
          '${suggested != null ? " Essaie $suggested matchs." : ""}';
    }
    if (e.code == 'NOT_ENOUGH_EVENTS') {
      return 'Seulement ${e.available ?? '?'} matchs disponibles. Réduis le nombre de matchs.';
    }
    return e.userMessage;
  }

  Future<void> _saveHistory(Map<String, dynamic> d, int n, double target) async {
    final codes = <String>[];
    if (d['couponCode'] != null && '${d['couponCode']}'.isNotEmpty) codes.add('${d['couponCode']}');
    await CouponHistoryStore.add(CouponRecord(
      createdAt: DateTime.now(),
      numMatches: (d['numMatches'] as num?)?.toInt() ?? n,
      totalOdds: (d['totalOdds'] as num?)?.toDouble() ?? 0,
      targetOdds: target,
      codes: codes,
      scopeLabel: '${d['day_scope'] ?? ''}',
      dayToday: ((d['day_summary'] is Map ? (d['day_summary'] as Map)['today'] : null) as num?)?.toInt() ?? 0,
      dayTomorrow: ((d['day_summary'] is Map ? (d['day_summary'] as Map)['tomorrow'] : null) as num?)?.toInt() ?? 0,
    ));
  }

  Future<void> _fetchPickCode(String eventId, String selectionId, {bool silent = false}) async {
    final key = '$eventId|$selectionId';
    if (_pickCodes[key]?.loading == true) return;
    setState(() => _pickCodes[key] = const _PickCodeState(loading: true));
    try {
      final d = await ApiService.pickCode(eventId: eventId, selectionId: selectionId);
      final code = d['couponCode']?.toString();
      setState(() => _pickCodes[key] = _PickCodeState(code: code, deepLink: d['deepLink']?.toString()));
      if (code != null && !silent) {
        await Clipboard.setData(ClipboardData(text: code));
        _snack('Code $code copié ✓');
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _pickCodes[key] = _PickCodeState(error: e.userMessage));
    } catch (_) {
      if (mounted) {
        setState(() => _pickCodes[key] = const _PickCodeState(error: 'Connexion impossible — réessaie.'));
      }
    }
  }

  Future<void> _fetchAllPickCodes(List<dynamic> picks) async {
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
      if (mounted) _snack('Codes générés ✓');
    } finally {
      if (mounted) setState(() => _bulkRunning = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ----------------------------------------------------------------- UI ---

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Combiné sur mesure', style: AppFonts.title(size: 19, weight: FontWeight.w800)),
          Text('Cotes relues en direct chez MegaPari', style: AppFonts.caption(size: 10.5)),
          const SizedBox(height: 14),
          _formCard(p),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _errorBanner(p),
          ],
          if (_result != null) ...[
            const SizedBox(height: 16),
            _resultCard(p),
          ],
          SizedBox(height: MediaQuery.of(context).size.width < 768 ? 100 : 24),
        ],
      ),
    );
  }

  Widget _formCard(AppPalette p) {
    return GlassContainer(
      padding: const EdgeInsets.all(18),
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: p.cyan.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.tune, size: 18, color: p.cyan),
                ),
                const SizedBox(width: 11),
                Text('Configuration', style: AppFonts.title(size: 15, weight: FontWeight.w800)),
                const Spacer(),
                if (_availableEvents != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: p.emerald.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      '$_availableEvents matchs',
                      style: AppFonts.num(size: 10.5, weight: FontWeight.w700, color: p.emerald),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _numCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              style: AppFonts.num(size: 16, weight: FontWeight.w700),
              decoration: InputDecoration(
                labelText: 'Nombre de matchs',
                prefixIcon: const Icon(Icons.sports_soccer, size: 19),
                helperText: '1 à $_maxMatches matchs',
              ),
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                if (n == null || n < 1) return 'Au moins 1 match';
                if (n > _maxMatches) return 'Maximum $_maxMatches matchs';
                return null;
              },
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _matchPresets
                  .map((v) => _pill('$v', int.tryParse(_numCtrl.text.trim()) == v, p.cyan, () {
                        setState(() => _numCtrl.text = '$v');
                      }))
                  .toList(),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _oddsCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              onChanged: (_) => setState(() {}),
              onFieldSubmitted: (_) => _generate(),
              style: AppFonts.num(size: 16, weight: FontWeight.w700),
              decoration: InputDecoration(
                labelText: 'Côte totale visée',
                prefixIcon: const Icon(Icons.trending_up, size: 19),
                suffixText: 'x',
                helperText: 'Cote moyenne par match : ×$_hintPerMatch',
              ),
              validator: (v) {
                final d = double.tryParse((v ?? '').trim().replaceAll(',', '.'));
                if (d == null || !d.isFinite || d < 1.01) return 'Côte minimale 1.01';
                return null;
              },
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _oddsPresets
                  .map((v) => _pill(
                        '×${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}',
                        double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.')) == v,
                        p.amber,
                        () => setState(() => _oddsCtrl.text = v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v'),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 14),
            _summaryStrip(p),
            const SizedBox(height: 16),
            SizedBox(
              height: 54,
              child: FilledButton.icon(
                onPressed: _loading ? null : _generate,
                icon: _loading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                    : const Icon(Icons.auto_awesome),
                label: Text(
                  _loading ? (_progress ?? 'Recherche de la meilleure combinaison…') : 'Générer le code coupon',
                  textAlign: TextAlign.center,
                  style: AppFonts.label(size: 15, weight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String label, bool selected, Color color, VoidCallback onTap) {
    final p = context.palette;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? color.withOpacity(0.65) : p.glassBorder),
        ),
        child: Text(
          label,
          style: AppFonts.num(
            size: 12,
            weight: FontWeight.w700,
            color: selected ? color : p.textSoft,
          ),
        ),
      ),
    );
  }

  String get _hintPerMatch {
    final n = int.tryParse(_numCtrl.text.trim());
    final t = double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.'));
    if (n == null || n < 1 || t == null || t <= 0) return '—';
    final per = math.pow(t, 1 / n).toDouble();
    return per.isFinite ? per.toStringAsFixed(2) : '—';
  }

  Widget _summaryStrip(AppPalette p) {
    final n = int.tryParse(_numCtrl.text.trim());
    final t = double.tryParse(_oddsCtrl.text.trim().replaceAll(',', '.'));
    final valid = n != null && t != null && t >= 1.01;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: p.cyan.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.glassBorder),
      ),
      child: Row(
        children: [
          Expanded(child: _mini(p, valid ? '$n' : '—', 'Matchs', p.textStrong)),
          Container(width: 1, height: 30, color: p.glassBorder),
          Expanded(child: _mini(p, valid ? '×${t.toStringAsFixed(2)}' : '—', 'Côte visée', p.amber)),
          Container(width: 1, height: 30, color: p.glassBorder),
          Expanded(child: _mini(p, '×$_hintPerMatch', 'Cote / match', p.emerald)),
        ],
      ),
    );
  }

  Widget _mini(AppPalette p, String value, String label, Color color) {
    return Column(
      children: [
        Text(value, style: AppFonts.num(size: 17, weight: FontWeight.w800, color: color)),
        const SizedBox(height: 2),
        Text(label, style: AppFonts.caption(size: 9.5)),
      ],
    );
  }

  Widget _errorBanner(AppPalette p) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.carmin.withOpacity(0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.carmin.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: p.carmin, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              style: AppFonts.label(size: 12.5, weight: FontWeight.w600, color: p.carmin),
            ),
          ),
          IconButton(
            tooltip: 'Réessayer',
            onPressed: _loading ? null : _generate,
            icon: Icon(Icons.refresh, color: p.carmin, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(AppPalette p) {
    final r = _result!;
    final picks = (r['picks'] is List) ? r['picks'] as List : const [];
    final totalOdds = (r['totalOdds'] as num?)?.toDouble();
    final target = (r['targetTotalOdds'] as num?)?.toDouble();
    final gap = (r['gapPercent'] as num?)?.toDouble();
    final exact = r['exact'] == true;
    final n = (r['numMatches'] as num?)?.toInt() ?? picks.length;
    final couponCode = r['couponCode']?.toString();
    final deepLink = r['deepLink']?.toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassContainer(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: p.emerald.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.check_circle_outline, size: 18, color: p.emerald),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Combiné composé', style: AppFonts.title(size: 15, weight: FontWeight.w800)),
                        Text(
                          '$n matchs  •  ${totalOdds != null ? '×${totalOdds.toStringAsFixed(2)}' : '—'}',
                          style: AppFonts.caption(size: 11),
                        ),
                      ],
                    ),
                  ),
                  GlowingConfidenceRing(
                    value: exact || (gap != null && gap <= 1) ? 1 : 0.72,
                    size: 52,
                    centerText: exact ? 'OK' : '${gap?.toStringAsFixed(0) ?? ''}%',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _targetStrip(p, target: target, achieved: totalOdds, gap: gap, exact: exact),
              if (couponCode != null && couponCode.isNotEmpty) ...[
                const SizedBox(height: 12),
                _codeCard(p, couponCode, deepLink),
              ],
              const SizedBox(height: 12),
              ...picks.map((raw) {
                final pick = RealPick.fromApi(Map<String, dynamic>.from(raw as Map));
                return _pickTile(p, pick);
              }),
            ],
          ),
        ),
        if (couponCode == null || couponCode.isEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: _bulkRunning ? null : () => _fetchAllPickCodes(picks),
              icon: _bulkRunning
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.qr_code_2),
              label: Text(
                _bulkRunning ? 'Génération des codes…' : 'Générer les ${picks.length} codes',
                style: AppFonts.label(size: 14.5, weight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _targetStrip(AppPalette p, {double? target, double? achieved, double? gap, required bool exact}) {
    final color = exact || (gap != null && gap <= 1.0) ? p.emerald : p.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(exact ? Icons.check_circle : Icons.adjust, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              [
                if (target != null) 'Visé ×${target.toStringAsFixed(2)}',
                if (achieved != null) 'Obtenu ×${achieved.toStringAsFixed(2)}',
                if (gap != null) 'Écart ${gap.toStringAsFixed(2)} %',
              ].join('   •   '),
              style: AppFonts.num(size: 11.5, weight: FontWeight.w700, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _codeCard(AppPalette p, String code, String? deepLink) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.emerald.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.emerald.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.confirmation_number, color: p.emerald, size: 19),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              code,
              style: AppFonts.num(size: 22, weight: FontWeight.w900, color: p.textStrong, letterSpacing: 3),
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              _snack('Code $code copié ✓');
            },
            icon: const Icon(Icons.copy, size: 15),
            label: const Text('Copier'),
          ),
        ],
      ),
    );
  }

  Widget _pickTile(AppPalette p, RealPick pick) {
    final key = '${pick.eventId}|${pick.selectionId}';
    final codeState = _pickCodes[key];
    final color = p.confidence(pick.probabilityPercent / 100);
    return GestureDetector(
      onTap: () {
        widget.feed.selected.value = pick;
        MatchDetailPanel.open(context, pick);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: p.cyan.withOpacity(0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.glassBorder),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(pick.matchup,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.label(size: 12.5, weight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(
                        '${pick.isTomorrow ? 'Demain' : "Aujourd'hui"} · ${pick.marketLabel} · ${pick.selectionName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.caption(size: 10.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    LiveOddsBadge(odds: pick.odds, size: 12),
                    const SizedBox(height: 4),
                    Text('${pick.probabilityPercent} %',
                        style: AppFonts.num(size: 10.5, weight: FontWeight.w800, color: color)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (codeState?.code != null)
              Row(
                children: [
                  Icon(Icons.confirmation_number, size: 15, color: p.emerald),
                  const SizedBox(width: 6),
                  Text(codeState!.code!,
                      style: AppFonts.num(size: 14, weight: FontWeight.w800, color: p.textStrong, letterSpacing: 2)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: codeState.code!));
                      _snack('Code copié ✓');
                    },
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Copier'),
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
                    child: Text(codeState!.error!,
                        style: AppFonts.caption(size: 10.5, color: p.carmin)),
                  ),
                  TextButton(
                    onPressed: () => _fetchPickCode(pick.eventId, pick.selectionId),
                    child: const Text('Réessayer'),
                  ),
                ],
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: codeState?.loading == true
                      ? null
                      : () => _fetchPickCode(pick.eventId, pick.selectionId),
                  icon: codeState?.loading == true
                      ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.qr_code_2, size: 15),
                  label: Text(codeState?.loading == true ? 'Génération…' : 'Obtenir le code'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PickCodeState {
  const _PickCodeState({this.code, this.deepLink, this.error, this.loading = false});
  final String? code;
  final String? deepLink;
  final String? error;
  final bool loading;
}
