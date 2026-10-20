"""
Taxonomie marchés 300+ — classification pour Normalizer + Margin Guard.
"""
from enum import Enum

class MarketCategory(str, Enum):
    EXCLUSIVE_2 = "exclusive_2"  # O/U, BTTS, Yes/No
    EXCLUSIVE_3 = "exclusive_3"  # 1X2
    NON_EXCLUSIVE = "non_exclusive"  # Double Chance
    HANDICAP = "handicap"
    REJECT = "reject"  # exotique / non fiable

TAXONOMY = {
    "1X2": MarketCategory.EXCLUSIVE_3,
    "1X2_HT": MarketCategory.EXCLUSIVE_3,
    "BTTS": MarketCategory.EXCLUSIVE_2,
    "BTTS_YES_NO": MarketCategory.EXCLUSIVE_2,
    "OVER_UNDER": MarketCategory.EXCLUSIVE_2,
    "CORNERS_OU": MarketCategory.EXCLUSIVE_2,
    "SHOTS_ON_TARGET_OU": MarketCategory.EXCLUSIVE_2,
    "FOULS_OU": MarketCategory.EXCLUSIVE_2,
    "DOUBLE_CHANCE": MarketCategory.NON_EXCLUSIVE,
    "HANDICAP": MarketCategory.HANDICAP,
    "ASIAN_HANDICAP": MarketCategory.HANDICAP,
    "CORRECT_SCORE": MarketCategory.REJECT,  # fail-closed par défaut (trop volatile)
    "UNKNOWN": MarketCategory.REJECT,
}

def classify(market_type: str) -> MarketCategory:
    return TAXONOMY.get(market_type.upper(), MarketCategory.REJECT)
