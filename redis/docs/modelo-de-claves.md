# Modelo de claves de Redis

Es el **contrato entre Redis y el backend**: qué hay en Redis, quién lo escribe y quién lo lee.
Si alguien necesita una clave nueva, se añade aquí primero. **Cómo leer cada cosa desde el backend**
(comandos y código Python probados): [`recetario-backend.md`](recetario-backend.md).

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
| `sim:incidents` | JSON | 180 s | replay | backend | Incidencias oficiales activas en el minuto actual (formato abajo) |
| `train:{train_id}` | Hash | 180 s | replay | backend, `idx:trains` | Estado actual de un tren (campos abajo) |
| `trail:{train_id}` | List | 180 s | replay | backend | Estela: últimas 30 posiciones del tren, la más nueva primero (`"lon,lat,hora"`) |
| `trains:geo` | GEO | se sustituye cada minuto | replay | backend | Trenes dentro del mapa / cerca de un punto |
| `trains:by_delay` | Sorted Set | se sustituye cada minuto | replay | backend | Ranking de retrasos, "cuántos llevan > X" |
| `line:{operador}:{línea}:trains` | Set | se sustituye cada minuto | replay | backend | Trenes de una línea ahora |
| `live:delays` | Hash con TTL por campo | 180 s por campo | replay | backend | Retraso actual por `trip_id` (búsqueda origen → destino) |
| `station:{station_id}` | Hash | — | carga inicial | `idx:stations` | Nombre y posición, para el buscador |
| `ts:delay:line:{operador}:{línea}` | TimeSeries | retención 7 días | replay | backend | Retraso medio por línea a lo largo del tiempo. Etiquetas `metric=avg_delay`, `operator`, `line`, `service` |
| `ts:delay_max:line:{operador}:{línea}` | TimeSeries | retención 7 días | replay | backend | Retraso máximo por línea. Etiquetas `metric=max_delay`, `operator`, `line`, `service` |
| `hll:trains:{fecha}` | HyperLogLog | 8 días | replay | backend | Trenes distintos vistos en un día |
| `events:trains` | Stream | `MAXLEN ~ 10000` | replay | worker de alertas, backend | Incidencias detectadas (retraso grande, parada larga) |
| `cache:v1:{consulta}:{parámetros}` | String (JSON) | 1 h | backend | backend | Resultado de una consulta pesada a Postgres (p. ej. `cache:v1:departures:{station_id}:{fecha}`, el horario del día de una estación) |
| `lock:{clave de caché}` | String | 5 s | backend | backend | Candado anti-estampida al rellenar una caché |
| `ratelimit:api:{ip}` | String (`INCREX`) | 60 s | backend | backend | Límite de peticiones por IP |
| canal `ocemt:clock` | Pub/Sub | — | replay | backend | Aviso de "la foto ha cambiado" para refrescar la web (mensaje abajo) |
| `idx:trains`, `idx:stations` | Índices de búsqueda | — | se crean al arrancar | backend | Filtros, búsquedas geográficas y agregaciones |

### Campos de `train:{train_id}`

Vienen de `public.positions` más datos de `routes`, `trips` y `stations` (desnormalizados a propósito,
para que el backend lo tenga todo con un solo `HGETALL`). Los campos vacíos no se guardan.

