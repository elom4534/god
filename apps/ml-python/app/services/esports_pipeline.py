"""
Pipeline E-Sports FIFA + Sega Football (jeux virtuels) — données RÉELLES uniquement.

Architecture :
  1. Ingestion temps réel depuis MegaPari (BetB2B LoadSingle v2, SportIds FIFA/Sega).
  2. Classification par catégorie (comme l'UI MegaPari) : nom équipe/joueur + logo.
  3. Snapshot pré-match des cotes 1N2 / BTTS / Over-Under juste avant coup d'envoi.
  4. Archivage du résultat final post-match dans match_snapshots (PostgreSQL).

Aucune simulation : si le flux réel est indisponible, on ne produit rien (fail-closed).
"""
from __future__ import annotations

import os
import json
import math
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, List, Optional

# SportIds MegaPari pour les e-sports / virtuels (à confirmer avec le manager)
FIFA_ESPORTS_SPORT_IDS = os.getenv("FIFA_ESPORTS_SPORT_IDS", "1001").split(",")
SEGA_FOOTBALL_SPORT_IDS = os.getenv("SEGA_FOOTBALL_SPORT_IDS", "1002").split(",")

SPORT_LABELS = {
    "fifa_esports": "FIFA E-Sports",
    "sega_football": "Sega Football",
}


def classify_sport(raw_event: Dict[str, Any]) -> str:
    """Classe un événement MegaPari en sport interne (fifa_esports | sega_football | football)."""
    sport_id = str(raw_event.get("sportId") or raw_event.get("sport_id") or "")
    sport_name = str(raw_event.get("sportName") or raw_event.get("sport") or "").lower()
    if sport_id in FIFA_ESPORTS_SPORT_IDS or "fifa" in sport_name or "e-football" in sport_name or "esports" in sport_name:
        return "fifa_esports"
    if sport_id in SEGA_FOOTBALL_SPORT_IDS or "sega" in sport_name or "virtual" in sport_name:
        return "sega_football"
    return "football"


def extract_event_meta(raw_event: Dict[str, Any]) -> Dict[str, Any]:
    """Extrait les métadonnées d'affichage (noms, logos) comme l'UI MegaPari."""
    home = raw_event.get("homeTeam") or raw_event.get("home") or raw_event.get("team1") or {}
    away = raw_event.get("awayTeam") or raw_event.get("away") or raw_event.get("team2") or {}
    if isinstance(home, str):
        home = {"name": home}
    if isinstance(away, str):
        away = {"name": away}
    return {
        "event_id": str(raw_event.get("id") or raw_event.get("sportEventId") or raw_event.get("gameId") or ""),
        "sport": classify_sport(raw_event),
        "league": raw_event.get("leagueName") or raw_event.get("league") or raw_event.get("tournament") or "",
        "home_team": home.get("name") or home.get("title") or "",
        "away_team": away.get("name") or away.get("title") or "",
        "home_logo_url": home.get("logo") or home.get("logoUrl") or home.get("image") or "",
        "away_logo_url": away.get("logo") or away.get("logoUrl") or away.get("image") or "",
        "start_time": raw_event.get("startDate") or raw_event.get("start_time") or raw_event.get("startTime"),
        "is_virtual": classify_sport(raw_event) in ("fifa_esports", "sega_football"),
    }


def snapshot_prematch_odds(raw_event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Extrait les cotes 1N2 / BTTS / Over-Under depuis un événement MegaPari réel.
    Retourne un dict prêt pour insertion dans match_snapshots.
    Fail-closed : si une cote manque, on la laisse None (pas de fabrication).
    """
    # Le flux BetB2B est plat : on regroupe par type via betb2b_adapter si dispo
    try:
        from app.core.betb2b_adapter import adapt_betb2b_event
        adapted = adapt_betb2b_event(raw_event)
        markets = adapted.get("markets", []) if adapted else []
    except Exception:
        markets = raw_event.get("markets", []) or []

    odds = {"odds_1": None, "odds_x": None, "odds_2": None,
            "odds_btts_yes": None, "odds_btts_no": None,
            "odds_over": None, "odds_under": None, "ou_line": 2.5,
            "margin_percent": None}

    for m in markets:
        mt = m.get("market_type")
        sels = m.get("selections", []) or []
        # Récupère les odds internes si présents
        internal = m.get("_odds_internal") or []
        # map selection -> odds
        sel_odds = {}
        for i, s in enumerate(sels):
            o = internal[i] if i < len(internal) else s.get("odds")
            sel_odds[s.get("selection_id") or s.get("name")] = o
            sel_odds[s.get("tags", [""])[0] if s.get("tags") else ""] = o

        if mt == "1X2" and len(sels) >= 3:
            # selections order: home, draw, away
            for s in sels:
                tags = [t.upper() for t in (s.get("tags") or [])]
                o = sel_odds.get(s.get("selection_id"))
                if "HOME" in tags:
                    odds["odds_1"] = o
                elif "DRAW" in tags:
                    odds["odds_x"] = o
                elif "AWAY" in tags:
                    odds["odds_2"] = o
        elif mt == "BTTS" and len(sels) >= 2:
            for s in sels:
                tags = [t.upper() for t in (s.get("tags") or [])]
                o = sel_odds.get(s.get("selection_id"))
                if "YES" in tags:
                    odds["odds_btts_yes"] = o
                elif "NO" in tags:
                    odds["odds_btts_no"] = o
        elif mt == "OVER_UNDER" and len(sels) >= 2:
            line = m.get("line")
            if line is not None:
                odds["ou_line"] = float(line)
            for s in sels:
                tags = [t.upper() for t in (s.get("tags") or [])]
                o = sel_odds.get(s.get("selection_id"))
                if "OVER" in tags:
                    odds["odds_over"] = o
                elif "UNDER" in tags:
                    odds["odds_under"] = o
        if m.get("margin_percent") is not None:
            odds["margin_percent"] = m.get("margin_percent")

    return odds


def build_snapshot_record(raw_event: Dict[str, Any]) -> Dict[str, Any]:
    """Construit un enregistrement complet pour match_snapshots (pré-match)."""
    meta = extract_event_meta(raw_event)
    odds = snapshot_prematch_odds(raw_event)
    return {**meta, **odds, "snapshot_at": datetime.now(timezone.utc).isoformat()}


def archive_result(event_id: str, final_home: int, final_away: int,
                  odds_over: Optional[float] = None, ou_line: float = 2.5) -> Dict[str, Any]:
    """Construit le payload de résultat final pour mise à jour post-match."""
    if final_home > final_away:
        result_1x2 = "1"
    elif final_home < final_away:
        result_1x2 = "2"
    else:
        result_1x2 = "X"
    btts = final_home > 0 and final_away > 0
    total = final_home + final_away
    over = total > ou_line
    return {
        "event_id": event_id,
        "final_score_home": final_home,
        "final_score_away": final_away,
        "result_1x2": result_1x2,
        "btts_result": btts,
        "over_result": over,
        "settled_at": datetime.now(timezone.utc).isoformat(),
    }
