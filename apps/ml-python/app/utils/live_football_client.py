"""
Client réel Live Football API — https://live-football-api.com
Docs: https://www.live-football-api.com/docs
3 clés avec rotation (1 épuisée, 2 actives à 499 crédits). Ne jamais utiliser source gratuite.
"""
import os
import time
import requests
from typing import List, Dict, Optional

BASE_URL = os.getenv("LIVE_FOOTBALL_BASE_URL", "https://live-football-api.com")
KEYS = [
    os.getenv("LIVE_FOOTBALL_API_KEY", ""),
    os.getenv("LIVE_FOOTBALL_API_KEY_2", ""),
    os.getenv("LIVE_FOOTBALL_API_KEY_3", ""),
]
KEYS = [k for k in KEYS if k]

class LiveFootballClient:
    def __init__(self, base_url: str = BASE_URL, timeout: int = 10):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._key_idx = 0

    def _key(self) -> str:
        if not KEYS:
            raise RuntimeError("LIVE_FOOTBALL_API_KEY manquant — voir INTEGRATION-REELLE.md")
        k = KEYS[self._key_idx % len(KEYS)]
        self._key_idx += 1
        return k

    def _get(self, path: str, params: dict = None, retries: int = 4) -> dict:
        last = None
        for attempt in range(retries):
            key = self._key()
            p = {"api_key": key, **(params or {})}
            try:
                r = requests.get(f"{self.base_url}{path}", params=p, timeout=self.timeout)
                data = r.json()
                # API returns success:false quand clé invalide/quota épuisé → rotation
                if isinstance(data, dict) and data.get("success") is False:
                    last = data.get("message", "Access denied")
                    # 499 crédits restants → on a de la marge, on rotate juste
                    time.sleep(0.3)
                    continue
                r.raise_for_status()
                return data
            except Exception as e:
                last = str(e)
                time.sleep(0.3)
                continue
        raise RuntimeError(f"LiveFootball API indisponible après {retries} tentatives: {last}")

    # --- Endpoints documentés ---
    def get_matches(self, date: str = None, lang: str = "en") -> List[Dict]:
        """GET /api/v1/matches?api_key=KEY&date=YYYY-MM-DD&lang=en"""
        params = {"lang": lang}
        if date: params["date"] = date
        data = self._get("/api/v1/matches", params=params)
        # Réponse: {success:true, data:{matches:[...]}, credits_remaining}
        if isinstance(data, dict) and "data" in data:
            inner = data["data"]
            if isinstance(inner, dict) and "matches" in inner:
                return inner["matches"]
            if isinstance(inner, list):
                return inner
        return data.get("matches", []) if isinstance(data, dict) else []

    def get_match(self, match_id: str, lang: str = "en") -> Dict:
        """GET /api/v1/match?api_key=KEY&match_id=ID"""
        data = self._get("/api/v1/match", params={"match_id": match_id, "lang": lang})
        return data.get("data", data)

    def get_leagues(self, lang: str = "en") -> List[Dict]:
        data = self._get("/api/v1/leagues", params={"lang": lang})
        return data.get("data", {}).get("leagues", []) if isinstance(data, dict) else []

    def get_teams(self, league_id: str, lang: str = "en") -> List[Dict]:
        data = self._get("/api/v1/teams", params={"league_id": league_id, "lang": lang})
        return data.get("data", {}).get("teams", []) if isinstance(data, dict) else []

    # Helpers legacy pour compat pipelines (mapping vers nouveau)
    def get_fixtures(self, league: str = None, season: int = None, date: str = None, **kwargs) -> List[Dict]:
        # On mappe league name -> league_id via get_leagues si besoin, sinon on filtre côté client
        matches = self.get_matches(date=date or time.strftime("%Y-%m-%d"))
        if league:
            # filtre simple par nom (insensible casse)
            matches = [m for m in matches if league.lower() in m.get("league", {}).get("name", "").lower()]
        return matches

    def get_fixture_statistics(self, fixture_id: str) -> Dict:
        return self.get_match(match_id=fixture_id)

    def get_results(self, from_date: str = None, to_date: str = None, **kwargs) -> List[Dict]:
        # L'API n'a pas de range, on itère jour par jour (à wrapper en pipeline)
        return self.get_matches(date=from_date)

client = LiveFootballClient()
