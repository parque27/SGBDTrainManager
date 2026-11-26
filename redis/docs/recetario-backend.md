# Recetario de Redis para el backend

Para cada cosa que necesita la web: qué clave de Redis la resuelve, el comando y el código Python listo
para copiar. Es el complemento de [`modelo-de-claves.md`](modelo-de-claves.md) (qué hay) con el **cómo
leerlo**.

Todo el código usa el cliente async del backend, `r = cache.get_redis()` (redis-py, `decode_responses=True`).
**Probado** con el docker-compose y el replay funcionando, desde el contenedor `backend`. Los tiempos son
medidos ahí.

| # | En la web | Endpoint sugerido | Redis | Medido |
|---|---|---|---|---|
| 1 | Mapa en vivo | `GET /live/snapshot` | `JSON.GET sim:snapshot` | 7 ms, ~75 KB |
| 2 | Reloj, pausa, velocidad, ir a una hora | `GET /clock`, `POST /clock` | `JSON.GET … $.status`, `HSET sim:control` | |
| 3 | Trenes cerca de un punto / en una zona | `GET /trains/near` | `GEOSEARCH trains:geo` | |
| 4 | Los más retrasados | `GET /trains/delayed` | `ZRANGE trains:by_delay … REV` | |
| 5 | Trenes de una línea | `GET /lines/{op}/{line}/trains` | `SMEMBERS line:…:trains` | |
| 6 | Buscador, autocompletar estaciones, retraso por línea | `GET /trains/search`, `GET /stations/autocomplete`, `GET /stats/lines` | `FT.SEARCH`, `FT.AGGREGATE` | 2,6 ms |
| 7 | Gráficas de retraso del día | `GET /stats/lines/{op}/{line}/delay` | `TS.RANGE`, `TS.MRANGE … GROUPBY` | |
| 8 | Últimas incidencias / worker de alertas | `GET /incidents` | `XREVRANGE`, `XREADGROUP` + `XACK` | |
| 9 | Trenes distintos hoy | `GET /stats/today` | `PFCOUNT hll:trains:{día}` | |
| 10 | La web se actualiza sola | `GET /live/events` (SSE) | `SUBSCRIBE ocemt:clock` | |
| 11 | Consultas pesadas a Postgres | (todas) | caché + candado `SET NX PX` / `DELEX IFEQ` | 20 a la vez → 1 consulta |
| 12 | Límite de peticiones | middleware | `INCREX` | |
| 13 | Panel de salidas de una estación | `GET /stations/{id}/departures` | caché del horario + `HMGET live:delays` | 50 ms → 3 ms |

Los nombres de los endpoints son una propuesta: los decide el backend.

## Reglas generales

- **Lo "en vivo" solo está en Redis.** Si no existe `sim:snapshot`, el replay no está funcionando: 503. Si
  Redis no responde (`RedisError`), también 503, como ya se hace con Postgres (`PoolTimeout`).
- **"Ahora" es `sim:clock`** (tiempo simulado), nunca `datetime.now()`. Todas las horas van en UTC
  (`2026-11-05T07:00:00Z`); el frontend las pasa a hora de Barcelona.
- **Varias claves del mismo minuto**: léelas en una transacción, `r.pipeline(transaction=True)`. Si se
  leen por separado, el replay puede cambiar de minuto entre una lectura y otra.
- **Detalles de varios trenes**: `HGETALL` de todos en un pipeline (un solo viaje de red). Si uno vuelve
  vacío, ese tren acaba de desaparecer: se salta.
- En los `train:*` todo es texto (`"1500"`); en la foto los números ya son números.
- Las líneas pueden tener espacios y puntos (`AVANT EXP`, `REG.EXP.`): en el buscador hay que escaparlas
  (`tag()` más abajo) y en las URL codificarlas (`AVANT%20EXP`).
- Nunca `KEYS`: si hace falta recorrer claves, `SCAN`.

### Utilidades (las usan las recetas)

