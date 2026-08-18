"""Azure Monitor wiring and the attribute allowlist every span is filtered through.

Verified against the installed `azure-monitor-opentelemetry` 1.8.9 rather than
assumed:

* `configure_azure_monitor(**kwargs)` takes keyword arguments only. It accepts a
  `resource` (an `opentelemetry.sdk.resources.Resource`) — not the
  `resource_attributes` mapping some samples show — so the service identity is
  built here and handed over as a `Resource`.
* Every processor passed as `span_processors` is registered on the SDK tracer
  provider *before* the exporting `BatchSpanProcessor`, so the sanitizer below
  always runs ahead of export.
* Configuration ends by loading the installed instrumentors, and the FastAPI one
  works by rebinding `fastapi.FastAPI` to an instrumented subclass. Anything that
  resolved that name earlier keeps the unpatched class, which is why
  `main.create_app` calls `setup_telemetry` first and only then looks the class up
  on the `fastapi` module.

Nothing is configured without a connection string, so local runs and the test
suite never export.
"""

import os
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass, field
from time import monotonic
from typing import Any, Final, Literal

from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import metrics, trace
from opentelemetry.attributes import BoundedAttributes
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import Span, SpanProcessor
from opentelemetry.sdk.util import BoundedList
from opentelemetry.trace import SpanKind, Status, StatusCode

from cost_copilot.config import Settings

__all__ = [
    "COST_DEPENDENCY",
    "CORRELATION_ID_ATTRIBUTE",
    "DEPENDENCY_DURATION_METRIC",
    "FOUNDRY_DEPENDENCY",
    "SAFE_ATTRIBUTE_NAMES",
    "SENSITIVE_ATTRIBUTE_NAMES",
    "SERVICE_NAME",
    "UNKNOWN_VERSION",
    "DependencyCall",
    "DependencyName",
    "SanitizingSpanProcessor",
    "dependency_span",
    "sanitize_attributes",
    "setup_telemetry",
]

SERVICE_NAME = "cost-copilot-api"
TRACER_NAME = "cost_copilot"
LOGGER_NAME = "cost_copilot"
UNKNOWN_VERSION = "unknown"
# A deployment stamps one of these; neither is a secret and both are plain text.
VERSION_ENV_VARS = ("OTEL_SERVICE_VERSION", "GIT_SHA")

# A span name is exported verbatim and is not covered by the attribute
# allowlist, so the callers may only choose from this closed set.
DependencyName = Literal["cost-management", "foundry"]
COST_DEPENDENCY: Final[DependencyName] = "cost-management"
FOUNDRY_DEPENDENCY: Final[DependencyName] = "foundry"
DEPENDENCY_DURATION_METRIC = "cost_copilot.dependency.duration"

OK_STATUS = "ok"
ERROR_STATUS = "error"

# The only value on the allowlist that originates outside this process. It is
# bounded and character-checked in `correlation.normalize_correlation_id` before
# it is ever set, so what reaches the exporter is an opaque token, not free text.
CORRELATION_ID_ATTRIBUTE: Final = "correlation_id"

# The allowlist is the rule: an attribute that is not named here never leaves the
# process, so a new attribute is invisible until it is reviewed and added.
SAFE_ATTRIBUTE_NAMES = frozenset(
    {
        "dependency",
        "dependency.name",
        CORRELATION_ID_ATTRIBUTE,
        "status",
        "status_code",
        "duration_ms",
        "row_count",
        "model",
        "input_tokens",
        "output_tokens",
        "total_tokens",
        "environment",
        "http.method",
        "http.status_code",
        "http.request.method",
        "http.response.status_code",
        "http.route",
    }
)

# Names that must never be added to the allowlist. They carry a user question, a
# model answer, a credential, a request body, or a tenant-identifying URL. A test
# asserts the two sets stay disjoint, so this list is what makes that check bite.
SENSITIVE_ATTRIBUTE_NAMES = frozenset(
    {
        "prompt",
        "answer",
        "authorization",
        "authorization-header",
        "http.request.header.authorization",
        "token",
        "access_token",
        "bearer",
        "query",
        "query_body",
        "request_body",
        "http.request.body",
        "resource_id",
        "resourceid",
        "rows",
        "raw_rows",
        "cost_rows",
        "url",
        "url.full",
        "http.url",
        "http.target",
        "tenant_id",
        "tenantid",
        "subscription_id",
        "subscriptionid",
        "connection_string",
        "connectionstring",
    }
)

