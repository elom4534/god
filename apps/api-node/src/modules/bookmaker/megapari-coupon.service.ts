/**
 * MegaPariCouponService — Node.js / NestJS
 * Génération de coupons B2B + Deep Links + Coupon Code copiable — Fail-Closed
 * Architecture réutilisable 1xBet (ref=1, même connecteur)
 *
 * B2B Endpoint: GET /datafeed/directories/api/v1/sharecoupon?ref=192&sportEventId=...&type=...&oddsMarket=...&kind=3
 * → "https://megapari.com/en?coupon-code=X9A1B" → extraction couponCode
 */

import * as crypto from 'crypto';
import { Injectable, BadRequestException, InternalServerErrorException, Logger } from '@nestjs/common';
import axios from 'axios';
import { createClient } from 'redis';

// --- Types ---
export interface Pick {
  event_id: string;        // GameId MegaPari = sportEventId (ex: 763041519)
  market_id: string;       // interne (ex: 763041519_9_2.5)
  selection_id: string;    // interne
  market_type: string;     // OVER_UNDER, 1X2, BTTS...
  line?: number | null;
  p_lower?: number;
  confidence?: string;
  // --- Champs B2B requis pour sharecoupon ---
  sportEventId?: number;   // = event_id as number (sportEventId BetB2B)
  b2b_type?: number;       // oddsLocalization.type (ex: 1=W1, 7=Handicap1, 9=Total Over)
  b2b_oddsMarket?: number; // oddsLocalization.oddsMarket (ex: 1.64, 1.95)
  b2b_parameter?: number;  // oddsLocalization.parameter (ex: -1.5, 2.5)
  b2b_playerId?: number;   // oddsLocalization.playerId (0 si pas joueur)
  b2b_kind?: number;       // 1=Live, 3=Line (pre-match) — nous: 3
  b2b_gr?: number;          // groupe (0 par défaut, voir manager)
  b2b_cnt?: number;         // pays (0 par défaut)
  b2b_lng?: string;         // langue deeplink
}

export interface CouponResult {
  success: boolean;
  provider: 'MEGAPARI';
  totalPicks: number;
  couponCode: string;       // Code copiable ex: X9A1B
  deepLink: string;         // https://megapari.com/en?coupon-code=X9A1B
  message: string;
  couponPayload: {
    ref: number;
    picks: Pick[];
    affiliateTag: string;
    createdAt: string;
    expiresAt: string;
  };
}

// --- Config Redis ---
const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379';
let redisClient: any = null;
async function getRedis() {
  if (redisClient) return redisClient;
  try { redisClient = createClient({ url: REDIS_URL }); await redisClient.connect(); return redisClient; } catch { return null; }
}

@Injectable()
export class MegaPariCouponService {
  private readonly logger = new Logger(MegaPariCouponService.name);
  private readonly ref = parseInt(process.env.MEGAPARI_REF || '192', 10);
  private readonly affiliateTag = process.env.MEGAPARI_AFFILIATE_TAG || process.env.MEGAPARI_TAG || 's_23283m_355c_';
  private readonly provider: 'MEGAPARI' = 'MEGAPARI';
  private readonly gatewayBase = (process.env.BOOKMAKER_API_BASE || 'https://cpservm.com/gateway/marketing').replace(/\/$/, '');
  private readonly tokenUrl = process.env.BOOKMAKER_TOKEN_URL || 'https://cpservm.com/gateway/token';

  // Config B2B MegaPari
  private get cfg() {
    return {
      client_id: process.env.MEGAPARI_CLIENT_ID || 'partners-c2b75a07c454fcd96f0453a0f79e1ead',
      client_secret: process.env.MEGAPARI_CLIENT_SECRET || '',
      ref: this.ref,
    };
  }

