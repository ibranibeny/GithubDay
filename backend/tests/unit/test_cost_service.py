"""Aggregation rules for the cost service, exercised against an injected client."""

import asyncio
from datetime import UTC, date, datetime

import pytest

from cost_copilot.clients.cost_management import (
    CostDataset,
    CostRecord,
    CostUpstreamError,
    parse_query_result,
)
from cost_copilot.models.cost import CostFilter, CostGrouping, CostMetric
from cost_copilot.services.cost_service import CostService
from fixture_data import cost_fixture

NOW = datetime(2026, 8, 18, 9, 30, tzinfo=UTC)


class StubCostClient:
    """Returns a queued dataset per call and records what was asked for."""

    def __init__(self, *datasets: CostDataset) -> None:
        self._datasets = list(datasets)
        self.calls: list[tuple[CostFilter, str]] = []
        self.in_flight = 0
        self.peak_in_flight = 0

    async def run_query(self, filters: CostFilter, granularity: str) -> CostDataset:
        index = len(self.calls)
        self.calls.append((filters, granularity))
        self.in_flight += 1
        self.peak_in_flight = max(self.peak_in_flight, self.in_flight)
        try:
            await asyncio.sleep(0)  # a yield point, so concurrent callers can overlap
            return self._datasets[min(index, len(self._datasets) - 1)]
        finally:
            self.in_flight -= 1


def a_filter(**overrides: object) -> CostFilter:
    values: dict[str, object] = {
        "start": date(2026, 8, 1),
        "end": date(2026, 8, 17),
        "metric": CostMetric.ACTUAL,
        "grouping": CostGrouping.SERVICE,
    }
    values.update(overrides)
    return CostFilter.model_validate(values)


def a_dataset(*records: tuple[date | None, str, float], currency: str = "USD") -> CostDataset:
    return CostDataset(
        currency=currency,
        records=tuple(CostRecord(usage_date=d, dimension=name, amount=a) for d, name, a in records),
    )


def a_service(*datasets: CostDataset) -> tuple[CostService, StubCostClient]:
    client = StubCostClient(*datasets)
    return CostService(client, now=lambda: NOW), client


async def test_summary_totals_compare_against_the_preceding_period() -> None:
    current = parse_query_result(cost_fixture("groupedDaily"))
    previous = a_dataset((date(2026, 7, 20), "Fabrikam Widget Service", 30.0))
    service, client = a_service(current, previous)

    summary = await service.summary(a_filter())

    assert summary.total == 45.0
    assert summary.previous_total == 30.0
    assert summary.change is not None
    assert summary.change.amount == 15.0
    assert summary.change.percentage == 50.0
    assert client.calls[0][1] == "Daily"
    assert client.calls[1][0].end == date(2026, 7, 31)


async def test_summary_runs_both_period_queries_concurrently() -> None:
    service, client = a_service(parse_query_result(cost_fixture("groupedDaily")), a_dataset())

    await service.summary(a_filter())

    assert client.peak_in_flight == 2


class FailFirstClient:
    """Fails the first period query and records whether the second one was cancelled."""

    def __init__(self) -> None:
        self.calls = 0
        self.sibling_cancelled = False

    async def run_query(self, filters: CostFilter, granularity: str) -> CostDataset:
        self.calls += 1
        if self.calls == 1:
            await asyncio.sleep(0)  # let the sibling reach its own await first
            raise CostUpstreamError("upstream refused the period query")
        try:
            # Bounded so a regression fails the suite instead of hanging it.
            await asyncio.sleep(5.0)
        except asyncio.CancelledError:
            self.sibling_cancelled = True
            raise
        return CostDataset(currency=None, records=())  # pragma: no cover - cancelled first


async def test_a_failing_period_query_cancels_its_sibling() -> None:
    """An orphaned sibling would outlive the request and drop its own exception."""
    client = FailFirstClient()
    service = CostService(client, now=lambda: NOW)

    with pytest.raises(CostUpstreamError):
        await service.summary(a_filter())

    assert client.calls == 2
    assert client.sibling_cancelled


async def test_a_comparison_across_currencies_is_withheld_rather_than_invented() -> None:
    """A EUR period minus a USD period is not a number anyone should act on."""
    current = a_dataset((date(2026, 8, 1), "Fabrikam Widget Service", 45.0), currency="EUR")
    previous = a_dataset((date(2026, 7, 20), "Fabrikam Widget Service", 30.0), currency="USD")
    service, _ = a_service(current, previous)

    summary = await service.summary(a_filter())

    assert summary.currency == "EUR"
    assert summary.total == 45.0
    assert summary.previous_total is None
    assert summary.change is None


async def test_a_comparison_is_kept_when_only_one_period_reports_a_currency() -> None:
    current = a_dataset((date(2026, 8, 1), "Fabrikam Widget Service", 45.0), currency="USD")
    previous = CostDataset(currency=None, records=())
    service, _ = a_service(current, previous)

    summary = await service.summary(a_filter())

    assert summary.previous_total == 0.0
    assert summary.change is not None
    assert summary.change.amount == 45.0


async def test_a_negative_previous_total_yields_no_percentage() -> None:
    """A credit-dominated period would flip the sign of any percentage change."""
    current = a_dataset((date(2026, 8, 1), "Fabrikam Widget Service", 50.0))
    previous = a_dataset((date(2026, 7, 20), "Fabrikam Widget Service", -20.0))
    service, _ = a_service(current, previous)

    summary = await service.summary(a_filter())

    assert summary.change is not None
    assert summary.change.amount == 70.0
    assert summary.change.percentage is None


