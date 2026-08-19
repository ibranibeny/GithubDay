"""Correlation id propagation between the SPA, the API, and the trace.

The id is a client-supplied string, so it is treated as untrusted input: it is
matched against a narrow character set and a length bound, and anything else is
replaced with a freshly minted uuid4 rather than escaped. That keeps it safe to
echo into a response header (no CR/LF injection) and safe to export as a span
attribute (no free text). It is never written to a log record and never appears
in an error body -- the client already knows it, and a log line is exported.
"""

import re
import uuid
from typing import Final

from opentelemetry import trace
from starlette.datastructures import Headers, MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from cost_copilot.telemetry import CORRELATION_ID_ATTRIBUTE

__all__ = [
    "CORRELATION_ID_HEADER",
    "MAX_CORRELATION_ID_LENGTH",
    "CorrelationIdMiddleware",
    "normalize_correlation_id",
]

CORRELATION_ID_HEADER: Final = "x-correlation-id"
MAX_CORRELATION_ID_LENGTH: Final = 128

# Narrower than "printable ASCII" on purpose: spaces, quotes, and control
# characters have no place in an opaque identifier, and excluding them means the
# value never has to be escaped on the way back out.
_VALID_CORRELATION_ID: Final = re.compile(rf"\A[A-Za-z0-9._-]{{1,{MAX_CORRELATION_ID_LENGTH}}}\Z")


def normalize_correlation_id(raw: str | None) -> str:
    """Adopt a well-formed inbound id, or mint one. Never returns caller text."""
    if raw is not None and _VALID_CORRELATION_ID.match(raw):
        return raw
    return str(uuid.uuid4())


class CorrelationIdMiddleware:
    """Adopts or mints the request correlation id, then echoes it back.

    The FastAPI instrumentor wraps the whole middleware stack rather than
    inserting itself into it, so the server span is already current by the time
    this runs and `set_attribute` lands on the exported span. `main.create_app`
    still places this inside CORS and outside `SafeErrorMiddleware`, so a
    sanitized 500 carries the header too.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        correlation_id = normalize_correlation_id(
            Headers(scope=scope).get(CORRELATION_ID_HEADER),
        )
        trace.get_current_span().set_attribute(CORRELATION_ID_ATTRIBUTE, correlation_id)

        async def send_with_correlation_id(message: Message) -> None:
            if message["type"] == "http.response.start":
                MutableHeaders(scope=message)[CORRELATION_ID_HEADER] = correlation_id
            await send(message)

        await self.app(scope, receive, send_with_correlation_id)
