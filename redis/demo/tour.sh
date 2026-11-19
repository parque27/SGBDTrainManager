#!/usr/bin/env bash
# Recorrido por las técnicas de Redis que usará OCEMT, con datos reales:
# trenes de Rodalies del 5 de noviembre de 2026 a las 08:00 de Barcelona (07:00 UTC),
# sacados de public.positions.
#
# Uso, con Redis arrancado (docker compose up -d redis redisinsight):
#   bash redis/demo/tour.sh            crea las claves y enseña cada comando con su respuesta
#   bash redis/demo/tour.sh --clean    borra todo lo que crea el recorrido
# Después abre Redis Insight (http://localhost:5540) para ver las claves.
#
# Usa los mismos nombres de clave que el modelo real (docs/modelo-de-claves.md), así que
# no lo ejecutes mientras esté funcionando el replay.
set -uo pipefail

cd "$(dirname "$0")/../.."   # raíz del repo, donde está docker-compose.yml
CID=$(docker compose ps -q redis)
[ -n "$CID" ] || { echo "Redis no está arrancado: docker compose up -d redis redisinsight" >&2; exit 1; }

CLI=(docker exec "$CID" redis-cli)              # respuesta en bruto (para guardarla en variables)
SHOW=(docker exec "$CID" redis-cli --no-raw)     # respuesta con formato, como en la consola
PIPE=(docker exec -i "$CID" redis-cli --no-raw)  # varios comandos por la misma conexión

# En producción el estado de un tren caduca a los 180 s. Aquí 15 min para que dé tiempo
# a mirarlo en Redis Insight (DEMO_TTL=180 bash redis/demo/tour.sh para el valor real).
TTL="${DEMO_TTL:-900}"

title() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
note()  { printf '\033[2m# %s\033[0m\n' "$*"; }
r()     { printf '\033[1m> %s\033[0m\n' "$*"; "${SHOW[@]}" "$@"; }

# id | trip_id | línea | color | lat | lon | retraso (s) | movimiento | parado en | siguiente estación | id siguiente
TRAINS='renfe:5108J25500R2S|renfe:5108J25500R2S@2026-11-05|R2S|146520|41.384972|2.153728|1500|moving||Barcelona-Sants|renfe:71801
renfe:5108J77980R4|renfe:5108J77980R4@2026-11-05|R4|F7A30D|41.387875|2.169721|1320|moving||Barcelona Plaça de Catalunya|renfe:78805
renfe:5108J28254R2S|renfe:5108J28254R2S@2026-11-05|R2S|146520|41.330601|2.089463|1200|stopped_station|El Prat de Llobregat|El Prat de Llobregat|renfe:71707
renfe:5108J77984R4|renfe:5108J77984R4@2026-11-05|R4|F7A30D|41.481228|2.166974|960|moving||Montcada i Reixac-Santa Maria|renfe:78707
renfe:5108J25480R2S|renfe:5108J25480R2S@2026-11-05|R2S|146520|41.309311|2.027487|900|stopped_station|Viladecans|Viladecans|renfe:71709
renfe:5108J25700R1|renfe:5108J25700R1@2026-11-05|R1|7DBCEC|41.364311|2.100894|840|stopped_station|L'"'"'Hospitalet de Llobregat|L'"'"'Hospitalet de Llobregat|renfe:72305
renfe:5108J25504R2S|renfe:5108J25504R2S@2026-11-05|R2S|146520|41.303219|2.010665|840|stopped_station|Gavà|Gavà|renfe:71706
renfe:5108J77710R4|renfe:5108J77710R4@2026-11-05|R4|F7A30D|41.430275|2.183151|660|stopped_station|Barcelona Fabra i Puig|Barcelona Fabra i Puig|renfe:78802'

