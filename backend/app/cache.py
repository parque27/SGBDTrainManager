"""Redis cache with the cache-aside pattern.

Read path for every cached endpoint:
    1. look the key up in Redis      -> hit: return it
    2. miss: run the loader (PostgreSQL), store the result in Redis with a TTL, return it

PostgreSQL is the source of truth. Redis only keeps copies that may expire or be flushed,
so if Redis is empty or down the loader is used and the API keeps working (just slower).
"""

import json
import logging
from collections.abc import Awaitable, Callable
from typing import Any, Literal

from fastapi.encoders import jsonable_encoder
from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.config import Settings

log = logging.getLogger(__name__)

CacheSource = Literal["cache", "database"]

_redis: Redis | None = None
_default_ttl: int = 300


async def open_redis(settings: Settings) -> None:
    global _redis, _default_ttl
    _redis = Redis.from_url(
        settings.redis_url,
        # Redis ACL user (redis/docs/tecnicas.md §6). Empty = no ACL yet: connect without a user.
        username=settings.redis_username or None,
        password=settings.redis_password or None,
        decode_responses=True,
        socket_connect_timeout=2,
        socket_timeout=2,
    )
    _default_ttl = settings.cache_default_ttl


async def close_redis() -> None:
    global _redis
    if _redis is not None:
        await _redis.aclose()
        _redis = None


def get_redis() -> Redis:
    if _redis is None:
        raise RuntimeError("Redis client is not open")
    return _redis


async def get_or_set(
    key: str,
    loader: Callable[[], Awaitable[Any]],
    ttl: int | None = None,
) -> tuple[Any, CacheSource]:
    """Return (value, source). `loader` must return something JSON-serialisable."""
    redis = get_redis()
    try:
        cached = await redis.get(key)
        if cached is not None:
            return json.loads(cached), "cache"
    except RedisError as exc:
        log.warning("Redis read failed for %s, falling back to PostgreSQL: %s", key, exc)

    # Encode once, the same way FastAPI does, and return that same value: otherwise a MISS returns
    # datetime/Decimal objects (FastAPI writes "2026-11-05T07:00:00+00:00", numbers) while a HIT returns
    # whatever json.dumps stored, and the two responses differ.
    value = jsonable_encoder(await loader())

    try:
        await redis.set(key, json.dumps(value), ex=ttl or _default_ttl)
    except RedisError as exc:
        log.warning("Redis write failed for %s: %s", key, exc)

    return value, "database"


async def invalidate(*keys: str) -> None:
    if keys:
        await get_redis().delete(*keys)
