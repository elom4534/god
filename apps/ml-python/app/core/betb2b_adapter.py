"""
Adaptateur BetB2B (1xBet / Méga Pari) — payload RÉEL → schéma interne stable.

=============================================================================
Source de vérité
=============================================================================
Documentation officielle « Marketing API » (BetB2B / docs-marketing-sport.com)
  - LoadSingle v2 : GET /datafeed/prematch/api/v2/sportevents
        params : Ref, Lng, SportIds, SchemeOfGettingOddsOperations
        réponse: {count, items:[ sportEvent ]}
  - LoadList v1   : GET /datafeed/loadlist/prematch/api/v1/GetGameIds
                    GET /datafeed/loadlist/prematch/api/v1/GetDetailsGame
                    GET /datafeed/loadlist/prematch/api/v1/GetMarketsGame

=============================================================================
Point critique : le flux BetB2B ne renvoie JAMAIS de marchés groupés
=============================================================================
Chaque item de `oddsLocalization` (LoadSingle) ou de `items` (GetMarketsGame)
est une SÉLECTION, pas un marché :

    {
      "type": 9,                  # id du type de marché (taxonomie officielle)
      "parameter": 3.5,           # la ligne (handicap / total)
      "oddsMarket": 1.825,        # la cote décimale
      "playerId": 0,
      "playerName": "",
      "isBlocked": false,
      "display": "Total (3.5) Over",
      "isCenter": true,
      "oddsMarketView": { "2": "-121", "3": "1.827" }
    }

Un marché 1X2 est donc décrit par TROIS items (type 1, 2, 3) ; un marché
Total par DEUX items (type 9 = Over, type 10 = Under) ; un marché Handicap par
DEUX items (type 7 = côté 1, type 8 = côté 2, lignes opposées).

C'est ce regroupement qui manque au scaffold d'origine : sans lui, chaque
sélection est traitée comme un marché à une seule option → 100 % des marchés
réels sont rejetés (SINGLE_SELECTION_NO_PAIR).

=============================================================================
Taxonomie officielle (page « Market Filters » de la documentation)
=============================================================================
Prematch (tous sports)     1=1  2=X  3=2  4=1X  5=12  6=2X
                           7=Handicap 1  8=Handicap 2  9=Total Over  10=Total Under
Live (tous sports)         + 2466/2467/2468 (par quart)  3653/3654/3655 (temps réglementaire)
Basketball                 + 401/402
Cricket                    + 3014..3021
Tennis                     + 50/51/1761/1762/1794/1795

Les familles exotiques (quart, cricket, tennis, basket) ne sont PAS dans la
taxonomie interne → classées REJECT → fail-closed.
"""
from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Tuple
from datetime import datetime, timezone

__all__ = [
    "MARKET_TYPE_SPEC",
    "adapt_betb2b_event",
    "group_selections_into_markets",
    "extract_flat_selections",
    "extract_event_fields",
]

