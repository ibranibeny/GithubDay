"""Telemetry wiring and attribute sanitization.

Nothing here reaches Azure. `configure_azure_monitor` is always replaced by a
fake, and every span and metric is read back from the OpenTelemetry SDK's
in-memory exporters, so the suite never opens a socket.
"""

import json
from collections.abc import Iterator
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient
from opentelemetry import metrics, trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import InMemoryMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace import SpanKind

from constants import TEST_SUBSCRIPTION_ID
from cost_copilot import main, telemetry
from cost_copilot.clients.cost_management import (
    API_VERSION,
    CostManagementClient,
    CostUpstreamError,
)
from cost_copilot.clients.foundry import FoundryChatClient
from cost_copilot.config import get_settings
from cost_copilot.models.cost import CostFilter, CostGrouping, CostMetric
from cost_copilot.telemetry import (
    COST_DEPENDENCY,
    DEPENDENCY_DURATION_METRIC,
    FOUNDRY_DEPENDENCY,
    SAFE_ATTRIBUTE_NAMES,
    SENSITIVE_ATTRIBUTE_NAMES,
    SERVICE_NAME,
    UNKNOWN_VERSION,
    SanitizingSpanProcessor,
    dependency_span,
    sanitize_attributes,
    setup_telemetry,
)

CONNECTION_STRING = "InstrumentationKey=00000000-0000-0000-0000-000000000000"
QUERY_URL = (
    f"https://management.azure.com/subscriptions/{TEST_SUBSCRIPTION_ID}"
    f"/providers/Microsoft.CostManagement/query?api-version={API_VERSION}"
)
LEAK_PROBE = "sk-live-abcdef principal 9f3c at contoso-internal.example"

SPANS = InMemorySpanExporter()
METRICS = InMemoryMetricReader()


@pytest.fixture(scope="module", autouse=True)
def _in_memory_pipeline() -> Iterator[None]:
    """One global SDK pipeline for this module; the global providers are set-once."""
    tracer_provider = TracerProvider()
    tracer_provider.add_span_processor(SanitizingSpanProcessor())
    tracer_provider.add_span_processor(SimpleSpanProcessor(SPANS))
    trace.set_tracer_provider(tracer_provider)
    metrics.set_meter_provider(MeterProvider(metric_readers=[METRICS]))
    yield


