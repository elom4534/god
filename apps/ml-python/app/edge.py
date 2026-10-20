"""
Edge HTTP — point d'entrée PUBLIC du déploiement Alwaysdata.

Pourquoi ce module ?
-------------------
Le site `god.alwaysdata.net` est de type « Programme utilisateur » : la
plateforme lance une seule commande, dans le dossier `/home/god`, avec les
variables `IP` et `PORT`. Le projet a deux services (NestJS + FastAPI) :
on expose donc le FastAPI en façade et on relaie `/api/v1/*` vers le
service NestJS qui tourne en interne sur 127.0.0.1:3000.

    https://god.alwaysdata.net/health        → santé ML (pg / redis / ml)
    https://god.alwaysdata.net/ml/v1/*        → API FastAPI (scan, picks, ingest)
    https://god.alwaysdata.net/api/v1/*       → API NestJS (proxy interne)
    https://god.alwaysdata.net/               → application Flutter web (statique)

Le relais ne fait que transmettre : la **politique pays**, le **rate limiting**,
l'**audit** et le **circuit breaker** restent appliqués côté NestJS, et le
**Margin Guard fail-closed** côté FastAPI.

Variables d'environnement :
    NODE_API_URL        URL interne du service NestJS (défaut http://127.0.0.1:3000)
    EDGE_STATIC_DIR     dossier du build Flutter web (défaut /home/god/www/web)
    EDGE_TIMEOUT        délai max du relais (défaut 30 s)
    NODE_AUTO_START     "true" → démarre le service NestJS s'il ne répond pas
    NODE_START_COMMAND  commande de démarrage NestJS (défaut launch_node.sh)
"""
from __future__ import annotations

import asyncio
import os
import secrets
import signal
import socket
import subprocess
import time
from pathlib import Path
from typing import Optional

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles

from app.routers import events, health, megapari, picks, scan, esports

NODE_API_URL = os.getenv("NODE_API_URL", "http://127.0.0.1:3000").rstrip("/")
EDGE_STATIC_DIR = os.getenv("EDGE_STATIC_DIR", "/home/god/www/web")
EDGE_TIMEOUT = float(os.getenv("EDGE_TIMEOUT", "30"))
NODE_AUTO_START = os.getenv("NODE_AUTO_START", "true").lower() in ("1", "true", "yes")
NODE_START_COMMAND = os.getenv("NODE_START_COMMAND", "launch_node.sh")
WATCHDOG_INTERVAL = float(os.getenv("EDGE_WATCHDOG_INTERVAL", "30"))
# Redémarrage automatique du service NestJS quand le build change (déploiement) :
# l'edge compare la date de `dist/main.js` à l'heure de démarrage du process.
NODE_DIST_MAIN = os.getenv("NODE_DIST_MAIN", "/home/god/pred-app/apps/api-node/dist/main.js")
NODE_AUTO_RELOAD = os.getenv("NODE_AUTO_RELOAD", "true").lower() in ("1", "true", "yes")
# Jeton d'administration (endpoint /admin/reload) — vide = endpoint désactivé.
EDGE_ADMIN_TOKEN = os.getenv("EDGE_ADMIN_TOKEN", "").strip()

_node_started_at: float = 0.0
_base_start_time: float = time.time()

# --- Redis (optionnel : l'offre Alwaysdata n'a pas de Redis managé, on
#     fait tourner un Redis local compilé, supervisé par l'edge) ---------------
REDIS_URL = os.getenv("REDIS_URL", "").strip()
REDIS_BIN = os.getenv("REDIS_BIN", "/home/god/.local/bin/redis-server")
REDIS_CONFIG = os.getenv("REDIS_CONFIG", "/home/god/.config/redis.conf")

app = FastAPI(
    title="pred-app",
    description="API publique pred-app (FastAPI + relais vers NestJS)",
    version="0.3.0",
    docs_url="/api-docs",
    openapi_url="/api-docs/openapi.json",
)

# ---------------------------------------------------------------------------
# Routes ML (mêmes routers que app/main.py, sans le préfixe /ml/v1 en double)
# ---------------------------------------------------------------------------
app.include_router(health.router, tags=["health"])
app.include_router(events.router, prefix="/ml/v1", tags=["events"])
app.include_router(scan.router, prefix="/ml/v1", tags=["scan"])
app.include_router(picks.router, prefix="/ml/v1", tags=["picks"])
app.include_router(megapari.router, prefix="/ml/v1", tags=["megapari"])
app.include_router(esports.router, prefix="/ml/v1", tags=["esports"])


# ---------------------------------------------------------------------------
# Relais vers le service NestJS
# ---------------------------------------------------------------------------
_HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length",
}


def _node_is_up(timeout: float = 1.5) -> bool:
    url = f"{NODE_API_URL}/api/v1/health"
    try:
        with httpx.Client(timeout=timeout) as client:
            resp = client.get(url)
            return resp.status_code < 500
    except Exception:
        return False


