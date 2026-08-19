"""Liveness check against the running API container.

This is an integration test: it needs the compose stack (or the built image) to
be listening on port 8000, so it is deselected from the default suite and run
explicitly with `-m integration` after `docker compose up`.
"""

import time

import httpx
import pytest

HEALTH_URL = "http://localhost:8000/health/live"
TIMEOUT_SECONDS = 30.0
POLL_INTERVAL_SECONDS = 1.0
REQUEST_TIMEOUT_SECONDS = 5.0


@pytest.mark.integration
def test_container_reports_alive() -> None:
    """The container may still be starting, so poll until it answers or 30s elapse."""
    deadline = time.monotonic() + TIMEOUT_SECONDS
    last_failure = "no request completed"
    while time.monotonic() < deadline:
        try:
            response = httpx.get(HEALTH_URL, timeout=REQUEST_TIMEOUT_SECONDS)
        except httpx.HTTPError as error:
            last_failure = f"{type(error).__name__}: {error}"
        else:
            if response.status_code == 200:
                assert response.json() == {"status": "alive"}
                return
            last_failure = f"HTTP {response.status_code}"
        time.sleep(POLL_INTERVAL_SECONDS)

    pytest.fail(f"{HEALTH_URL} did not report alive within {TIMEOUT_SECONDS:.0f}s ({last_failure})")
