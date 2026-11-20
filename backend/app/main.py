"""OCEMT API entry point.

Run locally:   uvicorn app.main:app --reload   (from backend/)
Run in Docker: docker compose up -d --build    (from the repository root)
"""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import cache, db
from app.config import get_settings
from app.routers import health, routes

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(_: FastAPI):
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

app.include_router(health.router)
app.include_router(routes.router)
