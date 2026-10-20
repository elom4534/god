import { Body, Controller, Get, HttpCode, Post } from '@nestjs/common';
import { CombinedCouponService } from './combined-coupon.service';

interface GenerateCombinedBody {
  num_matches?: number | string;
  target_total_odds?: number | string;
  currency?: string;
  language?: string;
  include_individual_codes?: boolean;
}

function toNumber(value: unknown): number {
  if (typeof value === 'number') return value;
  if (typeof value === 'string') return Number(value.replace(',', '.').trim());
  return NaN;
}

@Controller('coupons')
export class CombinedCouponController {
  constructor(private readonly svc: CombinedCouponService) {}

  /**
   * Disponibilité du pool de Value Picks — permet à l'UI de borner le formulaire
   * avant de lancer une génération (évite un aller-retour inutile).
   */
  @Get('value-picks/availability')
  async availability() {
    const picks = await this.svc.loadValuePicks();
    const events = new Set(picks.map(p => p.event_id));
    return {
      events: events.size,
      picks: picks.length,
      max_matches: parseInt(process.env.MAX_COUPON_SELECTIONS || '10', 10),
      margin_threshold: parseFloat(process.env.MARGIN_THRESHOLD_PERCENT || '5'),
    };
  }

  /**
   * Code coupon d'une sélection de la composition (mode PER_PICK).
   * Appelé au clic sur « Obtenir le code » d'un match — évite de saturer l'API
   * BetB2B (1 sélection = 1 coupon) et respecte la limite de débit.
   */
  @Post('pick-code')
  @HttpCode(201)
  async pickCode(@Body() body: { event_id?: string; selection_id?: string; language?: string }) {
    return this.svc.generatePickCode(
      String(body?.event_id ?? ''),
      String(body?.selection_id ?? ''),
      body?.language,
    );
  }

  /** Combiné personnalisé : N matchs + côte totale visée → code coupon MegaPari. */
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
      body?.include_individual_codes === true,
    );
  }
}
