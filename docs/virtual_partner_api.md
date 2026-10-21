# Football Virtuel — Partenaire API MegaPari (contrat réel)

> Étape 0 du module **Football Virtuel temps réel** (FIFA Virtual & Sega Virtual).
> Document de référence : tout le module s'appuie **uniquement** sur ces flux
> réels — aucune donnée simulée, estimée ou codée en dur.

## 1. Accès & authentification

| Élément | Valeur |
|---|---|
| Base API | `https://cpservm.com/gateway/marketing` |
| Token | `POST https://cpservm.com/gateway/token` |
| Flux | OAuth2 `clientCredentials` (corps `x-www-form-urlencoded`) |
| Corps token | `client_id=…&client_secret=…` (**sans** `grant_type`) |
| Jeton | `Bearer` (JWT, `expires_in` ≈ 3600 s, à renouveller) |
| `ref` (partenaire) | `192` (défaut `MEGAPARI_REF`) |

**Piège identifié** : le `client_secret` fourni contient des **entités HTML**
(`&amp;`) ; envoyé tel quel → `400 invalid_client`. Il faut le décoder
(`html.unescape`) et retirer les guillemets englobants (cf. `_secret()` de
`pipelines/etl/ingest_bookmaker_markets.py`).

**Sécurité** : la clé partenaire est lue côté **serveur uniquement**
(`MEGAPARI_PARTNER_API_KEY`, alias accepté `MEGAPARI_CLIENT_SECRET`, et
`MEGAPARI_CLIENT_ID`) via le gestionnaire de secrets
(`/home/god/.config/pred-app.env`, chmod 600). Elle n'est **jamais** exposée à
Flutter, ni commitée, ni journalisée. Toute absence/invalidité produit un
**échec explicite** (exception `PartnerAuthError`, log clair sans la valeur).

## 2. Endpoints utilisés (OpenAPI `openapi.yaml`, 40 endpoints REST)

Aucun WebSocket n'existe dans le contrat → **polling respectueux** (§5).

| Usage | Endpoint | Rate limit officiel |
|---|---|---|
| Rounds à venir + cotes | `GET /datafeed/prematch/api/v2/sportevents` | **1 req / 20 s mêmes params** |
| Rounds en direct | `GET /datafeed/live/api/v2/sportevents` | **1 req / 5 s mêmes params** |
| Résultats (clôture) | `GET /result/api/v1/sportevents` | usage poli (≥ 5 s) |
| Référentiel (dispo) | `GET /datafeed/directories/api/v2/*`, `loadlist/…/GetMarketsGame` | idem |

### 2.1 LoadSingle prematch / live

Paramètres retenus : `ref` (obligatoire), `lng=en`, `sportIds=1`, `count=1000`,
`periods=0`, `schemeOfGettingOddsOperations=GetAllOdds` (prematch) /
`GetMainOdds` (live), et si besoin `tournamentIds=…`.
**Sans `schemeOfGettingOddsOperations`, `oddsLocalization` est vide.**

Réponse : `{ "count": N, "items": [ … ] }`.

Champs exploités par item :

| Champ | Usage |
|---|---|
| `sportEventId` / `constSportEventId` | identifiants (`const…` stable prematch↔live↔résultats) |
| `tournamentId` / `tournamentNameLocalization` | famille provider (§3) |
| `opponent1/2NameLocalization`, `imageOpponent1/2` | équipes (+ logos) |
| `startDate` (epoch s) | `scheduled_start` |
| `oddsLocalization[]` | snapshots de cotes (§4) |
| `curScore{sc1,sc2}`, `fullScore`, `periodScores` | score en direct / final |
| `timeSec`, `currentPeriodName`, `gameStatus` | minute de jeu, période |
| `matchInfoObject.matchFormat` | format réel (ex. « 2 halves of 20 minutes ») |

### 2.2 Résultats

`GET /result/api/v1/sportevents?ref=192&tournamentIds=…&dateFrom=…&dateTo=…`
(epochs ; fenêtre **≥ 1 min, ≤ 48 h**). Réponse `{count, items[]}` :

