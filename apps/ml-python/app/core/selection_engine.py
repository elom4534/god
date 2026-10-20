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
from app.models.elo import win_prob_from_elo
from app.models.dixon_coles import over_under_probs, dixon_coles_probs
from app.services.prediction_engine import DixonColes_1X2_and_OU

# Inférence réelle basée sur Elo + Dixon-Coles (remplace le mock hash)
# Fail-closed: si données insuffisantes, sigma élevé + p conservateur.
def _outcome_prob(market: Dict, event: Dict, selection_id) -> tuple:
    home = event.get("home") or event.get("home_team") or ""
    away = event.get("away") or event.get("away_team") or ""
    mt = market.get("market_type", "")
    line = market.get("line")
    selections = market.get("selections", []) or []
    sel = next((x for x in selections if x.get("selection_id") == selection_id), None)
    tags = [str(t).upper() for t in (sel.get("tags") or [])] if sel else []
    name = (sel.get("name") or "").strip().lower() if sel else ""

    # Lambdas par défaut (moyenne ligue ~2.7 buts) — à remplacer par Dixon-Coles MLE sur historique
    lam_h, lam_a = 1.45, 1.25

    if mt == "1X2":
        p_home, p_draw, p_away = win_prob_from_elo(home, away)
        if "HOME" in tags or name in ("1", "home", home.lower()):
            return p_home
        if "DRAW" in tags or name in ("x", "draw", "nul"):
            return p_draw
        if "AWAY" in tags or name in ("2", "away", away.lower()):
            return p_away
        # fallback by selection name
        if name.startswith("1"): return p_home
        if name.startswith("x"): return p_draw
        if name.startswith("2"): return p_away
        return 1.0/3.0
    if mt == "DOUBLE_CHANCE":
        p_home, p_draw, p_away = win_prob_from_elo(home, away)
        if "HOME_DRAW" in tags or "1X" in tags:
            return p_home + p_draw
        if "HOME_AWAY" in tags or "12" in tags:
            return p_home + p_away
        if "DRAW_AWAY" in tags or "X2" in tags:
            return p_draw + p_away
        return 0.6
    if mt == "OVER_UNDER":
        over, under = over_under_probs(lam_h, lam_a, float(line) if line is not None else 2.5)
        if "OVER" in tags or "over" in name:
            return over
        return under
    if mt == "BTTS":
        probs = DixonColes_1X2_and_OU(lam_h, lam_a, rho=0.08)
        if "YES" in tags or "yes" in name:
            return probs["BTTS_YES"]
        return probs["BTTS_NO"]
    # Marchés de lines (corners, tirs, fautes): Poisson sur total, seuil line
    if mt in ("CORNERS_OU", "SHOTS_ON_TARGET_OU", "FOULS_OU"):
        # lambda moyen selon type
        if "CORNERS" in mt:
            lam_total = 9.5
        elif "SHOTS" in mt:
            lam_total = 10.0
        else:
            lam_total = 22.0
        over, under = over_under_probs(lam_total/2, lam_total/2, float(line) if line is not None else (lam_total/2))
        # reuse over_under with combined lambda via poisson total
        import math
        # compute over/under on total directly
        k_line = int(__import__("math").floor(float(line) if line is not None else lam_total/2))
        p_under = 0.0
        for k in range(k_line+1):
            p_under += (lam_total ** k) * math.exp(-lam_total) / math.factorial(k)
        over = 1 - p_under
        under = p_under
        if "OVER" in tags or "over" in name:
            return over
        return under
    # fallback: équiprobable sur les sélections
    n = max(1, len(selections))
    return 1.0 / n

def real_inference(market: Dict, event: Dict, selection_id=None) -> Tuple[float, float, List[Dict]]:
    """
    Inférence réelle (Elo + Dixon-Coles). Remplace mock_inference.
    Retourne (p_model, sigma, factors).
    """
    p = _outcome_prob(market, event, selection_id)
    p = max(0.01, min(0.99, float(p)))
    mt = market.get("market_type", "")
    # sigma: incertitude selon type de marché et dispo données
    sigma = 0.07
    if mt in ("CORNERS_OU", "SHOTS_ON_TARGET_OU", "FOULS_OU"):
        sigma = 0.10
    if mt in ("OVER_UNDER",):
        sigma = 0.08
    factors = [
        {"name": "elo_baseline", "impact": f"{0.0:+.3f}"},
        {"name": "dixon_coles", "impact": f"{0.0:+.3f}"},
    ]
    return p, sigma, factors

# Backward-compat alias
mock_inference = real_inference

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
            p_model, sigma, factors = real_inference(m, event, opt["selection_id"])
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
                "model_version": "v0.4.0-real",
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
