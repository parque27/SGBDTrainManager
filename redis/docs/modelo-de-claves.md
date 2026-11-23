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
- Nada sin caducidad salvo lo que se reconstruye cada minuto o se debe conservar (series, índices,
  `sim:control`).

## Claves

| Clave | Tipo | Caducidad | Escribe | Lee | Para qué |
|---|---|---|---|---|---|
| `sim:clock` | String | — | replay | backend | Minuto simulado actual (`2026-11-05T07:00:00Z`) |
| `sim:snapshot` | JSON | 180 s | replay | backend | **Foto completa del minuto actual**: un `JSON.GET` y está todo el mapa (formato abajo) |
| `sim:control` | Hash | — | backend | replay | Pausa, velocidad y saltos de la simulación (campos abajo) |
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

Un `train:*` dura mientras el tren salga en los datos: el replay lo borra cuando lleva **3 minutos
simulados** sin aparecer. Los 180 s de caducidad son tiempo real y solo hacen de red de seguridad: si
el replay se para, todo lo "en vivo" desaparece solo.

### `sim:snapshot`: la foto del minuto

Documento JSON (RedisJSON) que el replay sustituye entero cada minuto, en la misma transacción que todo
lo demás. Lo que hay en la foto y en los `train:*` es siempre del mismo minuto.

```json
{
  "version": 1,
  "snapshot_id": 1795435502131,
  "simulated_at": "2026-11-05T07:00:00Z",
  "published_at": "2026-11-23T15:25:02Z",
  "status": "playing",
  "speed": 30,
  "range": {"first": "2026-11-01T23:00:00Z", "last": "2026-11-06T22:59:00Z"},
  "count": 181,
  "positions": [
    {"train_id": "renfe:5108J25500R2S", "trip_id": "renfe:5108J25500R2S@2026-11-05",
     "line": "R2S", "operator": "renfe", "color": "146520", "lat": 41.384972, "lon": 2.153728,
     "delay_s": 1500, "speed_kmh": 62.0, "movement": "moving",
     "station": null, "station_name": null,
     "next_station": "renfe:71801", "next_station_name": "Barcelona-Sants"}
  ]
}
```

| Campo | Qué es |
|---|---|
| `version` | Versión del formato. Si cambia algo que rompa al backend, se sube |
| `snapshot_id` | Cambia en cada publicación (milisegundos de la hora real). Sirve para saber si hay foto nueva |
| `simulated_at` | Minuto simulado de **todas** las posiciones, en UTC |
| `published_at` | Hora real en que se escribió, en UTC |
| `status` | `playing`, `paused` o `finished` (solo con `--no-loop`, al llegar al final) |
| `speed` | Minutos simulados por minuto real: `30` = un minuto cada 2 s |
| `range` | Primer y último minuto con datos: los límites de un selector de hora |
| `positions` | Los trenes del minuto, con los mismos campos que `train:{id}` más `train_id`. Números de verdad (no texto) y `null` en lo que falta |

Si la clave no existe, el replay no está funcionando: el backend debe responder 503 para lo "en vivo".

Se puede leer entera o por partes:

```
JSON.GET sim:snapshot                                         # todo el mapa
JSON.GET sim:snapshot $.simulated_at $.status $.speed         # solo el reloj, para /clock
JSON.GET sim:snapshot '$.positions[?(@.line=="R2S")]'         # filtrar dentro del documento
```

### `sim:control`: controlar la simulación

Lo escribe el backend y el replay lo mira cada medio segundo. Si falta un campo, vale lo del `.env`.

| Campo | Valores | Efecto |
|---|---|---|
| `status` | `playing` / `paused` | Pausa o sigue. En pausa la foto dice `paused` y el reloj no avanza |
| `speed` | número de 1 a 600 | Velocidad: `1` = tiempo real, `30` = un minuto cada 2 s, `60` = uno por segundo |
| `seek` | fecha ISO en UTC (`2026-11-05T07:00:00Z`) | Salta a ese minuto (si está en pausa, sigue en pausa). Es una orden de una vez: el replay la borra al leerla (`HGETDEL`) |

```
HSET sim:control status paused
HSET sim:control status playing speed 60
HSET sim:control seek 2026-11-05T07:00:00Z
DEL sim:control                                   # volver a lo del .env
```

Se queda guardado en Redis: si se reinicia el replay y estaba en pausa, arranca en pausa.

## Índices de búsqueda

```
FT.CREATE idx:trains ON HASH PREFIX 1 train: SCHEMA
    line TAG  operator TAG  movement TAG  delay_s NUMERIC SORTABLE
    location GEO  next_station_name TEXT

FT.CREATE idx:stations ON HASH PREFIX 1 station: SCHEMA
    name TEXT  location GEO
```

## Lo que hace el replay cada minuto

Lo hace [`replay/replay.py`](../replay/replay.py):

1. Lee las posiciones del minuto, entre 100 y 250 trenes según la hora:
   `SELECT … FROM public.positions WHERE time = :minuto`, que usa el índice por `time`.
   Con `--source csv` las lee de los CSV de `data/realtime/positions`.
2. Lo escribe todo en **una sola transacción** (`MULTI`/`EXEC`), enviada en un solo viaje de red (pipeline):
   - `HSET train:{id} …` + `HDEL` de los campos que ya no aplican + `EXPIRE … 180`, por cada tren.
   - `UNLINK` de los trenes que llevan 3 minutos simulados sin aparecer.
   - Rehace `trains:geo`, `trains:by_delay` y los `line:…:trains` (`DEL` + `GEOADD`/`ZADD`/`SADD`).
   - `HSETEX live:delays EX 180 FIELDS …` con el retraso de cada viaje.
   - `TS.ADD` del retraso medio de cada línea y `PFADD hll:trains:{fecha}`.
   - `XADD events:trains` cuando un viaje pasa de 15 min de retraso.
   - `JSON.SET sim:snapshot $ …` con la foto entera, y `EXPIRE … 180`.
   - `SET sim:clock` y `PUBLISH ocemt:clock`.

   Quien lea ve el minuto anterior completo o el nuevo completo, nunca una mezcla. Son unos 600 comandos
   y tarda ~20 ms. Con muchos más trenes convendría el doble búfer (`…:next` + `RENAME`) para no
   bloquear Redis tanto rato.
3. Espera al siguiente minuto (por defecto 2 s: la simulación va 30 veces más rápida que la realidad).
   Mientras espera, mira `sim:control` cada medio segundo.

En pausa no avanza: cada 30 s reescribe el mismo minuto para que no caduque, sin añadir nada a las
series, al contador del día ni a las incidencias.

Al arrancar carga las 412 estaciones (`station:{id}` y `stations:geo`), borra los trenes que hubiera
dejado una ejecución anterior y crea los índices.

**Si se cae Redis**, el replay no se para: el reloj sigue avanzando en su memoria y cada minuto
reintenta. Cuando Redis vuelve, recarga estaciones e índices (por si ha vuelto vacío) y escribe el
minuto en el que va. **Si se cae Postgres**, se reconecta y repite la consulta del mismo minuto.