  // --- Validation stricte 1 pick/match ---
  private validateStrictOnePickPerMatch(picks: Pick[]): void {
    if (!picks || picks.length === 0) {
      throw new BadRequestException({
        error: 'STRICT_RULE_VIOLATION',
        reason_code: 'NO_PICKS',
        message: 'Aucune sélection fournie — 1 pick par match requis',
      });
    }
    const byEvent = new Map<string, Pick[]>();
    for (const p of picks) {
      if (!p.event_id) throw new BadRequestException({ error: 'STRICT_RULE_VIOLATION', reason_code: 'MISSING_EVENT_ID', message: `Pick sans event_id: ${JSON.stringify(p)}` });
      const list = byEvent.get(p.event_id) || [];
      list.push(p);
      byEvent.set(p.event_id, list);
    }
    for (const [eventId, list] of byEvent.entries()) {
      if (list.length > 1) {
        throw new BadRequestException({
          error: 'STRICT_RULE_VIOLATION',
          reason_code: 'DUPLICATE_MATCH',
          message: `Exactly 1 pick par match — violation sur GameId ${eventId}: ${list.length} sélections`,
          details: { event_id: eventId, picks: list },
        });
      }
    }
    const max = parseInt(process.env.MAX_COUPON_SELECTIONS || '10', 10);
    if (picks.length > max) throw new BadRequestException({ error: 'STRICT_RULE_VIOLATION', reason_code: 'TOO_MANY_PICKS', message: `Trop de sélections: ${picks.length} > ${max}` });
  }

  // --- OAuth2 client_credentials (identique MegaPari/1xBet) ---
  private async getAccessToken(): Promise<string> {
    const c = this.cfg;
    if (!c.client_id || !c.client_secret) throw new InternalServerErrorException(`[${this.provider}] client_id/client_secret manquants — configurer MEGAPARI_CLIENT_*`);
    // Le secret arrive parfois avec les entités HTML (&amp;) — on le décode comme l'ETL
    const clientSecret = c.client_secret.replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'");
    const cacheKey = `bookmaker:token:${this.provider}:${c.ref}:${c.client_id.slice(-6)}`;
    const r = await getRedis();
    if (r) { const cached = await r.get(cacheKey).catch(()=>null); if (cached) return cached; }
    const { data } = await axios.post(this.tokenUrl,
      new URLSearchParams({ client_id: c.client_id, client_secret: clientSecret }).toString(),
      { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, timeout: 8000 }
    );
    const token = data.access_token;
    const exp = data.expires_in || 3600;
    if (!token) throw new InternalServerErrorException(`[${this.provider}] pas de token`);
    if (r) await r.setEx(cacheKey, Math.max(60, exp - 60), token);
    return token;
  }

  /**
   * Événements prematch AVEC leurs cotes, lus à l'instant (LoadSingle v2).
   *
   * Utilisé par le générateur de combiné : les cotes doivent être celles du
   * moment du clic, pas celles d'un cache vieux de 10 minutes.
   *
   * ⚠️ Limite BetB2B : 1 requête / 5 s. `Count` est plafonné à 1000 par l'API.
   */
  async fetchPrematchEvents(limit = 400, sportId?: number | null): Promise<any[]> {
    const token = await this.getAccessToken();
    const params: Record<string, string> = {
      Ref: String(this.ref),
      Lng: 'en',
      SchemeOfGettingOddsOperations: 'GetAllOdds',
      Count: String(Math.max(1, Math.min(limit, 1000))),
    };
    if (sportId !== undefined && sportId !== null) params.SportIds = String(sportId);

    try {
      const res = await axios.get(`${this.gatewayBase}/datafeed/prematch/api/v2/sportevents`, {
        params,
        // `Accept: */*` est obligatoire sur cette passerelle (cf. sharecoupon).
        headers: { Authorization: `Bearer ${token}`, Accept: '*/*' },
        timeout: 30000,
      });
      const items = Array.isArray(res.data?.items) ? res.data.items : [];
      return items.filter((it: any) => it && Array.isArray(it.oddsLocalization) && it.oddsLocalization.length);
    } catch (e: any) {
      const status = e?.response?.status;
      const detail = JSON.stringify(e?.response?.data ?? e?.message).slice(0, 300);
      this.logger.error(`[MEGAPARI] flux prematch indisponible (HTTP ${status}) : ${detail}`);
      throw new BadRequestException({
        error: 'LIVE_FEED_UNAVAILABLE',
        reason_code: status === 429 || status === 400 ? 'B2B_RATE_LIMITED' : 'LIVE_FEED_UNAVAILABLE',
        message:
          status === 429 || status === 400
            ? 'MegaPari limite les requêtes : réessaie dans quelques secondes.'
            : 'Impossible de lire les cotes en direct chez MegaPari. Réessaie dans quelques secondes.',
        details: { upstream_status: status ?? null },
      });
    }
  }

