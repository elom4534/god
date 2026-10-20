# Intégration MegaPari (ref=192) — Opérationnelle & Réutilisable 1xBet

> **Fail-Closed** — Marge >5% = rejet, 1 pick/match strict, cotes jamais exposées client, TTL 15min.

## 1. Base de Données — `db/migrations/001_megapari_schema.sql`

```sql
-- Appliquer:
psql $DATABASE_URL -f db/migrations/001_megapari_schema.sql
-- Vérifier:
\d events
\d validated_markets
\d virtual_snapshots
```

**Tables:**
- `events(id=GameId, provider='MEGAPARI', sport, league, home_team, away_team, start_time, is_virtual)` + index `start_time`, `provider/sport`, `is_virtual`
- `validated_markets(event_id FK, market_type, margin_percent CHECK ≤5.0, selections_json JSONB)` + GIN + unique(event_id,market_type,json)
- `virtual_snapshots(event_id FK, market_type, odds_data JSONB, result JSONB, snapshot_time, drift_score)` + composite `event/market/time` + GIN

Réutilisable 1xBet: même schéma, `provider='1XBET'`.

## 2. Service Python — Margin Guard & Redis

**Fichier:** `apps/ml-python/app/services/megapari_margin_guard.py`

```python
# Flux réel MegaPari (LoadList 15093 events + LoadSingle)
POST /ml/v1/megapari/ingest
{
  "raw_events": [{ "id": 763041519, "markets": [...] }],
  "threshold": 5.0
}
→ {
  "provider":"MEGAPARI",
  "processed":1,
  "events":[{
    "event_id":"763041519",
    "validated_markets":[{market_id, market_type, margin_percent:2.56, selections:[{selection_id,name,tags}]}], // SANS cotes
    "rejected":[{market_id, reason_code:"MARGIN_GT_5", margin_percent:8.33}],
    "cached_key":"megapari:event:763041519",
    "ttl_seconds":900
  }]
}
```

- **Marge:** `(sum(1/cote)-1)*100` exclusifs, `DOUBLE_CHANCE` avec cohérence 7%
- **Parsing:** `None,"", "1,85", 0, -1, NaN, inf` → `None` → rejet Fail-Closed
- **Redis:** `SETEX megapari:event:{id} 900 json` + `ZADD megapari:events:by_time`
- **Tests:** `pytest apps/ml-python/tests/test_megapari_margin_guard.py` ✅

## 3. Service NestJS — Coupon & Deep Link

**Fichier:** `apps/api-node/src/modules/bookmaker/megapari-coupon.service.ts`

```typescript
POST /api/v1/megapari/coupon/generate
{
  "picks": [
    {event_id:"763041519", market_id:"9_2.5", selection_id:"over", market_type:"OVER_UNDER"},
    {event_id:"763041520", market_id:"1_0", selection_id:"1", market_type:"1X2"}
  ],
  "currency":"XOF"
}
→ {
  "success": true,
  "provider": "MEGAPARI",
  "totalPicks": 2,
  "deepLink": "https://ref.top/L?tag=s_23283m_355c_&r=%2Ffr%2Fline%2FFootball%2F763041519&selections=763041519%3A9_2.5%3Aover%2C763041520%3A1_0%3A1&ref=192",
  "message": "2 sélection(s) validée(s) — 1 par match (Fail-Closed)...",
  "couponPayload": {ref:192, picks, affiliateTag:"s_23283m_355c_", createdAt, expiresAt:"+5min"}
}
```

- **Règle stricte:** `validateStrictOnePickPerMatch()` lève `STRICT_RULE_VIOLATION` si 2 picks même `event_id`
- **Deep Link:** `https://{MEGAPARI_DEEP_LINK_DOMAIN}/L?tag={MEGAPARI_AFFILIATE_TAG}&r=...&selections=event:market:selection,...&ref=192`
- **Env:** `MEGAPARI_REF=192`, `MEGAPARI_AFFILIATE_TAG=s_23283m_355c_`, `MEGAPARI_DEEP_LINK_DOMAIN=ref.top`
- **Réutilisable 1xBet:** changer `ref=1`, `MEGAPARI_AFFILIATE_TAG` → `XBET_AFFILIATE_TAG`, même service

## 4. Déploiement

```bash
# DB
psql $DATABASE_URL -f db/migrations/001_megapari_schema.sql

# Python
curl -X POST http://localhost:8000/ml/v1/megapari/ingest -H "Content-Type: application/json" -d @pipelines/etl/fixtures/sample_events.json
curl http://localhost:8000/ml/v1/megapari/health
curl http://localhost:8000/ml/v1/megapari/cache/763041519

# Node
curl -X POST http://localhost:3000/api/v1/megapari/coupon/generate -H "Content-Type: application/json" -d '{"picks":[{"event_id":"763041519","market_id":"9_2.5","selection_id":"over","market_type":"OVER_UNDER"}]}'
```

Tous les fichiers sont en place, testés, documentés — prêts prod.
