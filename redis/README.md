# Redis de OCEMT

Capa de Redis del proyecto: el estado "en vivo" de los trenes, las cachés de las consultas a
PostgreSQL y la mensajería. Postgres es la fuente de verdad; todo lo que hay en Redis se puede
reconstruir desde ahí.

Los servicios `redis` (Redis 8.10.3), `redisinsight` y `replay` están en el
[`docker-compose.yml`](../docker-compose.yml) común. Esta carpeta tiene su código, su configuración
y su documentación:

| Archivo | Qué es |
|---|---|
| [`redis.conf`](redis.conf) | Configuración comentada: memoria, persistencia, diagnóstico. El compose la monta en el contenedor |
| [`replay/`](replay/) | El replay: llena Redis con los trenes, minuto a minuto, leyendo de Postgres |
| [`docs/modelo-de-claves.md`](docs/modelo-de-claves.md) | **Contrato con el backend**: qué claves hay, quién las escribe y quién las lee |
| [`docs/recetario-backend.md`](docs/recetario-backend.md) | **Cómo leerlo desde el backend**: cada pantalla con su comando de Redis y código Python probado |
| [`docs/tecnicas.md`](docs/tecnicas.md) | Qué funcionalidades de Redis usamos, por qué y cómo explicarlas |
| [`demo/tour.sh`](demo/tour.sh) | Recorrido por todas las técnicas con datos reales |

## Arrancar

Necesitas Docker Desktop abierto. Desde la raíz del repo, la primera vez:

```bash
cp .env.example .env
```

Y para arrancarlo todo:

```bash
docker compose up -d
```

- **Redis**: `localhost:6379` (solo desde tu ordenador).
- **Redis Insight**: http://localhost:5540. La primera vez acepta las condiciones y añade la base de
  datos con host `redis` y puerto `6379`: dentro de Docker, Redis se llama por su nombre de servicio,
  no `localhost`.
- **Replay**: empieza solo y en unos segundos verás los trenes en Redis Insight (ver abajo).

Consola de Redis:

```bash
docker compose exec redis redis-cli
```

## Replay: los trenes en vivo

[`replay/replay.py`](replay/replay.py) reproduce en Redis los 5 días grabados, minuto a minuto, según
`docs/modelo-de-claves.md`. Cada minuto hace una consulta a `public.positions` (`WHERE time = …`, que
usa el índice por `time`) y escribe el resultado en Redis en una sola transacción.

Lo arranca el docker-compose (servicio `replay`). La primera vez que se levanta todo, Postgres tarda
~1 minuto en cargar los datos; mientras tanto el replay escribe "Esperando a que PostgreSQL tenga los
datos cargados…" y empieza solo cuando están.

| Para | Comando |
|---|---|
| Ver lo que hace | `docker compose logs -f replay` |
| Pararlo / arrancarlo | `docker compose stop replay` / `docker compose start replay` |
| Volver a empezar desde el principio | `docker compose restart replay` |
| Aplicar cambios del código | `docker compose up -d --build replay` |

Se configura en el `.env`:
- `REPLAY_START`: primer minuto, en UTC. Por defecto `2026-11-05T05:00:00Z`, las 06:00 en Barcelona.
- `REPLAY_INTERVAL`: segundos reales por cada minuto de datos. Por defecto `2`, 30 veces más rápido.

Cuando llega al final de los datos, vuelve a empezar.

**Pausa, velocidad y saltos** (lo hará el backend desde la web; a mano, en `redis-cli` o en el Workbench
de Redis Insight):

```
HSET sim:control status paused                 # pausa  (status playing para seguir)
HSET sim:control speed 60                      # un minuto simulado por segundo real
HSET sim:control seek 2026-11-05T07:00:00Z     # saltar a las 08:00 de Barcelona (va en UTC)
DEL sim:control                                # volver a lo del .env
```

El estado se ve en la foto: `JSON.GET sim:snapshot $.simulated_at $.status $.speed`. Detalles en
[`docs/modelo-de-claves.md`](docs/modelo-de-claves.md).

**Si se cae Redis o Postgres**, el replay no se para: reintenta y sigue solo cuando vuelven
([`docs/tecnicas.md`](docs/tecnicas.md) §3.11).

**Sin Docker o sin Postgres** (por ejemplo, para probar cambios): se puede lanzar en local y leyendo
de los CSV de `data/`. Para el del compose antes (`docker compose stop replay`), porque escriben las
mismas claves.

```bash
python3 -m venv redis/replay/.venv && redis/replay/.venv/bin/pip install -r redis/replay/requirements.txt
```

```bash
redis/replay/.venv/bin/python redis/replay/replay.py --source csv
```

`demo/tour.sh` también usa las mismas claves: ejecútalo con el replay parado.

## Comandos útiles

| Para | Comando |
|---|---|
| Parar (los datos se quedan) | `docker compose stop redis redisinsight replay` |
| Borrar el contenedor y los datos de Redis | `docker compose rm -sf redis && docker volume rm ocemt_redis-data` |
| Ver los logs de Redis | `docker compose logs -f redis` |
| Borrar solo lo del recorrido | `bash redis/demo/tour.sh --clean` |
| Aplicar cambios de `redis.conf` | `docker compose restart redis` |

## Pendiente

- [x] Replay leyendo de PostgreSQL, dentro del docker-compose.
- [x] Recetario para el backend (`docs/recetario-backend.md`), probado con su cliente.
- [ ] Usuarios ACL `replay` y `backend` en un `users.acl` (ya probados, ver `docs/tecnicas.md` §6).
- [ ] Probar `TS.CREATERULE` y los compact hashes (`HIMPORT`).
- [ ] Benchmark Redis frente a Postgres (`docs/tecnicas.md` §8).