| Campo | Ejemplo | Origen |
|---|---|---|
| `trip_id` | `renfe:5108J25500R2S@2026-11-05` | `positions.trip_id` |
| `train_number` | `25500` | `trips.train_number`: el número del tren de los paneles (FGC no tiene) |
| `headsign` | `Vilanova i la Geltrú` | `trips.headsign`: destino |
| `line` | `R2S` | `routes.short_name` |
| `operator` | `renfe` | `positions.operator` |
| `service` | `rodalies` | `routes.service`: `rodalies`, `regional` (= MD), `long_distance` o `fgc` |
| `color` | `146520` | `routes.color` |
| `lat`, `lon` | `41.384972`, `2.153728` | `positions.geom` |
| `location` | `2.153728,41.384972` | lon,lat juntos: formato que pide el índice GEO de `idx:trains` |
| `delay_s` | `1500` | `positions.delay_s` |
| `movement` | `moving` | `moving`, `stopped_station` o `stopped_line` |
| `station_name` | `El Prat de Llobregat` | Solo si está parado en una estación |
| `station` | `renfe:71802` | `positions.station_id`, solo si está parado en una estación |
| `next_station`, `next_station_name` | `renfe:71801`, `Barcelona-Sants` | `positions.next_station_id` |
| `province` | `BARCELONA` | Cruce espacial con `public.provinces` si existe; si no, la provincia de la estación donde está o a la que va (`stations.province`) |
| `time` | `2026-11-05T07:00:00Z` | `positions.time` |

Hay un `train:*` por cada tren **del minuto actual**, ni uno más: el replay borra en el momento los que
dejan de salir en los datos. Así `idx:trains` cuenta lo mismo que la foto y `trains:geo`. Los 180 s de
caducidad son tiempo real y solo hacen de red de seguridad: si el replay se para, todo lo "en vivo"
desaparece solo. (En el 0,4 % de los casos un tren falta un minuto suelto en los datos: desaparece ese
minuto y vuelve en el siguiente.)

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
     "line": "R2S", "operator": "renfe", "service": "rodalies", "color": "146520",
     "train_number": "25500", "headsign": "Vilanova i la Geltrú",
     "lat": 41.384972, "lon": 2.153728, "delay_s": 1500, "speed_kmh": 62.0, "movement": "moving",
     "station": null, "station_name": null,
     "next_station": "renfe:71801", "next_station_name": "Barcelona-Sants", "province": "BARCELONA"}
  ]
}
```

| Campo | Qué es |
|---|---|
| `version` | Versión del formato. **Añadir campos no la cambia** (se avisa igual); quitar o renombrar campos o cambiar tipos la sube a `2`, avisando antes |
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

Si `speed` está fuera de 1–600 se recorta (y el replay lo avisa en su log); si no es un número, o
`status` no es `playing`/`paused`, se ignora con aviso.

### `sim:incidents`: incidencias activas

Las incidencias oficiales de `public.incidents` (cancelaciones, avisos y paradas inesperadas) activas en
el minuto simulado (`start <= minuto < end`). El replay lo reescribe en la misma transacción que la foto.

```json
{
  "simulated_at": "2026-11-05T08:00:00Z",
  "count": 22,
  "incidents": [
    {"incident_id": "cancellation:…", "type": "cancellation", "operator": "renfe",
     "route_id": "renfe:51T0002R1", "line": "R1", "trip_id": "…", "train_id": null,
     "station_id": null, "station_name": null,
     "start": "2026-11-05T06:53:00Z", "end": "2026-11-05T08:26:00Z", "details": "whole trip cancelled; …"}
  ]
}
```

Las incidencias que **detecta el replay** (un viaje que pasa de 15 min de retraso) siguen en el stream
`events:trains`.

### `trail:{train_id}`: la estela

Lista con las últimas 30 posiciones (30 minutos simulados), la más nueva primero:
`"2.100894,41.364311,2026-11-05T07:12:00Z"` (lon,lat,hora). `LPUSH` + `LTRIM 0 29` cada minuto: una
lista con tope. Se borra cuando el tren deja de salir, y todas empiezan de cero tras un salto (`seek`,
vuelta al principio o Redis caído), para no unir puntos de horas distintas.

### Canal `ocemt:clock`

Cada vez que el replay reescribe la foto publica un JSON pequeño:

```json
{"simulated_at": "2026-11-05T07:00:00Z", "status": "playing", "speed": 30, "snapshot_id": 1795807545572}
```

Se publica en cada minuto nuevo, **al momento** cuando cambia la pausa o la velocidad, y cada 30 s en pausa
(con el mismo minuto). La web actualiza el reloj y los botones con el mensaje, y solo vuelve a pedir la
foto si ha cambiado `simulated_at`.

## Índices de búsqueda

```
FT.CREATE idx:trains ON HASH PREFIX 1 train: SCHEMA
    line TAG  operator TAG  service TAG  movement TAG  province TAG
    trip_id TAG  train_number TAG  station TAG  next_station TAG
    delay_s NUMERIC SORTABLE  location GEO  next_station_name TEXT  headsign TEXT

