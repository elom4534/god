"""
MegaPari Margin Guard & Caching Service — Python / FastAPI
Fail-Closed, production-ready, réutilisable 1xBet (même logique, ref différent)

Flux:
  LoadList/LoadSingle → Extraction marchés → Margin Guard (≤5%) → Redis 15min → Payload nettoyé (sans cotes)

Auteur: Backend Trading Sportif
"""
import math
import json
import hashlib
from datetime import datetime, timezone
from typing import List, Dict, Any, Optional, Tuple
import redis.asyncio as redis  # async Redis
import os

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
REDIS_TTL_SECONDS = 15 * 60  # 15 minutes — pré-match uniquement
MARGIN_THRESHOLD = 5.0  # %
PROVIDER = "MEGAPARI"

_redis_client: Optional[redis.Redis] = None

async def get_redis() -> redis.Redis:
    global _redis_client
    if _redis_client is None:
        _redis_client = redis.from_url(REDIS_URL, decode_responses=True, health_check_interval=10)
    return _redis_client

# ---------------------------------------------------------------------------
# Parsing robuste cotes — Fail-Closed sur toute anomalie
# ---------------------------------------------------------------------------
def parse_odds(raw: Any) -> Optional[float]:
    """Gère None, '', '1,85'→1.85, 0, -1, NaN, inf, manquant → None (rejet)"""
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        val = float(raw)
    elif isinstance(raw, str):
        s = raw.strip()
        if s == "":
            return None
        s = s.replace(",", ".")  # virgule décimale FR
        try:
            val = float(s)
        except ValueError:
            return None
    else:
        return None
    if math.isnan(val) or math.isinf(val):
        return None
    if val <= 1.0:  # cote ≤1 invalide (bookmaker ne propose jamais 1.0)
        return None
    if val > 1000:  # aberrant (erreur feed)
        return None
    return val

def implied_prob(odds: float) -> Optional[float]:
    try:
        if odds is None or odds <= 1.0:
            return None
        return 1.0 / odds
    except Exception:
        return None

# ---------------------------------------------------------------------------
# Margin Guard — Formules trading sportif
# ---------------------------------------------------------------------------
def compute_margin_exclusive(odds_list: List[float]) -> Optional[float]:
    """
    Marchés exclusifs 2/3 issues (1X2, O/U, BTTS):
      marge% = (sum(1/odds) - 1) * 100
    Ex: [1.95, 1.95] → (0.5128+0.5128-1)*100 = 2.56% → validé
        [2.0, 3.0, 4.0] → 8.33% → rejet
    """
    if not odds_list or len(odds_list) < 2:
        return None
    probs = []
    for o in odds_list:
        p = implied_prob(o)
        if p is None:
            return None
        probs.append(p)
    return (sum(probs) - 1.0) * 100.0

def compute_margin_double_chance(odds_dc: List[float], odds_1x2: Optional[List[float]] = None) -> Dict[str, Any]:
    """
    Double Chance (non-exclusif): 1X, X2, 12
    Formule dédiée + contrôle cohérence vs 1X2 si disponible.
    Si écart >7% entre DC théorique et observé → rejet (marché incohérent)
    """
    margin_dc = compute_margin_exclusive(odds_dc)
    coherence_ok = True
    if odds_1x2 and len(odds_1x2) == 3 and margin_dc is not None:
        try:
            p1, px, p2 = [1/o for o in odds_1x2]
            theoretical = [p1+px, px+p2, p1+p2]  # P(1X), P(X2), P(12)
            observed = [1/o for o in odds_dc]
            diffs = [abs(a-b) for a, b in zip(theoretical, observed)]
            if max(diffs) > 0.07:
                coherence_ok = False
        except Exception:
            coherence_ok = False
    return {"margin_percent": margin_dc, "coherence_ok": coherence_ok}

