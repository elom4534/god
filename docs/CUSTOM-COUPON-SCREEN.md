# Écran « Combiné sur mesure » — contrat API & moteur de composition

Écran : `apps/client-flutter/lib/features/coupons/custom_coupon_screen.dart` (onglet **Coupons**).
Backend : `apps/api-node/src/modules/coupons/` (NestJS) + ETL `pipelines/etl/ingest_bookmaker_markets.py`.

---

## 1. Règles produit (version du 20/10/2026)

| Règle | État |
|---|---|
| Nombre de matchs | **1 à 50 maximum** (`MAX_COUPON_MATCHES`, exposé par `max_matches`) — au-delà : `TOO_MANY_MATCHES` |
| Côte totale visée | **libre**, aucune limite (≥ 1.01) |
| Discipline | liste des **sports réels du bookmaker** (répertoire officiel), ou « Tous les sports » |
| Recherche | sur **tous les marchés validés de chaque match** (1X2, Double chance, Handicap, Totaux, BTTS…) |
| Résultat | cote obtenue + **écart en %** avec la cible + drapeau `exact` |
| Code coupon | **UN SEUL code pour tout le combiné** (`couponMode: "COMBO"`) |
| Source des cotes | **LIVE** : relues chez MegaPari à chaque clic (aucun cache métier) |
| Seuil de sécurité | chaque sélection doit avoir **≥ 70 %** de chances de passer (`COUPON_MIN_PROBABILITY`) |
| Jours autorisés | **aujourd'hui** en priorité, **demain** en complément — jamais au-delà (`COUPON_TIMEZONE`, défaut `Africa/Lome`) |

Le moteur ne fabrique jamais de cote : il choisit parmi les cotes réellement proposées.

---

## 1 ter. Fenêtre temporelle : aujourd'hui → demain, jamais plus

Un combiné ne contient que des matchs qui se jouent **aujourd'hui**. Si le
nombre de matchs ou la côte visée n'est pas atteignable, le moteur **élargit à
demain**. Il ne va jamais au-delà.

```
compose(N, cible)
  ├─ tentative 1 : matchs d'AUJOURD'HUI uniquement      → day_scope "TODAY"
  └─ si échec    : matchs d'AUJOURD'HUI + DEMAIN         → day_scope "TODAY_TOMORROW"
                   (et jamais au-delà de demain)
```

- Le jour est calculé dans le **fuseau de l'utilisateur** (`COUPON_TIMEZONE`,
  défaut `Africa/Lome`), pas dans celui du serveur : un match à 00:30 reste
  « aujourd'hui » même si le serveur est encore la veille.
- Un match dont le **coup d'envoi est à moins de 30 minutes** est exclu
  (`COUPON_MIN_LEAD_MINUTES`, défaut `30`). Le coupon est créé en **prematch**
  (`kind=3`) : dès qu'un match bascule en live, MegaPari répond « les
  événements du coupon de paris sont terminés » et le code devient inutilisable.
  La marge de 30 min couvre le temps de génération, de copie et de collage du
  code.
- Réponse : `day_scope`, `day_summary {today, tomorrow}`, `today_events`,
  `tomorrow_events`, `timezone` et `day` (`TODAY` / `TOMORROW`) sur chaque
  sélection. Le libellé devient
  `Combiné 8 matchs (5 aujourd'hui + 3 demain) - Côte 7.99`.
- Si la fenêtre ne fournit aucun match : `NO_MATCH_TODAY_OR_TOMORROW`.

### `GET /api/v1/coupons/window`
Bornes réelles du formulaire (cotes live + seuil 70 %) :

```json
{
  "timezone": "Africa/Lome",
  "as_of": "2026-10-20T22:54:17.193Z",
  "min_probability": 70,
  "today_events": 5,
  "tomorrow_events": 10,
  "max_matches": 15,
  "picks": { "TODAY": 27, "TOMORROW": 43 },
  "events_fetched": 400,
  "validated_markets": 1011
}
```

L'écran Flutter affiche « 5 match(s) aujourd'hui · 10 demain » et plafonne le
champ « Nombre de matchs » à `max_matches`.

> **Pourquoi la fenêtre est courte.** Le flux prematch MegaPari renvoie les
> matchs **par ordre chronologique** : une requête `Count=400` couvre environ
> 8 jours (mesuré : 5 matchs le jour même, 74 le lendemain, puis les jours
> suivants). Le plafond de matchs d'aujourd'hui + demain vient de la densité
> réelle du calendrier à cet instant, pas d'une limite du moteur.

---

