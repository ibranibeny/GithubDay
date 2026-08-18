"""Read-only cost endpoints backed by the Cost Management Query API."""

import logging
from collections.abc import AsyncIterator, Awaitable
from contextlib import asynccontextmanager
from datetime import date
from typing import Annotated

import httpx
from azure.identity import DefaultAzureCredential
from fastapi import APIRouter, Depends, FastAPI, HTTPException, Query, Request
from pydantic import ValidationError

from cost_copilot.auth import CostReaderClaims
from cost_copilot.clients.cost_management import (
    REQUEST_TIMEOUT_SECONDS,
    CostManagementClient,
    CostQueryError,
    CostThrottledError,
    CostUpstreamTimeoutError,
    CredentialTokenProvider,
    TokenProvider,
)
from cost_copilot.config import Settings, get_settings
from cost_copilot.models.cost import (
    MAX_TAG_KEY_LENGTH,
    CostBreakdown,
    CostFilter,
    CostGrouping,
    CostMetric,
    CostSummary,
    CostTrend,
)
from cost_copilot.services.cost_service import CostService

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/costs", tags=["costs"])

UPSTREAM_UNAVAILABLE_DETAIL = "Cost data is unavailable"
UPSTREAM_THROTTLED_DETAIL = "Cost data is rate limited; retry shortly"
UPSTREAM_TIMEOUT_DETAIL = "Cost data request timed out"

COST_SERVICE_STATE_ATTRIBUTE = "cost_service"


def build_cost_client(settings: Settings, *, acquire_token: TokenProvider) -> CostManagementClient:
    """Compose the production client; it owns the pool created here and closes it."""
    return CostManagementClient(
        settings=settings,
        http_client=httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS),
        acquire_token=acquire_token,
        owns_client=True,
    )


@asynccontextmanager
async def cost_service_lifespan(app: FastAPI) -> AsyncIterator[None]:
    """One connection pool and one credential per application lifetime."""
    tokens = CredentialTokenProvider(DefaultAzureCredential())
    client = build_cost_client(get_settings(), acquire_token=tokens)
    setattr(app.state, COST_SERVICE_STATE_ATTRIBUTE, CostService(client))
    try:
        yield
    finally:
        await client.aclose()
        await tokens.aclose()


def get_cost_service(request: Request) -> CostService:
    """Dependency seam: overridden in tests, owned by the lifespan otherwise."""
    service = getattr(request.app.state, COST_SERVICE_STATE_ATTRIBUTE, None)
    if not isinstance(service, CostService):
        raise HTTPException(status_code=503, detail=UPSTREAM_UNAVAILABLE_DETAIL)
    return service


def build_filter(
    start: Annotated[date, Query(description="First day of the period, inclusive")],
    end: Annotated[date, Query(description="Last day of the period, inclusive")],
    metric: Annotated[CostMetric, Query()] = CostMetric.ACTUAL,
    grouping: Annotated[CostGrouping, Query()] = CostGrouping.SERVICE,
    tag_key: Annotated[str | None, Query(alias="tagKey", max_length=MAX_TAG_KEY_LENGTH)] = None,
) -> CostFilter:
    """Reject an unusable window before any upstream call is made."""
    try:
        return CostFilter(start=start, end=end, metric=metric, grouping=grouping, tag_key=tag_key)
    except ValidationError as error:
        # Only this module's own validator messages are echoed back.
        detail = "; ".join(item["msg"] for item in error.errors())
        raise HTTPException(status_code=422, detail=detail) from error


CostFilterParam = Annotated[CostFilter, Depends(build_filter)]
CostServiceParam = Annotated[CostService, Depends(get_cost_service)]


def _http_error_for(error: CostQueryError) -> HTTPException:
    if isinstance(error, CostThrottledError):
        return HTTPException(status_code=429, detail=UPSTREAM_THROTTLED_DETAIL)
    if isinstance(error, CostUpstreamTimeoutError):
        return HTTPException(status_code=504, detail=UPSTREAM_TIMEOUT_DETAIL)
    # An identity rejection is this API's misconfiguration, not the caller's: a 401
    # or 403 here would wrongly tell an authorized caller their own token failed.
    return HTTPException(status_code=502, detail=UPSTREAM_UNAVAILABLE_DETAIL)


async def _guarded[T](work: Awaitable[T]) -> T:
    try:
        return await work
    except CostQueryError as error:
        logger.warning("Cost query failed (%s)", type(error).__name__)
        raise _http_error_for(error) from error


@router.get("/summary")
async def summary(
    _claims: CostReaderClaims, filters: CostFilterParam, service: CostServiceParam
) -> CostSummary:
    return await _guarded(service.summary(filters))


@router.get("/trend")
async def trend(
    _claims: CostReaderClaims, filters: CostFilterParam, service: CostServiceParam
) -> CostTrend:
    return await _guarded(service.trend(filters))


@router.get("/breakdown")
async def breakdown(
    _claims: CostReaderClaims, filters: CostFilterParam, service: CostServiceParam
) -> CostBreakdown:
    return await _guarded(service.breakdown(filters))
