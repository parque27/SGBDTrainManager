"""PostgreSQL/PostGIS access: one async connection pool shared by the whole app."""

from typing import Any

from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

from app.config import Settings

_pool: AsyncConnectionPool | None = None


async def open_pool(settings: Settings) -> None:
    global _pool
    _pool = AsyncConnectionPool(
        conninfo=settings.postgres_conninfo,
        min_size=settings.postgres_pool_min,
        max_size=settings.postgres_pool_max,
        kwargs={"row_factory": dict_row},
        timeout=settings.postgres_pool_timeout,
        open=False,
    )
    # wait=False: the API still starts if the database is not ready yet; /health reports it.
    await _pool.open(wait=False)


async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def get_pool() -> AsyncConnectionPool:
    if _pool is None:
        raise RuntimeError("PostgreSQL pool is not open")
    return _pool


async def fetch_all(query: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    async with get_pool().connection() as conn:
        cur = await conn.execute(query, params)
        return await cur.fetchall()


async def fetch_one(query: str, params: dict[str, Any] | None = None) -> dict[str, Any] | None:
    async with get_pool().connection() as conn:
        cur = await conn.execute(query, params)
        return await cur.fetchone()
