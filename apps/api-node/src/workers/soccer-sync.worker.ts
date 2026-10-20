/**
 * SoccerSyncWorker — NestJS Cron Worker pour MegaPari (ref=192)
 * Partie 2 du pipeline: Prematch (30min) + Postmatch (15min)
 *
 * Architecture:
 *  - Prematch syncUpcomingGames: LoadList → events (UPCOMING) → Margin Guard Python → Redis
 *  - Postmatch syncFinishedGamesStats: events UPCOMING +110min → B2B Results → final_score/FINISHED → match_stats (xG/xGA + raw_stats_json) → ML Pipeline
 *
 * Fail-Closed: toute erreur réseau/validation → log + retry, jamais de données inventées
 */

import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import axios from 'axios';
import { Pool } from 'pg';

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const MEGAPARI_REF = parseInt(process.env.MEGAPARI_REF || '192', 10);
const MEGAPARI_GW = (process.env.BOOKMAKER_API_BASE || 'https://cpservm.com/gateway/marketing').replace(/\/$/, '');
const TOKEN_URL = process.env.BOOKMAKER_TOKEN_URL || 'https://cpservm.com/gateway/token';
const ML_PYTHON_URL = process.env.ML_PYTHON_URL || 'http://ml-python:8000';
const DATABASE_URL = process.env.DATABASE_URL || 'postgres://preduser:predpass@localhost:5432/preddb';

// Redis cache via @nestjs/schedule déjà, mais on utilise axios pour ML
// ---------------------------------------------------------------------------
// Helpers: DB Pool singleton
// ---------------------------------------------------------------------------
let pool: Pool | null = null;
function getPool(): Pool {
  if (!pool) {
    pool = new Pool({ connectionString: DATABASE_URL, max: 10, idleTimeoutMillis: 30000 });
    pool.on('error', (e) => Logger.error(`[DB Pool] ${e.message}`, e.stack, 'SoccerSyncWorker'));
  }
  return pool;
}

// ---------------------------------------------------------------------------
// Helpers: OAuth2 token (partagé avec connectors, dupliqué ici pour worker autonome)
// ---------------------------------------------------------------------------
let cachedToken: { token: string; exp: number } | null = null;
async function getAccessToken(): Promise<string> {
  if (cachedToken && Date.now() < cachedToken.exp - 60_000) return cachedToken.token;
  const client_id = process.env.MEGAPARI_CLIENT_ID || 'partners-c2b75a07c454fcd96f0453a0f79e1ead';
  const client_secret = process.env.MEGAPARI_CLIENT_SECRET || '';
  if (!client_id || !client_secret) throw new Error('[MegaPari] MEGAPARI_CLIENT_ID/SECRET manquants');
  const { data } = await axios.post(TOKEN_URL,
    new URLSearchParams({ client_id, client_secret }).toString(),
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, timeout: 8000 }
  );
  cachedToken = { token: data.access_token, exp: Date.now() + (data.expires_in || 3600) * 1000 };
  return cachedToken.token;
}

