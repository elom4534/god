# Mise en ligne Alwaysdata via GitHub — Guide complet

> **Cible:** `pred-app` (NestJS + FastAPI + Flutter Web + PostgreSQL + Redis) → `alwaysdata.net`
> **Méthode:** GitHub (source de vérité) → SSH `git pull` + rebuild auto via GitHub Actions

---

## Architecture Alwaysdata

```
GitHub (main) ──push──► GitHub Actions ──SSH──► Alwaysdata
                                           │
                        ┌──────────────────┼──────────────────┐
                        │                  │                  │
                Site Node.js          Site Python        Site statique
                api.*.alwaysdata.net  ml.*.alwaysdata.net  www.*.alwaysdata.net
                (NestJS :3000)         (FastAPI :8000)      (Flutter Web build)
                        │                  │                  │
                        └──────────────────┼──────────────────┘
                                           │
                                    PostgreSQL + Redis
                                    (gérés Alwaysdata)
```

**Pourquoi 3 sites:** Alwaysdata isole chaque technologie (Node, Python, statique) — plus stable que 1 seul Docker.

---

## Étape 1 — Préparer le repo GitHub (local)

```bash
# Depuis /home/user (où se trouve déjà le projet)
chmod +x scripts/alwaysdata-deploy.sh
./scripts/alwaysdata-deploy.sh
# → Si pas de .git: le script init, commit, et vous guide
# → Si déjà git: il push sur main

# Manuelllement:
git init
git add .
git commit -m "Initial commit: Pred App MegaPari (ref=192) + Flutter"
git remote add origin git@github.com:VOTRE_USER/pred-app.git
git branch -M main
git push -u origin main
```

**Vérifier `.gitignore`:** `.env` est ignoré (secrets jamais sur GitHub) — seul `.env.example` est versionné.

---

## Étape 2 — Créer les ressources Alwaysdata

Connectez-vous à `https://admin.alwaysdata.com` (offre 100 Mo gratuit ou payant).

### 2.1 Bases de données

1. **PostgreSQL:** `Bases de données > PostgreSQL > Créer`
   - Nom: `preddb` — notez l'URL `postgres://xxx:xxx@pg-xxx.alwaysdata.net/preddb`
   - Exécuter les migrations après clone:
     ```bash
     psql $DATABASE_URL -f db/migrations/001_megapari_schema.sql
     psql $DATABASE_URL -f db/migrations/002_post_match_stats.sql
     ```

2. **Redis:** `Services > Redis` (ou `Bases de données > Redis` selon offre) → Créer → notez `redis://:xxx@redis-xxx.alwaysdata.net:6379`

### 2.2 Sites

Créez **3 sites** (Menu `Sites > Ajouter un site`):

| Site | Type | Chemin | Commande / Config | URL |
|------|------|--------|------------------|-----|
| **API Node** | Node.js | `~/sites/pred-app/apps/api-node` | `Node 20`, `npm ci && npm run build && npm start` <br> Port `3000` (variable `$PORT` fournie) | `https://api.votre-domaine.alwaysdata.net` |
| **ML Python** | Python | `~/sites/pred-app/apps/ml-python` | `Python 3.11`, `pip install -r requirements.txt && uvicorn app.main:app --host 0.0.0.0 --port $PORT` | `https://ml.votre-domaine.alwaysdata.net` |
| **Flutter Web** | Fichiers statiques | `~/www/pred-flutter` | Aucune commande — sert le `build/web` | `https://www.votre-domaine.alwaysdata.net` |

> **Alternative Docker:** Si votre offre Alwaysdata supporte Docker (plan privé), vous pouvez créer 1 seul site Docker avec `docker-compose.yml` (Postgres + Redis inclus). Sinon, utilisez les 3 sites séparés ci-dessus.

### 2.3 Variables d'environnement

Pour **chaque site Node/Python**, ajoutez dans `Sites > Votre site > Environnement`:

```
DATABASE_URL=postgres://...
REDIS_URL=redis://...
JWT_SECRET=CHANGEZ_MOI_64_CHARS
MEGAPARI_CLIENT_ID=partners-c2b75a07c454fcd96f0453a0f79e1ead
MEGAPARI_CLIENT_SECRET=***
MEGAPARI_REF=192
MEGAPARI_AFFILIATE_TAG=s_23283m_355c_
XBET_CLIENT_ID=partners-592d3a39b56e7ca211a846129d6fc5e3
XBET_CLIENT_SECRET=***
XBET_REF=1
LIVE_FOOTBALL_API_KEY=***
LIVE_FOOTBALL_API_KEY_2=***
LIVE_FOOTBALL_API_KEY_3=***
LIVE_FOOTBALL_BASE_URL=https://live-football-api.com
MEGAPARI_GR=0
MEGAPARI_CNT=0
BOOKMAKER_API_BASE=https://cpservm.com/gateway/marketing
```

**Ne jamais committer `.env`** — Alwaysdata le gère via son interface.

---

## Étape 3 — SSH + GitHub Secrets

### 3.1 Clé SSH

