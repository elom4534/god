# Roadmap V2 — MVP → V1 → V2

## MVP (4-6 semaines) — Lean, pré-match uniquement
- [x] Scaffold monorepo + docker-compose (postgres, redis, minio)
- [x] Normalizer 300+ marchés → schéma interne stable
- [x] Margin Guard ≤5% (exclusifs, Double Chance, lines) + parsing robuste
- [x] Selection Engine 1 pick/match strict + scoring conservateur p_lower
- [x] NestJS BFF: /events/ingest, /scan, /picks/best, /coupons/generate, /bookmaker/coupon/create
- [x] FastAPI ML: normalizer, margin_guard, selection_engine, inference mock (Elo/Poisson prêts)
- [x] Flutter skeleton: Home (picks), Coupons (réel/virtuel/mix + SINGLE/COMBINE/SYSTEM), History, Settings (FR/EN, pays)
- [x] Country Policy Gate fail-closed + revalidation marge pré-create
- [x] Cache Redis pré-calcul + audit logs + responsible gambling
- [ ] Brancher vraies clés API (Live Football + Bookmaker) via .env
- [ ] Fournir JSON exemples marchés + createCoupon (voir API-CONTRACTS.md §8)

**Critère sortie MVP:** 1 pick/match fiable sur 6 ligues, marge ≤5% validée, coupons réels testés en sandbox bookmaker.

## V1 (8-12 semaines) — Calibration & autonomie
- Elo/Glicko live + Dixon-Coles Poisson calibrés (isotonic/Platt)
- CatBoost/LightGBM ensembling + time split rolling + calibration plots
- Stockage virtual_history complet + features temporelles + drift detection auto-disable
- Monitoring: Grafana (latence, taux rejet, drift PSI), alerting
- Backtests par ligue/saison + rapport hebdo
- Persistance Postgres (migrations) + rate limiting + circuit breaker
- Flutter: détails pick (proba, facteurs, warnings), historique perf
- Tests E2E Jest + Pytest + CI

## V2 (3-6 mois) — Scale & multi-sports
- Ensembles avancés (stacking) + personnalisation risk_profile
- Plug-in multi-sports (basket, tennis) — même normalizer générique
- Optimisation EV (si bookmaker autorise affichage interne) + gestion bankroll
- Mobile push + offline cache + PWA
- A/B testing + explainability SHAP
- Passage k8s si >10k req/j

## Dette connue à traiter après MVP
- Auth réelle (JWT refresh + OAuth), pas mock
- Chiffrement secrets (Vault/AWS Secrets Manager)
- Partitions Postgres virtual_history (par mois)
- Observabilité prod (OTEL + Prometheus)
