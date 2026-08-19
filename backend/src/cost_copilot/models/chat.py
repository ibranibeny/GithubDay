"""Typed request, model-output, and response shapes for the chat endpoint.

Every model here is deliberately closed: the answer the language model produces
is untrusted input, so a field it did not have to fill, or an extra field it
invented, is a reason to discard the answer rather than to guess at intent.
"""

from datetime import date
from enum import StrEnum
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, StringConstraints
from pydantic.alias_generators import to_camel

from cost_copilot.models.cost import CostFilter, CostGrouping, CostMetric

MAX_PROMPT_LENGTH = 4000
MAX_ANSWER_LENGTH = 4000
MAX_DIMENSION_LENGTH = 512
MAX_MODEL_EVIDENCE_ITEMS = 20
MAX_CHART_ACTIONS = 5

# Whitespace is stripped before the length check so a blank prompt is a 422 and
# never an empty question forwarded to the model.
PromptText = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=MAX_PROMPT_LENGTH)
]
DimensionText = Annotated[str, StringConstraints(min_length=1, max_length=MAX_DIMENSION_LENGTH)]


class ChatApiModel(BaseModel):
    """Base for chat payloads; the browser client speaks camelCase."""

    model_config = ConfigDict(
        alias_generator=to_camel, populate_by_name=True, extra="forbid", frozen=True
    )


class ChatCostFilter(CostFilter):
    """The Task 3 cost filter, accepted in the camelCase form the API uses."""

    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True, extra="forbid")


class Evidence(ChatApiModel):
    """One citable figure. Every field must match the queried cost data exactly."""

    metric: CostMetric
    dimension: DimensionText
    period_start: date
    period_end: date
    amount: float


class ChartActionKind(StrEnum):
    SET_FILTER = "set-filter"
    HIGHLIGHT_SERIES = "highlight-series"


class ChartAction(ChatApiModel):
    """A bounded command the dashboard may apply; never free-form instructions."""

    kind: ChartActionKind
    metric: CostMetric | None = None
    grouping: CostGrouping | None = None
    value: DimensionText | None = None
    start: date | None = None
    end: date | None = None


class ModelAnswer(ChatApiModel):
    """The model's raw structured output, shape-checked but not yet grounded."""

    answer: Annotated[str, StringConstraints(max_length=MAX_ANSWER_LENGTH)]
    evidence: list[Evidence] = Field(max_length=MAX_MODEL_EVIDENCE_ITEMS)
    chart_actions: list[ChartAction] = Field(max_length=MAX_CHART_ACTIONS)


class ChatRequest(ChatApiModel):
    """Filters are required: an unscoped question has no cost data to ground it."""

    prompt: PromptText
    filters: ChatCostFilter


class ChatResponse(ChatApiModel):
    """The cost evidence always survives, whether or not the explanation does."""

    answer: str
    evidence: list[Evidence]
    chart_actions: list[ChartAction]
    explanation_available: bool