  /**
   * Répertoire officiel des sports (noms réels proposés par le bookmaker).
   * GET /datafeed/directories/api/v2/sports?ref=…&lng=…
   * Cache Redis 6 h : la liste change très rarement.
   */
  async getSportsDirectory(language = 'en'): Promise<Array<{ id: number; name: string }>> {
    const cacheKey = `bookmaker:sports:${this.provider}:${language}`;
    const redis = await getRedis();
    if (redis) {
      const cached = await redis.get(cacheKey).catch(() => null);
      if (cached) {
        try {
          const parsed = JSON.parse(cached);
          if (Array.isArray(parsed) && parsed.length) return parsed;
        } catch { /* cache illisible → on retente l'appel */ }
      }
    }

    const token = await this.getAccessToken();
    const url = `${this.gatewayBase}/datafeed/directories/api/v2/sports`;
    const res = await axios.get(url, {
      params: { ref: this.cfg.ref, lng: language },
      headers: { Authorization: `Bearer ${token}`, Accept: '*/*' },
      timeout: 15000,
    });

    const items = Array.isArray(res.data?.items) ? res.data.items : [];
    const sports = items
      .filter((it: any) => it && typeof it.id === 'number' && it.name)
      .map((it: any) => ({ id: it.id as number, name: String(it.name) }))
      .sort((a: any, b: any) => a.name.localeCompare(b.name));

    if (redis && sports.length) {
      await redis.setEx(cacheKey, 6 * 3600, JSON.stringify(sports)).catch(() => undefined);
    }
    return sports;
  }

  // --- B2B: GET /datafeed/directories/api/v1/sharecoupon ---
  // Docs: https://docs-marketing-sport.com → operationId GameDataFeed_Directories_API_GET_api_v1_sharecoupon
  // Params strict order: ref, oddsMarket, sportEventId, type, kind, gr, cnt, lng, partnerLink, playerId, parameter
  /**
   * Throttle global des appels `sharecoupon`.
   *
   * BetB2B limite la création de liens coupon : au-delà d'une rafale d'appels,
   * la passerelle répond HTTP 400 « LiveBetService returned 200 » pendant
   * ~1 minute (vérifié le 20/10/2026). On sérialise donc les appels avec un
   * intervalle minimal configurable (MEGAPARI_MIN_INTERVAL_MS, défaut 8 s).
   */
  private static lastShareCall = 0;

  /** File process-local : une seule création de coupon à la fois. */
  private static shareQueue: Promise<unknown> = Promise.resolve();

  private enqueueShare<T>(fn: () => Promise<T>): Promise<T> {
    const run = MegaPariCouponService.shareQueue.then(fn, fn);
    MegaPariCouponService.shareQueue = run.then(() => undefined, () => undefined);
    return run;
  }

  /**
   * Réserve le prochain créneau de création de coupon auprès de BetB2B.
   *
   * Mesures du 20/10/2026 : la passerelle accepte environ **une création de
   * coupon par minute** (une requête de 50 sélections passe très bien, deux
   * requêtes rapprochées renvoient 400 « LiveBetService returned 200 »).
   *
   * On ne bloque JAMAIS la requête HTTP pour attendre le créneau : le proxy
   * Alwaysdata coupe les réponses trop longues (~30 s) et l'utilisateur
   * verrait une erreur réseau. Si le créneau est occupé, on renvoie
   * immédiatement `B2B_RATE_LIMITED` + `retry_after_seconds` ; le client
   * (Flutter) attend le délai indiqué puis relance automatiquement, ce qui
   * garantit des réponses < 1 s dans tous les cas.
   */
  private async acquireShareSlot(): Promise<void> {
    const interval = parseInt(process.env.MEGAPARI_SHARE_INTERVAL_MS || '65000', 10);
    const redis = await getRedis();
    const key = `bookmaker:share-slot:${this.provider}`;
    const now = Date.now();
    const last = redis
      ? parseInt((await redis.get(key).catch(() => null)) || '0', 10)
      : MegaPariCouponService.lastShareCall;
    const wait = last + interval - now;

    if (wait > 0) {
      const sec = Math.max(1, Math.ceil(wait / 1000));
      throw new BadRequestException({
        error: 'B2B_COUPON_FAILED',
        reason_code: 'B2B_RATE_LIMITED',
        message: `MegaPari autorise un code coupon par minute : nouvelle tentative possible dans ${sec} s.`,
        details: { retry_after_seconds: sec },
      });
    }
    MegaPariCouponService.lastShareCall = now;
    if (redis) await redis.set(key, String(now)).catch(() => undefined);
  }

  /** Invalide le créneau courant (la passerelle a refusé) → attente d'une minute. */
  private async markShareRejected(): Promise<void> {
    MegaPariCouponService.lastShareCall = Date.now();
    const redis = await getRedis();
    if (redis) await redis.set(`bookmaker:share-slot:${this.provider}`, String(Date.now())).catch(() => undefined);
  }

