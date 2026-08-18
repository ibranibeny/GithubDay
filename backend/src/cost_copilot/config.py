"""Application configuration loaded from the environment."""

from functools import lru_cache
from pathlib import Path
from uuid import UUID

from pydantic import AnyHttpUrl, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# Resolved from this module's location so the dotenv file is always the one that
# belongs to the backend project, never one that happens to sit in the caller's
# working directory.
ENV_FILE = Path(__file__).resolve().parents[2] / ".env"


class Settings(BaseSettings):
    """Runtime settings; environment variables always win over the dotenv file."""

    model_config = SettingsConfigDict(env_file=ENV_FILE, env_file_encoding="utf-8", extra="ignore")

    azure_tenant_id: UUID
    azure_subscription_id: UUID
    azure_client_id: str | None = None
    entra_api_client_id: str
    foundry_endpoint: AnyHttpUrl
    foundry_deployment: str = "gpt-5.4-mini"
    applicationinsights_connection_string: str | None = None
    app_environment: str = "local"
    allowed_origins: str = "http://localhost:5173"

    @field_validator("allowed_origins")
    @classmethod
    def _reject_wildcard(cls, value: str) -> str:
        if any(origin.strip() == "*" for origin in value.split(",")):
            raise ValueError("wildcard origins are not allowed; list every browser origin")
        return value

    @property
    def cors_origins(self) -> list[str]:
        return [origin.strip() for origin in self.allowed_origins.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]  # values come from the environment
