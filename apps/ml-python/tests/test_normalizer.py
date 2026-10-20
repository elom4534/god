from app.core.normalizer import normalize_batch

def test_normalizer_basic():
    raw = [
        {
            "id": "evt_1",
            "home": "Arsenal",
            "away": "Chelsea",
            "league": "Premier League",
            "start_time": "2026-10-20T19:45:00Z",
            "markets": [
                {"id":"m1","name":"1X2","odds":[2.10,3.20,3.60]},
                {"id":"m2","name":"Over/Under 2.5","line":2.5,"selections":[{"name":"Over","odds":"1,95"},{"name":"Under","odds":"1,85"}]}
            ]
        },
        {
            "id": "bad_evt",
            "markets": []  # missing teams → rejected
        }
    ]
    res = normalize_batch(raw, provider="1xBet")
    assert len(res["normalized"])==1
    assert res["normalized"][0]["event_id"]=="evt_1"
    assert len(res["normalized"][0]["markets"])==2
    assert res["normalized"][0]["markets"][0]["market_type"]=="1X2"
    assert len(res["rejected"])==1
    print("Normalizer tests passed")

if __name__=="__main__":
    test_normalizer_basic()