_tracer = trace.get_tracer(TRACER_NAME)
# Created before any provider exists on purpose: the API hands back a proxy that
# binds to the real provider once `configure_azure_monitor` installs one.
_duration_ms = metrics.get_meter(TRACER_NAME).create_histogram(
    DEPENDENCY_DURATION_METRIC,
    unit="ms",
    description="Wall-clock duration of one upstream dependency call.",
)

_configured = False


def sanitize_attributes(attributes: Mapping[str, Any]) -> dict[str, Any]:
    """Keep only reviewed, non-identifying attribute names; drop everything else."""
    return {
        key: value
        for key, value in attributes.items()
        if key.casefold() in SAFE_ATTRIBUTE_NAMES
        and key.casefold() not in SENSITIVE_ATTRIBUTE_NAMES
    }


class SanitizingSpanProcessor(SpanProcessor):
    """Last line of defence: scrubs every span on the way out, whoever created it.

    `_on_ending` is the SDK's only hook that still receives a writable span;
    `on_end` is handed an immutable `ReadableSpan`. All three of a span's free-text
    surfaces are handled, because the attribute allowlist alone does not cover the
    other two:

    * Attributes are replaced wholesale, because `BoundedAttributes` refuses
      deletion. The replacement is frozen again, matching what `Span.end` does to
      the original container immediately before calling this hook.
    * Events are dropped. `Span.record_exception` writes the exception message and
      the full stacktrace as event attributes, and neither the event name nor its
      attributes pass through any allowlist. The instrumentor's exception
      middleware records one whenever a response fails after it has started.
    * The status description is dropped and only the code is kept: the SDK builds
      that description from the exception's own text.

    Every field is reached through `getattr`, so an unfamiliar span shape degrades
    to "less scrubbing" rather than raising inside `Span.end`.
    """

    def _on_ending(self, span: Span) -> None:
        safe = sanitize_attributes(span.attributes or {})
        span._attributes = BoundedAttributes(attributes=safe, immutable=True)
        if getattr(span, "_events", None) is not None:
            span._events = BoundedList(0)
        status = getattr(span, "_status", None)
        if status is not None and getattr(status, "description", None) is not None:
            span._status = Status(status.status_code)


def _service_version() -> str:
    for name in VERSION_ENV_VARS:
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return UNKNOWN_VERSION


def setup_telemetry(settings: Settings) -> bool:
    """Configure Azure Monitor once. Returns whether this call did the configuring."""
    global _configured
    connection_string = settings.applicationinsights_connection_string
    if _configured or not connection_string:
        return False
    configure_azure_monitor(
        connection_string=connection_string,
        resource=Resource.create(
            {
                "service.name": SERVICE_NAME,
                "service.version": _service_version(),
                "deployment.environment": settings.app_environment,
            }
        ),
        span_processors=[SanitizingSpanProcessor()],
        logger_name=LOGGER_NAME,
    )
    _configured = True
    return True


@dataclass(slots=True)
class DependencyCall:
    """The safe facts a client may attach to its dependency span."""

    name: DependencyName
    status: str = OK_STATUS
    attributes: dict[str, Any] = field(default_factory=dict)

    def record(self, **attributes: Any) -> None:
        self.attributes.update(attributes)


@contextmanager
def dependency_span(name: DependencyName) -> Iterator[DependencyCall]:
    """Trace one upstream call, recording only attributes the allowlist admits.

    Exception recording and the SDK's automatic error status are both off: an
    upstream error message can quote a URL carrying the subscription id. The
    sanitizing processor drops both anyway, so this is belt and braces.
    """
    call = DependencyCall(name=name)
    started = monotonic()
    with _tracer.start_as_current_span(
        f"dependency {name}",
        kind=SpanKind.CLIENT,
        record_exception=False,
        set_status_on_exception=False,
    ) as span:
        try:
            yield call
        except BaseException:
            call.status = ERROR_STATUS
            raise
        finally:
            duration = round((monotonic() - started) * 1000.0, 3)
            span.set_attributes(
                sanitize_attributes(
                    {
                        **call.attributes,
                        "dependency": call.name,
                        "status": call.status,
                        "duration_ms": duration,
                    }
                )
            )
            span.set_status(
                Status(StatusCode.ERROR if call.status == ERROR_STATUS else StatusCode.OK)
            )
            _duration_ms.record(duration, {"dependency": call.name, "status": call.status})
