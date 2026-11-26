# Técnicas y funcionalidades de Redis en OCEMT

Guía de lo que usamos de Redis, por qué, y cómo explicarlo. Todo está probado en **Redis 8.10.3**
con `bash redis/demo/tour.sh`, que ejecuta cada ejemplo con datos reales (5-nov-2026, 08:00).

## 1. Redis en un minuto

- Base de datos **clave → valor en memoria RAM**. Por eso responde en microsegundos.
- El valor no es solo texto: hay **estructuras de datos** (hash, sorted set, geo, stream…), cada una
  con sus propias operaciones. Se elige la estructura según **la pregunta que hay que responder**.
- Ejecuta los comandos **de uno en uno** (un solo hilo para los datos), así que cada comando es
  atómico: nunca se ve un comando a medias.
- Puede guardar en disco (AOF/RDB), pero en OCEMT **Postgres es la fuente de verdad**: Redis guarda
  el "ahora" y las cachés, y todo se puede reconstruir desde Postgres.
- Redis 8 trae de serie lo que antes eran módulos aparte: JSON, búsqueda (Query Engine), series
  temporales y estructuras probabilísticas.

## 2. Estructuras de datos

| Estructura | En OCEMT | Comandos clave | Por qué esta y no otra |
|---|---|---|---|
| **String** | `sim:clock`, cachés JSON, candados, rate limit | `SET … EX/NX`, `GET`, `INCREX` | Valor único; con `NX` y `EX` sirve de candado y de caché |
| **Hash** | `train:{id}`, `station:{id}`, `sim:control` | `HSET`, `HGETALL`, `HSETEX`, `HGETDEL` | Un objeto con campos: se lee entero o por campos. Compacto (`listpack`) |
| **JSON** | `sim:snapshot` | `JSON.SET`, `JSON.GET … $.ruta` | Un documento con estructura (listas, objetos, números): se escribe de una vez y se lee entero o por partes con JSONPath |
| **GEO** | `trains:geo` | `GEOADD`, `GEOSEARCH BYBOX/BYRADIUS` | Búsqueda por zona en O(log N). Por dentro es un Sorted Set con el geohash como puntuación |
| **Sorted Set** | `trains:by_delay`, paneles de estación | `ZADD`, `ZRANGE … BYSCORE`, `ZREVRANGE`, `ZCOUNT` | Siempre ordenado por puntuación: rankings y "lo próximo a partir de ahora" |
| **Set** | `line:renfe:R2S:trains` | `SADD`, `SMEMBERS`, `SUNIONCARD` | Pertenencia sin duplicados y operaciones de conjuntos |
| **TimeSeries** | `ts:delay:line:{op}:{línea}` | `TS.CREATE … LABELS`, `TS.MADD`, `TS.RANGE … AGGREGATION`, `TS.MGET FILTER` | Muestras (tiempo, valor) con retención, agregación y filtro por etiquetas |
| **HyperLogLog** | `hll:trains:{fecha}` | `PFADD`, `PFCOUNT` | Cuenta elementos distintos con ≤ 12 KB y ~0,81 % de error |
| **Stream** | `events:trains` | `XADD … IDMPAUTO`, `XREADGROUP`, `XACK`, `XPENDING` | Log persistente con grupos de consumidores y confirmación |
| **Pub/Sub** | canal `ocemt:clock` | `PUBLISH`, `SUBSCRIBE` | Aviso instantáneo; si nadie escucha, se pierde (a diferencia de un Stream) |

## 3. Técnicas

### 3.1 La caducidad (TTL) como detector de datos viejos
Cada `train:{id}`, `live:delays` y `sim:snapshot` caduca a los 180 s. Si el replay se para, lo "en vivo"
desaparece solo del mapa, de las búsquedas y del índice. Nunca se enseña un dato viejo como si fuera actual.

Ojo con el **tiempo simulado**: el TTL cuenta segundos reales y la simulación va 30 veces más rápida.
180 s reales son 90 minutos simulados, así que un tren que termina su viaje seguiría en el índice hora y
media. Por eso el replay borra él mismo (`UNLINK`) los trenes del minuto anterior que ya no salen, y el
TTL queda como red de seguridad.
- `EXPIRE`/`TTL` a nivel de clave.
- **TTL por campo** (Redis 7.4+, `HSETEX … EX 180 FIELDS …` y `HTTL`): `live:delays` es un único hash
  donde el retraso de cada viaje caduca por separado.

