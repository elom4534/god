from fastapi import APIRouter, Body
from typing import List, Dict, Any
from app.services.esports_pipeline import (
    build_snapshot_record, archive_result, classify_sport, extract_event_meta, SPORT_LABELS,
)

router = APIRouter()


@router.post("/esports/snapshot")
async def esports_snapshot(payload: Dict[str, Any] = Body(...)):
    """
    Reçoit un événement MegaPari réel et renvoie un snapshot pré-match
    (cotes 1N2 / BTTS / O-U + métadonnées + logos). Aucune simulation.
    """
    raw_events = payload.get("raw_events") or payload.get("events") or []
    if isinstance(raw_events, dict):
        raw_events = [raw_events]
    out = []
    for ev in raw_events:
        rec = build_snapshot_record(ev)
        # Filtre optionnel par sport
        sport_filter = payload.get("sport")
        if sport_filter and rec.get("sport") != sport_filter:
            continue
        out.append(rec)
    return {"count": len(out), "snapshots": out, "as_of": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat()}


@router.post("/esports/result")
async def esports_result(payload: Dict[str, Any] = Body(...)):
    """Archive le résultat final d'un match (post-match) pour l'entraînement ML."""
    event_id = str(payload.get("event_id") or "")
    home = payload.get("final_score_home")
    away = payload.get("final_score_away")
    if event_id == "" or home is None or away is None:
        return {"error": "MISSING_FIELDS", "reason_code": "MISSING_FIELDS"}
    rec = archive_result(event_id, int(home), int(away),
                         odds_over=payload.get("odds_over"),
                         ou_line=float(payload.get("ou_line", 2.5)))
    return rec


@router.post("/esports/classify")
async def esports_classify(payload: Dict[str, Any] = Body(...)):
    raw_events = payload.get("raw_events") or payload.get("events") or []
    if isinstance(raw_events, dict):
        raw_events = [raw_events]
    out = []
    for ev in raw_events:
        meta = extract_event_meta(ev)
        meta["sport_label"] = SPORT_LABELS.get(meta["sport"], meta["sport"])
        out.append(meta)
    return {"count": len(out), "events": out}
