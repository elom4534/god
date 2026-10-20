"""
Normalizer — transforme payload brut bookmaker (1xBet / Méga Pari) en schéma interne stable.
Gère 300+ marchés, champs manquants, formats hétérogènes.
"""
from typing import List, Dict, Any, Tuple
from datetime import datetime, timezone
import re

# Mapping heuristique noms bruts → market_type normalisé
MARKET_NAME_MAP = {
    "1x2": "1X2",
    "1 x 2": "1X2",
    "match result": "1X2",
    "double chance": "DOUBLE_CHANCE",
    "dc": "DOUBLE_CHANCE",
    "over/under": "OVER_UNDER",
    "total": "OVER_UNDER",
    "goals over/under": "OVER_UNDER",
    "both teams to score": "BTTS",
    "btts": "BTTS",
    "handicap": "HANDICAP",
    "asian handicap": "ASIAN_HANDICAP",
    "corners": "CORNERS_OU",
    "corners over/under": "CORNERS_OU",
    "shots on target": "SHOTS_ON_TARGET_OU",
    "fouls": "FOULS_OU",
}

def normalize_market_type(raw_name: str, raw_id: str = "") -> str:
    if not raw_name:
        raw_name = raw_id
    key = raw_name.strip().lower()
    # exact match
    if key in MARKET_NAME_MAP:
        return MARKET_NAME_MAP[key]
    # fuzzy contains
    for k, v in MARKET_NAME_MAP.items():
        if k in key:
            return v
    # line detection: "Over 2.5", "Under 9.5 Corners"
    if re.search(r"over|under", key):
        if "corner" in key:
            return "CORNERS_OU"
        if "shot" in key:
            return "SHOTS_ON_TARGET_OU"
        if "foul" in key:
            return "FOULS_OU"
        return "OVER_UNDER"
    return "UNKNOWN"

def extract_line(raw_market: Dict[str, Any]) -> float | None:
    # cherche line dans divers champs
    for k in ["line", "total", "handicap", "threshold", "param", "value"]:
        if k in raw_market and raw_market[k] not in (None, ""):
            try:
                return float(str(raw_market[k]).replace(",", "."))
            except:
                pass
    # parse depuis name: "Over 2.5"
    name = raw_market.get("name", "") or raw_market.get("title", "")
    m = re.search(r"(\d+[.,]\d+)", name)
    if m:
        try:
            return float(m.group(1).replace(",", "."))
        except:
            pass
    return None

def normalize_selections(raw_market: Dict[str, Any]) -> List[Dict]:
    selections = []
    # formats possibles: "odds": [2.1,3.2,3.5], "selections": [{name, odds}], "outcomes": [...]
    raw_sels = raw_market.get("selections") or raw_market.get("outcomes") or raw_market.get("odds_table") or []
    if isinstance(raw_market.get("odds"), list) and not raw_sels:
        # odds simple array, on génère noms par défaut
        mt = normalize_market_type(raw_market.get("name",""), raw_market.get("id",""))
        defaults = {
            "1X2": ["1","X","2"],
            "DOUBLE_CHANCE": ["1X","X2","12"],
            "BTTS": ["Yes","No"],
            "OVER_UNDER": ["Over","Under"],
            "CORNERS_OU": ["Over","Under"],
        }
        names = defaults.get(mt, [f"sel_{i}" for i in range(len(raw_market["odds"]))])
        for i, odd in enumerate(raw_market["odds"]):
            selections.append({
                "selection_id": f"{raw_market.get('id','mkt')}_sel_{i}",
                "name": names[i] if i < len(names) else f"sel_{i}",
                "odds": odd,
                "odds_internal": odd,
                "tags": [names[i].upper()] if i < len(names) else []
            })
        return selections

    for idx, s in enumerate(raw_sels):
        if isinstance(s, dict):
            sel_id = s.get("id") or s.get("selection_id") or f"{raw_market.get('id','mkt')}_sel_{idx}"
            name = s.get("name") or s.get("title") or s.get("outcome") or f"sel_{idx}"
            odds = s.get("odds") or s.get("price") or s.get("coef") or s.get("value")
            tags = s.get("tags") or []
            if isinstance(tags, str):
                tags = [tags]
            # auto tags
            if not tags:
                ln = name.lower()
                if ln in ["1","home"]: tags=["HOME"]
                elif ln in ["x","draw"]: tags=["DRAW"]
                elif ln in ["2","away"]: tags=["AWAY"]
                elif "over" in ln: tags=["OVER"]
                elif "under" in ln: tags=["UNDER"]
                elif "yes" in ln: tags=["YES"]
                elif "no" in ln: tags=["NO"]
            selections.append({
                "selection_id": str(sel_id),
                "name": str(name),
                "odds": odds,
                "odds_internal": odds,
                "tags": [t.upper() for t in tags]
            })
        elif isinstance(s, (int, float, str)):
            selections.append({
                "selection_id": f"{raw_market.get('id','mkt')}_sel_{idx}",
                "name": f"sel_{idx}",
                "odds": s,
                "odds_internal": s,
                "tags": []
            })
    return selections