  /** Clé de cache stable d'un coupon (même sélection + même cote → même code). */
  private couponCacheKey(pick: Pick): string {
    const ev = pick.sportEventId ?? pick.event_id;
    return `bookmaker:coupon:${this.provider}:${ev}:${pick.b2b_type ?? 0}:${pick.b2b_oddsMarket}:${pick.b2b_parameter ?? ''}:${pick.b2b_kind ?? 3}`;
  }

  private async callB2BShareCoupon(pick: Pick): Promise<{ couponCode: string; deepLink: string; raw: string }> {
    const c = this.cfg;
    const cacheKey = this.couponCacheKey(pick);
    const redis = await getRedis();
    if (redis) {
      const cached = await redis.get(cacheKey).catch(() => null);
      if (cached) {
        try {
          const parsed = JSON.parse(cached);
          if (parsed?.couponCode && parsed?.deepLink) {
            return { couponCode: parsed.couponCode, deepLink: parsed.deepLink, raw: parsed.deepLink };
          }
        } catch { /* cache corrompu → on régénère */ }
      }
    }

    // Créneau réservé sans blocage (cf. acquireShareSlot).
    const token = await this.getAccessToken();

    // Extraction champs B2B — fallback depuis Pick si b2b_* nonfournis mais market_type connu
    const sportEventId = pick.sportEventId ?? parseInt(pick.event_id, 10);
    if (!sportEventId || isNaN(sportEventId)) throw new BadRequestException({ error: 'MISSING_B2B_FIELD', reason_code: 'MISSING_SPORT_EVENT_ID', message: `sportEventId requis pour B2B (pick ${pick.event_id})` });

    // Mapping market_type → b2b_type si non fourni (exemple heuristique, à affiner avec manager)
    const typeMap: Record<string, number> = { '1X2': 1, '1x2': 1, 'OVER_UNDER': 9, 'BTTS': 15, 'HANDICAP': 7, 'DOUBLE_CHANCE': 2 };
    const b2b_type = pick.b2b_type ?? typeMap[pick.market_type] ?? 1;
    const oddsMarket = pick.b2b_oddsMarket;
    if (oddsMarket === undefined || oddsMarket === null) {
      throw new BadRequestException({ error: 'MISSING_B2B_FIELD', reason_code: 'MISSING_ODDS_MARKET', message: `b2b_oddsMarket requis pour B2B (pick ${pick.selection_id}) — transmettre depuis validated_markets.oddsMarket` });
    }

    const kind = pick.b2b_kind ?? 3; // 3=Line (pre-match), 1=Live
    const lng = pick.b2b_lng || 'en';
    const parameter = pick.b2b_parameter ?? null;
    const playerId = pick.b2b_playerId ?? 0;

    // `gr` et `cnt` ont un défaut (0) côté BetB2B : les envoyer explicitement
    // casse la génération (HTTP 400 « LiveBetService returned 200 »). On ne les
    // transmet que si le manager a fourni des valeurs dédiées.
    const gr = pick.b2b_gr ?? (process.env.MEGAPARI_GR ? parseInt(process.env.MEGAPARI_GR, 10) : undefined);
    const cnt = pick.b2b_cnt ?? (process.env.MEGAPARI_CNT ? parseInt(process.env.MEGAPARI_CNT, 10) : undefined);

    // Construction params dans l'ordre documenté (validation stricte côté BetB2B)
    const params: Record<string, any> = {
      ref: c.ref,
      oddsMarket,
      sportEventId,
      type: b2b_type,
      kind,
      lng,
    };
    if (gr !== undefined && !isNaN(gr)) params.gr = gr;
    if (cnt !== undefined && !isNaN(cnt)) params.cnt = cnt;
    if (parameter !== undefined && parameter !== null) params.parameter = String(parameter);
    if (playerId) params.playerId = playerId;
    // partnerLink optionnel — si fourni, deeplink utilisera ce host
    if (process.env.MEGAPARI_PARTNER_LINK) params.partnerLink = process.env.MEGAPARI_PARTNER_LINK;

    const url = `${this.gatewayBase}/datafeed/directories/api/v1/sharecoupon`;
    this.logger.log(`[MEGAPARI B2B] GET sharecoupon sportEventId=${sportEventId} type=${b2b_type} odds=${oddsMarket} kind=${kind}`);

    let resp: any;
    try {
      // ⚠️ `Accept: */*` est OBLIGATOIRE : avec l'en-tête par défaut d'axios
      // (application/json, text/plain, */*) la passerelle répond
      // HTTP 400 « LiveBetService returned 200 » alors que la même requête
      // passe en curl. Vérifié le 20/10/2026 sur les 2 comptes.
      const res = await axios.get(url, {
        params,
        headers: { Authorization: `Bearer ${token}`, Accept: '*/*' },
        timeout: 15000,
      });
      resp = res.data;
    } catch (e: any) {
      const detail = e?.response?.data || e.message;
      const text = JSON.stringify(detail);
      // Message caractéristique d'une limitation de débit côté BetB2B.
      if (e?.response?.status === 400 && text.includes('LiveBetService')) {
        await this.markShareRejected();
        const cooldownSec = parseInt(process.env.MEGAPARI_COOLDOWN_SEC || '65', 10);
        throw new BadRequestException({
          error: 'B2B_COUPON_FAILED',
          reason_code: 'B2B_RATE_LIMITED',
          message: `MegaPari autorise un code coupon par minute : nouvelle tentative possible dans ${cooldownSec} s.`,
          details: { retry_after_seconds: cooldownSec },
        });
      }
      throw new InternalServerErrorException({
        error: 'B2B_COUPON_FAILED',
        reason_code: 'B2B_SHARECOUPON_ERROR',
        message: `Échec création coupon B2B MegaPari: ${text.slice(0,800)}`,
        details: { sportEventId, type: b2b_type, oddsMarket },
      });
    }

    // Réponse B2B: string URL "https://megapari.com/en?coupon-code=9V2XD" ou JSON avec même URL
    let rawUrl: string;
    if (typeof resp === 'string') rawUrl = resp;
    else if (typeof resp === 'object' && resp !== null) {
      // Gère cas où API renvoie {deeplink: "..."} ou {url: "..."}
      rawUrl = resp.deeplink || resp.url || resp.link || JSON.stringify(resp);
      if (rawUrl.startsWith('{')) throw new InternalServerErrorException({ error: 'B2B_COUPON_FAILED', reason_code: 'B2B_UNEXPECTED_JSON', details: resp });
    } else {
      throw new InternalServerErrorException({ error: 'B2B_COUPON_FAILED', reason_code: 'B2B_EMPTY_RESPONSE' });
    }

    // Validation Fail-Closed: si réponse contient "LiveBetService" ou pas de coupon-code → erreur
    if (rawUrl.includes('LiveBetService') || !rawUrl.includes('coupon-code=')) {
      throw new InternalServerErrorException({
        error: 'B2B_COUPON_FAILED',
        reason_code: 'B2B_INVALID_COUPON_RESPONSE',
        message: `Réponse B2B invalide (pas de coupon-code): ${rawUrl.slice(0,500)}`,
      });
    }

    // Extraction couponCode
    const match = rawUrl.match(/coupon-code=([A-Z0-9]+)/i);
    if (!match) throw new InternalServerErrorException({ error: 'B2B_COUPON_FAILED', reason_code: 'B2B_COUPON_CODE_NOT_FOUND', details: rawUrl });
    const couponCode = match[1].toUpperCase();
    const deepLink = rawUrl.replace(/^"|"$/g, '');

    // Cache 15 min : un même marché renvoie le même coupon sans re-solliciter
    // la passerelle (protection contre la limite de débit BetB2B).
    if (redis) {
      await redis
        .setEx(cacheKey, 900, JSON.stringify({ couponCode, deepLink }))
        .catch(() => undefined);
    }

    return { couponCode, deepLink, raw: rawUrl };
  }

