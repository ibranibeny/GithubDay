"""Query construction, filter validation, and transport behaviour of the cost client."""

import asyncio
from collections.abc import AsyncIterator
from datetime import date
from typing import Any

import httpx
import pytest
import respx
from pydantic import ValidationError

from constants import TEST_SUBSCRIPTION_ID
from cost_copilot.clients.cost_management import (
    API_VERSION,
    BASE_RETRY_DELAY_SECONDS,
    MAX_PAGES,
    QUERY_DEADLINE_SECONDS,
    RETRY_JITTER_FRACTION,
    CostAccessDeniedError,
    CostManagementClient,
    CostResponseError,
    CostThrottledError,
    CostUpstreamError,
    CostUpstreamTimeoutError,
    CredentialTokenProvider,
    build_query,
    query_url,
)
from cost_copilot.config import get_settings
from cost_copilot.models.cost import CostFilter, CostGrouping, CostMetric
from fixture_data import cost_fixture

QUERY_URL = (
    f"https://management.azure.com/subscriptions/{TEST_SUBSCRIPTION_ID}"
    f"/providers/Microsoft.CostManagement/query?api-version={API_VERSION}"
)
ACCESS_TOKEN = "fake-access-token"  # noqa: S105  # not a credential, only a stub value


def a_filter(**overrides: object) -> CostFilter:
    values: dict[str, object] = {
        "start": date(2026, 8, 1),
        "end": date(2026, 8, 17),
        "metric": CostMetric.ACTUAL,
        "grouping": CostGrouping.SERVICE,
    }
    values.update(overrides)
    return CostFilter.model_validate(values)


async def a_token() -> str:
    return ACCESS_TOKEN


async def no_sleep(seconds: float) -> None:
    return None


def a_client(http_client: httpx.AsyncClient, **overrides: Any) -> CostManagementClient:
    """A client wired to stubs; every timing input is injectable so tests stay offline."""
    arguments: dict[str, Any] = {
        "settings": get_settings(),
        "http_client": http_client,
        "acquire_token": a_token,
        "sleep": no_sleep,
        "jitter": lambda: 0.0,
    }
    arguments.update(overrides)
    return CostManagementClient(**arguments)


class SteppingClock:
    """Advances a fixed amount per read so a wall-clock budget expires deterministically."""

    def __init__(self, step: float) -> None:
        self._step = step
        self.now = 0.0

    def __call__(self) -> float:
        self.now += self._step
        return self.now


@pytest.fixture
async def recorded_delays() -> list[float]:
    return []


@pytest.fixture
async def client(recorded_delays: list[float]) -> AsyncIterator[CostManagementClient]:
    async def sleep(seconds: float) -> None:
        recorded_delays.append(seconds)

    http_client = httpx.AsyncClient()
    try:
        yield a_client(http_client, sleep=sleep)
    finally:
        await http_client.aclose()


# --- build_query -----------------------------------------------------------


def test_daily_query_is_bounded_and_grouped() -> None:
    query = build_query(a_filter(), granularity="Daily")

    assert query["type"] == "ActualCost"
    assert query["timeframe"] == "Custom"
    dataset = query["dataset"]
    assert dataset["granularity"] == "Daily"
    assert dataset["aggregation"] == {"totalCost": {"name": "Cost", "function": "Sum"}}
    assert dataset["grouping"] == [{"type": "Dimension", "name": "ServiceName"}]


def test_the_time_period_is_emitted_as_utc_date_times_covering_both_end_days() -> None:
    query = build_query(a_filter(), granularity="Daily")

    assert query["timePeriod"] == {
        "from": "2026-08-01T00:00:00+00:00",
        "to": "2026-08-17T23:59:59+00:00",
    }


def test_amortized_metric_maps_to_the_documented_export_type() -> None:
    query = build_query(a_filter(metric=CostMetric.AMORTIZED), granularity="None")

    assert query["type"] == "AmortizedCost"
    assert query["dataset"]["granularity"] == "None"


def test_tag_grouping_emits_a_tag_key_grouping() -> None:
    query = build_query(a_filter(grouping=CostGrouping.TAG, tag_key="cost-center"), "None")

    assert query["dataset"]["grouping"] == [{"type": "TagKey", "name": "cost-center"}]


# --- CostFilter validation -------------------------------------------------


def test_end_before_start_is_rejected() -> None:
    with pytest.raises(ValidationError, match="on or after"):
        a_filter(start=date(2026, 8, 17), end=date(2026, 8, 1))


