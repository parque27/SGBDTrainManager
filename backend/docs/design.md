# Backend design (KAN-14)

How the FastAPI server works inside and where it meets the work of the rest of the team.
Status: **proposal for review** (Luchaco: Redis parts, Joan: PostgreSQL parts).

## 1. Who owns what

| Part | Owner | What the server gets from it |
|---|---|---|
| `public` schema, `db/init/` (KAN-9) | Joan | Tables, geometry, indexes, `train_reliability()` |
| Replay + Redis (KAN-11) | Luchaco | Live state of the trains, key contract [`redis/docs/modelo-de-claves.md`](../../redis/docs/modelo-de-claves.md), read recipes [`redis/docs/recetario-backend.md`](../../redis/docs/recetario-backend.md) |
| Docker compose (KAN-7) | Pau | Services, healthchecks, production compose |
| **FastAPI server** | Oriol | Reads both databases and exposes the API the web uses |

The server **never writes the live state** and **does not own the clock**. The replay (its own container) owns the
simulated clock in memory and publishes every minute to Redis. The only thing the server writes for the replay
is `sim:control` (pause / speed / seek).

## 2. Two kinds of time

| | Live view | Time travel |
|---|---|---|
| What | "Now" of the simulation, like a real live app | Any minute of the 5 recorded days |
| Shared? | Yes, one clock for everybody | No, each user picks their own moment |
| Source | Redis (`sim:snapshot` and the other live keys) | PostgreSQL (`public.positions`, ...) |
| If the source is missing | **503**, never a frozen or invented map | 503 only if PostgreSQL is down |

Time travel never touches the replay. Pause / speed / seek of the shared clock are meant for whoever presents the
demo (admin panel or the API), not for every visitor.

## 3. Request flow

```
                    ┌──────────────── FastAPI ────────────────┐
 web ──HTTP──► routers/ ──► services/ ─┬─► live/ ─────────────┼──► Redis  (replay keys: read only,
   ▲                                   │                      │           sim:control: write)
   │                                   ├─► cache.get_or_set ──┼──► Redis  (cache:v1:*)
   │                                   │        │ miss        │
   │                                   │        ▼             │
   │                                   └─► repositories/ ─────┼──► PostgreSQL / PostGIS (public.*)
   └──── SSE /live/events ◄── live/events ◄── SUBSCRIBE ocemt:clock ◄── replay
```

## 4. Code layout

```
backend/app/
├── main.py            app, lifespan (pool + Redis), CORS, error handlers
├── config.py          settings (.env / environment)
├── db.py              PostgreSQL pool, fetch_all / fetch_one
├── cache.py           query cache: get_or_set, invalidate              (Redis keys cache:v1:*)
├── live/              read module for the replay's keys                (Redis, read only + sim:control)
│   ├── snapshot.py    sim:snapshot → typed model, version check, filters (bbox, line, service)
│   ├── trains.py      train:{id}, trail:{id}, trains:geo, trains:by_delay, idx:trains
│   ├── control.py     validate + HSET sim:control
│   └── events.py      SUBSCRIBE ocemt:clock → SSE
├── repositories/      SQL only, one file per area, returns dicts       (no Redis, no HTTP)
├── services/          logic: picks the source, builds cache keys, GeoJSON
├── schemas/           Pydantic response models (= the contract with the web, visible in /docs)
└── routers/           HTTP only: parameters, status codes, response_model
```

Rules: routers never run SQL or Redis commands; repositories never know about Redis; `cache.py` (query cache) and
`live/` (replay state) share the Redis connection but not their code or keys.

## 5. Endpoints and data source

Names are a proposal; prefixes group them by source. TTL = query cache (`cache:v1:{query}:{params}`).

### Live (Redis, 503 if `sim:snapshot` does not exist)

