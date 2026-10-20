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
  margin_percent: number;
  home: string;
  away: string;
  league: string;
  sport: string;
  start_time: string | null;
  b2b_type: number;
  b2b_parameter: number | null;
}

/** Mapping tag de sélection → type BetB2B (oddsLocalization.type). */
function resolveB2bType(marketType: string, tags: string[], name: string): number {
  const t = tags.map(x => String(x).toUpperCase());
  const up = (name || '').toUpperCase();
  const has = (tag: string) => t.includes(tag) || up === tag || up.includes(tag);

  switch (marketType) {
    case '1X2':
      if (has('HOME') || up === '1') return 1;   // W1
      if (has('DRAW') || up === 'X') return 2;   // X
      if (has('AWAY') || up === '2') return 3;   // W2
      return 1;
    case 'DOUBLE_CHANCE':
      if (has('1X')) return 4;
      if (has('12')) return 5;
      if (has('X2')) return 6;
      return 4;
    case 'OVER_UNDER':
    case 'CORNERS_OU':
      if (has('OVER') || up.startsWith('OVER')) return 9;   // Total Over
      if (has('UNDER') || up.startsWith('UNDER')) return 10; // Total Under
      return 9;
    case 'BTTS':
      if (has('YES')) return 15;
      if (has('NO')) return 16;
      return 15;
    case 'HANDICAP':
      if (has('HOME') || up.includes('1')) return 7;
      if (has('AWAY') || up.includes('2')) return 8;
      return 7;
    default:
      return 1;
  }
}

@Injectable()
export class CombinedCouponService {
  private readonly logger = new Logger(CombinedCouponService.name);
  private readonly maxPicks = parseInt(process.env.MAX_COUPON_SELECTIONS || '10', 10);
  private readonly marginThreshold = parseFloat(process.env.MARGIN_THRESHOLD_PERCENT || '5');

  constructor(private mega: MegaPariCouponService) {}

