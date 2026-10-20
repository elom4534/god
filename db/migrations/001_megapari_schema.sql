-- ============================================================================
-- Migration 001 — MegaPari Integration (ref=192) — PostgreSQL 15+
-- Fail-Closed & Réutilisable 1xBet (même schéma, provider différent)
-- ============================================================================
-- Auteur: Backend Trading Sportif
-- Date: 2026-10-19
-- Dépendances: extension pgcrypto pour gen_random_uuid() (ou uuid-ossp)

BEGIN;

-- Extensions utiles
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- --------------------------------------------------------------------------
-- 1. Table events — Source de vérité pré-match (LoadList / LoadSingle)
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS events (
    id              BIGINT PRIMARY KEY,               -- GameId MegaPari (sportEventId / constSportEventId)
    provider        VARCHAR(20) NOT NULL CHECK (provider IN ('MEGAPARI','1XBET','LIVE_FOOTBALL')),
    sport           VARCHAR(50) NOT NULL DEFAULT 'football',
    league          VARCHAR(200) NOT NULL,
    home_team       VARCHAR(200) NOT NULL,
    away_team       VARCHAR(200) NOT NULL,
    start_time      TIMESTAMPTZ NOT NULL,
    is_virtual      BOOLEAN NOT NULL DEFAULT FALSE,
    raw_payload_hash VARCHAR(64),                     -- SHA256 du payload brut pour audit (sans stocker cotes long terme réel)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index haute perf sur start_time (recherche pré-match du jour) + filtrage provider/sport
CREATE INDEX IF NOT EXISTS idx_events_start_time ON events (start_time DESC);
CREATE INDEX IF NOT EXISTS idx_events_provider_sport ON events (provider, sport);
CREATE INDEX IF NOT EXISTS idx_events_league ON events (league);
CREATE INDEX IF NOT EXISTS idx_events_is_virtual ON events (is_virtual) WHERE is_virtual = TRUE;
-- Index composite pour requêtes dashboard: provider + start_time > NOW()
CREATE INDEX IF NOT EXISTS idx_events_provider_start ON events (provider, start_time) WHERE start_time > NOW() - INTERVAL '7 days';

COMMENT ON TABLE events IS 'Events pré-match MegaPari (ref=192) — Fail-Closed: 1 GameId = 1 match';
COMMENT ON COLUMN events.id IS 'GameId MegaPari (sportEventId) — PK, réutilisable 1XBET avec provider différent';
COMMENT ON COLUMN events.raw_payload_hash IS 'Hash audit sans persister cotes réelles long terme (contrainte RGPD/trading)';

-- Trigger updated_at
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_events_updated ON events;
CREATE TRIGGER trg_events_updated BEFORE UPDATE ON events FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- --------------------------------------------------------------------------
-- 2. Table validated_markets — Marchés validés Margin Guard ≤5% (sans exposer cotes client)
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS validated_markets (
    id              BIGSERIAL PRIMARY KEY,
    event_id        BIGINT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    market_type     VARCHAR(50) NOT NULL,            -- ex: 1X2, OVER_UNDER, BTTS, DOUBLE_CHANCE, HANDICAP
    margin_percent  NUMERIC(5,2) NOT NULL CHECK (margin_percent >= 0 AND margin_percent <= 5.0),
    selections_json JSONB NOT NULL,                   -- [{selection_id, name, odds (interne), tags}] — JAMAIS exposé client tel quel
    validated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    model_version   VARCHAR(20) DEFAULT 'v0.3.0',
    -- Unicité: 1 marché validé par event + market_type + line (évite doublons)
    UNIQUE (event_id, market_type, selections_json)
);

-- Index perf
CREATE INDEX IF NOT EXISTS idx_validated_markets_event_id ON validated_markets (event_id);
CREATE INDEX IF NOT EXISTS idx_validated_markets_market_type ON validated_markets (market_type);
CREATE INDEX IF NOT EXISTS idx_validated_markets_validated_at ON validated_markets (validated_at DESC);
-- GIN pour requêtes JSONB (ex: recherche marché OVER_UNDER line 2.5)
CREATE INDEX IF NOT EXISTS idx_validated_markets_selections_gin ON validated_markets USING GIN (selections_json);

COMMENT ON TABLE validated_markets IS 'Marchés validés Margin Guard ≤5% — cotes stockées interne uniquement, jamais exposées API publique';
COMMENT ON COLUMN validated_markets.margin_percent IS 'Marge bookmaker (sum(1/odds)-1)*100 — rejet strict si >5% (Fail-Closed)';
COMMENT ON COLUMN validated_markets.selections_json IS 'JSONB interne avec odds — filtré par BFF avant envoi client';

-- --------------------------------------------------------------------------
-- 3. Table virtual_snapshots — Historique complet virtuel (ML + drift detection)
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS virtual_snapshots (
    id              BIGSERIAL PRIMARY KEY,
    event_id        BIGINT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    market_type     VARCHAR(50) NOT NULL,
    odds_data       JSONB NOT NULL,                  -- {selections: [{id, odds, tags}], margin, snapshot_odds}
    result          JSONB,                           -- {score, winner, settled_at} — NULL si pré-match
    snapshot_time   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    provider        VARCHAR(20) NOT NULL DEFAULT 'MEGAPARI' CHECK (provider IN ('MEGAPARI','1XBET')),
    drift_score     NUMERIC(5,4),                    -- PSI calculé par pipeline monitoring (NULL si pas encore calculé)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index perf + time-series
CREATE INDEX IF NOT EXISTS idx_virtual_snapshots_event_id ON virtual_snapshots (event_id);
CREATE INDEX IF NOT EXISTS idx_virtual_snapshots_market_type ON virtual_snapshots (market_type);
CREATE INDEX IF NOT EXISTS idx_virtual_snapshots_snapshot_time ON virtual_snapshots (snapshot_time DESC);
-- Composite pour drift detection: event + market + time
CREATE INDEX IF NOT EXISTS idx_virtual_snapshots_event_market_time ON virtual_snapshots (event_id, market_type, snapshot_time DESC);
-- GIN odds_data
CREATE INDEX IF NOT EXISTS idx_virtual_snapshots_odds_gin ON virtual_snapshots USING GIN (odds_data);
-- Partition-friendly: index sur created_at pour purge >90j virtuel si besoin
CREATE INDEX IF NOT EXISTS idx_virtual_snapshots_created ON virtual_snapshots (created_at DESC);

COMMENT ON TABLE virtual_snapshots IS 'Snapshots virtuels complets — stocke cotes+snapshots+résultats pour training ML et drift detection (PSI)';
COMMENT ON COLUMN virtual_snapshots.odds_data IS 'Historique cotes complètes — autorisé long terme uniquement pour virtuel (réel: discard)';
COMMENT ON COLUMN virtual_snapshots.drift_score IS 'PSI score — si >0.2 → marché auto-désactivé (pipeline monitoring)';

-- --------------------------------------------------------------------------
-- 4. Vues matérialisées utiles (optionnel, rafraîchies par pipeline)
-- --------------------------------------------------------------------------
-- Vue: marchés virtuels à risque drift
CREATE OR REPLACE VIEW v_virtual_drift_candidates AS
SELECT
    vs.event_id,
    vs.market_type,
    COUNT(*) as snapshot_count,
    AVG(vs.drift_score) as avg_drift,
    MAX(vs.snapshot_time) as last_snapshot
FROM virtual_snapshots vs
WHERE vs.snapshot_time > NOW() - INTERVAL '7 days'
GROUP BY vs.event_id, vs.market_type
HAVING AVG(vs.drift_score) > 0.15;

-- --------------------------------------------------------------------------
-- 5. Données de référence (exemple)
-- --------------------------------------------------------------------------
-- Insertion test (à retirer en prod)
-- INSERT INTO events (id, provider, sport, league, home_team, away_team, start_time, is_virtual)
-- VALUES (763041519, 'MEGAPARI', 'football', 'Premier League', 'Arsenal', 'Man City', NOW() + INTERVAL '1 day', FALSE);

COMMIT;

-- Vérification
-- \d events
-- \d validated_markets
-- \d virtual_snapshots
-- EXPLAIN ANALYZE SELECT * FROM events WHERE provider='MEGAPARI' AND start_time > NOW() ORDER BY start_time LIMIT 20;