| Endpoint | Redis | Notes |
|---|---|---|
| `GET /clock` | `JSON.GET sim:snapshot $.simulated_at $.status $.speed $.range $.snapshot_id $.published_at` | |
| `POST /clock` `{status?, speed?, seek?}` | `HSET sim:control` | **202**: the replay applies it within 0.5 s and announces it on `ocemt:clock`. Validation: status `playing`/`paused`, speed 1–600, seek = whole minute in UTC inside `range` (422 otherwise) |
| `GET /live/events` (SSE) | `SUBSCRIBE ocemt:clock` | Forwards the JSON message (`simulated_at`, `status`, `speed`, `snapshot_id`). The web fetches the map only when `simulated_at` changes |
| `GET /live/positions?bbox=&line=&service=` | `JSON.GET sim:snapshot` | GeoJSON FeatureCollection, filtered in Python (≈200 trains, ~87 KB) |
| `GET /trains/{train_id}` | `HGETALL train:{id}` | "El meu tren". 404 if it is not running this minute |
| `GET /trains/{train_id}/trail` | `LRANGE trail:{id} 0 -1` | Last 30 positions (pending in Luchaco's next PR) |
| `GET /trains/near?lon=&lat=&radius_km=` | `GEOSEARCH trains:geo` | |
| `GET /trains/delayed?limit=` | `ZRANGE trains:by_delay … REV` | |
| `GET /trains/search?q=&service=&line=&next_station=&train_number=` | `FT.SEARCH idx:trains` | Also "trains approaching a station" (`next_station`) |
| `GET /incidents/active` | `JSON.GET sim:incidents` | Pending in Luchaco's next PR |
| `GET /stats/lines/{op}/{line}/delay` | `TS.RANGE ts:delay:line:…` (+ `ts:delay_max:…`) | Only the minutes already replayed; full days come from PostgreSQL |

When several live keys are read for one answer: `pipeline(transaction=True)` so they all belong to the same minute.
If `sim:snapshot.version` is not `1`: log it and answer 503 instead of reading fields wrongly.

### Time travel and reference data (PostgreSQL + query cache)

| Endpoint | PostgreSQL | TTL |
|---|---|---|
| `GET /meta` | data window, credits, `DATA_SOURCE` | 1 h |
| `GET /routes` (exists) | `public.routes` | 1 h |
| `GET /routes/{route_id}/shape` | `public.trips` → `public.shapes` (GeoJSON) | 1 h |
| `GET /stations?bbox=` | `public.stations` (GeoJSON, `province`) | 1 h |
| `GET /stations/autocomplete?q=` | Redis `FT.SEARCH idx:stations` (no cache needed) | – |
| `GET /tracks?bbox=` | `public.tracks` (bbox **required**, simplified geometry) | 1 h |
| `GET /positions?at=&bbox=` | `public.positions WHERE time = :minute` | 5 min |
| `GET /trains/{train_id}/track?from=&to=` | `public.positions` | 5 min |
| `GET /trips/{trip_id}` | `public.trips` + `stop_times` + observed arrivals | 1 h |
| `GET /trips/{trip_id}/delays` | `public.trip_delays` | 1 h |
| `GET /stations/{station_id}/departures?at=` | day timetable (`stop_times`, index `(station_id, departure_time)`, PR #8) cached, + live delays `HMGET live:delays` | 1 h (timetable) |
| `GET /trains/by-number/{train_number}/reliability?days=` | `public.train_reliability(train_number, days)` (PR #8), days 1–4 | 1 h |
| `GET /incidents?from=&to=&route_id=` | `public.incidents` | 1 h |
| `GET /alerts?at=` | alerts (not in `public` yet, see §8) | 1 h |

The recorded data never changes, so TTLs only limit memory (`maxmemory 256mb`, `volatile-lru`), not freshness.

## 6. Cache keys

`cache:v1:{query}:{normalised params}`, e.g. `cache:v1:positions:2026-11-05T07:00Z:2.10,41.30,2.25,41.45`.

- Times: UTC, truncated to the minute (the data is minute by minute).
- bbox: `min_lon,min_lat,max_lon,max_lat`, checked and rounded to 2 decimals (~1 km) to limit the number of keys.
- Results are encoded once with `jsonable_encoder`, so a MISS and a HIT return the same JSON.
- Empty results are cached too (`[]`); errors are not.
- Anti-stampede lock (`lock:{key}`, recipe 11) only if the benchmark shows concurrent misses hurt.
- `v1` goes to `v2` when a response format changes: the old keys expire alone.

## 7. Errors and degradation

| Situation | Answer |
|---|---|
| Bad parameter (bbox order, time outside 2026-11-01T23:00Z → 2026-11-06T23:00Z, speed) | 422 |
| Unknown id | 404 |
| Live key missing / replay stopped / unknown snapshot version | 503 |
| PostgreSQL down or still running `db/init` | 503 (after 5 s, pool timeout) |
| Redis down | query cache → PostgreSQL directly; live endpoints → 503 |

Redis down today costs ~6 s per request (connect timeouts). Fix: after a Redis error, skip Redis for a few seconds
(simple circuit breaker in `cache.py` / `live/`), so requests go straight to PostgreSQL.

All times in responses are UTC ISO-8601. Error body: FastAPI's `{"detail": ...}`.

## 8. Open points

- **ACL**: the backend connects as user `backend` when `REDIS_BACKEND_PASSWORD` is set in `.env` (already optional
  in this PR); Luchaco enables it in a later PR.
- **Tables not in `public`**: alerts, alert_targets, cancellations, occupancy, stop_arrivals. Read from `import.*`
  meanwhile, or Joan adds them (KAN-9)?
- **Provinces**: many trains have no `province` until the province boundaries are in PostgreSQL (PR #8).
- **Who presses the clock buttons**: admin panel vs. any visitor (proposal: admin only).

## 9. Implementation plan (one ticket per PR, created after this design is reviewed)

| PR | Scope | Depends on |
|---|---|---|
| 1 | API foundations (layers, schemas, validation, errors, `/meta`) + reference data: routes, shapes, stations, autocomplete, tracks | this design |
| 2 | Live: `/clock` GET/POST, `/live/events`, `/live/positions`, `/trains/{id}`, near, delayed, search | 1, Luchaco's new fields for some filters |
| 3 | Time travel + trips: `/positions?at=`, `/trains/{id}/track`, `/trips/*`, departures, reliability | 1, PR #8 |
| 4 | Events + stats: incidents (active + history), alerts, delay charts, trail | 2, Luchaco's `trail:*` / `sim:incidents` |
| 5 | Hardening: Redis circuit breaker, rate limit, CI pytest, Redis vs PostgreSQL benchmark, `EXPLAIN ANALYZE`, production compose | 2, 3 |
