from app.core.selection_engine import select_best_per_event

def test_selection_one_per_match():
    events = [
        {
            "event_id": "evt1",
            "sport": "football",
            "league": "Premier League",
            "start_time": "2026-10-20T19:45:00Z",
            "home": "Arsenal",
            "away": "Chelsea",
            "is_virtual": False,
            "markets": [
                {
                    "market_id": "m1",
                    "market_type": "1X2",
                    "name": "1X2",
                    "period": "FT",
                    "line": None,
                    "selections": [
                        {"selection_id":"s1","name":"1","odds":2.0},
                        {"selection_id":"s2","name":"X","odds":3.3},
                        {"selection_id":"s3","name":"2","odds":3.8},
                    ]
                },
                {
                    "market_id": "m2",
                    "market_type": "OVER_UNDER",
                    "name": "Over/Under 2.5",
                    "period": "FT",
                    "line": 2.5,
                    "selections": [
                        {"selection_id":"s_over","name":"Over","odds":1.95},
                        {"selection_id":"s_under","name":"Under","odds":1.95},
                    ]
                }
            ]
        },
        {
            "event_id": "evt2",
            "sport": "football",
            "league": "La Liga",
            "start_time": "2026-10-20T20:00:00Z",
            "home": "Barca",
            "away": "Real",
            "is_virtual": True,
            "markets": [
                {
                    "market_id": "m3",
                    "market_type": "BTTS",
                    "name": "BTTS",
                    "period": "FT",
                    "line": None,
                    "selections": [
                        {"selection_id":"s_yes","name":"Yes","odds":1.92},
                        {"selection_id":"s_no","name":"No","odds":1.92},
                    ]
                }
            ]
        }
    ]
    res = select_best_per_event(events, mode="mix")
    # 1 pick per event max
    assert len(res["picks"]) <= len(events)
    # each pick has required fields, no duplicate event
    eids = [p["event_id"] for p in res["picks"]]
    assert len(eids) == len(set(eids))
    for p in res["picks"]:
        assert "p_lower" in p
        assert "confidence" in p
        assert p["score"] >= 0
    print(f"Picks: {res['picks']}")
    print("Selection engine tests passed")

if __name__=="__main__":
    test_selection_one_per_match()
