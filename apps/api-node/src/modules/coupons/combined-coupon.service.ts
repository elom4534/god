import { Injectable, BadRequestException, Logger } from '@nestjs/common';
import { createClient } from 'redis';
import { MegaPariCouponService, Pick } from '../bookmaker/megapari-coupon.service';

const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379';

let redisClient: any = null;
async function getRedis() {
  if (redisClient) return redisClient;
  try {
    redisClient = createClient({ url: REDIS_URL });
    redisClient.on('error', () => undefined);
    await redisClient.connect();
    return redisClient;
  } catch {
    return null;
  }
}

/** Une sélection exploitable pour un combiné (issue du cache Margin Guard). */
export interface ValuePick {
  event_id: string;
  market_id: string;
  selection_id: string;
  market_type: string;
  selection_name: string;
  tags: string[];
  line: number | null;
  odds: number;
  logOdds: number;
  margin_percent: number;
  home: string;
  away: string;
  league: string;
  sport: string;
  sport_id: number | null;
  sport_name: string;
  start_time: string | null;
  b2b_type: number;
  b2b_parameter: number | null;
}

export interface ComposeOptions {
  /** Identifiant du sport réel (répertoire bookmaker). null/undefined = tous. */
  sportId?: number | null;
  /** Nombre maximal d'événements lus dans le cache (garde-fou mémoire). */
  maxEvents?: number;
}

/** Mapping tag de sélection → type BetB2B (oddsLocalization.type). */
function resolveB2bType(marketType: string, tags: string[], name: string): number {
  const t = tags.map(x => String(x).toUpperCase());
  const up = (name || '').toUpperCase();
  const has = (tag: string) => t.includes(tag) || up === tag || up.includes(tag);

  switch (marketType) {
    case '1X2':
      if (has('HOME') || up === '1') return 1;
      if (has('DRAW') || up === 'X') return 2;
      if (has('AWAY') || up === '2') return 3;
      return 1;
    case 'DOUBLE_CHANCE':
      if (has('1X')) return 4;
      if (has('12')) return 5;
      if (has('X2')) return 6;
      return 4;
    case 'OVER_UNDER':
    case 'CORNERS_OU':
      if (has('OVER') || up.startsWith('OVER')) return 9;
      if (has('UNDER') || up.startsWith('UNDER')) return 10;
      return 9;
    case 'BTTS':
      if (has('YES')) return 15;
      if (has('NO')) return 16;
      return 15;
    case 'HANDICAP':
      if (has('AWAY')) return 8;
      return 7;
    default:
      return 1;
  }
}

@Injectable()
export class CombinedCouponService {
  private readonly logger = new Logger(CombinedCouponService.name);

  /** Garde-fou technique uniquement (protection mémoire) — pas une limite produit. */
  private readonly maxEventsScanned = parseInt(process.env.COUPON_MAX_EVENTS_SCANNED || '5000', 10);
  private readonly marginThreshold = parseFloat(process.env.MARGIN_THRESHOLD_PERCENT || '5');

  constructor(private mega: MegaPariCouponService) {}

  // ------------------------------------------------------------------ pool --

