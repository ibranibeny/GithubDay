"""Turns Cost Management rows into the summary, trend, and breakdown payloads.

Every endpoint issues the same Daily grouped query: one shape yields the totals,
the per-day series, the per-group ranking, and the latest day that carries data.
"""

from collections import defaultdict
from collections.abc import Callable
from datetime import UTC, date, datetime
from typing import Any, Protocol

from cost_copilot.clients.cost_management import CostDataset
from cost_copilot.models.cost import (
    RERATING_NOTICE,
    BreakdownItem,
    CostBreakdown,
    CostChange,
    CostFilter,
    CostSummary,
    CostTrend,
    TopDriver,
    TrendPoint,
)

DAILY_GRANULARITY = "Daily"
DEFAULT_BREAKDOWN_LIMIT = 10
MONEY_PRECISION = 2


class CostQueryRunner(Protocol):
    """The slice of the Cost Management client this service depends on."""

    async def run_query(self, filters: CostFilter, granularity: str) -> CostDataset: ...


def _utc_now() -> datetime:
    return datetime.now(UTC)


def _money(value: float) -> float:
    return round(value, MONEY_PRECISION)


def _total(dataset: CostDataset) -> float:
    return sum(record.amount for record in dataset.records)


def _by_dimension(dataset: CostDataset) -> dict[str, float]:
    totals: defaultdict[str, float] = defaultdict(float)
    for record in dataset.records:
        totals[record.dimension] += record.amount
    return dict(totals)


def _by_date(dataset: CostDataset) -> dict[date, float]:
    totals: defaultdict[date, float] = defaultdict(float)
    for record in dataset.records:
        if record.usage_date is not None:
            totals[record.usage_date] += record.amount
    return dict(totals)


def _latest_date(dataset: CostDataset) -> date | None:
    dates = [record.usage_date for record in dataset.records if record.usage_date is not None]
    return max(dates) if dates else None


class CostService:
    """Deterministic aggregation over an injected query runner."""

    def __init__(self, client: CostQueryRunner, *, now: Callable[[], datetime] = _utc_now) -> None:
        self.client = client
        self._now = now

    def _context(self, dataset: CostDataset, filters: CostFilter) -> dict[str, Any]:
        generated_at = self._now()
        billing_period_start = generated_at.date().replace(day=1)
        return {
            "generated_at": generated_at,
            "data_freshness": _latest_date(dataset),
            "currency": dataset.currency,
            # Charges in the open billing period are still subject to rerating.
            "rerating_notice": (RERATING_NOTICE if filters.end >= billing_period_start else None),
        }

    async def summary(self, filters: CostFilter) -> CostSummary:
        current = await self.client.run_query(filters, DAILY_GRANULARITY)
        previous = await self.client.run_query(filters.preceding_period(), DAILY_GRANULARITY)

        total = _total(current)
        previous_total = _total(previous)
        drivers = _by_dimension(current)
        # Same ordering rule as the breakdown: largest first, ties settled by name.
        top_driver = min(drivers.items(), key=lambda item: (-item[1], item[0])) if drivers else None

        return CostSummary(
            **self._context(current, filters),
            total=_money(total),
            previous_total=_money(previous_total),
            change=CostChange(
                amount=_money(total - previous_total),
                percentage=(
                    _money((total - previous_total) / previous_total * 100)
                    if previous_total
                    else None
                ),
            ),
            # The Forecast API is a separate operation and is not part of this task,
            # so no projection is invented here.
            forecast=None,
            top_driver=(
                None
                if top_driver is None
                else TopDriver(name=top_driver[0], amount=_money(top_driver[1]))
            ),
        )

    async def trend(self, filters: CostFilter) -> CostTrend:
        dataset = await self.client.run_query(filters, DAILY_GRANULARITY)
        return CostTrend(
            **self._context(dataset, filters),
            points=[
                TrendPoint(usage_date=day, amount=_money(amount))
                for day, amount in sorted(_by_date(dataset).items())
            ],
        )

    async def breakdown(
        self, filters: CostFilter, *, limit: int = DEFAULT_BREAKDOWN_LIMIT
    ) -> CostBreakdown:
        if limit < 1:
            raise ValueError("limit must be at least 1")

        dataset = await self.client.run_query(filters, DAILY_GRANULARITY)
        total = _total(dataset)
        # Descending by amount, then by name so equal amounts keep a stable order.
        ranked = sorted(_by_dimension(dataset).items(), key=lambda item: (-item[1], item[0]))
        top = ranked[:limit]

        return CostBreakdown(
            **self._context(dataset, filters),
            grouping=filters.grouping,
            total=_money(total),
            items=[
                BreakdownItem(
                    name=name,
                    amount=_money(amount),
                    percentage=_money(amount / total * 100) if total else 0.0,
                )
                for name, amount in top
            ],
            other_amount=_money(total - sum(amount for _, amount in top)),
        )