## 1 bis. Comment les marchés sont choisis (résumé opérationnel)

```
CLIC « Générer »
  ├─ LoadSingle v2 chez MegaPari  → événements + cotes DU MOMENT
  ├─ regroupement en marchés      → 1X2, Double chance, Handicap, Totaux
  ├─ Margin Guard (marge ≤ 5 %)   → élimine les marchés incohérents
  ├─ probabilité fair par issue   → p = (1/cote) / Σ(1/cote)   (marge retirée)
  ├─ filtre produit               → on ne garde que p ≥ 70 %
  └─ moteur de composition        → 1 sélection par match, N matchs,
                                    produit des cotes ≈ côte visée
```

Exemple mesuré : **6 matchs visés à 6.78** → obtenu **6.76** (0.27 %), toutes les
sélections entre **70 % et 72 %**.

Contrainte qui en découle : avec 70 % minimum, la cote d'une sélection plafonne
naturellement autour de 1.43. Pour une cible donnée, le nombre de matchs minimal
est donc borné par le haut. L'API ne renvoie pas une erreur muette mais :

```json
{
  "reason_code": "TARGET_UNREACHABLE_AT_MIN_PROBABILITY",
  "message": "Avec 70 % de chances minimum par sélection, 5 matchs plafonnent à une cote de 5.10. Augmente le nombre de matchs à 6 (ou plus) pour viser 6.78.",
  "details": { "min_probability": 70, "requested_matches": 5, "max_reachable_odds": 5.10, "suggested_matches": 6 }
}
```

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
  "total_picks": 2108,
  "margin_threshold": 5,
  "max_matches": 50
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
  "couponMode": "COMBO",
  "label": "Combiné 50 matchs - Côte 4997.59",
  "targetTotalOdds": 5000,
  "totalOdds": 4997.59,
  "gapPercent": 0.05,
  "exact": false,
  "numMatches": 50,
  "sport": null,
  "sports": ["Football"],
  "couponCode": "YZLAH",
  "deepLink": "https://megapari.com/en?coupon-code=YZLAH",
  "message": "Code coupon combiné généré (50 sélections) — code YZLAH",
  "retry_after_seconds": null,
  "source": "live",
  "odds_as_of": "2026-10-20T22:26:41.512Z",
  "min_probability": 70,
  "events_fetched": 400,
  "coupons": [ { "event_id": "*", "market_type": "COMBO", "selection_name": "50 sélections",
                 "odds": 4997.59, "success": true, "couponCode": "YZLAH",
                 "deepLink": "https://megapari.com/en?coupon-code=YZLAH" } ],
  "picks": [ { "event_id": "…", "home": "…", "away": "…", "league": "…",
               "sport_id": 1, "sport_name": "Football",
               "market_type": "OVER_UNDER", "selection_name": "Total (2.5) Over",
               "line": 2.5, "odds": 1.92, "margin_percent": 1.51,
               "probability_percent": 71 } ]
}
```

`couponMode` :
- **`COMBO` (défaut)** — **un seul code coupon pour tout le combiné** : toutes les
  sélections partent dans une seule requête `sharecoupon` (paramètres répétés) ;
- `SINGLE` — 1 seul match (même mécanique, un seul élément) ;
- `PER_PICK` — codes générés côté serveur, un par sélection (option `include_individual_codes: true`) ;
- `NONE` — pas de code (MegaPari indisponible) : la composition reste utilisable.

Erreurs :
| Code | HTTP | Sens |
|---|---|---|
| `TOO_MANY_MATCHES` | 400 | `num_matches > max_matches` (`details: {max, requested}`) |
| `B2B_RATE_LIMITED` | 400 | créneau occupé (1 code / minute) → `retry_after_seconds` |

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
| 50 matchs → 5000 | 4997.59 | 0.05 % | — (code `YZLAH` / `LMSAH`) |

> 50 matchs = plafond produit. Une demande à 51 est refusée (`TOO_MANY_MATCHES`),
> côté API comme dans le formulaire (`Maximum 50 matchs`).

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

## 5. Code coupon combiné (vérifié le 20/10/2026)

Le manager MegaPari a confirmé que la génération d'un code pour un combiné est autorisée.
Vérification faite sur la passerelle BetB2B : `sharecoupon` **accepte les paramètres
répétés** et renvoie un vrai code combiné.

```
GET {gateway}/datafeed/directories/api/v1/sharecoupon
    ?ref=192
    &sportEventId=A&type=1&oddsMarket=1.229&parameter=0&playerId=0
    &sportEventId=B&type=1&oddsMarket=1.291&parameter=0&playerId=0
    &kind=3&gr=0&cnt=0&lng=en
