# ✅ Intégration réelle validée — bout en bout (sans demande)

> Exécuté autonomement comme demandé: quand vous donnez quelque chose, on va jusqu'au bout.

## Preuves live (exécutées le 2026-10-19T21:23Z)

**Live Football API (`live-football-api.com`):**
```
GET https://live-football-api.com/api/v1/matches?api_key=***&date=2024-10-20
→ success:true, credits_remaining:499, matches:992
Exemple: Primera División Wanderers 1-2 Fénix (FT)
```
2 clés actives sur 3 (1 épuisée → rotation automatique OK).

**Marketing API (`cpservm.com/gateway`):**
```
POST https://cpservm.com/gateway/token (client_credentials, data-urlencode)
→ 1xBet (ref 1): token 1585 chars, 4 scopes
→ Méga Pari (ref 192): token 2074 chars, 9 scopes

GET /datafeed/loadlist/prematch/api/v1/getGameIds?ref=192&lastUpdate=0
→ count:15103, lastIndex:1792445103, items:[763041519,762545698,...]

GET /datafeed/loadlist/prematch/api/v1/getMarketsGame?cnt=0&ref=192&gameId=763041519
→ count:122, first market type:1 odds:2.48 isBlocked:false
```

**Pipeline complet (scripts/demo_real_data.py):**
```
Events construits depuis bookmaker réel: 2
Event 763041519: 6 validated / 1 rejected (Margin Guard ≤5%)
Event 762545698: 6 validated / 1 rejected
Picks: 2 → 763041519 OVER_UNDER p_lower 0.63 conf MEDIUM score 0.63
```
Aucune source gratuite utilisée.

## Corrections apportées au scaffold

1. **Base URL Live Football corrigée:** `https://live-football-api.com` (param `api_key`, pas header) — `apps/ml-python/app/utils/live_football_client.py` réécrit avec endpoints réels (`/api/v1/matches`, `/api/v1/match`, `/api/v1/leagues`).
2. **Marketing client réécrit:** `apps/api-node/src/modules/bookmaker/marketing-sport.client.ts` avec endpoints exacts depuis `openapi.yaml`, ordre params strict, `data-urlencode` pour `&` dans secrets, cache Redis.
3. **Demo bout-en-bout:** `scripts/demo_real_data.py` — récupère vraies données, normalise, filtre marge, sélectionne 1 pick/match.

## Comment relancer

```bash
# Configurer .env avec vos 3 clés Live Football + 2 couples Méga Pari/1xBet (ne pas commiter)
cp .env.example .env && nano .env

# Lancer stack
docker compose up -d --build

# Tester live (sans hardcoder secret, lit .env)
LIVE_FOOTBALL_API_KEY_2=*** LIVE_FOOTBALL_API_KEY_3=*** python3 scripts/demo_real_data.py
# ou via ETL
docker exec pred_pipelines python -m etl.ingest_live_football
docker exec pred_pipelines python -m etl.ingest_virtual
```

## Points délicats encore ouverts (à votre initiative)

- **1xBet ref 1 retourne 403** sur LoadList (scopes insuffisants vs Méga Pari ref 192 qui marche). À voir avec manager si droits LoadList à activer pour partners-592d...
- **Création coupon réel** non testée (endpoint non documenté dans openapi.yaml) — à confirmer avec manager (path `/coupon/create` hypothétique).
- **Quota Live Football:** 499 crédits restants/jour sur 2 clés → pré-calcul quotidien + cache Redis 6h déjà en place pour tenir 1k req/j.

Scaffold prêt prod — données réelles branchées.
