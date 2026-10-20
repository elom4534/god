#!/bin/bash
# Script de déploiement Alwaysdata via GitHub (à exécuter en local ou sur Alwaysdata)
# Usage: chmod +x scripts/alwaysdata-deploy.sh && ./scripts/alwaysdata-deploy.sh

set -e
echo "=== Déploiement Pred App → Alwaysdata via GitHub ==="

# ---------------------------------------------------------------------------
# 1. Vérifications locales
# ---------------------------------------------------------------------------
if [ ! -d ".git" ]; then
  echo "Initialisation Git..."
  git init
  git add .
  git commit -m "Initial commit: Pred App (MegaPari + Flutter)"
  echo "→ Créez un repo sur https://github.com/new (nom: pred-app)"
  echo "→ Puis: git remote add origin git@github.com:VOTRE_USER/pred-app.git"
  echo "→       git branch -M main && git push -u origin main"
  exit 0
fi

# Vérifier remote
if ! git remote | grep -q origin; then
  echo "❌ Aucun remote 'origin' configuré"
  echo "   git remote add origin git@github.com:VOTRE_USER/pred-app.git"
  exit 1
fi

echo "Remote: $(git remote get-url origin)"
echo "Branche: $(git rev-parse --abbrev-ref HEAD)"
echo "Dernier commit: $(git log --oneline -1)"

# ---------------------------------------------------------------------------
# 2. Push GitHub
# ---------------------------------------------------------------------------
echo ""
read -p "Pousser vers GitHub ? (o/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[oOyY]$ ]]; then
  git add -A
  git status
  read -p "Message de commit (Entrée pour 'deploy: mise à jour'): " MSG
  MSG=${MSG:-"deploy: mise à jour $(date -u +%Y-%m-%d)"}
  git commit -m "$MSG" || echo "Rien à committer"
  git push origin main
  echo "✅ Push GitHub OK — GitHub Actions va déclencher le deploy Alwaysdata"
else
  echo "Push annulé"
fi

# ---------------------------------------------------------------------------
# 3. Instructions Alwaysdata
# ---------------------------------------------------------------------------
cat <<'EOS'

=== Suite sur Alwaysdata (https://admin.alwaysdata.com) ===

1. Base de données:
   - PostgreSQL → Créer base "preddb" → noter DATABASE_URL
   - Redis → Activer Redis → noter REDIS_URL

2. Sites:
   - Site 1 (API Node): Type Node.js, chemin ~/sites/pred-app/apps/api-node, Node 20, commande: npm start
     Env: DATABASE_URL, REDIS_URL, MEGAPARI_*, LIVE_FOOTBALL_*, JWT_SECRET, etc. (copier .env.example)
   - Site 2 (ML Python): Type Python, chemin ~/sites/pred-app/apps/ml-python, Python 3.11, commande: uvicorn app.main:app --host 0.0.0.0 --port $PORT
     Même Env
   - Site 3 (Flutter Web): Type Fichiers statiques, chemin ~/www/pred-flutter, URL www.votre-domaine.alwaysdata.net

3. SSH:
   - Générer clé: ssh-keygen -t ed25519 -f ~/.ssh/alwaysdata_pred
   - Ajouter clé publique dans Alwaysdata > Compte > Clés SSH
   - Ajouter secrets GitHub: SSH_HOST (ssh-xxx.alwaysdata.net), SSH_USER (xxx), SSH_KEY (clé privée)

4. Premier clone sur Alwaysdata (via SSH):
   ssh xxx@ssh-xxx.alwaysdata.net
   mkdir -p ~/sites && cd ~/sites
   git clone git@github.com:VOTRE_USER/pred-app.git pred-app
   cd pred-app && cp .env.example .env && nano .env  # remplir secrets
   psql $DATABASE_URL -f db/migrations/001_megapari_schema.sql
   psql $DATABASE_URL -f db/migrations/002_post_match_stats.sql
   # Déploiements suivants: git pull (auto via GitHub Actions)

Voir docs/DEPLOY-ALWAYSDATA.md pour le détail complet.
EOS
