#!/bin/bash
set -e
exec > /tmp/start.log 2>&1
set -x
echo "=== START $(date) ==="
echo "IP=$IP PORT=$PORT PWD=$(pwd) USER=$(whoami)"
ls -la
ls -la apps/ml-python/app/main.py || echo "main.py missing"
echo "HOST=${IP:-0.0.0.0} PORT=${PORT:-8100}"
HOST=${IP:-0.0.0.0}
PORT=${PORT:-8100}
if [ -n "$IP" ]; then HOST="$IP"; fi
cd /home/god/apps/ml-python 2>/dev/null || cd apps/ml-python 2>/dev/null || cd "$(dirname "$0")/apps/ml-python"
echo "cd to $(pwd) ls:"
ls -la
echo "starting uvicorn..."
exec python -m uvicorn app.main:app --host "$HOST" --port "$PORT" --log-level debug
