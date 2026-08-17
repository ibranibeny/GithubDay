"""FastAPI application factory."""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from cost_copilot import __version__
from cost_copilot.config import get_settings
from cost_copilot.errors import register_exception_handlers
from cost_copilot.routers import health


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="Azure Cost Copilot API", version=__version__)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type"],
    )
    register_exception_handlers(app)
    app.include_router(health.router)
    return app


app = create_app()
