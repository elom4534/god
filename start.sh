#!/bin/bash
set -e
HOST=${IP:-0.0.0.0}
PORT=${PORT:-8100}
echo "Starting god on $HOST:$PORT"
cd /home/god/apps/ml-python
pip install -r requirements.txt > /tmp/pip.log 2>&1 || true
exec uvicorn app.main:app --host $HOST --port $PORT
