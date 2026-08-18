"""Route wiring for the cost APIs, with auth and the cost service stubbed out."""

from collections.abc import Iterator
from datetime import UTC, datetime

import pytest
import respx
from fastapi import FastAPI
from fastapi.testclient import TestClient

from constants import TEST_SUBSCRIPTION_ID
from cost_copilot.auth import COST_READER_ROLE, verify_token
from cost_copilot.clients.cost_management import (
    CostAccessDeniedError,
    CostDataset,
    CostManagementClient,
    CostQueryError,
    CostResponseError,
    CostThrottledError,
    CostUpstreamError,
    CostUpstreamTimeoutError,
    parse_query_result,
)
from cost_copilot.config import get_settings
from cost_copilot.main import create_app
from cost_copilot.models.cost import CostFilter
from cost_copilot.routers.costs import (
    UPSTREAM_THROTTLED_DETAIL,
    UPSTREAM_TIMEOUT_DETAIL,
    UPSTREAM_UNAVAILABLE_DETAIL,
    build_cost_service,
    get_cost_service,
    reset_cost_service,
)
from cost_copilot.services.cost_service import CostService
from fixture_data import cost_fixture

CLAIMS = {"oid": "00000000-0000-0000-0000-000000000002", "roles": [COST_READER_ROLE]}
PARAMS = {"start": "2026-08-01", "end": "2026-08-17"}
NOW = datetime(2026, 8, 18, 9, 30, tzinfo=UTC)


class StubCostClient:
    def __init__(self, dataset: CostDataset | None = None, error: Exception | None = None) -> None:
        self._dataset = dataset if dataset is not None else CostDataset(None, ())
        self._error = error
        self.calls: list[tuple[CostFilter, str]] = []

    async def run_query(self, filters: CostFilter, granularity: str) -> CostDataset:
        self.calls.append((filters, granularity))
        if self._error is not None:
            raise self._error
        return self._dataset


def build_client(
    *, authorized: bool = True, client: StubCostClient | None = None
) -> tuple[TestClient, StubCostClient]:
    cost_client = client or StubCostClient(parse_query_result(cost_fixture("groupedDaily")))
    app = create_app()
    # The Entra dependency itself is covered by the auth suite; overriding it keeps
    # these tests off the network while still exercising the role gate.
    app.dependency_overrides[verify_token] = lambda: (
        CLAIMS if authorized else {"oid": CLAIMS["oid"], "roles": []}
    )
    app.dependency_overrides[get_cost_service] = lambda: CostService(cost_client, now=lambda: NOW)
    return TestClient(app), cost_client


@pytest.fixture(autouse=True)
def _forbid_network() -> Iterator[None]:
    """Any escape to ARM fails loudly instead of silently reaching the internet."""
    with respx.mock(assert_all_called=False):
        yield


@pytest.mark.parametrize("path", ["/api/costs/summary", "/api/costs/trend", "/api/costs/breakdown"])
def test_a_caller_without_the_cost_read_role_is_refused(path: str) -> None:
    client, cost_client = build_client(authorized=False)

    response = client.get(path, params=PARAMS)

    assert response.status_code == 403
    assert response.json() == {"detail": "Cost.Read role is required"}
    assert cost_client.calls == []


@pytest.mark.parametrize("path", ["/api/costs/summary", "/api/costs/trend", "/api/costs/breakdown"])
def test_an_anonymous_caller_is_refused(path: str) -> None:
    app: FastAPI = create_app()
    app.dependency_overrides[get_cost_service] = lambda: CostService(StubCostClient())

    response = TestClient(app).get(path, params=PARAMS)

    assert response.status_code == 401


def test_summary_returns_the_typed_payload() -> None:
    client, _ = build_client()

    response = client.get("/api/costs/summary", params=PARAMS)

    assert response.status_code == 200
    body = response.json()
    assert body["total"] == 45.0
    assert body["currency"] == "USD"
    assert body["dataFreshness"] == "2026-08-02"
    assert body["generatedAt"] == "2026-08-18T09:30:00Z"
    assert body["reratingNotice"] is not None
    assert body["topDriver"] == {"name": "Fabrikam Widget Service", "amount": 32.5}
    assert body["forecast"] is None


