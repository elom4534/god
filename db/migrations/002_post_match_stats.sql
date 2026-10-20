-- ============================================================================
-- Migration 002 — Post-Match Stats & Lifecycle (xG/xGA indispensables IA)
-- Cycle de vie complet: UPCOMING → LIVE → FINISHED/CANCELLED
-- ============================================================================
-- Date: 2026-10-19
-- Dépendance: 001_megapari_schema.sql (events BIGINT PK)

BEGIN;

-- --------------------------------------------------------------------------
-- 0. Compatibilité FK — events.id BIGINT → VARCHAR(64)
--    match_stats.event_id est VARCHAR(64) PK FK → on convertit events.id
--    pour respecter la spec sans casser les données existantes.
--    Si events.id est déjà VARCHAR, l'ALTER est no-op.
-- --------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='events' AND column_name='id' AND data_type='bigint'
  ) THEN
    -- Conversion BIGINT → VARCHAR(64) avec USING
    ALTER TABLE events ALTER COLUMN id TYPE VARCHAR(64) USING id::text;
    RAISE NOTICE 'events.id converti BIGINT → VARCHAR(64) pour FK match_stats';
  END IF;
END $$;

-- --------------------------------------------------------------------------
-- 1. events — ajout cycle de vie + score final
-- --------------------------------------------------------------------------
ALTER TABLE events ADD COLUMN IF NOT EXISTS status VARCHAR(32) NOT NULL DEFAULT 'UPCOMING'
  CHECK (status IN ('UPCOMING','LIVE','FINISHED','CANCELLED'));

ALTER TABLE events ADD COLUMN IF NOT EXISTS final_score JSONB;
-- Ex: {"home":2,"away":1,"ht_home":1,"ht_away":0,"ft_home":2,"ft_away":1}

COMMENT ON COLUMN events.status IS 'Lifecycle: UPCOMING → LIVE → FINISHED/CANCELLED (Fail-Closed: pas de prédiction si CANCELLED)';
COMMENT ON COLUMN events.final_score IS 'Score final JSONB: {home, away, ht_home, ht_away} — NULL si UPCOMING/LIVE';

-- Index pour requêtes haute perf sur status (filtrage FINISHED pour training IA)
CREATE INDEX IF NOT EXISTS idx_events_status ON events(status);
-- Composite pour dashboard: provider + status + start_time
CREATE INDEX IF NOT EXISTS idx_events_status_start ON events(status, start_time DESC) WHERE status = 'FINISHED';

-- --------------------------------------------------------------------------
-- 2. match_stats — statistiques avancées fin de match (xG/xGA critiques IA)
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS match_stats (
    event_id        VARCHAR(64) PRIMARY KEY REFERENCES events(id) ON DELETE CASCADE,
    provider        VARCHAR(32) NOT NULL DEFAULT 'MEGAPARI' CHECK (provider IN ('MEGAPARI','1XBET','LIVE_FOOTBALL','OPTIMIZED')),
    xg              JSONB,                  -- Ex: {"home":1.85,"away":0.92} — Expected Goals
    xga             JSONB,                  -- Ex: {"home":0.92,"away":1.85} — Expected Goals Against (inverse xG)
    corners         JSONB,                  -- Ex: {"home":6,"away":3}
    yellow_cards    JSONB,                  -- Ex: {"home":2,"away":1}
    red_cards       JSONB,                  -- Ex: {"home":0,"away":0}
    shots_on_target JSONB,                  -- Ex: {"home":7,"away":2}
    shots_off_target JSONB,                 -- Ex: {"home":5,"away":3}
    big_chances     JSONB,                  -- Ex: {"home":3,"away":1} — Occasions franches
    dangerous_attacks JSONB,                -- Ex: {"home":45,"away":22}
    possession      JSONB,                  -- Ex: {"home":58,"away":42} — % possession
    raw_stats_json  JSONB NOT NULL,         -- Sauvegarde intégrale payload brut (audit + réentraînement)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Trigger updated_at pour match_stats
DROP TRIGGER IF EXISTS trg_match_stats_updated ON match_stats;
CREATE TRIGGER trg_match_stats_updated BEFORE UPDATE ON match_stats
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE match_stats IS 'Stats fin de match — xG/xGA indispensables pour IA (Poisson/Dixon-Coles + CatBoost). 1 ligne = 1 event FINISHED';
COMMENT ON COLUMN match_stats.xg IS 'Expected Goals: {"home":1.85,"away":0.92} — métrique clé IA (calibration Poisson)';
COMMENT ON COLUMN match_stats.xga IS 'Expected Goals Against: inverse xG — utile pour défense';
COMMENT ON COLUMN match_stats.raw_stats_json IS 'Payload brut complet — conservé pour audit, drift detection, réentraînement (ne pas discard)';

-- Index GIN pour requêtes JSONB avancées
CREATE INDEX IF NOT EXISTS idx_match_stats_xg_gin ON match_stats USING GIN (xg);
CREATE INDEX IF NOT EXISTS idx_match_stats_corners_gin ON match_stats USING GIN (corners);
CREATE INDEX IF NOT EXISTS idx_match_stats_provider ON match_stats(provider);
CREATE INDEX IF NOT EXISTS idx_match_stats_created_at ON match_stats(created_at DESC);

-- --------------------------------------------------------------------------
-- 3. Helpers — vues pour IA
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_finished_with_xg AS
SELECT
    e.id AS event_id,
    e.provider,
    e.league,
    e.home_team,
    e.away_team,
    e.start_time,
    e.final_score,
    ms.xg,
    ms.xga,
    (ms.xg->>'home')::numeric AS xg_home,
    (ms.xg->>'away')::numeric AS xg_away,
    ms.corners,
    ms.possession,
    ms.shots_on_target
FROM events e
JOIN match_stats ms ON ms.event_id = e.id
WHERE e.status = 'FINISHED'
  AND ms.xg IS NOT NULL;

COMMENT ON VIEW v_finished_with_xg IS 'Vue IA: matchs FINISHED avec xG — prête pour training Elo/Poisson/CatBoost';

COMMIT;

-- Vérification:
-- \d events
-- \d match_stats
-- SELECT * FROM v_finished_with_xg LIMIT 5;
-- EXPLAIN ANALYZE SELECT * FROM events WHERE status='FINISHED' ORDER BY start_time DESC LIMIT 20;