  /**
   * Charge TOUTES les sélections disponibles (tous les marchés validés de chaque
   * match), puis filtre éventuellement sur une discipline réelle.
   *
   * Source : cache Margin Guard (`megapari:event:*`, TTL 15 min) alimenté par l'ETL.
   */
  async loadValuePicks(sportId?: number | null, maxEvents?: number): Promise<ValuePick[]> {
    const r = await getRedis();
    if (!r) return [];

    const picks: ValuePick[] = [];
    const wantedSport = sportId !== undefined && sportId !== null ? Number(sportId) : null;
    const scanLimit = Math.max(1, Math.min(maxEvents ?? this.maxEventsScanned, this.maxEventsScanned));

    let keys: string[] = [];
    try {
      // SCAN (non bloquant) au lieu de KEYS : le cache peut contenir des milliers d'entrées.
      for await (const batch of r.scanIterator({ MATCH: 'megapari:event:*', COUNT: 500 })) {
        keys.push(...(Array.isArray(batch) ? batch : [batch]));
        if (keys.length >= scanLimit) break;
      }
    } catch {
      return [];
    }

    for (const key of keys) {
      let raw: string | null = null;
      try { raw = await r.get(key); } catch { continue; }
      if (!raw) continue;

      let data: any;
      try { data = JSON.parse(raw); } catch { continue; }

      const eventId = String(data.event_id || key.replace('megapari:event:', ''));
      if (!eventId || !/^\d+$/.test(eventId)) continue;

      const eventSportId =
        typeof data.sport_id === 'number' ? data.sport_id : (String(data.sport_id || '').match(/^\d+$/) ? Number(data.sport_id) : null);

      if (wantedSport !== null && eventSportId !== wantedSport) continue;

      const markets: any[] = Array.isArray(data.validated_markets) ? data.validated_markets : [];
      for (const vm of markets) {
        const margin = typeof vm.margin_percent === 'number' ? vm.margin_percent : null;
        if (margin === null || margin > this.marginThreshold) continue;

        const sels: any[] = Array.isArray(vm.selections) ? vm.selections : [];
        const internal: number[] = Array.isArray(vm._odds_internal) ? vm._odds_internal : [];

        sels.forEach((s: any, i: number) => {
          const odds = internal[i];
          if (typeof odds !== 'number' || !isFinite(odds) || odds <= 1.0) return;
          const tags: string[] = Array.isArray(s.tags) ? s.tags : [];
          const name = String(s.name || '');
          const line = vm.line !== undefined && vm.line !== null ? Number(vm.line) : null;
          const exactType = typeof s.b2b_type === 'number' ? s.b2b_type : null;
          const exactParam = typeof s.b2b_parameter === 'number' ? s.b2b_parameter : null;

          picks.push({
            event_id: eventId,
            market_id: String(vm.market_id),
            selection_id: String(s.selection_id),
            market_type: String(vm.market_type),
            selection_name: name,
            tags,
            line,
            odds,
            logOdds: Math.log(odds),
            margin_percent: margin,
            home: String(data.home_team || ''),
            away: String(data.away_team || ''),
            league: String(data.league || ''),
            sport: String(data.sport || 'football'),
            sport_id: eventSportId,
            sport_name: String(data.sport_name || ''),
            start_time: data.start_time ? String(data.start_time) : null,
            b2b_type: exactType ?? resolveB2bType(String(vm.market_type), tags, name),
            b2b_parameter: exactParam !== null
              ? exactParam
              : ((String(vm.market_type) === 'OVER_UNDER' || String(vm.market_type) === 'HANDICAP' || String(vm.market_type) === 'CORNERS_OU') ? line : null),
          });
        });
      }
    }
    return picks;
  }

  /** Sports réels proposés par le bookmaker, avec le nombre de matchs disponibles. */
  async getSports(language = 'en') {
    const [directory, pool] = await Promise.all([
      this.mega.getSportsDirectory(language).catch(() => [] as Array<{ id: number; name: string }>),
      this.loadValuePicks(),
    ]);

    const counts = new Map<number, { events: Set<string>; picks: number }>();
    for (const p of pool) {
      if (p.sport_id === null) continue;
      const entry = counts.get(p.sport_id) || { events: new Set<string>(), picks: 0 };
      entry.events.add(p.event_id);
      entry.picks += 1;
      counts.set(p.sport_id, entry);
    }

    // On expose tout le répertoire (l'utilisateur voit les disciplines réelles),
    // en signalant celles qui ont des marchés disponibles à cet instant.
    const sports = directory.map(s => {
      const c = counts.get(s.id);
      return {
        id: s.id,
        name: s.name,
        events: c ? c.events.size : 0,
        picks: c ? c.picks : 0,
        available: !!c && c.events.size > 0,
      };
    });

    // Sécurité : un sport présent dans le cache mais absent du répertoire
    // (réponse partielle) doit quand même apparaître.
    for (const [id, c] of counts.entries()) {
      if (!sports.some(s => s.id === id)) {
        const sample = pool.find(p => p.sport_id === id);
        sports.push({
          id,
          name: sample?.sport_name || `Sport ${id}`,
          events: c.events.size,
          picks: c.picks,
          available: true,
        });
      }
    }

    return {
      sports: sports.sort((a, b) => (b.events - a.events) || a.name.localeCompare(b.name)),
      total_events: new Set(pool.map(p => p.event_id)).size,
      total_picks: pool.length,
      margin_threshold: this.marginThreshold,
    };
  }