# ---------------------------------------------------------------------------
# Taxonomie des types BetB2B → familles internes
# ---------------------------------------------------------------------------
# family   : famille de marché interne (alignée sur app/core/taxonomy.py)
# group    : sous-groupe dans la famille (sépare 1X2 "main" du "temps
#            réglementaire" live qui portent les mêmes types)
# label    : libellé canonique de la sélection
# tags     : tags métier (HOME / DRAW / AWAY / OVER / UNDER …)
MARKET_TYPE_SPEC: Dict[int, Dict[str, Any]] = {
    # --- Football prematch -------------------------------------------------
    1: {"family": "1X2", "group": "main", "label": "1", "tags": ["HOME"], "slot": "home"},
    2: {"family": "1X2", "group": "main", "label": "X", "tags": ["DRAW"], "slot": "draw"},
    3: {"family": "1X2", "group": "main", "label": "2", "tags": ["AWAY"], "slot": "away"},
    4: {"family": "DOUBLE_CHANCE", "group": "main", "label": "1X", "tags": ["HOME", "DRAW"], "slot": "dc_1x"},
    5: {"family": "DOUBLE_CHANCE", "group": "main", "label": "12", "tags": ["HOME", "AWAY"], "slot": "dc_12"},
    6: {"family": "DOUBLE_CHANCE", "group": "main", "label": "2X", "tags": ["DRAW", "AWAY"], "slot": "dc_2x"},
    7: {"family": "HANDICAP", "group": "main", "label": "Handicap 1", "tags": ["HOME", "HANDICAP"], "slot": "hc_home"},
    8: {"family": "HANDICAP", "group": "main", "label": "Handicap 2", "tags": ["AWAY", "HANDICAP"], "slot": "hc_away"},
    9: {"family": "OVER_UNDER", "group": "main", "label": "Total Over", "tags": ["OVER"], "slot": "ou_over"},
    10: {"family": "OVER_UNDER", "group": "main", "label": "Total Under", "tags": ["UNDER"], "slot": "ou_under"},
    # --- Live ---------------------------------------------------------------
    2466: {"family": "QUARTER_RESULT", "group": "quarters", "label": "W1 By Quarters", "tags": ["HOME"], "slot": "q_home"},
    2467: {"family": "QUARTER_RESULT", "group": "quarters", "label": "W2 By Quarters", "tags": ["AWAY"], "slot": "q_away"},
    2468: {"family": "QUARTER_RESULT", "group": "quarters", "label": "X By Quarters", "tags": ["DRAW"], "slot": "q_draw"},
    3653: {"family": "1X2", "group": "regular_time", "label": "1", "tags": ["HOME"], "slot": "rt_home"},
    3654: {"family": "1X2", "group": "regular_time", "label": "X", "tags": ["DRAW"], "slot": "rt_draw"},
    3655: {"family": "1X2", "group": "regular_time", "label": "2", "tags": ["AWAY"], "slot": "rt_away"},
    # --- Basketball ---------------------------------------------------------
    401: {"family": "TEAM_WINS", "group": "main", "label": "First Team Wins", "tags": ["HOME"], "slot": "bw_home"},
    402: {"family": "TEAM_WINS", "group": "main", "label": "Second Team Wins", "tags": ["AWAY"], "slot": "bw_away"},
    # --- Cricket ------------------------------------------------------------
    3014: {"family": "WIDES_OU", "group": "main", "label": "Total Wides Over", "tags": ["OVER"], "slot": "cr_wides_o"},
    3015: {"family": "WIDES_OU", "group": "main", "label": "Total Wides Under", "tags": ["UNDER"], "slot": "cr_wides_u"},
    3016: {"family": "RUN_OUTS_OU", "group": "main", "label": "Total Run-Outs Over", "tags": ["OVER"], "slot": "cr_ro_o"},
    3017: {"family": "RUN_OUTS_OU", "group": "main", "label": "Total Run-Outs Under", "tags": ["UNDER"], "slot": "cr_ro_u"},
    3018: {"family": "FOURS_OU", "group": "main", "label": "Total Fours Over", "tags": ["OVER"], "slot": "cr_fours_o"},
    3019: {"family": "FOURS_OU", "group": "main", "label": "Total Fours Under", "tags": ["UNDER"], "slot": "cr_fours_u"},
    3020: {"family": "SIXES_OU", "group": "main", "label": "Total Sixes Over", "tags": ["OVER"], "slot": "cr_sixes_o"},
    3021: {"family": "SIXES_OU", "group": "main", "label": "Total Sixes Under", "tags": ["UNDER"], "slot": "cr_sixes_u"},
    # --- Tennis -------------------------------------------------------------
    50: {"family": "GAME_WIN", "group": "main", "label": "Game Win 1", "tags": ["HOME"], "slot": "tn_g1"},
    51: {"family": "GAME_WIN", "group": "main", "label": "Game Win 2", "tags": ["AWAY"], "slot": "tn_g2"},
    1794: {"family": "PLAYER_POINT", "group": "main", "label": "Player 1 To Win Point", "tags": ["HOME"], "slot": "tn_p1"},
    1795: {"family": "PLAYER_POINT", "group": "main", "label": "Player 2 To Win Point", "tags": ["AWAY"], "slot": "tn_p2"},
    1761: {"family": "SET_POINT", "group": "main", "label": "1 To Win Point In Set", "tags": ["HOME"], "slot": "tn_s1"},
    1762: {"family": "SET_POINT", "group": "main", "label": "2 To Win Point In Set", "tags": ["AWAY"], "slot": "tn_s2"},
}

