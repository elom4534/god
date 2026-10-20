# Sécurité & Compliance — Fail-Closed

## Principes non négociables

1. **Pas de cotes côté client** — filtrées par BFF (NestJS). Seules probas + confiance exposées.
2. **Revalidation marge ≤5% juste avant createCoupon** — fetch odds frais → scan ML → rejet si >5%.
3. **Country Policy Gate fail-closed** — `ALLOWED_COUNTRIES` whitelist. Si pays absent → `403 COUNTRY_NOT_CONFIGURED` (on peut afficher probas informatives, pas créer coupon).
4. **1 sélection/match strict** — validé côté BFF + ML + DB (contrainte unique).
5. **Audit logs** — chaque décision: user_id, provider, model_version, as_of, reason_codes, payload_hash → Postgres audit_logs.
6. **Secrets** — uniquement env, jamais hardcodés, jamais loggés. Utiliser Vault en prod.
7. **Rate limiting** — Redis: 10 coupons/min/user, 100 req/min/IP.
8. **Timeouts + Circuit Breaker** — Bookmaker API: 2s timeout, 2 retries max, circuit ouvert après 5 erreurs/10s (cockatiel).
9. **Responsible gambling** — banner obligatoire + limites modifiables en settings + blocage si limite atteinte.
10. **Pas de promesse de gain** — UI affiche probas + incertitude + avertissements.

## Menaces & mitigations

| Menace | Mitigation |
|--------|-----------|
| Exfiltration cotes | BFF filtre `odds_internal` |
| Cotes changées entre draft et create | Re-scan marge frais |
| Pays non autorisé | Country Gate fail-closed |
| Double sélection même match (système) | Déduplication event_id + DB constraint |
| Drift moteur virtuel | PSI >0.2 → auto-disable + alerte |
| Injection Bookmaker payload | Validation Pydantic + sanitize |
| Brute force coupons | Rate limit + idempotency-key |

## Checklist prod

- [ ] TLS partout, HSTS
- [ ] JWT rotation + refresh, HttpOnly cookie
- [ ] Secrets Manager (AWS/GCP Vault)
- [ ] WAF + IP allowlist pour /bookmaker/coupon/create
- [ ] Logs structurés + SIEM
- [ ] RGPD: droit à l'effacement, anonymisation virtual_history