```python
import asyncio, json, re, secrets
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi.encoders import jsonable_encoder
from redis.asyncio import Redis
from redis.commands.search import reducers
from redis.commands.search.aggregation import AggregateRequest, Desc
from redis.commands.search.query import Query
from redis.exceptions import RedisError, ResponseError

MADRID = ZoneInfo("Europe/Madrid")


def as_dt(value) -> datetime:
    """Fecha de Redis/Postgres a datetime (acepta datetime, '…Z' y '… 07:00:00+00:00')."""
    if isinstance(value, datetime):
        return value
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tag(value: str) -> str:
    """Escapa un valor para un campo TAG del buscador ('AVANT EXP' -> 'AVANT\\ EXP')."""
    return re.sub(r"([^\w])", r"\\\1", value)


async def sim_now(r: Redis) -> datetime | None:
    clock = await r.get("sim:clock")
    return as_dt(clock) if clock else None


async def with_details(r: Redis, train_ids: list[str]) -> list[dict]:
    """HGETALL de varios trenes en un solo viaje (pipeline). Vacío = el tren acaba de desaparecer."""
    async with r.pipeline(transaction=False) as pipe:
        for train in train_ids:
            pipe.hgetall(f"train:{train}")
        rows = await pipe.execute()
    return [{"train_id": t, **h} for t, h in zip(train_ids, rows) if h]
```

---

## 1. Mapa en vivo

```
JSON.GET sim:snapshot
```

La foto ya es JSON: se devuelve **tal cual, sin parsearla** (ni `json.loads` ni volver a serializar 75 KB).

```python
async def snapshot_raw(r: Redis) -> str | None:
    return await r.execute_command("JSON.GET", "sim:snapshot")


@router.get("/live/snapshot")
async def live_snapshot():
    raw = await snapshot_raw(cache.get_redis())
    if raw is None:
        raise HTTPException(503, "El replay no está funcionando (no hay sim:snapshot)")
    return Response(raw, media_type="application/json")
```

