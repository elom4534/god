"""
Router FastAPI — MegaPari Caching & Margin Guard
POST /ml/v1/megapari/ingest — point d'entrée Flux MegaPari (LoadList/LoadSingle)
GET  /ml/v1/megapari/cache/{event_id} — lecture Redis
"""
from fastapi import APIRouter, Body
from typing import List, Dict, Any
import json
from app.services.megapari_margin_guard import process_batch_megapari, get_redis
from app.config import get_settings

router = APIRouter()
settings = get_settings()

@router.post("/megapari/ingest")
async def megapari_ingest(payload: Dict[str, Any] = Body(...)):
    """
    Reçoit flux MegaPari (LoadList / LoadSingle) :
    {
      "raw_events": [ {id, markets:[{type, parameter, oddsMarket, isBlocked, displayMulti}] } ],
      "threshold": 5.0  // optionnel
    }
    → Valide Margin Guard, cache Redis 15min, retourne payload nettoyé sans cotes
    """
    raw_events = payload.get("raw_events") or payload.get("events") or []
    threshold = float(payload.get("threshold", 5.0))
    # Supporte aussi un seul event
    if isinstance(raw_events, dict):
        raw_events = [raw_events]
    result = await process_batch_megapari(raw_events, threshold=threshold)
    return result

@router.get("/megapari/cache/{event_id}")
async def megapari_cache(event_id: str):
    """Lecture cache Redis — debug/monitoring"""
    r = await get_redis()
    key = f"megapari:event:{event_id}"
    data = await r.get(key)
    if not data:
        return {"event_id": event_id, "cached": False, "reason_code": "NOT_IN_CACHE_OR_EXPIRED"}
    ttl = await r.ttl(key)
    return {"event_id": event_id, "cached": True, "ttl_remaining": ttl, "payload": json.loads(data)}

@router.get("/megapari/health")
async def megapari_health():
    """Health check service"""
    try:
        r = await get_redis()
        await r.ping()
        redis_ok = True
    except Exception as e:
        redis_ok = False
        redis_err = str(e)
        return {"provider": "MEGAPARI", "status": "degraded", "redis": redis_ok, "error": redis_err, "version": settings.model_version}
    return {"provider": "MEGAPARI", "status": "ok", "redis": redis_ok, "ttl_seconds": 900, "version": settings.model_version}