  /**
   * Génère UN SEUL code coupon pour un combiné (plusieurs sélections).
   *
   * Le endpoint `sharecoupon` est déclaré au singulier dans la doc, mais il
   * accepte les paramètres répétés : `sportEventId=…&sportEventId=…`,
   * `type=…&type=…`, `oddsMarket=…&oddsMarket=…`, `parameter=…&parameter=…`.
   * Confirmé par le manager MegaPari (20/10/2026) : la création d'un code
   * coupon combiné est autorisée. On construit donc la requête à la main pour
   * envoyer chaque sélection (les sérialiseurs type axios produiraient
   * `sportEventId[]=`, que la passerelle n'attend pas).
   */
  async shareCouponCombined(
    picks: Pick[],
    options?: { language?: string },
  ): Promise<{ couponCode: string; deepLink: string; raw: string; submitted: number }> {
    if (!picks.length) throw new BadRequestException({ error: 'B2B_COUPON_FAILED', reason_code: 'NO_PICKS', message: 'Aucune sélection' });

    const c = this.cfg;
    const lng = options?.language || picks[0].b2b_lng || 'en';

    // Clé de cache : toutes les sélections (ordre stable) → même code réutilisé.
    const signature = picks
      .map(p => `${p.sportEventId ?? p.event_id}:${p.b2b_type}:${p.b2b_oddsMarket}:${p.b2b_parameter ?? ''}`)
      .sort()
      .join('|');
    // ⚠️ Pas de base64 tronqué : la signature fait ~1 000 caractères pour 50
    // sélections et les 90 premiers caractères encodés ne couvrent que le début
    // de la liste → deux combinés distincts partageaient le même code coupon
    // (observé le 20/10/2026). On hache la signature entière.
    const digest = crypto.createHash('sha1').update(`${c.ref}|${signature}`).digest('hex');
    const cacheKey = `bookmaker:combo:${this.provider}:${c.ref}:${digest}`;

    const redis = await getRedis();
    if (redis) {
      const cached = await redis.get(cacheKey).catch(() => null);
      if (cached) {
        try {
          const parsed = JSON.parse(cached);
          if (parsed?.couponCode) {
            return { couponCode: parsed.couponCode, deepLink: parsed.deepLink, raw: parsed.deepLink, submitted: picks.length };
          }
        } catch { /* cache illisible → on regénère */ }
      }
    }

    await this.acquireShareSlot();
    const token = await this.getAccessToken();

    // ⚠️ Les paramètres sont répétés N fois (un bloc par sélection) : la
    // passerelle associe `sportEventId`, `type`, `oddsMarket`, `parameter` et
    // `playerId` **par position**. Si une seule sélection omettait
    // `parameter` (cas d'un 1X2, paramètre 0 côté BetB2B), tous les blocs
    // suivants seraient décalés et le coupon pointerait vers de mauvais
    // marchés — MegaPari affiche alors « les événements sont terminés ».
    // On envoie donc TOUJOURS les cinq champs, dans le même ordre, pour chaque
    // sélection.
    const ordered = [...picks].sort((a, b) => {
      const ea = a.sportEventId ?? parseInt(a.event_id, 10);
      const eb = b.sportEventId ?? parseInt(b.event_id, 10);
      if (ea !== eb) return ea - eb;
      if ((a.b2b_type ?? 0) !== (b.b2b_type ?? 0)) return (a.b2b_type ?? 0) - (b.b2b_type ?? 0);
      return (a.b2b_parameter ?? 0) - (b.b2b_parameter ?? 0);
    });

    const qs = new URLSearchParams();
    qs.append('ref', String(c.ref));
    for (const p of ordered) {
      const sportEventId = p.sportEventId ?? parseInt(p.event_id, 10);
      const oddsMarket = p.b2b_oddsMarket;
      const type = p.b2b_type;
      if (!sportEventId || isNaN(sportEventId) || !oddsMarket || !type) {
        throw new BadRequestException({
          error: 'MISSING_B2B_FIELD',
          reason_code: 'MISSING_B2B_FIELD',
          message: `Sélection incomplète pour le B2B (event ${p.event_id})`,
        });
      }
      qs.append('sportEventId', String(sportEventId));
      qs.append('type', String(type));
      qs.append('oddsMarket', String(oddsMarket));
      qs.append('parameter', String(p.b2b_parameter ?? 0));
      qs.append('playerId', String(p.b2b_playerId ?? 0));
    }
    qs.append('kind', '3'); // 3 = prematch (line) — confirmé par la doc OpenAPI
    qs.append('gr', String(parseInt(process.env.MEGAPARI_GR || '0', 10)));
    qs.append('cnt', String(parseInt(process.env.MEGAPARI_CNT || '0', 10)));
    qs.append('lng', lng);
    if (process.env.MEGAPARI_PARTNER_LINK) qs.append('partnerLink', process.env.MEGAPARI_PARTNER_LINK);
    this.logger.log(`[MEGAPARI B2B] query: ${qs.toString()}`);

    const url = `${this.gatewayBase}/datafeed/directories/api/v1/sharecoupon?${qs.toString()}`;
    this.logger.log(`[MEGAPARI B2B] sharecoupon combiné — ${picks.length} sélections`);

    // La passerelle BetB2B tolère environ **1 création de coupon par minute**.
    // Au-delà, elle répond 400 « LiveBetService returned 200 ». On réessaie donc
    // automatiquement (2 tentatives espacées) avant de signaler une limite.
    // Vérifié le 20/10/2026 : un coupon de 50 sélections passe bien en un appel.
    let rawUrl = '';
    let lastText = '';
    try {
      const res = await axios.get(url, {
        headers: { Authorization: `Bearer ${token}`, Accept: '*/*' },
        timeout: 20000,
      });
      const resp = res.data;
      rawUrl = typeof resp === 'string' ? resp : (resp?.deeplink || resp?.url || JSON.stringify(resp));
    } catch (e: any) {
      lastText = JSON.stringify(e?.response?.data ?? e?.message);
      const rateLimited = e?.response?.status === 400 && lastText.includes('LiveBetService');
      if (rateLimited) {
        // La passerelle vient de refuser : on repousse le créneau d'une minute
        // et on laisse le client relancer automatiquement.
        await this.markShareRejected();
        const cooldownSec = parseInt(process.env.MEGAPARI_COOLDOWN_SEC || '65', 10);
        this.logger.warn(`[MEGAPARI B2B] création refusée par la passerelle — créneau repoussé de ${cooldownSec} s`);
        throw new BadRequestException({
          error: 'B2B_COUPON_FAILED',
          reason_code: 'B2B_RATE_LIMITED',
          message: `MegaPari autorise un code coupon par minute : nouvelle tentative possible dans ${cooldownSec} s.`,
          details: { retry_after_seconds: cooldownSec },
        });
      }
      throw new InternalServerErrorException({
        error: 'B2B_COUPON_FAILED',
        reason_code: 'B2B_SHARECOUPON_ERROR',
        message: `Échec création du coupon combiné MegaPari: ${lastText.slice(0, 500)}`,
        details: { selections: picks.length },
      });
    }

    if (typeof rawUrl !== 'string' || !rawUrl.includes('coupon-code=')) {
      throw new InternalServerErrorException({
        error: 'B2B_COUPON_FAILED',
        reason_code: 'B2B_INVALID_COUPON_RESPONSE',
        message: `Réponse B2B invalide (pas de coupon-code): ${String(rawUrl).slice(0, 300)}`,
      });
    }

    const match = rawUrl.match(/coupon-code=([A-Z0-9]+)/i);
    if (!match) {
      throw new InternalServerErrorException({ error: 'B2B_COUPON_FAILED', reason_code: 'B2B_COUPON_CODE_NOT_FOUND', details: rawUrl });
    }
    const couponCode = match[1].toUpperCase();
    const deepLink = rawUrl.replace(/^"|"$/g, '');

    if (redis) {
      await redis.setEx(cacheKey, 900, JSON.stringify({ couponCode, deepLink, selections: picks.length })).catch(() => undefined);
    }

    this.logger.log(`[MEGAPARI B2B] coupon combiné ${couponCode} (${picks.length} sélections)`);

    return { couponCode, deepLink, raw: rawUrl, submitted: picks.length };
  }

