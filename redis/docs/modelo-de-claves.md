# Modelo de claves de Redis

Es el **contrato entre Redis y el backend**: qué hay en Redis, quién lo escribe y quién lo lee.
Si alguien necesita una clave nueva, se añade aquí primero.

## Convenciones

- Formato `entidad:id[:subrecurso]`. Los `:` hacen que Redis Insight agrupe las claves en carpetas.
- Los ids se guardan **tal cual vienen de Postgres**, con su prefijo de operador (`renfe:…`, `fgc:…`).
  Por eso hay claves con varios `:` seguidos, como `train:renfe:5108J25500R2S`.
- Las líneas se identifican por operador + nombre público (`renfe:R2S`, `fgc:S1`), porque varios
  `route_id` (uno por sentido) comparten línea, y FGC y Renfe tienen nombres parecidos.
- Las horas, en UTC como en la base de datos. Epoch en segundos en los Sorted Sets y en milisegundos
  en TimeSeries (es lo que pide cada tipo).
- Las cachés llevan versión (`cache:v1:…`). Si cambia el formato de una respuesta, se sube a `v2`
  y las viejas caducan solas.
- Nada sin caducidad salvo lo que se reconstruye cada minuto o se debe conservar (series, índices).

## Claves

| Clave | Tipo | Caducidad | Escribe | Lee | Para qué |
|---|---|---|---|---|---|
| `sim:clock` | String | — | replay | backend | Minuto simulado actual (`2026-11-05T07:00:00Z`) |
| `train:{train_id}` | Hash | 180 s | replay | backend, `idx:trains` | Estado actual de un tren (campos abajo) |
| `trains:geo` | GEO | se sustituye cada minuto | replay | backend | Trenes dentro del mapa / cerca de un punto |
| `trains:by_delay` | Sorted Set | se sustituye cada minuto | replay | backend | Ranking de retrasos, "cuántos llevan > X" |
| `line:{operador}:{línea}:trains` | Set | se sustituye cada minuto | replay | backend | Trenes de una línea ahora |
| `live:delays` | Hash con TTL por campo | 180 s por campo | replay | backend | Retraso actual por `trip_id` (búsqueda origen → destino) |
| `station:{station_id}` | Hash | — | carga inicial | `idx:stations` | Nombre y posición, para el buscador |
| `station:{station_id}:departures` | Sorted Set | 120 s | backend | backend | Panel de salidas: miembro `trip_id`, puntuación = salida estimada (epoch s) |
| `ts:delay:line:{operador}:{línea}` | TimeSeries | retención 7 días | replay | backend | Retraso medio por línea a lo largo del tiempo |
| `hll:trains:{fecha}` | HyperLogLog | 8 días | replay | backend | Trenes distintos vistos en un día |
| `events:trains` | Stream | `MAXLEN ~ 10000` | replay | worker de alertas, backend | Incidencias detectadas (retraso grande, parada larga) |
| `cache:v1:{consulta}:{parámetros}` | String (JSON) | 1 h | backend | backend | Resultado de una consulta pesada a Postgres |
| `lock:{clave de caché}` | String | 5 s | backend | backend | Candado anti-estampida al rellenar una caché |
| `ratelimit:api:{ip}` | String (`INCREX`) | 60 s | backend | backend | Límite de peticiones por IP |
| canal `ocemt:clock` | Pub/Sub | — | replay | backend | Aviso de "hay minuto nuevo" para refrescar la web |
| `idx:trains`, `idx:stations` | Índices de búsqueda | — | se crean al arrancar | backend | Filtros, búsquedas geográficas y agregaciones |

### Campos de `train:{train_id}`

Vienen de `public.positions` más los nombres de `routes` y `stations` (desnormalizados a propósito,
para que el backend lo tenga todo con un solo `HGETALL`).

| Campo | Ejemplo | Origen |
|---|---|---|
| `trip_id` | `renfe:5108J25500R2S@2026-11-05` | `positions.trip_id` |
| `line` | `R2S` | `routes.short_name` |
| `operator` | `renfe` | `positions.operator` |
| `color` | `146520` | `routes.color` |
| `lat`, `lon` | `41.384972`, `2.153728` | `positions.geom` |
| `location` | `2.153728,41.384972` | lon,lat juntos: formato que pide el índice GEO de `idx:trains` |
| `delay_s` | `1500` | `positions.delay_s` |
| `movement` | `moving` | `moving`, `stopped_station` o `stopped_line` |
| `station_name` | `El Prat de Llobregat` | Solo si está parado en una estación |
| `next_station`, `next_station_name` | `renfe:71801`, `Barcelona-Sants` | `positions.next_station_id` |
| `time` | `2026-11-05T07:00:00Z` | `positions.time` |

## Índices de búsqueda

```
FT.CREATE idx:trains ON HASH PREFIX 1 train: SCHEMA
    line TAG  operator TAG  movement TAG  delay_s NUMERIC SORTABLE
    location GEO  next_station_name TEXT

FT.CREATE idx:stations ON HASH PREFIX 1 station: SCHEMA
    name TEXT  location GEO
```

## Lo que hace el replay cada minuto

1. Lee de Postgres las posiciones del minuto (`WHERE time = :minuto`, unas 200 filas).
2. En un **pipeline** (un solo viaje de red):
   - `HSET train:{id} …` + `EXPIRE … 180` por cada tren.
   - Construye `trains:geo:next`, `trains:by_delay:next` y `line:…:trains:next`.
   - `HSETEX live:delays EX 180 FIELDS …` con el retraso de cada viaje.
   - `TS.ADD` del retraso medio de cada línea y `PFADD hll:trains:{fecha}`.
3. En una **transacción** (`MULTI`/`EXEC`): `RENAME` de cada `…:next` a su nombre final y `SET sim:clock`.
   Quien lea ve el minuto anterior completo o el nuevo completo, nunca una mezcla.
4. `PUBLISH ocemt:clock {minuto}`, y `XADD events:trains` si detecta una incidencia.
5. Avanza un minuto y espera (por defecto 2 s: la simulación va 30 veces más rápida que la realidad).
