from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from pydantic import AnyHttpUrl

from conftest import (
    TEST_API_CLIENT_ID,
    TEST_FOUNDRY_ENDPOINT,
    TEST_SUBSCRIPTION_ID,
    TEST_TENANT_ID,
)
from cost_copilot import config
from cost_copilot.config import Settings, get_settings


def build_settings(**overrides: Any) -> Settings:
    """Unpacking keeps mypy from demanding fields that come from the environment."""
    return Settings(**overrides)


@pytest.fixture(autouse=True)
def _clear_settings_cache() -> Iterator[None]:
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def test_subscription_is_fixed_by_configuration() -> None:
    settings = Settings(
        azure_tenant_id=TEST_TENANT_ID,
        azure_subscription_id=TEST_SUBSCRIPTION_ID,
        entra_api_client_id=TEST_API_CLIENT_ID,
        foundry_endpoint=AnyHttpUrl(TEST_FOUNDRY_ENDPOINT),
        foundry_deployment="gpt-5.4-mini",
    )

    assert settings.azure_subscription_id == TEST_SUBSCRIPTION_ID


def test_optional_fields_have_safe_defaults() -> None:
    settings = build_settings()

    assert settings.azure_client_id is None
    assert settings.applicationinsights_connection_string is None
    assert settings.foundry_deployment == "gpt-5.4-mini"
    assert settings.allowed_origins == "http://localhost:5173"
    assert settings.cors_origins == ["http://localhost:5173"]


def test_missing_required_field_is_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ENTRA_API_CLIENT_ID", raising=False)

    with pytest.raises(ValueError, match="entra_api_client_id"):
        build_settings()


def test_env_file_is_resolved_relative_to_the_backend_project() -> None:
    backend_root = Path(config.__file__).resolve().parents[2]

    assert config.ENV_FILE == backend_root / ".env"
    assert config.ENV_FILE.is_absolute()
    assert Settings.model_config["env_file"] == config.ENV_FILE


def test_env_file_in_the_caller_working_directory_is_ignored(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    (tmp_path / ".env").write_text("FOUNDRY_DEPLOYMENT=from-caller-cwd\n", encoding="utf-8")
    monkeypatch.chdir(tmp_path)

    assert build_settings().foundry_deployment == "gpt-5.4-mini"


def test_environment_variables_stay_primary(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FOUNDRY_DEPLOYMENT", "gpt-from-environment")
    monkeypatch.setenv("ALLOWED_ORIGINS", "https://a.example, https://b.example ,")

    settings = build_settings()

    assert settings.foundry_deployment == "gpt-from-environment"
    assert settings.cors_origins == ["https://a.example", "https://b.example"]


def test_get_settings_is_cached() -> None:
    assert get_settings() is get_settings()
