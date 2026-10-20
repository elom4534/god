# Tests & Validation — V2

## Tests unitaires (ML)

```bash
cd apps/ml-python
pytest -v
# - test_margin_guard.py: parsing "1,85", "", null, inf, marge >5% rejet, Double Chance cohérence
# - test_normalizer.py: mapping 1xBet/Méga Pari → schéma interne, line extraction, rejected si incomplet
# - test_selection_engine.py: 1 pick/match strict, scoring conservateur, déterministe
```

Cas critiques couverts:
- `parse_odds("1,85") == 1.85`, `parse_odds("") is None`, `parse_odds(0) is None`
- Marge 1X2 [2.0,3.0,4.0] = 8.33% → rejet
- Marge O/U [1.95,1.95] = 2.56% → validé
- Marché suspendu/invalide → rejet fail-closed

## Tests E2E (NestJS)

```bash
cd apps/api-node
npm test
```

Scénarios:
- `POST /events/ingest` → normalized + rejected
- `POST /scan` avec marge >5% → rejected_options
- `POST /picks/best` → 1/match, pas de doublon
- `POST /coupons/generate` mode mix + SYSTEM → draft sans cotes, expiry 5min
- `POST /bookmaker/coupon/create` → revalidation marge (mock bookmaker marge 5.3% → 409)
- Country Gate: X-Country-Code=US → 403 COUNTRY_BLOCKED

## Backtests & Calibration

```bash
python pipelines/training/backtest.py  # rolling 3m/1m par ligue
python pipelines/monitoring/calibration_report.py
# Vérifier: Brier <0.22, ECE <0.05, calibration slope 0.9-1.1
```

## cURL exemples (une fois docker up)

```bash
# Health
curl http://localhost:3000/api/v1/health
curl http://localhost:8000/health

# Ingest
curl -X POST http://localhost:3000/api/v1/events/ingest \
  -H "Content-Type: application/json" \
  -d @pipelines/etl/fixtures/sample_events.json

# Scan
curl -X POST http://localhost:3000/api/v1/scan \
  -H "Content-Type: application/json" \
  -d '{"event_id":"evt_pl_001","markets":[{"market_id":"m_ou25","market_type":"OVER_UNDER","line":2.5,"selections":[{"selection_id":"over","name":"Over","odds":1.95},{"selection_id":"under","name":"Under","odds":1.95}]}],"threshold_pct":5}'

# Picks
curl -X POST http://localhost:3000/api/v1/picks/best \
  -H "Content-Type: application/json" \
  -d '{"events":[...],"mode":"mix"}'

# Coupon generate (avec country header obligatoire pour create, pas pour generate)
curl -X POST http://localhost:3000/api/v1/coupons/generate \
  -H "Content-Type: application/json" \
  -d '{"mode":"mix","format":"COMBINE","event_ids":["evt_pl_001","virt_001"]}'

# Coupon create (revalidation fail-closed)
curl -X POST http://localhost:3000/api/v1/bookmaker/coupon/create \
  -H "Content-Type: application/json" \
  -H "X-Country-Code: TG" \
  -d '{"draft_id":"draft_abc123","provider":"1xBet","stake":1000,"currency":"XOF"}'
```

## Manuel (Flutter)

- Vérifier: aucune cote affichée nulle part
- Mode Réel/Virtuel/Mix filtre bien
- Draft expire après 5min
- Banner responsible gambling visible partout
- Settings: passage FR↔EN, changement pays TG→US bloque création
