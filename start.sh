#!/bin/bash
set -e
HOST=${IP:-0.0.0.0}
PORT=${PORT:-8100}
echo "Starting god on $HOST:$PORT IP=$IP PORT=$PORT"
cd /home/god/apps/ml-python
exec uvicorn app.main:app --host $HOST --port $PORT --log-level info
