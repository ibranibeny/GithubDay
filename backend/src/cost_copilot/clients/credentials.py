"""Azure AD token acquisition shared by every outbound client.

One synchronous `DefaultAzureCredential` backs every scope this API needs. The
synchronous credential is deliberate: `azure.identity.aio` needs azure-core's
aiohttp transport, and aiohttp is not in this project's lockfile, so the async
credential would fail on its first token request. Each provider therefore runs
the blocking call in a worker thread, which keeps the event loop free while the
credential's own cache absorbs the repeat calls.
"""

from collections.abc import Awaitable, Callable
from typing import Protocol

from anyio import to_thread

MANAGEMENT_SCOPE = "https://management.azure.com/.default"
COGNITIVE_SERVICES_SCOPE = "https://cognitiveservices.azure.com/.default"


class AccessTokenLike(Protocol):
    @property
    def token(self) -> str: ...


class SupportsGetToken(Protocol):
    def get_token(self, *scopes: str) -> AccessTokenLike: ...

    def close(self) -> None: ...


TokenProvider = Callable[[], Awaitable[str]]


class CredentialTokenProvider:
    """Acquires a token for one scope off the event loop.

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
    ) -> None:
        self._credential = credential
        self._scope = scope
        self._owns_credential = owns_credential

    def _token(self) -> str:
        return self._credential.get_token(self._scope).token

    async def __call__(self) -> str:
        return await to_thread.run_sync(self._token)

    async def aclose(self) -> None:
        """Releases the credential's transport, but only for whoever owns it.

        Several providers share one credential, so a borrower closing it would
        tear down the token cache the other scopes are still using.
        """
        if self._owns_credential:
            await to_thread.run_sync(self._credential.close)
