"""Integration tests against the real PostgreSQL and Redis of docker compose.

Run inside the backend container:  docker compose exec backend pytest
"""

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.routers.routes import ROUTES_KEY


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:  # runs the lifespan: opens the pool and the Redis client
        yield c


def test_health_both_databases_ok(client):
    r = client.get("/health")
    body = r.json()
    assert r.status_code == 200, body
    assert body["status"] == "ok"
    assert body["postgres"]["ok"] and body["postgres"]["postgis"]
    assert body["redis"]["ok"]


def test_routes_miss_then_hit(client):
    from app import cache

    client.portal.call(cache.invalidate, ROUTES_KEY)

    first = client.get("/routes")
    if first.status_code == 503:
        pytest.skip("import.routes not loaded: " + first.json()["detail"])
    second = client.get("/routes")

    assert first.status_code == second.status_code == 200
    assert first.headers["X-Cache"] == "MISS"
    assert second.headers["X-Cache"] == "HIT"
    assert first.json() == second.json()
    assert len(first.json()) == 219  # rows in data/manifest.csv
