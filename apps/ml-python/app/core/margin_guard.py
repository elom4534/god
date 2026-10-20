"""
Margin Guard — fail-closed, marge >5% = rejet.
Gère exclusifs 2/3 issues, Double Chance, sous-marchés lines.
"""
from typing import List, Dict, Any
import math
from app.utils.parsing import parse_odds, safe_implied_prob
from app.core.taxonomy import classify, MarketCategory

def compute_margin_exclusive(odds_list: List[float]) -> float | None:
    """marge% = (sum(1/odds) -1)*100 pour marchés exclusifs."""
    if not odds_list or len(odds_list) < 2:
        return None
    probs = []
    for o in odds_list:
        p = safe_implied_prob(o)
        if p is None:
            return None
        probs.append(p)
    s = sum(probs)
    return (s - 1.0) * 100.0

def compute_margin_double_chance(odds_dc: List[float], odds_1x2: List[float] | None = None) -> Dict[str, Any]:
    """
    Double Chance: 1X, X2, 12. Non exclusif — formule dédiée + contrôle cohérence.
    On calcule marge DC séparément, et si 1X2 disponible on vérifie cohérence.
    Règle: si cohérence écart >7% → rejet (marché incohérent).
    """
    margin_dc = compute_margin_exclusive(odds_dc)
    # cohérence vs 1X2: la somme des probas DC /2 devrait ≈1 (chevauchement)
    # Simplifié: on vérifie juste que margin_dc n'est pas aberrant et que les cotes DC sont cohérentes
    # Ex: si 1X2 = [2.0,3.0,4.0] alors P(1X)=0.5+0.33=0.83 → cote DC 1X ≈1.20
    coherence_ok = True
    if odds_1x2 and len(odds_1x2)==3 and margin_dc is not None:
        try:
            p1, px, p2 = [1/o for o in odds_1x2]
            implied_dc = [p1+px, px+p2, p1+p2]
            # comparer avec implied proba DC observée
            observed_p_dc = [1/o for o in odds_dc]
            diffs = [abs(a-b) for a,b in zip(implied_dc, observed_p_dc)]
            if max(diffs) > 0.07:
                coherence_ok = False
        except Exception:
            coherence_ok = False
    return {"margin_pct": margin_dc, "coherence_ok": coherence_ok}

def scan_markets(markets: List[Dict[str, Any]], threshold_pct: float = 5.0) -> Dict[str, List[Dict]]:
    validated = []
    rejected = []

    for m in markets:
        market_id = m.get("market_id", "unknown")
        market_type = m.get("market_type", "UNKNOWN")
        line = m.get("line")
        selections = m.get("selections", [])
        category = classify(market_type)

        if category == MarketCategory.REJECT:
            rejected.append({"market_id": market_id, "reason_code": "REJECT_CATEGORY", "category": str(category)})
            continue
        if not selections or len(selections) < 2:
            rejected.append({"market_id": market_id, "reason_code": "INCOMPLETE_MARKET"})
            continue

        # Parse odds
        parsed_odds = []
        valid_selections = []
        for s in selections:
            raw_odds = s.get("odds") if "odds" in s else s.get("odds_internal")
            parsed = parse_odds(raw_odds)
            if parsed is None:
                # une cote invalide → tout le marché rejeté (fail-closed)
                parsed_odds = None
                break
            parsed_odds.append(parsed)
            valid_selections.append(s)

        if parsed_odds is None:
            rejected.append({"market_id": market_id, "reason_code": "INVALID_ODDS_FORMAT"})
            continue

        # Calcul marge selon catégorie
        margin = None
        coherence_ok = True
        if category in (MarketCategory.EXCLUSIVE_2, MarketCategory.EXCLUSIVE_3, MarketCategory.HANDICAP):
            margin = compute_margin_exclusive(parsed_odds)
        elif category == MarketCategory.NON_EXCLUSIVE:
            # tenter de retrouver 1X2 du même event pour cohérence (si fourni dans meta)
            odds_1x2 = m.get("_odds_1x2_ref")
            res = compute_margin_double_chance(parsed_odds, odds_1x2)
            margin = res["margin_pct"]
            coherence_ok = res["coherence_ok"]
            if not coherence_ok:
                rejected.append({"market_id": market_id, "margin_pct": margin, "reason_code": "DOUBLE_CHANCE_INCOHERENT"})
                continue
        else:
            rejected.append({"market_id": market_id, "reason_code": "UNKNOWN_CATEGORY"})
            continue

        if margin is None:
            rejected.append({"market_id": market_id, "reason_code": "MARGIN_NOT_COMPUTABLE"})
            continue
        if math.isnan(margin) or math.isinf(margin):
            rejected.append({"market_id": market_id, "reason_code": "MARGIN_NAN_INF"})
            continue

        # Décision threshold
        if margin <= threshold_pct:
            # validated: chaque sélection est une option éligible
            for sel, odds in zip(valid_selections, parsed_odds):
                validated.append({
                    "market_id": market_id,
                    "market_type": market_type,
                    "line": line,
                    "selection_id": sel.get("selection_id"),
                    "margin_pct": round(margin, 2),
                    "reason_code": "OK",
                })
        else:
            rejected.append({
                "market_id": market_id,
                "margin_pct": round(margin, 2),
                "reason_code": "MARGIN_GT_5",
                "threshold": threshold_pct
            })

    return {"validated_options": validated, "rejected_options": rejected}

# Fonction utilitaire pour endpoint
def scan_event_markets(event_id: str, markets: List[Dict], threshold_pct: float = 5.0) -> Dict:
    result = scan_markets(markets, threshold_pct)
    return {
        "event_id": event_id,
        **result,
        "as_of": __import__("datetime").datetime.utcnow().isoformat() + "Z"
    }