  // --------------------------------------------------------------- compose --

  /**
   * Compose un combiné de `numMatches` sélections (1 par match) dont le produit
   * des cotes est aussi proche que possible de `targetTotalOdds`.
   *
   * Aucune limite produit sur N ni sur la cote : seul le nombre de matchs
   * réellement disponibles contraint le résultat.
   *
   * Algorithme (espace logarithmique, car ln(a·b) = ln a + ln b) :
   *   1. Pour chaque match, on considère TOUTES ses sélections (tous marchés).
   *   2. Initialisation : on retient les N matchs dont la meilleure sélection
   *      est la plus proche de la cote cible par match (target^(1/N)).
   *   3. Amélioration : à chaque passe, pour chaque position on calcule la
   *      cote idéale `cote_actuelle × (cible / produit_actuel)`, puis on
   *      cherche par dichotomie la sélection la plus proche de cette cote
   *      (autre marché du même match, ou match non utilisé). On garde le
   *      remplacement qui minimise l'écart final.
   *   4. On répète jusqu'à stabilité (ou exactitude atteinte).
   */
  async compose(
    numMatches: number,
    targetTotalOdds: number,
    options: ComposeOptions = {},
  ): Promise<{
    picks: ValuePick[];
    totalOdds: number;
    targetTotalOdds: number;
    gapPercent: number;
    exact: boolean;
    candidatesEvaluated: number;
  }> {
    const n = Number(numMatches);
    const target = Number(targetTotalOdds);

    if (!Number.isFinite(n) || !Number.isInteger(n) || n < 1) {
      throw new BadRequestException({
        error: 'INVALID_INPUT',
        reason_code: 'INVALID_NUM_MATCHES',
        message: 'Le nombre de matchs doit être un entier supérieur ou égal à 1.',
      });
    }
    if (!Number.isFinite(target) || target < 1.01) {
      throw new BadRequestException({
        error: 'INVALID_INPUT',
        reason_code: 'INVALID_TARGET_ODDS',
        message: 'La côte totale visée doit être supérieure ou égale à 1.01.',
      });
    }

    const pool = await this.loadValuePicks(options.sportId ?? null);
    if (pool.length === 0) {
      throw new BadRequestException({
        error: 'NO_VALUE_PICKS',
        reason_code: 'NO_VALUE_PICKS',
        message: options.sportId
          ? 'Aucune Value Pick disponible pour cette discipline (marge au-dessus du seuil ou aucun match à venir).'
          : 'Aucune Value Pick disponible (cache MegaPari vide ou marge au-dessus du seuil). Lance un scan puis réessaie.',
      });
    }

    // 1 sélection par match : on indexe toutes les sélections par événement.
    const byEvent = new Map<string, ValuePick[]>();
    for (const p of pool) {
      const arr = byEvent.get(p.event_id) || [];
      arr.push(p);
      byEvent.set(p.event_id, arr);
    }
    const events = [...byEvent.keys()];
    if (events.length < n) {
      throw new BadRequestException({
        error: 'NOT_ENOUGH_EVENTS',
        reason_code: 'NOT_ENOUGH_EVENTS',
        message: `Seulement ${events.length} match(s) disponible(s) pour cette sélection : réduis le nombre de matchs ou choisis « Tous les sports ».`,
        details: { available: events.length, requested: n },
      });
    }

    const logTarget = Math.log(target);
    const perSlot = logTarget / n;

    // Sélections triées par cote croissante (pour la recherche par dichotomie).
    for (const list of byEvent.values()) list.sort((a, b) => a.odds - b.odds);

    // --- 2. Initialisation : meilleure sélection par match, matchs les mieux placés
    const scored = events
      .map(eventId => {
        const sels = byEvent.get(eventId)!;
        let best = sels[0];
        let bestDiff = Math.abs(best.logOdds - perSlot);
        for (const s of sels) {
          const d = Math.abs(s.logOdds - perSlot);
          if (d < bestDiff) { best = s; bestDiff = d; }
        }
        return { eventId, best, bestDiff, sels };
      })
      .sort((a, b) => (a.bestDiff - b.bestDiff) || (a.best.margin_percent - b.best.margin_percent));

    const chosen: ValuePick[] = scored.slice(0, n).map(c => c.best);
    const usedEvents = new Set(chosen.map(p => p.event_id));
    const spareEvents = scored.slice(n).map(c => c.eventId);

    const sumLog = (list: ValuePick[]) => list.reduce((acc, p) => acc + p.logOdds, 0);
    const gapOf = (list: ValuePick[]) => Math.abs(sumLog(list) - logTarget);

    let currentGap = gapOf(chosen);
    let evaluations = scored.reduce((acc, c) => acc + c.sels.length, 0);

    /** Sélection d'un événement dont la cote est la plus proche d'une cote idéale. */
    const closestIn = (list: ValuePick[], ideal: number): ValuePick => {
      // list triée par cote croissante → dichotomie
      let lo = 0;
      let hi = list.length - 1;
      while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (list[mid].odds < ideal) lo = mid + 1; else hi = mid;
      }
      const candidates = [list[lo], list[Math.max(0, lo - 1)]];
      return candidates.reduce((a, b) => (Math.abs(a.odds - ideal) <= Math.abs(b.odds - ideal) ? a : b));
    };

