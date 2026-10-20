import { Injectable, BadRequestException, Logger } from '@nestjs/common';
import axios from 'axios';
import { createClient } from 'redis';
import { MegaPariCouponService, Pick } from '../bookmaker/megapari-coupon.service';
import { buildLivePool } from './live-odds';

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
  /** Probabilité "fair" (marge retirée) que la sélection passe — 0..1. */
  prob: number;
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
  /** Seuil de probabilité minimal par sélection (0..1). Défaut : 70 %. */
  minProbability?: number;
  /** Pool déjà chargé (Live Feed) — évite un second appel bookmaker. */
  pool?: ValuePick[];
  /** Provenance du pool, reportée dans la réponse. */
  source?: 'live' | 'cache';
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

  /** Limite produit : 50 matchs maximum par combiné. */
  private readonly maxMatches = parseInt(process.env.MAX_COUPON_MATCHES || '50', 10);

  /** Garde-fou technique uniquement (protection mémoire) — pas une limite produit. */
  private readonly maxEventsScanned = parseInt(process.env.COUPON_MAX_EVENTS_SCANNED || '5000', 10);
  private readonly marginThreshold = parseFloat(process.env.MARGIN_THRESHOLD_PERCENT || '5');

  /**
   * Règle produit : une sélection n'est retenue que si sa probabilité de
   * passer atteint ce seuil (70 % par défaut).
   */
  private readonly minProbability = Math.min(
    0.99,
    Math.max(0.01, parseFloat(process.env.COUPON_MIN_PROBABILITY || '70') / 100),
  );

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

          // Probabilité fair : (1/cote) / Σ(1/cote) = (1/cote) / (1 + marge).
          const invSum = 1 + margin / 100;
          const prob = Math.min(0.995, (1 / odds) / Math.max(invSum, 1e-6));

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
            prob,
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

  // ------------------------------------------------------------ live feed --

  /**
   * Charge les marchés DIRECTEMENT chez MegaPari (BetB2B), à l'instant du clic.
   *
   * Aucune lecture du cache métier : une cote peut bouger en quelques secondes,
   * et générer un code coupon sur des cotes périmées n'a aucun sens. Le flux
   * est regroupé en marchés puis filtré par le même Margin Guard fail-closed
   * que l'ETL, et chaque issue reçoit sa probabilité « fair » (marge retirée).
   */
  async loadLivePicks(sportId?: number | null, limit = 400): Promise<{
    picks: ValuePick[];
    asOf: string;
    eventsFetched: number;
    validatedMarkets: number;
  }> {
    // Pool plus large que le nombre de matchs demandé : la contrainte de
    // probabilité élimine beaucoup de matchs, il faut donc du choix.
    const events = await this.mega.fetchPrematchEvents(limit, sportId ?? null);

    const names = new Map<number, string>();
    try {
      for (const s of await this.mega.getSportsDirectory('en')) names.set(s.id, s.name);
    } catch { /* répertoire indisponible : noms de sport vides, sans impact */ }

    const pool = buildLivePool(events, Object.fromEntries(names), {
      sportId: sportId ?? null,
      marginThreshold: this.marginThreshold,
    });

    const picks: ValuePick[] = [];
    for (const ev of pool.events) {
      for (const vm of ev.markets) {
        if (vm.margin_percent > this.marginThreshold) continue;
        for (const sel of vm.selections) {
          if (!Number.isFinite(sel.odds) || sel.odds <= 1.0) continue;
          if (!Number.isFinite(sel.prob) || sel.prob <= 0) continue;
          picks.push({
            event_id: ev.event_id,
            market_id: vm.market_id,
            selection_id: sel.selection_id,
            market_type: vm.market_type,
            selection_name: sel.name,
            tags: sel.tags,
            line: vm.line,
            odds: sel.odds,
            logOdds: Math.log(sel.odds),
            margin_percent: vm.margin_percent,
            prob: sel.prob,
            home: ev.home,
            away: ev.away,
            league: ev.league,
            sport: 'football',
            sport_id: ev.sport_id,
            sport_name: ev.sport_name,
            start_time: ev.start_time,
            b2b_type: sel.b2b_type,
            b2b_parameter: sel.b2b_parameter,
          });
        }
      }
    }

    return {
      picks,
      asOf: new Date().toISOString(),
      eventsFetched: pool.eventsFetched,
      validatedMarkets: pool.validatedMarkets,
    };
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
      max_matches: this.maxMatches,
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
    if (n > this.maxMatches) {
      throw new BadRequestException({
        error: 'INVALID_INPUT',
        reason_code: 'TOO_MANY_MATCHES',
        message: `Le nombre de matchs est limité à ${this.maxMatches} par combiné.`,
        details: { max: this.maxMatches, requested: n },
      });
    }
    if (!Number.isFinite(target) || target < 1.01) {
      throw new BadRequestException({
        error: 'INVALID_INPUT',
        reason_code: 'INVALID_TARGET_ODDS',
        message: 'La côte totale visée doit être supérieure ou égale à 1.01.',
      });
    }

    // --- Source du pool : LIVE par défaut (cotes de dernière minute) --------
    const minProb = Math.min(
      0.99,
      Math.max(0.01, options.minProbability ?? this.minProbability),
    );

    const rawPool = options.pool ?? (await this.loadLivePicks(options.sportId ?? null)).picks;
    if (rawPool.length === 0) {
      throw new BadRequestException({
        error: 'NO_VALUE_PICKS',
        reason_code: 'NO_VALUE_PICKS',
        message: options.sportId
          ? 'Aucun marché validé pour cette discipline à cet instant (marge au-dessus du seuil ou aucun match à venir).'
          : 'Aucun marché validé disponible à cet instant (marge au-dessus du seuil ou aucun match à venir).',
      });
    }

    // --- Règle produit : ne garder que les sélections assez sûres ----------
    const pool = rawPool.filter(p => p.prob >= minProb);
    if (pool.length === 0) {
      const best = rawPool.reduce((a, b) => (a.prob >= b.prob ? a : b));
      throw new BadRequestException({
        error: 'NO_PICK_ABOVE_MIN_PROBABILITY',
        reason_code: 'NO_PICK_ABOVE_MIN_PROBABILITY',
        message:
          `Aucune sélection n'atteint ${Math.round(minProb * 100)} % de chances de passer ` +
          `(meilleure trouvée : ${Math.round(best.prob * 100)} %). Réessaie dans quelques minutes.`,
        details: {
          min_probability: Math.round(minProb * 100),
          best_probability: Math.round(best.prob * 100),
        },
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

    // --- Borne haute : cote maximale atteignable sous la contrainte 70 % ---
    // Comme on prend exactement 1 sélection par match, la cote maximale d'un
    // combiné de n matchs est le produit des n plus grosses cotes autorisées.
    const maxOddsByEvent = new Map<string, number>();
    for (const p of pool) {
      const cur = maxOddsByEvent.get(p.event_id) ?? 0;
      if (p.odds > cur) maxOddsByEvent.set(p.event_id, p.odds);
    }
    const topOdds = [...maxOddsByEvent.values()].sort((a, b) => b - a).slice(0, n);
    const maxReachable = topOdds.reduce((acc, o) => acc * o, 1);

    if (target > maxReachable * 1.0001) {
      // Nombre de matchs nécessaire pour que la cible devienne atteignable.
      const allOdds = [...maxOddsByEvent.values()].sort((a, b) => b - a);
      let product = 1;
      let needed = 0;
      for (const o of allOdds) {
        product *= o;
        needed += 1;
        if (product >= target) break;
      }
      throw new BadRequestException({
        error: 'TARGET_UNREACHABLE',
        reason_code: 'TARGET_UNREACHABLE_AT_MIN_PROBABILITY',
        message:
          `Avec ${Math.round(minProb * 100)} % de chances minimum par sélection, ` +
          `${n} matchs plafonnent à une cote de ${maxReachable.toFixed(2)}. ` +
          `Augmente le nombre de matchs à ${needed} (ou plus) pour viser ${target}.`,
        details: {
          min_probability: Math.round(minProb * 100),
          requested_matches: n,
          requested_target_odds: target,
          max_reachable_odds: Math.round(maxReachable * 100) / 100,
          suggested_matches: needed,
        },
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
    minProbability?: number,
  ) {
    // 1) Cotes de dernière minute : un SEUL appel bookmaker, réutilisé pour
    //    la composition ET pour le contrôle de cohérence des seuils.
    const live = await this.loadLivePicks(sportId ?? null);
    const composed = await this.compose(numMatches, targetTotalOdds, {
      sportId,
      pool: live.picks,
      minProbability,
      source: 'live',
    });
    const picks = composed.picks;
    const minProb = Math.min(0.99, Math.max(0.01, minProbability ?? this.minProbability));

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

    let couponMode: 'COMBO' | 'SINGLE' | 'PER_PICK' | 'NONE' = 'NONE';
    // Renseigné quand MegaPari limite la création (1 code / minute) : le client
    // attend ce délai puis relance automatiquement.
    let retryAfterSeconds: number | null = null;
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

    // 1) Cas mono-sélection : coupon simple.
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
    } else if (includeIndividualCodes) {
      // 2) Mode explicite « un code par sélection » (fallback manuel).
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
        ? `${ok} codes générés — un par sélection.`
        : `${ok}/${picks.length} codes générés — certains marchés ne sont plus disponibles.`;
    } else {
      // 3) Cas nominal : UN code coupon pour tout le combiné (confirmé par le
      //    manager MegaPari). Toutes les sélections partent dans la même requête.
      try {
        const res = await this.mega.shareCouponCombined(b2bPicks, { language });
        couponMode = 'COMBO';
        couponCode = res.couponCode;
        deepLink = res.deepLink;
        message = `Code coupon combiné généré (${picks.length} sélections) — code ${res.couponCode}`;
        coupons.push({
          event_id: '*',
          home: '',
          away: '',
          selection_name: `${picks.length} sélections`,
          market_type: 'COMBO',
          line: null,
          odds: composed.totalOdds,
          success: true,
          couponCode: res.couponCode,
          deepLink: res.deepLink,
          error: null,
        });
      } catch (e: any) {
        const body = e?.getResponse?.() ?? e?.response?.data ?? null;
        const reason = typeof body?.reason_code === 'string' ? body.reason_code : 'B2B_COUPON_FAILED';
        success = false;
        couponMode = 'NONE';
        message = body?.message || e?.message || 'Échec de la génération du coupon combiné MegaPari';
        const ra = body?.details?.retry_after_seconds;
        if (reason === 'B2B_RATE_LIMITED' && Number.isFinite(Number(ra))) {
          retryAfterSeconds = Number(ra);
        }
        this.logger.warn(`[COMBINED] coupon combiné indisponible (${reason}) — fallback sélection par sélection`);
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
      retryAfterSeconds,
      source: 'live',
      oddsAsOf: live.asOf,
      minProbability: Math.round(minProb * 100),
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
      retry_after_seconds: retryAfterSeconds,
      // Traçabilité : d'où viennent les cotes et quelle règle a été appliquée.
      source: 'live',
      odds_as_of: live.asOf,
      min_probability: Math.round(minProb * 100),
      events_fetched: live.eventsFetched,
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
        // Probabilité « fair » de passer (marge retirée) — arrondie à l'unité.
        probability_percent: Math.round(p.prob * 100),
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
