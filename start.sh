#!/bin/bash
set -x
echo "START $(date) IP=$IP PORT=$PORT PWD=$(pwd)"
ls -la /home/god/start.sh 2>&1 | head
ls -la apps/ml-python/app/main.py 2>&1 | head
HOST=${IP:-0.0.0.0}
PORT=${PORT:-8100}
if [ -n "$IP" ]; then HOST="$IP"; fi
echo "Launching uvicorn on $HOST:$PORT"
cd /home/god/apps/ml-python
exec python -m uvicorn app.main:app --host "$HOST" --port "$PORT" --log-level info
