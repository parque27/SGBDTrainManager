"""Unit tests for the cache-aside helper (no real Redis needed)."""

import asyncio

import pytest
from redis.exceptions import ConnectionError as RedisConnectionError

from app import cache


class FakeRedis:
    def __init__(self, fail: bool = False):
        self.store: dict[str, str] = {}
        self.ttls: dict[str, int] = {}
        self.fail = fail

    async def get(self, key):
        if self.fail:
            raise RedisConnectionError("down")
        return self.store.get(key)

    async def set(self, key, value, ex=None):
        if self.fail:
            raise RedisConnectionError("down")
        self.store[key] = value
        self.ttls[key] = ex


@pytest.fixture
def fake(monkeypatch):
    def _install(**kwargs):
        redis = FakeRedis(**kwargs)
        monkeypatch.setattr(cache, "_redis", redis)
        monkeypatch.setattr(cache, "_default_ttl", 300)
        return redis

    return _install


def counting_loader(value):
    calls = {"n": 0}

    async def loader():
        calls["n"] += 1
        return value

    return loader, calls


def test_miss_then_hit(fake):
    redis = fake()
    loader, calls = counting_loader([{"route_id": "renfe:R1"}])

    first = asyncio.run(cache.get_or_set("k", loader, ttl=60))
    second = asyncio.run(cache.get_or_set("k", loader, ttl=60))

    assert first == ([{"route_id": "renfe:R1"}], "database")
    assert second == ([{"route_id": "renfe:R1"}], "cache")
    assert calls["n"] == 1  # PostgreSQL queried only once
    assert redis.ttls["k"] == 60


def test_default_ttl(fake):
    redis = fake()
    loader, _ = counting_loader({"a": 1})
    asyncio.run(cache.get_or_set("k", loader))
    assert redis.ttls["k"] == 300


def test_redis_down_falls_back_to_loader(fake):
    fake(fail=True)
    loader, calls = counting_loader({"a": 1})

    value, source = asyncio.run(cache.get_or_set("k", loader))

    assert (value, source) == ({"a": 1}, "database")
    assert calls["n"] == 1


def test_miss_and_hit_return_the_same_json(fake):
    """Dates and Decimals from PostgreSQL must look the same whether they come from the DB or from Redis."""
    from datetime import datetime, timezone
    from decimal import Decimal

    fake()
    row = {"time": datetime(2026, 11, 5, 7, 0, tzinfo=timezone.utc), "pct": Decimal("97.50")}
    loader, _ = counting_loader([row])

    miss, _ = asyncio.run(cache.get_or_set("k", loader))
    hit, source = asyncio.run(cache.get_or_set("k", loader))

    assert source == "cache"
    assert miss == hit == [{"time": "2026-11-05T07:00:00+00:00", "pct": 97.5}]
