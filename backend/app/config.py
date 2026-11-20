"""Server settings, read from environment variables (or a .env file when run outside Docker)."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=(".env", "../.env"), extra="ignore")

    # PostgreSQL / PostGIS (source of truth)
    postgres_host: str = "localhost"
    postgres_port: int = 5432
    postgres_user: str = "root"
    postgres_password: str = "root"
    postgres_db: str = "ocemt"
    postgres_pool_min: int = 1
    postgres_pool_max: int = 10

    # Redis (cache, read first)
    redis_host: str = "localhost"
    redis_port: int = 6379
    redis_db: int = 0
    cache_default_ttl: int = 300  # seconds

    # Frontend origins allowed to call the API
    cors_origins: list[str] = ["http://localhost:8100", "http://localhost:5173"]

    @property
    def postgres_conninfo(self) -> str:
        return (
            f"host={self.postgres_host} port={self.postgres_port} "
            f"dbname={self.postgres_db} user={self.postgres_user} "
            f"password={self.postgres_password} connect_timeout=5"
        )

    @property
    def redis_url(self) -> str:
        return f"redis://{self.redis_host}:{self.redis_port}/{self.redis_db}"


@lru_cache
def get_settings() -> Settings:
    return Settings()
