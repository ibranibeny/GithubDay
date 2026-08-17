"""Client-safe error surfaces: generic 500s, CORS on failures, log hygiene."""

import logging

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.requests import Request

from cost_copilot.errors import INTERNAL_ERROR_DETAIL, http_exception_handler
from cost_copilot.main import create_app

ALLOWED_ORIGIN = "http://localhost:5173"
SENSITIVE_DETAIL = "AccountKey=super-secret-value"
CALLER_CREDENTIAL = "eyJhbGciOiJSUzI1NiJ9.header-secret.signature"


def build_app() -> FastAPI:
    app = create_app()

    @app.get("/boom")
    def boom() -> None:
        raise RuntimeError(SENSITIVE_DETAIL)

    @app.get("/teapot")
    def teapot() -> None:
        raise StarletteHTTPException(status_code=418, detail="I am a teapot")

    return app


def build_client() -> TestClient:
    return TestClient(build_app(), raise_server_exceptions=False)


def test_unhandled_error_returns_a_static_500_without_leaking() -> None:
    response = build_client().get("/boom")

    assert response.status_code == 500
    assert response.json() == {"detail": INTERNAL_ERROR_DETAIL}
    assert SENSITIVE_DETAIL not in response.text
    assert "RuntimeError" not in response.text
    assert "Traceback" not in response.text


def test_unhandled_error_response_carries_cors_headers_for_an_allowed_origin() -> None:
    response = build_client().get("/boom", headers={"Origin": ALLOWED_ORIGIN})

    assert response.status_code == 500
    assert response.headers["access-control-allow-origin"] == ALLOWED_ORIGIN


def test_unhandled_error_does_not_expose_cors_headers_to_other_origins() -> None:
    response = build_client().get("/boom", headers={"Origin": "https://evil.example"})

    assert response.status_code == 500
    assert "access-control-allow-origin" not in response.headers


def test_unhandled_error_is_logged_without_the_caller_token(
    caplog: pytest.LogCaptureFixture,
) -> None:
    with caplog.at_level(logging.ERROR):
        build_client().get("/boom", headers={"Authorization": f"Bearer {CALLER_CREDENTIAL}"})

    assert "RuntimeError" in caplog.text
    assert CALLER_CREDENTIAL not in caplog.text


def test_unknown_path_keeps_its_404_semantics() -> None:
    response = build_client().get("/does-not-exist")

    assert response.status_code == 404
    assert response.json() == {"detail": "Not Found"}


def test_starlette_http_exception_is_rendered_as_json() -> None:
    response = build_client().get("/teapot")

    assert response.status_code == 418
    assert response.json() == {"detail": "I am a teapot"}


def test_non_http_exceptions_reaching_the_http_handler_are_sanitized() -> None:
    scope = {
        "type": "http",
        "method": "GET",
        "path": "/x",
        "headers": [],
        "query_string": b"",
        "scheme": "http",
        "server": ("testserver", 80),
    }

    response = http_exception_handler(Request(scope), RuntimeError(SENSITIVE_DETAIL))

    assert response.status_code == 500
    assert SENSITIVE_DETAIL.encode() not in response.body


def test_lifespan_traffic_passes_through_the_error_middleware() -> None:
    with TestClient(build_app(), raise_server_exceptions=False) as client:
        assert client.get("/health/live").status_code == 200
