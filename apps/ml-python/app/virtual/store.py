"""
Persistance PostgreSQL du Football Virtuel (tables migration 004).

Horodatage double : `snapshot_at` = UTC serveur (NOW()), `source_ts` =
horodatage du flux partenaire, `captured_at` = UTC de capture applicative.
"""
from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import asyncpg

log = logging.getLogger("virtual.store")

_pool: Optional[asyncpg.Pool] = None


def _dsn() -> str:
    dsn = os.getenv("DATABASE_URL", "").strip()
    if not dsn:
        raise RuntimeError(
            "DATABASE_URL absente — impossible d'écrire les données virtuelles "
            "(aucune source de repli : flux réel uniquement)."
        )
    return dsn.replace("postgresql+asyncpg://", "postgresql://")


async def pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(dsn=_dsn(), min_size=1, max_size=5, command_timeout=60)
    return _pool


async def close() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def utc(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is None:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


# --------------------------------------------------------------- écritures
UPSERT_ROUND = """
INSERT INTO virtual_rounds (
    round_id, provider, league, home_team, away_team, scheduled_start,
    status, tournament_id, api_event_id, api_const_event_id,
    match_format, home_logo, away_logo, source_ts, captured_at
) VALUES ($1,$2,$3,$4,$5,$6,'SCHEDULED',$7,$8,$9,$10,$11,$12,$13,$14)
ON CONFLICT (round_id) DO UPDATE SET
    league = EXCLUDED.league,
    home_team = EXCLUDED.home_team,
    away_team = EXCLUDED.away_team,
    scheduled_start = LEAST(virtual_rounds.scheduled_start, EXCLUDED.scheduled_start),
    updated_at = NOW()
RETURNING (xmax = 0) AS inserted
"""

UPSERT_LIVE = """
INSERT INTO virtual_rounds (
    round_id, provider, league, home_team, away_team, scheduled_start,
    started_at, status, home_score, away_score, time_sec, period_name,
    tournament_id, api_event_id, api_const_event_id, match_format,
    home_logo, away_logo, source_ts, captured_at
) VALUES ($1,$2,$3,$4,$5,$6,COALESCE($7, NOW()),'LIVE',$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19)
ON CONFLICT (round_id) DO UPDATE SET
    started_at = COALESCE(virtual_rounds.started_at, EXCLUDED.started_at),
    status = CASE WHEN virtual_rounds.status = 'FINISHED' THEN 'FINISHED' ELSE 'LIVE' END,
    home_score = EXCLUDED.home_score,
    away_score = EXCLUDED.away_score,
    time_sec = EXCLUDED.time_sec,
    period_name = EXCLUDED.period_name,
    source_ts = EXCLUDED.source_ts,
    captured_at = EXCLUDED.captured_at,
    updated_at = NOW()
"""

INSERT_ODDS = """
INSERT INTO virtual_odds_snapshots
    (round_id, snapshot_at, market, selection, odds, raw,
     line, phase, is_blocked, source_ts, captured_at)
VALUES ($1, NOW(), $2, $3, $4, $5, $6, $7, $8, $9, $10)
"""

INSERT_EVENT = """
INSERT INTO virtual_live_events (round_id, event_at, minute, event_type, detail)
VALUES ($1, NOW(), $2, $3, $4)
"""

UPSERT_RESULT = """
INSERT INTO virtual_results
    (round_id, closed_at, home_score, away_score, btts, over_2_5, raw, source, half_time)
VALUES ($1, NOW(), $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT (round_id) DO UPDATE SET
    home_score = EXCLUDED.home_score,
    away_score = EXCLUDED.away_score,
    btts = EXCLUDED.btts,
    over_2_5 = EXCLUDED.over_2_5,
    raw = EXCLUDED.raw,
    source = EXCLUDED.source,
    half_time = EXCLUDED.half_time
WHERE virtual_results.ratings_applied_at IS NULL
RETURNING round_id
"""

MARK_FINISHED = """
UPDATE virtual_rounds
SET status = 'FINISHED', ended_at = COALESCE($2, NOW()),
    home_score = COALESCE($3, home_score), away_score = COALESCE($4, away_score),
    updated_at = NOW()
WHERE round_id = $1 AND status <> 'FINISHED'
RETURNING round_id
"""

MARK_RATINGS_APPLIED = """
UPDATE virtual_results SET ratings_applied_at = NOW() WHERE round_id = $1
"""

UPSERT_RATING = """
INSERT INTO virtual_team_ratings (provider, team, elo_rating, attack_rating, defense_rating, updated_at, matches_count)
VALUES ($1,$2,$3,$4,$5, NOW(), $6)
ON CONFLICT (provider, team) DO UPDATE SET
    elo_rating = EXCLUDED.elo_rating,
    attack_rating = EXCLUDED.attack_rating,
    defense_rating = EXCLUDED.defense_rating,
    matches_count = EXCLUDED.matches_count,
    updated_at = NOW()
"""


async def upsert_round_scheduled(row: Dict[str, Any]) -> None:
    p = await pool()
    await p.execute(
        UPSERT_ROUND,
        row["round_id"], row["provider"], row.get("league"), row["home_team"], row["away_team"],
        row["scheduled_start"], row.get("tournament_id"), row.get("api_event_id"),
        row.get("api_const_event_id"), row.get("match_format"), row.get("home_logo"),
        row.get("away_logo"), row.get("source_ts"), row.get("captured_at"),
    )


async def upsert_round_live(row: Dict[str, Any]) -> None:
    p = await pool()
    await p.execute(
        UPSERT_LIVE,
        row["round_id"], row["provider"], row.get("league"), row["home_team"], row["away_team"],
        row["scheduled_start"], row.get("started_at"), row.get("home_score"), row.get("away_score"),
        row.get("time_sec"), row.get("period_name"), row.get("tournament_id"),
        row.get("api_event_id"), row.get("api_const_event_id"), row.get("match_format"),
        row.get("home_logo"), row.get("away_logo"), row.get("source_ts"), row.get("captured_at"),
    )


async def insert_odds_snapshot(row: Dict[str, Any]) -> None:
    p = await pool()
    await p.execute(
        INSERT_ODDS,
        row["round_id"], row["market"], row["selection"], row["odds"],
        json.dumps(row.get("raw"), ensure_ascii=False) if row.get("raw") is not None else None,
        row.get("line"), row.get("phase", "PREMATCH"), bool(row.get("is_blocked")),
        row.get("source_ts"), row.get("captured_at"),
    )


async def insert_live_event(round_id: str, minute: Optional[int], event_type: str, detail: Dict[str, Any]) -> None:
    p = await pool()
    await p.execute(INSERT_EVENT, round_id, minute, event_type, json.dumps(detail, ensure_ascii=False))


async def upsert_result(round_id: str, home: int, away: int, raw: Any, source: str,
                        half_time: Optional[str]) -> Optional[str]:
    p = await pool()
    row = await p.fetchrow(
        UPSERT_RESULT, round_id, home, away,
        home > 0 and away > 0, (home + away) > 2.5,
        json.dumps(raw, ensure_ascii=False) if raw is not None else None, source, half_time,
    )
    return row["round_id"] if row else None


async def mark_finished(round_id: str, closed_at: Optional[datetime],
                        home: Optional[int], away: Optional[int]) -> bool:
    p = await pool()
    row = await p.fetchrow(MARK_FINISHED, round_id, utc(closed_at), home, away)
    return row is not None


async def mark_ratings_applied(round_id: str) -> None:
    p = await pool()
    await p.execute(MARK_RATINGS_APPLIED, round_id)


async def upsert_rating(provider: str, team: str, elo: float, attack: float,
                        defense: float, matches: int) -> None:
    p = await pool()
    await p.execute(UPSERT_RATING, provider, team, elo, attack, defense, matches)


# ---------------------------------------------------------------- lectures
async def list_rounds(provider: Optional[str] = None, status: Optional[str] = None,
                      limit: int = 50, upcoming_only: bool = False) -> List[asyncpg.Record]:
    p = await pool()
    sql = """
        SELECT * FROM virtual_rounds
        WHERE ($1::text IS NULL OR provider = $1)
          AND ($2::text IS NULL OR status = $2)
          AND (NOT $3 OR scheduled_start >= NOW() - INTERVAL '5 minutes')
        ORDER BY scheduled_start ASC
        LIMIT $4
    """
    return await p.fetch(sql, provider, status, upcoming_only, max(1, min(limit, 200)))


async def get_round(round_id: str) -> Optional[asyncpg.Record]:
    p = await pool()
    return await p.fetchrow("SELECT * FROM virtual_rounds WHERE round_id = $1", round_id)


async def odds_history(round_id: str, limit: int = 500) -> List[asyncpg.Record]:
    p = await pool()
    return await p.fetch(
        """SELECT snapshot_at, market, selection, odds, line, phase, is_blocked, source_ts
           FROM virtual_odds_snapshots WHERE round_id = $1
           ORDER BY snapshot_at ASC, id ASC LIMIT $2""",
        round_id, max(1, min(limit, 5000)),
    )


async def recent_results(provider: Optional[str] = None, limit: int = 20) -> List[asyncpg.Record]:
    p = await pool()
    return await p.fetch(
        """
        SELECT r.round_id, r.provider, r.league, r.home_team, r.away_team,
               v.home_score, v.away_score, v.btts, v.over_2_5, v.half_time, v.closed_at
        FROM virtual_results v
        JOIN virtual_rounds r ON r.round_id = v.round_id
        WHERE ($1::text IS NULL OR r.provider = $1)
        ORDER BY v.closed_at DESC
        LIMIT $2
        """,
        provider, max(1, min(limit, 100)),
    )


async def ratings_rows(provider: Optional[str] = None) -> List[asyncpg.Record]:
    p = await pool()
    return await p.fetch(
        "SELECT * FROM virtual_team_ratings WHERE ($1::text IS NULL OR provider = $1)",
        provider,
    )


async def sample_size(provider: str) -> int:
    p = await pool()
    return int(await p.fetchval(
        """SELECT COUNT(*) FROM virtual_results v
           JOIN virtual_rounds r ON r.round_id = v.round_id
           WHERE r.provider = $1 AND v.ratings_applied_at IS NOT NULL""",
        provider,
    ) or 0)


async def capture_started_at(provider: str) -> Optional[datetime]:
    p = await pool()
    return await p.fetchval(
        "SELECT MIN(created_at) FROM virtual_rounds WHERE provider = $1", provider
    )


async def pending_results(limit: int = 20) -> List[asyncpg.Record]:
    """Rounds dont on n'a pas encore le résultat officiel (à clôturer)."""
    p = await pool()
    return await p.fetch(
        """
        SELECT round_id, provider, tournament_id, scheduled_start, home_score, away_score,
               home_team, away_team
        FROM virtual_rounds
        WHERE status <> 'FINISHED' AND status <> 'CANCELLED'
          AND scheduled_start <= NOW() - INTERVAL '3 minutes'
        ORDER BY scheduled_start ASC
        LIMIT $1
        """,
        limit,
    )


async def rounds_missing_result(limit: int = 20) -> List[asyncpg.Record]:
    """Rounds FINISHED sans ligne virtual_results (résultat à confirmer)."""
    p = await pool()
    return await p.fetch(
        """
        SELECT r.round_id, r.provider, r.tournament_id, r.scheduled_start, r.home_score, r.away_score,
               r.home_team, r.away_team
        FROM virtual_rounds r
        LEFT JOIN virtual_results v ON v.round_id = r.round_id
        WHERE v.round_id IS NULL AND r.scheduled_start <= NOW() - INTERVAL '3 minutes'
        ORDER BY r.scheduled_start ASC
        LIMIT $1
        """,
        limit,
    )


async def known_round_ids() -> set:
    p = await pool()
    return {r["round_id"] for r in await p.fetch("SELECT round_id FROM virtual_rounds")}


async def last_scores(round_ids: List[str]) -> Dict[str, tuple]:
    if not round_ids:
        return {}
    p = await pool()
    rows = await p.fetch(
        "SELECT round_id, home_score, away_score FROM virtual_rounds WHERE round_id = ANY($1)",
        round_ids,
    )
    return {r["round_id"]: (r["home_score"], r["away_score"]) for r in rows}