def test_range_longer_than_366_days_is_rejected() -> None:
    with pytest.raises(ValidationError, match="366"):
        a_filter(start=date(2025, 1, 1), end=date(2026, 8, 1))


def test_tag_grouping_without_a_tag_key_is_rejected() -> None:
    with pytest.raises(ValidationError, match="tag_key"):
        a_filter(grouping=CostGrouping.TAG)


def test_blank_tag_key_is_rejected() -> None:
    with pytest.raises(ValidationError, match="tag_key"):
        a_filter(grouping=CostGrouping.TAG, tag_key="   ")


def test_tag_key_with_control_characters_is_rejected() -> None:
    with pytest.raises(ValidationError, match="printable"):
        a_filter(grouping=CostGrouping.TAG, tag_key="cost\ncenter")


@pytest.mark.parametrize(
    "grouping", [CostGrouping.SERVICE, CostGrouping.RESOURCE_GROUP, CostGrouping.RESOURCE]
)
def test_a_tag_key_without_tag_grouping_is_rejected(grouping: CostGrouping) -> None:
    with pytest.raises(ValidationError, match="tag grouping"):
        a_filter(grouping=grouping, tag_key="cost-center")


def test_azure_dimension_prefers_the_tag_key_for_tag_grouping() -> None:
    assert a_filter().azure_dimension == "ServiceName"
    assert a_filter(grouping=CostGrouping.TAG, tag_key="team").azure_dimension == "team"


def test_preceding_period_has_the_same_length_and_ends_the_day_before() -> None:
    previous = a_filter().preceding_period()

    assert previous.end == date(2026, 7, 31)
    assert previous.start == date(2026, 7, 15)
    assert previous.day_count == a_filter().day_count


# --- transport -------------------------------------------------------------


@respx.mock
async def test_query_posts_to_the_configured_subscription_url(
    client: CostManagementClient,
) -> None:
    route = respx.post(QUERY_URL).mock(
        return_value=httpx.Response(200, json=cost_fixture("groupedDaily"))
    )

    dataset = await client.run_query(a_filter(), "Daily")

    assert route.called
    request = route.calls.last.request
    assert str(request.url) == QUERY_URL
    assert request.headers["authorization"] == f"Bearer {ACCESS_TOKEN}"
    assert len(dataset.records) == 4
    assert dataset.currency == "USD"


@respx.mock
async def test_caller_supplied_values_never_reach_the_request_url(
    client: CostManagementClient,
) -> None:
    hostile = "../../subscriptions/00000000-0000-0000-0000-000000000000?x=1"
    route = respx.post(QUERY_URL).mock(
        return_value=httpx.Response(200, json=cost_fixture("ungrouped"))
    )

    await client.run_query(a_filter(grouping=CostGrouping.TAG, tag_key=hostile), "None")

    request = route.calls.last.request
    assert str(request.url) == QUERY_URL
    assert hostile.encode() in request.content  # it belongs in the JSON body, nowhere else


def test_query_url_is_derived_only_from_settings() -> None:
    assert query_url(get_settings().azure_subscription_id) == QUERY_URL


@respx.mock
@pytest.mark.parametrize("fixture", ["preTaxCostOffer", "preTaxCostOfferWithQuantity"])
async def test_a_legacy_offer_cost_column_is_bound_end_to_end(
    client: CostManagementClient, fixture: str
) -> None:
    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, json=cost_fixture(fixture)))

    dataset = await client.run_query(a_filter(grouping=CostGrouping.RESOURCE_GROUP), "Daily")

    assert dataset.currency == "EUR"
    assert [(record.dimension, record.amount) for record in dataset.records] == [
        ("rg-fabrikam-dev", 41.25),
        ("rg-fabrikam-prod", 108.75),
    ]


@respx.mock
async def test_a_tag_grouped_response_binds_the_tag_value_column(
    client: CostManagementClient,
) -> None:
    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, json=cost_fixture("tagGrouped")))

    dataset = await client.run_query(
        a_filter(grouping=CostGrouping.TAG, tag_key="cost-center"), "Daily"
    )

    assert [record.dimension for record in dataset.records] == ["fin-ops", "platform"]


@respx.mock
async def test_the_requested_dimension_wins_over_another_string_column(
    client: CostManagementClient,
) -> None:
    respx.post(QUERY_URL).mock(
        return_value=httpx.Response(200, json=cost_fixture("dimensionGroupedWithExtraString"))
    )

    dataset = await client.run_query(a_filter(), "Daily")

    assert [record.dimension for record in dataset.records] == [
        "Fabrikam Widget Service",
        "Fabrikam Ledger Service",
    ]