clean() {
  "${CLI[@]}" FT.DROPINDEX idx:trains >/dev/null 2>&1
  "${CLI[@]}" FT.DROPINDEX idx:stations >/dev/null 2>&1
  local keys=(sim:clock live:delays trains:geo trains:geo:next stations:geo trains:by_delay
    station:renfe:71801:departures line:renfe:R2S:trains line:renfe:R4:trains line:renfe:R1:trains
    station:renfe:71801 station:renfe:71802
    cache:v1:stats:avg_delay_by_line:2026-11-05 lock:cache:v1:stats:avg_delay_by_line:2026-11-05
    ts:delay:line:renfe:R1 ts:delay:line:renfe:R2S ts:delay:line:renfe:R4
    hll:trains:2026-11-05 events:trains ratelimit:api:203.0.113.7)
  while IFS='|' read -r id _; do keys+=("train:$id"); done <<< "$TRAINS"
  "${CLI[@]}" UNLINK "${keys[@]}" >/dev/null
}

if [ "${1:-}" = "--clean" ]; then clean; echo "Claves del recorrido borradas."; exit 0; fi
clean

title "0. Reloj de la simulación (String)"
note "El replay irá avanzando este minuto. Todo lo demás describe el estado 'a esta hora'."
r SET sim:clock 2026-11-05T07:00:00Z
r GET sim:clock

title "1. Estado de cada tren (Hash + TTL)"
note "Un hash por tren. Guarda juntos los campos que se leen juntos (incluido el nombre de la"
note "siguiente estación, aunque esté repetido: en Redis se desnormaliza para leer en un paso)."
while IFS='|' read -r id trip line color lat lon delay movement station next_name next_id; do
  fields=(trip_id "$trip" line "$line" operator renfe color "$color" lat "$lat" lon "$lon" location "$lon,$lat"
          delay_s "$delay" movement "$movement" next_station "$next_id" next_station_name "$next_name"
          time 2026-11-05T07:00:00Z)
  [ -n "$station" ] && fields+=(station_name "$station")
  "${CLI[@]}" HSET "train:$id" "${fields[@]}" >/dev/null
  "${CLI[@]}" EXPIRE "train:$id" "$TTL" >/dev/null
done <<< "$TRAINS"
note "Creados 8 hashes train:<id> con TTL. Uno de ellos:"
r HGETALL train:renfe:5108J25500R2S
note "Segundos que le quedan antes de desaparecer si nadie lo actualiza:"
r TTL train:renfe:5108J25500R2S
note "Codificación interna: listpack (compacta) mientras el hash sea pequeño."
r OBJECT ENCODING train:renfe:5108J25500R2S
r MEMORY USAGE train:renfe:5108J25500R2S
note "Caducidad por campo (Redis 7.4+): un solo hash con el retraso de cada viaje,"
note "donde cada campo caduca por separado."
r HSETEX live:delays EX "$TTL" FIELDS 3 renfe:5108J25500R2S@2026-11-05 1500 renfe:5108J77980R4@2026-11-05 1320 renfe:5108J25480R2S@2026-11-05 900
r HTTL live:delays FIELDS 1 renfe:5108J25500R2S@2026-11-05

title "2. Mapa (GEO)"
r GEOADD trains:geo 2.153728 41.384972 renfe:5108J25500R2S 2.169721 41.387875 renfe:5108J77980R4 2.089463 41.330601 renfe:5108J28254R2S 2.166974 41.481228 renfe:5108J77984R4 2.027487 41.309311 renfe:5108J25480R2S 2.100894 41.364311 renfe:5108J25700R1 2.010665 41.303219 renfe:5108J25504R2S 2.183151 41.430275 renfe:5108J77710R4
r GEOADD stations:geo 2.141017 41.379863 renfe:71801 2.165339 41.392086 renfe:71802
note "Trenes a menos de 2 km de Barcelona-Sants, del más cercano al más lejano:"
r GEOSEARCH trains:geo FROMLONLAT 2.141017 41.379863 BYRADIUS 2 km ASC WITHDIST
note "Lo que pedirá el mapa: los trenes dentro del rectángulo visible (ancho x alto)."
r GEOSEARCH trains:geo FROMLONLAT 2.10 41.36 BYBOX 12 8 km ASC
r GEODIST stations:geo renfe:71801 renfe:71802 km
note "Por dentro, un GEO es un Sorted Set cuya puntuación es el geohash de la posición:"
r TYPE trains:geo

