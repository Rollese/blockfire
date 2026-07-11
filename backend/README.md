# Blockfire Stats Backend (P1 — ingest + DB)

Python/FastAPI + PostgreSQL ingest service for match/event data. See the design spec
`docs/superpowers/specs/2026-07-11-stats-analytics-backend-design.md`.

> **For agents doing game work:** this directory is out of scope — see the root `AGENTS.md`.

## Run (dev, on game2 or locally)
```bash
cd backend
export INGEST_TOKEN=dev-secret
docker compose up --build       # db + api (:8000) + worker
curl -s localhost:8000/healthz  # {"status":"ok"}
```

## Test
```bash
cd backend
docker compose up -d db
export DATABASE_URL='postgresql+asyncpg://blockfire:blockfire@localhost:5432/blockfire_stats'
export INGEST_TOKEN='test-token'
pip install -e '.[dev]'
python -m pytest -v
```
