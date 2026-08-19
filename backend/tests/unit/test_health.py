import logging
from collections.abc import Awaitable, Callable

import pytest
from fastapi.testclient import TestClient

from cost_copilot.main import app, create_app
from cost_copilot.routers.health import get_readiness_checker

ReadinessCheckerStub = Callable[[], Awaitable[None]]


def build_client(checker: ReadinessCheckerStub | None = None) -> TestClient:
    application = create_app()
    if checker is not None:
        application.dependency_overrides[get_readiness_checker] = lambda: checker
    return TestClient(application)


def test_liveness_is_public() -> None:
    response = TestClient(app).get("/health/live")

    assert response.status_code == 200
    assert response.json() == {"status": "alive"}


def test_liveness_does_not_require_authentication() -> None:
    assert build_client().get("/health/live").status_code == 200


def test_readiness_uses_a_no_network_checker_by_default() -> None:
    response = build_client().get("/health/ready")

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_readiness_reports_success_from_an_injected_checker() -> None:
    calls: list[int] = []

    async def checker() -> None:
        calls.append(1)

    response = build_client(checker).get("/health/ready")

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
    assert calls == [1]


def test_readiness_failure_is_generic_and_never_leaks_details() -> None:
    async def checker() -> None:
        raise RuntimeError("cost management preflight failed for https://internal.example")

    response = build_client(checker).get("/health/ready")

    assert response.status_code == 503
    assert response.json() == {"detail": "dependencies unavailable"}
    assert "internal.example" not in response.text
    assert "preflight" not in response.text


def test_cors_allows_only_configured_origins() -> None:
    client = build_client()

    allowed = client.get("/health/live", headers={"Origin": "http://localhost:5173"})
    rejected = client.get("/health/live", headers={"Origin": "https://evil.example"})

    assert allowed.headers["access-control-allow-origin"] == "http://localhost:5173"
    assert "access-control-allow-origin" not in rejected.headers


def test_cors_does_not_allow_credentials() -> None:
    response = build_client().options(
        "/health/live",
        headers={
            "Origin": "http://localhost:5173",
            "Access-Control-Request-Method": "GET",
            "Access-Control-Request-Headers": "authorization",
        },
    )

    assert response.status_code == 200
    assert "access-control-allow-credentials" not in response.headers
    assert "authorization" in response.headers["access-control-allow-headers"].lower()


def test_readiness_failure_is_logged_without_dependency_details(
    caplog: pytest.LogCaptureFixture,
) -> None:
    async def checker() -> None:
        raise RuntimeError("preflight failed for https://internal.example")

    with caplog.at_level(logging.WARNING):
        build_client(checker).get("/health/ready")

    assert "Readiness check failed (RuntimeError)" in caplog.text
    assert "internal.example" not in caplog.text
    assert "preflight" not in caplog.text


def test_cost_and_chat_routes_are_not_registered_yet() -> None:
    paths: set[str] = set(create_app().openapi()["paths"])

    assert "/health/live" in paths
    assert "/health/ready" in paths
    assert not any(path.startswith(("/costs", "/chat")) for path in paths)