FT.CREATE idx:stations ON HASH PREFIX 1 station: SCHEMA
    name TEXT  operator TAG  province TAG  location GEO
```

El replay los borra (`FT.DROPINDEX`, sin `DD`: los hashes se quedan) y los vuelve a crear en cada
arranque, así que un cambio de esquema se aplica solo. En los TAG, los caracteres que no son letras o
números se escapan: `@next_station:{renfe\:71801}`.

## Lo que hace el replay cada minuto

Lo hace [`replay/replay.py`](../replay/replay.py):

1. Lee las posiciones del minuto, entre 100 y 250 trenes según la hora:
   `SELECT … FROM public.positions WHERE time = :minuto`, que usa el índice por `time`.
   Con `--source csv` las lee de los CSV de `data/realtime/positions`.
2. Lo escribe todo en **una sola transacción** (`MULTI`/`EXEC`), enviada en un solo viaje de red (pipeline):
   - `HSET train:{id} …` + `HDEL` de los campos que ya no aplican + `EXPIRE … 180`, por cada tren.
   - `LPUSH trail:{id} …` + `LTRIM … 0 29`, por cada tren.
   - `UNLINK` de los trenes (y sus estelas) del minuto anterior que ya no salen.
   - Rehace `trains:geo`, `trains:by_delay` y los `line:…:trains` (`DEL` + `GEOADD`/`ZADD`/`SADD`).
   - `HSETEX live:delays EX 180 FIELDS …` con el retraso de cada viaje.
   - `TS.ADD` del retraso medio y del máximo de cada línea, y `PFADD hll:trains:{fecha}`.
   - `XADD events:trains` cuando un viaje pasa de 15 min de retraso.
   - `JSON.SET sim:snapshot $ …` con la foto entera, y `EXPIRE … 180`.
   - `JSON.SET sim:incidents $ …` con las incidencias activas (otra consulta a `public.incidents`).
   - `SET sim:clock` y `PUBLISH ocemt:clock` (el JSON de arriba).

   Quien lea ve el minuto anterior completo o el nuevo completo, nunca una mezcla. Son unos 1.200 comandos
   y tarda ~25 ms. Con muchos más trenes convendría el doble búfer (`…:next` + `RENAME`) para no
   bloquear Redis tanto rato.
3. Espera al siguiente minuto (por defecto 2 s: la simulación va 30 veces más rápida que la realidad).
   Mientras espera, mira `sim:control` cada medio segundo.

En pausa no avanza: cada 30 s reescribe el mismo minuto para que no caduque, sin añadir nada a las
series, a las estelas, al contador del día ni a las incidencias de retraso.

Al arrancar:
- Carga la red: rutas, estaciones y viajes (`trips`, para el número de tren y el destino).
- Carga las 412 estaciones en Redis (`station:{id}` y `stations:geo`).
- Borra los trenes y estelas que hubiera dejado una ejecución anterior.
- Vuelve a crear los índices.
- Pone las etiquetas (`service` incluida) a las series que ya existían.
- Mira si existe `public.provinces` para la provincia de cada tren.

**Si se cae Redis**, el replay no se para: el reloj sigue avanzando en su memoria y cada minuto
reintenta. Cuando Redis vuelve, recarga estaciones e índices (por si ha vuelto vacío) y escribe el
minuto en el que va. **Si se cae Postgres**, se reconecta y repite la consulta del mismo minuto.