- `score: "3:2 (3:0,0:2)"` → score final puis scores par période ;
- `constSportEventId`, `startDate`, équipes, `type`, `vid`.
- **Absence de `state`/`resultType`** : les annulations se détectent via le
  flux live/résultat lui-même (ex. forfait non rejoué).

## 3. Classification des providers (aucun ID provider dans le flux)

Tous les rounds virtuels sont sous **`sportId=1` (Football)**, `subSportId=0`.
Deux familles produits, validées avec le commanditaire (21/10/2026) :

| Provider | Famille | Tournois observés (réel) | Équipes |
|---|---|---|---|
| `FIFA_VIRTUAL` | A | `FIFA 27. Amateur daily league` (id **3105089**), `FIFA 23. Volta daily league`, `FC 26. eSports Battle. {World Cup, Bundesliga, CSL, FA Cup, Champions League A/B, Europa League, International A, Seria A, Eredivisie}`, `Esoccer GG League`, `Esoccer Battle Volta` | `Pays/Club (Pseudo joueur)` |
| `SEGA_VIRTUAL` | B | `Virtual eComp. {Premier League (id 2834136), Copa Libertadores (id 2876177), La Liga, Champions League, Serie A, Bundesliga, International, Asian Champions League}` | `Club (virtual_N)`, RNG |

Règle : **classification par regex sur le nom de tournoi**, configurable par
env (`VIRTUAL_FIFA_TOURNAMENTS`, `VIRTUAL_SEGA_TOURNAMENTS`) :

- `SEGA_VIRTUAL` ⇔ `^Virtual eComp\.`
- `FIFA_VIRTUAL` ⇔ `^(FIFA \d+\.|FC \d+\. eSports Battle|Esoccer )`

Cycle d'un round famille B : ~720 s (prém. → live 2×20 min → résultat).

## 4. Cotes (`oddsLocalization[]`) — structure réelle vérifiée

| Champ | Sens réel |
|---|---|
| `type` | type de marché (table ci-dessous) |
| `parameter` | ligne (total/handicap) ou code (correct score `1.002` = 1-2) |
| `oddsMarket` | **cote décimale** (ex. `1.94`) |
| `oddsMarketView` | formats `{'2': américain, '3': décimal}` |
| `display` | libellé réel (« W1 », « Total Over (5.5) », « Both Teams To Score - Yes ») |
| `isBlocked`, `isCenter`, `playerId`, `playerName` | métadonnées |

Mapping `type` (valeurs observées en production) :

| type(s) | Marché (stockage) | Selection |
|---|---|---|
| 1 / 2 / 3 | `1X2` | `1` / `X` / `2` |
| 180 / 181 | `BTTS` | `YES` / `NO` |
| 9 / 10 et **3827 / 3828** | `TOTAL` (**toutes lignes**, `parameter` = ligne) | `OVER` / `UNDER` |
| 7 / 8, 3829 / 3830 | `HANDICAP` | `H1` / `H2` |
| 11–14 | `IND_TOTAL` | `OVER` / `UNDER` |
| 15–23 | `HTFT` | libellé (`W1W1`, `XX`…) |
| 182 / 183 | `ODD_EVEN` | `YES` / `NO` |
| 388–390 | `NEXT_GOAL` | `TEAM1` / `TEAM2` / `NEITHER` |
| 731 | `CORRECT_SCORE` | libellé (`1-2`…) |

Avant chaque round, **chaque snapshot** de ces marchés est stocké
(`virtual_odds_snapshots`) avec double horodatage : `snapshot_at` (UTC serveur
DB) + `source_ts` (horodatage du flux : `startDate`/heure de la réponse) +
`captured_at` (UTC de capture applicative). Toutes les lignes O/U sont
conservées (9/10 + 3827/3828).

## 5. Stratégie de polling (adaptative, respect des rate limits)

| État | Fréquence |
|---|---|
| Normal (rounds à venir loin) | toutes les **60 s** |
| Round dans les **2 dernières minutes** | toutes les **10 s** |
| Rounds en direct | toutes les **10 s** (plancher 5 s imposé) |
| Balayage résultats | toutes les **60 s** |

