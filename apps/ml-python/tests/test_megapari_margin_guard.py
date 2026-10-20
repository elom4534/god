"""
Tests production — MegaPari Margin Guard + Cache
"""
import asyncio
import sys
sys.path.append("..")
from app.services.megapari_margin_guard import parse_odds, compute_margin_exclusive, process_and_cache_event

def test_parse_odds():
    assert parse_odds("1,85") == 1.85
    assert parse_odds("1.95") == 1.95
    assert parse_odds("") is None
    assert parse_odds(None) is None
    assert parse_odds(0) is None
    assert parse_odds(1.0) is None
    assert parse_odds(float("inf")) is None
    assert parse_odds(float("nan")) is None
    print("✅ parse_odds OK")

def test_margin():
    # [1.95, 1.95] → 2.56% validé
    assert abs(compute_margin_exclusive([1.95, 1.95]) - 2.56) < 0.05
    # [2.0, 3.0, 4.0] → 8.33% rejet
    assert compute_margin_exclusive([2.0, 3.0, 4.0]) > 5.0
    # invalide → None
    assert compute_margin_exclusive([None, 2.0]) is None
    print("✅ margin OK")

async def test_process_event():
    raw = {
        "id": 763041519,
        "provider": "MEGAPARI",
        "markets": [
            {
                "market_id": "m1",
                "market_type": "OVER_UNDER",
                "line": 2.5,
                "selections": [
                    {"selection_id": "over", "name": "Over", "odds": 1.95, "tags": ["OVER"]},
                    {"selection_id": "under", "name": "Under", "odds": 1.95, "tags": ["UNDER"]},
                ]
            },
            {
                "market_id": "m2",
                "market_type": "1X2",
                "selections": [
                    {"selection_id": "1", "name": "1", "odds": 2.0},
                    {"selection_id": "X", "name": "X", "odds": 3.2},
                    {"selection_id": "2", "name": "2", "odds": 4.0},
                ]
            },
            {
                "market_id": "m3",
                "market_type": "BTTS",
                "selections": [
                    {"selection_id": "yes", "name": "Yes", "odds": ""},  # invalide
                    {"selection_id": "no", "name": "No", "odds": 1.9},
                ]
            }
        ]
    }
    res = await process_and_cache_event(raw)
    print(f"validated: {len(res['validated_markets'])} rejected: {len(res['rejected'])}")
    assert len(res["validated_markets"]) == 2  # m1: 2 sélections → 1 marché validé avec 2 sels
    assert any(r["reason_code"] == "MARGIN_GT_5" for r in res["rejected"])  # m2
    assert any(r["reason_code"] == "INVALID_ODDS_FORMAT" for r in res["rejected"])  # m3
    # Vérifie que les cotes ne sont PAS dans le payload client
    for vm in res["validated_markets"]:
        for sel in vm["selections"]:
            assert "odds" not in sel or sel.get("odds") is None
    print("✅ process_and_cache_event OK (Fail-Closed + sans cotes)")
    print(f"   cached_key: {res['cached_key']} ttl {res['ttl_seconds']}s")

if __name__ == "__main__":
    test_parse_odds()
    test_margin()
    asyncio.run(test_process_event())
    print("Tous tests MegaPari OK")
