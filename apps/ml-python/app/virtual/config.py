"""
Configuration du module Football Virtuel (FIFA Virtual & Sega Virtual).

TOUTES les données proviennent du flux Partner API MegaPari — aucune donnée
simulée, estimée ou codée en dur. Les seuils ci-dessous ne sont que des
paramètres de fonctionnement (polling, calibration, value bet).
"""
from __future__ import annotations

import os
from typing import Dict, Tuple

# --------------------------------------------------------------- Partner API
BOOKMAKER_TOKEN_URL = os.getenv("BOOKMAKER_TOKEN_URL", "https://cpservm.com/gateway/token")
BOOKMAKER_API_BASE = os.getenv("BOOKMAKER_API_BASE", "https://cpservm.com/gateway/marketing").rstrip("/")
MEGAPARI_REF = int(os.getenv("MEGAPARI_REF", "192"))

# Clé partenaire : côté serveur UNIQUEMENT (gestionnaire de secrets).
# Jamais côté Flutter, jamais dans git, jamais dans les logs.
API_KEY_ENV = "MEGAPARI_PARTNER_API_KEY"
API_KEY_FALLBACK_ENV = "MEGAPARI_CLIENT_SECRET"
CLIENT_ID_ENV = "MEGAPARI_CLIENT_ID"

# ----------------------------------------------- Rate limits officiels (docs)
# LoadSingle prematch : 1 req / 20 s (mêmes params) ; live : 1 req / 5 s.
PAUSE_LIVE = float(os.getenv("BOOKMAKER_PAUSE_LIVE", "5"))
PAUSE_LINE = float(os.getenv("BOOKMAKER_PAUSE_LINE", "20"))
PAUSE_RESULT = float(os.getenv("BOOKMAKER_PAUSE_RESULT", "5"))

# ----------------------------------------------------- Polling adaptatif
POLL_NORMAL = float(os.getenv("VIRTUAL_POLL_NORMAL", "60"))
POLL_PRE_ROUND = float(os.getenv("VIRTUAL_POLL_PRE_ROUND", "10"))
POLL_LIVE = float(os.getenv("VIRTUAL_POLL_LIVE", "10"))
PRE_ROUND_WINDOW = float(os.getenv("VIRTUAL_PRE_ROUND_WINDOW", "120"))
RESULTS_SWEEP = float(os.getenv("VIRTUAL_RESULTS_SWEEP", "60"))
ODDS_SNAPSHOT_INTERVAL = float(os.getenv("VIRTUAL_ODDS_SNAPSHOT_INTERVAL", "60"))

INGEST_ENABLED = os.getenv("VIRTUAL_INGEST_ENABLED", "true").lower() in ("1", "true", "yes")

# ------------------------------------------ Classification des providers
# Aucun ID provider dans le flux → regex sur le nom de tournoi (configurable).
# Familles validées avec le commanditaire le 21/10/2026 (voir
# docs/virtual_partner_api.md §3).
FIFA_TOURNAMENT_RE = os.getenv(
    "VIRTUAL_FIFA_TOURNAMENTS", r"^(FIFA \d+\.|FC \d+\. eSports Battle|Esoccer )"
)
SEGA_TOURNAMENT_RE = os.getenv("VIRTUAL_SEGA_TOURNAMENTS", r"^Virtual eComp\.")

PROVIDERS: Tuple[str, ...] = ("FIFA_VIRTUAL", "SEGA_VIRTUAL")

# ------------------------------------------------------- Mapping des marchés
# Types réels vérifiés en production (docs/virtual_partner_api.md §4).
# type -> (market, selection) ; la ligne (parameter) est stockée à part.
MARKET_BY_TYPE: Dict[int, Tuple[str, str]] = {
    1: ("1X2", "1"),
    2: ("1X2", "X"),
    3: ("1X2", "2"),
    180: ("BTTS", "YES"),
    181: ("BTTS", "NO"),
    9: ("TOTAL", "OVER"),
    10: ("TOTAL", "UNDER"),
    3827: ("TOTAL", "OVER"),     # lignes asiatiques (.25/.75) — TOUTES les lignes
    3828: ("TOTAL", "UNDER"),
    7: ("HANDICAP", "H1"),
    8: ("HANDICAP", "H2"),
    3829: ("HANDICAP", "H1"),
    3830: ("HANDICAP", "H2"),
    11: ("IND_TOTAL", "OVER"),
    12: ("IND_TOTAL", "UNDER"),
    13: ("IND_TOTAL", "OVER"),
    14: ("IND_TOTAL", "UNDER"),
    182: ("ODD_EVEN", "YES"),
    183: ("ODD_EVEN", "NO"),
    388: ("NEXT_GOAL", "TEAM1"),
    389: ("NEXT_GOAL", "TEAM2"),
    390: ("NEXT_GOAL", "NEITHER"),
}
# HT-FT (15-23) et Correct Score (731) : selection = libellé réel du flux.
HTFT_TYPES = set(range(15, 24))
CORRECT_SCORE_TYPE = 731
LINE_MARKETS = {"TOTAL", "HANDICAP", "IND_TOTAL"}

# ------------------------------------------- Modèle / calibration / valeur
MIN_OBSERVATIONS = int(os.getenv("VIRTUAL_MIN_OBSERVATIONS", "100"))
CALIBRATION_MIN_HOURS = float(os.getenv("VIRTUAL_CALIBRATION_MIN_HOURS", "24"))
VALUE_MIN_EDGE = float(os.getenv("VIRTUAL_VALUE_MIN_EDGE", "0.10"))
DRIFT_WINDOW = int(os.getenv("VIRTUAL_DRIFT_WINDOW", "50"))
DRIFT_FACTOR = float(os.getenv("VIRTUAL_DRIFT_FACTOR", "1.35"))
LGBM_BLEND = float(os.getenv("VIRTUAL_LGBM_BLEND", "0.5"))
