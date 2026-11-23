from fastapi import APIRouter, Response, status

from app import cache, db

router = APIRouter(tags=["health"])


@router.get("/health")
async def health(response: Response) -> dict:
    """Checks both databases. 200 if both answer, 503 otherwise."""
    result: dict = {"postgres": {"ok": False}, "redis": {"ok": False}}

    try:
        row = await db.fetch_one("SELECT version() AS version, postgis_lib_version() AS postgis")
        result["postgres"] = {"ok": True, "version": row["version"].split(" on ")[0], "postgis": row["postgis"]}
    except Exception as exc:  # noqa: BLE001 - report any failure
        result["postgres"]["error"] = f"{type(exc).__name__}: {exc}"

    try:
        await cache.get_redis().ping()
        info = await cache.get_redis().info("server")
        result["redis"] = {"ok": True, "version": info.get("redis_version")}
    except Exception as exc:  # noqa: BLE001
        result["redis"]["error"] = f"{type(exc).__name__}: {exc}"

    healthy = result["postgres"]["ok"] and result["redis"]["ok"]
    result["status"] = "ok" if healthy else "degraded"
    if not healthy:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return result
