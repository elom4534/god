import { Controller, Post, Body, UseGuards, Headers, BadRequestException } from '@nestjs/common';
import axios from 'axios';
import { CountryPolicyGuard } from '../../common/guards/country-policy.guard';
import { v4 as uuid } from 'uuid';

// In-memory store pour MVP (remplacer par Postgres + Redis en prod)
const DRAFTS = new Map<string, any>();

@Controller()
export class CouponsController {
  private mlUrl = process.env.ML_PYTHON_URL || 'http://ml-python:8000';

  @Post('coupons/generate')
  async generate(@Body() body: any, @Headers('x-country-code') country: string) {
    const { mode, format, system_k, system_n, event_ids, preferences } = body;

    if (!mode || !['real_only','virtual_only','mix'].includes(mode)) {
      throw new BadRequestException({ error: 'INVALID_MODE', reason_code: 'INVALID_MODE' });
    }
    if (!format || !['SINGLE','COMBINE','SYSTEM'].includes(format)) {
      throw new BadRequestException({ error: 'INVALID_FORMAT', reason_code: 'INVALID_FORMAT' });
    }
    if (format==='SYSTEM' && (!system_k || !system_n || system_k>=system_n)) {
      throw new BadRequestException({ error: 'INVALID_SYSTEM', reason_code: 'SYSTEM_K_GTE_N' });
    }
    if (!event_ids || !Array.isArray(event_ids) || event_ids.length===0) {
      throw new BadRequestException({ error: 'NO_EVENT_IDS', reason_code: 'NO_EVENT_IDS' });
    }
    // Contrainte 1 sélection par match: vérifiée côté pick (1/match) + ici on déduplique
    const uniqueIds = [...new Set(event_ids)];
    if (uniqueIds.length !== event_ids.length) {
      throw new BadRequestException({ error: 'DUPLICATE_MATCH', reason_code: 'DUPLICATE_MATCH', details: '1 sélection par match strict' });
    }
    if (uniqueIds.length > (parseInt(process.env.MAX_COUPON_SELECTIONS||'10'))) {
      throw new BadRequestException({ error: 'TOO_MANY_SELECTIONS', reason_code: 'TOO_MANY_SELECTIONS' });
    }

    // 1. Récupérer events normalisés (mock: on les reconstruit à partir d'event_ids via ML ou cache)
    // Pour MVP: on appelle un endpoint interne qui simule des events pré-normalisés
    // En prod: fetch Postgres + Redis
    const mockEvents = uniqueIds.map((id, idx) => ({
      event_id: id,
      sport: 'football',
      league: (preferences?.leagues?.[0] || 'Premier League'),
      start_time: new Date(Date.now()+86400000).toISOString(),
      home: `Home${idx}`,
      away: `Away${idx}`,
      is_virtual: mode==='virtual_only' ? true : (mode==='mix' ? idx%2===0 : false),
      provider: '1xBet',
      markets: [
        {
          market_id: `${id}_m_ou25`,
          market_type: 'OVER_UNDER',
          name: 'Over/Under 2.5',
          period: 'FT',
          line: 2.5,
          selections: [
            { selection_id: `${id}_over`, name: 'Over', tags: ['OVER'], odds: 1.95 },
            { selection_id: `${id}_under`, name: 'Under', tags: ['UNDER'], odds: 1.95 },
          ]
        },
        {
          market_id: `${id}_m_btts`,
          market_type: 'BTTS',
          name: 'BTTS',
          period: 'FT',
          line: null,
          selections: [
            { selection_id: `${id}_yes`, name: 'Yes', tags: ['YES'], odds: 1.90 },
            { selection_id: `${id}_no`, name: 'No', tags: ['NO'], odds: 1.90 },
          ]
        }
      ]
    }));

    // 2. Appeler Selection Engine pour 1 pick/match
    const { data: picksData } = await axios.post(`${this.mlUrl}/ml/v1/picks/best`, {
      events: mockEvents,
      mode,
      k_sigma: 1.0,
      threshold_pct: 5.0
    }, { timeout: 4000 });

    if (!picksData.picks || picksData.picks.length===0) {
      throw new BadRequestException({ error: 'NO_ELIGIBLE_PICKS', reason_code: 'NO_ELIGIBLE_MARKET', details: picksData.skipped });
    }

    // 3. Assembler draft (SANS cotes)
    const draftId = `draft_${uuid().slice(0,8)}`;
    const now = new Date();
    const expires = new Date(now.getTime()+5*60*1000);
    const selections = picksData.picks.map((p:any)=> ({
      event_id: p.event_id,
      market_id: p.market_id,
      selection_id: p.selection_id,
      market_type: p.market_type,
      line: p.line,
      p_lower: p.p_lower,
      confidence: p.confidence,
      // pas de cotes
    }));

    // Multi-format: SINGLE / COMBINE / SYSTEM(k,n) — validation métier
    let couponFormat = format;
    if (format==='SYSTEM') couponFormat = `SYSTEM_${system_k}_${system_n}`;
    // si SINGLE: chaque pick est un coupon séparé (ici on retourne 1 draft par pick)
    // Pour MVP on retourne un seul draft combiné, client gère l'affichage

    const draft = {
      draft_id: draftId,
      mode,
      format: couponFormat,
      selections,
      constraints_ok: true,
      warnings: picksData.picks.flatMap((p:any)=>p.warnings).filter(Boolean),
      created_at: now.toISOString(),
      expires_at: expires.toISOString(),
      // interne: garder picks complets pour revalidation (non exposé)
      _internal_picks: picksData.picks,
      country,
    };
    DRAFTS.set(draftId, draft);

    // Audit log
    console.log(JSON.stringify({ level:'audit', action:'coupons/generate', draft_id: draftId, mode, format: couponFormat, selections_count: selections.length, country }));

    // Réponse publique SANS cotes
    const { _internal_picks, ...publicDraft } = draft;
    return publicDraft;
  }

  // Helper pour bookmaker controller (accès interne)
  static getDraft(draftId: string) { return DRAFTS.get(draftId); }
  static deleteDraft(draftId: string) { return DRAFTS.delete(draftId); }
}