def _launch_node() -> bool:
    """Démarre le service NestJS (une seule instance, via fichier PID)."""
    pid_file = Path("/home/god/admin/tmp/node-api.pid")
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            os.kill(pid, 0)
            return True  # déjà en vie
        except (ValueError, ProcessLookupError, PermissionError, OSError):
            pid_file.unlink(missing_ok=True)

    launcher = Path.home() / NODE_START_COMMAND
    if not launcher.exists():
        print(f"[edge] {launcher} introuvable — service NestJS non démarré")
        return False
    log = Path("/home/god/admin/tmp/node-api.log")
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, "ab") as fh:
        proc = subprocess.Popen(
            ["bash", str(launcher)],
            cwd=str(Path.home()),
            stdout=fh,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    pid_file.write_text(str(proc.pid))
    global _node_started_at
    _node_started_at = time.time()
    print(f"[edge] service NestJS lancé (pid {proc.pid}) — log : {log}")
    return True


def _redis_target() -> tuple[str, int]:
    """(host, port) du Redis local à partir de REDIS_URL."""
    host, port = "127.0.0.1", 6379
    if REDIS_URL:
        rest = REDIS_URL.split("://", 1)[-1]
        hostport = rest.split("/", 1)[0]
        if ":" in hostport:
            h, _, p = hostport.rpartition(":")
            host, port = h or "127.0.0.1", int(p or 6379)
        else:
            host = hostport
    return host, port


def _redis_is_up(timeout: float = 1.5) -> bool:
    host, port = _redis_target()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _launch_redis() -> bool:
    """Démarre le Redis local s'il est arrêté (et si le binaire existe)."""
    if not REDIS_URL:
        return False
    if _redis_is_up():
        return True
    binary = Path(REDIS_BIN)
    config = Path(REDIS_CONFIG)
    if not binary.is_file():
        print(f"[edge] Redis non configuré (binaire {REDIS_BIN} absent) — mode dégradé")
        return False
    cmd = [str(binary), str(config)] if config.is_file() else [str(binary)]
    try:
        subprocess.Popen(cmd, cwd=str(Path.home()), stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception as e:
        print(f"[edge] démarrage Redis impossible : {e}")
        return False
    for _ in range(10):
        if _redis_is_up():
            print(f"[edge] Redis local démarré sur {REDIS_URL}")
            return True
        time.sleep(0.5)
    print("[edge] ⚠️  Redis local injoignable — mode dégradé")
    return False


@app.on_event("startup")
async def _startup() -> None:
    if not NODE_AUTO_START:
        return
    if _node_is_up():
        print("[edge] service NestJS déjà disponible")
    else:
        _launch_node()
        for _ in range(15):
            if _node_is_up():
                print("[edge] service NestJS prêt")
                break
            time.sleep(1)
        else:
            print("[edge] ⚠️  service NestJS injoignable sur " + NODE_API_URL)
    await asyncio.to_thread(_launch_redis)
    # Sur Alwaysdata il n'y a ni systemd ni superviseur : sans ce chien de garde,
    # un crash du service NestJS laisserait /api/v1/* en 502 jusqu'au redémarrage
    # du site par la plateforme.
    _watchdog_task = asyncio.create_task(_watchdog())


def _node_pid() -> Optional[int]:
    """PID du service NestJS (fichier PID), None s'il est absent."""
    pid_file = Path("/home/god/admin/tmp/node-api.pid")
    try:
        return int(pid_file.read_text().strip())
    except Exception:
        return None


def _stop_node() -> None:
    """Arrête le service NestJS (SIGTERM puis SIGKILL), en-tête du PID."""
    pid = _node_pid()
    if not pid:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            break
        except OSError:
            break
        for _ in range(20):
            time.sleep(0.25)
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
    Path("/home/god/admin/tmp/node-api.pid").unlink(missing_ok=True)


def _dist_mtime() -> float:
    """Date de dernière modification du build NestJS (0 si absent)."""
    try:
        return Path(NODE_DIST_MAIN).stat().st_mtime
    except OSError:
        return 0.0


def _node_needs_reload() -> bool:
    """Vrai si le build NestJS est plus récent que le process en cours."""
    if not NODE_AUTO_RELOAD:
        return False
    started = _node_started_at or (_base_start_time or 0.0)
    dist = _dist_mtime()
    if dist <= 0 or started <= 0:
        return False
    return dist > started + 5  # marge : le build précède de peu le démarrage


def _reload_node(reason: str) -> bool:
    """Redémarre le service NestJS (rechargement du build)."""
    print(f"[edge] redémarrage NestJS ({reason})")
    _stop_node()
    return _launch_node()


async def _watchdog() -> None:
    """Relance les services internes (NestJS, Redis) s'ils tombent."""
    while True:
        await asyncio.sleep(WATCHDOG_INTERVAL)
        try:
            if await asyncio.to_thread(_node_needs_reload):
                await asyncio.to_thread(_reload_node, "build plus récent")
                continue
            if not await asyncio.to_thread(_node_is_up):
                print("[edge] service NestJS injoignable — relance…")
                _launch_node()
                for _ in range(15):
                    await asyncio.sleep(1)
                    if await asyncio.to_thread(_node_is_up):
                        print("[edge] service NestJS relancé")
                        break
            if REDIS_URL and not await asyncio.to_thread(_redis_is_up):
                print("[edge] Redis injoignable — relance…")
                await asyncio.to_thread(_launch_redis)
        except asyncio.CancelledError:  # pragma: no cover
            raise
        except Exception as e:  # pragma: no cover — le chien de garde ne doit jamais s'arrêter
            print(f"[edge] watchdog : {e}")


@app.api_route("/api/v1/{path:path}",
               methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
async def proxy_node(path: str, request: Request):
    """Relais transparent /api/v1/* → NestJS (127.0.0.1:3000)."""
    url = f"{NODE_API_URL}/api/v1/{path}"
    body = await request.body()
    headers = {k: v for k, v in request.headers.items() if k.lower() not in _HOP_BY_HOP}
    try:
        async with httpx.AsyncClient(timeout=EDGE_TIMEOUT) as client:
            resp = await client.request(
                request.method, url,
                content=body or None,
                headers=headers,
                params=dict(request.query_params),
            )
    except Exception as e:
        return JSONResponse(
            status_code=502,
            content={"error": "UPSTREAM_UNAVAILABLE", "reason_code": "NODE_API_UNREACHABLE",
                     "details": str(e)[:200]},
        )
    out_headers = {k: v for k, v in resp.headers.items() if k.lower() not in _HOP_BY_HOP}
    return Response(content=resp.content, status_code=resp.status_code, headers=out_headers)


# ---------------------------------------------------------------------------
# Administration : rechargement du service NestJS
# ---------------------------------------------------------------------------
@app.post("/admin/reload")
async def admin_reload(request: Request):
    """Redémarre le service NestJS pour charger le dernier build.

    Protégé par le jeton `EDGE_ADMIN_TOKEN` (en-tête `X-Admin-Token`).
    Sans jeton configuré, l'endpoint est désactivé (404).
    """
    if not EDGE_ADMIN_TOKEN:
        return JSONResponse(status_code=404, content={"error": "NOT_FOUND"})
    provided = request.headers.get("x-admin-token", "")
    if not secrets.compare_digest(provided, EDGE_ADMIN_TOKEN):
        return JSONResponse(status_code=403, content={"error": "FORBIDDEN"})
    ok = await asyncio.to_thread(_reload_node, "demande administrateur")
    # On laisse au process le temps de démarrer avant de répondre.
    for _ in range(20):
        if await asyncio.to_thread(_node_is_up):
            return {"status": "reloaded", "node_up": True, "launched": ok}
        await asyncio.sleep(0.5)
    return JSONResponse(status_code=503, content={"status": "starting", "node_up": False})


# ---------------------------------------------------------------------------
# Application Flutter web (statique)
# ---------------------------------------------------------------------------
_static = Path(EDGE_STATIC_DIR)
if _static.is_dir():
    app.mount("/assets", StaticFiles(directory=_static / "assets"), name="flutter-assets")
    if (_static / "icons").is_dir():
        app.mount("/icons", StaticFiles(directory=_static / "icons"), name="flutter-icons")
    if (_static / "fonts").is_dir():
        app.mount("/fonts", StaticFiles(directory=_static / "fonts"), name="flutter-fonts")


@app.get("/")
async def root():
    index = _static / "index.html"
    if index.is_file():
        return FileResponse(str(index))
    return {
        "service": "pred-app",
        "version": "0.3.0",
        "endpoints": ["/health", "/ml/v1/scan", "/ml/v1/picks/best", "/api/v1/health", "/api-docs"],
        "static_dir": EDGE_STATIC_DIR,
        "static_present": _static.is_dir(),
    }


@app.get("/favicon.ico")
async def favicon():
    ico = _static / "favicon.png"
    if ico.is_file():
        return FileResponse(str(ico))
    return Response(status_code=204)


@app.get("/{filename:path}")
async def static_files(filename: str):
    """Fichiers statiques du build Flutter (après les routes ci-dessus)."""
    if not filename or filename.startswith(("api/", "ml/")):
        return JSONResponse(status_code=404, content={"error": "NOT_FOUND"})
    target = (_static / filename).resolve()
    try:
        target.relative_to(_static.resolve())
    except ValueError:
        return JSONResponse(status_code=403, content={"error": "FORBIDDEN"})
    if target.is_file():
        return FileResponse(str(target))
    index = _static / "index.html"
    if index.is_file():
        return FileResponse(str(index))
    return JSONResponse(status_code=404, content={"error": "NOT_FOUND"})
