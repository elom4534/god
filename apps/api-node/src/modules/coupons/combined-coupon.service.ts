import { Injectable, BadRequestException } from '@nestjs/common';
import { createClient } from 'redis';
import { MegaPariCouponService, Pick } from '../bookmaker/megapari-coupon.service';

const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379';
let redisClient: any = null;
async function getRedis() {
  if (redisClient) return redisClient;
  try { redisClient = createClient({ url: REDIS_URL }); await redisClient.connect(); return redisClient; } catch { return null; }
}

interface ValuePick {
  event_id: string;
  market_id: string;
  selection_id: string;
  market_type: string;
  line: number | null;
  odds: number;
  margin_percent: number;
  home?: string;
  away?: string;
}

@Injectable()
export class CombinedCouponService {
  constructor(private mega: MegaPariCouponService) {}

  /**
   * Lit les événements cachés (megapari:event:*) et extrait les Value Picks (marge <=5%)
   * avec leurs cotes internes.
   */
  async loadValuePicks(): Promise<ValuePick[]> {
    const r = await getRedis();
    if (!r) return [];
    const picks: ValuePick[] = [];
    try {
      const keys = await r.keys('megapari:event:*');
      for (const key of keys) {
        const raw = await r.get(key);
        if (!raw) continue;
        let data: any;
        try { data = JSON.parse(raw); } catch { continue; }
        const eventId = String(data.event_id || key.replace('megapari:event:', ''));
        const validated = data.validated_markets || [];
        for (const vm of validated) {
          const margin = vm.margin_percent ?? 0;
          if (margin > 5) continue;
          const internal = vm._odds_internal || [];
          const sels = vm.selections || [];
          sels.forEach((s: any, i: number) => {
            const odds = internal[i];
            if (typeof odds !== 'number' || odds <= 1) return;
            picks.push({
              event_id: eventId,
              market_id: vm.market_id,
              selection_id: s.selection_id,
              market_type: vm.market_type,
              line: vm.line ?? null,
              odds,
              margin_percent: margin,
            });
          });
        }
      }
    } catch (e) {
      // fail-closed: pas de picks si erreur Redis
    }
    return picks;
  }

  /**
   * Compose un combiné de `numMatches` picks dont le produit des cotes
   * est le plus proche possible de `targetTotalOdds`.
   */
  async compose(numMatches: number, targetTotalOdds: number): Promise<ValuePick[]> {
    if (numMatches < 1 || numMatches > 20) throw new BadRequestException('num_matches invalide (1-20)');
    if (targetTotalOdds < 1.01) throw new BadRequestException('target_total_odds invalide');

    const pool = await this.loadValuePicks();
    if (pool.length < numMatches) throw new BadRequestException('pas assez de value picks disponibles');

    // Dédupliquer par event_id (1 pick par match)
    const byEvent = new Map<string, ValuePick[]>();
    for (const p of pool) {
      const arr = byEvent.get(p.event_id) || [];
      arr.push(p);
      byEvent.set(p.event_id, arr);
    }
    const events = [...byEvent.keys()];

    // Greedy: choisir à chaque étape le pick qui rapproche le produit de la cible
    const chosen: ValuePick[] = [];
    const usedEvents = new Set<string>();
    let product = 1.0;
    const remainingTarget = () => targetTotalOdds / product;
    const remainingSlots = () => numMatches - chosen.length;

    // Pour chaque slot, choisir le pick (d'un event non utilisé) dont odds est le plus proche
    // de la cible par slot (target^(1/remaining))
    for (let slot = 0; slot < numMatches; slot++) {
      const slotsLeft = numMatches - slot;
      const perSlotTarget = Math.pow(targetTotalOdds / product, 1 / slotsLeft);
      let best: ValuePick | null = null;
      let bestDiff = Infinity;
      for (const ev of events) {
        if (usedEvents.has(ev)) continue;
        for (const p of byEvent.get(ev) || []) {
          const diff = Math.abs(p.odds - perSlotTarget);
          if (diff < bestDiff) { bestDiff = diff; best = p; }
        }
      }
      if (!best) break;
      chosen.push(best);
      usedEvents.add(best.event_id);
      product *= best.odds;
    }

    if (chosen.length < numMatches) throw new BadRequestException('composition impossible (pas assez d events distincts)');
    return chosen;
  }

  async generateCombined(numMatches: number, targetTotalOdds: number, currency?: string, language?: string) {
    const picks = await this.compose(numMatches, targetTotalOdds);
    const totalOdds = picks.reduce((a, p) => a * p.odds, 1);
    const label = `Combiné ${numMatches} matchs - Côte ${totalOdds.toFixed(2)}`;

    // Construire les Pick B2B (avec b2b_oddsMarket = odds)
    const b2bPicks: Pick[] = picks.map(p => ({
      event_id: p.event_id,
      market_id: p.market_id,
      selection_id: p.selection_id,
      market_type: p.market_type,
      line: p.line,
      sportEventId: parseInt(p.event_id, 10) || 0,
      b2b_type: p.market_type === '1X2' ? 1 : (p.market_type === 'OVER_UNDER' ? 9 : 1),
      b2b_oddsMarket: p.odds,
      b2b_kind: 3,
    }));

    const result = await this.mega.generateCoupon(b2bPicks, { currency, language });
    return {
      success: result.success,
      label,
      totalOdds: parseFloat(totalOdds.toFixed(2)),
      numMatches: picks.length,
      couponCode: result.couponCode,
      deepLink: result.deepLink,
      message: result.message,
      picks: picks.map(p => ({
        event_id: p.event_id,
        market_id: p.market_id,
        selection_id: p.selection_id,
        market_type: p.market_type,
        odds: p.odds,
      })),
    };
  }
}