async def test_summary_reports_the_largest_driver_and_no_forecast() -> None:
    current = parse_query_result(cost_fixture("groupedDaily"))
    service, _ = a_service(current, a_dataset())

    summary = await service.summary(a_filter())

    assert summary.top_driver is not None
    assert summary.top_driver.name == "Fabrikam Widget Service"
    assert summary.top_driver.amount == 32.5
    assert summary.forecast is None


async def test_summary_of_an_empty_period_is_zero_valued() -> None:
    service, _ = a_service(CostDataset(currency=None, records=()))

    summary = await service.summary(a_filter())

    assert summary.total == 0.0
    assert summary.previous_total == 0.0
    assert summary.change is not None
    assert summary.change.amount == 0.0
    assert summary.change.percentage is None
    assert summary.top_driver is None
    assert summary.currency is None
    assert summary.data_freshness is None


async def test_summary_carries_an_aware_timestamp_and_freshness() -> None:
    current = parse_query_result(cost_fixture("groupedDaily"))
    service, _ = a_service(current, a_dataset())

    summary = await service.summary(a_filter())

    assert summary.generated_at == NOW
    assert summary.generated_at.tzinfo is not None
    assert summary.data_freshness == date(2026, 8, 2)
    assert summary.currency == "USD"


async def test_a_period_inside_the_current_billing_month_carries_a_rerating_notice() -> None:
    service, _ = a_service(parse_query_result(cost_fixture("groupedDaily")), a_dataset())

    summary = await service.summary(a_filter())

    assert summary.rerating_notice is not None
    assert "rerated" in summary.rerating_notice


async def test_a_closed_period_carries_no_rerating_notice() -> None:
    service, _ = a_service(parse_query_result(cost_fixture("groupedDaily")), a_dataset())

    summary = await service.summary(a_filter(start=date(2026, 7, 1), end=date(2026, 7, 31)))

    assert summary.rerating_notice is None


async def test_trend_sums_each_day_in_order() -> None:
    service, client = a_service(parse_query_result(cost_fixture("groupedDaily")))

    trend = await service.trend(a_filter())

    assert client.calls == [(a_filter(), "Daily")]
    assert [(point.usage_date, point.amount) for point in trend.points] == [
        (date(2026, 8, 1), 20.0),
        (date(2026, 8, 2), 25.0),
    ]


async def test_trend_ignores_rows_without_a_date() -> None:
    service, _ = a_service(
        a_dataset(
            (date(2026, 8, 2), "b", 2.0),
            (None, "a", 5.0),
            (date(2026, 8, 1), "a", 1.0),
        )
    )

    trend = await service.trend(a_filter())

    assert [point.usage_date for point in trend.points] == [date(2026, 8, 1), date(2026, 8, 2)]


async def test_breakdown_ranks_groups_and_reports_shares() -> None:
    service, _ = a_service(parse_query_result(cost_fixture("groupedDaily")))

    breakdown = await service.breakdown(a_filter())

    assert breakdown.grouping is CostGrouping.SERVICE
    assert breakdown.total == 45.0
    assert [(item.name, item.amount, item.percentage) for item in breakdown.items] == [
        ("Fabrikam Widget Service", 32.5, 72.22),
        ("Fabrikam Ledger Service", 12.5, 27.78),
    ]
    assert breakdown.other_amount == 0.0


async def test_breakdown_folds_the_tail_into_other() -> None:
    service, _ = a_service(
        a_dataset(
            (None, "a", 40.0),
            (None, "b", 30.0),
            (None, "c", 20.0),
            (None, "d", 6.0),
            (None, "e", 4.0),
        )
    )

    breakdown = await service.breakdown(a_filter(), limit=3)

    assert [item.name for item in breakdown.items] == ["a", "b", "c"]
    assert breakdown.other_amount == 10.0


async def test_breakdown_parts_add_up_to_the_reported_total() -> None:
    """Rounding must not leave the published items and remainder off the total."""
    service, _ = a_service(
        a_dataset(
            (None, "a", 10.005),
            (None, "b", 10.005),
            (None, "c", 0.333),
            (None, "d", 0.333),
        )
    )

    breakdown = await service.breakdown(a_filter(), limit=2)

    assert sum(item.amount for item in breakdown.items) + breakdown.other_amount == pytest.approx(
        breakdown.total
    )


async def test_breakdown_ties_are_broken_by_name_for_determinism() -> None:
    service, _ = a_service(a_dataset((None, "zeta", 5.0), (None, "alpha", 5.0)))

    breakdown = await service.breakdown(a_filter())

    assert [item.name for item in breakdown.items] == ["alpha", "zeta"]


async def test_breakdown_of_an_empty_period_reports_zero_shares() -> None:
    service, _ = a_service(CostDataset(currency=None, records=()))

    breakdown = await service.breakdown(a_filter())

    assert breakdown.total == 0.0
    assert breakdown.items == []
    assert breakdown.other_amount == 0.0


@pytest.mark.parametrize("limit", [0, -1])
async def test_a_non_positive_breakdown_limit_is_rejected(limit: int) -> None:
    service, _ = a_service(CostDataset(currency=None, records=()))

    with pytest.raises(ValueError, match="limit"):
        await service.breakdown(a_filter(), limit=limit)


async def test_the_service_uses_a_real_clock_by_default() -> None:
    service = CostService(StubCostClient(CostDataset(currency=None, records=())))

    trend = await service.trend(a_filter())

    assert trend.generated_at.tzinfo is UTC