@respx.mock
async def test_a_tag_grouped_response_without_a_tag_value_column_is_unassigned(
    client: CostManagementClient,
) -> None:
    respx.post(QUERY_URL).mock(
        return_value=httpx.Response(200, json=cost_fixture("tagGroupedWithoutTagValue"))
    )

    dataset = await client.run_query(
        a_filter(grouping=CostGrouping.TAG, tag_key="cost-center"), "Daily"
    )

    assert [record.dimension for record in dataset.records] == ["Unassigned"]


@respx.mock
async def test_no_content_yields_an_empty_dataset(client: CostManagementClient) -> None:
    respx.post(QUERY_URL).mock(return_value=httpx.Response(204))

    dataset = await client.run_query(a_filter(), "Daily")

    assert dataset.records == ()
    assert dataset.currency is None


@respx.mock
async def test_a_success_body_without_properties_is_rejected_instead_of_reading_as_zero(
    client: CostManagementClient,
) -> None:
    """A 200 that lost its payload must fail closed; only a real 204 means "no cost"."""
    respx.post(QUERY_URL).mock(
        return_value=httpx.Response(200, json={"id": "/subscriptions/contoso-secret/query"})
    )

    with pytest.raises(CostResponseError, match="properties") as raised:
        await client.run_query(a_filter(), "Daily")

    assert "contoso-secret" not in str(raised.value)


@respx.mock
async def test_throttling_is_retried_using_retry_after_then_succeeds(
    client: CostManagementClient, recorded_delays: list[float]
) -> None:
    respx.post(QUERY_URL).mock(
        side_effect=[
            httpx.Response(429, headers={"x-ms-ratelimit-microsoft.consumption-retry-after": "4"}),
            httpx.Response(503, headers={"Retry-After": "2"}),
            httpx.Response(200, json=cost_fixture("groupedDaily")),
        ]
    )

    dataset = await client.run_query(a_filter(), "Daily")

    assert len(dataset.records) == 4
    assert recorded_delays == [4.0, 2.0]


@respx.mock
async def test_retry_after_is_capped_and_falls_back_when_unparsable(
    client: CostManagementClient, recorded_delays: list[float]
) -> None:
    respx.post(QUERY_URL).mock(
        side_effect=[
            httpx.Response(429, headers={"Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"}),
            httpx.Response(502, headers={"Retry-After": "9000"}),
            httpx.Response(200, json=cost_fixture("groupedDaily")),
        ]
    )

    await client.run_query(a_filter(), "Daily")

    assert recorded_delays == [1.0, 30.0]


@respx.mock
async def test_throttling_gives_up_after_three_retries(
    client: CostManagementClient, recorded_delays: list[float]
) -> None:
    respx.post(QUERY_URL).mock(return_value=httpx.Response(429))

    with pytest.raises(CostThrottledError):
        await client.run_query(a_filter(), "Daily")

    assert len(recorded_delays) == 3


@respx.mock
async def test_persistent_server_errors_surface_as_an_upstream_error(
    client: CostManagementClient,
) -> None:
    respx.post(QUERY_URL).mock(return_value=httpx.Response(503))

    with pytest.raises(CostUpstreamError) as raised:
        await client.run_query(a_filter(), "Daily")

    assert "503" in str(raised.value)


@pytest.mark.parametrize("status", [401, 403])
async def test_identity_rejection_maps_to_a_typed_error_without_leaking(
    client: CostManagementClient, status: int
) -> None:
    with respx.mock:
        respx.post(QUERY_URL).mock(
            return_value=httpx.Response(
                status,
                json={
                    "error": {"code": "AuthorizationFailed", "message": "principal abc-123 denied"}
                },
            )
        )

        with pytest.raises(CostAccessDeniedError) as raised:
            await client.run_query(a_filter(), "Daily")

    message = str(raised.value)
    assert "abc-123" not in message
    assert "AuthorizationFailed" not in message
    assert ACCESS_TOKEN not in message


@respx.mock
async def test_client_errors_do_not_leak_the_arm_response_body(
    client: CostManagementClient,
) -> None:
    respx.post(QUERY_URL).mock(
        return_value=httpx.Response(400, json={"error": {"message": "tenant contoso is invalid"}})
    )

    with pytest.raises(CostUpstreamError) as raised:
        await client.run_query(a_filter(), "Daily")

    assert "contoso" not in str(raised.value)


