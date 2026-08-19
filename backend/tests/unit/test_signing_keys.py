"""Signing-key resolution: JWKS cache policy and unknown-kid throttling."""

import threading
import time
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
    _await_jwks_refresh,
    unverified_kid,
)

# Valid base64url for the 24-byte secret backing the symmetric JWKs used below.
OCT_KEY_MATERIAL = "c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0"

# Every wait in these tests is released by an explicit signal, never by elapsing.
# The bound only stops a regression from hanging the suite.
THREAD_TIMEOUT_SECONDS = 5.0
FOLLOWER_COUNT = 8


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


class KidRegistry:
    """Thread-safe stand-in for the set of key ids held in the JWKS cache."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._kids: set[str] = set()

    def snapshot(self) -> set[str]:
        with self._lock:
            return set(self._kids)

    def add(self, kid: str) -> None:
        with self._lock:
            self._kids.add(kid)


class BlockingFirstLookup:
    """Scripted lookup whose first call parks until the test releases it.

    Parking the leader inside the lookup is what makes the single-flight window
    observable: follower threads are provably queued before it completes. A
    successful first call publishes `warm_kid` the way a real refresh would.
    """

    def __init__(
        self,
        *outcomes: Any,
        registry: KidRegistry | None = None,
        warm_kid: str = "",
    ) -> None:
        self.calls: list[str] = []
        self.entered = threading.Event()
        self.release = threading.Event()
        self._outcomes = list(outcomes)
        self._registry = registry
        self._warm_kid = warm_kid
        self._lock = threading.Lock()

    def __call__(self, token: str) -> Any:
        with self._lock:
            self.calls.append(token)
            is_first = len(self.calls) == 1
            outcome = self._outcomes.pop(0)
        if is_first:
            self.entered.set()
            assert self.release.wait(THREAD_TIMEOUT_SECONDS), "leader was never released"
        if isinstance(outcome, Exception):
            raise outcome
        if is_first and self._registry is not None:
            self._registry.add(self._warm_kid)
        return outcome


class RecordingWaiter:
    """Follower wait seam: counts arrivals so the test can barrier on them.

    `ride_the_refresh=False` reproduces a wait that hits its timeout bound
    without the test having to spend the real timeout.
    """

    def __init__(self, *, ride_the_refresh: bool = True) -> None:
        self.arrivals = threading.Semaphore(0)
        self.count = 0
        self._ride = ride_the_refresh
        self._lock = threading.Lock()

    def __call__(self, refresh_done: threading.Event) -> None:
        with self._lock:
            self.count += 1
        self.arrivals.release()
        if self._ride:
            assert refresh_done.wait(THREAD_TIMEOUT_SECONDS), "leader never signalled"

    def await_arrivals(self, expected: int) -> None:
        for _ in range(expected):
            assert self.arrivals.acquire(timeout=THREAD_TIMEOUT_SECONDS), "follower never waited"


class ResolverCall:
    """Runs one resolver call on its own thread and records the outcome."""

    def __init__(self, resolver: EntraSigningKeyResolver, token: str) -> None:
        self._resolver = resolver
        self._token = token
        self.result: Any = None
        self.error: Exception | None = None
        self._thread = threading.Thread(target=self._run)

    def _run(self) -> None:
        try:
            self.result = self._resolver(self._token)
        except Exception as error:
            self.error = error

    def start(self) -> None:
        self._thread.start()

    def join(self) -> None:
        self._thread.join(THREAD_TIMEOUT_SECONDS)
        assert not self._thread.is_alive(), "resolver call never finished"


def token_with_kid(kid: str | None) -> str:
    headers = {"kid": kid} if kid is not None else {}
    return jwt.encode({"sub": "s"}, key="k" * 32, algorithm="HS256", headers=headers)


def concurrent_resolver(
    lookup: Callable[[str], Any],
    registry: KidRegistry,
    waiter: Callable[[threading.Event], None],
    clock: Clock,
) -> EntraSigningKeyResolver:
    return EntraSigningKeyResolver(
        TEST_TENANT_ID,
        key_lookup=lookup,
        cached_key_ids=registry.snapshot,
        time_source=clock,
        refresh_waiter=waiter,
    )


def fetch_must_not_run() -> Any:
    raise AssertionError("the cached-kid probe must never reach the JWKS endpoint")


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


def test_concurrent_cold_cache_requests_share_one_forced_refresh() -> None:
    registry, waiter, clock = KidRegistry(), RecordingWaiter(), Clock()
    lookup = BlockingFirstLookup(
        *["key-material"] * (FOLLOWER_COUNT + 1),
        registry=registry,
        warm_kid="good-kid",
    )
    resolver = concurrent_resolver(lookup, registry, waiter, clock)
    token = token_with_kid("good-kid")

    leader = ResolverCall(resolver, token)
    leader.start()
    assert lookup.entered.wait(THREAD_TIMEOUT_SECONDS), "leader never reached the lookup"
    followers = [ResolverCall(resolver, token) for _ in range(FOLLOWER_COUNT)]
    for follower in followers:
        follower.start()
    waiter.await_arrivals(FOLLOWER_COUNT)
    lookup.release.set()
    for call in [leader, *followers]:
        call.join()

    assert [call.error for call in [leader, *followers]] == [None] * (FOLLOWER_COUNT + 1)
    assert [call.result for call in [leader, *followers]] == ["key-material"] * (FOLLOWER_COUNT + 1)
    # Every follower rode the leader's refresh, so exactly one caller was elected.
    assert waiter.count == FOLLOWER_COUNT


def test_a_leader_connection_failure_fails_followers_closed_without_denying_the_kid() -> None:
    registry, waiter, clock = KidRegistry(), RecordingWaiter(), Clock()
    lookup = BlockingFirstLookup(PyJWKClientConnectionError("jwks unreachable"), "key-material")
    resolver = concurrent_resolver(lookup, registry, waiter, clock)
    token = token_with_kid("legit-kid")

    leader = ResolverCall(resolver, token)
    leader.start()
    assert lookup.entered.wait(THREAD_TIMEOUT_SECONDS), "leader never reached the lookup"
    followers = [ResolverCall(resolver, token) for _ in range(3)]
    for follower in followers:
        follower.start()
    waiter.await_arrivals(3)
    lookup.release.set()
    for call in [leader, *followers]:
        call.join()

    assert isinstance(leader.error, PyJWKClientConnectionError)
    for follower in followers:
        assert isinstance(follower.error, UnknownSigningKeyError)
    # Followers failed closed off the leader's result rather than each fetching.
    assert len(lookup.calls) == 1

    clock.advance(JWKS_FORCED_REFRESH_COOLDOWN_SECONDS)
    assert resolver(token) == "key-material"
    assert len(lookup.calls) == 2


def test_a_follower_whose_wait_expires_fails_closed() -> None:
    registry, clock = KidRegistry(), Clock()
    waiter = RecordingWaiter(ride_the_refresh=False)
    lookup = BlockingFirstLookup("key-material", registry=registry, warm_kid="good-kid")
    resolver = concurrent_resolver(lookup, registry, waiter, clock)
    token = token_with_kid("good-kid")

    leader = ResolverCall(resolver, token)
    leader.start()
    assert lookup.entered.wait(THREAD_TIMEOUT_SECONDS), "leader never reached the lookup"
    follower = ResolverCall(resolver, token)
    follower.start()
    follower.join()
    lookup.release.set()
    leader.join()

    assert isinstance(follower.error, UnknownSigningKeyError)
    assert leader.result == "key-material"
    assert len(lookup.calls) == 1


def test_an_absent_kid_within_the_cooldown_fails_without_waiting_or_fetching() -> None:
    registry, waiter, clock = KidRegistry(), RecordingWaiter(), Clock()
    lookup = ScriptedLookup(PyJWKClientError("no match"))
    resolver = concurrent_resolver(lookup, registry, waiter, clock)

    with pytest.raises(PyJWKClientError):
        resolver(token_with_kid("kid-a"))
    with pytest.raises(UnknownSigningKeyError):
        resolver(token_with_kid("kid-b"))

    # Nothing is in flight to ride, so the throttled caller fails immediately.
    assert waiter.count == 0
    assert len(lookup.calls) == 1


def test_the_default_follower_wait_returns_once_the_leader_signals() -> None:
    # The other concurrency tests inject a waiter, so exercise the real one.
    refresh_done = threading.Event()
    refresh_done.set()
    started = time.monotonic()

    _await_jwks_refresh(refresh_done)

    assert time.monotonic() - started < JWKS_TIMEOUT_SECONDS


def test_cached_key_ids_read_the_client_cache_without_fetching(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    resolver = EntraSigningKeyResolver(TEST_TENANT_ID)
    cache = resolver.jwks_client.jwk_set_cache
    assert cache is not None
    monkeypatch.setattr(resolver.jwks_client, "fetch_data", fetch_must_not_run)

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


def test_cached_key_ids_never_fetch_when_the_cache_expires_mid_read(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    resolver = EntraSigningKeyResolver(TEST_TENANT_ID)
    cache = resolver.jwks_client.jwk_set_cache
    assert cache is not None
    cache.put(
        cast(Any, {"keys": [{"kty": "oct", "k": OCT_KEY_MATERIAL, "kid": "sig-kid", "use": "sig"}]})
    )
    monkeypatch.setattr(resolver.jwks_client, "fetch_data", fetch_must_not_run)
    # Expires the cache immediately after the probe's first read, which is the
    # window a second `get()` would fall through to `fetch_data()`.
    reads = iter([cache.get()])
    monkeypatch.setattr(cache, "get", lambda: next(reads, None))

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
