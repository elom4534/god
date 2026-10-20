"""
Parsing robuste cotes — gère None, "", "1,85", 0, -1, NaN, inf, missing.
"""
import math

def parse_odds(raw) -> float | None:
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        # already numeric
        val = float(raw)
    elif isinstance(raw, str):
        s = raw.strip()
        if s == "":
            return None
        # handle comma decimal: "1,85" -> "1.85"
        s = s.replace(",", ".")
        # handle thousands sep incorrectly passed?
        try:
            val = float(s)
        except ValueError:
            return None
    else:
        return None

    if math.isnan(val) or math.isinf(val):
        return None
    if val <= 1.0:  # cotes <=1 invalides (même 1.0 est nulle)
        return None
    if val > 1000:  # aberrant
        return None
    return val

def safe_implied_prob(odds: float) -> float | None:
    try:
        if odds is None or odds <= 1.0:
            return None
        return 1.0 / odds
    except Exception:
        return None
