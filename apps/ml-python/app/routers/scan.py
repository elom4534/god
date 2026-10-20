from fastapi import APIRouter, Body
from app.core.margin_guard import scan_event_markets
from datetime import datetime, timezone

router = APIRouter()

@router.post("/scan")
def scan(payload: dict = Body(...)):
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
