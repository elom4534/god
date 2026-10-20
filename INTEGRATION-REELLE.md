# Intégration réelle — 1xBet / Méga Pari + Live Football API

> **Statut:** Scaffold mis à jour pour données réelles. **Aucun secret hardcodé.** Toutes les clés via variables d'environnement.

## 1. Secrets reçus — action sécurité

Vous avez transmis en clair dans le chat:
- `docs-marketing-sport.com` login + 2 couples `client_id/client_secret` (partners-592..., partners-c2b7...)
- 3 clés Live Football API

**Recommandation immédiate (délicat):**
- Ces secrets sont exposés dans l'historique du chat. **À révoquer/rotater après tests.**
- Ne jamais commiter `.env` (déjà dans `.gitignore`).
- En prod: utiliser Vault / AWS Secrets Manager / Doppler — jamais `.env` en clair sur serveur.

Je **n'ai stocké aucun secret en dur** dans le repo. Le code lit uniquement `process.env` / `os.getenv`.

Voulez-vous que je teste la connectivité live maintenant ? (appel réseau authentifié qui log votre IP chez le provider) — **je demande confirmation avant toute action délicate** comme convenu.

---

## 2. Live Football API — 3 clés avec rotation

**Provider:** Live Football API (fixtures, résultats, stats, xG, lineups si dispo)
**Quota:** 3 clés fournies → implémentation rotation + fallback automatique.

### Env à configurer (local, non commité)
```bash
# .env (à la racine, gitignoré — JAMAIS commité)
LIVE_FOOTBALL_API_KEY=***_1  # clé 1 fournie hors chat
LIVE_FOOTBALL_API_KEY_2=***_2  # clé 2
LIVE_FOOTBALL_API_KEY_3=***_3  # clé 3
LIVE_FOOTBALL_BASE_URL=https://api.live-football-api.com  # adapter selon doc officielle fournie
```

### Client implémenté
`apps/ml-python/app/utils/live_football_client.py` (nouveau):
- Rotation Round-Robin sur les 3 clés si `429 Rate Limited` ou `403`
- Headers `X-API-Key` + `Accept: application/json`
- Endpoints utilisés (à confirmer selon doc exacte Live Football API):
  - `GET /fixtures?league=PL&season=2024&date=2026-10-20` (fixtures pré-match)
  - `GET /fixtures/{id}/statistics` (stats équipes, forme, xG)
  - `GET /fixtures/{id}/lineups` (blessures/lineups si dispo)
  - `GET /results?from=...&to=...` (résultats pour training)
- **Fail-closed:** si quota épuisé sur 3 clés → on n'invente pas de données, on retourne `NO_DATA` + alerte.

**Règle stockage cotes réelles:** le client **discard** les cotes après calcul marge (jamais persistées long terme) — conforme contrainte.

---

## 3. 1xBet & Méga Pari — docs-marketing-sport.com

**Doc officielle:** https://docs-marketing-sport.com/ (auth requise) + https://docs-marketing-sport.com/en
- Même documentation pour 1xBet et Méga Pari, seuls `client_id/client_secret` et `ref` changent.
- Endpoints clés: `loadList` et `loadTree` (découverts via doc, à adapter selon JSON réel).

### Auth flow (affilié)
```
POST https://api.marketing-sport.com/auth/token
Body: { client_id, client_secret, ref }
→ { access_token, expires_in }
```
Headers suivants: `Authorization: Bearer <token>`

### Env à configurer
```bash
# 1xBet (docs-marketing-sport.com)
XBET_CLIENT_ID=partners-592d***  # fourni hors chat — ref 1
XBET_CLIENT_SECRET=***  # fourni hors chat
XBET_REF=1
XBET_LOGIN=marketingsport
XBET_PASSWORD=***  # via secrets manager, jamais en clair

# Méga Pari (même doc, ref différent)
MEGAPARI_CLIENT_ID=partners-c2b75***  # fourni hors chat — ref 192
MEGAPARI_CLIENT_SECRET=***  # fourni hors chat
MEGAPARI_REF=192

# Commun
BOOKMAKER_API_BASE=https://api.marketing-sport.com
BOOKMAKER_CREATE_COUPON_PATH=/coupon/create  # à confirmer dans doc loadList/loadTree

# Country gate (fail-closed)
ALLOWED_COUNTRIES=CI,CM,FR,BE,MA,SN,TG,BJ,ML,BF,NE,GN,GA,CG,CD,RW,KE,NG,GH,ZA
```

