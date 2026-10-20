"""
ETL Virtual Bookmaker → stockage COMPLET (snapshots, cotes, résultats).
Pour apprentissage + drift detection.
"""
import os, sys, datetime, requests

# Client réel MarketingSport si secrets présents
try:
    sys.path.append(os.path.join(os.path.dirname(__file__), "../../apps/api-node"))
    HAS_REAL = bool(os.getenv("XBET_CLIENT_ID") or os.getenv("BOOKMAKER_CLIENT_ID"))
except Exception:
    HAS_REAL = False

BOOKMAKER_BASE = os.getenv("BOOKMAKER_API_BASE", os.getenv("BOOKMAKER_BASE_URL", "https://api.marketing-sport.com"))

def fetch_virtual_events_real():
    """Tentative réelle via Node helper (loadList avec is_virtual=true)."""
    # On passe par l'API Node qui détient le client MarketingSport (évite duplication Python)
    try:
        r = requests.get("http://api-node:3000/api/v1/bookmaker/loadList", params={"provider":"1xBet","is_virtual":1,"sport":"football"}, timeout=10)
        if r.status_code==200:
            return r.json()
    except Exception as e:
        print(f"[ETL VIRTUAL REAL] failed: {e}")
    return None

def fetch_virtual_events():
    real = None
    if HAS_REAL:
        real = fetch_virtual_events_real()
        if real:
            print(f"[ETL VIRTUAL REAL] {len(real)} events via loadList is_virtual=1")
            return real
        print("[ETL VIRTUAL REAL] pas de données réelles → fail-closed (pas d'invention)")
        return []
    # Mock dev only
    print("[ETL VIRTUAL MOCK] pas de XBET_CLIENT_ID → 1 event mock (dev only)")
    return [
        {
            "virtual_event_id": "virt_001",
            "round": 42,
            "home": "Virt Team A",
            "away": "Virt Team B",
            "start_time": datetime.datetime.utcnow().isoformat(),
            "markets": [
                {"id":"m1","name":"1X2","odds":[2.2,3.1,3.4]},
                {"id":"m2","name":"Over 2.5","line":2.5,"selections":[{"name":"Over","odds":1.95},{"name":"Under","odds":1.95}]},
            ],
            "result": {"score":"2-1"},
            "snapshot_ts": datetime.datetime.utcnow().isoformat()
        }
    ]

def ingest_virtual():
    events = fetch_virtual_events()
    print(f"[ETL VIRTUAL] {len(events)} events")
    for e in events:
        vid = e.get('virtual_event_id') or e.get('id') or 'unknown'
        snap = e.get('snapshot_ts') or e.get('start_time') or ''
        mkts = e.get('markets') or e.get('markets_json') or []
        print(f"  - {vid} snapshot {snap} markets={len(mkts)}")
        # TODO: INSERT INTO virtual_history(event_id, snapshot_ts, markets_json, odds_json, result_json) VALUES (...)

if __name__ == "__main__":
    ingest_virtual()
