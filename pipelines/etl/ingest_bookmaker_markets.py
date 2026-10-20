#!/usr/bin/env python3
"""
ETL Bookmaker (BetB2B : 1xBet / Méga Pari) → Margin Guard → cache Redis.

Chaîne complète, en production :
    1. OAuth2 BetB2B  : POST {BOOKMAKER_TOKEN_URL} (client_credentials)
    2. Flux réel      : LoadSingle v2  (tous les providers)
                         LoadList v1   (si les scopes LoadList/LoadTree sont ouverts)
    3. Normalisation : app.core.betb2b_adapter  (regroupement des sélections
                       en marchés 1X2 / Double Chance / Handicap / Total)
    4. Margin Guard  : marge ≤ 5 % (fail-closed) — app.services.megapari_margin_guard
    5. Cache Redis   : megapari:event:{event_id} (TTL 15 min) — contient les
                       cotes EN INTERNE (EV) ; jamais exposées par l'API.

⚠️ Points durs rencontrés et corrigés (voir AUDIT-PROMPT-V2.md) :
   - le secret Méga Pari arrive avec les entités HTML `&amp;` → il faut le
     décoder en `&` avant de l'envoyer (sinon « invalid_client ») ;
   - le flux BetB2B renvoie une liste PLATE de sélections, pas des marchés ;
   - le Double Chance n'est pas un marché exclusif → marge calculée par
     inversion des probabilités, sinon 100 % de rejet.

Usage :
    python pipelines/etl/ingest_bookmaker_markets.py --provider megapari --limit 50
    python pipelines/etl/ingest_bookmaker_markets.py --provider 1xbet --dry-run
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests

def _locate_ml_app() -> str:
    """
    Trouve le dossier de l'application ML (qui contient app/core/…).

    Le script est soit dans le monorepo (pipelines/etl/… → <racine>/apps/ml-python),
    soit déployé à côté de l'app ML (pred-ml/pipelines/etl/… → <racine>).
    """
    here = Path(__file__).resolve()
    candidates = [
        os.getenv("ML_APP_DIR", ""),
        str(here.parents[2] / "apps" / "ml-python"),   # pipelines/etl/x.py → monorepo
        str(here.parents[2]),                          # déployé dans le site ML
        str(here.parents[1]),
        str(here.parent),
    ]
    for cand in candidates:
        if not cand:
            continue
        p = Path(cand)
        if (p / "app" / "core" / "betb2b_adapter.py").exists():
            return str(p)
    sys.exit("Impossible de localiser l'application ML (app/core/betb2b_adapter.py) "
             "— définissez ML_APP_DIR")


sys.path.append(_locate_ml_app())

from app.core.betb2b_adapter import adapt_betb2b_event  # noqa: E402
from app.services.megapari_margin_guard import process_and_cache_event  # noqa: E402

TOKEN_URL = os.getenv("BOOKMAKER_TOKEN_URL", "https://cpservm.com/gateway/token")
GATEWAY = os.getenv("BOOKMAKER_API_BASE", "https://cpservm.com/gateway/marketing").rstrip("/")

# Rate limits officiels : 1 requête / 5 s (live), 1 / 20 s (lines).
PAUSE_LIVE = float(os.getenv("BOOKMAKER_PAUSE_LIVE", "5"))
PAUSE_LINE = float(os.getenv("BOOKMAKER_PAUSE_LINE", "20"))


def _secret(raw: str) -> str:
    """
    Les identifiants fournis par le bookmaker arrivent avec les entités HTML
    (`&amp;`). Envoyé tel quel → « invalid_client ». On tente les deux formes
    et on retient celle qui fonctionne.
    """
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        raw = raw[1:-1]
    decoded = raw.replace("&amp;", "&").replace("&quot;", '"').replace("&#39;", "'")
    return decoded if decoded != raw else raw


def get_token(client_id: str, client_secret: str) -> str:
    last_error = None
    for candidate in {client_secret, _secret(client_secret)}:
        r = requests.post(
            TOKEN_URL,
            data={"client_id": client_id, "client_secret": candidate},
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=25,
        )
        if r.status_code == 200:
            token = (r.json() or {}).get("access_token")
            if token:
                return token
        last_error = f"HTTP {r.status_code} {r.text[:160]}"
    raise RuntimeError(f"Échec d'obtention du token BetB2B : {last_error}")


def _get(token: str, path: str, params: Dict[str, Any], pause: float) -> Optional[Any]:
    r = requests.get(GATEWAY + path, params=params,
                     headers={"Authorization": f"Bearer {token}"}, timeout=30)
    time.sleep(pause)
    if r.status_code != 200:
        print(f"   ⚠️  HTTP {r.status_code} sur {path} → ignoré ({r.text[:120]})")
        return None
    try:
        return r.json()
    except ValueError:
        return None


def fetch_sports_directory(token: str, ref: int) -> Dict[int, str]:
    """
    Répertoire officiel des sports du bookmaker (noms réels : Football, Tennis, …).

    GET /datafeed/directories/api/v2/sports?ref=…&lng=en
    → {"items":[{"id":1,"name":"Football","maxPeriodCount":3}, …]}

    Sert à étiqueter chaque événement par son sport réel, pour que l'utilisateur
    puisse filtrer le combiné par discipline (ou rester sur « tous les sports »).
    """
    data = _get(token, "/datafeed/directories/api/v2/sports",
                {"ref": ref, "lng": "en"}, pause=1)
    directory: Dict[int, str] = {}
    for item in (data or {}).get("items") or []:
        try:
            directory[int(item["id"])] = str(item["name"])
        except (KeyError, TypeError, ValueError):
            continue
    if directory:
        print(f"   Répertoire sports → {len(directory)} disciplines")
    return directory


def enrich_with_sport_names(events: List[Dict[str, Any]], directory: Dict[int, str]) -> None:
    """Ajoute `sportName` (nom réel) à chaque événement, sur place."""
    if not directory:
        return
    for ev in events:
        sid = ev.get("sportId") or ev.get("sport_id")
        try:
            sid_int = int(sid)
        except (TypeError, ValueError):
            continue
        name = directory.get(sid_int)
        if name:
            ev["sportName"] = name


def fetch_events(provider: str, token: str, limit: int, sport_ids: str = "") -> List[Dict[str, Any]]:
    """
    Charge les événements prematch avec leurs cotes.

    LoadSingle v2 est prioritaire : il renvoie les événements ET leurs
    sélections (oddsLocalization) en une requête, et il est ouvert aux deux
    providers. LoadList n'est utilisé qu'en complément (les scopes LoadList
    ne sont pas ouverts chez tous les bookmakers → HTTP 403).
    """
    events: List[Dict[str, Any]] = []
    try:
        params = {
            "Ref": provider_ref(provider),
            "Lng": "en",
            "SchemeOfGettingOddsOperations": "GetAllOdds",
            # `Count` : nombre max d'événements renvoyés (défaut API = 100).
            # On l'aligne sur la limite demandée pour constituer un pool large
            # (l'utilisateur peut demander un très grand nombre de matchs).
            "Count": str(max(1, min(limit, 1000))),
        }
        if sport_ids:
            params["SportIds"] = sport_ids
        data = _get(token, "/datafeed/prematch/api/v2/sportevents", params, pause=PAUSE_LIVE)
        if data:
            items = data.get("items") or []
            for it in items:
                if len(events) >= limit:
                    break
                if not it.get("oddsLocalization"):
                    continue
                events.append(it)
            print(f"   LoadSingle v2 → {len(items)} événements (retenus {len(events)})")
    except Exception as e:  # pragma: no cover - réseau
        print(f"   ⚠️  LoadSingle v2 indisponible : {e}")

    if not events:
        # Repli LoadList : GetGameIds → GetDetailsGame → GetMarketsGame
        print("   → repli LoadList v1 (GetGameIds / GetDetailsGame / GetMarketsGame)")
        ids = _get(token, "/datafeed/loadlist/prematch/api/v1/GetGameIds",
                   {"ref": provider_ref(provider)}, pause=PAUSE_LINE)
        game_ids = (ids or {}).get("items") or []
        print(f"   GetGameIds → {len(game_ids)} gameIds")
        for gid in game_ids[:limit]:
            details = _get(token, "/datafeed/loadlist/prematch/api/v1/GetDetailsGame",
                           {"ref": provider_ref(provider), "gr": 0, "cnt": 0,
                            "gameId": gid, "languages": "en", "languageForLink": "en"},
                           pause=PAUSE_LINE)
            markets = _get(token, "/datafeed/loadlist/prematch/api/v1/GetMarketsGame",
                           {"cnt": 0, "ref": provider_ref(provider), "gameId": gid},
                           pause=PAUSE_LINE)
            if not markets:
                continue
            events.append({
                "sportEventId": gid,
                **(details or {}),
                "selections": markets.get("items") or [],
            })
    return events[:limit]


def provider_ref(provider: str) -> int:
    if provider.lower() in ("1xbet", "1x"):
        return int(os.getenv("XBET_REF", "1"))
    return int(os.getenv("MEGAPARI_REF", "192"))


def provider_credentials(provider: str) -> tuple:
    if provider.lower() in ("1xbet", "1x"):
        return (os.getenv("XBET_CLIENT_ID", ""),
                os.getenv("XBET_CLIENT_SECRET", ""))
    return (os.getenv("MEGAPARI_CLIENT_ID", ""),
            os.getenv("MEGAPARI_CLIENT_SECRET", ""))


async def run(provider: str, limit: int, dry_run: bool, sport_ids: str = "") -> int:
    client_id, client_secret = provider_credentials(provider)
    if not client_id or not client_secret:
        print(f"❌ Credentials manquantes pour {provider} "
              f"(MEGAPARI_CLIENT_ID/MEGAPARI_CLIENT_SECRET ou XBET_*)")
        return 2

    print(f"=== ETL Bookmaker — {provider} (ref={provider_ref(provider)}) ===")
    token = get_token(client_id, client_secret)
    print("   ✅ token OAuth2 obtenu")

    events = fetch_events(provider, token, limit, sport_ids)
    enrich_with_sport_names(events, fetch_sports_directory(token, provider_ref(provider)))
    if not events:
        print("   ⚠️  aucun événement exploitable — rien à traiter (fail-closed)")
        return 1

    ok = failed = 0
    validated_total = rejected_total = 0
    for ev in events:
        adapted = adapt_betb2b_event(ev)
        # L'adaptateur reconstruit un dict : on y reporte le nom réel du sport
        # (répertoire officiel) pour que le cache soit filtrable par discipline.
        if adapted and ev.get("sportName") and not adapted.get("sportName"):
            adapted["sportName"] = ev["sportName"]
        if not adapted or not adapted.get("markets"):
            failed += 1
            continue
        try:
            res = await process_and_cache_event(adapted, provider=provider.upper(), cache=not dry_run)
        except Exception as e:
            print(f"   ⚠️  event {adapted.get('id')} : {e}")
            failed += 1
            continue
        if res.get("error"):
            failed += 1
            continue
        ok += 1
        validated_total += len(res.get("validated_markets") or [])
        rejected_total += len(res.get("rejected") or [])
        if dry_run:
            print(f"   [{adapted['id']}] {adapted.get('home')} vs {adapted.get('away')} — "
                  f"{len(res.get('validated_markets') or [])} marché(s) validés, "
                  f"{len(res.get('rejected') or [])} rejetés")
            print("      " + json.dumps(res.get("validated_markets") or [], ensure_ascii=False)[:220])

    print(f"\n=== Bilan : {ok} événement(s) traités, {failed} ignoré(s) ===")
    print(f"    marchés validés (marge ≤ 5 %) : {validated_total}")
    print(f"    marchés rejetés (fail-closed) : {rejected_total}")
    if dry_run:
        print("    (dry-run : rien n'a été écrit dans Redis)")
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="ETL bookmaker BetB2B → Margin Guard → Redis")
    parser.add_argument("--provider", default="megapari", choices=["megapari", "1xbet"])
    parser.add_argument("--limit", type=int, default=int(os.getenv("BOOKMAKER_ETL_LIMIT", "25")))
    parser.add_argument("--dry-run", action="store_true", help="affiche sans écrire dans Redis")
    parser.add_argument("--sport-ids", default=os.getenv("BOOKMAKER_ETL_SPORT_IDS", ""),
                        help="IDs de sports (répertoire) séparés par des virgules — vide = tous")
    args = parser.parse_args()
    return asyncio.run(run(args.provider, args.limit, args.dry_run, args.sport_ids))


if __name__ == "__main__":
    raise SystemExit(main())
