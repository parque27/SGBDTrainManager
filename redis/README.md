# Redis de OCEMT

Capa de Redis del proyecto: el estado "en vivo" de los trenes, las cachés de las consultas a
PostgreSQL y la mensajería. Postgres es la fuente de verdad; todo lo que hay en Redis se puede
reconstruir desde ahí.

Los servicios `redis` (Redis 8.10.3) y `redisinsight` están en el [`docker-compose.yml`](../docker-compose.yml)
común. Esta carpeta tiene su configuración y su documentación:

| Archivo | Qué es |
|---|---|
| [`redis.conf`](redis.conf) | Configuración comentada: memoria, persistencia, diagnóstico. El compose la monta en el contenedor |
| [`docs/modelo-de-claves.md`](docs/modelo-de-claves.md) | **Contrato con el backend**: qué claves hay, quién las escribe y quién las lee |
| [`docs/tecnicas.md`](docs/tecnicas.md) | Qué funcionalidades de Redis usamos, por qué y cómo explicarlas |
| [`demo/tour.sh`](demo/tour.sh) | Recorrido por todas las técnicas con datos reales |

## Arrancar

Necesitas Docker Desktop abierto. Desde la raíz del repo, la primera vez:

```bash
cp .env.example .env
```

Y para arrancar solo Redis y Redis Insight:

```bash
docker compose up -d redis redisinsight
```

- **Redis**: `localhost:6379` (solo desde tu ordenador).
- **Redis Insight**: http://localhost:5540. La primera vez acepta las condiciones y añade la base de
  datos con host `redis` y puerto `6379`: dentro de Docker, Redis se llama por su nombre de servicio,
  no `localhost`.

Recorrido con datos reales (crea ~26 claves; después míralas en Redis Insight → *Browser*):

```bash
bash redis/demo/tour.sh
```

Consola de Redis:

```bash
docker compose exec redis redis-cli
```

## Comandos útiles

| Para | Comando |
|---|---|
| Parar (los datos se quedan) | `docker compose stop redis redisinsight` |
| Borrar el contenedor y los datos de Redis | `docker compose rm -sf redis && docker volume rm ocemt_redis-data` |
| Ver los logs | `docker compose logs -f redis` |
| Borrar solo lo del recorrido | `bash redis/demo/tour.sh --clean` |
| Aplicar cambios de `redis.conf` | `docker compose restart redis` |

## Pendiente

- [ ] Worker de replay (Python, `redis-py`): Postgres → Redis minuto a minuto, según `docs/modelo-de-claves.md`.
- [ ] Módulo Python para el backend con las lecturas (trenes en el mapa, panel de estación, cachés).
- [ ] Usuarios ACL `replay` y `backend` en un `users.acl` (ya probados, ver `docs/tecnicas.md` §6).
- [ ] Probar `TS.CREATERULE` y los compact hashes (`HIMPORT`).
- [ ] Benchmark Redis frente a Postgres (`docs/tecnicas.md` §8).