### Client implémenté
`apps/api-node/src/modules/bookmaker/marketing-sport.client.ts` (nouveau):
- `getAccessToken(provider)` avec cache Redis TTL `expires_in - 60s`
- `loadList({ sport, league, is_virtual })` → liste sports/ligues/events (pré-match uniquement, pas de live)
- `loadTree({ event_id })` → détail event + 300+ marchés + cotes + snapshots + `snapshot_ts` (pour virtuel, stock complet)
- Normalization → schéma interne (`apps/ml-python/app/core/normalizer.py` déjà compatible, adapter mapping exact après 1er JSON réel)
- `createCoupon(draft, stake)` → proxy sécurisé avec revalidation marge ≤5% juste avant envoi + `Idempotency-Key: draft_id`

**Hypothèses explicites (à valider sur 1er payload réel):**
- `loadList` paginé (`page`, `limit`), filtre `is_virtual` bool.
- `loadTree` retourne `markets[].selections[].odds` + `status: active|suspended`.
- Virtuel: `loadList` inclut `round`, `virtual=true`, résultats dans `loadTree.result`.
- Si endpoints différents (`/v1/loadList`), le client détecte via config `BOOKMAKER_API_BASE`.

---

## 4. Modifications apportées au scaffold

1. **Nouveaux fichiers:**
   - `apps/ml-python/app/utils/live_football_client.py` — client réel avec rotation 3 clés
   - `apps/api-node/src/modules/bookmaker/marketing-sport.client.ts` — client réel loadList/loadTree
   - `apps/api-node/src/modules/bookmaker/bookmaker-real.controller.ts` — exemple controller branché au client réel
   - `.env.example` mis à jour avec toutes les variables (sans valeurs)

2. **Modifiés:**
   - `pipelines/etl/ingest_live_football.py` → appelle vrai client si clés présentes, sinon mock
   - `pipelines/etl/ingest_virtual.py` → via `loadList` avec `is_virtual=true`

3. **Non modifié (sécurité):** aucun secret écrit en dur, `.gitignore` protège `.env`.

---

## 5. Prochaines étapes — demande de validation (délicat)

**Je ne lance aucun appel réseau réel sans votre GO.** Dites-moi pour chaque:

1. **Tester auth 1xBet/Méga Pari (loadList) ?** → Oui/Non. Si Oui, je tente `POST /auth/token` puis `loadList(sport=football, league=Premier League)` et vous montre le JSON normalisé (sans logger le secret).
2. **Tester Live Football API (fixtures du jour) ?** → Oui/Non. Si Oui, je tente `GET /fixtures` avec rotation des 3 clés.
3. **Créer un coupon test réel (stake 1 XOF) ?** → **Jamais sans validation explicite** — je demande systématiquement avant tout `createCoupon` impliquant de l'argent.

Répondez simplement: `GO loadList`, `GO live-football`, ou `GO coupon test` pour autoriser.

---

## 6. Utilisation

```bash
# 1. Configurer .env localement (ne pas commit)
cp .env.example .env
# remplir XBET_CLIENT_* / MEGAPARI_CLIENT_* / LIVE_FOOTBALL_API_KEY* avec vraies valeurs

# 2. Lancer en mode réel
docker compose up -d --build
docker compose logs -f api-node  # voir "MarketingSport token OK" sans afficher le token
curl http://localhost:3000/api/v1/health
```

Aucune source gratuite ne sera utilisée — uniquement les 2 providers ci-dessus (plus Live Football pour stats). Chaque décision délicate (changement seuil marge, désactivation marché, création coupon) vous sera soumise avant exécution.
