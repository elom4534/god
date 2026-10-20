# LIVRAISON — Scaffold complet V2 (prêt à `docker compose up`)

## ✅ Ce qui est livré (monorepo opérationnel)

**Repo:** `/home/user` — 68 fichiers, 3 apps + pipelines + shared.

### 1. Stack respectée (contraintes FIXES)
- **Flutter Web + Mobile** (`apps/client-flutter`) — FR/EN, sans cotes, responsible gambling partout
- **NestJS BFF** (`apps/api-node`) — auth, Country Gate fail-closed, orchestration coupon, proxy bookmaker, audit
- **FastAPI ML** (`apps/ml-python`) — normalizer 300+ marchés, Margin Guard ≤5%, Selection Engine 1/match strict, Elo/Dixon-Coles/CatBoost scaffold
- **Postgres + Redis + MinIO** via `docker-compose.yml`
- **Pipelines** (`pipelines/`) — ETL réel/virtuel, training, backtests, drift, scheduler

### 2. Modules critiques implémentés (code prêt)

**Normalizer** (`apps/ml-python/app/core/normalizer.py`):
- Mapping heuristique 300+ marchés → `1X2, DOUBLE_CHANCE, OVER_UNDER, BTTS, CORNERS_OU… → UNKNOWN=REJECT`
- Extraction line (`Over 2.5`, `9.5 Corners`), parsing odds `1,85`→1.85, tags auto
- Rejet fail-closed si incomplet

**Margin Guard** (`app/core/margin_guard.py`):
- Parsing robuste `None,"",0,-1,NaN,inf,missing` → rejet
- `marge% = (sum(1/odds)-1)*100` exclusifs 2/3 issues
- `Double Chance` formule dédiée + contrôle cohérence vs 1X2 (écart >7% → rejet)
- Sous-marchés lines traités comme marchés distincts
- Seuil 5% paramétrable, revalidé avant chaque `createCoupon`

**Selection Engine** (`app/core/selection_engine.py`):
- Étage 1 éligibilité: Margin Guard + historique + compatibilité modèle
- Étage 2 scoring conservateur: `p_lower = p_model - k·σ`, `score = p_lower·stabilité - pénalités`
- Étage 3 choix: 1 pick/match strict, déterministe, seuil `score<0.30 → skip`
- Mock inference déterministe (hash) prête à remplacer par vrai modèle calibré

**Coupon** (`apps/api-node/src/modules/coupons/` + `bookmaker/`):
- Modes `real_only / virtual_only / mix` + formats `SINGLE / COMBINE / SYSTEM(k,n)`
- 1 sélection/match validée côté serveur, draft 5min TTL, sans cotes
- `POST /bookmaker/coupon/create` → re-fetch odds frais + re-scan marge ≤5% → proxy signé + idempotency-key + audit

**Country Gate** (`common/guards/country-policy.guard.ts`): whitelist `ALLOWED_COUNTRIES`, fail-closed si absent → `403 COUNTRY_NOT_CONFIGURED`

### 3. Endpoints livrés (contrats figés)

| Méthode | Route | Implémentation |
|---------|-------|----------------|
| POST | /api/v1/events/ingest | NestJS → FastAPI normalizer |
| POST | /api/v1/scan | FastAPI `core/margin_guard` |
| POST | /api/v1/picks/best | FastAPI `selection_engine` |
| POST | /api/v1/coupons/generate | NestJS (draft sans cotes) |
| POST | /api/v1/bookmaker/coupon/create | NestJS proxy + revalidation |
| GET | /api/v1/health | health checks |

Contrats: `packages/shared/src/contracts/*.ts` + `API-CONTRACTS.md`

### 4. Flutter UI premium (sans cotes)

- **Accueil:** picks du jour pré-calculés (cache Redis), filtres Réel/Virtuel/Mix, `ProbabilityCard` (p_lower + confiance + facteurs)
- **Coupons:** choix mode + format, draft sans cotes, placement avec revalidation
- **Historique:** perf modèles, calibration, marchés désactivés
- **Paramètres:** langue FR/EN, pays (Country Gate), profil risque, limite RG
- Thème Material 3, bannière responsible gambling obligatoire

### 5. Data & stockage (réel vs virtuel)

- Réel: ingestion Live Football API, cotes discard après marge, feature store versionné
- Virtuel: stockage complet snapshots + drift PSI/KS, auto-disable si `psi>0.2`

### 6. Tests & validation

```bash
make test-ml # pytest margin_guard, normalizer, selection_engine ✅
docker compose up -d --build
curl http://localhost:3000/api/v1/health
curl http://localhost:8000/health
```

Voir `TESTING.md` pour cURL complets.

## Hypothèses explicites (incertitudes)

1. **Bookmaker API 1xBet/Méga Pari:** même doc, endpoints `/events`, `/markets`, `/coupon/create` avec snapshots horodatés — hypothèse basée sur prompt, à confirmer avec JSON réels.
2. **Live Football API:** fixtures/stats/xG/lineups dispo, clés via env.
3. **Marge Double Chance:** formule agrégée `P(1X)=P1+PX` + contrôle cohérence 7% — hypothèse trading standard, à ajuster avec bookmaker.
4. **Modèles MVP:** Elo/Poisson/Dixon-Coles + CatBoost mock calibré — prod nécessite données historiques réelles (~2 saisons, 3000 matchs/ligue).
5. **Volume 1k/j:** architecture lean (pas de k8s), pré-calcul quotidien + Redis 6h TTL suffit.
6. **Pays cibles tous pays:** `ALLOWED_COUNTRIES` en whitelist, on bloque si non configuré (fail-closed). À fournir liste exacte par légal.

## Ce qui manque pour prod (besoin de vous — hors chat)

- Variables d'env: `LIVE_FOOTBALL_API_KEY`, `BOOKMAKER_API_KEY`, `BOOKMAKER_BASE_URL`, `JWT_SECRET`
- **JSON exemples obligatoires:**
  - payload marchés réel (1xBet) + virtuel (Méga Pari) avec snapshots
  - payload `createCoupon` request/response + erreurs (odds changed, suspended, limit)

Sans ces JSON, le scaffold tourne en mode mock (`pipelines/etl/fixtures/sample_events.json`) — normalizer générique déjà prêt à s'adapter.

## Lancement immédiat

```bash
cp .env.example .env  # renseigner clés
docker compose up -d --build
# API: http://localhost:3000/docs
# ML:  http://localhost:8000/docs
cd apps/client-flutter && flutter run -d chrome
```

## Docs livrées

- `README.md` — démarrage + flux coupon
- `ARCHITECTURE.md` — diagramme + flux séquence + schéma PG/Redis
- `API-CONTRACTS.md` — contrats complets + exemples JSON à fournir
- `SECURITY.md` — menaces & check-list prod
- `TESTING.md` — tests & cURL
- `ROADMAP.md` — MVP→V1→V2

**Fail-closed respecté partout:** si incertain → rejet, pas de cotes exposées, pas de promesse de gain.
