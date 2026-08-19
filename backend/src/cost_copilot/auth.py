"""Entra ID bearer token validation and app-role authorization."""

import logging
import threading
import time
from collections import OrderedDict
from collections.abc import Callable
from functools import lru_cache
from typing import Annotated, Any, Protocol, cast
from uuid import UUID

import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWK, PyJWKClient, PyJWKSet
from jwt.exceptions import PyJWKClientConnectionError, PyJWKClientError, PyJWTError

from cost_copilot.config import Settings, get_settings
from cost_copilot.errors import forbidden_role_error, unauthorized_error

COST_READER_ROLE = "Cost.Read"
ALLOWED_ALGORITHMS = ["RS256"]
REQUIRED_CLAIMS = ["exp", "tid", "aud", "iss", "ver", "oid"]
REQUIRED_TOKEN_VERSION = "2.0"  # noqa: S105  # Entra token format version, not a secret

JWKS_CACHE_LIFESPAN_SECONDS = 300.0
JWKS_TIMEOUT_SECONDS = 5.0
JWKS_FORCED_REFRESH_COOLDOWN_SECONDS = 10.0
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
    """Bounded, TTL'd set of key ids that a JWKS lookup definitively rejected.

    Keeps a known-bad `kid` from consuming the shared refresh budget on every
    request. Entries expire so a genuine key rotation is still picked up.
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


def _await_jwks_refresh(refresh_done: threading.Event) -> None:
    """Block until the in-flight JWKS refresh finishes, bounded by the fetch timeout."""
    refresh_done.wait(JWKS_TIMEOUT_SECONDS)


class EntraSigningKeyResolver:
    """Fetches signing keys from the tenant JWKS endpoint.

    PyJWKClient re-fetches the JWKS document whenever a token's `kid` is not in
    the cached set, so unauthenticated callers could otherwise drive outbound
    traffic by varying the `kid` on every request. Two limits close that off: a
    per-kid negative cache, and a global cooldown that caps forced refreshes to
    one per window no matter how many distinct key ids arrive.

    The cooldown alone would reject legitimate tokens whenever the cache is cold
    or has just expired, because then *every* kid misses the cached set and only
    one caller could claim the window. So the refresh is single-flight instead of
    fail-fast: one caller leads it and the rest wait on its result before
    deciding, which keeps the outbound bound at one refresh per window while
    still admitting concurrent valid callers.
    """

    def __init__(
        self,
        tenant_id: str,
        *,
        key_lookup: Callable[[str], SigningKey] | None = None,
        cached_key_ids: Callable[[], set[str]] | None = None,
        time_source: Callable[[], float] = time.monotonic,
        refresh_waiter: Callable[[threading.Event], None] | None = None,
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
        self._cached_key_ids = cached_key_ids or self.signing_key_ids_in_cache
        self._now = time_source
        self._await_refresh = refresh_waiter or _await_jwks_refresh
        self._unknown_kids = UnknownKidCache(time_source=time_source)
        self._refresh_lock = threading.Lock()
        self._last_forced_refresh: float | None = None
        self._refresh_in_flight: threading.Event | None = None

    def signing_key_ids_in_cache(self) -> set[str]:
        """Key ids already held locally, filtered the way PyJWKClient filters them.

        A single cache read decides the answer: routing back through
        `get_jwk_set()` would let an expiry between the check and the read fall
        through to the fetch this class exists to ration.
        """
        cache = self.jwks_client.jwk_set_cache
        # JWKSetCache is annotated as holding a PyJWKSet, but fetch_data() stores
        # the raw decoded JSON, which is what get_jwk_set() then parses.
        cached = cast(Any, cache.get()) if cache is not None else None
        if not isinstance(cached, dict):
            return set()
        return {
            key.key_id
            for key in PyJWKSet.from_dict(cached).keys
            if key.key_id and key.public_key_use in ("sig", None)
        }

    def _claim_forced_refresh(self) -> tuple[bool, threading.Event | None]:
        """Elect one leader per cooldown window; report what everyone else may wait on.

        Returns `(is_leader, refresh_done)`. A `None` event means no refresh is in
        flight and the cooldown has not elapsed, so there is nothing to ride.
        """
        now = self._now()
        with self._refresh_lock:
            if self._refresh_in_flight is not None:
                return False, self._refresh_in_flight
            last = self._last_forced_refresh
            if last is not None and now - last < JWKS_FORCED_REFRESH_COOLDOWN_SECONDS:
                return False, None
            self._last_forced_refresh = now
            self._refresh_in_flight = threading.Event()
            return True, self._refresh_in_flight

    def _release_forced_refresh(self) -> None:
        """Wake the followers, including when the leader's fetch failed."""
        with self._refresh_lock:
            refresh_done, self._refresh_in_flight = self._refresh_in_flight, None
        if refresh_done is not None:
            refresh_done.set()

    def _lookup_and_record(self, token: str, kid: str | None) -> SigningKey:
        try:
            return self._lookup(token)
        except PyJWKClientError as error:
            # Only a definitive no-match is cached: a connection failure says nothing
            # about the kid, and caching it would deny a valid key for the whole TTL.
            if kid is not None and not isinstance(error, PyJWKClientConnectionError):
                self._unknown_kids.record(kid)
            raise

    def _resolve_without_refreshing(
        self, token: str, kid: str | None, refresh_done: threading.Event | None
    ) -> SigningKey:
        """Ride an in-flight refresh rather than starting one or failing outright.

        A leader that fails still releases the event, so a bounded wait plus a
        pure cache re-read fails closed instead of falling back to a fetch.
        """
        if refresh_done is not None:
            self._await_refresh(refresh_done)
        if kid is not None and kid in self._cached_key_ids():
            return self._lookup_and_record(token, kid)
        raise UnknownSigningKeyError("Signing key id is uncached and refresh is throttled")

    def __call__(self, token: str) -> SigningKey:
        kid = unverified_kid(token)
        if kid is not None and self._unknown_kids.is_denied(kid):
            raise UnknownSigningKeyError("Signing key id was rejected by a recent lookup")
        # A missing kid also misses the cached set, so it is rationed the same way.
        if kid is None or kid not in self._cached_key_ids():
            is_leader, refresh_done = self._claim_forced_refresh()
            if not is_leader:
                return self._resolve_without_refreshing(token, kid, refresh_done)
            try:
                return self._lookup_and_record(token, kid)
            finally:
                self._release_forced_refresh()
        return self._lookup_and_record(token, kid)


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