title "3. Rankings y paneles (Sorted Set)"
r ZADD trains:by_delay 1500 renfe:5108J25500R2S 1320 renfe:5108J77980R4 1200 renfe:5108J28254R2S 960 renfe:5108J77984R4 900 renfe:5108J25480R2S 840 renfe:5108J25700R1 840 renfe:5108J25504R2S 660 renfe:5108J77710R4
note "Los 3 trenes más retrasados ahora mismo:"
r ZREVRANGE trains:by_delay 0 2 WITHSCORES
note "Cuántos llevan 15 minutos o más de retraso:"
r ZCOUNT trains:by_delay 900 +inf
note "Panel de salidas de Sants: puntuación = hora de salida estimada (epoch, programada + retraso)."
note "La R2S de las 08:03 lleva 15 min de retraso, así que queda detrás (08:18)."
r ZADD station:renfe:71801:departures 1793862000 renfe:0308212026-11-04@2026-11-05 1793862060 renfe:5108J25408R2N@2026-11-05 1793862060 renfe:5108J77982R4@2026-11-05 1793862180 renfe:5108J15003R15@2026-11-05 1793863080 renfe:5108J25480R2S@2026-11-05
r ZRANGE station:renfe:71801:departures 1793862000 +inf BYSCORE WITHSCORES LIMIT 0 5

title "4. Grupos (Set)"
r SADD line:renfe:R2S:trains renfe:5108J25500R2S renfe:5108J28254R2S renfe:5108J25480R2S renfe:5108J25504R2S
r SADD line:renfe:R4:trains renfe:5108J77980R4 renfe:5108J77984R4 renfe:5108J77710R4
r SMEMBERS line:renfe:R4:trains
note "SUNIONCARD (Redis 8.10): cuántos trenes hay entre R2S y R4 sin construir la unión."
r SUNIONCARD 2 line:renfe:R2S:trains line:renfe:R4:trains

title "5. Escrituras atómicas (MULTI/EXEC) y cambio de minuto sin parpadeos (RENAME)"
note "El replay actualiza hash, mapa y ranking de un tren a la vez: nadie lo ve a medias."
printf '\033[1m> MULTI … EXEC\033[0m\n'
"${PIPE[@]}" <<EOF
MULTI
HSET train:renfe:5108J25700R1 delay_s 900 movement moving
EXPIRE train:renfe:5108J25700R1 $TTL
GEOADD trains:geo 2.104 41.366 renfe:5108J25700R1
ZADD trains:by_delay 900 renfe:5108J25700R1
EXEC
EOF
note "Para el minuto siguiente se construye el mapa nuevo en otra clave y RENAME lo sustituye"
note "de golpe (es atómico): quien lea trains:geo ve el minuto viejo o el nuevo, nunca una mezcla."
r GEOADD trains:geo:next 2.150 41.383 renfe:5108J25500R2S 2.171 41.389 renfe:5108J77980R4 2.089463 41.330601 renfe:5108J28254R2S 2.168 41.475 renfe:5108J77984R4 2.030 41.312 renfe:5108J25480R2S 2.108 41.368 renfe:5108J25700R1 2.010665 41.303219 renfe:5108J25504R2S 2.183151 41.430275 renfe:5108J77710R4
r RENAME trains:geo:next trains:geo
r ZCARD trains:geo