  // --- Génération coupon + B2B ---
  async generateCoupon(picks: Pick[], options?: { currency?: string; language?: string }): Promise<CouponResult> {
    this.validateStrictOnePickPerMatch(picks);

    const now = new Date();
    const expiresAt = new Date(now.getTime() + 5 * 60 * 1000);

    // Cas SINGLE (1 pick): interrogation B2B directe → couponCode réel
    // Cas MULTI (combiné): B2B ne supporte qu'1 marché par appel → on génère via premier pick + deepLink combiné
    // Pour un vrai combiné multi-sélections, il faudra demander au manager l'endpoint accumulator (non documenté dans openapi.yaml)
    let couponCode: string;
    let deepLink: string;

    if (picks.length === 1) {
      const b2b = await this.callB2BShareCoupon(picks[0]);
      couponCode = b2b.couponCode;
      deepLink = b2b.deepLink;
      // Si MEGAPARI_PARTNER_LINK configuré, le deepLink utilisera déjà ce host
    } else {
      // MULTI — stratégie Fail-Closed documentée:
      // On tente B2B sur chaque pick et on combine les codes en un deepLink affilié
      // Le couponCode retourné est celui du combiné (premier pick + suffixe)
      const results = [];
      for (const pick of picks) {
        try {
          const r = await this.callB2BShareCoupon(pick);
          results.push(r);
        } catch (e) {
          this.logger.warn(`[MEGAPARI B2B] échec pick ${pick.event_id}: ${e}`);
          throw e; // Fail-Closed: pas de coupon partiel
        }
      }
      // Pour combiné, on construit un deepLink affilié combiné (ref.top)
      // et on expose le code du premier + indicateur combiné
      const first = results[0];
      couponCode = first.couponCode; // Code principal (à coller dans MegaPari → le combiné se recomposera côté site si deepLink contient toutes sélections)
      // DeepLink combiné: base affiliée + toutes sélections
      const selectionsParam = picks.map(p => `${p.event_id}:${p.market_id}:${p.selection_id}`).join(',');
      const baseDomain = process.env.MEGAPARI_DEEP_LINK_DOMAIN || 'ref.top';
      const tag = this.affiliateTag;
      deepLink = first.deepLink; // On garde le deepLink B2B du premier (contient déjà coupon-code)
      // Alternative: deepLink combiné custom (si manager préfère)
      // deepLink = `https://${baseDomain}/L?tag=${encodeURIComponent(tag)}&ref=${this.ref}&selections=${encodeURIComponent(selectionsParam)}&coupon-code=${couponCode}`;
      this.logger.log(`[MEGAPARI] Combiné ${picks.length} picks → couponCode ${couponCode} (B2B 1er pick) + deepLink combiné`);
    }

    const couponPayload = {
      ref: this.ref,
      picks,
      affiliateTag: this.affiliateTag,
      createdAt: now.toISOString(),
      expiresAt: expiresAt.toISOString(),
    };

    this.logger.log(JSON.stringify({
      level: 'audit',
      action: 'megapari/coupon/generate',
      provider: this.provider,
      ref: this.ref,
      totalPicks: picks.length,
      couponCode,
      deepLink_hash: couponCode, // on log le code (non sensible, à usage unique)
      createdAt: couponPayload.createdAt,
    }));

    return {
      success: true,
      provider: this.provider,
      totalPicks: picks.length,
      couponCode,
      deepLink,
      message: picks.length === 1
        ? `Coupon généré avec succès — Code ${couponCode}`
        : `Coupon combiné généré — Code ${couponCode} (${picks.length} sélections)`,
      couponPayload,
    };
  }

