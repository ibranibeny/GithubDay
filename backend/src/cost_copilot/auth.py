"""Entra ID bearer token validation and app-role authorization."""

import logging
import threading
import time
from collections import OrderedDict
from collections.abc import Callable
from functools import lru_cache
from typing import Annotated, Any, Protocol
from uuid import UUID

import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWK, PyJWKClient
from jwt.exceptions import PyJWKClientError, PyJWTError

from cost_copilot.config import Settings, get_settings
from cost_copilot.errors import forbidden_role_error, unauthorized_error

COST_READER_ROLE = "Cost.Read"
ALLOWED_ALGORITHMS = ["RS256"]
REQUIRED_CLAIMS = ["exp", "tid", "aud", "iss", "ver", "oid"]
REQUIRED_TOKEN_VERSION = "2.0"  # noqa: S105  # Entra token format version, not a secret

JWKS_CACHE_LIFESPAN_SECONDS = 300.0
JWKS_TIMEOUT_SECONDS = 5.0
UNKNOWN_KID_TTL_SECONDS = 30.0
UNKNOWN_KID_CACHE_SIZE = 256

logger = logging.getLogger(__name__)
bearer_scheme = HTTPBearer(auto_error=False)

SigningKey = PyJWK | str


class UnknownSigningKeyError(PyJWKClientError):
    """Raised for a `kid` that a recent JWKS lookup already failed to match."""


class SigningKeyResolver(Protocol):
    """Maps a raw token to the key material that signed it."""

    def __call__(self, token: str) -> SigningKey: ...


class UnknownKidCache:
    """Bounded, TTL'd set of key ids that JWKS could not resolve.

    Without it every token carrying an unrecognised `kid` forces PyJWKClient to
    re-fetch the JWKS document, so unauthenticated callers can drive outbound
    traffic at will. Entries expire so a genuine key rotation is still picked up.
    """

    def __init__(
        self,
        *,
        ttl_seconds: float = UNKNOWN_KID_TTL_SECONDS,
        max_entries: int = UNKNOWN_KID_CACHE_SIZE,
        time_source: Callable[[], float] = time.monotonic,
    ) -> None:
        self._ttl = ttl_seconds
        self._max_entries = max_entries
        self._now = time_source
        self._lock = threading.Lock()
        self._entries: OrderedDict[str, float] = OrderedDict()

    def is_denied(self, kid: str) -> bool:
        with self._lock:
            recorded_at = self._entries.get(kid)
            if recorded_at is None:
                return False
            if self._now() - recorded_at >= self._ttl:
                del self._entries[kid]
                return False
            return True

    def record(self, kid: str) -> None:
        with self._lock:
            self._entries.pop(kid, None)
            self._entries[kid] = self._now()
            while len(self._entries) > self._max_entries:
                self._entries.popitem(last=False)


def unverified_kid(token: str) -> str | None:
    """Read `kid` from the unverified JOSE header, for cache keying only.

    Nothing else in the header is trusted or acted on: the signature, algorithm
    and claims are still decided by PyJWT against the resolved key.
    """
    try:
        kid = jwt.get_unverified_header(token).get("kid")
    except PyJWTError:
        return None
    return kid if isinstance(kid, str) else None


class EntraSigningKeyResolver:
    """Fetches signing keys from the tenant JWKS endpoint."""

    def __init__(
        self,
        tenant_id: str,
        *,
        key_lookup: Callable[[str], SigningKey] | None = None,
        time_source: Callable[[], float] = time.monotonic,
    ) -> None:
        self.jwks_uri = f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys"
        self.jwks_client = PyJWKClient(
            self.jwks_uri,
            cache_keys=False,
            cache_jwk_set=True,
            lifespan=JWKS_CACHE_LIFESPAN_SECONDS,
            timeout=JWKS_TIMEOUT_SECONDS,
        )
        self._lookup = key_lookup or self.jwks_client.get_signing_key_from_jwt
        self._unknown_kids = UnknownKidCache(time_source=time_source)

    def __call__(self, token: str) -> SigningKey:
        kid = unverified_kid(token)
        if kid is not None and self._unknown_kids.is_denied(kid):
            raise UnknownSigningKeyError("Signing key id was rejected by a recent lookup")
        try:
            return self._lookup(token)
        except Exception:
            if kid is not None:
                self._unknown_kids.record(kid)
            raise


@lru_cache
def _resolver_for_tenant(tenant_id: str) -> EntraSigningKeyResolver:
    return EntraSigningKeyResolver(tenant_id)


def get_signing_key_resolver(
    settings: Annotated[Settings, Depends(get_settings)],
) -> SigningKeyResolver:
    """Dependency seam: override this to avoid network access in tests."""
    return _resolver_for_tenant(str(settings.azure_tenant_id))


def issuer_for(tenant_id: UUID | str) -> str:
    return f"https://login.microsoftonline.com/{tenant_id}/v2.0"


def _rejected(reason: str) -> HTTPException:
    logger.info("Access token rejected (%s)", reason)
    return unauthorized_error()


def verify_token(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    settings: Annotated[Settings, Depends(get_settings)],
    resolve_signing_key: Annotated[SigningKeyResolver, Depends(get_signing_key_resolver)],
) -> dict[str, Any]:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise unauthorized_error()

    try:
        signing_key = resolve_signing_key(credentials.credentials)
    except Exception as error:  # JWKS lookup failures must not surface to callers.
        # Only the exception class is logged: messages can carry tokens or URIs.
        logger.warning("Signing key lookup failed (%s)", type(error).__name__)
        raise unauthorized_error() from error

    try:
        claims: dict[str, Any] = jwt.decode(
            credentials.credentials,
            signing_key,
            algorithms=ALLOWED_ALGORITHMS,
            audience=settings.entra_api_client_id,
            issuer=issuer_for(settings.azure_tenant_id),
            options={"require": REQUIRED_CLAIMS, "verify_signature": True},
        )
    except PyJWTError as error:
        raise _rejected(type(error).__name__) from error

    if claims.get("tid") != str(settings.azure_tenant_id):
        raise _rejected("tenant_mismatch")
    if claims.get("ver") != REQUIRED_TOKEN_VERSION:
        raise _rejected("unsupported_token_version")
    if "nonce" in claims:
        # `nonce` marks an ID token; only access tokens may call this API.
        raise _rejected("id_token_presented")
    return claims


def require_cost_reader(
    claims: Annotated[dict[str, Any], Depends(verify_token)],
) -> dict[str, Any]:
    roles = claims.get("roles", [])
    if not isinstance(roles, list) or COST_READER_ROLE not in roles:
        raise forbidden_role_error()
    return claims


CostReaderClaims = Annotated[dict[str, Any], Depends(require_cost_reader)]