title "6. Caché de consultas a PostgreSQL (cache-aside)"
note "1) El backend mira la caché. (nil) = no está: tiene que preguntar a Postgres."
r GET cache:v1:stats:avg_delay_by_line:2026-11-05
note "2) Antes de ir a Postgres coge un candado, para que 100 peticiones a la vez no lancen"
note "   100 consultas iguales (anti-estampida). Solo el primero lo consigue:"
r SET lock:cache:v1:stats:avg_delay_by_line:2026-11-05 backend-1 NX PX 5000
r SET lock:cache:v1:stats:avg_delay_by_line:2026-11-05 backend-2 NX PX 5000
note "3) Guarda el resultado de Postgres con caducidad de 1 hora. La siguiente petición ya lo encuentra."
r SET cache:v1:stats:avg_delay_by_line:2026-11-05 '[{"line":"R2S","avg_delay_s":389},{"line":"R4","avg_delay_s":283},{"line":"R1","avg_delay_s":259}]' EX 3600
r GET cache:v1:stats:avg_delay_by_line:2026-11-05
r TTL cache:v1:stats:avg_delay_by_line:2026-11-05

title "7. Retraso medio por línea a lo largo del tiempo (TimeSeries)"
note "Una serie por línea con etiquetas, para poder pedirlas todas a la vez por etiqueta."
for line in R1 R2S R4; do
  "${CLI[@]}" TS.CREATE "ts:delay:line:renfe:$line" RETENTION 604800000 DUPLICATE_POLICY LAST LABELS metric avg_delay operator renfe line "$line" >/dev/null
done
note "Retraso medio real cada 5 minutos entre las 07:30 y las 08:00:"
r TS.MADD ts:delay:line:renfe:R1 1793860200000 189 ts:delay:line:renfe:R1 1793860500000 214 ts:delay:line:renfe:R1 1793860800000 228 ts:delay:line:renfe:R1 1793861100000 273 ts:delay:line:renfe:R1 1793861400000 252 ts:delay:line:renfe:R1 1793861700000 259 ts:delay:line:renfe:R2S 1793860200000 293 ts:delay:line:renfe:R2S 1793860500000 282 ts:delay:line:renfe:R2S 1793860800000 320 ts:delay:line:renfe:R2S 1793861100000 380 ts:delay:line:renfe:R2S 1793861400000 329 ts:delay:line:renfe:R2S 1793861700000 389 ts:delay:line:renfe:R4 1793860200000 210 ts:delay:line:renfe:R4 1793860500000 230 ts:delay:line:renfe:R4 1793860800000 249 ts:delay:line:renfe:R4 1793861100000 287 ts:delay:line:renfe:R4 1793861400000 229 ts:delay:line:renfe:R4 1793861700000 283
r TS.RANGE ts:delay:line:renfe:R2S - +
note "Reducir resolución al vuelo: el máximo de cada media hora."
r TS.RANGE ts:delay:line:renfe:R2S - + AGGREGATION max 1800000
note "El último valor de todas las líneas, filtrando por etiqueta:"
r TS.MGET FILTER metric=avg_delay

title "8. Consultar como una base de datos (Redis Query Engine)"
note "Un índice sobre los hashes train:* . Se mantiene solo: cada HSET o caducidad lo actualiza."
r FT.CREATE idx:trains ON HASH PREFIX 1 train: SCHEMA line TAG operator TAG movement TAG delay_s NUMERIC SORTABLE location GEO next_station_name TEXT
sleep 0.5
note "Trenes de la R2S con 15 min o más de retraso, del más retrasado al menos:"
r FT.SEARCH idx:trains "@line:{R2S} @delay_s:[900 +inf]" SORTBY delay_s DESC RETURN 3 line delay_s next_station_name
note "Trenes parados en una estación a menos de 10 km de Sants:"
r FT.SEARCH idx:trains "@movement:{stopped_station} @location:[2.141017 41.379863 10 km]" RETURN 2 line next_station_name
note "Como un GROUP BY: número de trenes y retraso medio por línea."
r FT.AGGREGATE idx:trains "*" GROUPBY 1 @line REDUCE COUNT 0 AS trenes REDUCE AVG 1 @delay_s AS retraso_medio SORTBY 2 @retraso_medio DESC
note "Autocompletar estaciones en el buscador:"
"${CLI[@]}" HSET station:renfe:71801 name "Barcelona-Sants" location "2.141017,41.379863" >/dev/null
"${CLI[@]}" HSET station:renfe:71802 name "Barcelona-Passeig de Gràcia" location "2.165339,41.392086" >/dev/null
r FT.CREATE idx:stations ON HASH PREFIX 1 station: SCHEMA name TEXT location GEO
sleep 0.5
r FT.SEARCH idx:stations "@name:Barc*" RETURN 1 name

