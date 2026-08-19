"""Liveness and readiness endpoints."""

import logging
from typing import Annotated, Protocol

from fastapi import APIRouter, Depends

from cost_copilot.errors import dependencies_unavailable_error

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/health", tags=["health"])


class ReadinessChecker(Protocol):
    """Preflights the runtime dependencies the API needs to serve traffic."""

    async def __call__(self) -> None: ...


async def no_dependency_readiness_check() -> None:
    """Default checker: the credential and service clients arrive in later tasks.

    Readiness deliberately makes no network call in this phase; the Cost
    Management and Foundry preflights replace this checker in tasks 3 and 4.
    """
    return None


def get_readiness_checker() -> ReadinessChecker:
    """Dependency seam: override this to plug in real dependency preflights."""
    return no_dependency_readiness_check


@router.get("/live")
async def live() -> dict[str, str]:
    return {"status": "alive"}


@router.get("/ready")
async def ready(
    check_readiness: Annotated[ReadinessChecker, Depends(get_readiness_checker)],
) -> dict[str, str]:
    try:
        await check_readiness()
    except Exception as error:  # Dependency failures are reported without detail.
        logger.warning("Readiness check failed (%s)", type(error).__name__)
        raise dependencies_unavailable_error() from error
    return {"status": "ready"}
