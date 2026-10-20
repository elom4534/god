# Écran « Combiné sur mesure » — contrat API & moteur de composition

Écran : `apps/client-flutter/lib/features/coupons/custom_coupon_screen.dart` (onglet **Coupons**).
Backend : `apps/api-node/src/modules/coupons/` (NestJS) + ETL `pipelines/etl/ingest_bookmaker_markets.py`.

---

## 1. Règles produit (version du 20/10/2026)

| Règle | État |
|---|---|
| Nombre de matchs | **libre**, aucune limite produit (seule contrainte : matchs réellement disponibles) |
| Côte totale visée | **libre**, aucune limite (≥ 1.01) |
| Discipline | liste des **sports réels du bookmaker** (répertoire officiel), ou « Tous les sports » |
| Recherche | sur **tous les marchés validés de chaque match** (1X2, Double chance, Handicap, Totaux, BTTS…) |
| Résultat | cote obtenue + **écart en %** avec la cible + drapeau `exact` |

Le moteur ne fabrique jamais de cote : il choisit parmi les cotes réellement proposées.

---

## 2. Endpoints

### `GET /api/v1/coupons/sports`
Répertoire officiel (`/datafeed/directories/api/v2/sports`) enrichi du nombre de matchs disponibles.

```json
{
  "sports": [
    { "id": 1,  "name": "Football",   "events": 167, "picks": 1987, "available": true },
    { "id": 2,  "name": "Ice Hockey", "events": 13,  "picks": 129,  "available": true },
    { "id": 9,  "name": "Boxing",     "events": 0,   "picks": 0,    "available": false }
  ],
  "total_events": 180,
  "total_picks": 2116,
  "margin_threshold": 5
}
```

### `GET /api/v1/coupons/value-picks/availability?sport_id=1`
```json
{ "events": 167, "picks": 1987, "sport_id": 1, "margin_threshold": 5 }
```

### `POST /api/v1/coupons/generate-combined`
```json
{ "num_matches": 30, "target_total_odds": 1000, "sport_id": 1 }
```
Réponse :
```json
{
  "success": true,
  "couponMode": "NONE",
  "label": "Combiné 30 matchs - Côte 1000.29",
  "targetTotalOdds": 1000,
  "totalOdds": 1000.29,
  "gapPercent": 0.03,
  "exact": false,
  "numMatches": 30,
  "sport": 1,
  "sports": ["Football"],
  "couponCode": null,
  "deepLink": "https://megapari.com/en",
  "message": "Composition prête — ouvre MegaPari et ajoute les sélections.",
  "coupons": [],
  "picks": [ { "event_id": "…", "home": "…", "away": "…", "league": "…",
               "sport_id": 1, "sport_name": "Football",
               "market_type": "OVER_UNDER", "selection_name": "Total (2.5) Over",
               "line": 2.5, "odds": 1.92, "margin_percent": 1.51 } ]
}
```

`couponMode` :
- `SINGLE` — 1 seul match : vrai code coupon + deep link pré-rempli ;
- `NONE` — composition seule (N > 1) : l'utilisateur demande le code sélection par sélection ;
- `PER_PICK` — codes générés côté serveur (option `include_individual_codes: true`).

### `POST /api/v1/coupons/pick-code`
```json
{ "event_id": "761655009", "selection_id": "761655009_OVER_UNDER_main_3.5_ou_over" }
```
→ `{ "success": true, "couponCode": "MN6TG", "deepLink": "https://megapari.com/en?coupon-code=MN6TG" }`

---

## 3. Moteur de composition

Espace logarithmique (`ln(a·b) = ln a + ln b`) : le produit des cotes devient une somme,
ce qui rend la recherche d'une cible exacte numériquement stable.

1. **Pool** : toutes les sélections des marchés validés (marge ≤ seuil) du cache
   `megapari:event:*`, filtrées par discipline si demandée. Parcours par `SCAN`
   (non bloquant), pas `KEYS`.
2. **Initialisation** : cible par match = `target^(1/N)` ; on retient les N matchs dont
   la meilleure sélection (tous marchés confondus) est la plus proche de cette valeur.
3. **Amélioration par coordonnée** : à chaque passe, pour chaque position *i* on calcule
   la cote idéale `cote_i × (cible / produit courant)` puis on cherche **par dichotomie**
   la sélection la plus proche de cette cote :
   - parmi les autres marchés du même match ;
   - parmi les matchs non encore utilisés.
4. **Sortie de blocage** : échange simultané de deux positions.
5. Répétition jusqu'à stabilité, exactitude, ou `min(60, max(12, 4·N))` passes.

La composition s'exécute **au clic sur « Générer »** : c'est à ce moment que tous les
marchés disponibles de chaque match sont parcourus.

### Résultats mesurés (pool réel du 20/10/2026)

| Demande | Obtenu | Écart | Exact |
|---|---|---|---|
| 3 matchs → 6.78 | 6.78 | 0.00 % | ✅ |
| 1 match → 2.37 | 2.37 | 0.00 % | ✅ |
| 5 matchs → 12 | 12.00 | 0.00 % | ✅ |
| 8 matchs → 25 | 25.12 | 0.47 % | — |
| 12 matchs → 100 | 99.99 | 0.01 % | — |
| 30 matchs → 1000 | 1000.29 | 0.03 % | — |
| 50 matchs → 5000 | 5018.51 | 0.37 % | — |
| 120 matchs → 50000 | 49800.15 | 0.40 % | — |

---

## 4. Fraîcheur du pool

Le cache Margin Guard a un TTL de **15 min**. Deux mécanismes le maintiennent :

1. **Rafraîchissement automatique côté edge** (`apps/ml-python/app/edge.py`) :
   l'ETL est relancé au démarrage puis toutes les **10 min** (`ETL_REFRESH_INTERVAL`),
   en tâche de fond, sans bloquer le site.
2. **ETL manuel** : `python pipelines/etl/ingest_bookmaker_markets.py --provider megapari --limit 400`
   (~8 s pour 400 événements, 968 marchés validés).

L'ETL interroge `Count` (max 1000) sur LoadSingle, récupère le **répertoire des sports**
(`directories/api/v2/sports`, 33 disciplines) et étiquette chaque événement
(`sport_id`, `sport_name`), ce qui rend le cache filtrable par discipline.

---

## 5. Limite MegaPari (inchangée)

`sharecoupon` (BetB2B) ne crée **qu'un coupon par marché** : aucun endpoint « combiné »
n'est documenté. Le produit ne fabrique donc pas de faux code combiné — composition
réelle + un code par sélection, généré à la demande.

---

## 6. Robustesse B2B (découvertes du 20/10/2026)

| Constat | Correctif |
|---|---|
| `getAccessToken` → HTTP 400 | décoder `&amp;` dans `client_secret` |
| `setEx` « Invalid argument type » | signature `setEx(key, ttl, value)` |
| `GET sharecoupon` → 400 « LiveBetService returned 200 » alors que curl passe | en-tête `Accept: */*` obligatoire |
| 400 sur tous les appels pendant ~1 min | throttle 20 s + cooldown 60 s sur `B2B_RATE_LIMITED` |
| mêmes sélections re-testées sans fin | cache coupon 15 min |