@pytest.fixture(autouse=True)
def _clean_slate(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    SPANS.clear()
    monkeypatch.setattr(telemetry, "_configured", False)
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


class _RecordingConfigure:
    """Stands in for `configure_azure_monitor`, which would open a socket."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def __call__(self, **kwargs: Any) -> None:
        self.calls.append(kwargs)


def a_configure(monkeypatch: pytest.MonkeyPatch) -> _RecordingConfigure:
    configure = _RecordingConfigure()
    monkeypatch.setattr(telemetry, "configure_azure_monitor", configure)
    return configure


def finished(kind: SpanKind | None = None) -> list[ReadableSpan]:
    spans = SPANS.get_finished_spans()
    return [span for span in spans if kind is None or span.kind is kind]


def attributes_of(span: ReadableSpan) -> dict[str, Any]:
    return dict(span.attributes or {})


# --- sanitize_attributes ----------------------------------------------------


def test_sensitive_fields_are_removed() -> None:
    output = sanitize_attributes(
        {
            "prompt": "show my costs",
            "answer": "USD 100",
            "authorization": "Bearer token",
            "dependency": "cost-management",
        }
    )

    assert output == {"dependency": "cost-management"}


@pytest.mark.parametrize("name", sorted(SENSITIVE_ATTRIBUTE_NAMES))
def test_every_named_sensitive_attribute_is_dropped(name: str) -> None:
    assert sanitize_attributes({name: LEAK_PROBE, "dependency": "x"}) == {"dependency": "x"}


@pytest.mark.parametrize(
    "name",
    [
        "dependency",
        "status",
        "status_code",
        "duration_ms",
        "row_count",
        "model",
        "deployment",
        "input_tokens",
        "output_tokens",
        "total_tokens",
        "environment",
        "http.method",
        "http.status_code",
    ],
)
def test_safe_attributes_are_kept(name: str) -> None:
    assert sanitize_attributes({name: 1}) == {name: 1}


def test_unknown_attributes_are_dropped_even_when_they_look_harmless() -> None:
    assert sanitize_attributes({"net.peer.ip": "10.0.0.1", "http.url": LEAK_PROBE}) == {}


def test_attribute_names_are_matched_case_insensitively() -> None:
    assert sanitize_attributes({"Authorization": LEAK_PROBE, "ResourceId": LEAK_PROBE}) == {}


def test_the_allowlist_and_the_denylist_never_overlap() -> None:
    assert not SAFE_ATTRIBUTE_NAMES & SENSITIVE_ATTRIBUTE_NAMES


# --- setup_telemetry --------------------------------------------------------


def test_setup_is_a_no_op_without_a_connection_string(monkeypatch: pytest.MonkeyPatch) -> None:
    configure = a_configure(monkeypatch)

    assert setup_telemetry(get_settings()) is False
    assert configure.calls == []


def test_setup_configures_once_when_a_connection_string_is_present(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    configure = a_configure(monkeypatch)
    monkeypatch.setenv("APPLICATIONINSIGHTS_CONNECTION_STRING", CONNECTION_STRING)

    assert setup_telemetry(get_settings()) is True
    assert setup_telemetry(get_settings()) is False
    assert len(configure.calls) == 1
    assert configure.calls[0]["connection_string"] == CONNECTION_STRING


def test_setup_reports_the_service_identity(monkeypatch: pytest.MonkeyPatch) -> None:
    configure = a_configure(monkeypatch)
    monkeypatch.setenv("APPLICATIONINSIGHTS_CONNECTION_STRING", CONNECTION_STRING)
    monkeypatch.setenv("APP_ENVIRONMENT", "prod")
    monkeypatch.setenv("GIT_SHA", "0f58c91")

    setup_telemetry(get_settings())

    resource = configure.calls[0]["resource"]
    assert isinstance(resource, Resource)
    assert resource.attributes["service.name"] == SERVICE_NAME
    assert resource.attributes["service.version"] == "0f58c91"
    assert resource.attributes["deployment.environment"] == "prod"


def test_the_service_version_falls_back_when_no_build_stamp_is_present(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    configure = a_configure(monkeypatch)
    monkeypatch.setenv("APPLICATIONINSIGHTS_CONNECTION_STRING", CONNECTION_STRING)
    monkeypatch.delenv("GIT_SHA", raising=False)
    monkeypatch.delenv("OTEL_SERVICE_VERSION", raising=False)

    setup_telemetry(get_settings())

    assert configure.calls[0]["resource"].attributes["service.version"] == UNKNOWN_VERSION


def test_an_explicit_service_version_wins_over_the_git_sha(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    configure = a_configure(monkeypatch)
    monkeypatch.setenv("APPLICATIONINSIGHTS_CONNECTION_STRING", CONNECTION_STRING)
    monkeypatch.setenv("OTEL_SERVICE_VERSION", "1.2.3")
    monkeypatch.setenv("GIT_SHA", "0f58c91")

    setup_telemetry(get_settings())

    assert configure.calls[0]["resource"].attributes["service.version"] == "1.2.3"


def test_setup_installs_the_sanitizing_span_processor(monkeypatch: pytest.MonkeyPatch) -> None:
    configure = a_configure(monkeypatch)
    monkeypatch.setenv("APPLICATIONINSIGHTS_CONNECTION_STRING", CONNECTION_STRING)

    setup_telemetry(get_settings())

    processors = configure.calls[0]["span_processors"]
    assert any(isinstance(processor, SanitizingSpanProcessor) for processor in processors)


# --- the sanitizing processor ----------------------------------------------


def test_the_processor_strips_attributes_that_bypassed_the_helper() -> None:
    tracer = trace.get_tracer("test")

    with tracer.start_as_current_span("manual") as span:
        span.set_attribute("dependency", "cost-management")
        span.set_attribute("prompt", LEAK_PROBE)
        span.set_attribute("http.url", LEAK_PROBE)

    assert attributes_of(finished()[0]) == {"dependency": "cost-management"}


# --- cost dependency spans --------------------------------------------------


def a_filter() -> CostFilter:
    return CostFilter.model_validate(
        {
            "start": "2026-08-01",
            "end": "2026-08-17",
            "metric": CostMetric.ACTUAL,
            "grouping": CostGrouping.SERVICE,
        }
    )


COST_PAGE: dict[str, Any] = {
    "properties": {
        "columns": [
            {"name": "totalCost", "type": "Number"},
            {"name": "ServiceName", "type": "String"},
            {"name": "Currency", "type": "String"},
        ],
        "rows": [[32.5, "Fabrikam Widget Service", "USD"], [1.0, "Storage", "USD"]],
        "nextLink": None,
    }
}


async def a_token() -> str:
    return "fake-access-token"  # noqa: S105 - a stub value, not a credential


def a_cost_client(handler: Any, acquire_token: Any = a_token) -> CostManagementClient:
    return CostManagementClient(
        settings=get_settings(),
        http_client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
        acquire_token=acquire_token,
        jitter=lambda: 0.0,
    )


async def test_the_cost_span_reports_row_count_and_never_the_rows() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert str(request.url) == QUERY_URL
        return httpx.Response(200, json=COST_PAGE)

    dataset = await a_cost_client(handler).run_query(a_filter(), "None")

    assert len(dataset.records) == 2
    span = finished(SpanKind.CLIENT)[0]
    assert attributes_of(span) | {"duration_ms": 0.0} == {
        "dependency": COST_DEPENDENCY,
        "status": "ok",
        "row_count": 2,
        "duration_ms": 0.0,
    }
    assert "Fabrikam Widget Service" not in json.dumps(attributes_of(span))


async def test_the_cost_span_records_a_failure_without_quoting_it() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text=LEAK_PROBE)

    with pytest.raises(CostUpstreamError):
        await a_cost_client(handler).run_query(a_filter(), "None")

    span = finished(SpanKind.CLIENT)[0]
    assert attributes_of(span)["status"] == "error"
    assert span.events == ()
    assert LEAK_PROBE not in str(span.status.description)


async def test_a_sensitive_attribute_injected_on_the_cost_span_is_stripped() -> None:
    async def leaking_token() -> str:
        trace.get_current_span().set_attribute("authorization", LEAK_PROBE)
        return "fake-access-token"  # noqa: S105 - a stub value, not a credential

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=COST_PAGE)

    await a_cost_client(handler, leaking_token).run_query(a_filter(), "None")

    assert "authorization" not in attributes_of(finished(SpanKind.CLIENT)[0])


async def test_the_cost_duration_is_recorded_as_a_metric() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=COST_PAGE)

    await a_cost_client(handler).run_query(a_filter(), "None")

    recorded = METRICS.get_metrics_data()
    points = [
        point
        for resource in (recorded.resource_metrics if recorded else [])
        for scope in resource.scope_metrics
        for metric in scope.metrics
        if metric.name == DEPENDENCY_DURATION_METRIC
        for point in metric.data.data_points
    ]
    assert points
    assert {"dependency": COST_DEPENDENCY, "status": "ok"} in [
        dict(point.attributes or {}) for point in points
    ]


# --- foundry dependency spans ----------------------------------------------


MODEL_OUTPUT: dict[str, Any] = {
    "answer": "Fabrikam Widget Service is the largest cost at 32.50 USD.",
    "evidence": [
        {
            "metric": "ActualCost",
            "dimension": "Fabrikam Widget Service",
            "periodStart": "2026-08-01",
            "periodEnd": "2026-08-17",
            "amount": 32.5,
        }
    ],
    "chartActions": [],
}


class _Usage:
    def __init__(self) -> None:
        self.input_tokens = 120
        self.output_tokens = 45
        self.total_tokens = 165


class _FakeResponse:
    def __init__(self, usage: object | None) -> None:
        self.output_text = json.dumps(MODEL_OUTPUT)
        if usage is not None:
            self.usage = usage


class _FakeResponses:
    def __init__(self, usage: object | None) -> None:
        self._usage = usage

    async def create(self, **kwargs: Any) -> Any:
        return _FakeResponse(self._usage)


class _FakeClient:
    def __init__(self, usage: object | None) -> None:
        self.responses = _FakeResponses(usage)

    async def close(self) -> None:  # pragma: no cover - the client does not own this fake
        raise AssertionError("the fake client is never closed")


async def test_the_foundry_span_reports_the_model_and_token_counts() -> None:
    client = FoundryChatClient(client=_FakeClient(_Usage()), model="gpt-5.4-mini")

    await client.respond(prompt=LEAK_PROBE, grounding={"currency": "USD"})

    attributes = attributes_of(finished(SpanKind.CLIENT)[0])
    assert attributes | {"duration_ms": 0.0} == {
        "dependency": FOUNDRY_DEPENDENCY,
        "status": "ok",
        "model": "gpt-5.4-mini",
        "input_tokens": 120,
        "output_tokens": 45,
        "total_tokens": 165,
        "duration_ms": 0.0,
    }
    assert LEAK_PROBE not in json.dumps(attributes)
    assert MODEL_OUTPUT["answer"] not in json.dumps(attributes)


async def test_the_foundry_span_survives_a_response_without_usage() -> None:
    client = FoundryChatClient(client=_FakeClient(None), model="gpt-5.4-mini")

    await client.respond(prompt="hello", grounding={"currency": "USD"})

    attributes = attributes_of(finished(SpanKind.CLIENT)[0])
    assert attributes["model"] == "gpt-5.4-mini"
    assert "input_tokens" not in attributes


# --- FastAPI instrumentation ordering --------------------------------------


def test_a_traced_request_carries_only_safe_attributes() -> None:
    FastAPIInstrumentor().instrument(tracer_provider=trace.get_tracer_provider())
    try:
        response = TestClient(main.create_app()).get("/health/live")
    finally:
        FastAPIInstrumentor().uninstrument()

    assert response.status_code == 200
    server_spans = finished(SpanKind.SERVER)
    assert server_spans
    attributes = attributes_of(server_spans[0])
    assert set(attributes) <= SAFE_ATTRIBUTE_NAMES
    assert "GET" in attributes.values()


def test_the_app_is_built_only_after_telemetry_is_configured(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Azure Monitor swaps `fastapi.FastAPI` while configuring, so order decides tracing."""
    monkeypatch.setenv("APPLICATIONINSIGHTS_CONNECTION_STRING", CONNECTION_STRING)

    def configure(**kwargs: Any) -> None:
        FastAPIInstrumentor().instrument(tracer_provider=trace.get_tracer_provider())

    monkeypatch.setattr(telemetry, "configure_azure_monitor", configure)
    try:
        response = TestClient(main.create_app()).get("/health/live")
    finally:
        FastAPIInstrumentor().uninstrument()

    assert response.status_code == 200
    assert finished(SpanKind.SERVER)


def test_a_dependency_span_is_named_for_its_dependency() -> None:
    with dependency_span("probe") as call:
        call.record(row_count=1)

    assert [span.name for span in finished(SpanKind.CLIENT)] == ["dependency probe"]