@respx.mock
async def test_timeouts_are_retried_then_reported_as_a_timeout(
    client: CostManagementClient, recorded_delays: list[float]
) -> None:
    respx.post(QUERY_URL).mock(side_effect=httpx.ReadTimeout("timed out"))

    with pytest.raises(CostUpstreamTimeoutError):
        await client.run_query(a_filter(), "Daily")

    assert len(recorded_delays) == 3


@respx.mock
async def test_connection_failures_are_not_retried(
    client: CostManagementClient, recorded_delays: list[float]
) -> None:
    respx.post(QUERY_URL).mock(side_effect=httpx.ConnectError("no route"))

    with pytest.raises(CostUpstreamError):
        await client.run_query(a_filter(), "Daily")

    assert recorded_delays == []


@respx.mock
async def test_unparsable_success_body_is_rejected(client: CostManagementClient) -> None:
    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, content=b"not json"))

    with pytest.raises(CostResponseError):
        await client.run_query(a_filter(), "Daily")


@respx.mock
async def test_a_success_body_that_is_not_an_object_is_rejected(
    client: CostManagementClient,
) -> None:
    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, json=[1, 2, 3]))

    with pytest.raises(CostResponseError, match="object"):
        await client.run_query(a_filter(), "Daily")


@respx.mock
async def test_a_negative_retry_after_falls_back_to_the_local_backoff(
    client: CostManagementClient, recorded_delays: list[float]
) -> None:
    respx.post(QUERY_URL).mock(
        side_effect=[
            httpx.Response(503, headers={"Retry-After": "-5"}),
            httpx.Response(200, json=cost_fixture("groupedDaily")),
        ]
    )

    await client.run_query(a_filter(), "Daily")

    assert recorded_delays == [1.0]


@respx.mock
async def test_next_link_pages_are_concatenated(client: CostManagementClient) -> None:
    page_one = cost_fixture("pageOne")
    next_link = page_one["properties"]["nextLink"]
    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, json=page_one))
    second = respx.post(next_link).mock(
        return_value=httpx.Response(200, json=cost_fixture("pageTwo"))
    )

    dataset = await client.run_query(a_filter(), "Daily")

    assert second.called
    assert [record.amount for record in dataset.records] == [12.5, 7.5]


@respx.mock
async def test_a_page_that_changes_the_schema_is_rejected(client: CostManagementClient) -> None:
    page_one = cost_fixture("pageOne")
    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, json=page_one))
    respx.post(page_one["properties"]["nextLink"]).mock(
        return_value=httpx.Response(200, json=cost_fixture("pageTwoDifferentSchema"))
    )

    with pytest.raises(CostResponseError, match="schema"):
        await client.run_query(a_filter(), "Daily")


@respx.mock
async def test_a_next_link_off_the_management_host_is_refused(
    client: CostManagementClient,
) -> None:
    hostile = cost_fixture("hostileNextLink")
    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, json=hostile))
    off_host = respx.post(hostile["properties"]["nextLink"]).mock(
        return_value=httpx.Response(200, json=cost_fixture("pageTwo"))
    )

    with pytest.raises(CostResponseError, match="paging link"):
        await client.run_query(a_filter(), "Daily")

    assert not off_host.called


@respx.mock
async def test_endless_paging_is_bounded(client: CostManagementClient) -> None:
    page = cost_fixture("pageOne")
    page["properties"]["nextLink"] = QUERY_URL
    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, json=page))

    with pytest.raises(CostUpstreamError, match="pages"):
        await client.run_query(a_filter(), "Daily")

    assert respx.calls.call_count == MAX_PAGES


# --- the cumulative query deadline -----------------------------------------


@respx.mock
async def test_paging_stops_once_the_query_budget_is_spent() -> None:
    """The per-attempt timeout must not multiply across pages."""
    page = cost_fixture("pageOne")
    page["properties"]["nextLink"] = QUERY_URL
    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, json=page))

    async with httpx.AsyncClient() as http_client:
        client = a_client(http_client, clock=SteppingClock(QUERY_DEADLINE_SECONDS / 4))

        with pytest.raises(CostUpstreamTimeoutError):
            await client.run_query(a_filter(), "Daily")

    assert 0 < respx.calls.call_count < MAX_PAGES


@respx.mock
async def test_retrying_stops_once_the_query_budget_is_spent() -> None:
    respx.post(QUERY_URL).mock(return_value=httpx.Response(429))

    async with httpx.AsyncClient() as http_client:
        client = a_client(http_client, clock=SteppingClock(QUERY_DEADLINE_SECONDS / 2))

        with pytest.raises(CostUpstreamTimeoutError):
            await client.run_query(a_filter(), "Daily")

    assert respx.calls.call_count == 1