Garde-fous : verre global inter-appels (≥ 5 s live / ≥ 20 s prematch mêmes
params) ; un seul task asyncio ; backoff exponentiel sur erreurs HTTP ; arrêt
propre si la clé expire (renouvellement auto du token à `expires_in - 60 s`).

Cycle de vie d'un round : `SCHEDULED → LIVE → FINISHED` (+ `CANCELLED`) —
reconstitué à partir du flux uniquement (présence prematch/live, `timeSec`,
clôture via `result/api`).

## 6. Schéma de stockage (migration `004_virtual_football.sql`)

`virtual_rounds`, `virtual_odds_snapshots`, `virtual_live_events`,
`virtual_results`, `virtual_team_ratings` (voir le fichier pour la DDL exacte,
conforme au brief). Lignes `virtual_live_events` : `KICKOFF`, `TICK`,
`GOAL_HOME`, `GOAL_AWAY`, `HALFTIME`, `FULLTIME` — dérivées des écarts de
score réels du flux (jamais inventées).

## 7. Modèle de prédictions (interne)

- **Ratings par provider séparés** (aucun mélange FIFA/Sega) : Elo (K=20,
  multiplicateur de différence de buts) + **Dixon-Coles** (attaque/défense,
  ρ=-0.13, avantage domicile par provider), mis à jour **incrémentalement à
  chaque round FINISHED**.
- **LightGBM** en affinement (mélange 50/50 avec le Poisson Dixon-Coles),
  entraîné sur les rounds terminés seulement ; silencieux si indisponible.
- **Drift detection** : Brier glissant (fenêtre 50 rounds) ; au-delà de
  1,35× la moyenne historique → **reset partiel** (repli des forces vers la
  moyenne du provider) + log.
- **Value bet uniquement si significatif** : `p×cote − 1 ≥ 0,10` **et**
  échantillon ≥ **100 rounds** finis **et** capture réelle ≥ **24 h** ; sinon
  l'API expose `calibration_in_progress: true` et l'UI affiche
  « Calibration en cours » (aucune prédiction exposée).

## 8. Fiabilité Virtuel (écran dédié)

Message affiché (validé le 21/10/2026) :

> Les matchs de football virtuel (FIFA Virtual & Sega Virtual) sont des
> simulations aléatoires (RNG) du bookmaker MegaPari. Aucun modèle ne peut
> prédire leur issue avec certitude. Les probabilités affichées sont des
> statistiques calculées uniquement sur les rounds réellement joués du flux
> partenaire ; elles ne garantissent aucun gain. Les prédictions s'affichent
> uniquement après 24 h de capture réelle et un échantillon suffisant
> (100 rounds).

L'écran affiche aussi la **taille d'échantillon réelle**, l'ancienneté de
capture, l'état de calibration et l'historique des 20 derniers résultats.

## 9. Endpoints internes (FastAPI, avant le catch-all NestJS)

| Route | Rôle |
|---|---|
| `GET /api/v1/virtual/rounds` | rounds (`?provider=&status=&limit=`) |
| `GET /api/v1/virtual/rounds/upcoming` | rounds à venir (tri `scheduled_start`) |
| `GET /api/v1/virtual/rounds/{round_id}/odds-history` | snapshots de cotes |
| `GET /api/v1/virtual/results/recent` | 20 derniers résultats (score exact + BTTS) |
| `GET /api/v1/virtual/predictions/{round_id}` | probabilités + taille d'échantillon + value bets |
| `GET /api/v1/virtual/reliability` | état « Fiabilité Virtuel » |

Enregistrement **impératif** dans `edge.py` **avant** le proxy catch-all
`@app.api_route("/api/v1/{path:path}")`, sinon tout est avalé par NestJS.

## 10. Écrans Flutter

`VirtualLiveBoardScreen` (onglet « Virtuel ») : sélecteur FIFA Virtual /
Sega Virtual, `CountdownClock` synchronisé sur `scheduled_start`, `BentoMatchCard`,
`LiveOddsBadge`, `GlowingConfidenceRing`, 20 derniers résultats (score exact +
BTTS), sous-vue « Fiabilité Virtuel » (§8). **Rafraîchissement par flux
périodique uniquement (zéro bouton manuel).**