### 3.2 Pipelining
El replay escribe ~200 trenes por minuto. Mandar los comandos uno a uno supondría ~1.000 viajes de red;
en un **pipeline** se envían todos juntos y se leen todas las respuestas al final: un solo viaje.
En Python: `pipe = r.pipeline(transaction=False)` … `pipe.execute()`.

### 3.3 Atomicidad: MULTI/EXEC y cambio de minuto con RENAME
- `MULTI … EXEC` ejecuta un bloque sin que se cuele ningún otro cliente en medio.
- **Un solo comando ya es atómico**, porque Redis ejecuta los comandos de uno en uno. `JSON.SET sim:snapshot`
  sustituye la foto entera de golpe: quien la lea ve la vieja o la nueva, nunca la mitad. Por eso no hace
  falta el patrón "puntero" (`current` → `snapshot:{id}`), que se usa cuando la escritura se reparte entre
  varias claves sin transacción. Aquí además la foto va dentro del mismo `MULTI` que los `train:*`, así que
  todo es siempre del mismo minuto.
- **Doble búfer**: el minuto nuevo se construye en `trains:geo:next` y `RENAME trains:geo:next trains:geo`
  lo sustituye de golpe. Quien lea ve el minuto anterior entero o el nuevo entero, nunca una mezcla.
- Siguiente nivel (pendiente): una **Redis Function** en Lua que actualice un tren solo si su `time` es
  más nuevo que el guardado. Es una lógica que depende de leer antes de escribir, y eso MULTI no lo puede hacer.

### 3.4 Caché de Postgres (cache-aside)
1. `GET cache:v1:…`. Si está, se devuelve.
2. Si no: `SET lock:… <token> NX PX 5000`. Solo el que consigue el candado consulta Postgres; los demás
   esperan un momento y vuelven a mirar la caché. Así se evita la **estampida** (100 peticiones
   simultáneas = 100 consultas iguales). Probado: 20 a la vez → 1 consulta.
   El candado se suelta con `DELEX lock:… IFEQ <token>` (Redis 8.4): solo lo borra si sigue siendo suyo,
   por si la consulta tardó más de 5 s y el candado ya es de otro. Antes hacía falta un script de Lua.
3. `SET cache:v1:… <json> EX 3600`.
- La versión en la clave (`v1`) permite cambiar el formato sin tener que borrar nada a mano.
- Con muchas claves que caducan a la vez conviene sumar al TTL unos segundos aleatorios (*jitter*).

### 3.5 Consultar Redis como una base de datos (Query Engine)
`FT.CREATE idx:trains ON HASH PREFIX 1 train: …` crea un índice secundario sobre los hashes, que se
mantiene solo con cada `HSET` o caducidad. Permite:
- Filtros: `@line:{R2S} @delay_s:[900 +inf]`.
- Geográficas: `@location:[lon lat 10 km]`.
- Agregaciones tipo `GROUP BY`: `FT.AGGREGATE … GROUPBY 1 @line REDUCE AVG 1 @delay_s`. Ojo: si un grupo
  no tiene ningún valor, `AVG` da `nan` y `SORTBY` deja de ordenar bien. Se filtra antes con
  `@delay_s:[-inf +inf]` (solo documentos que tienen el campo).
- Prefijos para autocompletar: `@name:Barc*`.

Sin esto habría que mantener a mano un Set por cada filtro.

Limitación: los índices solo funcionan en la **base de datos 0** (`FT.CREATE` en otra responde
`Cannot create index on db != 0`). Tampoco importa mucho: en Redis Cluster solo existe la 0, y lo
recomendado es separar con prefijos de clave, no con números de base de datos.

### 3.6 Series temporales con retención
- `RETENTION 604800000`: Redis borra solo las muestras de más de 7 días.
- `TS.RANGE … AGGREGATION max 1800000` reduce la resolución al vuelo (máximo por media hora).
- `TS.CREATERULE` (pendiente de probar) mantiene automáticamente una serie agregada, por ejemplo la
  media cada 5 minutos, para que las gráficas largas lean pocos puntos.
- Las **etiquetas** (`LABELS operator renfe line R2S`) permiten pedir todas las líneas a la vez:
  `TS.MGET FILTER metric=avg_delay`.

### 3.7 Mensajería: Pub/Sub frente a Streams
| | Pub/Sub | Streams |
|---|---|---|
| Si nadie escucha | El mensaje se pierde | Se queda guardado |
| Varios workers | Todos reciben todo | Un grupo de consumidores se lo reparte |
| Confirmación | No | `XACK`; lo no confirmado queda en `XPENDING` |
| En OCEMT | "Hay minuto nuevo" (`ocemt:clock`) | Incidencias (`events:trains`) |

