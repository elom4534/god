"""
Endpoints internes Football Virtuel (`/api/v1/virtual/…`).

Lecture seule, exposés par l'edge AVANT le catch-all NestJS. Les prédictions
n'exposent des probabilités qu'après calibration réelle (≥ 24 h de capture ET
≥ 100 rounds finis) ; sinon `calibration_in_progress: true` et l'UI affiche
« Calibration en cours ».
"""
from __future__ import annotations

from typing import Any, Dict, Optional

from fastapi import APIRouter, HTTPException, Query

from app.virtual import config as C
from app.virtual import store
from app.virtual.ratings import engine as ratings_engine

router = APIRouter(prefix="/api/v1/virtual", tags=["virtual"])

RELIABILITY_MESSAGE = (
    "Les matchs de football virtuel (FIFA Virtual & Sega Virtual) sont des "
    "simulations aléatoires (RNG) du bookmaker MegaPari. Aucun modèle ne peut "
    "prédire leur issue avec certitude. Les probabilités affichées sont des "
    "statistiques calculées uniquement sur les rounds réellement joués du flux "
    "partenaire ; elles ne garantissent aucun gain. Les prédictions s'affichent "
    "uniquement après 24 h de capture réelle et un échantillon suffisant "
    "(100 rounds)."
)


def _round_payload(r: Any) -> Dict[str, Any]:
    return {
        "round_id": r["round_id"],
        "provider": r["provider"],
        "league": r["league"],
        "home_team": r["home_team"],
        "away_team": r["away_team"],
        "scheduled_start": r["scheduled_start"].isoformat() if r["scheduled_start"] else None,
        "started_at": r["started_at"].isoformat() if r["started_at"] else None,
        "ended_at": r["ended_at"].isoformat() if r["ended_at"] else None,
        "status": r["status"],
        "home_score": r["home_score"],
        "away_score": r["away_score"],
        "time_sec": r["time_sec"],
        "period_name": r["period_name"],
        "match_format": r["match_format"],
        "home_logo": r["home_logo"],
        "away_logo": r["away_logo"],
    }


@router.get("/rounds")
async def rounds(provider: Optional[str] = Query(None, pattern="^(FIFA_VIRTUAL|SEGA_VIRTUAL)$"),
                 status: Optional[str] = Query(None, pattern="^(SCHEDULED|LIVE|FINISHED|CANCELLED)$"),
                 limit: int = Query(50, ge=1, le=200)) -> Dict[str, Any]:
    rows = await store.list_rounds(provider=provider, status=status, limit=limit)
    return {"count": len(rows), "rounds": [_round_payload(r) for r in rows]}


@router.get("/rounds/upcoming")
async def rounds_upcoming(provider: Optional[str] = Query(None, pattern="^(FIFA_VIRTUAL|SEGA_VIRTUAL)$"),
                          limit: int = Query(30, ge=1, le=100)) -> Dict[str, Any]:
    rows = await store.list_rounds(provider=provider, status="SCHEDULED",
                                   limit=limit, upcoming_only=True)
    return {"count": len(rows), "rounds": [_round_payload(r) for r in rows]}


@router.get("/rounds/{round_id}/odds-history")
async def rounds_odds_history(round_id: str, limit: int = Query(500, ge=1, le=5000)) -> Dict[str, Any]:
    rnd = await store.get_round(round_id)
    if rnd is None:
        raise HTTPException(status_code=404, detail=f"Round inconnu : {round_id}")
    rows = await store.odds_history(round_id, limit=limit)
    return {
        "round": _round_payload(rnd),
        "count": len(rows),
        "odds_history": [
            {
                "snapshot_at": r["snapshot_at"].isoformat(),
                "market": r["market"],
                "selection": r["selection"],
                "odds": float(r["odds"]),
                "line": float(r["line"]) if r["line"] is not None else None,
                "phase": r["phase"],
                "is_blocked": r["is_blocked"],
                "source_ts": r["source_ts"].isoformat() if r["source_ts"] else None,
            }
            for r in rows
        ],
    }


@router.get("/results/recent")
async def results_recent(provider: Optional[str] = Query(None, pattern="^(FIFA_VIRTUAL|SEGA_VIRTUAL)$"),
                         limit: int = Query(20, ge=1, le=100)) -> Dict[str, Any]:
    rows = await store.recent_results(provider=provider, limit=limit)
    return {
        "count": len(rows),
        "results": [
            {
                "round_id": r["round_id"],
                "provider": r["provider"],
                "league": r["league"],
                "home_team": r["home_team"],
                "away_team": r["away_team"],
                "home_score": r["home_score"],
                "away_score": r["away_score"],
                "btts": r["btts"],
                "over_2_5": r["over_2_5"],
                "half_time": r["half_time"],
                "closed_at": r["closed_at"].isoformat(),
            }
            for r in rows
        ],
    }


@router.get("/predictions/{round_id}")
async def predictions(round_id: str) -> Dict[str, Any]:
    rnd = await store.get_round(round_id)
    if rnd is None:
        raise HTTPException(status_code=404, detail=f"Round inconnu : {round_id}")
    provider = rnd["provider"]
    sample = await store.sample_size(provider)
    started = await store.capture_started_at(provider)
    calib = ratings_engine.calibration_state(provider, started, sample)
    ready = not calib["calibration_in_progress"]

    latest = await store.odds_history(round_id, limit=5000)
    last_by_key: Dict[tuple, Dict[str, Any]] = {}
    for r in latest:
        last_by_key[(r["market"], r["selection"], r["line"])] = r
    odds_rows = [
        {"market": k[0], "selection": k[1], "line": float(k[2]) if k[2] is not None else None,
         "odds": float(v["odds"]), "snapshot_at": v["snapshot_at"].isoformat()}
        for k, v in last_by_key.items()
    ]

    payload: Dict[str, Any] = {
        "round": _round_payload(rnd),
        "sample_size": calib["sample_size"],
        "capture_hours": calib["capture_hours"],
        "min_observations": calib["min_observations"],
        "min_capture_hours": calib["min_capture_hours"],
        "calibration_in_progress": calib["calibration_in_progress"],
        "probabilities": None,
        "value_bets": [],
        "latest_odds": odds_rows,
    }
    if ready:
        probs = ratings_engine.predict(provider, rnd["home_team"], rnd["away_team"])
        payload["probabilities"] = {
            "home": round(probs["p_home"], 4),
            "draw": round(probs["p_draw"], 4),
            "away": round(probs["p_away"], 4),
            "btts_yes": round(probs["p_btts_yes"], 4),
            "over_2_5": round(probs["p_over_2_5"], 4),
            "lambda_home": round(probs["lambda_home"], 3),
            "lambda_away": round(probs["lambda_away"], 3),
            "model": probs.get("model"),
        }
        payload["value_bets"] = ratings_engine.value_bets(probs, odds_rows, ready=True)
    return payload


@router.get("/reliability")
async def reliability() -> Dict[str, Any]:
    providers = {}
    for provider in C.PROVIDERS:
        sample = await store.sample_size(provider)
        started = await store.capture_started_at(provider)
        calib = ratings_engine.calibration_state(provider, started, sample)
        providers[provider] = calib
    return {
        "message": RELIABILITY_MESSAGE,
        "providers": providers,
        "model": "Elo + Dixon-Coles (par provider), affinement LightGBM, détection de drift",
    }
