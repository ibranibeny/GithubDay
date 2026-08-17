"""Client-safe error responses.

Handlers here deliberately return fixed messages: upstream exception text can
carry tokens, connection strings, or internal hostnames.
"""

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from starlette.requests import Request
from starlette.responses import Response

INVALID_CREDENTIALS_DETAIL = "Invalid or expired access token"
DEPENDENCIES_UNAVAILABLE_DETAIL = "dependencies unavailable"
INTERNAL_ERROR_DETAIL = "Internal server error"


def unauthorized_error() -> HTTPException:
    return HTTPException(
        status_code=401,
        detail=INVALID_CREDENTIALS_DETAIL,
        headers={"WWW-Authenticate": "Bearer"},
    )


def dependencies_unavailable_error() -> HTTPException:
    return HTTPException(status_code=503, detail=DEPENDENCIES_UNAVAILABLE_DETAIL)


def http_exception_handler(request: Request, exc: Exception) -> Response:
    if not isinstance(exc, HTTPException):
        return unhandled_exception_handler(request, exc)
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail},
        headers=exc.headers,
    )


def unhandled_exception_handler(request: Request, exc: Exception) -> Response:
    return JSONResponse(status_code=500, content={"detail": INTERNAL_ERROR_DETAIL})


def register_exception_handlers(app: FastAPI) -> None:
    app.add_exception_handler(HTTPException, http_exception_handler)
    app.add_exception_handler(Exception, unhandled_exception_handler)
