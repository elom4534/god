#!/bin/bash
set -x
echo "START $(date) IP=$IP PORT=$PORT PWD=$(pwd) USER=$(whoami)"
ls -la /home/god/apps/ml-python/app/main.py 2>&1 | head
HOST=0.0.0.0
PORT=${PORT:-8100}
echo "Launching uvicorn on $HOST:$PORT"
cd /home/god/apps/ml-python
exec python3 -m uvicorn app.main:app --host "$HOST" --port "$PORT" --log-level info
