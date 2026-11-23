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

### Data

PostgreSQL loads the data by itself the first time it starts with an empty volume
(`db/init/`: PostGIS, the `import` schema, then the `public` schema). The API reads `public.*`.

If your `pg-data` volume was created before `db/init/` existed, recreate it once:

```bash
docker compose down -v
docker compose up -d --build
```

## Endpoints

| Endpoint | What it does |
|---|---|
| `GET /health` | Checks PostgreSQL (with PostGIS version) and Redis. 200 if both answer, 503 otherwise. |
| `GET /routes` | Example cached endpoint: all lines from `public.routes`. `X-Cache` header says HIT or MISS. |

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
(see `app/routers/routes.py`). Queries read the `public` schema (KAN-9).
Cache keys follow the Redis contract in [`redis/docs/modelo-de-claves.md`](../redis/docs/modelo-de-claves.md):
`cache:v1:{query}:{parameters}`.
