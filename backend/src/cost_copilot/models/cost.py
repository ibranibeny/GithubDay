"""Bounded cost query inputs and the typed shapes the cost API returns."""

from datetime import date, datetime, timedelta
from enum import StrEnum
from typing import Self

from pydantic import BaseModel, ConfigDict, Field, model_validator
from pydantic.alias_generators import to_camel

MAX_RANGE_DAYS = 366
MAX_TAG_KEY_LENGTH = 128

RERATING_NOTICE = (
    "Costs in the current billing period are preliminary and can be rerated until "
    "the invoice is final."
)


class CostMetric(StrEnum):
    """Subset of the Cost Management `ExportType` enum this API exposes."""

    ACTUAL = "ActualCost"
    AMORTIZED = "AmortizedCost"


class CostGrouping(StrEnum):
    """Allow-list of groupings; `TAG` is resolved through `CostFilter.tag_key`."""

    SERVICE = "ServiceName"
    RESOURCE_GROUP = "ResourceGroupName"
    RESOURCE = "ResourceId"
    TAG = "Tag"


class CostFilter(BaseModel):
    """Validated query window. Never carries a scope: that comes from settings."""

    model_config = ConfigDict(frozen=True)

    start: date
    end: date
    metric: CostMetric = CostMetric.ACTUAL
    grouping: CostGrouping = CostGrouping.SERVICE
    tag_key: str | None = Field(default=None, max_length=MAX_TAG_KEY_LENGTH)

    @model_validator(mode="after")
    def _validate_range_and_grouping(self) -> Self:
        if self.end < self.start:
            raise ValueError("end must be on or after start")
        if (self.end - self.start).days > MAX_RANGE_DAYS:
            raise ValueError(f"date range cannot exceed {MAX_RANGE_DAYS} days")
        if self.tag_key is not None and not self.tag_key.isprintable():
            raise ValueError("tag_key must contain printable characters only")
        if self.grouping is CostGrouping.TAG and not (self.tag_key or "").strip():
            raise ValueError("tag_key is required for tag grouping")
        return self

    @property
    def azure_dimension(self) -> str:
        """Dimension or tag key to group by, as the query body expects it."""
        if self.grouping is CostGrouping.TAG and self.tag_key is not None:
            return self.tag_key
        return self.grouping.value

    @property
    def day_count(self) -> int:
        return (self.end - self.start).days + 1

    def preceding_period(self) -> "CostFilter":
        """Equal-length window ending the day before this one starts."""
        end = self.start - timedelta(days=1)
        return self.model_copy(update={"start": end - (self.end - self.start), "end": end})


class CostApiModel(BaseModel):
    """Base for response payloads; the browser client consumes camelCase."""

    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)


class CostContext(CostApiModel):
    """Provenance every cost response carries so a figure is never context-free."""

    generated_at: datetime
    data_freshness: date | None = None
    currency: str | None = None
    rerating_notice: str | None = None


class CostChange(CostApiModel):
    amount: float
    percentage: float | None = None


class TopDriver(CostApiModel):
    name: str
    amount: float


class CostSummary(CostContext):
    total: float
    previous_total: float
    change: CostChange
    forecast: float | None = None
    top_driver: TopDriver | None = None


class TrendPoint(CostApiModel):
    usage_date: date
    amount: float


class CostTrend(CostContext):
    points: list[TrendPoint]


class BreakdownItem(CostApiModel):
    name: str
    amount: float
    percentage: float


class CostBreakdown(CostContext):
    grouping: CostGrouping
    total: float
    items: list[BreakdownItem]
    other_amount: float