    // --- 3. Amélioration locale par coordonnée
    const maxPasses = Math.min(60, Math.max(12, n * 4));
    for (let pass = 0; pass < maxPasses && currentGap > 1e-9; pass++) {
      const total = sumLog(chosen);
      // Cote idéale pour la position i : celle qui annule l'écart restant.
      const residual = logTarget - total;
      let improved = false;

      for (let i = 0; i < chosen.length; i++) {
        const current = chosen[i];
        const idealOdds = current.odds * Math.exp(residual);
        let best: ValuePick | null = null;
        let bestGap = currentGap;

        // (a) autres marchés du même match
        const sameEvent = byEvent.get(current.event_id) || [];
        if (sameEvent.length > 1) {
          const cand = closestIn(sameEvent, idealOdds);
          evaluations += 1;
          if (cand.selection_id !== current.selection_id) {
            const trial = chosen.slice();
            trial[i] = cand;
            const g = gapOf(trial);
            if (g < bestGap - 1e-12) { bestGap = g; best = cand; }
          }
        }

        // (b) matchs non utilisés : on prend leur sélection la plus proche de l'idéal
        for (const eventId of spareEvents) {
          if (usedEvents.has(eventId)) continue;
          const cand = closestIn(byEvent.get(eventId)!, idealOdds);
          evaluations += 1;
          const trial = chosen.slice();
          trial[i] = cand;
          const g = gapOf(trial);
          if (g < bestGap - 1e-12) { bestGap = g; best = cand; }
        }

        if (best) {
          chosen[i] = best;
          currentGap = bestGap;
          improved = true;
          break; // on recalcule le résidu avant la position suivante
        }
      }

      if (!improved) {
        // --- 4. Sortie de blocage : échange de deux positions
        let paired = false;
        outer:
        for (let i = 0; i < chosen.length && !paired; i++) {
          const residualI = logTarget - sumLog(chosen);
          const idealI = chosen[i].odds * Math.exp(residualI);
          for (let j = 0; j < chosen.length; j++) {
            if (i === j) continue;
            const residualJ = logTarget - sumLog(chosen);
            const idealJ = chosen[j].odds * Math.exp(residualJ);
            const poolI = byEvent.get(chosen[i].event_id)!;
            const poolJ = byEvent.get(chosen[j].event_id)!;
            const ci = closestIn(poolI, idealI);
            const cj = closestIn(poolJ, idealJ);
            if (ci.selection_id === chosen[i].selection_id && cj.selection_id === chosen[j].selection_id) continue;
            const trial = chosen.slice();
            trial[i] = ci;
            trial[j] = cj;
            evaluations += 2;
            const g = gapOf(trial);
            if (g < currentGap - 1e-12) {
              chosen[i] = ci;
              chosen[j] = cj;
              currentGap = g;
              paired = true;
              break outer;
            }
          }
        }
        if (!paired) break;
      }
    }

