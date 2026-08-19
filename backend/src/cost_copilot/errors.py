"""Client-safe error responses.

Handlers here deliberately return fixed messages: upstream exception text can
carry tokens, connection strings, or internal hostnames.
"""

import logging

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.requests import Request
from starlette.responses import Response
from starlette.types import ASGIApp, Message, Receive, Scope, Send

INVALID_CREDENTIALS_DETAIL = "Invalid or expired access token"
FORBIDDEN_ROLE_DETAIL = "Cost.Read role is required"
DEPENDENCIES_UNAVAILABLE_DETAIL = "dependencies unavailable"
INTERNAL_ERROR_DETAIL = "Internal server error"

logger = logging.getLogger(__name__)


def unauthorized_error() -> HTTPException:
    return HTTPException(
        status_code=401,
        detail=INVALID_CREDENTIALS_DETAIL,
        headers={"WWW-Authenticate": "Bearer"},
    )


def forbidden_role_error() -> HTTPException:
    return HTTPException(status_code=403, detail=FORBIDDEN_ROLE_DETAIL)


def dependencies_unavailable_error() -> HTTPException:
    return HTTPException(status_code=503, detail=DEPENDENCIES_UNAVAILABLE_DETAIL)


def http_exception_handler(request: Request, exc: Exception) -> Response:
    if not isinstance(exc, StarletteHTTPException):
        return unhandled_exception_handler(request, exc)
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail},
        headers=exc.headers,
    )


def unhandled_exception_handler(request: Request, exc: Exception) -> Response:
    # `setup_telemetry` exports this logger, and a traceback quotes the failing
    # request line -- for an upstream call, the subscription-scoped ARM URL. The
    # path and the exception type are enough to find the fault in the code.
    logger.error("Unhandled error serving %s (%s)", request.url.path, type(exc).__name__)
    return JSONResponse(status_code=500, content={"detail": INTERNAL_ERROR_DETAIL})


class SafeErrorMiddleware:
    """Turns unhandled errors into a generic 500 from inside the CORS layer.

    Starlette's own ServerErrorMiddleware sits outside every user middleware, so
    the 500 it emits carries no CORS headers and a browser sees an opaque network
    failure instead of the error.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        response_started = False

        async def guarded_send(message: Message) -> None:
            nonlocal response_started
            if message["type"] == "http.response.start":
                response_started = True
            await send(message)

        try:
            await self.app(scope, receive, guarded_send)
        except Exception as exc:
            if response_started:
                raise
            response = unhandled_exception_handler(Request(scope), exc)
            await response(scope, receive, send)


def register_exception_handlers(app: FastAPI) -> None:
    # Starlette raises the base class for 404/405, which a FastAPI-only handler misses.
    app.add_exception_handler(StarletteHTTPException, http_exception_handler)
    app.add_exception_handler(Exception, unhandled_exception_handler)