# Taxonomie marchés (réutilisable 1xBet)
MARKET_CATEGORY = {
    "1X2": "exclusive_3",
    "OVER_UNDER": "exclusive_2",
    "BTTS": "exclusive_2",
    "CORNERS_OU": "exclusive_2",
    "DOUBLE_CHANCE": "non_exclusive",
    "HANDICAP": "handicap",
}

def classify_market(market_type: str) -> str:
    return MARKET_CATEGORY.get(market_type.upper(), "reject")

# ---------------------------------------------------------------------------
# Extraction marchés depuis flux MegaPari (LoadList / LoadSingle)
# ---------------------------------------------------------------------------
def extract_markets_from_megapari(raw_event: Dict[str, Any]) -> List[Dict[str, Any]]:
    """
    Normalise payload brut MegaPari (LoadList getDetailsGame / getMarketsGame + LoadSingle)
    en schéma interne stable. Gère 300+ marchés, champs manquants, formats hétérogènes.
    """
    markets = []
    # LoadList getDetailsGame: marchés dans raw_event['markets'] ou ['odds'] ou ['items']
    raw_markets = raw_event.get("markets") or raw_event.get("odds") or raw_event.get("items") or []
    if isinstance(raw_markets, dict):
        raw_markets = [raw_markets]

    for rm in raw_markets:
        if not isinstance(rm, dict):
            continue
        # Mapping type MegaPari → market_type interne
        # Type IDs BetB2B: 1=1X2, 7/8=Handicap, 9/10=Total O/U, 11/12=IT1, etc.
        type_id = rm.get("type")
        market_type = {
            1: "1X2", 2: "DOUBLE_CHANCE",  # hypothèse mapping
            7: "HANDICAP", 8: "HANDICAP",
            9: "OVER_UNDER", 10: "OVER_UNDER",
            11: "OVER_UNDER", 12: "OVER_UNDER",
        }.get(type_id, rm.get("market_type") or "OVER_UNDER")

        selections = []
        # Format MegaPari: oddsMarket direct + parameter (line)
        if "oddsMarket" in rm:
            # Marché 2 issues (Over/Under, Handicap)
            # On génère 2 sélections: Over/Under ou Home/Away
            param = rm.get("parameter")
            selections = [
                {"selection_id": f"{rm.get('type')}_{param}_1", "name": rm.get("display", f"Over {param}"), "odds": rm.get("oddsMarket"), "odds_internal": rm.get("oddsMarket"), "tags": ["OVER"]},
                # Pour un vrai marché O/U, il faut 2 items (type 9 et 10) — on les pairera côté scan
            ]
            # Ici on stocke 1 sélection par item BetB2B — le scan regroupera par paires
            markets.append({
                "market_id": f"{raw_event.get('id') or raw_event.get('gameId')}_{type_id}_{param}",
                "market_type": market_type,
                "line": float(param) if param is not None else None,
                "selections": selections,
                "is_blocked": rm.get("isBlocked", False),
            })
        else:
            # Format générique
            sels = rm.get("selections") or rm.get("outcomes") or []
            for s in sels:
                selections.append({
                    "selection_id": str(s.get("id") or s.get("selection_id")),
                    "name": str(s.get("name") or s.get("display", "")),
                    "odds": s.get("odds") or s.get("price"),
                    "odds_internal": s.get("odds") or s.get("price"),
                    "tags": s.get("tags", []),
                })
            markets.append({
                "market_id": str(rm.get("id") or rm.get("market_id") or f"mkt_{type_id}"),
                "market_type": market_type,
                "line": rm.get("line") or rm.get("parameter"),
                "selections": selections,
                "is_blocked": rm.get("isBlocked", False),
            })
    return markets

