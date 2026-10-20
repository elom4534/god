from fastapi import APIRouter, Body
from app.core.selection_engine import select_best_per_event

router = APIRouter()

@router.post("/picks/best")
def picks_best(payload: dict = Body(...)):
    events = payload.get("events", [])
    mode = payload.get("mode", "real_only")
    k_sigma = float(payload.get("k_sigma", 1.0))
    threshold = float(payload.get("threshold_pct", 5.0))
    result = select_best_per_event(events, mode=mode, k_sigma=k_sigma, threshold_pct=threshold)
    return result
