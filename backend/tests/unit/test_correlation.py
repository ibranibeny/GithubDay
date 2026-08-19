"""Correlation id adoption, minting, echo, and the telemetry surface it adds.

The middleware is the only thing allowed to widen the Task 5 allowlist, so the
checks below do double duty: they prove the id reaches the server span and the
response header, and they prove the allowlist gained `correlation_id` and
nothing else.
"""

import logging
import re
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace import SpanKind

from cost_copilot.correlation import (
    CORRELATION_ID_HEADER,
    MAX_CORRELATION_ID_LENGTH,
    CorrelationIdMiddleware,
    normalize_correlation_id,
)
from cost_copilot.main import create_app
from cost_copilot.telemetry import (
    CORRELATION_ID_ATTRIBUTE,
    SAFE_ATTRIBUTE_NAMES,
    SENSITIVE_ATTRIBUTE_NAMES,
    SanitizingSpanProcessor,
    sanitize_attributes,
)

ORIGIN = "http://localhost:5173"
LEAK_PROBE = "sk-live-abcdef principal 9f3c at contoso-internal.example"
UUID_PATTERN = re.compile(
    r"\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z"
)


def a_client() -> TestClient:
    return TestClient(create_app())


def server_span_attributes(exporter: InMemorySpanExporter) -> dict[str, Any]:
    spans = [span for span in exporter.get_finished_spans() if span.kind is SpanKind.SERVER]
    assert spans, "the request produced no server span"
    return dict(spans[0].attributes or {})


@contextmanager
def traced(app: FastAPI | None = None) -> Iterator[tuple[TestClient, InMemorySpanExporter]]:
    """A client whose app is built *after* instrumentation, so the server span exists."""
    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SanitizingSpanProcessor())
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    FastAPIInstrumentor().instrument(tracer_provider=provider)
    try:
        yield (
            TestClient(app if app is not None else create_app(), raise_server_exceptions=False),
            exporter,
        )
    finally:
        FastAPIInstrumentor().uninstrument()


# --- normalize_correlation_id ----------------------------------------------


def test_a_well_formed_inbound_id_is_adopted_verbatim() -> None:
    given = "9f3c1d2e-0000-4000-8000-abcdefabcdef"

    assert normalize_correlation_id(given) == given


def test_a_missing_id_is_replaced_with_a_uuid4() -> None:
    minted = normalize_correlation_id(None)

    assert UUID_PATTERN.match(minted)
    assert uuid.UUID(minted).version == 4


def test_each_minted_id_is_distinct() -> None:
    assert len({normalize_correlation_id(None) for _ in range(50)}) == 50


def test_an_id_at_the_length_limit_is_adopted() -> None:
    given = "a" * MAX_CORRELATION_ID_LENGTH

    assert normalize_correlation_id(given) == given


@pytest.mark.parametrize(
    "given",
    [
        pytest.param("", id="empty"),
        pytest.param("a" * (MAX_CORRELATION_ID_LENGTH + 1), id="oversized"),
        pytest.param("has spaces", id="space"),
        pytest.param("id\r\nX-Injected: 1", id="header-injection"),
        pytest.param("id\nX-Injected: 1", id="bare-newline"),
        pytest.param("<script>alert(1)</script>", id="markup"),
        pytest.param("id\x00null", id="nul-byte"),
        pytest.param("caf\u00e9", id="non-ascii"),
        pytest.param(LEAK_PROBE, id="leak-probe"),
    ],
)
def test_an_invalid_id_is_replaced_rather_than_escaped(given: str) -> None:
    minted = normalize_correlation_id(given)

    assert minted != given
    assert UUID_PATTERN.match(minted)


# --- the response header ----------------------------------------------------


def test_an_inbound_id_is_echoed_back() -> None:
    given = "9f3c1d2e-0000-4000-8000-abcdefabcdef"

    response = a_client().get("/health/live", headers={CORRELATION_ID_HEADER: given})

    assert response.headers[CORRELATION_ID_HEADER] == given


def test_a_request_without_an_id_is_answered_with_a_minted_one() -> None:
    response = a_client().get("/health/live")

    assert UUID_PATTERN.match(response.headers[CORRELATION_ID_HEADER])


def test_an_invalid_inbound_id_is_not_echoed_back() -> None:
    response = a_client().get("/health/live", headers={CORRELATION_ID_HEADER: "not a valid id"})

    echoed = response.headers[CORRELATION_ID_HEADER]
    assert echoed != "not a valid id"
    assert UUID_PATTERN.match(echoed)


def test_an_oversized_inbound_id_is_not_echoed_back() -> None:
    oversized = "a" * (MAX_CORRELATION_ID_LENGTH + 1)

    response = a_client().get("/health/live", headers={CORRELATION_ID_HEADER: oversized})

    assert response.headers[CORRELATION_ID_HEADER] != oversized
    assert UUID_PATTERN.match(response.headers[CORRELATION_ID_HEADER])


def test_the_header_is_present_on_an_error_response_too() -> None:
    given = "0000aaaa-0000-4000-8000-00000000beef"

    response = a_client().get("/no-such-route", headers={CORRELATION_ID_HEADER: given})

    assert response.status_code == 404
    assert response.headers[CORRELATION_ID_HEADER] == given


def test_the_header_survives_an_unhandled_error_and_the_body_stays_generic() -> None:
    app = create_app()

    @app.get("/boom")
    def boom() -> None:
        raise RuntimeError(LEAK_PROBE)

    given = "0000bbbb-0000-4000-8000-00000000cafe"
    client = TestClient(app, raise_server_exceptions=False)

    response = client.get("/boom", headers={CORRELATION_ID_HEADER: given})

    assert response.status_code == 500
    assert response.headers[CORRELATION_ID_HEADER] == given
    assert response.json() == {"detail": "Internal server error"}
    assert given not in response.text