# Familles porteuses d'une ligne (parameter) — la ligne est symétrique pour
# un handicap (type 7 = -1.5 / type 8 = +1.5) → on groupe sur |parameter|.
_LINE_FAMILIES = {"HANDICAP", "OVER_UNDER"}

# Libellé de marché canonique (le normalizer s'appuie dessus en dernier
# recours ; l'adaptateur force en plus market_type de façon déterministe).
_FAMILY_NAME = {
    "1X2": "1X2",
    "DOUBLE_CHANCE": "Double Chance",
    "HANDICAP": "Handicap",
    "OVER_UNDER": "Total Over/Under",
}

_LANG_KEYS = ("en", "fr", "de", "es", "it", "ru", "pt", "nl")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _localized(value: Any) -> Optional[str]:
    """BetB2B renvoie les libellés sous forme {lang: texte} (singulier ou pluriel)."""
    if value is None:
        return None
    if isinstance(value, str):
        return value.strip() or None
    if isinstance(value, dict):
        for key in _LANG_KEYS:
            v = value.get(key)
            if isinstance(v, str) and v.strip():
                return v.strip()
        for v in value.values():
            if isinstance(v, str) and v.strip():
                return v.strip()
        return None
    return None


def _to_float(value: Any) -> Optional[float]:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        try:
            f = float(value)
        except (TypeError, ValueError):
            return None
        return None if f != f else f  # NaN check
    if isinstance(value, str):
        s = value.strip().replace(",", ".")
        if not s:
            return None
        try:
            return float(s)
        except ValueError:
            return None
    return None


def _epoch_to_iso(value: Any) -> Optional[str]:
    ts = _to_float(value)
    if ts is None or ts <= 0:
        return None
    try:
        return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()
    except (OverflowError, OSError, ValueError):
        return None


# ---------------------------------------------------------------------------
# Extraction des sélections (liste PLATE) depuis les différents conteneurs
# ---------------------------------------------------------------------------
def extract_flat_selections(raw_event: Dict[str, Any]) -> List[Dict[str, Any]]:
    """
    Retrouve la liste plate de sélections BetB2B quel que soit le conteneur.

    Conteneurs gérés :
      - LoadSingle v2 : raw["oddsLocalization"]
      - LoadList GetMarketsGame : raw["selections"] ou raw["items"]
      - Worker Node : raw["selections"] + raw["details"]
    """
    if not isinstance(raw_event, dict):
        return []

    # 1) LoadSingle v2
    odds_loc = raw_event.get("oddsLocalization")
    if isinstance(odds_loc, list):
        return [s for s in odds_loc if isinstance(s, dict)]

    # 2) Sélections explicites (worker Node / payload de l'API d'ingest)
    sels = raw_event.get("selections")
    if isinstance(sels, list):
        return [s for s in sels if isinstance(s, dict)]

    # 3) Réponse GetMarketsGame ({count, items:[sélections]})
    items = raw_event.get("items")
    if isinstance(items, list) and items and isinstance(items[0], dict):
        if "oddsMarket" in items[0] or "type" in items[0]:
            return [s for s in items if isinstance(s, dict)]

    # 4) markets déjà groupés (compatibilité tests / autres providers)
    mkts = raw_event.get("markets")
    if isinstance(mkts, list):
        for m in mkts:
            if isinstance(m, dict) and isinstance(m.get("selections"), list):
                return []  # déjà groupé → traitement handled par is_already_grouped()

    return []


def is_already_grouped(raw_event: Dict[str, Any]) -> bool:
    """Vrai si le payload contient déjà des marchés groupés (selections imbriquées)."""
    mkts = raw_event.get("markets")
    return bool(
        isinstance(mkts, list)
        and mkts
        and isinstance(mkts[0], dict)
        and isinstance(mkts[0].get("selections"), list)
    )