# ---------------------------------------------------------------------------
# Service principal — Margin Guard + Redis Cache
# ---------------------------------------------------------------------------
async def process_and_cache_event(
    raw_event: Dict[str, Any],
    provider: str = PROVIDER,
    threshold: float = MARGIN_THRESHOLD,
    cache: bool = True,
) -> Dict[str, Any]:
    """
    Traite 1 event MegaPari:
      1. Extraction marchés
      2. Margin Guard strict (≤5% ou rejet Fail-Closed)
      3. Cache Redis 15min
      4. Retour payload nettoyé SANS cotes (prêt Selection Engine)

    Returns:
      {
        event_id, provider, validated_markets: [{market_id, market_type, margin_percent, selections: [{selection_id, name, tags}]}],
        rejected: [{market_id, reason_code, margin_percent}],
        cached_key, as_of
      }
    """
    event_id = str(raw_event.get("id") or raw_event.get("gameId") or raw_event.get("sportEventId") or "")
    if not event_id:
        return {"error": "MISSING_EVENT_ID", "reason_code": "MISSING_EVENT_ID"}

    # Extraction
    markets = extract_markets_from_megapari(raw_event)
    # Fallback: si raw_event contient déjà des marchés normalisés (tests)
    if not markets and raw_event.get("markets"):
        markets = raw_event["markets"]

    validated = []
    rejected = []

    for m in markets:
        if m.get("is_blocked"):
            rejected.append({"market_id": m["market_id"], "reason_code": "MARKET_BLOCKED"})
            continue
        sels = m.get("selections", [])
        if not sels or len(sels) < 1:
            rejected.append({"market_id": m["market_id"], "reason_code": "INCOMPLETE_MARKET"})
            continue

        # Parsing cotes — toute cote invalide → rejet marché entier (Fail-Closed)
        parsed_odds = []
        valid_sels = []
        for s in sels:
            raw_odds = s.get("odds") if "odds" in s else s.get("odds_internal")
            parsed = parse_odds(raw_odds)
            if parsed is None:
                parsed_odds = None
                break
            parsed_odds.append(parsed)
            valid_sels.append(s)

        if parsed_odds is None:
            rejected.append({"market_id": m["market_id"], "reason_code": "INVALID_ODDS_FORMAT"})
            continue

        # Pour les marchés BetB2B 1-sélection (type 9 seul), on ne peut calculer marge seul
        # → on attend la paire (type 9 + 10) — si seul, on le garde en pending et on le pairera
        # Ici simplifié: si 1 seule cote → on ne peut calculer marge → rejet Fail-Closed sauf si on a la paire
        if len(parsed_odds) == 1:
            # Tentative de paire: chercher l'autre côté dans les marchés voisins (même parameter, type complémentaire)
            # Pour MVP, on rejette les marchés singletons (manque données)
            rejected.append({"market_id": m["market_id"], "reason_code": "SINGLE_SELECTION_NO_PAIR"})
            continue

        # Calcul marge
        mtype = m.get("market_type", "OVER_UNDER")
        category = classify_market(mtype)
        margin = None
        coherence_ok = True

        if category in ("exclusive_2", "exclusive_3", "handicap"):
            margin = compute_margin_exclusive(parsed_odds)
        elif category == "non_exclusive":
            margin = compute_margin_double_chance(parsed_odds).get("margin_percent")
            coherence_ok = compute_margin_double_chance(parsed_odds).get("coherence_ok", True)
            if not coherence_ok:
                rejected.append({"market_id": m["market_id"], "margin_percent": round(margin, 2) if margin else None, "reason_code": "DOUBLE_CHANCE_INCOHERENT"})
                continue
        else:
            rejected.append({"market_id": m["market_id"], "reason_code": "REJECT_CATEGORY"})
            continue

        if margin is None or math.isnan(margin) or math.isinf(margin):
            rejected.append({"market_id": m["market_id"], "reason_code": "MARGIN_NOT_COMPUTABLE"})
            continue

        margin = round(margin, 2)
        if margin <= threshold:
            # Validé — on ne garde que les champs sans cotes pour le client
            validated.append({
                "market_id": m["market_id"],
                "market_type": mtype,
                "line": m.get("line"),
                "margin_percent": margin,
                "selections": [
                    {
                        "selection_id": s["selection_id"],
                        "name": s["name"],
                        "tags": s.get("tags", []),
                        # Taxonomie BetB2B exacte (issue du flux LoadSingle) — sert au
                        # lien coupon sharecoupon (type + parameter signé).
                        "b2b_type": s.get("_betb2b_type"),
                        "b2b_parameter": s.get("_betb2b_parameter"),
                    }
                    # odds intentionnellement omises — stockées interne uniquement
                    for s in valid_sels
                ],
                # Interne: on garde odds pour audit/EV mais jamais exposé API publique
                "_odds_internal": parsed_odds,
                "reason_code": "OK",
            })
        else:
            rejected.append({"market_id": m["market_id"], "margin_percent": margin, "reason_code": "MARGIN_GT_5"})

    # 3. Cache Redis 15min — clé = megapari:event:{event_id}
    as_of = datetime.now(timezone.utc).isoformat()
    # Métadonnées d'affichage (noms, logos, ligue, coup d'envoi) — nécessaires
    # au générateur de combiné pour présenter des libellés lisibles côté client.
    try:
        from app.services.esports_pipeline import extract_event_meta
        meta = extract_event_meta(raw_event)
    except Exception:
        meta = {"home_team": "", "away_team": "", "league": "", "start_time": None,
                "sport": "football", "home_logo_url": "", "away_logo_url": ""}
    cache_payload = {
        "event_id": event_id,
        "provider": provider,
        "validated_markets": validated,
        "rejected": rejected,
        "home_team": meta.get("home_team", ""),
        "away_team": meta.get("away_team", ""),
        "home_logo_url": meta.get("home_logo_url", ""),
        "away_logo_url": meta.get("away_logo_url", ""),
        "league": meta.get("league", ""),
        "sport": meta.get("sport", "football"),
        "start_time": meta.get("start_time"),
        "as_of": as_of,
        "model_version": "v0.3.0",
    }

    # On stocke en Redis (TTL 15min) — pour Selection Engine + pré-calcul picks (si cache=True)
    if cache:
        try:
            r = await get_redis()
            redis_key = f"megapari:event:{event_id}"
            await r.setex(redis_key, REDIS_TTL_SECONDS, json.dumps(cache_payload, ensure_ascii=False))
            # Aussi index par start_time pour requêtes rapides (zset)
            start_time = raw_event.get("start_time") or raw_event.get("startDate")
            if start_time:
                await r.zadd("megapari:events:by_time", {event_id: float(start_time) if isinstance(start_time, (int, float)) else 0})
        except Exception as e:
            # Redis down → Fail-Closed: on log mais on retourne quand même le payload (pas de cache)
            print(f"[MEGAPARI CACHE ERROR] {e} — fallback sans Redis")

    # 4. Payload nettoyé — SANS cotes (prêt Selection Engine)
    # On retire _odds_internal avant envoi client, mais on le garde pour PG si besoin
    for vm in validated:
        vm.pop("_odds_internal", None)

    return {
        "event_id": event_id,
        "provider": provider,
        "validated_markets": validated,
        "rejected": rejected,
        "cached_key": f"megapari:event:{event_id}",
        "ttl_seconds": REDIS_TTL_SECONDS,
        "as_of": as_of,
    }

# ---------------------------------------------------------------------------
# Helper batch — pour endpoint FastAPI POST /megapari/ingest
# ---------------------------------------------------------------------------
async def process_batch_megapari(raw_events: List[Dict[str, Any]], threshold: float = MARGIN_THRESHOLD) -> Dict[str, Any]:
    results = []
    for raw in raw_events:
        res = await process_and_cache_event(raw, threshold=threshold)
        results.append(res)
    return {
        "provider": PROVIDER,
        "processed": len(results),
        "events": results,
        "threshold": threshold,
        "as_of": datetime.now(timezone.utc).isoformat(),
    }