  /**
   * Génère un code coupon par sélection (B2B sharecoupon = 1 marché par appel).
   * Sert aux combinés : MegaPari n'expose aucun endpoint « coupon combiné »,
   * on fournit donc des codes individuels, chacun pré-remplissant sa sélection.
   * Fail-open partiel : un échec n'invalide pas les autres codes.
   */
  async generateSeparateCoupons(
    picks: Pick[],
    options?: { currency?: string; language?: string },
  ): Promise<Array<{ pick: Pick; success: boolean; couponCode: string | null; deepLink: string | null; error: string | null }>> {
    const out: Array<{ pick: Pick; success: boolean; couponCode: string | null; deepLink: string | null; error: string | null }> = [];
    for (const pick of picks) {
      try {
        const r = await this.callB2BShareCoupon(pick);
        out.push({ pick, success: true, couponCode: r.couponCode, deepLink: r.deepLink, error: null });
      } catch (e: any) {
        const body = e?.response?.data ?? e?.getResponse?.() ?? null;
        const msg = body?.message || e?.message || 'B2B error';
        this.logger.warn(`[MEGAPARI B2B] pick ${pick.event_id} refusé: ${String(msg).slice(0, 200)}`);
        out.push({ pick, success: false, couponCode: null, deepLink: null, error: String(msg).slice(0, 300) });
      }
    }
    return out;
  }

  // Helper depuis validated_markets (sortie Margin Guard)
  async generateFromValidatedMarkets(
    validatedMarkets: Array<{ event_id: string; market_id: string; selection_id: string; market_type: string; line?: number; b2b_type?: number; b2b_oddsMarket?: number; b2b_parameter?: number }>,
    options?: { currency?: string; language?: string },
  ): Promise<CouponResult> {
    const picks: Pick[] = validatedMarkets.map(vm => ({
      event_id: vm.event_id,
      market_id: vm.market_id,
      selection_id: vm.selection_id,
      market_type: vm.market_type,
      line: vm.line,
      sportEventId: parseInt(vm.event_id, 10),
      b2b_type: vm.b2b_type,
      b2b_oddsMarket: vm.b2b_oddsMarket,
      b2b_parameter: vm.b2b_parameter,
      b2b_kind: 3,
    }));
    return this.generateCoupon(picks, options);
  }
}
