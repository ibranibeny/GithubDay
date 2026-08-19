"""Azure AD token acquisition shared by every outbound client.

One synchronous `DefaultAzureCredential` backs every scope this API needs. The
synchronous credential is deliberate: `azure.identity.aio` needs azure-core's
aiohttp transport, and aiohttp is not in this project's lockfile, so the async
credential would fail on its first token request. Each provider therefore runs
the blocking call in a worker thread, which keeps the event loop free while the
credential's own cache absorbs the repeat calls.

Two guarantees are centralized here rather than repeated per consumer, because
one consumer -- the OpenAI SDK, which awaits the provider from inside its own
request call -- has no way to add either:

* Acquisition is *bounded*. A credential that never answers would otherwise
  consume the caller's whole request budget.
* Acquisition *fails typed*. Whatever the credential raises is reported as a
  `CredentialError`, so a caller can map it instead of letting a foreign
  exception escape its own error contract as an unhandled 500.
"""

import asyncio
import logging
from collections.abc import Awaitable, Callable
from typing import Protocol

from anyio import to_thread

logger = logging.getLogger(__name__)

MANAGEMENT_SCOPE = "https://management.azure.com/.default"
COGNITIVE_SERVICES_SCOPE = "https://cognitiveservices.azure.com/.default"

# Comfortably longer than a warm cache hit or a managed-identity round trip, and
# far short of the callers' own request budgets, so a stuck identity endpoint is
# a fast failure rather than a slow one.
TOKEN_ACQUISITION_TIMEOUT_SECONDS = 10.0


class CredentialError(Exception):
    """Token acquisition failed. Messages never quote the credential's own error."""


class CredentialTimeoutError(CredentialError):
    """The credential did not produce a token within the acquisition bound."""


class CredentialAcquisitionError(CredentialError):
    """The credential refused, or could not produce, a token."""


class AccessTokenLike(Protocol):
    @property
    def token(self) -> str: ...


class SupportsGetToken(Protocol):
    def get_token(self, *scopes: str) -> AccessTokenLike: ...

    def close(self) -> None: ...


TokenProvider = Callable[[], Awaitable[str]]


class CredentialTokenProvider:
    """Acquires a token for one scope off the event loop, bounded and single-flight.

    Awaitable rather than plain-callable on purpose: both consumers (the Cost
    Management client and the OpenAI SDK's async `api_key` provider) await it,
    so no caller ever blocks the loop on a credential round trip.
    """

    def __init__(
        self,
        credential: SupportsGetToken,
        *,
        scope: str = MANAGEMENT_SCOPE,
        owns_credential: bool = True,
        timeout: float = TOKEN_ACQUISITION_TIMEOUT_SECONDS,
    ) -> None:
        self._credential = credential
        self._scope = scope
        self._owns_credential = owns_credential
        self._timeout = timeout
        self._lock = asyncio.Lock()

    def _token(self) -> str:
        return self._credential.get_token(self._scope).token

    async def __call__(self) -> str:
        try:
            # The bound wraps the lock as well as the call, so a caller queued
            # behind a stuck acquisition is bounded too. A cancelled `run_sync`
            # returns control immediately instead of waiting for its worker
            # thread, so the lock is released the moment the bound fires.
            async with asyncio.timeout(self._timeout), self._lock:
                return await to_thread.run_sync(self._token)
        except TimeoutError as error:
            logger.warning("Azure token acquisition exceeded its bound")
            raise CredentialTimeoutError(
                "Azure token acquisition did not finish in time"
            ) from error
        except Exception as error:
            # Only the type is logged: a credential error can quote tenant,
            # principal, or identity-endpoint detail.
            logger.warning("Azure token acquisition failed (%s)", type(error).__name__)
            raise CredentialAcquisitionError("Azure token acquisition failed") from error

    async def aclose(self) -> None:
        """Releases the credential's transport, but only for whoever owns it.

        Several providers share one credential, so a borrower closing it would
        tear down the token cache the other scopes are still using.
        """
        if self._owns_credential:
            await to_thread.run_sync(self._credential.close)