→ "https://megapari.com/en?coupon-code=XXXXX"
```

**Les cinq champs d'une sélection sont un bloc positionnel** :
`sportEventId`, `type`, `oddsMarket`, `parameter`, `playerId`. Ils sont émis
**systématiquement, dans cet ordre, pour chaque sélection** (valeur `0` par
défaut). Un bloc incomplet décale la correspondance des blocs suivants : le
coupon pointe alors vers de mauvais marchés et MegaPari le déclare « terminé ».
Les sélections sont triées (`event`, `type`, `parameter`) pour que deux
combinés identiques produisent exactement la même requête.

- La réponse est une **chaîne JSON entre guillemets** ; `coupon-code=` est extrait.
- 50 sélections tiennent dans **une seule requête** (testé : cotes 1.04 → 1.29, code `RYZ1H`).
- Le endpoint **ne valide rien** (un `type` inexistant renvoie quand même un code) :
  la validation métier reste côté composition (marge, marchés réels).
- `couponCode` est renvoyé avant la liste des sélections dans l'UI : plus besoin de
  faire défiler 50 lignes pour récupérer le code.

### Cotes live vs cache

| | Avant | Maintenant |
|---|---|---|
| source | cache Redis ETL (10 min) | **LoadSingle v2 au clic** (`live-odds.ts`) |
| fraîcheur | jusqu'à 15 min (TTL) | quelques secondes |
| probabilité | non calculée (choix « au plus proche de la cible ») | **fair odds**, filtre ≥ 70 % |
| panne bookmaker | on servait du cache périmé | erreur explicite `LIVE_FEED_UNAVAILABLE`, **jamais de cote périmée** |

Le cache Redis reste utilisé **uniquement** pour les compteurs d'affichage
(`/coupons/sports`, disponibilité) — jamais pour composer un combiné.

### Limite de débit : 1 code / minute

| Constat | Correctif |
|---|---|
| 2 créations rapprochées → 400 « LiveBetService returned 200 » | **créneau partagé** Redis `bookmaker:share-slot:megapari` (`MEGAPARI_SHARE_INTERVAL_MS`, 65 s) |
| Bloquer la requête pour attendre = coupure du proxy Alwaysdata (~30 s) | l'API répond **en < 1 s** avec `retry_after_seconds` |
| L'utilisateur devait recliquer | l'app **attend le délai en affichant un compte à rebours**, puis relance automatiquement (3 essais max) |

Cache : clé `bookmaker:combo:megapari:{ref}:{sha1(ref|sélections)}` — TTL 15 min, donc un
combiné identique réutilise son code sans re-solliciter la passerelle.

### Pourquoi MegaPari répondait « les événements du coupon de paris sont terminés »

| Cause | Correctif |
|---|---|
| le combiné pouvait contenir un match **déjà en live** (seul un match commencé depuis > 10 min était filtré) | marge de **30 min** avant le coup d'envoi (`COUPON_MIN_LEAD_MINUTES`) |
| blocs `sportEventId/type/oddsMarket` émis **sans** `parameter`/`playerId` pour les 1X2 → risque de décalage des blocs | bloc positionnel complet (5 champs) pour **chaque** sélection |
| ordre des paramètres variable d'une requête à l'autre | tri déterministe des sélections avant émission |

Vérifié le 20/10/2026 à 23:12 UTC : `GET /coupons/window` renvoie
`min_lead_minutes: 30`, `today_events: 0` (tous les matchs du jour étaient à
moins de 30 min du coup d'envoi), `tomorrow_events: 10`. Le combiné généré
(`H9UFH`, 3 sélections, cote 1.90, `day_scope TODAY_TOMORROW`) ne contient que
des matchs du lendemain à 19:00 UTC, soit ~20 h de marge.

## 6. Robustesse B2B (découvertes du 20/10/2026)

| Constat | Correctif |
|---|---|
| `getAccessToken` → HTTP 400 | décoder `&amp;` dans `client_secret` |
| `setEx` « Invalid argument type » | signature `setEx(key, ttl, value)` |
| `GET sharecoupon` → 400 « LiveBetService returned 200 » alors que curl passe | en-tête `Accept: */*` obligatoire |
| 400 sur tous les appels pendant ~1 min | créneau 1 code/65 s + `retry_after_seconds` + reprise auto côté app |
| mêmes sélections re-testées sans fin | cache coupon 15 min |
| deux combinés distincts recevaient **le même code** | clé de cache tronquée (base64 90 car.) → **SHA-1** de la signature complète |