Sur votre machine locale:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/alwaysdata_pred -C "pred-app@alwaysdata"
cat ~/.ssh/alwaysdata_pred.pub  # copier
```
- Alwaysdata: `Compte > Clés SSH > Ajouter` → coller la clé publique
- Test: `ssh VOTRE_USER@ssh-VOTRE_USER.alwaysdata.net` → doit connecter sans mot de passe

### 3.2 GitHub Secrets

Dans GitHub: `Votre repo > Settings > Secrets and variables > Actions > New repository secret`:

| Secret | Valeur | Exemple |
|--------|--------|---------|
| `SSH_HOST` | Hôte SSH Alwaysdata | `ssh-votreuser.alwaysdata.net` |
| `SSH_USER` | Login Alwaysdata | `votreuser` |
| `SSH_KEY` | Clé privée **entière** (cat ~/.ssh/alwaysdata_pred) | `-----BEGIN OPENSSH PRIVATE KEY-----...` |

---

## Étape 4 — Premier clone sur Alwaysdata

En SSH sur Alwaysdata:
```bash
ssh VOTRE_USER@ssh-VOTRE_USER.alwaysdata.net
mkdir -p ~/sites ~/www
cd ~/sites
git clone git@github.com:VOTRE_USER/pred-app.git pred-app
cd pred-app
# Créer .env à partir de l'exemple + remplir
cp .env.example .env
nano .env  # remplir DATABASE_URL, REDIS_URL, MEGAPARI_*, etc.

# Première install manuelle (ensuite auto via GitHub Actions)
cd apps/api-node && npm ci && npm run build && cd ../..
cd apps/ml-python && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && cd ../..
# Migrations
psql $DATABASE_URL -f db/migrations/001_megapari_schema.sql
psql $DATABASE_URL -f db/migrations/002_post_match_stats.sql

# Flutter Web initial (buildé par GitHub Actions, mais on peut aussi builder ici)
# sera déployé via rsync par le workflow
mkdir -p ~/www/pred-flutter && echo "ok" > ~/www/pred-flutter/index.html
```

---

## Étape 5 — Déploiement automatique (GitHub → Alwaysdata)

Désormais, chaque `git push` sur `main` déclenche `.github/workflows/deploy-alwaysdata.yml`:

1. **Tests** (pytest, lint)
2. **Build Flutter Web** (`flutter build web --wasm`)
3. **Deploy SSH:**
   - `git fetch && git reset --hard origin/main`
   - `npm ci && npm run build && touch tmp/restart.txt` (Node)
   - `pip install -r requirements.txt && touch tmp/restart.txt` (Python)
   - `psql` migrations
   - `rsync` Flutter `build/web` → `~/www/pred-flutter`

**Manuel:**
```bash
git add .
git commit -m "deploy: nouvelle feature"
git push origin main
# → Voir progression: GitHub > Actions > Deploy to Alwaysdata
```

**Sans GitHub Actions (fallback):** Sur Alwaysdata, `cd ~/sites/pred-app && git pull && ./scripts/alwaysdata-deploy.sh` suffit.

---

## Étape 6 — Vérification

```bash
# API
curl https://api.votre-domaine.alwaysdata.net/api/v1/health
curl https://api.votre-domaine.alwaysdata.net/api/v1/megapari/coupon/generate -X POST -H "Content-Type: application/json" -d '{"picks":[...]}' | jq

# ML
curl https://ml.votre-domaine.alwaysdata.net/health
curl https://ml.votre-domaine.alwaysdata.net/ml/v1/megapari/health

# Flutter
open https://www.votre-domaine.alwaysdata.net
# → Vérifier que l'app charge, que le Code Coupon s'affiche et que le bouton Copier fonctionne
```

Logs Alwaysdata: `Sites > Votre site > Logs` ou `~/sites/pred-app/apps/api-node/logs/`

---

## Domaine personnalisé (optionnel)

`Sites > Votre site > Adresses` → Ajouter `www.votredomaine.com` → configurer DNS `CNAME` vers `votre-domaine.alwaysdata.net` → SSL auto via Let's Encrypt.

---

## Coûts Alwaysdata

- **Gratuit:** 100 Mo, 1 site, 1 DB PostgreSQL, pas de Redis (utiliser Upstash Redis gratuit externe à la place)
- **Payant (recommandé):** Dès 6€/mois → 1 Go, 3 sites, Redis inclus, support

Pour Redis gratuit externe si offre gratuite: `https://upstash.com` → créer Redis → copier `REDIS_URL` dans Alwaysdata.

---

## Checklist finale

- [ ] Repo GitHub créé + push `main`
- [ ] PostgreSQL + Redis créés sur Alwaysdata
- [ ] 3 sites créés (Node, Python, statique)
- [ ] Env vars configurées dans Alwaysdata
- [ ] SSH clé ajoutée (Alwaysdata + GitHub Secrets)
- [ ] Premier `git clone` + `.env` + migrations sur Alwaysdata
- [ ] Push test → GitHub Actions vert → sites accessibles
