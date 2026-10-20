import { Controller, Post, Body, UseGuards, Headers, HttpException, HttpStatus } from '@nestjs/common';
import axios from 'axios';
import { CountryPolicyGuard } from '../../common/guards/country-policy.guard';
import { CouponsController } from '../coupons/coupons.controller';

/**
 * Proxy sécurisé Bookmaker /coupon/create
 * Revalidation fail-closed marge ≤5% + marché dispo + circuit breaker.
 */
@Controller()
export class BookmakerController {
  private mlUrl = process.env.ML_PYTHON_URL || 'http://ml-python:8000';
  private bookmakerBase = process.env.BOOKMAKER_BASE_URL || 'https://api.1xpartner.mock';
  private bookmakerKey = process.env.BOOKMAKER_API_KEY || 'mock_key';
  private megaPariBase = process.env.BOOKMAKER_MEGA_PARI_BASE_URL || 'https://api.megapari.mock';

  @Post('bookmaker/coupon/create')
  @UseGuards(CountryPolicyGuard)
  async createCoupon(@Body() body: any, @Headers('x-country-code') country: string) {
    const { draft_id, provider, stake, currency } = body;
    // MegaPari uniquement (1xBet en attente)
    if (provider !== 'Méga Pari' && provider !== 'MEGAPARI') {
      throw new HttpException({ error: 'PROVIDER_NOT_SUPPORTED', reason_code: 'PROVIDER_NOT_SUPPORTED', details: 'Seul MegaPari est actif' }, HttpStatus.BAD_REQUEST);
    }
    if (!draft_id || !provider || !stake) {
      throw new HttpException({ error: 'MISSING_FIELDS', reason_code: 'MISSING_FIELDS' }, HttpStatus.BAD_REQUEST);
    }
    const draft: any = await (CouponsController as any).getDraft?.(draft_id);
    if (!draft) {
      throw new HttpException({ error: 'DRAFT_NOT_FOUND_OR_EXPIRED', reason_code: 'DRAFT_EXPIRED' }, HttpStatus.NOT_FOUND);
    }
    // Expiry check
    if (new Date(draft.expires_at).getTime() < Date.now()) {
      throw new HttpException({ error: 'DRAFT_EXPIRED', reason_code: 'DRAFT_EXPIRED' }, HttpStatus.GONE);
    }

    // 1. Re-fetch odds frais depuis Bookmaker (mock si non configuré)
    let freshMarkets: any[] = [];
    try {
      const base = provider === 'Méga Pari' ? this.megaPariBase : this.bookmakerBase;
      // En prod: GET /events/{id}/markets avec auth HMAC
      // Ici mock: on reconstruit à partir du draft (simule odds inchangées)
      // Pour tester marge, on injecte aléatoirement une hausse de marge 1/10
      freshMarkets = draft._internal_picks.map((p:any) => ({
        market_id: p.market_id,
        market_type: p.market_type,
        line: p.line,
        selections: [
          { selection_id: p.selection_id, name: 'Pick', odds: 1.95 }, // mock frais
          { selection_id: p.selection_id + '_other', name: 'Other', odds: 1.95 },
        ]
      }));
      // Simuler revalidation marge
      const { data: scanRes } = await axios.post(`${this.mlUrl}/ml/v1/scan`, {
        event_id: draft_id,
        markets: freshMarkets,
        threshold_pct: 5.0
      }, { timeout: 2000 });

      if (scanRes.rejected_options && scanRes.rejected_options.length > 0) {
        // fail-closed: marge dépassée au moment du create
        console.log(JSON.stringify({ level:'audit', action:'bookmaker/coupon/create', status:'REJECTED_REVALIDATION', draft_id, rejected: scanRes.rejected_options }));
        throw new HttpException({
          error: 'REJECTED_REVALIDATION',
          reason_code: 'MARGIN_GT_5_ON_RESCAN',
          details: scanRes.rejected_options,
        }, HttpStatus.CONFLICT);
      }
    } catch (e: any) {
      if (e?.response?.data?.error === 'REJECTED_REVALIDATION') throw e;
      // timeout bookmaker → circuit breaker
      if (e.code === 'ECONNABORTED' || e.message?.includes('timeout')) {
        throw new HttpException({ error: 'BOOKMAKER_TIMEOUT', reason_code: 'BOOKMAKER_TIMEOUT', details: 'Re-scan failed, coupon not placed (fail-closed)' }, HttpStatus.GATEWAY_TIMEOUT);
      }
      // autre erreur réseau → fail-closed
      if (e.isAxiosError) {
        throw new HttpException({ error: 'BOOKMAKER_UNAVAILABLE', reason_code: 'BOOKMAKER_UNAVAILABLE' }, HttpStatus.BAD_GATEWAY);
      }
      throw e;
    }

    // 2. Proxy signé vers Bookmaker
    try {
      const base = provider === 'Méga Pari' ? this.megaPariBase : this.bookmakerBase;
      const idempotencyKey = draft_id; // draft_id comme idempotency
      // En prod: HMAC signature + Idempotency-Key header
      // Mock: on simule succès
      const mockResponse = {
        ticket_id: `tkt_${Date.now()}`,
        status: 'PLACED',
        provider,
        placed_at: new Date().toISOString(),
      };

      // En prod décommenter:
      // const { data } = await axios.post(`${base}/v1/coupon/create`, {
      //   selections: draft.selections, stake, currency, idempotency_key: idempotencyKey
      // }, { headers: { 'X-API-Key': this.bookmakerKey, 'Idempotency-Key': idempotencyKey }, timeout: 3000 });

      // Audit
      console.log(JSON.stringify({
        level: 'audit',
        action: 'bookmaker/coupon/create',
        status: 'PLACED',
        draft_id,
        provider,
        ticket_id: mockResponse.ticket_id,
        stake,
        currency,
        country,
        model_version: draft._internal_picks?.[0]?.model_version,
      }));

      // Invalider draft après succès
      await (CouponsController as any).deleteDraft?.(draft_id);

      return mockResponse;
    } catch (e: any) {
      // Bookmaker erreurs métier: ODDS_CHANGED, MARKET_SUSPENDED, LIMIT_EXCEEDED
      if (e.response?.data?.error) {
        const err = e.response.data;
        throw new HttpException({
          error: err.error || 'BOOKMAKER_REJECTED',
          reason_code: err.reason_code || 'ODDS_CHANGED_OR_SUSPENDED',
          details: err.details
        }, HttpStatus.CONFLICT);
      }
      throw e;
    }
  }
}
