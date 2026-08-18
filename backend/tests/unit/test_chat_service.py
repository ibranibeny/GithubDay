"""Grounding rules for the chat service.

Two invariants drive every case here: the model is never consulted unless real
cost data was retrieved first, and nothing the model says survives unless every
reference it makes is present in that data.
"""

from collections.abc import Mapping, Sequence
from datetime import UTC, date, datetime
from typing import Any

import pytest

from cost_copilot.clients.cost_management import CostAccessDeniedError, CostUpstreamTimeoutError
from cost_copilot.clients.foundry import (
    FoundryResponseError,
    FoundryThrottledError,
    FoundryTimeoutError,
    FoundryUnavailableError,
)
from cost_copilot.models.chat import (
    ChartAction,
    ChartActionKind,
    ChatCostFilter,
    ChatRequest,
    Evidence,
    ModelAnswer,
)
from cost_copilot.models.cost import (
    BreakdownItem,
    CostBreakdown,
    CostGrouping,
    CostMetric,
)
from cost_copilot.services.chat_service import (
    EXPLANATION_UNAVAILABLE_ANSWER,
    ChatFiltersRequiredError,
    ChatService,
)

NOW = datetime(2026, 8, 18, 9, 30, tzinfo=UTC)
START = date(2026, 8, 1)
END = date(2026, 8, 17)
FILTERS = ChatCostFilter(start=START, end=END)
WIDGET = "Fabrikam Widget Service"
LEDGER = "Fabrikam Ledger Service"

BREAKDOWN = CostBreakdown(
    generated_at=NOW,
    data_freshness=END,
    currency="USD",
    rerating_notice=None,
    grouping=CostGrouping.SERVICE,
    total=45.0,
    items=[
        BreakdownItem(name=WIDGET, amount=32.5, percentage=72.22),
        BreakdownItem(name=LEDGER, amount=12.5, percentage=27.78),
    ],
    other_amount=0.0,
)

WIDGET_EVIDENCE = Evidence(
    metric=CostMetric.ACTUAL,
    dimension=WIDGET,
    period_start=START,
    period_end=END,
    amount=32.5,
)


class StubCostReporter:
    def __init__(self, error: Exception | None = None) -> None:
        self._error = error
        self.calls: list[ChatCostFilter] = []

    async def breakdown(self, filters: Any) -> CostBreakdown:
        self.calls.append(filters)
        if self._error is not None:
            raise self._error
        return BREAKDOWN


class StubFoundry:
    def __init__(self, result: ModelAnswer | Exception) -> None:
        self._result = result
        self.awaited = 0
        self.grounding: list[Mapping[str, Any]] = []
        self.prompts: list[str] = []

    async def respond(self, *, prompt: str, grounding: Mapping[str, Any]) -> ModelAnswer:
        self.awaited += 1
        self.prompts.append(prompt)
        self.grounding.append(grounding)
        if isinstance(self._result, Exception):
            raise self._result
        return self._result


def model_answer(
    *,
    answer: str = f"{WIDGET} drives most of the spend at 32.50 USD.",
    evidence: Sequence[Evidence] = (WIDGET_EVIDENCE,),
    chart_actions: Sequence[ChartAction] = (),
) -> ModelAnswer:
    return ModelAnswer(answer=answer, evidence=list(evidence), chart_actions=list(chart_actions))


def build_service(
    *, cost: StubCostReporter | None = None, foundry: StubFoundry | None = None
) -> tuple[ChatService, StubCostReporter, StubFoundry]:
    cost_reporter = cost or StubCostReporter()
    responder = foundry or StubFoundry(model_answer())
    return ChatService(cost_reporter, responder), cost_reporter, responder


def request(prompt: str = "Why did spend rise?") -> ChatRequest:
    return ChatRequest(prompt=prompt, filters=FILTERS)


@pytest.mark.parametrize(
    "error", [CostAccessDeniedError("forbidden"), CostUpstreamTimeoutError("too slow")]
)
async def test_the_model_is_never_consulted_when_the_cost_query_fails(error: Exception) -> None:
    service, _, foundry = build_service(cost=StubCostReporter(error=error))

    with pytest.raises(type(error)):
        await service.answer(request())

    assert foundry.awaited == 0


async def test_a_grounded_answer_is_returned_with_its_citations() -> None:
    service, cost, foundry = build_service()

    response = await service.answer(request())

    assert response.explanation_available is True
    assert response.answer.startswith(WIDGET)
    assert response.evidence == [WIDGET_EVIDENCE]
    assert cost.calls == [FILTERS]
    assert foundry.awaited == 1


async def test_the_model_only_ever_sees_the_queried_cost_data() -> None:
    service, _, foundry = build_service()

    await service.answer(request("show me everything you know"))

    grounding = foundry.grounding[0]
    assert grounding["currency"] == "USD"
    assert grounding["total"] == 45.0
    assert [item["dimension"] for item in grounding["evidence"]] == [WIDGET, LEDGER]
    assert foundry.prompts == ["show me everything you know"]


