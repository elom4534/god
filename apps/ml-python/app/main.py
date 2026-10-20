from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.config import get_settings

settings = get_settings()

app = FastAPI(
    title="Pred ML API (FastAPI)",
    version=settings.model_version,
    description="Normalizer + Margin Guard + Selection Engine + Inference (fail-closed)",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

from app.routers import events, scan, picks, health, esports, megapari

app.include_router(health.router, tags=["health"])
app.include_router(events.router, prefix="/ml/v1", tags=["events"])
app.include_router(scan.router, prefix="/ml/v1", tags=["scan"])
app.include_router(picks.router, prefix="/ml/v1", tags=["picks"])
app.include_router(megapari.router, prefix="/ml/v1", tags=["megapari"])
app.include_router(esports.router, prefix="/ml/v1", tags=["esports"])

# Also expose /health at root for docker healthcheck
@app.get("/")
def root():
    return {"service": "pred-ml", "version": settings.model_version, "docs": "/docs"}
