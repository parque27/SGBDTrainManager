"""OCEMT API entry point.

Run locally:   uvicorn app.main:app --reload   (from backend/)
Run in Docker: docker compose up -d --build    (from the repository root)
"""

import asyncio
import logging
import socket
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from psycopg import OperationalError
from psycopg_pool import PoolTimeout

from app import cache, db
from app.config import get_settings
from app.routers import health, routes

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)


def _quiet_dns_errors(loop: asyncio.AbstractEventLoop, context: dict) -> None:
    """When the redis container is stopped, Docker's DNS stops resolving `redis`. redis-py gives up
    after its timeout (already logged by app.cache) but the DNS lookup finishes later, and asyncio
    logs that unread result as an ERROR. Downgrade only that case to DEBUG."""
    if isinstance(context.get("exception"), socket.gaierror):
        log.debug("Ignored late DNS failure: %s", context["exception"])
        return
    loop.default_exception_handler(context)


@asynccontextmanager
async def lifespan(_: FastAPI):
    asyncio.get_running_loop().set_exception_handler(_quiet_dns_errors)
    settings = get_settings()
    await db.open_pool(settings)
    await cache.open_redis(settings)
    yield
    await cache.close_redis()
    await db.close_pool()


app = FastAPI(title="OCEMT API", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=get_settings().cors_origins,
    allow_methods=["GET"],
    allow_headers=["*"],
    expose_headers=["X-Cache"],
)

@app.exception_handler(PoolTimeout)
@app.exception_handler(OperationalError)
async def database_unavailable(_: Request, exc: Exception) -> JSONResponse:
    """PostgreSQL down or still loading the data (db/init runs on first start): 503, not 500."""
    log.warning("PostgreSQL unavailable: %s", exc)
    return JSONResponse(status_code=503, content={"detail": "PostgreSQL is not available yet, try again."})


app.include_router(health.router)
app.include_router(routes.router)
