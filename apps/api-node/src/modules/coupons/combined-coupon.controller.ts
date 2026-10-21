import { Body, Controller, Get, HttpCode, Post, Query } from '@nestjs/common';
import { CombinedCouponService } from './combined-coupon.service';

interface GenerateCombinedBody {
  num_matches?: number | string;
  target_total_odds?: number | string;
  sport_id?: number | string | null;
  currency?: string;
  language?: string;
  include_individual_codes?: boolean;
}

function toNumber(value: unknown): number {
  if (typeof value === 'number') return value;
  if (typeof value === 'string') return Number(value.replace(',', '.').trim());
  return NaN;
}

function toSportId(value: unknown): number | null {
  if (value === undefined || value === null || value === '' || value === 'all') return null;
  const n = toNumber(value);
  return Number.isFinite(n) ? Math.trunc(n) : null;
}

@Controller('coupons')
export class CombinedCouponController {
  constructor(private readonly svc: CombinedCouponService) {}

  /**
   * Sports réels proposés par le bookmaker (répertoire officiel) avec le nombre
   * de matchs disponibles à cet instant. Sert à alimenter le sélecteur de
   * discipline de l'application.
   */
  @Get('sports')
  async sports(@Query('language') language?: string) {
    return this.svc.getSports(language || 'en');
  }

  /**
   * Fenêtre « aujourd'hui / demain » : nombre de matchs réellement composables
   * par jour, avec le seuil de probabilité appliqué. Sert à borner le
   * formulaire et à expliquer pourquoi une cible est inatteignable.
   */
  @Get('window')
  async window(@Query('sport_id') sportId?: string) {
    return this.svc.getWindowSummary(toSportId(sportId));
  }

  /** Disponibilité du pool — borne le formulaire sans imposer de limite produit. */
  @Get('value-picks/availability')
  async availability(@Query('sport_id') sportId?: string) {
    const sid = toSportId(sportId);
    const picks = await this.svc.loadValuePicks(sid);
    const events = new Set(picks.map(p => p.event_id));
    return {
      events: events.size,
      picks: picks.length,
      sport_id: sid,
      margin_threshold: parseFloat(process.env.MARGIN_THRESHOLD_PERCENT || '5'),
    };
  }

  /**
   * Détail multi-marchés d'un match : toutes les sélections validées
   * (1X2, Double Chance, O/U, BTTS, Handicaps, Corners…) avec probabilités
   * réelles, relues en direct chez MegaPari.
   */
  @Get('match-picks')
  async matchPicks(@Query('event_id') eventId?: string) {
    return this.svc.getMatchPicks(String(eventId ?? ''));
  }

  /** Code coupon d'une sélection de la composition (mode PER_PICK). */
  @Post('pick-code')
  @HttpCode(201)
  async pickCode(@Body() body: { event_id?: string; selection_id?: string; language?: string }) {
    return this.svc.generatePickCode(
      String(body?.event_id ?? ''),
      String(body?.selection_id ?? ''),
      body?.language,
    );
  }

  /**
   * Combiné personnalisé : N matchs (libre) + côte totale visée (libre)
   * + discipline optionnelle → composition + codes coupon MegaPari.
   */
  @Post('generate-combined')
  @HttpCode(201)
  async generateCombined(@Body() body: GenerateCombinedBody) {
    const numMatches = toNumber(body?.num_matches);
    const targetOdds = toNumber(body?.target_total_odds);
    return this.svc.generateCombined(
      numMatches,
      targetOdds,
      body?.currency,
      body?.language,
      toSportId(body?.sport_id),
      body?.include_individual_codes === true,
    );
  }
}