# ---------------------------------------------------------------------------
# Regroupement des sélections en marchés
# ---------------------------------------------------------------------------
def group_selections_into_markets(
    selections: Iterable[Dict[str, Any]],
    event_id: str,
) -> List[Dict[str, Any]]:
    """
    Regroupe la liste PLATE de sélections BetB2B en marchés internes.

    Règles :
      - la clé de regroupement est (famille, groupe, ligne) ;
      - la ligne d'un handicap est symétrique (type 7 = -1.5, type 8 = +1.5)
        → on groupe sur la valeur absolue ;
      - une sélection `isBlocked` est conservée mais le marché est marqué
        bloqué (rejet fail-closed côté Margin Guard) ;
      - les types inconnus de la taxonomie sont ignorés (fail-closed).
    """
    groups: Dict[Tuple[str, str, Optional[float]], Dict[str, Any]] = {}

    for sel in selections:
        if not isinstance(sel, dict):
            continue
        type_id = sel.get("type")
        try:
            type_id = int(type_id)
        except (TypeError, ValueError):
            continue
        spec = MARKET_TYPE_SPEC.get(type_id)
        if spec is None:
            continue  # type hors taxonomie → ignoré

        family = spec["family"]
        group = spec["group"]
        parameter = _to_float(sel.get("parameter"))
        line: Optional[float] = None
        if family in _LINE_FAMILIES and parameter is not None:
            line = abs(parameter)

        key = (family, group, line)
        bucket = groups.get(key)
        if bucket is None:
            market_id = f"{event_id}_{family}_{group}"
            if line is not None:
                market_id = f"{market_id}_{line:g}"
            bucket = {
                "market_id": market_id,
                "market_type": family,
                "name": _FAMILY_NAME.get(family, family),
                "period": "FT",
                "line": line,
                "selections": [],
                "_betb2b_types": [],
                "_betb2b_group": group,
                "_blocked": False,
            }
            groups[key] = bucket

        odds = _to_float(sel.get("oddsMarket"))
        if odds is None:
            odds = _to_float((sel.get("oddsMarketView") or {}).get("3") if isinstance(sel.get("oddsMarketView"), dict) else None)
        label = spec["label"]
        if family == "HANDICAP":
            label = f"{label} ({line:g})" if line is not None else label
        elif family == "OVER_UNDER":
            label = f"Total ({line:g}) {label.split(' ')[-1]}" if line is not None else label

        selection_id = f"{bucket['market_id']}_{spec['slot']}"
        bucket["selections"].append({
            "selection_id": selection_id,
            "name": label,
            "odds": odds,
            "odds_internal": odds,
            "tags": list(spec["tags"]),
            "_betb2b_type": type_id,
            # Paramètre BRUT signé de BetB2B (ex: -1.5 / +1.5 en handicap) :
            # indispensable pour reconstruire le lien coupon (sharecoupon.parameter).
            "_betb2b_parameter": parameter,
            "_is_center": bool(sel.get("isCenter")),
        })
        bucket["_betb2b_types"].append(type_id)
        if sel.get("isBlocked"):
            bucket["_blocked"] = True

    markets: List[Dict[str, Any]] = []
    for bucket in groups.values():
        sels = [s for s in bucket["selections"] if s.get("odds") is not None]
        if len(sels) < 2:
            # Marché incomplet (une seule issue disponible) → laissé de côté :
            # le Margin Guard le re rejetterait de toute façon (INCOMPLETE_MARKET).
            continue
        bucket["selections"] = sels
        bucket["is_blocked"] = bucket.pop("_blocked")
        bucket.pop("_betb2b_types", None)
        for s in bucket["selections"]:
            s.pop("_is_center", None)
        markets.append(bucket)

    # Ordre stable : 1X2 d'abord, puis Double Chance, Handicap, Totaux, le reste.
    order = {"1X2": 0, "DOUBLE_CHANCE": 1, "HANDICAP": 2, "OVER_UNDER": 3}
    markets.sort(key=lambda m: (order.get(m["market_type"], 9), m["market_id"]))

    # Contrôle de cohérence du Double Chance : on rattache les cotes 1X2 du
    # même match au marché DC (le Margin Guard compare les probabilités
    # inversées du DC aux probabilités observées en 1X2).
    one_x_two = next(
        (m for m in markets if m["market_type"] == "1X2" and m.get("_betb2b_group") == "main"),
        None,
    )
    if one_x_two:
        odds_1x2 = [s["odds"] for s in one_x_two["selections"]]
        if len(odds_1x2) == 3:
            for m in markets:
                if m["market_type"] == "DOUBLE_CHANCE":
                    m["_odds_1x2_ref"] = odds_1x2
    return markets


