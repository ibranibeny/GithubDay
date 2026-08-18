"""FastAPI application factory."""

from collections.abc import AsyncIterator
from contextlib import AsyncExitStack, asynccontextmanager

import fastapi
from fastapi.middleware.cors import CORSMiddleware

from cost_copilot import __version__
from cost_copilot.config import get_settings
from cost_copilot.correlation import CORRELATION_ID_HEADER, CorrelationIdMiddleware
from cost_copilot.errors import SafeErrorMiddleware, register_exception_handlers
from cost_copilot.routers import chat, costs, health
from cost_copilot.telemetry import setup_telemetry


@asynccontextmanager
async def application_lifespan(app: fastapi.FastAPI) -> AsyncIterator[None]:
    """Builds every upstream client once, in dependency order.

    The cost lifespan owns the shared Azure credential, so it is entered first
    and torn down last; the chat lifespan borrows that credential and releases
    its own model client before the credential goes away.
    """
    async with AsyncExitStack() as resources:
        await resources.enter_async_context(costs.cost_service_lifespan(app))
        await resources.enter_async_context(chat.chat_service_lifespan(app))
        yield


def create_app() -> fastapi.FastAPI:
    settings = get_settings()
    # Azure Monitor rebinds `fastapi.FastAPI` to its instrumented subclass while it
    # configures, so telemetry is set up first and the class is resolved from the
    # module here rather than imported by name at the top of this file.
    setup_telemetry(settings)
    app = fastapi.FastAPI(
        title="Azure Cost Copilot API",
        version=__version__,
        lifespan=application_lifespan,
    )
    # add_middleware prepends, so CORSMiddleware must be added last to wrap the
    # error middleware and put CORS headers on sanitized 500 responses too.
    # Correlation sits between the two: outside SafeErrorMiddleware so a sanitized
    # 500 still carries the header, inside CORS so the browser may read it.
    app.add_middleware(SafeErrorMiddleware)
    app.add_middleware(CorrelationIdMiddleware)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=False,  # the browser sends bearer tokens, not cookies
        allow_methods=["GET", "POST", "OPTIONS"],
        # A header the SPA sends must be advertised here or the preflight fails.
        allow_headers=["Authorization", "Content-Type", CORRELATION_ID_HEADER, "traceparent"],
        # ...and a header the SPA reads back must be exposed, or fetch hides it.
        expose_headers=[CORRELATION_ID_HEADER],
    )
    register_exception_handlers(app)
    app.include_router(health.router)
    app.include_router(costs.router)
    app.include_router(chat.router)
    return app


app = create_app()
