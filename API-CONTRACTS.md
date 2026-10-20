# CONTRATS API — Source of Truth

> Implémentations miroir: `packages/shared/src/contracts/*.ts` (TS) et `apps/ml-python/app/schemas/*.py` (Pydantic).

## 1. Conventions globales

- Base URL NestJS: `/api/v1`
- Base URL ML: `/ml/v1`
- Auth: `Bearer JWT` (sauf `/health`, `/events/ingest` interne via API key).
- Erreurs fail-closed standard:
```json
{ "error": "MARGIN_EXCEEDED", "reason_code": "MARGIN_GT_5", "details": "margin=5.8%", "as_of": "2026-10-19T20:50:00Z" }
{ "error": "COUNTRY_NOT_CONFIGURED", "reason_code": "COUNTRY_GATE_BLOCKED", "country": "US" }
{ "error": "MARKET_UNAVAILABLE", "reason_code": "ODDS_CHANGED_OR_SUSPENDED" }
```
- **Jamais de cotes** dans les réponses publiques. Elles restent internes (`odds_internal` côté ML/DB).

## 2. POST /events/ingest (NestJS → ML proxy)

Normalise payload brut bookmaker/Live Football API.

**Request:**
```json
{
  "provider": "1xBet",
  "is_virtual": false,
  "raw_events": [ { /* payload brut bookmaker */ } ],
  "as_of": "2026-10-19T20:00:00Z"
}
```

**Response 200:**
```json
{
  "normalized": [
    {
      "event_id": "evt_123",
      "sport": "football",
      "league": "Premier League",
      "start_time": "2026-10-20T19:45:00Z",
      "home": "Arsenal",
      "away": "Man City",
      "is_virtual": false,
      "markets": [
        {
          "market_id": "mkt_1x2",
          "market_type": "1X2",
          "name": "1X2",
          "period": "FT",
          "line": null,
          "selections": [
            { "selection_id": "sel_home", "name": "1", "tags": ["HOME"] },
            { "selection_id": "sel_draw", "name": "X", "tags": ["DRAW"] },
            { "selection_id": "sel_away", "name": "2", "tags": ["AWAY"] }
          ]
        }
      ]
    }
  ],
  "rejected": [{ "raw_id": "evt_bad", "reason_code": "INCOMPLETE_MARKET" }],
  "model_version": "v0.3.0",
  "as_of": "2026-10-19T20:00:00Z"
}
```

## 3. POST /scan (Margin Guard)

**Request:**
```json
{
  "event_id": "evt_123",
  "markets": [ /* schéma interne, avec odds internes */ ],
  "threshold_pct": 5.0
}
```

**Response 200:**
```json
{
  "event_id": "evt_123",
  "validated_options": [
    {
      "market_id": "mkt_ou25",
      "market_type": "OVER_UNDER",
      "line": 2.5,
      "selection_id": "sel_over",
      "margin_pct": 3.2,
      "reason_code": "OK"
    }
  ],
  "rejected_options": [
    {
      "market_id": "mkt_1x2",
      "selection_id": "sel_home",
      "margin_pct": 5.8,
      "reason_code": "MARGIN_GT_5"
    },
    {
      "market_id": "mkt_corners",
      "reason_code": "INVALID_ODDS_FORMAT"
    }
  ],
  "as_of": "2026-10-19T20:01:00Z"
}
```

Voir `packages/shared/src/contracts/scan.contract.ts` + `apps/ml-python/app/core/margin_guard.py` pour formules (exclusifs vs Double Chance).

## 4. POST /picks/best (1 pick/match strict)

**Request:**
```json
{
  "events": [ /* normalized events */ ],
  "mode": "real_only | virtual_only | mix",
  "k_sigma": 1.0
}
```

