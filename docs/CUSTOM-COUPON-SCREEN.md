# Écran « Combiné sur mesure » — contrat API & intégration Flutter

Écran : `apps/client-flutter/lib/features/coupons/custom_coupon_screen.dart`
Onglet **Coupons** de l'application (remplace l'ancien écran de draft).

---

## 1. Ce que fait l'écran

1. **Formulaire** (`Form` + validation) :
   - **Nombre de matchs** — défaut `3`, bornes `1 … max_matches`.
   - **Côte totale visée** — défaut `2.5`, bornes `1.01 … 100000`.
   - Raccourcis (chips) : `2 / 3 / 5 / 7 / 10` matchs, `×2 / ×2.5 / ×5 / ×10 / ×25`.
   - Aperçu live : **cote estimée par match** = `target^(1/N)`.
2. **CTA** « Générer le Code Coupon » avec `CircularProgressIndicator` pendant l'appel.
3. **Résultat** : libellé `Combiné {N} matchs - Côte {Y}`, cote totale réelle, liste des
   sélections (équipes, compétition, marché, cote, marge), puis :
   - **1 match** → `CouponCodeCard` (code en gros, Copier, Ouvrir MegaPari) ;
   - **N matchs** → un **bouton « Obtenir le code » par sélection** (voir §4).
4. **Erreurs** : bandeau explicite (code raison + message actionnable + bouton Réessayer).

---

## 2. Endpoints

### `GET /api/v1/coupons/value-picks/availability`
Appelé à l'ouverture de l'écran — borne le formulaire avant tout appel coûteux.

```json
{ "events": 10, "picks": 158, "max_matches": 10, "margin_threshold": 5 }
```

### `POST /api/v1/coupons/generate-combined`
Corps :
```json
{ "num_matches": 3, "target_total_odds": 6.78 }
```
Champs optionnels : `language` (`en`/`fr`), `include_individual_codes` (`false` par défaut).

Réponse (combiné) :
```json
{
  "success": true,
  "couponMode": "NONE",
  "label": "Combiné 3 matchs - Côte 6.85",
  "totalOdds": 6.85,
  "numMatches": 3,
  "targetTotalOdds": 6.78,
  "couponCode": null,
  "deepLink": "https://megapari.com/en",
  "message": "Composition prête — ouvre MegaPari et ajoute les sélections.",
  "coupons": [],
  "picks": [
    {
      "event_id": "761655009",
      "home": "Sporting Clube de Portugal",
      "away": "LASK Linz",
      "league": "UEFA Champions League",
      "sport": "football",
      "start_time": "2026-10-21T19:00:00+00:00",
      "market_type": "OVER_UNDER",
      "market_id": "761655009_OVER_UNDER_main_3.5",
      "selection_id": "761655009_OVER_UNDER_main_3.5_ou_over",
      "selection_name": "Total (3.5) Over",
      "line": 3.5,
      "odds": 1.858,
      "margin_percent": 1.31
    }
  ]
}
```

Réponse (1 match → vrai coupon) :
```json
{
  "success": true,
  "couponMode": "SINGLE",
  "label": "Combiné 1 matchs - Côte 1.92",
  "couponCode": "1RUTG",
  "deepLink": "https://megapari.com/en?coupon-code=1RUTG",
  "message": "Coupon généré avec succès — Code 1RUTG"
}
```

### `POST /api/v1/coupons/pick-code`
Code coupon d'**une** sélection de la composition (généré à la demande).

```json
{ "event_id": "761655009", "selection_id": "761655009_OVER_UNDER_main_3.5_ou_over" }
```
→ `{ "success": true, "couponCode": "MN6TG", "deepLink": "https://megapari.com/en?coupon-code=MN6TG", "odds": 1.858, ... }`

---

## 3. Composition de l'algorithme

1. Lecture du cache Margin Guard (`megapari:event:{id}`, TTL 15 min) — seules les
   sélections de marchés **marge ≤ 5 %** sont retenues.
2. Cible par match = `target^(1/N)`. Sélection gloutonne de l'événement le plus proche
   **en log-cote**, puis passes d'amélioration locale (échange de sélection ou
   d'événement) tant que l'écart diminue.
3. Une seule sélection par match (règle stricte, vérifiée côté serveur).

---

## 4. Limite MegaPari (important)

`sharecoupon` (BetB2B) **ne crée qu'un coupon par marché**. Il n'existe aucun endpoint
« coupon combiné » documenté. Le produit ne fabrique donc pas de faux code combiné :

| Cas | Comportement |
|-----|--------------|
| 1 match | Vrai coupon : code + deep link pré-rempli |
| N matchs | Composition réelle + libellé + un code **par sélection**, généré au clic |

L'UI affiche une note explicite : *« MegaPari n'autorise la création que d'un code par marché. »*

---

## 5. Robustesse B2B (découverte du 20/10/2026)

| Constat | Correctif |
|---|---|
| `getAccessToken` → HTTP 400 | décoder `&amp;` dans `client_secret` |
| `setEx` « Invalid argument type » | signature `setEx(key, ttl, value)` |
| `GET sharecoupon` → 400 « LiveBetService returned 200 » **alors que curl passe** | en-tête `Accept: */*` obligatoire |
| 400 sur tous les appels pendant ~1 min | throttle 20 s entre appels + cooldown 60 s sur `B2B_RATE_LIMITED` |
| mêmes sélections re-testées sans fin | cache coupon 15 min (clé = event + type + cote + paramètre) |

Le message renvoyé à l'UI est `B2B_RATE_LIMITED` avec `details.retry_after_seconds`,
traduit par « MegaPari limite temporairement la création de codes coupon. Réessaie dans N secondes. »

---

## 6. Rechargement du backend

L'edge FastAPI `/home/god/main.py` surveille le build NestJS :

- **auto-reload** : si `dist/main.js` est plus récent que le process Node, l'edge le
  redémarre (intervalle de chien de garde : 30 s) ;
- **endpoint admin** : `POST /admin/reload` avec l'en-tête `X-Admin-Token: <EDGE_ADMIN_TOKEN>`
  (`EDGE_ADMIN_TOKEN` dans `/home/god/.config/pred-app.env` ; vide = endpoint désactivé).

Sans cela, un `install.sh` seul ne suffisait pas : le process Node restait sur l'ancien build.