# ---------------------------------------------------------------------------
# Extraction des métadonnées d'un événement
# ---------------------------------------------------------------------------
def extract_event_fields(raw_event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Extrait event_id / home / away / league / start_time / period depuis :
      - un item LoadSingle v2 (champs *Localization au singulier)
      - une réponse GetDetailsGame (champs *Localizations au pluriel)
      - un payload worker {id, details:{...}, selections:[...]}
    """
    sources: List[Dict[str, Any]] = []
    if isinstance(raw_event, dict):
        sources.append(raw_event)
        for key in ("details", "event", "sport_event", "raw"):
            sub = raw_event.get(key)
            if isinstance(sub, dict):
                sources.append(sub)

    def pick(*names: str) -> Any:
        for src in sources:
            for n in names:
                if n in src and src[n] not in (None, ""):
                    return src[n]
        return None

    event_id = pick("sportEventId", "gameId", "id", "event_id", "eventId")
    home = _localized(pick("opponent1NameLocalization", "opponent1NameLocalizations",
                           "homeTeam", "home", "team1", "participant1"))
    away = _localized(pick("opponent2NameLocalization", "opponent2NameLocalizations",
                           "awayTeam", "away", "team2", "participant2"))
    league = _localized(pick("tournamentNameLocalization", "tournamentNameLocalizations",
                              "league", "competition", "championship", "tournamentName"))
    start_iso = pick("startDate", "startTime", "start_time", "kickoff", "date")
    start_time = _epoch_to_iso(start_iso)
    if start_time is None and isinstance(start_iso, str):
        try:
            dt = datetime.fromisoformat(start_iso.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            start_time = dt.isoformat()
        except ValueError:
            start_time = None
    period = pick("period", "periodName")
    sport_id = pick("sportId")

    return {
        "event_id": str(event_id) if event_id is not None else "",
        "home": home,
        "away": away,
        "league": league,
        "start_time": start_time,
        "period": str(period) if period is not None else "FT",
        "sport_id": sport_id,
    }


# ---------------------------------------------------------------------------
# Point d'entrée
# ---------------------------------------------------------------------------
def adapt_betb2b_event(
    raw_event: Dict[str, Any],
    event_id: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    """
    Transforme un événement BetB2B brut en événement interne « raw »
    (compatible app.core.normalizer.normalize_event).

    Retourne None si l'événement n'est pas exploitable (fail-closed).
    """
    if not isinstance(raw_event, dict):
        return None

    fields = extract_event_fields(raw_event)
    resolved_id = str(event_id) if event_id else fields["event_id"]
    if not resolved_id:
        return None

    if is_already_grouped(raw_event):
        markets = raw_event.get("markets") or []
        normalized_markets = []
        for m in markets:
            if not isinstance(m, dict):
                continue
            normalized_markets.append({
                "market_id": str(m.get("market_id") or m.get("id") or f"{resolved_id}_m{len(normalized_markets)}"),
                "market_type": m.get("market_type") or m.get("name") or "UNKNOWN",
                "name": m.get("name") or m.get("title") or m.get("market_type") or "UNKNOWN",
                "period": m.get("period") or "FT",
                "line": _to_float(m.get("line")),
                "selections": m.get("selections") or [],
                "is_blocked": bool(m.get("is_blocked")),
            })
    else:
        flat = extract_flat_selections(raw_event)
        normalized_markets = group_selections_into_markets(flat, resolved_id)

    if not normalized_markets and not fields["home"] and not fields["away"]:
        return None

    return {
        "id": resolved_id,
        "home": fields["home"] or "Home",
        "away": fields["away"] or "Away",
        "league": fields["league"] or "Unknown League",
        "start_time": fields["start_time"] or datetime.now(tz=timezone.utc).isoformat(),
        "period": fields["period"],
        "sport_id": fields["sport_id"],
        "markets": normalized_markets,
    }


def describe_taxonomy() -> str:
    """Documentation de la taxonomie (utilisée par le rapport FR)."""
    lines = ["Type | Famille | Groupe | Label"]
    for type_id in sorted(MARKET_TYPE_SPEC):
        spec = MARKET_TYPE_SPEC[type_id]
        lines.append(f"{type_id} | {spec['family']} | {spec['group']} | {spec['label']}")
    return "\n".join(lines)