- `MAXLEN ~ 10000` limita el stream; con `~` Redis recorta cuando le es eficiente.
- `IDMPAUTO` (Redis 8.6): si el replay reenvía el mismo evento, no se duplica (en la demo, el segundo
  `XADD` idéntico devuelve el mismo id).

### 3.8 Limitar peticiones con INCREX (Redis 8.8)
`INCREX ratelimit:api:{ip} BYINT 1 UBOUND 5 EX 60 ENX` incrementa, comprueba el límite y pone la
caducidad en un solo comando atómico. Responde `[valor, 1]` si se acepta y `[valor, 0]` si se pasa.

### 3.9 Enterarse de lo que caduca (keyspace notifications)
`notify-keyspace-events Ex` (en `redis.conf`) publica un evento cuando caduca una clave. Suscribiéndose a
`__keyevent@0__:expired` se sabe en el momento que un tren ha dejado de emitir. Redis 8.8 añade
notificaciones por campo de hash.

### 3.10 Controlar la simulación: estado deseado en un Hash
El backend no le "manda órdenes" al replay: escribe **lo que quiere** en `sim:control`
(`status paused`, `speed 60`) y el replay lo lee cada medio segundo y se adapta.
- Si el replay está reiniciándose cuando el backend escribe, no se pierde nada: el Hash sigue ahí. Con
  Pub/Sub, si nadie escucha en ese momento, el mensaje se pierde (3.7).
- `seek` (saltar a una hora) es una orden de una sola vez. El replay la lee y la borra en un solo comando con
  `HGETDEL sim:control FIELDS 1 seek` (Redis 8.0). Leer y luego borrar con dos comandos podría perder un
  segundo `seek` que llegara justo en medio.

### 3.11 Qué pasa si algo se cae
| Se cae | Replay | Backend |
|---|---|---|
| Redis | No se para: el reloj sigue en su memoria y reintenta cada minuto. Al volver recarga estaciones e índices y escribe el minuto en el que va | Lo "en vivo" responde 503; las cachés tiran de Postgres (cache-aside) |
| Postgres | Se reconecta y repite la consulta del mismo minuto | Lo "en vivo" sigue saliendo de Redis; las consultas a Postgres responden 503 |
| El replay | Docker lo reinicia (`restart: unless-stopped`). Si no vuelve, a los 180 s caduca lo "en vivo" | No hay `sim:snapshot`: 503 en lo "en vivo" |

## 4. Configuración (`redis.conf`)

| Opción | Valor | Por qué |
|---|---|---|
| `maxmemory` | `256mb` | Que Redis nunca se coma la RAM |
| `maxmemory-policy` | `volatile-lru` | Si se llena, solo expulsa claves con TTL (estado y cachés), nunca series ni índices. Alternativas: `allkeys-lru` (todo es caché) o `volatile-lrm` (Redis 8.6, por última *modificación*) |
| `appendonly` / `appendfsync` | `yes` / `everysec` | Tras reiniciar no hay que esperar al replay; se pierde como mucho 1 s |
| `slowlog-log-slower-than` | `1000` µs | Registra lo que tarde más de 1 ms |
| `notify-keyspace-events` | `Ex` | Eventos de caducidad (3.9) |
| `key-memory-histograms` | `yes` | Histogramas de tamaño por tipo (Redis 8.6) |

## 5. Memoria y rendimiento

- Los hashes pequeños se guardan como **listpack** (`OBJECT ENCODING`): un tren ocupa ~300 bytes.
- **Compact hashes** (Redis 8.10): los hashes con los mismos campos comparten los nombres de campo.
  Todos los `train:*` tienen el mismo esquema, así que pueden ahorrar memoria. Se cargan con `HIMPORT`
  (pendiente de probar).
- **`SCAN`, nunca `KEYS`**: `KEYS` recorre todo de golpe y bloquea Redis.
- **`UNLINK` en vez de `DEL`** para claves grandes: libera la memoria en segundo plano.
- GEO y Sorted Set son O(log N): buscar entre 200 o entre 200.000 trenes cuesta casi lo mismo.

## 6. Seguridad: usuarios ACL (probado)

Ahora mismo cualquiera que llegue al puerto puede hacer `FLUSHALL`. Además, si `redis-cli` no consigue
autenticarse, sigue como usuario `default`, que tiene todos los permisos. La propuesta es un usuario por
servicio con lo mínimo:

