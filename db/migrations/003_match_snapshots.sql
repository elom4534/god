-- ============================================================================
-- Migration 003 — Pre-match snapshots & post-match results (FIFA e-sports + Sega/virtual)
-- Données RÉELLES uniquement (bookmaker MegaPari). Fail-closed.
-- ============================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS match_snapshots (
    id              BIGSERIAL PRIMARY KEY,
    event_id        BIGINT NOT NULL,                 -- GameId MegaPari (sportEventId)
    provider        VARCHAR(20) NOT NULL DEFAULT 'MEGAPARI' CHECK (provider IN ('MEGAPARI')),
    sport           VARCHAR(50) NOT NULL,            -- 'fifa_esports' | 'sega_football' | 'football'
    league          VARCHAR(200),
    home_team       VARCHAR(200) NOT NULL,
    away_team       VARCHAR(200) NOT NULL,
    home_logo_url   TEXT,
    away_logo_url   TEXT,
    start_time      TIMESTAMPTZ NOT NULL,
    is_virtual      BOOLEAN NOT NULL DEFAULT FALSE,
    -- Cotes pré-match (snapshot juste avant coup d'envoi)
    odds_1          NUMERIC(8,4),   -- victoire domicile
    odds_x          NUMERIC(8,4),   -- nul
    odds_2          NUMERIC(8,4),   -- victoire extérieur
    odds_btts_yes   NUMERIC(8,4),
    odds_btts_no    NUMERIC(8,4),
    odds_over       NUMERIC(8,4),   -- Over (ligne typique 2.5)
    odds_under      NUMERIC(8,4),
    ou_line         NUMERIC(4,2) DEFAULT 2.5,
    margin_percent  NUMERIC(5,2),
    snapshot_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Résultat final (post-match)
    final_score_home INT,
    final_score_away INT,
    result_1x2      VARCHAR(2),     -- '1' | 'X' | '2'
    btts_result     BOOLEAN,
    over_result     BOOLEAN,
    settled_at      TIMESTAMPTZ,
    -- Métadonnées
    raw_payload_hash VARCHAR(64),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (event_id, provider, snapshot_at)
);

CREATE INDEX IF NOT EXISTS idx_match_snapshots_event ON match_snapshots (event_id);
CREATE INDEX IF NOT EXISTS idx_match_snapshots_sport ON match_snapshots (sport);
CREATE INDEX IF NOT EXISTS idx_match_snapshots_start ON match_snapshots (start_time DESC);
CREATE INDEX IF NOT EXISTS idx_match_snapshots_settled ON match_snapshots (settled_at) WHERE settled_at IS NOT NULL;

COMMENT ON TABLE match_snapshots IS 'Snapshots pré-match (cotes 1N2/BTTS/O-U) + résultats finaux pour entraînement ML — données réelles uniquement';

COMMIT;