    const totalOdds = chosen.reduce((acc, p) => acc * p.odds, 1);
    const rounded = Math.round(totalOdds * 100) / 100;
    const targetRounded = Math.round(target * 100) / 100;
    const gapPercent = Math.abs(totalOdds - target) / target * 100;

    return {
      picks: chosen.sort((a, b) => a.start_time && b.start_time ? a.start_time.localeCompare(b.start_time) : a.odds - b.odds),
      totalOdds: rounded,
      targetTotalOdds: targetRounded,
      gapPercent: Math.round(gapPercent * 100) / 100,
      // « exact » = la cote affichée (2 décimales) est identique à la cible affichée.
      exact: Math.abs(rounded - targetRounded) < 0.005,
      candidatesEvaluated: evaluations,
    };
  }

  // ------------------------------------------------------------ génération --

  /**
   * Compose le combiné puis gère la création des codes coupon.
   *
   * MegaPari B2B n'accepte qu'un marché par coupon : on génère donc les codes
   * sélection par sélection (à la demande côté client), jamais un faux combiné.
   */
  async generateCombined(
    numMatches: number,
    targetTotalOdds: number,
    currency?: string,
    language?: string,
    sportId?: number | null,
    includeIndividualCodes = false,
  ) {
    const composed = await this.compose(numMatches, targetTotalOdds, { sportId });
    const picks = composed.picks;

    const label = `Combiné ${picks.length} matchs - Côte ${composed.totalOdds.toFixed(2)}`;
    const sports = [...new Set(picks.map(p => p.sport_name).filter(Boolean))];

    const b2bPicks: Pick[] = picks.map(p => ({
      event_id: p.event_id,
      market_id: p.market_id,
      selection_id: p.selection_id,
      market_type: p.market_type,
      line: p.line,
      sportEventId: parseInt(p.event_id, 10),
      b2b_type: p.b2b_type,
      b2b_oddsMarket: p.odds,
      b2b_parameter: p.b2b_parameter ?? undefined,
      b2b_kind: 3,
      b2b_lng: language || 'en',
    }));

    let couponMode: 'SINGLE' | 'PER_PICK' | 'NONE' = 'NONE';
    let couponCode: string | null = null;
    let deepLink: string | null = process.env.MEGAPARI_AFFILIATE_URL || 'https://megapari.com/en';
    let message = 'Composition prête — ouvre MegaPari et ajoute les sélections.';
    let success = true;
    const coupons: Array<{
      event_id: string;
      home: string;
      away: string;
      selection_name: string;
      market_type: string;
      line: number | null;
      odds: number;
      success: boolean;
      couponCode: string | null;
      deepLink: string | null;
      error: string | null;
    }> = [];

    if (b2bPicks.length === 1 || includeIndividualCodes) {
      if (b2bPicks.length === 1) {
        try {
          const res = await this.mega.generateCoupon(b2bPicks, { currency, language });
          couponMode = 'SINGLE';
          couponCode = res.couponCode;
          deepLink = res.deepLink;
          message = res.message;
          coupons.push({
            event_id: picks[0].event_id,
            home: picks[0].home,
            away: picks[0].away,
            selection_name: picks[0].selection_name,
            market_type: picks[0].market_type,
            line: picks[0].line,
            odds: picks[0].odds,
            success: true,
            couponCode: res.couponCode,
            deepLink: res.deepLink,
            error: null,
          });
        } catch (e: any) {
          const body = e?.getResponse?.() ?? e?.response?.data ?? null;
          success = false;
          message = body?.message || e?.message || 'Échec de la génération du coupon MegaPari';
        }
      } else {
        const results = await this.mega.generateSeparateCoupons(b2bPicks, { currency, language });
        couponMode = 'PER_PICK';
        let ok = 0;
        results.forEach((r, i) => {
          const p = picks[i];
          if (r.success) ok++;
          coupons.push({
            event_id: p.event_id,
            home: p.home,
            away: p.away,
            selection_name: p.selection_name,
            market_type: p.market_type,
            line: p.line,
            odds: p.odds,
            success: r.success,
            couponCode: r.couponCode,
            deepLink: r.deepLink,
            error: r.error,
          });
        });
        success = ok > 0;
        message = ok === picks.length
          ? `${ok} codes générés — un par sélection : ajoute-les à ton coupon MegaPari.`
          : `${ok}/${picks.length} codes générés — certains marchés ne sont plus disponibles.`;
      }
    }

    this.logger.log(JSON.stringify({
      level: 'audit',
      action: 'coupons/generate-combined',
      numMatches: picks.length,
      targetTotalOdds: composed.targetTotalOdds,
      achievedTotalOdds: composed.totalOdds,
      gapPercent: composed.gapPercent,
      exact: composed.exact,
      sportId: sportId ?? null,
      sports,
      couponMode,
      couponCode,
      success,
    }));

    return {
      success,
      couponMode,
      label,
      // cible demandée vs cote réellement atteinte
      targetTotalOdds: composed.targetTotalOdds,
      totalOdds: composed.totalOdds,
      gapPercent: composed.gapPercent,
      exact: composed.exact,
      numMatches: picks.length,
      sport: sportId ?? null,
      sports,
      couponCode,
      deepLink,
      message,
      coupons,
      picks: picks.map(p => ({
        event_id: p.event_id,
        home: p.home,
        away: p.away,
        league: p.league,
        sport: p.sport,
        sport_id: p.sport_id,
        sport_name: p.sport_name,
        start_time: p.start_time,
        market_type: p.market_type,
        market_id: p.market_id,
        selection_id: p.selection_id,
        selection_name: p.selection_name,
        line: p.line,
        odds: p.odds,
        margin_percent: p.margin_percent,
      })),
    };
  }

  /**
   * Génère le code coupon d'UNE sélection de la composition (mode PER_PICK).
   */
  async generatePickCode(eventId: string, selectionId: string, language?: string) {
    if (!eventId || !selectionId) {
      throw new BadRequestException({
        error: 'INVALID_INPUT',
        reason_code: 'MISSING_SELECTION',
        message: 'event_id et selection_id sont requis',
      });
    }

    const picks = await this.loadValuePicks();
    const pick = picks.find(p => p.event_id === String(eventId) && p.selection_id === String(selectionId));
    if (!pick) {
      throw new BadRequestException({
        error: 'SELECTION_NOT_AVAILABLE',
        reason_code: 'SELECTION_NOT_AVAILABLE',
        message: 'Cette sélection n\'est plus disponible (cote changée ou marché fermé). Relance la composition.',
      });
    }

    const b2bPick: Pick = {
      event_id: pick.event_id,
      market_id: pick.market_id,
      selection_id: pick.selection_id,
      market_type: pick.market_type,
      line: pick.line,
      sportEventId: parseInt(pick.event_id, 10),
      b2b_type: pick.b2b_type,
      b2b_oddsMarket: pick.odds,
      b2b_parameter: pick.b2b_parameter ?? undefined,
      b2b_kind: 3,
      b2b_lng: language || 'en',
    };

    try {
      const res = await this.mega.generateCoupon([b2bPick], { language });
      return {
        success: true,
        couponCode: res.couponCode,
        deepLink: res.deepLink,
        message: res.message,
        event_id: pick.event_id,
        selection_id: pick.selection_id,
        home: pick.home,
        away: pick.away,
        selection_name: pick.selection_name,
        odds: pick.odds,
      };
    } catch (e: any) {
      const body = e?.getResponse?.() ?? e?.response?.data ?? null;
      const reason = typeof body?.reason_code === 'string' ? body.reason_code : 'B2B_COUPON_FAILED';
      const msg = body?.message || e?.message || 'Échec MegaPari';
      throw new BadRequestException({
        error: 'B2B_COUPON_FAILED',
        reason_code: reason,
        message: String(msg).slice(0, 400),
        details: { ...(body?.details || {}), event_id: pick.event_id, selection_id: pick.selection_id },
      });
    }
  }
}
