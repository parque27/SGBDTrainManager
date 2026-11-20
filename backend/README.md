# OCEMT backend (FastAPI)

Python server between the web app and the databases.

```
Web ──► FastAPI ──► Redis (cache, read first)
                 └► PostgreSQL + PostGIS (source of truth, read on a cache miss)
```

**Cache-aside:** every cached endpoint calls `cache.get_or_set(key, loader, ttl)`.
It returns the value from Redis if it is there (`X-Cache: HIT`); otherwise it runs the loader
against PostgreSQL, stores the result in Redis with a TTL and returns it (`X-Cache: MISS`).
If Redis is down the loader is used, so the API keeps working (only slower) and `/health` returns 503.

## Run it

From the repository root (Docker Desktop running):

```bash
cp .env.example .env          # first time only
docker compose up -d --build
docker compose ps             # backend, postgres and redis: running (healthy)
```

- API: http://localhost:8080 (`BACKEND_PORT`), interactive docs at http://localhost:8080/docs
- The code in `backend/` is mounted in the container and uvicorn reloads on every change.

### Load the data (first time, or after `docker compose down -v`)

Compose does not load the train data by itself. Load the `import` schema (about 10 s):

```bash
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f /data/load/create_import_tables.sql -f /data/load/load.sql'
```

(In Git Bash on Windows, prefix it with `MSYS_NO_PATHCONV=1`.)

## Endpoints

| Endpoint | What it does |
|---|---|
| `GET /health` | Checks PostgreSQL (with PostGIS version) and Redis. 200 if both answer, 503 otherwise. |
| `GET /routes` | Example cached endpoint: all lines from `import.routes`. `X-Cache` header says HIT or MISS. |

## Tests

```bash
docker compose exec backend pytest
```

- `tests/test_cache.py`: the cache-aside helper (hit, miss, TTL, Redis down), no databases needed.
- `tests/test_integration.py`: `/health` and `/routes` against the real PostgreSQL and Redis.

## Layout

```
backend/
├── app/
│   ├── main.py         FastAPI app, opens/closes the connections (lifespan), CORS
│   ├── config.py       settings from environment variables / .env
│   ├── db.py           PostgreSQL async connection pool (psycopg 3)
│   ├── cache.py        Redis client + get_or_set (cache-aside)
│   └── routers/        one file per group of endpoints
└── tests/
```

To add a cached endpoint: write the SQL in a loader function and wrap it with `cache.get_or_set`
(see `app/routers/routes.py`). The final tables will live in the `public` schema (KAN-9);
until then the queries read `import.*`.
