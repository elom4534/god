-- ============================================================================
-- Migration 004 — Football Virtuel temps réel (FIFA Virtual & Sega Virtual)
-- Source unique : flux Partner API MegaPari (aucune donnée simulée/estimée).
-- Schéma conforme au brief (5 tables) + colonnes de traçabilité réelle.
-- Idempotent : rejouable sans erreur.
-- ============================================================================
BEGIN;

-- ------------------------------------------------------------- virtual_rounds
-- Un « round » = un match virtuel. round_id = constSportEventId du flux.
CREATE TABLE IF NOT EXISTS virtual_rounds (
    round_id        TEXT PRIMARY KEY,
    provider        TEXT NOT NULL CHECK (provider IN ('FIFA_VIRTUAL', 'SEGA_VIRTUAL')),
    league          TEXT,
    home_team       TEXT NOT NULL,
    away_team       TEXT NOT NULL,
    scheduled_start TIMESTAMPTZ NOT NULL,
    started_at      TIMESTAMPTZ,
    ended_at        TIMESTAMPTZ,
    status          TEXT NOT NULL DEFAULT 'SCHEDULED'
                    CHECK (status IN ('SCHEDULED', 'LIVE', 'FINISHED', 'CANCELLED')),
    home_score      INT,
    away_score      INT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- --- traçabilité flux réel -------------------------------------------
    tournament_id   BIGINT,
    api_event_id    BIGINT,                  -- sportEventId
    api_const_event_id BIGINT,               -- constSportEventId
    time_sec        INT,                     -- minute de jeu (timeSec du flux)
    period_name     TEXT,                    -- ex. "1st half" / "2nd half"
    match_format    TEXT,                    -- ex. "2 halves of 20 minutes"
    home_logo       TEXT,
    away_logo       TEXT,
    source_ts       TIMESTAMPTZ,             -- horodatage du flux
    captured_at     TIMESTAMPTZ,             -- UTC capture applicative
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_virtual_rounds_provider_status
    ON virtual_rounds (provider, status);
CREATE INDEX IF NOT EXISTS idx_virtual_rounds_scheduled
    ON virtual_rounds (scheduled_start);
CREATE INDEX IF NOT EXISTS idx_virtual_rounds_api_ids
    ON virtual_rounds (api_event_id, api_const_event_id);

-- ------------------------------------------------------ virtual_odds_snapshots
-- Chaque snapshot de cotes avant/après le round : 1X2, BTTS, O/U (toutes
-- lignes) + tout le reste du catalogue réel. Horodatage double/triple.
CREATE TABLE IF NOT EXISTS virtual_odds_snapshots (
    id           BIGSERIAL PRIMARY KEY,
    round_id     TEXT NOT NULL REFERENCES virtual_rounds (round_id) ON DELETE CASCADE,
    snapshot_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),   -- UTC serveur
    market       TEXT NOT NULL,                        -- 1X2 | BTTS | TOTAL | …
    selection    TEXT NOT NULL,                        -- 1 | X | 2 | YES | NO | OVER | UNDER | …
    odds         NUMERIC(10, 4) NOT NULL,
    raw          JSONB,                                -- objet oddsLocalization complet
    -- --- traçabilité flux réel -------------------------------------------
    line         NUMERIC(6, 2),                        -- ligne O/U, handicap, …
    phase        TEXT NOT NULL DEFAULT 'PREMATCH' CHECK (phase IN ('PREMATCH', 'LIVE')),
    is_blocked   BOOLEAN NOT NULL DEFAULT FALSE,
    source_ts    TIMESTAMPTZ,
    captured_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_virtual_odds_round
    ON virtual_odds_snapshots (round_id, snapshot_at);
CREATE INDEX IF NOT EXISTS idx_virtual_odds_market
    ON virtual_odds_snapshots (round_id, market, selection, snapshot_at);

-- --------------------------------------------------------- virtual_live_events
-- Événements dérivés des écarts de score réels du flux live (jamais inventés).
CREATE TABLE IF NOT EXISTS virtual_live_events (
    id          BIGSERIAL PRIMARY KEY,
    round_id    TEXT NOT NULL REFERENCES virtual_rounds (round_id) ON DELETE CASCADE,
    event_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    minute      INT,
    event_type  TEXT NOT NULL
                CHECK (event_type IN ('KICKOFF', 'TICK', 'GOAL_HOME', 'GOAL_AWAY',
                                      'HALFTIME', 'FULLTIME')),
    detail      JSONB
);

CREATE INDEX IF NOT EXISTS idx_virtual_live_events_round
    ON virtual_live_events (round_id, event_at);

-- ------------------------------------------------------------ virtual_results
-- Résultat exact à la clôture (result/api/v1/sportevents, score réel).
CREATE TABLE IF NOT EXISTS virtual_results (
    round_id     TEXT PRIMARY KEY REFERENCES virtual_rounds (round_id) ON DELETE CASCADE,
    closed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    home_score   INT NOT NULL,
    away_score   INT NOT NULL,
    btts         BOOLEAN NOT NULL,
    over_2_5     BOOLEAN NOT NULL,
    raw          JSONB,
    -- --- traçabilité ------------------------------------------------------
    source       TEXT NOT NULL DEFAULT 'result_api'
                 CHECK (source IN ('result_api', 'live_feed')),
    half_time    TEXT,
    ratings_applied_at TIMESTAMPTZ        -- update incrémentale une seule fois
);

CREATE INDEX IF NOT EXISTS idx_virtual_results_closed
    ON virtual_results (closed_at DESC);

-- --------------------------------------------------------- virtual_team_ratings
-- Ratings Dixon-Coles + Elo, PAR PROVIDER (jamais mélangés).
CREATE TABLE IF NOT EXISTS virtual_team_ratings (
    provider        TEXT NOT NULL CHECK (provider IN ('FIFA_VIRTUAL', 'SEGA_VIRTUAL')),
    team            TEXT NOT NULL,
    elo_rating      NUMERIC(8, 2) NOT NULL DEFAULT 1500,
    attack_rating   NUMERIC(8, 4) NOT NULL DEFAULT 0,   -- force d'attaque (log)
    defense_rating  NUMERIC(8, 4) NOT NULL DEFAULT 0,   -- solidité défense (log)
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    matches_count   INT NOT NULL DEFAULT 0,
    PRIMARY KEY (provider, team)
);

COMMIT;