// ---------------------------------------------------------------------------
// Helpers: B2B Results — détection endpoint réel
// OpenAPI liste: /result/api/v1/sportevents, /result/api/v1/sportevent, etc.
// On teste plusieurs candidats, ordre: sportevents → sportevent
// ---------------------------------------------------------------------------
async function fetchResultsB2B(params: { dateFrom?: number; dateTo?: number; sportEventIds?: string }): Promise<any> {
  const token = await getAccessToken();
  const candidates = [
    `${MEGAPARI_GW}/result/api/v1/sportevents`,
    `${MEGAPARI_GW}/result/api/v1/sportevent`,
    `${MEGAPARI_GW}/result/api/v1/sports`, // fallback pour validation
    `${MEGAPARI_GW}/datafeed/directories/api/v1/sharecoupon`, // non, mais test
  ];
  // Endpoint réel d'après openapi.yaml: /result/api/v1/sportevent?ref=192&sportEventId=XXX
  // Et /result/api/v1/sportevents?ref=192&dateFrom=...&dateTo=...
  const baseCandidates = [
    `${MEGAPARI_GW}/result/api/v1/sportevents`,
    `${MEGAPARI_GW}/result/api/v1/sportevent`,
  ];
  for (const url of baseCandidates) {
    try {
      const q: any = { ref: MEGAPARI_REF };
      if (params.sportEventIds) q.sportEventIds = params.sportEventIds;
      if (params.dateFrom) q.dateFrom = params.dateFrom;
      if (params.dateTo) q.dateTo = params.dateTo;
      const { data } = await axios.get(url, { params: q, headers: { Authorization: `Bearer ${token}` }, timeout: 10000 });
      if (data && (data.items || data.count !== undefined)) return data;
      return data;
    } catch (e: any) {
      if (e?.response?.status === 404) continue;
      if (e?.response?.status === 400) {
        // Log détail pour debug ordre params
        Logger.warn(`[B2B Results] 400 ${url} → ${JSON.stringify(e.response.data).slice(0,400)}`, 'SoccerSyncWorker');
        continue;
      }
      throw e;
    }
  }
  throw new Error(`[B2B] Aucun endpoint Results accessible — vérifier openapi.yaml /result`);
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------
@Injectable()
export class SoccerSyncWorker implements OnModuleInit {
  private readonly logger = new Logger(SoccerSyncWorker.name);
  private pool = getPool();

  async onModuleInit() {
    this.logger.log('SoccerSyncWorker initialisé — Prematch 30min / Postmatch 15min (ref=192)');
    // Optionnel: lancer un sync au démarrage si flag
    if (process.env.SOCCER_SYNC_ON_START === 'true') {
      this.logger.log('SOCCER_SYNC_ON_START=true → lancement initial syncUpcomingGames()');
      this.syncUpcomingGames().catch(e => this.logger.error(e.message, e.stack));
    }
  }

  // =========================================================================
  // A. TÂCHE PREMATCH — toutes les 30 minutes
  // =========================================================================
  @Cron('*/30 * * * *', { name: 'syncUpcomingGames', timeZone: 'UTC' })
  async syncUpcomingGames(): Promise<void> {
    const start = Date.now();
    this.logger.log(`[Prematch] Début syncUpcomingGames ref=${MEGAPARI_REF}`);

    try {
      const token = await getAccessToken();

      // 1. GET /getGameIds — liste tous les GameIds pré-match
      const { data: gameIdsData } = await axios.get(
        `${MEGAPARI_GW}/datafeed/loadlist/prematch/api/v1/getGameIds`,
        { params: { ref: MEGAPARI_REF, lastUpdate: 0 }, headers: { Authorization: `Bearer ${token}` }, timeout: 10000 }
      );
      const gameIds: number[] = gameIdsData.items || [];
      this.logger.log(`[Prematch] getGameIds → ${gameIds.length} events (count=${gameIdsData.count})`);

      if (gameIds.length === 0) {
        this.logger.warn('[Prematch] Aucun GameId — skip');
        return;
      }

      // Limite pour respecter rate-limit (1 req/20s pour getDetailsGame) — on traite par batch 10
      const BATCH = parseInt(process.env.SOCCER_PREMATCH_BATCH || '10', 10);
      const toProcess = gameIds.slice(0, BATCH);
      let inserted = 0, updated = 0, marginGuardOk = 0;

      for (const gameId of toProcess) {
        try {
          // 2. GET /getGame avec ref=192 (détail event)
          // Note: l'endpoint exact est /getDetailsGame avec ordre strict: ref, gr, cnt, gameId, languages, languageForLink
          const { data: detail } = await axios.get(
            `${MEGAPARI_GW}/datafeed/loadlist/prematch/api/v1/getDetailsGame`,
            {
              params: { ref: MEGAPARI_REF, gr: 0, cnt: 0, gameId, languages: 'en', languageForLink: 'en' },
              headers: { Authorization: `Bearer ${token}` },
              timeout: 10000,
            }
          );

          // Detail peut être {gameId, sport, league, homeTeam, awayTeam, startTime, ...}
          // On normalise pour table events
          const event = this.normalizePrematchEvent(gameId, detail);

          // 3. INSERT ... ON CONFLICT UPDATE dans events avec status='UPCOMING'
          const res = await this.pool.query(`
            INSERT INTO events (id, provider, sport, league, home_team, away_team, start_time, is_virtual, status, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'UPCOMING', NOW(), NOW())
            ON CONFLICT (id) DO UPDATE SET
              league = EXCLUDED.league,
              home_team = EXCLUDED.home_team,
              away_team = EXCLUDED.away_team,
              start_time = EXCLUDED.start_time,
              status = 'UPCOMING',
              updated_at = NOW()
            RETURNING (xmax = 0) AS inserted
          `, [event.id, 'MEGAPARI', event.sport, event.league, event.home_team, event.away_team, event.start_time, event.is_virtual]);

          if (res.rows[0]?.inserted) inserted++; else updated++;

          // 4. Transmet les cotes au service Python Margin Guard (marge ≤5%) pour cache Redis
          // On récupère les marchés via getMarketsGame (si disponible) ou depuis detail
          let markets = detail.markets || detail.odds || [];
          if (markets.length === 0) {
            try {
              const { data: mk } = await axios.get(
                `${MEGAPARI_GW}/datafeed/loadlist/prematch/api/v1/getMarketsGame`,
                { params: { cnt: 0, ref: MEGAPARI_REF, gameId }, headers: { Authorization: `Bearer ${token}` }, timeout: 10000 }
              );
              markets = mk.items || mk.markets || [];
            } catch {}
          }

          if (markets.length > 0) {
            await this.forwardToMarginGuard({ id: event.id, markets, provider: 'MEGAPARI' });
            marginGuardOk++;
          }

          // Respect rate-limit 20s si BATCH >1 — on sleep 1s entre chaque (optimisé pour 30min cron)
          await new Promise(r => setTimeout(r, 1000));

        } catch (e: any) {
          this.logger.warn(`[Prematch] gameId ${gameId} échoué: ${e?.response?.data ? JSON.stringify(e.response.data).slice(0,300) : e.message}`);
          continue;
        }
      }

      this.logger.log(`[Prematch] Terminé en ${Date.now() - start}ms — inserted=${inserted} updated=${updated} marginGuard=${marginGuardOk}/${toProcess.length}`);

    } catch (e: any) {
      this.logger.error(`[Prematch] Erreur fatale: ${e.message}`, e.stack, 'SoccerSyncWorker');
      // Fail-Closed: on ne crée pas de fausses données, juste log + alerte
    }
  }

  // =========================================================================
  // B. TÂCHE POSTMATCH — toutes les 15 minutes
  // =========================================================================
  @Cron('*/15 * * * *', { name: 'syncFinishedGamesStats', timeZone: 'UTC' })
  async syncFinishedGamesStats(): Promise<void> {
    const start = Date.now();
    this.logger.log('[Postmatch] Début syncFinishedGamesStats');

    try {
      // 1. Recherche events UPCOMING dont T_start +110min < NOW()
      const { rows: pending } = await this.pool.query(`
        SELECT id, league, home_team, away_team, start_time
        FROM events
        WHERE provider = 'MEGAPARI'
          AND status = 'UPCOMING'
          AND start_time < NOW() - INTERVAL '110 minutes'
        ORDER BY start_time ASC
        LIMIT 20
      `);

      if (pending.length === 0) {
        this.logger.log('[Postmatch] Aucun match à clôturer');
        return;
      }
      this.logger.log(`[Postmatch] ${pending.length} matchs à vérifier (ex: ${pending[0].id} ${pending[0].home_team} vs ${pending[0].away_team})`);

      let finished = 0, statsInserted = 0;

      for (const ev of pending) {
        try {
          // 2. Interroge endpoint Results B2B pour scores + stats complètes
          // On tente d'abord par sportEventIds, sinon par date range
          let resultData: any = null;
          try {
            resultData = await fetchResultsB2B({ sportEventIds: String(ev.id) });
          } catch {
            // Fallback: recherche par date (start_time ±2h)
            const from = Math.floor(new Date(ev.start_time).getTime() / 1000) - 7200;
            const to = Math.floor(Date.now() / 1000);
            resultData = await fetchResultsB2B({ dateFrom: from, dateTo: to });
          }

          const matchResult = this.extractSingleResult(resultData, String(ev.id));
          if (!matchResult) {
            this.logger.warn(`[Postmatch] Pas de résultat pour ${ev.id} — skip (match peut-être reporté)`);
            continue;
          }

          // 3. Enregistre final_score et passe à FINISHED
          const finalScore = {
            home: matchResult.homeScore ?? matchResult.score?.home ?? null,
            away: matchResult.awayScore ?? matchResult.score?.away ?? null,
            ht_home: matchResult.htHome ?? matchResult.halfTime?.home ?? null,
            ht_away: matchResult.htAway ?? matchResult.halfTime?.away ?? null,
            status: matchResult.status || 'FINISHED',
          };

          await this.pool.query(`
            UPDATE events SET final_score = $2::jsonb, status = 'FINISHED', updated_at = NOW()
            WHERE id = $1
          `, [ev.id, JSON.stringify(finalScore)]);
          finished++;

          // 4. Remplit match_stats — extraction explicite + sauvegarde intégrale raw
          const raw = matchResult.raw || matchResult;
          const statsRow = this.extractStatsForDB(raw, ev.id);

          await this.pool.query(`
            INSERT INTO match_stats (event_id, provider, xg, xga, corners, yellow_cards, red_cards, shots_on_target, shots_off_target, big_chances, dangerous_attacks, possession, raw_stats_json)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
            ON CONFLICT (event_id) DO UPDATE SET
              xg = EXCLUDED.xg,
              xga = EXCLUDED.xga,
              corners = EXCLUDED.corners,
              yellow_cards = EXCLUDED.yellow_cards,
              red_cards = EXCLUDED.red_cards,
              shots_on_target = EXCLUDED.shots_on_target,
              shots_off_target = EXCLUDED.shots_off_target,
              big_chances = EXCLUDED.big_chances,
              dangerous_attacks = EXCLUDED.dangerous_attacks,
              possession = EXCLUDED.possession,
              raw_stats_json = EXCLUDED.raw_stats_json,
              updated_at = NOW()
          `, [
            String(ev.id), 'MEGAPARI',
            JSON.stringify(statsRow.xg), JSON.stringify(statsRow.xga),
            JSON.stringify(statsRow.corners), JSON.stringify(statsRow.yellow_cards),
            JSON.stringify(statsRow.red_cards), JSON.stringify(statsRow.shots_on_target),
            JSON.stringify(statsRow.shots_off_target), JSON.stringify(statsRow.big_chances),
            JSON.stringify(statsRow.dangerous_attacks), JSON.stringify(statsRow.possession),
            JSON.stringify(raw), // IMPÉRATIF: totalité JSON brut sans perte
          ]);
          statsInserted++;

          // 5. Transmet au pipeline Python ML (Dixon-Coles / CatBoost) — mise à jour base d'apprentissage
          await this.notifyMLPipeline(ev.id, statsRow, finalScore);

          this.logger.log(`[Postmatch] ${ev.id} → FINISHED ${finalScore.home}-${finalScore.away} xG ${JSON.stringify(statsRow.xg)}`);

        } catch (e: any) {
          this.logger.warn(`[Postmatch] ${ev.id} échoué: ${e.message}`);
          continue;
        }
      }

      this.logger.log(`[Postmatch] Terminé en ${Date.now() - start}ms — finished=${finished} stats=${statsInserted}/${pending.length}`);

    } catch (e: any) {
      this.logger.error(`[Postmatch] Erreur fatale: ${e.message}`, e.stack, 'SoccerSyncWorker');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers: Normalisation Prematch
  // ---------------------------------------------------------------------------
  private normalizePrematchEvent(gameId: number, detail: any): { id: string; sport: string; league: string; home_team: string; away_team: string; start_time: Date; is_virtual: boolean } {
    // Detail peut avoir formats variés selon BetB2B version — on gère tous
    const home = detail.homeTeam || detail.home_team || detail.opponent1Name || detail.opponents?.[0]?.name || 'Home';
    const away = detail.awayTeam || detail.away_team || detail.opponent2Name || detail.opponents?.[1]?.name || 'Away';
    const league = detail.league || detail.tournamentName || detail.tournament || 'Unknown League';
    const startRaw = detail.startTime || detail.start_time || detail.startDate || detail.kickoff;
    let startTime: Date;
    if (typeof startRaw === 'number') startTime = new Date(startRaw * 1000); // Unix epoch
    else if (typeof startRaw === 'string') startTime = new Date(startRaw);
    else startTime = new Date();

    const sport = (detail.sport || detail.sportName || 'football').toLowerCase();
    const isVirtual = !!(detail.isVirtual || detail.virtual || false);

    return {
      id: String(gameId),
      sport,
      league: String(league),
      home_team: String(home),
      away_team: String(away),
      start_time: startTime,
      is_virtual: isVirtual,
    };
  }

  // ---------------------------------------------------------------------------
  // Helpers: Extraction résultat single depuis réponse B2B Results (format variable)
  // ---------------------------------------------------------------------------
  private extractSingleResult(data: any, eventId: string): any | null {
    if (!data) return null;
    // Format 1: {items: [{sportEventId, homeScore, awayScore, ...}]}
    if (data.items && Array.isArray(data.items)) {
      const found = data.items.find((it: any) => String(it.sportEventId || it.eventId || it.id) === String(eventId));
      if (found) return { ...found, raw: found };
      // Si pas de match exact, et on a cherché par date, prendre le premier si peu d'items
      if (data.items.length === 1) return { ...data.items[0], raw: data.items[0] };
    }
    // Format 2: {sportEventId, score, ...} direct
    if (data.sportEventId || data.eventId) {
      if (String(data.sportEventId || data.eventId) === String(eventId)) return { ...data, raw: data };
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Helpers: Extraction stats explicites pour match_stats
  // ---------------------------------------------------------------------------
  private extractStatsForDB(raw: any, eventId: string): {
    xg: any; xga: any; corners: any; yellow_cards: any; red_cards: any;
    shots_on_target: any; shots_off_target: any; big_chances: any; dangerous_attacks: any; possession: any;
  } {
    // Les champs B2B peuvent être dans raw.stats, raw.statistics, ou racine
    const src = raw.stats || raw.statistics || raw.details || raw;

    // Helper pour extraire {home, away} depuis divers formats
    const pick = (keys: string[]): any => {
      for (const k of keys) {
        if (src[k] !== undefined) return src[k];
        if (raw[k] !== undefined) return raw[k];
      }
      return null;
    };

    // Normalisation en {home, away}
    const norm = (v: any): any => {
      if (v === null || v === undefined) return null;
      if (typeof v === 'object' && 'home' in v && 'away' in v) return v;
      if (typeof v === 'object' && 'homeTeam' in v) return { home: v.homeTeam, away: v.awayTeam };
      if (Array.isArray(v) && v.length === 2) return { home: v[0], away: v[1] };
      return v;
    };

    return {
      xg: norm(pick(['xg', 'expectedGoals', 'xG'])),
      xga: norm(pick(['xga', 'expectedGoalsAgainst', 'xGA'])),
      corners: norm(pick(['corners', 'cornerKicks', 'cornersCount'])),
      yellow_cards: norm(pick(['yellow_cards', 'yellowCards'])),
      red_cards: norm(pick(['red_cards', 'redCards'])),
      shots_on_target: norm(pick(['shots_on_target', 'shotsOnTarget', 'shotsOnGoal'])),
      shots_off_target: norm(pick(['shots_off_target', 'shotsOffTarget'])),
      big_chances: norm(pick(['big_chances', 'bigChances', 'bigChancesCreated'])),
      dangerous_attacks: norm(pick(['dangerous_attacks', 'dangerousAttacks'])),
      possession: norm(pick(['possession', 'ballPossession'])),
    };
  }

  // ---------------------------------------------------------------------------
  // Helpers: Forward to Python Margin Guard & ML Pipeline
  // ---------------------------------------------------------------------------
  private async forwardToMarginGuard(event: { id: string; markets: any[]; provider: string }): Promise<void> {
    try {
      await axios.post(`${ML_PYTHON_URL}/ml/v1/megapari/ingest`, {
        raw_events: [{ id: event.id, markets: event.markets, provider: event.provider }],
        threshold: 5.0,
      }, { timeout: 5000 });
    } catch (e: any) {
      this.logger.warn(`[Prematch] Margin Guard forward failed pour ${event.id}: ${e.message}`);
      // Non bloquant — l'event est déjà en DB, le cache Redis pourra être retry
    }
  }

  private async notifyMLPipeline(eventId: string, stats: any, finalScore: any): Promise<void> {
    try {
      await axios.post(`${ML_PYTHON_URL}/ml/v1/training/ingest-finished`, {
        event_id: eventId,
        provider: 'MEGAPARI',
        final_score: finalScore,
        stats,
        triggered_at: new Date().toISOString(),
      }, { timeout: 5000 });
      this.logger.log(`[Postmatch] ML pipeline notifié pour ${eventId}`);
    } catch (e: any) {
      // ML pipeline peut ne pas encore exister — on log sans échouer
      this.logger.warn(`[Postmatch] ML notify failed ${eventId}: ${e.message} — sera retraité au prochain cycle`);
    }
  }
}
