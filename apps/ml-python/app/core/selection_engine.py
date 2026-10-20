"""
Selection Engine — 3 étages: éligibilité, scoring conservateur, choix 1/match strict.
Fail-closed + déterministe + traçable.
"""
from typing import List, Dict, Any, Tuple
from datetime import datetime, timezone
import math
import hashlib

from app.core.margin_guard import scan_markets
from app.core.taxonomy import classify, MarketCategory

# Mock modèle pour MVP — en prod remplacé par Elo/Dixon-Coles/CatBoost calibré
# On simule p_model + sigma à partir de features heuristiques
def mock_inference(market: Dict, event: Dict) -> Tuple[float, float, List[Dict]]:
    """
    Retourne (p_model, sigma, factors).
    MVP: heuristique déterministe basée sur hash(event+market) pour reproductibilité sans vrai modèle.
    Prod: appel au modèle versionné (Elo, Poisson, CatBoost).
    """
    seed = f"{event['event_id']}|{market['market_id']}|{market['market_type']}|{market.get('line')}"
    h = int(hashlib.md5(seed.encode()).hexdigest()[:8], 16)
    # p_model entre 0.35 et 0.75
    p = 0.35 + (h % 400) / 1000.0
    # sigma entre 0.04 et 0.12
    sigma = 0.04 + (h % 80) / 1000.0
    # factors mock
    factors = [
        {"name": "elo_diff", "impact": f"+{0.02 + (h%20)/500:.3f}"},
        {"name": "form_home", "impact": f"+{0.01 + (h%15)/500:.3f}"},
        {"name": "xG_trend", "impact": f"{-0.02 + (h%30)/1000:.3f}"},
    ]
    return p, sigma, factors

def confidence_from_sigma(sigma: float, p_lower: float) -> str:
    if sigma <= 0.06 and p_lower >= 0.55:
        return "HIGH"
    if sigma <= 0.09 and p_lower >= 0.50:
        return "MEDIUM"
    return "LOW"

def score_conservative(p_lower: float, sigma: float, stability: float = 1.0, penalties: float = 0.0) -> float:
    """
    score = p_lower * stabilité - pénalités
    stabilité: 0.8-1.0 (marchés fragiles/drift/low-data réduisent)
    pénalités: ex 0.05 pour corners low-data
    """
    return max(0.0, p_lower * stability - penalties)

def select_best_per_event(events: List[Dict], mode: str = "real_only", k_sigma: float = 1.0, threshold_pct: float = 5.0) -> Dict:
    picks = []
    skipped = []
    now = datetime.now(timezone.utc).isoformat()

    for event in events:
        # filtre mode
        is_virtual = event.get("is_virtual", False)
        if mode == "real_only" and is_virtual:
            skipped.append({"event_id": event["event_id"], "reason_code": "FILTERED_VIRTUAL_EXCLUDED"})
            continue
        if mode == "virtual_only" and not is_virtual:
            skipped.append({"event_id": event["event_id"], "reason_code": "FILTERED_REAL_EXCLUDED"})
            continue

        markets = event.get("markets", [])
        if not markets:
            skipped.append({"event_id": event["event_id"], "reason_code": "NO_MARKETS"})
            continue

        # 1. Éligibilité: Margin Guard
        scan_res = scan_markets(markets, threshold_pct=threshold_pct)
        validated = scan_res["validated_options"]
        if not validated:
            skipped.append({"event_id": event["event_id"], "reason_code": "NO_ELIGIBLE_MARKET_AFTER_MARGIN_GUARD"})
            continue

        # Group validated by market_id+selection
        # On doit reconstituer l'objet market complet pour inference
        market_lookup = {m["market_id"]: m for m in markets}
        candidates = []

        for opt in validated:
            m = market_lookup.get(opt["market_id"])
            if not m:
                continue
            # Compatibilité modèle: si market_type REJECT → skip (déjà filtré)
            cat = classify(m["market_type"])
            if cat == MarketCategory.REJECT:
                continue

            # 2. Scoring conservateur
            p_model, sigma, factors = mock_inference(m, event)
            # Règles données: pas assez d'historique → pénalité (simulé pour corners)
            stability = 1.0
            penalties = 0.0
            warnings = []
            if m["market_type"] in ("CORNERS_OU", "SHOTS_ON_TARGET_OU", "FOULS_OU"):
                # simuler low-data
                h = int(hashlib.md5(event["event_id"].encode()).hexdigest()[:4], 16)
                if h % 3 == 0:
                    stability = 0.85
                    penalties = 0.03
                    warnings.append("LOW_HISTORY_CORNERS")
            # drift simulé pour virtuel
            if is_virtual:
                h2 = int(hashlib.md5((event["event_id"]+m["market_id"]).encode()).hexdigest()[:4], 16)
                if h2 % 10 == 0:
                    stability *= 0.9
                    warnings.append("VIRTUAL_DRIFT_SUSPECTED")

            p_lower = p_model - k_sigma * sigma
            p_lower = max(0.0, min(1.0, p_lower))
            conf = confidence_from_sigma(sigma, p_lower)
            sc = score_conservative(p_lower, sigma, stability, penalties)

            # Filtre confiance minimale: si p_lower <0.50 et marché 2 issues → on peut skip car peu d'edge
            # Mais on garde pour laisser le scoring décider ; fail-closed seulement si sigma trop grand
            if sigma > 0.15:
                warnings.append("HIGH_UNCERTAINTY")
                # on penalise fort mais on ne rejette pas encore
                sc *= 0.7

            candidates.append({
                "event_id": event["event_id"],
                "market_id": m["market_id"],
                "selection_id": opt["selection_id"],
                "market_type": m["market_type"],
                "line": m["line"],
                "p_model": round(p_model, 4),
                "sigma": round(sigma, 4),
                "p_lower": round(p_lower, 4),
                "confidence": conf,
                "score": round(sc, 4),
                "factors": factors,
                "warnings": warnings,
                "model_version": "v0.3.0-mvp",
                "as_of": now,
                "_raw_market": m
            })

        if not candidates:
            skipped.append({"event_id": event["event_id"], "reason_code": "NO_CANDIDATE_AFTER_SCORING"})
            continue

        # 3. Choix final 1/match strict, déterministe
        # Tri: score desc, p_lower desc, confidence (HIGH>MEDIUM>LOW), market_type lexical
        def sort_key(c):
            conf_order = {"HIGH": 0, "MEDIUM": 1, "LOW": 2}
            return (-c["score"], -c["p_lower"], conf_order.get(c["confidence"], 3), c["market_type"], c["market_id"])
        candidates.sort(key=sort_key)
        best = candidates[0]
        # Retirer champ interne
        best.pop("_raw_market", None)

        # Seuil final: si best score <0.35 → on considère trop faible → skip (fail-closed)
        if best["score"] < 0.30:
            skipped.append({"event_id": event["event_id"], "reason_code": "BEST_SCORE_TOO_LOW", "best_score": best["score"]})
            continue

        picks.append(best)

    return {"picks": picks, "skipped": skipped, "as_of": now}