  /**
   * Charge le pool de Value Picks depuis Redis (cache Margin Guard 15 min).
   * Une sélection par marché et par événement, marge <= seuil.
   */
  async loadValuePicks(): Promise<ValuePick[]> {
    const r = await getRedis();
    if (!r) return [];

    const picks: ValuePick[] = [];
    let keys: string[] = [];
    try {
      keys = await r.keys('megapari:event:*');
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
          // Taxonomie exacte BetB2B fournie par l'ETL (type + paramètre signé) ;
          // fallback heuristique si l'événement vient d'un ancien cache.
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
            margin_percent: margin,
            home: String(data.home_team || ''),
            away: String(data.away_team || ''),
            league: String(data.league || ''),
            sport: String(data.sport || 'football'),
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

  /**
   * Compose un combiné de `numMatches` sélections (1 par match) dont le produit
   * des cotes est le plus proche possible de `targetTotalOdds`.
   *
   * Méthode : cible par match = target^(1/N), choix glouton de l'événement le plus
   * proche, puis passes d'amélioration locale (remplacement d'une sélection par une
   * autre issue d'un match non utilisé) tant que l'écart en log-cote diminue.
   */
  async compose(numMatches: number, targetTotalOdds: number): Promise<ValuePick[]> {
    if (!Number.isInteger(numMatches) || numMatches < 1) {
      throw new BadRequestException({ error: 'INVALID_INPUT', reason_code: 'INVALID_NUM_MATCHES', message: 'num_matches doit être un entier >= 1' });
    }
    if (numMatches > this.maxPicks) {
      throw new BadRequestException({
        error: 'INVALID_INPUT',
        reason_code: 'TOO_MANY_MATCHES',
        message: `num_matches maximum: ${this.maxPicks}`,
        details: { max: this.maxPicks },
      });
    }
    if (!isFinite(targetTotalOdds) || targetTotalOdds < 1.01) {
      throw new BadRequestException({ error: 'INVALID_INPUT', reason_code: 'INVALID_TARGET_ODDS', message: 'target_total_odds doit être >= 1.01' });
    }

    const pool = await this.loadValuePicks();
    if (pool.length === 0) {
      throw new BadRequestException({
        error: 'NO_VALUE_PICKS',
        reason_code: 'NO_VALUE_PICKS',
        message: 'Aucune Value Pick disponible (cache MegaPari vide ou marge > seuil). Relancez un scan.',
      });
    }

    // 1 sélection "représentative" par événement pour le premier passage :
    // la plus proche de la cote cible par match.
    const perSlot = Math.pow(targetTotalOdds, 1 / numMatches);
    const byEvent = new Map<string, ValuePick[]>();
    for (const p of pool) {
      const arr = byEvent.get(p.event_id) || [];
      arr.push(p);
      byEvent.set(p.event_id, arr);
    }

    const distinctEvents = [...byEvent.keys()];
    if (distinctEvents.length < numMatches) {
      throw new BadRequestException({
        error: 'NOT_ENOUGH_EVENTS',
        reason_code: 'NOT_ENOUGH_EVENTS',
        message: `Pas assez de matchs disponibles: ${distinctEvents.length} < ${numMatches}`,
        details: { available: distinctEvents.length, requested: numMatches },
      });
    }

    // Classement glouton : on prend les événements dont une sélection est la plus
    // proche de la cote cible par match (en log), en évitant les doublons d'événement.
    const logTarget = Math.log(targetTotalOdds);
    const candidates = distinctEvents
      .map(eventId => {
        const sels = (byEvent.get(eventId) || []).slice().sort(
          (a, b) => Math.abs(Math.log(a.odds) - Math.log(perSlot)) - Math.abs(Math.log(b.odds) - Math.log(perSlot)),
        );
        return { eventId, best: sels[0], all: sels };
      })
      .sort((a, b) => {
        const da = Math.abs(Math.log(a.best.odds) - Math.log(perSlot));
        const db = Math.abs(Math.log(b.best.odds) - Math.log(perSlot));
        if (da !== db) return da - db;
        // Tie-break : marge la plus faible (valeur la plus sure)
        return a.best.margin_percent - b.best.margin_percent;
      });

    const chosen: ValuePick[] = candidates.slice(0, numMatches).map(c => c.best);

    // --- Amélioration locale : on tente de se rapprocher de la cible en log ---
    const diff = (list: ValuePick[]) => {
      const s = list.reduce((acc, p) => acc + Math.log(p.odds), 0);
      return Math.abs(s - logTarget);
    };

    let currentDiff = diff(chosen);
    const usedEvents = new Set(chosen.map(p => p.event_id));
    const spare = candidates.slice(numMatches);

    for (let pass = 0; pass < 3; pass++) {
      let improved = false;
      for (let i = 0; i < chosen.length; i++) {
        const alternatives: ValuePick[] = [];
        // Autres sélections du même match déjà choisi
        const sameEvent = (byEvent.get(chosen[i].event_id) || []).filter(p => p.selection_id !== chosen[i].selection_id);
        alternatives.push(...sameEvent);
        // Sélections d'un match non utilisé (swap d'événement)
        for (const c of spare) {
          if (usedEvents.has(c.eventId)) continue;
          alternatives.push(c.best);
        }

        for (const alt of alternatives) {
          const trial = chosen.slice();
          trial[i] = alt;
          // Interdit deux sélections du même match
          if (new Set(trial.map(p => p.event_id)).size !== trial.length) continue;
          const d = diff(trial);
          if (d + 1e-9 < currentDiff) {
            chosen[i] = alt;
            currentDiff = d;
            usedEvents.clear();
            chosen.forEach(p => usedEvents.add(p.event_id));
            improved = true;
            break;
          }
        }
        if (improved) break;
      }
      if (!improved) break;
    }

    return chosen.sort((a, b) => a.odds - b.odds);
  }

  /**
   * Compose le combiné puis demande le code coupon B2B à MegaPari.
   * Le libellé respecte le format demandé : "Combiné [X] matchs - Côte [Y]".
   */
  /**
   * Génère le code coupon d'UNE sélection de la composition (mode PER_PICK).
   *
   * On relit la Value Pick dans le cache : les cotes doivent être celles du
   * moment (BetB2B refuse un `oddsMarket` périmé) et la marge est revérifiée.
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
      // On propage le code raison d'origine (ex. B2B_RATE_LIMITED) pour que
      // l'application affiche un message actionnable plutôt qu'une erreur brute.
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

  async generateCombined(
    numMatches: number,
    targetTotalOdds: number,
    currency?: string,
    language?: string,
    includeIndividualCodes = false,
  ) {
    const picks = await this.compose(numMatches, targetTotalOdds);

    const totalOdds = picks.reduce((acc, p) => acc * p.odds, 1);
    const roundedOdds = Math.round(totalOdds * 100) / 100;
    const label = `Combiné ${picks.length} matchs - Côte ${roundedOdds.toFixed(2)}`;

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

    // MegaPari B2B n'expose que `sharecoupon` : un appel = une seule sélection.
    //  - 1 match  → un vrai coupon (code + deep link pré-remplis)
    //  - N matchs → composition réelle + un code par sélection (mode PER_PICK),
    //               jamais de faux « code combiné ».
    let couponMode: 'SINGLE' | 'PER_PICK' | 'NONE' = 'NONE';
    let couponCode: string | null = null;
    let deepLink: string | null = null;
    let message = '';
    let success = false;
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

    if (b2bPicks.length === 1) {
      try {
        const res = await this.mega.generateCoupon(b2bPicks, { currency, language });
        couponMode = 'SINGLE';
        couponCode = res.couponCode;
        deepLink = res.deepLink;
        message = res.message;
        success = true;
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
        const body = e?.response?.data ?? e?.getResponse?.() ?? null;
        message = body?.message || e?.message || 'Échec de la génération du coupon MegaPari';
      }
    } else if (includeIndividualCodes) {
      const results = await this.mega.generateSeparateCoupons(b2bPicks, { currency, language });
      couponMode = 'PER_PICK';
      success = results.some(r => r.success);
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
      message = ok === picks.length
        ? `${ok} codes générés — un par sélection : ajoute-les à ton coupon MegaPari.`
        : `${ok}/${picks.length} codes générés — certains marchés ne sont plus disponibles.`;
      deepLink = process.env.MEGAPARI_AFFILIATE_URL || 'https://megapari.com/en';
    } else {
      // Mode manuel : aucune création de coupon demandée. La composition est
      // livrée (succès), l'utilisateur génère les codes sélection par sélection.
      couponMode = 'NONE';
      success = true;
      deepLink = process.env.MEGAPARI_AFFILIATE_URL || 'https://megapari.com/en';
      message = 'Composition prête — ouvre MegaPari et ajoute les sélections.';
    }

    if (!message) message = 'Composition prête — MegaPari n\'a pas validé la génération du coupon.';

    this.logger.log(JSON.stringify({
      level: 'audit',
      action: 'coupons/generate-combined',
      numMatches: picks.length,
      targetTotalOdds,
      totalOdds: roundedOdds,
      couponMode,
      couponCode,
      codesGenerated: coupons.filter(c => c.success).length,
      success,
    }));

    return {
      success,
      couponMode,
      label,
      totalOdds: roundedOdds,
      numMatches: picks.length,
      targetTotalOdds,
      couponCode,
      deepLink,
      message,
      // Un code par sélection (mode PER_PICK) — vide en mode SINGLE (voir couponCode).
      coupons,
      picks: picks.map(p => ({
        event_id: p.event_id,
        home: p.home,
        away: p.away,
        league: p.league,
        sport: p.sport,
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

}