title "9. Contar sin guardar la lista (HyperLogLog)"
note "Trenes distintos vistos hoy. Ocupa como mucho 12 KB, sean 200 o 2 millones (error ~0,81 %)."
r PFADD hll:trains:2026-11-05 renfe:5108J25500R2S renfe:5108J77980R4 renfe:5108J28254R2S renfe:5108J77984R4 renfe:5108J25480R2S renfe:5108J25700R1 renfe:5108J25504R2S renfe:5108J77710R4
note "Añadir uno que ya estaba no cambia nada (devuelve 0):"
r PFADD hll:trains:2026-11-05 renfe:5108J25500R2S
r PFCOUNT hll:trains:2026-11-05

title "10. Log de incidencias con consumidores (Streams)"
note "Cada incidencia queda en un log ordenado y limitado (~10.000 entradas)."
note "IDMPAUTO (Redis 8.6): si el replay reenvía el mismo evento, no se duplica."
r XADD events:trains IDMPAUTO replay MAXLEN '~' 10000 '*' type delay train renfe:5108J25500R2S line R2S delay_s 1500
r XADD events:trains IDMPAUTO replay MAXLEN '~' 10000 '*' type delay train renfe:5108J25500R2S line R2S delay_s 1500
r XADD events:trains IDMPAUTO replay MAXLEN '~' 10000 '*' type stopped train renfe:5108J28254R2S line R2S station "El Prat de Llobregat"
r XLEN events:trains
note "Un grupo de consumidores reparte los eventos entre workers. Lo leído queda pendiente hasta XACK:"
r XGROUP CREATE events:trains alertas 0
r XREADGROUP GROUP alertas worker-1 COUNT 10 STREAMS events:trains '>'
ids=$("${CLI[@]}" XRANGE events:trains - + | grep -E '^[0-9]+-[0-9]+$')
r XPENDING events:trains alertas
# shellcheck disable=SC2086
r XACK events:trains alertas $ids
r XPENDING events:trains alertas

title "11. Aviso en directo (Pub/Sub)"
note "El replay avisa de cada minuto nuevo; el backend lo reenvía a la web. Devuelve cuántos"
note "clientes lo han recibido (ahora 0: nadie escucha). Si nadie escucha, el mensaje se pierde."
r PUBLISH ocemt:clock 2026-11-05T07:00:00Z

title "12. Limitar peticiones a la API (INCREX, Redis 8.8)"
note "Como mucho 5 peticiones por minuto por IP, en un solo comando atómico."
note "Respuesta: [valor, 1] si se acepta; [valor, 0] si supera el límite."
for _ in 1 2 3 4 5 6; do r INCREX ratelimit:api:203.0.113.7 BYINT 1 UBOUND 5 EX 60 ENX; done

title "13. Mirar dentro de Redis"
r DBSIZE
r INFO keyspace
printf '\033[1m> INFO memory (resumen)\033[0m\n'
"${CLI[@]}" INFO memory | grep -E '^(used_memory_human|maxmemory_human|maxmemory_policy):'
note "Recorrer claves por patrón con SCAN (nunca KEYS: bloquea Redis si hay muchas):"
r --scan --pattern 'train:*'
note "Comandos lentos registrados (más de 1 ms):"
r SLOWLOG GET 3

printf '\n\033[1;32mListo.\033[0m Abre http://localhost:5540 → OCEMT (local) → Browser para ver las claves.\n'
printf 'Los trenes caducan en %s s. Para borrar todo: bash redis/demo/tour.sh --clean\n' "$TTL"
