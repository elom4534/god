from fastapi import APIRouter, Body
from datetime import datetime, timezone
from app.core.normalizer import normalize_batch
from app.config import get_settings

router = APIRouter()
settings = get_settings()

@router.post("/events/ingest")
def events_ingest(payload: dict = Body(...)):
    provider = payload.get("provider", "1xBet")
    is_virtual = payload.get("is_virtual", False)
    raw_events = payload.get("raw_events", [])
    as_of = payload.get("as_of") or datetime.now(timezone.utc).isoformat()
    # parse as_of if string
    if isinstance(as_of, str):
        try:
            as_of_dt = datetime.fromisoformat(as_of.replace("Z","+00:00"))
        except:
            as_of_dt = datetime.now(timezone.utc)
    else:
        as_of_dt = as_of

    result = normalize_batch(raw_events, provider=provider, is_virtual=is_virtual)
    return {
        "normalized": result["normalized"],
        "rejected": result["rejected"],
        "model_version": settings.model_version,
        "as_of": as_of_dt.isoformat() if hasattr(as_of_dt, "isoformat") else str(as_of_dt)
    }