# --- CORS -------------------------------------------------------------------


def test_the_preflight_allows_the_correlation_and_trace_headers() -> None:
    response = a_client().options(
        "/health/live",
        headers={
            "Origin": ORIGIN,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization,content-type,x-correlation-id",
        },
    )

    assert response.status_code == 200
    allowed = response.headers["access-control-allow-headers"].lower()
    assert "x-correlation-id" in allowed
    assert "traceparent" in allowed
    assert "authorization" in allowed
    assert "content-type" in allowed


def test_a_preflight_naming_only_the_correlation_header_is_not_rejected() -> None:
    response = a_client().options(
        "/health/live",
        headers={
            "Origin": ORIGIN,
            "Access-Control-Request-Method": "GET",
            "Access-Control-Request-Headers": "x-correlation-id",
        },
    )

    assert response.status_code == 200
    assert response.text != "Disallowed CORS headers"


def test_the_browser_may_read_the_echoed_correlation_header() -> None:
    response = a_client().get("/health/live", headers={"Origin": ORIGIN})

    exposed = response.headers["access-control-expose-headers"].lower()
    assert "x-correlation-id" in exposed


# --- the span ---------------------------------------------------------------


def test_an_inbound_id_lands_on_the_server_span() -> None:
    given = "9f3c1d2e-0000-4000-8000-abcdefabcdef"

    with traced() as (client, exporter):
        client.get("/health/live", headers={CORRELATION_ID_HEADER: given})

    assert server_span_attributes(exporter)[CORRELATION_ID_ATTRIBUTE] == given


def test_a_minted_id_lands_on_the_server_span_and_matches_the_header() -> None:
    with traced() as (client, exporter):
        response = client.get("/health/live")

    attributes = server_span_attributes(exporter)
    assert attributes[CORRELATION_ID_ATTRIBUTE] == response.headers[CORRELATION_ID_HEADER]


def test_an_invalid_inbound_id_never_reaches_the_span() -> None:
    with traced() as (client, exporter):
        client.get("/health/live", headers={CORRELATION_ID_HEADER: LEAK_PROBE})

    attributes = server_span_attributes(exporter)
    assert attributes[CORRELATION_ID_ATTRIBUTE] != LEAK_PROBE
    assert LEAK_PROBE not in str(attributes)


def test_the_server_span_still_carries_only_allowlisted_attributes() -> None:
    with traced() as (client, exporter):
        client.get("/health/live")

    assert set(server_span_attributes(exporter)) <= SAFE_ATTRIBUTE_NAMES


# --- the allowlist ----------------------------------------------------------


def test_the_allowlist_admits_the_correlation_id() -> None:
    assert CORRELATION_ID_ATTRIBUTE in SAFE_ATTRIBUTE_NAMES


def test_the_correlation_id_is_not_also_on_the_denylist() -> None:
    assert CORRELATION_ID_ATTRIBUTE not in SENSITIVE_ATTRIBUTE_NAMES
    assert not SAFE_ATTRIBUTE_NAMES & SENSITIVE_ATTRIBUTE_NAMES


def test_the_sanitizer_keeps_the_correlation_id_and_still_drops_everything_sensitive() -> None:
    output = sanitize_attributes(
        {
            CORRELATION_ID_ATTRIBUTE: "9f3c1d2e-0000-4000-8000-abcdefabcdef",
            "prompt": LEAK_PROBE,
            "answer": LEAK_PROBE,
            "token": LEAK_PROBE,
            "authorization": LEAK_PROBE,
            "url": LEAK_PROBE,
            "http.url": LEAK_PROBE,
            "subscription_id": LEAK_PROBE,
            "tenant_id": LEAK_PROBE,
            "connection_string": LEAK_PROBE,
        }
    )

    assert output == {CORRELATION_ID_ATTRIBUTE: "9f3c1d2e-0000-4000-8000-abcdefabcdef"}


@pytest.mark.parametrize("name", sorted(SENSITIVE_ATTRIBUTE_NAMES))
def test_every_named_sensitive_attribute_is_still_dropped(name: str) -> None:
    assert sanitize_attributes({name: LEAK_PROBE, CORRELATION_ID_ATTRIBUTE: "abc"}) == {
        CORRELATION_ID_ATTRIBUTE: "abc"
    }


# --- discipline -------------------------------------------------------------


def test_the_correlation_id_is_never_logged(caplog: pytest.LogCaptureFixture) -> None:
    given = "0000cccc-0000-4000-8000-00000000d00d"

    with caplog.at_level(logging.DEBUG):
        a_client().get("/health/live", headers={CORRELATION_ID_HEADER: given})

    assert given not in caplog.text


async def test_a_non_http_scope_is_passed_through_untouched() -> None:
    seen: list[str] = []

    async def app(scope: Any, receive: Any, send: Any) -> None:
        seen.append(scope["type"])

    async def receive() -> Any:  # pragma: no cover - never awaited
        raise AssertionError("receive must not be called")

    async def send(message: Any) -> None:  # pragma: no cover - never called
        raise AssertionError("send must not be called")

    await CorrelationIdMiddleware(app)({"type": "lifespan"}, receive, send)

    assert seen == ["lifespan"]


def test_the_middleware_runs_inside_the_traced_stack() -> None:
    """A span attribute only sticks if the server span is already current here."""
    with traced() as (client, exporter):
        client.get("/health/live")

    assert CORRELATION_ID_ATTRIBUTE in server_span_attributes(exporter)