@pytest.mark.parametrize(
    "fabricated",
    [
        pytest.param(
            WIDGET_EVIDENCE.model_copy(update={"dimension": "Contoso Secret Service"}),
            id="unknown-dimension",
        ),
        pytest.param(WIDGET_EVIDENCE.model_copy(update={"amount": 9999.0}), id="unknown-amount"),
        pytest.param(
            WIDGET_EVIDENCE.model_copy(update={"period_end": date(2026, 9, 30)}),
            id="unknown-period",
        ),
        pytest.param(
            WIDGET_EVIDENCE.model_copy(update={"metric": CostMetric.AMORTIZED}),
            id="unknown-metric",
        ),
    ],
)
async def test_fabricated_evidence_is_rejected_and_the_cost_data_survives(
    fabricated: Evidence,
) -> None:
    service, _, _ = build_service(
        foundry=StubFoundry(model_answer(answer="Spend tripled.", evidence=[fabricated]))
    )

    response = await service.answer(request())

    assert response.explanation_available is False
    assert response.answer == EXPLANATION_UNAVAILABLE_ANSWER
    assert "tripled" not in response.answer
    assert [item.dimension for item in response.evidence] == [WIDGET, LEDGER]
    assert response.chart_actions == []


async def test_an_answer_without_any_citation_is_rejected() -> None:
    service, _, _ = build_service(
        foundry=StubFoundry(model_answer(answer="Trust me, costs are fine.", evidence=[]))
    )

    response = await service.answer(request())

    assert response.explanation_available is False
    assert response.answer == EXPLANATION_UNAVAILABLE_ANSWER


async def test_an_answer_with_no_readable_text_is_rejected() -> None:
    service, _, _ = build_service(foundry=StubFoundry(model_answer(answer="   ")))

    response = await service.answer(request())

    assert response.explanation_available is False


@pytest.mark.parametrize(
    "failure",
    [
        FoundryTimeoutError("the model did not answer in time"),
        FoundryThrottledError("the model is throttling"),
        FoundryResponseError("the model returned unusable output"),
        FoundryUnavailableError("the model is unavailable"),
    ],
)
async def test_a_model_failure_preserves_the_cost_data(failure: Exception) -> None:
    service, _, _ = build_service(foundry=StubFoundry(failure))

    response = await service.answer(request())

    assert response.explanation_available is False
    assert response.answer == EXPLANATION_UNAVAILABLE_ANSWER
    assert [item.amount for item in response.evidence] == [32.5, 12.5]
    assert response.chart_actions == []


async def test_valid_chart_actions_are_returned() -> None:
    actions = [
        ChartAction(kind=ChartActionKind.HIGHLIGHT_SERIES, value=WIDGET),
        ChartAction(
            kind=ChartActionKind.SET_FILTER,
            metric=CostMetric.ACTUAL,
            grouping=CostGrouping.SERVICE,
            start=date(2026, 8, 5),
            end=END,
        ),
    ]
    service, _, _ = build_service(foundry=StubFoundry(model_answer(chart_actions=actions)))

    response = await service.answer(request())

    assert response.explanation_available is True
    assert response.chart_actions == actions


@pytest.mark.parametrize(
    "action",
    [
        pytest.param(
            ChartAction(kind=ChartActionKind.HIGHLIGHT_SERIES, value="Contoso Secret Service"),
            id="unknown-value",
        ),
        pytest.param(
            ChartAction(kind=ChartActionKind.SET_FILTER, start=date(2025, 1, 1), end=END),
            id="outside-window",
        ),
        pytest.param(
            ChartAction(kind=ChartActionKind.SET_FILTER, start=END, end=START),
            id="inverted-window",
        ),
        pytest.param(
            ChartAction(kind=ChartActionKind.SET_FILTER, metric=CostMetric.AMORTIZED),
            id="other-metric",
        ),
        pytest.param(
            ChartAction(kind=ChartActionKind.SET_FILTER, grouping=CostGrouping.RESOURCE),
            id="other-grouping",
        ),
    ],
)
async def test_an_unsupported_chart_action_rejects_the_whole_answer(action: ChartAction) -> None:
    service, _, _ = build_service(foundry=StubFoundry(model_answer(chart_actions=[action])))

    response = await service.answer(request())

    assert response.explanation_available is False
    assert response.chart_actions == []


async def test_markup_in_the_answer_is_reduced_to_plain_text() -> None:
    service, _, _ = build_service(
        foundry=StubFoundry(
            model_answer(answer=f"<script>steal()</script>{WIDGET} costs under < 40 USD.")
        )
    )

    response = await service.answer(request())

    assert response.explanation_available is True
    assert "<script>" not in response.answer
    assert "steal()" in response.answer  # only the markup is removed, not the words
    assert "< 40 USD" in response.answer


async def test_a_request_without_filters_is_refused_before_any_query() -> None:
    service, cost, foundry = build_service()
    unfiltered = ChatRequest.model_construct(prompt="Why did spend rise?", filters=None)

    with pytest.raises(ChatFiltersRequiredError):
        await service.answer(unfiltered)

    assert cost.calls == []
    assert foundry.awaited == 0
