"""Signing-key resolution: JWKS cache policy and unknown-kid throttling."""

from collections.abc import Callable
from typing import Any, cast

import jwt
import pytest
from jwt.exceptions import PyJWKClientConnectionError, PyJWKClientError

from constants import TEST_TENANT_ID
from cost_copilot.auth import (
    JWKS_CACHE_LIFESPAN_SECONDS,
    JWKS_FORCED_REFRESH_COOLDOWN_SECONDS,
    JWKS_TIMEOUT_SECONDS,
    UNKNOWN_KID_CACHE_SIZE,
    UNKNOWN_KID_TTL_SECONDS,
    EntraSigningKeyResolver,
    UnknownKidCache,
    UnknownSigningKeyError,
    unverified_kid,
)

# Valid base64url for the 24-byte secret backing the symmetric JWKs used below.
OCT_KEY_MATERIAL = "c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0"


class Clock:
    """Injection seam that makes the negative-cache TTL deterministic."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class CountingLookup:
    def __init__(self, key: str | None = None) -> None:
        self.calls: list[str] = []
        self._key = key

    def __call__(self, token: str) -> Any:
        self.calls.append(token)
        if self._key is None:
            raise PyJWKClientError('Unable to find a signing key that matches: "abc"')
        return self._key


class ScriptedLookup:
    """Plays back one outcome per call: exceptions are raised, anything else returned."""

    def __init__(self, *outcomes: Any) -> None:
        self.calls: list[str] = []
        self._outcomes = list(outcomes)

    def __call__(self, token: str) -> Any:
        self.calls.append(token)
        outcome = self._outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


def token_with_kid(kid: str | None) -> str:
    headers = {"kid": kid} if kid is not None else {}
    return jwt.encode({"sub": "s"}, key="k" * 32, algorithm="HS256", headers=headers)


def build_resolver(
    lookup: Callable[[str], Any],
    clock: Clock,
    cached_kids: set[str] | None = None,
) -> EntraSigningKeyResolver:
    kids = set(cached_kids or ())
    return EntraSigningKeyResolver(
        TEST_TENANT_ID,
        key_lookup=lookup,
        cached_key_ids=lambda: kids,
        time_source=clock,
    )


def test_jwks_client_is_configured_with_a_bounded_cache_lifespan() -> None:
    client = EntraSigningKeyResolver(TEST_TENANT_ID).jwks_client

    assert client.jwk_set_cache is not None
    assert client.jwk_set_cache.lifespan == JWKS_CACHE_LIFESPAN_SECONDS
    assert client.timeout == JWKS_TIMEOUT_SECONDS
    # cache_keys=True installs an unbounded-lifetime lru_cache over signing keys.
    assert not hasattr(client.get_signing_key, "cache_info")


def test_unknown_kid_is_looked_up_once_then_denied_from_cache() -> None:
    lookup, clock = CountingLookup(), Clock()
    resolver = build_resolver(lookup, clock)
    token = token_with_kid("unknown-kid")

    with pytest.raises(PyJWKClientError):
        resolver(token)
    for _ in range(5):
        with pytest.raises(UnknownSigningKeyError):
            resolver(token)

    assert len(lookup.calls) == 1


def test_distinct_unknown_kids_share_a_single_forced_refresh() -> None:
    lookup, clock = CountingLookup(), Clock()
    resolver = build_resolver(lookup, clock)

    with pytest.raises(PyJWKClientError):
        resolver(token_with_kid("kid-0"))
    for index in range(1, 20):
        with pytest.raises(UnknownSigningKeyError):
            resolver(token_with_kid(f"kid-{index}"))

    assert len(lookup.calls) == 1


def test_a_forced_refresh_is_allowed_again_after_the_cooldown() -> None:
    lookup, clock = CountingLookup(), Clock()
    resolver = build_resolver(lookup, clock)

    with pytest.raises(PyJWKClientError):
        resolver(token_with_kid("kid-a"))
    with pytest.raises(UnknownSigningKeyError):
        resolver(token_with_kid("kid-b"))
    clock.advance(JWKS_FORCED_REFRESH_COOLDOWN_SECONDS)
    with pytest.raises(PyJWKClientError):
        resolver(token_with_kid("kid-c"))

    assert len(lookup.calls) == 2


def test_a_cached_kid_resolves_while_forced_refreshes_are_throttled() -> None:
    lookup, clock = ScriptedLookup(PyJWKClientError("no match"), "key-material"), Clock()
    resolver = build_resolver(lookup, clock, cached_kids={"rotated-kid"})

    with pytest.raises(PyJWKClientError):
        resolver(token_with_kid("attacker-kid"))

    assert resolver(token_with_kid("rotated-kid")) == "key-material"
    assert len(lookup.calls) == 2


def test_cached_key_ids_read_the_client_cache_without_fetching() -> None:
    resolver = EntraSigningKeyResolver(TEST_TENANT_ID)
    cache = resolver.jwks_client.jwk_set_cache
    assert cache is not None

    assert resolver.signing_key_ids_in_cache() == set()

    # PyJWT annotates put() as taking a PyJWKSet, but get_jwk_set() only accepts the
    # raw dict that fetch_data() actually stores, so the annotation is the wrong one.
    cache.put(
        cast(
            Any,
            {
                "keys": [
                    {"kty": "oct", "k": OCT_KEY_MATERIAL, "kid": "sig-kid", "use": "sig"},
                    {"kty": "oct", "k": OCT_KEY_MATERIAL, "kid": "enc-kid", "use": "enc"},
                ]
            },
        )
    )

    assert resolver.signing_key_ids_in_cache() == {"sig-kid"}


def test_negative_cache_expires_so_key_rotation_still_resolves() -> None:
    lookup, clock = CountingLookup(), Clock()
    resolver = build_resolver(lookup, clock)
    token = token_with_kid("rotating-kid")

    with pytest.raises(PyJWKClientError):
        resolver(token)
    clock.advance(UNKNOWN_KID_TTL_SECONDS + 1)
    with pytest.raises(PyJWKClientError):
        resolver(token)

    assert len(lookup.calls) == 2


def test_negative_cache_is_bounded_to_a_fixed_number_of_kids() -> None:
    # Driven directly: the global refresh throttle caps how fast the resolver can fill it.
    cache = UnknownKidCache(time_source=Clock())

    for index in range(UNKNOWN_KID_CACHE_SIZE + 1):
        cache.record(f"kid-{index}")

    assert not cache.is_denied("kid-0")
    assert cache.is_denied("kid-1")


def test_tokens_without_a_kid_are_throttled_but_never_denied_permanently() -> None:
    lookup, clock = CountingLookup(), Clock()
    resolver = build_resolver(lookup, clock)
    token = token_with_kid(None)

    with pytest.raises(PyJWKClientError):
        resolver(token)
    with pytest.raises(UnknownSigningKeyError):
        resolver(token)
    clock.advance(JWKS_FORCED_REFRESH_COOLDOWN_SECONDS)
    with pytest.raises(PyJWKClientError) as error:
        resolver(token)

    assert not isinstance(error.value, UnknownSigningKeyError)
    assert len(lookup.calls) == 2


def test_successful_resolution_is_not_negatively_cached() -> None:
    lookup, clock = CountingLookup(key="key-material"), Clock()
    resolver = build_resolver(lookup, clock, cached_kids={"good-kid"})
    token = token_with_kid("good-kid")

    assert resolver(token) == "key-material"
    assert resolver(token) == "key-material"
    assert len(lookup.calls) == 2


def test_connection_failures_are_not_negatively_cached() -> None:
    lookup = ScriptedLookup(PyJWKClientConnectionError("jwks unreachable"), "key-material")
    clock = Clock()
    resolver = build_resolver(lookup, clock)
    token = token_with_kid("legit-kid")

    with pytest.raises(PyJWKClientConnectionError):
        resolver(token)
    # Well short of the negative-cache TTL, so only the connection rule can allow this.
    assert JWKS_FORCED_REFRESH_COOLDOWN_SECONDS < UNKNOWN_KID_TTL_SECONDS
    clock.advance(JWKS_FORCED_REFRESH_COOLDOWN_SECONDS)

    assert resolver(token) == "key-material"
    assert len(lookup.calls) == 2


@pytest.mark.parametrize("token", ["not-a-jwt", "", "a.b.c"])
def test_unparseable_tokens_have_no_cacheable_kid(token: str) -> None:
    assert unverified_kid(token) is None
