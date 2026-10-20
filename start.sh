#!/bin/bash
set -x
echo "START $(date) IP=$IP PORT=$PORT PWD=$(pwd)"
export DATABASE_URL="${DATABASE_URL:-postgresql://preduser:predpass@localhost:5432/preddb}"
export REDIS_URL="${REDIS_URL:-redis://localhost:6379}"
export LIVE_FOOTBALL_API_KEY="${LIVE_FOOTBALL_API_KEY:-mock}"
export LIVE_FOOTBALL_API_KEY_2="${LIVE_FOOTBALL_API_KEY_2:-mock}"
export LIVE_FOOTBALL_API_KEY_3="${LIVE_FOOTBALL_API_KEY_3:-mock}"
export MEGAPARI_CLIENT_ID="${MEGAPARI_CLIENT_ID:-mock_id}"
export MEGAPARI_CLIENT_SECRET="${MEGAPARI_CLIENT_SECRET:-mock_secret}"
export JWT_SECRET="${JWT_SECRET:-dev-secret-alwaysdata}"
PORT=${PORT:-8100}
HOST=${IP:-0.0.0.0}
if [ -n "$IP" ]; then HOST="$IP"; fi
echo "DB=$DATABASE_URL"
echo "Launching uvicorn on $HOST:$PORT"
cd /home/god/apps/ml-python
exec python3 -m uvicorn app.main:app --host "$HOST" --port "$PORT" --log-level info
