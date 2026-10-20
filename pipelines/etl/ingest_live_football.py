"""
ETL Live Football API → Postgres + feature store.
- Respect time split as-of (pas de fuite)
- Cotes réelles jamais stockées long terme (discard après marge)
"""
import os, sys, datetime, requests
# Tente client réel avec rotation 3 clés, sinon fallback mock (sans source gratuite externe)
try:
    sys.path.append(os.path.join(os.path.dirname(__file__), "../../apps/ml-python"))
    from app.utils.live_football_client import client as lf_client
    HAS_REAL_CLIENT = bool(os.getenv("LIVE_FOOTBALL_API_KEY"))
except Exception:
    HAS_REAL_CLIENT = False
    lf_client = None

LEAGUES = ["Premier League","La Liga","Serie A","Bundesliga","Ligue 1","Eredivisie"]

def fetch_fixtures(league="Premier League", season=2025):
    if HAS_REAL_CLIENT and lf_client:
        try:
            # Appel réel — demande validation si délicat (quota)
            fixtures = lf_client.get_fixtures(league=league, season=season, date=datetime.datetime.utcnow().strftime("%Y-%m-%d"))
            print(f"[ETL REAL] {league}: {len(fixtures)} fixtures via Live Football API")
            return fixtures
        except Exception as e:
            print(f"[ETL REAL] {league} failed: {e} → fallback mock (fail-closed, pas d'invention)")
            # fail-closed: on ne génère pas de fausses données pour training
            return []
    # Mode mock uniquement si clés absentes (dev local sans secrets)
    print(f"[ETL MOCK] {league}: pas de LIVE_FOOTBALL_API_KEY → 1 fixture mock (dev only)")
    return [
        {"id":"evt_1","home":"Arsenal","away":"Man City","league":league,"date":datetime.datetime.utcnow().isoformat(), "stats":{"xG_home":1.4,"xG_away":1.1}},
    ]

def ingest():
    for league in LEAGUES:
        fixtures = fetch_fixtures(league)
        print(f"[ETL] {league}: {len(fixtures)} fixtures")
        # TODO: POST to /events/ingest + save to Postgres
        # Ne pas stocker cotes réelles → discard après calcul marge
        if HAS_REAL_CLIENT and fixtures:
            # Exemple: pousser vers API
            # requests.post("http://api-node:3000/api/v1/events/ingest", json={"provider":"LiveFootball","raw_events":fixtures})
            pass

if __name__ == "__main__":
    ingest()
