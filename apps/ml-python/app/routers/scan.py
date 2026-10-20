from fastapi import APIRouter, Body, HTTPException
from app.core.margin_guard import scan_event_markets
from datetime import datetime, timezone

router = APIRouter()

def _validate(payload):
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail={"error": "INVALID_BODY", "reason_code": "INVALID_BODY"})
    markets = payload.get("markets", payload.get("raw_markets"))
    if not isinstance(markets, list) or len(markets) == 0:
        raise HTTPException(status_code=400, detail={"error": "NO_MARKETS", "reason_code": "NO_MARKETS"})
    threshold = payload.get("threshold_pct", 5.0)
    try:
        t = float(threshold)
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail={"error": "INVALID_THRESHOLD", "reason_code": "INVALID_THRESHOLD"})
    if t <= 0 or t > 100:
        raise HTTPException(status_code=400, detail={"error": "INVALID_THRESHOLD", "reason_code": "INVALID_THRESHOLD"})
    return payload

@router.post("/scan")
def scan(payload: dict = Body(...)):
    payload = _validate(payload)
    event_id = payload.get("event_id", "unknown")
    markets = payload.get("markets", [])
    threshold = float(payload.get("threshold_pct", 5.0))
    # alias for /scan compat
    if not markets and "markets" not in payload and "raw_markets" in payload:
        markets = payload["raw_markets"]
    result = scan_event_markets(event_id, markets, threshold_pct=threshold)
    return result

# Compatibility alias POST /scan and POST /events/scan
@router.post("/events/scan")
def scan_alias(payload: dict = Body(...)):
    return scan(payload)