def test_trend_returns_a_daily_series() -> None:
    client, cost_client = build_client()

    response = client.get("/api/costs/trend", params=PARAMS)

    assert response.status_code == 200
    assert response.json()["points"] == [
        {"usageDate": "2026-08-01", "amount": 20.0},
        {"usageDate": "2026-08-02", "amount": 25.0},
    ]
    assert cost_client.calls[0][1] == "Daily"


def test_breakdown_returns_ranked_items() -> None:
    client, _ = build_client()

    response = client.get(
        "/api/costs/breakdown", params={**PARAMS, "grouping": "ResourceGroupName"}
    )

    assert response.status_code == 200
    body = response.json()
    assert body["grouping"] == "ResourceGroupName"
    assert body["items"][0]["name"] == "Fabrikam Widget Service"
    assert body["otherAmount"] == 0.0


def test_tag_grouping_passes_the_tag_key_through() -> None:
    client, cost_client = build_client()

    response = client.get(
        "/api/costs/breakdown", params={**PARAMS, "grouping": "Tag", "tagKey": "cost-center"}
    )

    assert response.status_code == 200
    assert cost_client.calls[0][0].tag_key == "cost-center"


@pytest.mark.parametrize(
    "params",
    [
        {"start": "2026-08-17", "end": "2026-08-01"},
        {"start": "2025-01-01", "end": "2026-08-01"},
        {"start": "2026-08-01", "end": "2026-08-17", "grouping": "Tag"},
    ],
)
def test_an_invalid_filter_is_refused_before_any_upstream_call(params: dict[str, str]) -> None:
    client, cost_client = build_client()

    response = client.get("/api/costs/summary", params=params)

    assert response.status_code == 422
    assert cost_client.calls == []


@pytest.mark.parametrize(
    "params",
    [
        {"start": "not-a-date", "end": "2026-08-17"},
        {"start": "2026-08-01", "end": "2026-08-17", "grouping": "DROP TABLE"},
        {"start": "2026-08-01", "end": "2026-08-17", "metric": "FreeCost"},
        {"end": "2026-08-17"},
    ],
)
def test_unsupported_query_parameters_are_refused(params: dict[str, str]) -> None:
    client, cost_client = build_client()

    response = client.get("/api/costs/trend", params=params)

    assert response.status_code == 422
    assert cost_client.calls == []


UPSTREAM_DETAIL_LEAK_PROBE = "principal 9f3c at contoso-internal.example"


@pytest.mark.parametrize(
    ("error", "status", "detail"),
    [
        (CostAccessDeniedError(UPSTREAM_DETAIL_LEAK_PROBE), 502, UPSTREAM_UNAVAILABLE_DETAIL),
        (CostThrottledError(UPSTREAM_DETAIL_LEAK_PROBE), 429, UPSTREAM_THROTTLED_DETAIL),
        (CostUpstreamTimeoutError(UPSTREAM_DETAIL_LEAK_PROBE), 504, UPSTREAM_TIMEOUT_DETAIL),
        (CostResponseError(UPSTREAM_DETAIL_LEAK_PROBE), 502, UPSTREAM_UNAVAILABLE_DETAIL),
        (CostUpstreamError(UPSTREAM_DETAIL_LEAK_PROBE), 502, UPSTREAM_UNAVAILABLE_DETAIL),
        (CostQueryError(UPSTREAM_DETAIL_LEAK_PROBE), 502, UPSTREAM_UNAVAILABLE_DETAIL),
    ],
)
def test_upstream_failures_map_to_safe_statuses(
    error: CostQueryError, status: int, detail: str
) -> None:
    client, _ = build_client(client=StubCostClient(error=error))

    response = client.get("/api/costs/summary", params=PARAMS)

    assert response.status_code == status
    assert response.json() == {"detail": detail}
    assert "contoso-internal" not in response.text


async def test_the_default_service_targets_only_the_configured_subscription() -> None:
    client = build_cost_service(get_settings()).client
    assert isinstance(client, CostManagementClient)
    try:
        assert client.url == (
            f"https://management.azure.com/subscriptions/{TEST_SUBSCRIPTION_ID}"
            "/providers/Microsoft.CostManagement/query?api-version=2026-06-01"
        )
    finally:
        await client.aclose()


async def test_the_default_service_is_reused_across_requests() -> None:
    settings = get_settings()
    first = get_cost_service(settings)
    try:
        assert get_cost_service(settings) is first
        assert isinstance(first.client, CostManagementClient)
    finally:
        assert isinstance(first.client, CostManagementClient)
        await first.client.aclose()
        reset_cost_service()
