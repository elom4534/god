from pydantic_settings import BaseSettings
from functools import lru_cache

class Settings(BaseSettings):
    port: int = 8000
    database_url: str = "postgresql+asyncpg://preduser:predpass@localhost:5432/preddb"
    redis_url: str = "redis://localhost:6379"
    live_football_api_key: str = "mock"
    model_store_path: str = "./models_store"
    minio_endpoint: str = "http://localhost:9000"
    margin_threshold_default: float = 5.0
    model_version: str = "v0.3.0-mvp"

    class Config:
        env_file = ".env"
        extra = "allow"

@lru_cache
def get_settings() -> Settings:
    return Settings()
