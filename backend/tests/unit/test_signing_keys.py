"""Signing-key resolution: JWKS cache policy and unknown-kid throttling."""

from typing import Any

import jwt
import pytest
from jwt.exceptions import PyJWKClientError

from constants import TEST_TENANT_ID
from cost_copilot.auth import (
    JWKS_CACHE_LIFESPAN_SECONDS,
    JWKS_TIMEOUT_SECONDS,
    UNKNOWN_KID_CACHE_SIZE,
    UNKNOWN_KID_TTL_SECONDS,
    EntraSigningKeyResolver,
    UnknownSigningKeyError,
    unverified_kid,
)


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


def token_with_kid(kid: str | None) -> str:
    headers = {"kid": kid} if kid is not None else {}
    return jwt.encode({"sub": "s"}, key="k" * 32, algorithm="HS256", headers=headers)


def build_resolver(lookup: CountingLookup, clock: Clock) -> EntraSigningKeyResolver:
    return EntraSigningKeyResolver(TEST_TENANT_ID, key_lookup=lookup, time_source=clock)


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


def test_a_different_unknown_kid_is_still_looked_up() -> None:
    lookup, clock = CountingLookup(), Clock()
    resolver = build_resolver(lookup, clock)

    for kid in ("kid-a", "kid-b"):
        with pytest.raises(PyJWKClientError):
            resolver(token_with_kid(kid))

    assert len(lookup.calls) == 2


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
    lookup, clock = CountingLookup(), Clock()
    resolver = build_resolver(lookup, clock)
    first = token_with_kid("kid-0")

    with pytest.raises(PyJWKClientError):
        resolver(first)
    for index in range(1, UNKNOWN_KID_CACHE_SIZE + 1):
        with pytest.raises(PyJWKClientError):
            resolver(token_with_kid(f"kid-{index}"))

    # The oldest entry was evicted, so the first kid is looked up again.
    with pytest.raises(PyJWKClientError):
        resolver(first)
    assert lookup.calls[-1] == first


def test_tokens_without_a_kid_are_never_negatively_cached() -> None:
    lookup, clock = CountingLookup(), Clock()
    resolver = build_resolver(lookup, clock)
    token = token_with_kid(None)

    for _ in range(3):
        with pytest.raises(PyJWKClientError):
            resolver(token)

    assert len(lookup.calls) == 3


def test_successful_resolution_is_not_negatively_cached() -> None:
    lookup, clock = CountingLookup(key="key-material"), Clock()
    resolver = build_resolver(lookup, clock)
    token = token_with_kid("good-kid")

    assert resolver(token) == "key-material"
    assert resolver(token) == "key-material"
    assert len(lookup.calls) == 2


@pytest.mark.parametrize("token", ["not-a-jwt", "", "a.b.c"])
def test_unparseable_tokens_have_no_cacheable_kid(token: str) -> None:
    assert unverified_kid(token) is None
