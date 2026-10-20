import sys
sys.path.append(".")

from app.core.margin_guard import compute_margin_exclusive, scan_markets
from app.utils.parsing import parse_odds

def test_parse_odds():
    assert parse_odds("1,85") == 1.85
    assert parse_odds("") is None
    assert parse_odds(None) is None
    assert parse_odds(0) is None
    assert parse_odds(-1) is None
    assert parse_odds(float("inf")) is None
    assert parse_odds("1.90") == 1.9

def test_margin_exclusive():
    # 1X2 à 2.0, 3.0, 4.0 → marge = (0.5+0.333+0.25 -1)*100 = 8.33%
    m = compute_margin_exclusive([2.0,3.0,4.0])
    assert abs(m - 8.333) < 0.01
    # marge faible 1.95,1.95 → (0.512+0.512-1)*100=2.56%
    assert compute_margin_exclusive([1.95,1.95]) < 5
    assert compute_margin_exclusive([1.95,1.95]) > 2
    # une cote invalide → None
    assert compute_margin_exclusive([None,2.0]) is None

def test_scan_rejects_gt5():
    markets = [
        {
            "market_id": "m1",
            "market_type": "1X2",
            "line": None,
            "selections": [
                {"selection_id":"s1","odds":2.0},
                {"selection_id":"s2","odds":3.0},
                {"selection_id":"s3","odds":4.0},
            ]
        },
        {
            "market_id": "m2",
            "market_type": "OVER_UNDER",
            "line": 2.5,
            "selections": [
                {"selection_id":"s_over","odds":1.95},
                {"selection_id":"s_under","odds":1.95},
            ]
        },
        {
            "market_id": "m3",
            "market_type": "BTTS",
            "selections": [
                {"selection_id":"s_yes","odds": ""},  # invalid
                {"selection_id":"s_no","odds": 1.9},
            ]
        }
    ]
    res = scan_markets(markets, threshold_pct=5.0)
    # m1 marge 8.33% → rejet
    assert any(r["market_id"]=="m1" for r in res["rejected_options"])
    # m2 marge 2.56% → validé (2 options)
    assert len([v for v in res["validated_options"] if v["market_id"]=="m2"])==2
    # m3 invalid odds → rejet
    assert any(r["market_id"]=="m3" for r in res["rejected_options"])
    print("All margin guard tests passed")

if __name__ == "__main__":
    test_parse_odds()
    test_margin_exclusive()
    test_scan_rejects_gt5()
