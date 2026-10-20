from fastapi import APIRouter
from datetime import datetime, timezone
from app.config import get_settings

router = APIRouter()
settings = get_settings()

@router.get("/health")
def health():
    return {
        "status": "ok",
        "service": "pred-ml",
        "version": settings.model_version,
        "time": datetime.now(timezone.utc).isoformat(),
        "checks": {"model_store": "ok", "margin_guard": "ok", "normalizer": "ok"}
    }