Formato: [`modelo-de-claves.md`](modelo-de-claves.md#simsnapshot-la-foto-del-minuto). Para no pedirla si
no ha cambiado, el frontend puede comparar `snapshot_id`, o escuchar el aviso de la receta 10.

## 2. Reloj y control de la simulación

```
JSON.GET sim:snapshot $.simulated_at $.status $.speed $.range     # solo esos campos, no el mapa
HSET sim:control status paused | speed 60 | seek 2026-11-05T07:00:00Z
DEL sim:control                                                    # volver a lo del .env
```

```python
async def clock(r: Redis) -> dict | None:
    res = await r.json().get("sim:snapshot", "$.simulated_at", "$.status", "$.speed", "$.range")
    if not res:
        return None
    return {path[2:]: values[0] for path, values in res.items()}


async def set_control(r: Redis, status: str | None = None, speed: float | None = None,
                      seek: datetime | None = None) -> None:
    fields = {}
    if status is not None:
        fields["status"] = status
    if speed is not None:
        fields["speed"] = speed
    if seek is not None:
        fields["seek"] = iso(seek)
    if fields:
        await r.hset("sim:control", mapping=fields)


class ControlIn(BaseModel):
    status: Literal["playing", "paused"] | None = None
    speed: float | None = Field(None, ge=1, le=600)  # 30 = un minuto cada 2 s
    seek: datetime | None = None                     # con zona: "2026-11-05T07:00:00Z"


@router.post("/clock", status_code=204)
async def control_clock(body: ControlIn):
    await set_control(cache.get_redis(), body.status, body.speed, body.seek)
```

- El replay mira `sim:control` cada medio segundo: tras un `POST`, en ≤ 0,5 s la foto ya dice el estado nuevo.
- `seek` estando en pausa: salta a ese minuto y **sigue en pausa** (como un vídeo).
- `range` de la foto da los límites para un selector de hora.

## 3. Trenes cerca de un punto o dentro de una zona

```
GEOSEARCH trains:geo FROMLONLAT 2.17 41.387 BYRADIUS 5 km ASC COUNT 10 WITHDIST
GEOSEARCH trains:geo FROMLONLAT 2.17 41.39 BYBOX 10 6 km
```

```python
async def trains_near(r: Redis, lon: float, lat: float, km: float = 5, limit: int = 10) -> list[dict]:
    near = await r.geosearch("trains:geo", longitude=lon, latitude=lat, radius=km, unit="km",
                             sort="ASC", count=limit, withdist=True)
    trains = await with_details(r, [train for train, _ in near])
    dist = dict(near)
    return [{**t, "distance_km": dist[t["train_id"]]} for t in trains]


async def trains_in_box(r: Redis, lon: float, lat: float, width_km: float, height_km: float) -> list[str]:
    return await r.geosearch("trains:geo", longitude=lon, latitude=lat,
                             width=width_km, height=height_km, unit="km")
```

Probado: a 5 km de plaça Catalunya, el más cercano a 100 m; en una caja de 10×6 km, 50 trenes.
Para pintar el mapa entero es más simple la foto (receta 1). `GEOSEARCH` sirve para "cerca de mí" o para
filtrar en el servidor.

## 4. Los más retrasados

```
MULTI
GET sim:clock
ZRANGE trains:by_delay 0 9 REV WITHSCORES
ZCOUNT trains:by_delay 900 +inf          # cuántos van con más de 15 min
EXEC
```

```python
async def most_delayed(r: Redis, limit: int = 10) -> dict:
    async with r.pipeline(transaction=True) as pipe:  # MULTI: reloj y ranking del mismo minuto
        pipe.get("sim:clock")
        pipe.zrange("trains:by_delay", 0, limit - 1, desc=True, withscores=True)
        pipe.zcount("trains:by_delay", 900, "+inf")
        now, top, over_15_min = await pipe.execute()
    return {"simulated_at": now, "over_15_min": over_15_min,
            "trains": await with_details(r, [train for train, _ in top])}
```

## 5. Trenes de una línea

```
SMEMBERS line:renfe:R2S:trains
```

```python
async def line_trains(r: Redis, operator: str, line: str) -> list[dict]:
    return await with_details(r, sorted(await r.smembers(f"line:{operator}:{line}:trains")))
```

La lista de líneas (para un desplegable) sale de Postgres (`public.routes`), cacheada: ya está en `GET /routes`.

## 6. Buscador (Query Engine)

Los `train:*` y `station:*` están indexados (`idx:trains`, `idx:stations`): se puede filtrar y agregar sin
mantener un Set por cada filtro. `idx:trains` tiene exactamente los trenes del minuto actual (comprobado:
229 en el índice, 229 en la foto).

```
FT.SEARCH idx:trains "@line:{R2S} @delay_s:[300 +inf]" SORTBY delay_s DESC LIMIT 0 20
FT.SEARCH idx:trains "@operator:{fgc} @location:[2.17 41.387 3 km]"
FT.SEARCH idx:stations "barc* sants*" RETURN 2 name operator LIMIT 0 10
FT.AGGREGATE idx:trains "@delay_s:[-inf +inf]" GROUPBY 2 @operator @line
    REDUCE COUNT 0 AS trains REDUCE AVG 1 @delay_s AS avg_delay_s REDUCE MAX 1 @delay_s AS max_delay_s
    SORTBY 2 @avg_delay_s DESC
```

```python
async def search_trains(r: Redis, line: str | None = None, operator: str | None = None,
                        min_delay_s: int | None = None, near: tuple[float, float, float] | None = None,
                        limit: int = 20) -> dict:
    filters = []
    if line:
        filters.append(f"@line:{{{tag(line)}}}")
    if operator:
        filters.append(f"@operator:{{{tag(operator)}}}")
    if min_delay_s is not None:
        filters.append(f"@delay_s:[{int(min_delay_s)} +inf]")
    if near:
        lon, lat, km = near
        filters.append(f"@location:[{lon} {lat} {km} km]")
    query = Query(" ".join(filters) or "*").sort_by("delay_s", asc=False).paging(0, limit)
    res = await r.ft("idx:trains").search(query)
    return {"total": res.total,
            "trains": [{"train_id": d.id.removeprefix("train:"),
                        **{k: v for k, v in vars(d).items() if k not in ("id", "payload")}} for d in res.docs]}


async def stations_autocomplete(r: Redis, text: str, limit: int = 10) -> list[dict]:
    words = re.findall(r"\w{2,}", text)  # el buscador pide al menos 2 letras por prefijo
    if not words:
        return []
    query = Query(" ".join(f"{w}*" for w in words)).return_fields("name", "operator").paging(0, limit)
    res = await r.ft("idx:stations").search(query)
    return [{"station_id": d.id.removeprefix("station:"), "name": d.name, "operator": d.operator} for d in res.docs]


async def delay_by_line(r: Redis) -> list[dict]:
    # Solo trenes con delay_s: una línea sin ningún dato daría media "nan" y rompería el orden
    req = (AggregateRequest("@delay_s:[-inf +inf]")
           .group_by(["@operator", "@line"],
                     reducers.count().alias("trains"),
                     reducers.avg("@delay_s").alias("avg_delay_s"),
                     reducers.max("@delay_s").alias("max_delay_s"))
           .sort_by(Desc("@avg_delay_s")))
    res = await r.ft("idx:trains").aggregate(req)
    return [dict(zip(row[::2], row[1::2])) for row in res.rows]
```

Probado:
- Autocompletar: "barc sants" → Barcelona-Sants; "Adri" y "Adrià" → Sant Adrià de Besòs; "pl cat" → las
  dos plaça Catalunya (Renfe y FGC).
- `REG.EXP.` (con puntos) encuentra los mismos 6 trenes que su Set.

## 7. Gráficas de retraso del día (TimeSeries)

```
TS.RANGE ts:delay:line:renfe:R2S <inicio del día> <ahora> AGGREGATION avg 900000
TS.MRANGE <inicio del día> <ahora> AGGREGATION avg 1800000 FILTER metric=avg_delay GROUPBY operator REDUCE avg
```

```python
async def line_delay_today(r: Redis, operator: str, line: str, bucket_min: int = 15) -> list[dict]:
    now = await sim_now(r)
    start = datetime.combine(now.astimezone(MADRID).date(), time.min, MADRID)
    try:
        points = await r.ts().range(f"ts:delay:line:{operator}:{line}",
                                    int(start.timestamp() * 1000), int(now.timestamp() * 1000),
                                    aggregation_type="avg", bucket_size_msec=bucket_min * 60_000)
    except ResponseError:  # la línea aún no ha salido en esta ejecución del replay
        return []
    return [{"time": iso(datetime.fromtimestamp(ms / 1000, timezone.utc)), "avg_delay_s": round(v)}
            for ms, v in points]


async def operator_delay_today(r: Redis, bucket_min: int = 30) -> dict:
    now = await sim_now(r)
    start = datetime.combine(now.astimezone(MADRID).date(), time.min, MADRID)
    res = await r.ts().mrange(int(start.timestamp() * 1000), int(now.timestamp() * 1000),
                              filters=["metric=avg_delay"], aggregation_type="avg",
                              bucket_size_msec=bucket_min * 60_000, groupby="operator", reduce="avg")
    out = {}
    for item in res:
        for name, (_labels, points) in item.items():  # name = "operator=renfe"
            out[name] = [{"time": iso(datetime.fromtimestamp(ms / 1000, timezone.utc)), "avg_delay_s": round(v)}
                         for ms, v in points]
    return out
```

- Siempre **hasta `sim:clock`**, no hasta `+`: tras un salto atrás, las series tienen puntos "del futuro".
- Las series solo tienen lo que el replay ya ha reproducido (7 días de retención). Para el histórico
  completo de días pasados, Postgres.

## 8. Incidencias (Stream)

```
XREVRANGE events:trains + - COUNT 500
```

```python
async def latest_incidents(r: Redis, limit: int = 20) -> list[dict]:
    now = await r.get("sim:clock")
    entries = await r.xrevrange("events:trains", count=500)
    # Solo las de hoy hasta ahora: tras un salto atrás, el stream tiene incidencias "del futuro"
    today = [{"id": entry_id, **f} for entry_id, f in entries if f["time"][:10] == now[:10] and f["time"] <= now]
    return today[:limit]
```

**Worker de alertas** (opcional): un grupo de consumidores reparte las incidencias entre workers. Cada una
la procesa uno solo y se confirma con `XACK`; si un worker cae, lo no confirmado queda en `XPENDING`.

```python
async def alerts_worker(r: Redis, group: str = "alerts", consumer: str = "worker-1", rounds: int = 1,
                        start_id: str = "$") -> int:
    """start_id al crear el grupo: "$" = solo las nuevas, "0" = desde la primera que haya."""
    try:
        await r.xgroup_create("events:trains", group, id=start_id, mkstream=True)
    except ResponseError as exc:
        if "BUSYGROUP" not in str(exc):
            raise
    handled = 0
    for _ in range(rounds):
        res = await r.xreadgroup(group, consumer, {"events:trains": ">"}, count=10, block=1000)
        for _stream, messages in res or []:
            for entry_id, fields in messages:
                handled += 1  # aquí: avisar, guardar en Postgres, …
                await r.xack("events:trains", group, entry_id)
    return handled
```

Probado: 30 incidencias procesadas y confirmadas, 0 pendientes.

## 9. Trenes distintos hoy (HyperLogLog)

```
PFCOUNT hll:trains:2026-11-05
```

```python
async def distinct_trains_today(r: Redis) -> int:
    now = await sim_now(r)
    return await r.pfcount(f"hll:trains:{now.astimezone(MADRID).date().isoformat()}")
```

El día es el de Barcelona. Ocupa ≤ 12 KB por día, con ~0,8 % de error.

## 10. La web se actualiza sola (Pub/Sub → SSE)

Cada vez que el replay escribe un minuto, publica la hora en `ocemt:clock`. El backend lo reenvía al
navegador con *Server-Sent Events* y el navegador vuelve a pedir la foto.

```python
async def clock_events(r: Redis, is_disconnected):
    pubsub = r.pubsub()
    await pubsub.subscribe("ocemt:clock")
    try:
        while not await is_disconnected():
            # get_message con timeout: no choca con el socket_timeout=2 del cliente si nadie publica
            msg = await pubsub.get_message(ignore_subscribe_messages=True, timeout=1.0)
            if msg:
                yield f"data: {msg['data']}\n\n"
    finally:
        await pubsub.unsubscribe("ocemt:clock")
        await pubsub.aclose()


@router.get("/live/events")
async def live_events(request: Request):
    return StreamingResponse(clock_events(cache.get_redis(), request.is_disconnected),
                             media_type="text/event-stream")
```

```js
// Frontend
new EventSource("http://localhost:8080/live/events").onmessage = () => refreshMap();
```

Ojo: con `async for … in pubsub.listen()`, el `socket_timeout=2` del cliente da error cuando pasan 2 s sin
mensajes (en pausa, por ejemplo). Con `get_message(timeout=…)` no pasa: probado con 4 s de pausa.

## 11. Caché de Postgres con candado anti-estampida

Propuesta para sustituir `get_or_set` en `app/cache.py`. Hace dos cosas más que la actual:
- **Candado**: si llegan 20 peticiones a la vez y la caché está vacía, solo una consulta Postgres; las
  demás esperan y leen la caché.
- **`jsonable_encoder`**: fechas y decimales salen igual en un MISS que en un HIT.

```python
async def get_or_set(key: str, loader, ttl: int | None = None):
    redis = get_redis()
    lock, token = f"lock:{key}", secrets.token_hex(8)
    try:
        for _ in range(50):  # como mucho ~5 s esperando a que otro rellene la caché
            cached = await redis.get(key)
            if cached is not None:
                return json.loads(cached), "cache"
            if await redis.set(lock, token, nx=True, px=5000):
                try:
                    value = jsonable_encoder(await loader())
                    await redis.set(key, json.dumps(value), ex=ttl or _default_ttl)
                    return value, "database"
                finally:
                    # DELEX … IFEQ (Redis 8.4): borra el candado solo si sigue siendo nuestro
                    await redis.execute_command("DELEX", lock, "IFEQ", token)
            await asyncio.sleep(0.1)
    except RedisError as exc:
        log.warning("Redis failed for %s, falling back to PostgreSQL: %s", key, exc)
    return jsonable_encoder(await loader()), "database"
```

- El candado caduca solo a los 5 s (`PX 5000`) por si el proceso muere con él puesto.
- El token y `DELEX … IFEQ` evitan borrar el candado de otro si la consulta tarda más de 5 s. Antes de
  Redis 8.4 esto pedía un script de Lua.

Probado: 20 peticiones a la vez → 1 consulta a Postgres y 19 desde la caché, todas con el mismo
resultado, y el candado borrado al final. (Los tests de `test_cache.py` usan un `FakeRedis` que habría que
ampliar con `set(nx, px)` y `execute_command`.)

## 12. Límite de peticiones por IP

```
INCREX ratelimit:api:{ip} BYINT 1 UBOUND 120 EX 60 ENX     ->  [cuenta, 1] aceptada | [cuenta, 0] rechazada
```

Un solo comando atómico (Redis 8.8): incrementa, comprueba el límite y pone la caducidad la primera vez.

```python
async def allow_request(r: Redis, client_ip: str, per_minute: int = 120) -> bool:
    try:
        _count, accepted = await r.execute_command("INCREX", f"ratelimit:api:{client_ip}", "BYINT", 1,
                                                   "UBOUND", per_minute, "EX", 60, "ENX")
    except RedisError:
        return True  # sin Redis no se limita
    return bool(accepted)


@app.middleware("http")
async def rate_limit(request: Request, call_next):
    if not await allow_request(cache.get_redis(), request.client.host):
        return JSONResponse({"detail": "Too many requests"}, status_code=429, headers={"Retry-After": "60"})
    return await call_next(request)
```

Probado con límite 3: `[True, True, True, False, False]`.

## 13. Panel de salidas de una estación (Postgres + Redis)

Junta lo mejor de cada base de datos:
- **El horario** (`stop_times`) no cambia: se pide a Postgres una vez por estación y día y se cachea 1 h.
- **El retraso** sí cambia cada minuto: se pide a Redis en el momento, todos los viajes en un solo `HMGET`.

```python
DEPARTURES_SQL = """
    SELECT st.trip_id, st.departure_time, t.headsign, r.short_name AS line, r.color, r.operator
    FROM public.stop_times st
    JOIN public.trips t ON t.trip_id = st.trip_id
    JOIN public.routes r ON r.route_id = t.route_id
    WHERE st.station_id = %(station)s
      AND st.departure_time >= %(start)s AND st.departure_time < %(end)s
    ORDER BY st.departure_time"""


async def departures(r: Redis, station_id: str, limit: int = 10) -> dict:
    now = await sim_now(r)
    day = now.astimezone(MADRID).date()
    start = datetime.combine(day, time.min, MADRID)

    schedule, source = await cache.get_or_set(
        f"cache:v1:departures:{station_id}:{day}",
        lambda: db.fetch_all(DEPARTURES_SQL, {"station": station_id, "start": start, "end": start + timedelta(days=1)}),
        ttl=3600)

    # Desde hace 1 h (un tren con retraso aún puede no haber salido) hasta dentro de 3 h
    upcoming = [s for s in schedule
                if now - timedelta(hours=1) <= as_dt(s["departure_time"]) <= now + timedelta(hours=3)]
    delays = await r.hmget("live:delays", [s["trip_id"] for s in upcoming]) if upcoming else []
    board = []
    for s, delay in zip(upcoming, delays):
        planned = as_dt(s["departure_time"])
        estimated = planned + timedelta(seconds=int(delay or 0))
        if estimated >= now:
            board.append({**s, "departure_time": iso(planned), "delay_s": int(delay) if delay else None,
                          "estimated": iso(estimated)})
    board.sort(key=lambda d: d["estimated"])
    return {"simulated_at": iso(now), "departures": board[:limit]}
```

- Probado en Barcelona-Sants (~1.000 salidas al día): 50 ms la primera vez (Postgres) y 3 ms después
  (caché). Sale, por ejemplo, un R16 previsto a las 07:12 con 20 min de retraso, estimado a las 07:32
  (horas en UTC).
- `delay_s: null` = ese viaje no tiene dato en vivo ahora (aún no ha empezado o ya ha terminado).
- Por eso no hay una clave `station:{id}:departures`: un Sorted Set con las salidas estimadas habría que
  rehacerlo cada minuto. Así, lo que no cambia se cachea y lo que cambia se lee en el momento.
