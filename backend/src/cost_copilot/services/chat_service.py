"""Grounds an AI explanation in cost data that was actually queried.

Two rules hold everywhere in this module. The model is never consulted unless a
real cost query succeeded first, so a failed query can never be papered over by
a plausible-sounding answer. And an answer is published only if every evidence
entry and every command it produced matches the queried data; what is then
published as evidence is the queried row itself, never the model's copy of it.

The answer *prose* is not verified figure by figure: it is bounded, stripped to
plain text, and published alongside evidence a reader can check it against.
"""

import logging
import re
from collections.abc import Mapping, Sequence
from typing import Any, Protocol

from cost_copilot.clients.foundry import FoundryError
from cost_copilot.models.chat import (
    ChartAction,
    ChatCostFilter,
    ChatRequest,
    ChatResponse,
    Evidence,
    ModelAnswer,
)
from cost_copilot.models.cost import CostBreakdown, CostFilter

logger = logging.getLogger(__name__)

EXPLANATION_UNAVAILABLE_ANSWER = (
    "An AI explanation is not available for this question. The cost figures below "
    "come straight from the cost query and are unchanged."
)

MONEY_PRECISION = 2
# Removes only tag-like sequences, so a comparison such as "< 40 USD" survives
# while "<script>" does not. The answer is published as JSON text, never as HTML.
_MARKUP = re.compile(r"</?[A-Za-z][^>]*>")
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


class ChatFiltersRequiredError(ValueError):
    """A question arrived without the dashboard filters that would ground it."""


class CostReporter(Protocol):
    """The slice of the cost service this service depends on."""

    async def breakdown(self, filters: CostFilter) -> CostBreakdown: ...


class FoundryResponder(Protocol):
    """The slice of the Foundry client this service depends on."""

    async def respond(self, *, prompt: str, grounding: Mapping[str, Any]) -> ModelAnswer: ...


def plain_text(value: str) -> str:
    """Reduce model prose to plain text: no markup, no control characters."""
    return _CONTROL.sub("", _MARKUP.sub("", value)).strip()


def normalize_evidence(breakdown: CostBreakdown, filters: ChatCostFilter) -> list[Evidence]:
    """Turn the ranked breakdown into the only figures an answer may cite."""
    return [
        Evidence(
            metric=filters.metric,
            dimension=item.name,
            period_start=filters.start,
            period_end=filters.end,
            amount=item.amount,
        )
        for item in breakdown.items
    ]


def _citation_key(item: Evidence) -> tuple[str, str, str, str, float]:
    # Amounts are compared at the precision they were published with, so a
    # round-tripped 32.5 matches and a fabricated 32.51 does not.
    return (
        item.metric.value,
        item.dimension,
        item.period_start.isoformat(),
        item.period_end.isoformat(),
        round(item.amount, MONEY_PRECISION),
    )


def build_grounding(breakdown: CostBreakdown, evidence: Sequence[Evidence]) -> dict[str, Any]:
    """The complete, and only, context the model is given."""
    return {
        "currency": breakdown.currency,
        "grouping": breakdown.grouping.value,
        "total": breakdown.total,
        "otherAmount": breakdown.other_amount,
        "dataFreshness": None
        if breakdown.data_freshness is None
        else str(breakdown.data_freshness),
        "reratingNotice": breakdown.rerating_notice,
        "evidence": [item.model_dump(mode="json", by_alias=True) for item in evidence],
    }


def _action_is_supported(
    action: ChartAction, filters: ChatCostFilter, dimensions: frozenset[str]
) -> bool:
    """A command may only re-express the current view over data already returned."""
    if action.metric is not None and action.metric is not filters.metric:
        return False
    if action.grouping is not None and action.grouping is not filters.grouping:
        return False
    if action.value is not None and action.value not in dimensions:
        return False
    start = action.start or filters.start
    end = action.end or filters.end
    return filters.start <= start <= end <= filters.end


class ChatService:
    """Answers cost questions from queried figures, or declines to answer at all."""

    def __init__(self, cost: CostReporter, foundry: FoundryResponder) -> None:
        self.cost = cost
        self.foundry = foundry

    async def answer(self, request: ChatRequest) -> ChatResponse:
        filters = _required_filters(request)
        # Deliberately before any model call: a cost failure propagates to the
        # caller as a cost error, and the model is never asked to fill the gap.
        breakdown = await self.cost.breakdown(filters)
        evidence = normalize_evidence(breakdown, filters)

        try:
            proposed = await self.foundry.respond(
                prompt=request.prompt, grounding=build_grounding(breakdown, evidence)
            )
        except FoundryError as error:
            logger.warning("Foundry explanation unavailable (%s)", type(error).__name__)
            return _ungrounded(evidence)

        grounded = _grounded_answer(proposed, evidence, filters)
        return grounded if grounded is not None else _ungrounded(evidence)


def _required_filters(request: ChatRequest) -> ChatCostFilter:
    """Guards the programmatic path; the HTTP boundary already rejects a missing filter."""
    filters = request.filters
    if not isinstance(filters, ChatCostFilter):
        raise ChatFiltersRequiredError("chat requires the active dashboard filters")
    return filters


def _grounded_answer(
    proposed: ModelAnswer, evidence: Sequence[Evidence], filters: ChatCostFilter
) -> ChatResponse | None:
    """Return the answer only if every citation and command in it is backed by `evidence`."""
    answer = plain_text(proposed.answer)
    if not answer:
        logger.warning("Discarding a model answer with no readable text")
        return None
    # An answer that cites nothing is an unsupported claim by definition.
    if not proposed.evidence:
        logger.warning("Discarding a model answer that cites no evidence")
        return None

    queried = {_citation_key(item): item for item in evidence}
    cited = [queried.get(_citation_key(item)) for item in proposed.evidence]
    if any(item is None for item in cited):
        logger.warning("Discarding a model answer that cites figures outside the cost data")
        return None

    dimensions = frozenset(item.dimension for item in evidence)
    if any(
        not _action_is_supported(action, filters, dimensions) for action in proposed.chart_actions
    ):
        logger.warning("Discarding a model answer that proposes an unsupported chart action")
        return None

    return ChatResponse(
        answer=answer,
        # The queried rows are republished, not the model's copies of them: a
        # citation matches at published precision, so an echoed amount could
        # otherwise differ from the queried one by up to that tolerance.
        evidence=[item for item in cited if item is not None],
        chart_actions=list(proposed.chart_actions),
        explanation_available=True,
    )


def _ungrounded(evidence: Sequence[Evidence]) -> ChatResponse:
    """No explanation, but the queried cost figures still reach the caller."""
    return ChatResponse(
        answer=EXPLANATION_UNAVAILABLE_ANSWER,
        evidence=list(evidence),
        chart_actions=[],
        explanation_available=False,
    )
