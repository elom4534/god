/**
 * Base connector BetB2B — utilisé à l'identique pour MegaPari et 1xBet
 * Seuls client_id / client_secret / ref changent.
 * Gateway unique: https://cpservm.com/gateway/marketing
 * Token: POST https://cpservm.com/gateway/token (OAuth2 client_credentials, form-urlencoded, --data-urlencode)
 */
import axios from 'axios';
import { createClient } from 'redis';

const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379';
const GATEWAY_BASE = (process.env.BOOKMAKER_API_BASE || 'https://cpservm.com/gateway/marketing').replace(/\/$/, '');
const TOKEN_URL = process.env.BOOKMAKER_TOKEN_URL || 'https://cpservm.com/gateway/token';

let redis: any = null;
async function getRedis() {
  if (redis) return redis;
  try { redis = createClient({ url: REDIS_URL }); await redis.connect(); return redis; } catch { return null; }
}

export interface ProviderConfig {
  name: '1xBet' | 'Méga Pari';
  client_id: string;
  client_secret: string;
  ref: number;
}

export function loadConfig(name: '1xBet' | 'Méga Pari'): ProviderConfig {
  if (name === 'Méga Pari') {
    return {
      name: 'Méga Pari',
      client_id: process.env.MEGAPARI_CLIENT_ID || process.env.BOOKMAKER_CLIENT_ID || 'partners-c2b75a07c454fcd96f0453a0f79e1ead',
      client_secret: process.env.MEGAPARI_CLIENT_SECRET || process.env.BOOKMAKER_CLIENT_SECRET || '',
      ref: parseInt(process.env.MEGAPARI_REF || '192', 10),
    };
  }
  return {
    name: '1xBet',
    client_id: process.env.XBET_CLIENT_ID || 'partners-592d3a39b56e7ca211a846129d6fc5e3',
    client_secret: process.env.XBET_CLIENT_SECRET || '',
    ref: parseInt(process.env.XBET_REF || '1', 10),
  };
}

export class BaseBetB2BConnector {
  constructor(public provider: '1xBet' | 'Méga Pari') {}

  get cfg() { return loadConfig(this.provider); }
  get base() { return GATEWAY_BASE; }

  /** OAuth2 client_credentials — IDENTIQUE pour les 2 providers */
  async getAccessToken(): Promise<string> {
    const c = this.cfg;
    if (!c.client_id || !c.client_secret) throw new Error(`[${c.name}] client_id/client_secret manquants`);
    const clientSecret = c.client_secret.replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'");
    const cacheKey = `bookmaker:token:${c.name}:${c.ref}:${c.client_id.slice(-6)}`;
    const r = await getRedis();
    if (r) { const cached = await r.get(cacheKey).catch(()=>null); if (cached) return cached; }

    const { data } = await axios.post(TOKEN_URL,
      new URLSearchParams({ client_id: c.client_id, client_secret: clientSecret }).toString(),
      { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, timeout: 8000 }
    );
    const token = data.access_token;
    const exp = data.expires_in || 3600;
    if (!token) throw new Error(`[${c.name}] pas de token`);
    if (r) await r.setEx(cacheKey, Math.max(60, exp - 60), token);
    return token;
  }

  /** Helper GET avec Bearer — headers identiques */
  private async get(path: string, params: Record<string, any>, token: string) {
    const url = `${this.base}${path}`;
    return axios.get(url, { params, headers: { Authorization: `Bearer ${token}` }, timeout: 10000 });
  }

  // ---- LoadList (prematch) — MÊME signatures, MÊME ordre params ----
  async getGameIds(lastUpdate = 0) {
    const c = this.cfg;
    const token = await this.getAccessToken();
    const { data } = await this.get('/datafeed/loadlist/prematch/api/v1/getGameIds', { ref: c.ref, lastUpdate }, token);
    return data; // {count, lastIndex, items}
  }

  async getDetailsGame(gameId: number, gr = 0, cnt = 0) {
    const c = this.cfg;
    const token = await this.getAccessToken();
    // ORDRE STRICT ref, gr, cnt, gameId, languages, languageForLink
    const params = { ref: c.ref, gr, cnt, gameId, languages: 'en', languageForLink: 'en' };
    const { data } = await this.get('/datafeed/loadlist/prematch/api/v1/getDetailsGame', params, token);
    return data;
  }

  async getMarketsGame(gameId: number, cnt = 0) {
    const c = this.cfg;
    const token = await this.getAccessToken();
    // ORDRE STRICT cnt, ref, gameId
    const { data } = await this.get('/datafeed/loadlist/prematch/api/v1/getMarketsGame', { cnt, ref: c.ref, gameId }, token);
    return data;
  }

  // ---- LoadTree (prematch) ----
  async sportList() {
    const c = this.cfg;
    const token = await this.getAccessToken();
    const { data } = await this.get('/datafeed/loadtree/prematch/api/v1/sportList', { ref: c.ref }, token);
    return data;
  }

  async tournaments(sportId: number) {
    const c = this.cfg;
    const token = await this.getAccessToken();
    const { data } = await this.get('/datafeed/loadtree/prematch/api/v1/tournaments', { ref: c.ref, sportId }, token);
    return data;
  }

  async sporteventIds(tournamentId: number) {
    const c = this.cfg;
    const token = await this.getAccessToken();
    const { data } = await this.get('/datafeed/loadtree/prematch/api/v1/sporteventIds', { ref: c.ref, tournamentId }, token);
    return data;
  }

  async sporteventDetail(sportEventId: number, withSubGames = true) {
    const c = this.cfg;
    const token = await this.getAccessToken();
    const params: any = { ref: c.ref, gr: 0, cnt: 0, sportEventId, withSubGames, schemeOfGettingOdds: 'GetAllOdds' };
    const { data } = await this.get('/datafeed/loadtree/prematch/api/v1/sporteventDetail', params, token);
    return data;
  }

  // ---- LoadSingle (fallback si LoadList 403) — 1xBet a accès à celui-ci ----
  async loadSinglePreMatch(count = 5, sportIds?: string) {
    const c = this.cfg;
    const token = await this.getAccessToken();
    const params: any = { ref: c.ref, count };
    if (sportIds) params.sportIds = sportIds;
    const { data } = await this.get('/datafeed/prematch/api/v2/sportevents', params, token);
    return data; // {count, items: [sportEvent... avec link 1xBet ou Megapari selon ref]}
  }

  /** Wrapper unifié avec fallback LoadList → LoadSingle si 403 */
  async getGameIdsWithFallback(lastUpdate = 0) {
    try {
      return await this.getGameIds(lastUpdate);
    } catch (e: any) {
      if (e?.response?.status === 403) {
        console.warn(`[${this.cfg.name}] LoadList 403 → fallback LoadSingle (scopes manquants, voir manager)`);
        const single = await this.loadSinglePreMatch(100);
        // Normalise en même format {count, items: [sportEventId]}
        const items = (single.items || []).map((ev: any) => ev.sportEventId);
        return { count: items.length, lastIndex: Date.now(), items, fallback: 'LoadSingle' };
      }
      throw e;
    }
  }
}