```
ACL SETUSER replay on >*** resetkeys ~sim:* ~train:* ~trains:* ~line:* ~live:* ~ts:* ~hll:* ~events:*
    ~station:* ~stations:* resetchannels &ocemt:* -@all +@read +@write +@transaction +@pubsub +@timeseries
    +@hyperloglog +@stream +@search +@json +@connection -@dangerous

ACL SETUSER backend on >*** resetkeys %R~* ~cache:* ~lock:* ~ratelimit:* ~sim:control
    resetchannels &ocemt:* -@all +@read +@write +@pubsub +@search +@timeseries +@json +@connection -@dangerous
```

Comprobado con el replay funcionando con su usuario: `backend` lee la foto y los trenes, busca con
`FT.SEARCH`, escribe cachés y `sim:control` (y el replay se pone en pausa), pero recibe `NOPERM` al
escribir en `train:*` o `sim:clock` y al pedir `FLUSHALL`. `replay` escribe trenes pero no cachés.
`%R~*` significa "puede leer cualquier clave". El replay necesita `station:*` y `+@search` porque al
arrancar carga las estaciones y crea los índices.
Pendiente: guardarlos en un `users.acl` y desactivar `default`.

## 7. Observar y enseñarlo

- **Redis Insight** (http://localhost:5540):
  - *Browser*: claves en carpetas, tipo, TTL bajando.
  - *Workbench*: lanzar comandos con resultados formateados.
  - *Profiler*: ver en directo los comandos que llegan (ideal con el replay en marcha).
  - *Slow Log*, *Analysis Tools* (memoria por tipo y por prefijo), *Pub/Sub*.
- Comandos: `INFO memory|stats|keyspace`, `SLOWLOG GET`, `LATENCY DOCTOR`, `MEMORY USAGE`, `HOTKEYS`
  (Redis 8.6, claves más usadas).
- Medir latencia:
  ```
  docker compose exec redis redis-cli --latency-history -i 5
  ```

## 8. Para la memoria del trabajo: medir Redis frente a Postgres

Haced la misma pregunta a las dos bases de datos y medid la latencia (p50/p95) con muchas repeticiones
y varios clientes a la vez:

| Pregunta | PostgreSQL | Redis |
|---|---|---|
| Trenes dentro del mapa ahora | `WHERE time = :t AND geom && ST_MakeEnvelope(…)` (índice GiST) | `GEOSEARCH trains:geo BYBOX …` |
| Los 10 más retrasados | `ORDER BY delay_s DESC LIMIT 10` | `ZREVRANGE trains:by_delay 0 9` |
| Retraso medio por línea | `GROUP BY` sobre `positions` | `FT.AGGREGATE` o `TS.MGET` |

Con ~200 trenes, Postgres con índices también será rápido. La diferencia aparece con **muchos usuarios
a la vez** y en que Redis ya tiene el "ahora" calculado. Hay que medirlo, no suponerlo.

## 9. Versiones: por qué Redis 8.10 y no 7

| Funcionalidad | Desde |
|---|---|
| TTL por campo de hash (`HEXPIRE`, `HTTL`) | 7.4 |
| `HSETEX`, `HGETDEL`; JSON, Query Engine, TimeSeries y Bloom incluidos de serie | 8.0 |
| `DELEX … IFEQ` (borrar solo si el valor coincide) | 8.4 |
| `XADD … IDMP/IDMPAUTO`, `HOTKEYS`, políticas `*-lrm` | 8.6 |
| `INCREX`, notificaciones por campo de hash | 8.8 |
| `SUNIONCARD`/`SDIFFCARD`, compact hashes + `HIMPORT`, `TS.NRANGE`/`TS.READ` | 8.10 |

El docker-compose común empezó con `redis:7-alpine`, donde **no funcionaría casi nada de esta guía**.
Por eso usa `redis:8.10.3` y monta `redis/redis.conf`. La versión está fijada: subirla es una decisión
del equipo, no algo que pase solo.

## Fuentes

- [Redis 8.10 – What's new](https://redis.io/docs/latest/develop/whats-new/8-10/)
- [Redis 8.8 – What's new](https://redis.io/docs/latest/develop/whats-new/8-8/)
- [Redis 8.6 – What's new](https://redis.io/docs/latest/develop/whats-new/8-6/)
- [Redis 8.4 – What's new](https://redis.io/docs/latest/develop/whats-new/8-4/)
- [Eviction policies](https://redis.io/docs/latest/develop/reference/eviction)
