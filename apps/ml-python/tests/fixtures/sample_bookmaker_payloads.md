# Fixtures attendues — à fournir hors chat pour finaliser normalizer/coupon builder

## 1. Marchés réel 1xBet (snapshot)
```json
{
  "event_id": "12345",
  "league": "Premier League",
  "home": "Arsenal",
  "away": "Man City",
  "start_time": "2026-10-21T19:45:00Z",
  "status": "active",
  "markets": [
    {"id":"1","name":"1X2","outcomes":[{"name":"1","price":2.10},{"name":"X","price":3.20},{"name":"2","price":3.50}]},
    {"id":"2","name":"Over/Under 2.5","param":"2.5","outcomes":[{"name":"Over","price":1.95},{"name":"Under","price":1.85}]},
    {"id":"3","name":"Corners Over/Under 9.5","param":"9.5","outcomes":[{"name":"Over","price":1.88},{"name":"Under","price":1.88}]}
  ],
  "snapshot_ts": "2026-10-21T19:40:00Z"
}
```

## 2. Virtuel Méga Pari
```json
{
  "virtual_event_id": "virt_42",
  "round": 42,
  "markets": [{"id":"m1","name":"Match Result","odds":[2.2,3.1,3.4]}],
  "result": {"score":"1-0","winner":"1"},
  "snapshot_ts": "2026-10-21T20:00:00Z"
}
```

## 3. createCoupon request/response + erreurs
```json
// Request
{"coupon":{"selections":[{"event_id":"12345","market_id":"1","selection_id":"1"}],"stake":100,"currency":"XOF"},"idempotency_key":"abc"}
// Success
{"coupon_id":"tkt_789","status":"accepted","placed_at":"2026-10-21T19:45:00Z"}
// Error odds changed
{"error":"ODDS_CHANGED","details":{"selection_id":"1","old_odds":2.10,"new_odds":1.95},"reason_code":"ODDS_CHANGED_OR_SUSPENDED"}
// Error limit
{"error":"LIMIT_EXCEEDED","reason_code":"LIMIT_EXCEEDED"}
// Error suspended
{"error":"MARKET_SUSPENDED","reason_code":"MARKET_SUSPENDED"}
```

Sans ces JSON réels, le scaffold tourne en mode mock (pipelines/etl/fixtures/sample_events.json).
