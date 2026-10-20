.PHONY: up down build logs psql redis-clean test lint

up:
	docker compose up -d --build

down:
	docker compose down

build:
	docker compose build

logs:
	docker compose logs -f

logs-api:
	docker compose logs -f api-node

logs-ml:
	docker compose logs -f ml-python

psql:
	docker exec -it pred_postgres psql -U preduser -d preddb

redis-cli:
	docker exec -it pred_redis redis-cli

test-ml:
	cd apps/ml-python && pytest -v

test-api:
	cd apps/api-node && npm test

migrate:
	docker exec pred_api_node npm run migration:run || echo "no migrations yet"

seed:
	curl -X POST http://localhost:3000/events/ingest -H "Content-Type: application/json" -d @pipelines/etl/fixtures/sample_events.json || true

lint:
	cd apps/api-node && npm run lint || true
	cd apps/ml-python && ruff check . || true
