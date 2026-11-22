"""Example endpoint using the cache: the list of lines.

Reads `public.routes` (KAN-9). Cache key follows redis/docs/modelo-de-claves.md (`cache:v1:...`).
The `X-Cache` response header says where the answer came from: HIT (Redis) or MISS (PostgreSQL).
"""

from fastapi import APIRouter, HTTPException, Response
from psycopg.errors import UndefinedTable

from app import cache, db

router = APIRouter(prefix="/routes", tags=["network"])

ROUTES_KEY = "cache:v1:routes:all"
ROUTES_TTL = 3600  # static network data: one hour


async def _load_routes() -> list[dict]:
    return await db.fetch_all(
        """
        SELECT route_id, operator, service, short_name, long_name, color
        FROM public.routes
        ORDER BY operator, short_name
        """
    )


@router.get("")
async def list_routes(response: Response) -> list[dict]:
    try:
        routes, source = await cache.get_or_set(ROUTES_KEY, _load_routes, ttl=ROUTES_TTL)
    except UndefinedTable as exc:
        raise HTTPException(
            status_code=503,
            detail="Table public.routes not found: the database was created before db/init existed, "
            "recreate it with `docker compose down -v && docker compose up -d --build`.",
        ) from exc
    response.headers["X-Cache"] = "HIT" if source == "cache" else "MISS"
    return routes
