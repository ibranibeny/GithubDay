"""Bounded, single-flight, fail-closed token acquisition.

Nothing here reaches Azure: the credential is a stub whose `get_token` either
raises or parks, so the failure mapping, the acquisition bound, and the
single-flight guarantee are all exercised deterministically and offline.
"""

import asyncio
import threading
import time

import pytest
from azure.core.exceptions import ClientAuthenticationError
from azure.identity import CredentialUnavailableError

from cost_copilot.clients.credentials import (
    TOKEN_ACQUISITION_TIMEOUT_SECONDS,
    CredentialAcquisitionError,
    CredentialError,
    CredentialTimeoutError,
    CredentialTokenProvider,
)

ACCESS_TOKEN = "fake-access-token"  # noqa: S105  # not a credential, only a stub value
LEAK_PROBE = "sk-live-abcdef principal 9f3c at contoso-internal.example"
# Small enough that a regression is measured in milliseconds, not in the real bound.
TEST_BOUND_SECONDS = 0.05
# Long enough that two unsynchronized acquisitions would overlap and be observed.
SLOW_ACQUISITION_SECONDS = 0.02


class _StubAccessToken:
    def __init__(self, token: str) -> None:
        self.token = token


class _FailingCredential:
    def __init__(self, error: Exception) -> None:
        self._error = error

    def get_token(self, *scopes: str) -> _StubAccessToken:
        raise self._error

    def close(self) -> None: ...


class _ParkedCredential:
    """Stands in for an identity endpoint that accepts the call and never answers."""

    def __init__(self) -> None:
        self.release = threading.Event()

    def get_token(self, *scopes: str) -> _StubAccessToken:
        # Bounded so a regression fails the suite instead of hanging it.
        self.release.wait(timeout=10.0)
        return _StubAccessToken(ACCESS_TOKEN)

    def close(self) -> None: ...


class _SlowCredential:
    """Records how many acquisitions the credential is asked to serve at once."""

    def __init__(self) -> None:
        self.calls = 0
        self.peak = 0
        self._in_flight = 0
        self._lock = threading.Lock()

    def get_token(self, *scopes: str) -> _StubAccessToken:
        with self._lock:
            self.calls += 1
            self._in_flight += 1
            self.peak = max(self.peak, self._in_flight)
        time.sleep(SLOW_ACQUISITION_SECONDS)
        with self._lock:
            self._in_flight -= 1
        return _StubAccessToken(ACCESS_TOKEN)

    def close(self) -> None: ...


@pytest.mark.parametrize(
    "raised",
    [
        pytest.param(ClientAuthenticationError(LEAK_PROBE), id="client-authentication"),
        pytest.param(CredentialUnavailableError(LEAK_PROBE), id="credential-unavailable"),
        pytest.param(RuntimeError(LEAK_PROBE), id="generic-credential-failure"),
    ],
)
async def test_a_credential_failure_becomes_a_typed_error_without_leaking(
    raised: Exception,
) -> None:
    """Every consumer awaits this provider, so a raw credential error must not escape it."""
    provider = CredentialTokenProvider(_FailingCredential(raised))

    with pytest.raises(CredentialAcquisitionError) as caught:
        await provider()

    assert isinstance(caught.value, CredentialError)
    assert "contoso-internal" not in str(caught.value)
    assert "sk-live" not in str(caught.value)


async def test_a_credential_failure_is_logged_by_type_only(
    caplog: pytest.LogCaptureFixture,
) -> None:
    provider = CredentialTokenProvider(_FailingCredential(ClientAuthenticationError(LEAK_PROBE)))

    with caplog.at_level("WARNING"), pytest.raises(CredentialAcquisitionError):
        await provider()

    assert "ClientAuthenticationError" in caplog.text
    assert "contoso-internal" not in caplog.text


async def test_a_parked_credential_is_refused_within_the_acquisition_bound() -> None:
    """A hung identity endpoint must not consume the caller's whole request budget."""
    credential = _ParkedCredential()
    provider = CredentialTokenProvider(credential, timeout=TEST_BOUND_SECONDS)
    started = time.monotonic()

    try:
        with pytest.raises(CredentialTimeoutError):
            await provider()

        # Generous, but far below the credential's own 10s park: an unbounded
        # acquisition would sit here for the full park instead.
        assert time.monotonic() - started < 5.0
    finally:
        credential.release.set()


def test_the_default_acquisition_bound_leaves_room_in_the_request_budget() -> None:
    assert 0 < TOKEN_ACQUISITION_TIMEOUT_SECONDS <= 10.0


async def test_concurrent_callers_share_one_in_flight_acquisition() -> None:
    """Single-flight: a cold credential is asked once at a time, not once per caller."""
    credential = _SlowCredential()
    provider = CredentialTokenProvider(credential)

    tokens = await asyncio.gather(*(provider() for _ in range(4)))

    assert tokens == [ACCESS_TOKEN] * 4
    assert credential.peak == 1


async def test_a_queued_caller_is_bounded_while_it_waits_for_the_lock() -> None:
    """The bound covers waiting for the single-flight lock, not just the credential call."""
    credential = _ParkedCredential()
    provider = CredentialTokenProvider(credential, timeout=TEST_BOUND_SECONDS)

    try:
        results = await asyncio.gather(provider(), provider(), return_exceptions=True)

        assert [type(result) for result in results] == [
            CredentialTimeoutError,
            CredentialTimeoutError,
        ]
    finally:
        credential.release.set()