@respx.mock
async def test_a_request_timeout_never_outlives_the_remaining_budget() -> None:
    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, json=cost_fixture("groupedDaily")))

    async with httpx.AsyncClient() as http_client:
        client = a_client(http_client, clock=SteppingClock(QUERY_DEADLINE_SECONDS - 1.0))

        await client.run_query(a_filter(), "Daily")

    assert respx.calls.last.request.extensions["timeout"]["read"] == pytest.approx(1.0)


@respx.mock
async def test_local_backoff_carries_jitter(recorded_delays: list[float]) -> None:
    """Jitter decorrelates retries across instances; the cap still applies."""

    async def sleep(seconds: float) -> None:
        recorded_delays.append(seconds)

    respx.post(QUERY_URL).mock(
        side_effect=[
            httpx.Response(503),
            httpx.Response(200, json=cost_fixture("groupedDaily")),
        ]
    )

    async with httpx.AsyncClient() as http_client:
        client = a_client(http_client, sleep=sleep, jitter=lambda: 1.0)

        await client.run_query(a_filter(), "Daily")

    assert recorded_delays == [BASE_RETRY_DELAY_SECONDS * (1.0 + RETRY_JITTER_FRACTION)]


# --- lifecycle -------------------------------------------------------------


async def test_aclose_leaves_a_pool_the_caller_owns_open() -> None:
    async with httpx.AsyncClient() as http_client:
        client = a_client(http_client)

        await client.aclose()

        assert not client.is_closed


async def test_aclose_closes_a_pool_the_client_owns() -> None:
    client = a_client(httpx.AsyncClient(), owns_client=True)

    await client.aclose()

    assert client.is_closed


# --- token acquisition -----------------------------------------------------


class _StubAccessToken:
    def __init__(self, token: str) -> None:
        self.token = token
        self.expires_on = 0


class _StubCredential:
    def __init__(self) -> None:
        self.scopes: list[tuple[str, ...]] = []
        self.closed = False

    def get_token(self, *scopes: str) -> _StubAccessToken:
        self.scopes.append(scopes)
        return _StubAccessToken(ACCESS_TOKEN)

    def close(self) -> None:
        self.closed = True


async def test_token_provider_requests_the_management_scope() -> None:
    credential = _StubCredential()
    provider = CredentialTokenProvider(credential)

    assert await provider() == ACCESS_TOKEN
    assert credential.scopes == [("https://management.azure.com/.default",)]


async def test_token_provider_closes_the_credential_it_was_given() -> None:
    credential = _StubCredential()
    provider = CredentialTokenProvider(credential)

    await provider.aclose()

    assert credential.closed


@respx.mock
async def test_every_page_is_authorized_with_a_freshly_acquired_token() -> None:
    """A long paging loop can outlive a token, and the credential caches, so re-ask."""
    tokens: list[str] = []

    async def rotating_token() -> str:
        tokens.append(f"token-{len(tokens)}")
        return tokens[-1]

    page_one = cost_fixture("pageOne")
    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, json=page_one))
    second = respx.post(page_one["properties"]["nextLink"]).mock(
        return_value=httpx.Response(200, json=cost_fixture("pageTwo"))
    )

    async with httpx.AsyncClient() as http_client:
        await a_client(http_client, acquire_token=rotating_token).run_query(a_filter(), "Daily")

    assert tokens == ["token-0", "token-1"]
    assert second.calls.last.request.headers["authorization"] == "Bearer token-1"


@respx.mock
async def test_concurrent_queries_acquire_a_token_one_at_a_time() -> None:
    """Single-flight: a cold credential must not be hit by every in-flight query."""
    in_flight = 0
    peak = 0

    async def counting_token() -> str:
        nonlocal in_flight, peak
        in_flight += 1
        peak = max(peak, in_flight)
        await asyncio.sleep(0)
        in_flight -= 1
        return ACCESS_TOKEN

    respx.post(QUERY_URL).mock(return_value=httpx.Response(200, json=cost_fixture("groupedDaily")))

    async with httpx.AsyncClient() as http_client:
        client = a_client(http_client, acquire_token=counting_token)

        await asyncio.gather(
            client.run_query(a_filter(), "Daily"), client.run_query(a_filter(), "Daily")
        )

    assert peak == 1