def normalize_event(raw: Dict[str, Any], provider: str = "1xBet", is_virtual: bool = False) -> Tuple[Dict | None, str | None]:
    try:
        # event_id
        event_id = str(raw.get("id") or raw.get("event_id") or raw.get("fixture_id") or raw.get("match_id") or "")
        if not event_id:
            return None, "MISSING_EVENT_ID"
        # teams (éviter bug priorité opérateur ternaire)
        home = raw.get("home") or raw.get("home_team") or raw.get("team1")
        if not home and isinstance(raw.get("teams"), dict):
            home = raw.get("teams", {}).get("home")
        away = raw.get("away") or raw.get("away_team") or raw.get("team2")
        if not away and isinstance(raw.get("teams"), dict):
            away = raw.get("teams", {}).get("away")
        if not home or not away:
            # try split name
            name = raw.get("name") or raw.get("title") or ""
            if " - " in name:
                parts = name.split(" - ")
                home, away = parts[0].strip(), parts[1].strip()
            elif " vs " in name:
                parts = name.split(" vs ")
                home, away = parts[0].strip(), parts[1].strip()
            else:
                return None, "MISSING_TEAMS"
        # league
        league = raw.get("league") or raw.get("competition") or raw.get("tournament") or raw.get("championship") or "Unknown League"
        if isinstance(league, dict):
            league = league.get("name") or league.get("title") or "Unknown League"
        # start_time
        st = raw.get("start_time") or raw.get("kickoff") or raw.get("date") or raw.get("time") or raw.get("start_date")
        if isinstance(st, (int, float)):
            # timestamp
            try:
                start_time = datetime.fromtimestamp(float(st), tz=timezone.utc)
            except:
                start_time = datetime.now(tz=timezone.utc)
        elif isinstance(st, str):
            try:
                # try ISO
                start_time = datetime.fromisoformat(st.replace("Z", "+00:00"))
                if start_time.tzinfo is None:
                    start_time = start_time.replace(tzinfo=timezone.utc)
            except:
                try:
                    start_time = datetime.strptime(st, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
                except:
                    start_time = datetime.now(tz=timezone.utc)
        elif isinstance(st, datetime):
            start_time = st
            if start_time.tzinfo is None:
                start_time = start_time.replace(tzinfo=timezone.utc)
        else:
            start_time = datetime.now(tz=timezone.utc)

        # markets
        raw_markets = raw.get("markets") or raw.get("odds") or raw.get("bookmaker_markets") or []
        if isinstance(raw_markets, dict):
            raw_markets = [raw_markets]
        markets = []
        for rm in raw_markets:
            if not isinstance(rm, dict):
                continue
            mtype = normalize_market_type(rm.get("name","") or rm.get("title",""), rm.get("id",""))
            market = {
                "market_id": str(rm.get("id") or rm.get("market_id") or f"{event_id}_{mtype}_{len(markets)}"),
                "market_type": mtype,
                "name": rm.get("name") or rm.get("title") or mtype,
                "period": rm.get("period") or rm.get("time") or "FT",
                "line": extract_line(rm),
                "selections": normalize_selections(rm),
                "_raw": rm  # keep for debugging, not persisted
            }
            # reject empty selections immediately
            if not market["selections"]:
                continue
            markets.append(market)

        normalized = {
            "event_id": event_id,
            "sport": "football",
            "league": str(league),
            "start_time": start_time.isoformat(),
            "home": str(home),
            "away": str(away),
            "is_virtual": bool(is_virtual or raw.get("is_virtual") or raw.get("virtual")),
            "provider": provider,
            "markets": markets
        }
        return normalized, None
    except Exception as e:
        return None, f"NORMALIZER_EXCEPTION:{str(e)}"

def normalize_batch(raw_events: List[Dict], provider: str = "1xBet", is_virtual: bool = False) -> Dict:
    normalized = []
    rejected = []
    for raw in raw_events:
        evt, err = normalize_event(raw, provider, is_virtual)
        if evt:
            # remove _raw before returning (internal only)
            for m in evt["markets"]:
                m.pop("_raw", None)
            normalized.append(evt)
        else:
            rejected.append({"raw_id": str(raw.get("id","unknown")), "reason_code": err or "UNKNOWN"})
    return {"normalized": normalized, "rejected": rejected}
