# App Prédiction Sportive — 1xBet + Méga Pari (Scaffold V2)

> **Stack:** Flutter (Web + iOS + Android) + NestJS + FastAPI + Postgres + Redis + MinIO  
> **Principe cardinal:** `fail-closed` — si incertain → on ne propose pas. Probas calibrées, pas de certitudes. Jamais de cotes exposées côté client.

## 1. Démarrage ultra-rapide

```bash
cp .env.example .env
# Renseigner LIVE_FOOTBALL_API_KEY et BOOKMAKER_API_KEY (fournis hors chat)
docker compose up -d --build
# API Node: http://localhost:3000  | Swagger: http://localhost:3000/docs
# ML Python: http://localhost:8000 | Docs: http://localhost:8000/docs
# Flutter Web (dev): cd apps/client-flutter && flutter run -d chrome
```

Vérif santé:
```bash
curl http://localhost:3000/health
curl http://localhost:8000/health
```

## 2. Architecture (lean ~1k req/j)

```
[Flutter Web/Mobile] ──HTTPS──> [NestJS API :3000] ──HTTP──> [FastAPI ML :8000]
                                      │                           │
                                      ├─> Postgres (entités, audit, virtual history)
                                      ├─> Redis (cache pré-calcul picks, rate-limit)
                                      ├─> MinIO/S3 (datasets, modèles versionnés)
                                      └─> Bookmaker API (proxy sécurisé, revalidation marge)
                                                    
[Pipelines] ──ETL cron──> Postgres/Redis/MinIO (ingestion Live Football + virtuel, training, drift)
```

Voir **ARCHITECTURE.md** pour diagramme détaillé + flux.

## 3. Monorepo

```
/
├── docker-compose.yml
├── apps/
│   ├── api-node/        # NestJS — API publique, auth, orchestration coupon, proxy bookmaker
│   ├── ml-python/       # FastAPI — normalizer, margin guard, selection engine, inference
│   └── client-flutter/  # Flutter — Web + iOS + Android, sans cotes, FR/EN
├── pipelines/           # ETL, training, backtests, drift detection
├── packages/shared/     # Contrats TS + JSON schemas (source of truth)
└── docs/
```

## 4. Endpoints clés (contrats fixés)

| Méthode | Route | Rôle |
|---------|-------|------|
| POST | /events/ingest | Normalisation events bruts → schéma interne |
| POST | /scan | Margin Guard → validated_options (marge ≤5%) |
| POST | /picks/best | 1 pick/match strict, scoring conservateur |
| POST | /coupons/generate | Draft coupon (réel/virtuel/mix + SINGLE/ACCUM/SYSTEM) |
| POST | /bookmaker/coupon/create | Proxy sécurisé + revalidation marge fail-closed |
| GET | /health | Liveness |
| GET | /metrics | Prometheus (NestJS) |

Contrats complets: `packages/shared/src/contracts/*.ts` + `API-CONTRACTS.md`.

## 5. Règles de sécurité non négociables

- **Jamais de cotes côté client.** Filtrées par le BFF (NestJS). Le ML les utilise en interne uniquement.
- **Margin Guard >5% = rejet.** Revalidé juste avant `createCoupon`.
- **Country Policy Gate fail-closed.** Si pays non autorisé/non configuré → blocage création coupon (probas informatives OK).
- **1 sélection par match strict** (même en système).
- **Audit log** obligatoire: user_id, provider, model_version, as_of, reason_codes.
- **Responsible gambling** banner + limites sur chaque écran coupon.

## 6. Flux coupon (sans cotes)

1. Client: `POST /coupons/generate { mode: "mix", format: "SYSTEM_3_4", match_ids: [...] }`
2. NestJS: vérifie JWT + Country Gate + rate-limit → appelle `POST /picks/best` (FastAPI) → cache Redis → assemble draft (sans cotes, avec proba + confiance + facteurs)
3. Client affiche draft → user confirme
4. Client: `POST /bookmaker/coupon/create { draft_id, provider: "1xBet" }`
5. NestJS: re-scan marge ≤5% (fetch odds frais) + circuit-breaker + proxy signé → Bookmaker → retour ticket_id/status
6. Audit + métriques

## 7. Football réel vs Virtuel

| Aspect | Réel (Live Football API) | Virtuel (Bookmaker) |
|--------|--------------------------|---------------------|
| Stockage cotes | **INTERDIT long terme** — discard après marge | **Complet** (snapshots, timestamps, résultats) |
| Entraînement | Elo + Dixon-Coles + CatBoost, calibré | Pipeline séparé, features temporelles |
| Drift | Monitoring par ligue | Drift detection obligatoire (RNG change) |
| Latence | Pré-calcul + cache Redis (secondes) | Idem + snapshot versioning |

## 8. Modèles (roadmap)

- **MVP:** Normalizer + Margin Guard + Elo/Poisson + 1 pick/match + cache
- **V1:** CatBoost/LightGBM + calibration isotonic + monitoring + virtual storage/training
- **V2:** Ensembles, personnalisation, multi-sports plug-in

## 9. Tests

```bash
make test-ml      # pytest margin_guard, normalizer, selection_engine
make test-api     # jest e2e coupons, country gate, margin revalidation
```

## 10. Entrées externes à fournir (hors chat)

Variables d'env + **exemples JSON** pour finaliser:
- `payload marchés/événements` (réel + virtuel) avec snapshots horodatés
- `payload createCoupon` request/response + erreurs (marché suspendu, odds changed, limit exceeded)

Sans ces JSON, le scaffold tourne en **mode mock** (`pipelines/etl/fixtures/*`).

## 11. Compliance

Aucune promesse de gain. Probas + incertitude + avertissements. Voir `apps/client-flutter/lib/widgets/responsible_gambling_banner.dart`.

---
© Scaffold V2 — fail-closed by design.