**Response 200:**
```json
{
  "picks": [
    {
      "event_id": "evt_123",
      "market_id": "mkt_ou25",
      "selection_id": "sel_over",
      "market_type": "OVER_UNDER",
      "line": 2.5,
      "p_model": 0.58,
      "sigma": 0.07,
      "p_lower": 0.51,
      "confidence": "MEDIUM",
      "score": 0.42,
      "factors": [
        { "name": "form_home", "impact": "+0.06" },
        { "name": "elo_diff", "impact": "+0.04" }
      ],
      "warnings": ["LOW_HISTORY_CORNERS"],
      "model_version": "v0.3.0",
      "as_of": "2026-10-19T20:02:00Z"
    }
  ],
  "skipped": [{ "event_id": "evt_456", "reason_code": "NO_ELIGIBLE_MARKET" }],
  "as_of": "2026-10-19T20:02:00Z"
}
```

Règles: 1 pick/match max, déterministe, scoring conservateur.

## 5. POST /coupons/generate (NestJS)

**Request:**
```json
{
  "mode": "real_only | virtual_only | mix",
  "format": "SINGLE | COMBINE | SYSTEM",
  "system_k": 2,
  "system_n": 3,
  "event_ids": ["evt_123", "evt_124", "evt_125"],
  "preferences": { "risk_profile": "conservative", "leagues": ["Premier League"] }
}
```

**Response 200:**
```json
{
  "draft_id": "draft_abc",
  "mode": "mix",
  "format": "SYSTEM_2_3",
  "selections": [
    { "event_id": "evt_123", "market_id": "mkt_ou25", "selection_id": "sel_over", "p_lower": 0.51, "confidence": "MEDIUM" }
  ],
  "constraints_ok": true,
  "warnings": ["MIX_VIRTUAL_REAL"],
  "created_at": "2026-10-19T20:03:00Z",
  "expires_at": "2026-10-19T20:08:00Z"
}
```
**Aucune cote exposée.** Le draft expire en 5min (revalidation obligatoire).

## 6. POST /bookmaker/coupon/create (NestJS proxy fail-closed)

**Request:**
```json
{
  "draft_id": "draft_abc",
  "provider": "1xBet",
  "stake": 1000,
  "currency": "XOF"
}
```

**Success 201:**
```json
{ "ticket_id": "tkt_789", "status": "PLACED", "provider": "1xBet", "placed_at": "2026-10-19T20:03:30Z" }
```

**Fail-closed 409:**
```json
{ "error": "REJECTED_REVALIDATION", "reason_code": "MARGIN_GT_5_ON_RESCAN", "details": "mkt_ou25 margin 5.3% on rescan" }
{ "error": "COUNTRY_NOT_CONFIGURED", "reason_code": "COUNTRY_GATE_BLOCKED" }
{ "error": "MARKET_SUSPENDED", "reason_code": "ODDS_CHANGED_OR_SUSPENDED" }
```

Idempotency: header `Idempotency-Key: <draft_id>` transmis au bookmaker.

## 7. GET /health & GET /metrics

```json
// GET /health
{ "status": "ok", "version": "0.3.0", "checks": { "postgres": "up", "redis": "up", "ml": "up" } }
```

## 8. Exemples JSON à fournir (pour finaliser normalizer/coupon builder)

Le scaffold inclut des mocks dans `pipelines/etl/fixtures/` et `apps/ml-python/tests/fixtures/`. Pour prod, fournir:

1. **Payload marchés réel (1xBet)** — avec snapshots:
```json
{ "event_id": "123", "league": "Premier League", "markets": [ { "id": "1", "name": "1X2", "odds": ["2.10","3.20","3.50"], "status": "active" } ], "snapshot_ts": "2026-10-19T..." }
```
2. **Payload virtuel (Méga Pari)** — distribution différente, moteur RNG:
```json
{ "virtual_event_id": "virt_001", "round": 42, "markets": [...], "result": { "score": "2-1" }, "snapshot_ts": "..." }
```
3. **Payload createCoupon request/response + erreurs**:
```json
// request
{ "coupon": { "selections": [...] }, "stake": 100, "currency": "EUR" }
// response success
{ "coupon_id": "abc", "status": "accepted" }
// response error: odds changed
{ "error": "ODDS_CHANGED", "details": { "selection_id": "x", "old": 2.1, "new": 1.95 } }
```

Ces JSON permettront de verrouiller le mapping exact `raw → normalized → margin_guard → selection → coupon`.
