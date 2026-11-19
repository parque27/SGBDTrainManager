#!/usr/bin/env bash
# Load every file in data/ into PostgreSQL/PostGIS (schema "import", one table per file).
# Run from anywhere:  bash data/load/load.sh
#
# Default: starts a throwaway container "ocemt-pg" (postgis/postgis:18-3.7) with data/ mounted read-only at /data.
# Set OCEMT_PG_PORT to publish it on another host port than 5432.
# To load into a server you already have, set PGHOST (and PGPORT, PGUSER, PGDATABASE, PGPASSWORD as needed).
# That path runs psql and gzip on this machine (client-side \copy, load_client.sql): no superuser needed, but the
# server needs PostGIS (or the right to create it) and psql and gzip must be on PATH.
set -euo pipefail
export MSYS_NO_PATHCONV=1           # Git Bash: do not rewrite /data/... arguments into Windows paths

IMAGE="postgis/postgis:18-3.7"
NAME="ocemt-pg"
cd "$(dirname "$0")/../.."          # repository root, so that $PWD/data is this data folder
[ -f data/manifest.csv ] || { echo "data/manifest.csv not found: run this script from the repository" >&2; exit 1; }

if [ -n "${PGHOST:-}" ]; then
    for tool in psql gzip; do
        command -v "$tool" >/dev/null || { echo "$tool is not on PATH (needed to load into $PGHOST)" >&2; exit 1; }
    done
    echo "Loading into the existing server at $PGHOST (files are read on this machine)"
    psql -v ON_ERROR_STOP=1 -f data/load/create_import_tables.sql -f data/load/load_client.sql
    exit 0
fi

command -v docker >/dev/null || { echo "Docker is not installed or not on PATH" >&2; exit 1; }
HOST_DATA="$PWD/data"
if pwd -W >/dev/null 2>&1; then HOST_DATA="$(pwd -W)/data"; fi   # Git Bash: give Docker a C:/... path
if [ -n "$(docker ps -aq --filter "name=^${NAME}$")" ]; then
    echo "Reusing the existing container $NAME (remove it with: docker rm -fv $NAME)"
    docker start "$NAME" >/dev/null
else
    docker run -d --name "$NAME" -e POSTGRES_PASSWORD=ocemt -p "127.0.0.1:${OCEMT_PG_PORT:-5432}:5432" \
        -v "$HOST_DATA:/data:ro" "$IMAGE" >/dev/null
fi

echo -n "Waiting for PostgreSQL"
# The first start runs a temporary server on the socket only; wait for the real one on TCP.
for _ in $(seq 1 120); do
    if docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 -q; then break; fi
    echo -n "."; sleep 1
done
echo
docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 -q || { echo "PostgreSQL did not start; see: docker logs $NAME" >&2; exit 1; }

docker exec "$NAME" psql -U postgres -v ON_ERROR_STOP=1 -f /data/load/create_import_tables.sql -f /data/load/load.sql
echo "Done. SQL prompt: docker exec -it $NAME psql -U postgres"
