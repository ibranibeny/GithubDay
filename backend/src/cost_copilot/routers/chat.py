"""Evidence-grounded chat endpoint backed by the Foundry Responses API."""

import logging
from collections.abc import AsyncIterator
from contextlib import AsyncExitStack, asynccontextmanager
from typing import Annotated, cast

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request

from cost_copilot.auth import CostReaderClaims
from cost_copilot.clients.cost_management import CostQueryError
from cost_copilot.clients.credentials import (
    COGNITIVE_SERVICES_SCOPE,
    CredentialTokenProvider,
    SupportsGetToken,
)
from cost_copilot.clients.foundry import build_foundry_client
from cost_copilot.config import get_settings
from cost_copilot.models.chat import ChatRequest, ChatResponse
from cost_copilot.routers.costs import (
    COST_SERVICE_STATE_ATTRIBUTE,
    CREDENTIAL_STATE_ATTRIBUTE,
    http_error_for,
)
from cost_copilot.services.chat_service import ChatFiltersRequiredError, ChatService

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api", tags=["chat"])

CHAT_SERVICE_STATE_ATTRIBUTE = "chat_service"
CHAT_UNAVAILABLE_DETAIL = "Chat is unavailable"
FILTERS_REQUIRED_DETAIL = "active dashboard filters are required"


@asynccontextmanager
async def chat_service_lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Borrows the credential the cost lifespan owns, and owns only its own client.

    Entered after the cost lifespan, so it also exits first: the model client is
    released while the shared credential is still alive, and the credential is
    then closed exactly once by its owner.
    """
    credential = cast(SupportsGetToken, getattr(app.state, CREDENTIAL_STATE_ATTRIBUTE))
    cost_service = getattr(app.state, COST_SERVICE_STATE_ATTRIBUTE)

    async with AsyncExitStack() as resources:
        # A token for the model plane only, and a borrowed credential: closing it
        # here would tear down the cache the cost client still uses.
        tokens = CredentialTokenProvider(
            credential, scope=COGNITIVE_SERVICES_SCOPE, owns_credential=False
        )
        # Symmetric with the cost lifespan: whoever builds a provider releases it,
        # and the provider itself decides that a borrowed credential is left alone.
        resources.push_async_callback(tokens.aclose)
        client = build_foundry_client(get_settings(), acquire_token=tokens)
        resources.push_async_callback(client.aclose)
        setattr(app.state, CHAT_SERVICE_STATE_ATTRIBUTE, ChatService(cost_service, client))
        yield


def get_chat_service(request: Request) -> ChatService:
    """Dependency seam: overridden in tests, owned by the lifespan otherwise."""
    service = getattr(request.app.state, CHAT_SERVICE_STATE_ATTRIBUTE, None)
    if not isinstance(service, ChatService):
        raise HTTPException(status_code=503, detail=CHAT_UNAVAILABLE_DETAIL)
    return service


ChatServiceParam = Annotated[ChatService, Depends(get_chat_service)]


@router.post("/chat")
async def chat(
    _claims: CostReaderClaims, request: ChatRequest, service: ChatServiceParam
) -> ChatResponse:
    try:
        return await service.answer(request)
    except ChatFiltersRequiredError as error:
        raise HTTPException(status_code=422, detail=FILTERS_REQUIRED_DETAIL) from error
    except CostQueryError as error:
        # A cost failure is reported as a cost failure: the model was never asked.
        logger.warning("Chat cost query failed (%s)", type(error).__name__)
        raise http_error_for(error) from error
