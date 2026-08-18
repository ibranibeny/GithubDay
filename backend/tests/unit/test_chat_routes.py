"""Route wiring for the chat API, with auth and both upstreams stubbed out."""

from collections.abc import Iterator, Mapping
from datetime import UTC, date, datetime
from typing import Any

import pytest
import respx
from fastapi import FastAPI
from fastapi.testclient import TestClient

from cost_copilot.auth import COST_READER_ROLE, verify_token
from cost_copilot.clients.cost_management import (
    CostAccessDeniedError,
    CostDataset,
    CostRecord,
    CostThrottledError,
)
from cost_copilot.clients.foundry import FoundryChatClient, FoundryTimeoutError
from cost_copilot.main import create_app
from cost_copilot.models.chat import ChartAction, ChartActionKind, Evidence, ModelAnswer
from cost_copilot.models.cost import BreakdownItem, CostBreakdown, CostGrouping, CostMetric
from cost_copilot.routers import chat, costs
from cost_copilot.routers.chat import (
    CHAT_UNAVAILABLE_DETAIL,
    FILTERS_REQUIRED_DETAIL,
    get_chat_service,
)
from cost_copilot.routers.costs import UPSTREAM_THROTTLED_DETAIL, UPSTREAM_UNAVAILABLE_DETAIL
from cost_copilot.services.chat_service import (
    EXPLANATION_UNAVAILABLE_ANSWER,
    ChatFiltersRequiredError,
    ChatService,
)

CLAIMS = {"oid": "00000000-0000-0000-0000-000000000002", "roles": [COST_READER_ROLE]}
NOW = datetime(2026, 8, 18, 9, 30, tzinfo=UTC)
START = date(2026, 8, 1)
END = date(2026, 8, 17)
WIDGET = "Fabrikam Widget Service"
BODY: dict[str, Any] = {
    "prompt": "Why did spend rise?",
    "filters": {"start": "2026-08-01", "end": "2026-08-17"},
}

BREAKDOWN = CostBreakdown(
    generated_at=NOW,
    data_freshness=END,
    currency="USD",
    rerating_notice=None,
    grouping=CostGrouping.SERVICE,
    total=32.5,
    items=[BreakdownItem(name=WIDGET, amount=32.5, percentage=100.0)],
    other_amount=0.0,
)

ANSWER = ModelAnswer(
    answer=f"{WIDGET} drives the spend.",
    evidence=[
        Evidence(
            metric=CostMetric.ACTUAL,
            dimension=WIDGET,
            period_start=START,
            period_end=END,
            amount=32.5,
        )
    ],
    chart_actions=[ChartAction(kind=ChartActionKind.HIGHLIGHT_SERIES, value=WIDGET)],
)

LEAK_PROBE = "principal 9f3c at contoso-internal.example"


class StubCostReporter:
    def __init__(self, error: Exception | None = None) -> None:
        self._error = error
        self.calls: list[Any] = []

    async def breakdown(self, filters: Any) -> CostBreakdown:
        self.calls.append(filters)
        if self._error is not None:
            raise self._error
        return BREAKDOWN


class StubFoundry:
    def __init__(self, result: ModelAnswer | Exception = ANSWER) -> None:
        self._result = result
        self.awaited = 0

    async def respond(self, *, prompt: str, grounding: Mapping[str, Any]) -> ModelAnswer:
        self.awaited += 1
        if isinstance(self._result, Exception):
            raise self._result
        return self._result

    async def aclose(self) -> None:
        """Stands in for the Foundry client the lifespan would otherwise build."""


class _StubCostQueryClient:
    """Stands in for the Cost Management client so startup touches no network."""

    async def run_query(self, filters: Any, granularity: str) -> CostDataset:
        return CostDataset(
            currency="USD", records=(CostRecord(usage_date=END, dimension=WIDGET, amount=32.5),)
        )

    async def aclose(self) -> None: ...


def build_client(
    *,
    authorized: bool = True,
    cost: StubCostReporter | None = None,
    foundry: StubFoundry | None = None,
) -> tuple[TestClient, StubCostReporter, StubFoundry]:
    cost_reporter = cost or StubCostReporter()
    responder = foundry or StubFoundry()
    app = create_app()
    app.dependency_overrides[verify_token] = lambda: (
        CLAIMS if authorized else {"oid": CLAIMS["oid"], "roles": []}
    )
    app.dependency_overrides[get_chat_service] = lambda: ChatService(cost_reporter, responder)
    return TestClient(app), cost_reporter, responder


@pytest.fixture(autouse=True)
def _forbid_network() -> Iterator[None]:
    with respx.mock(assert_all_called=False):
        yield


def test_a_caller_without_the_cost_read_role_is_refused() -> None:
    client, cost, foundry = build_client(authorized=False)

    response = client.post("/api/chat", json=BODY)

    assert response.status_code == 403
    assert cost.calls == []
    assert foundry.awaited == 0


def test_an_anonymous_caller_is_refused() -> None:
    app: FastAPI = create_app()
    app.dependency_overrides[get_chat_service] = lambda: ChatService(
        StubCostReporter(), StubFoundry()
    )

    response = TestClient(app).post("/api/chat", json=BODY)

    assert response.status_code == 401


def test_a_grounded_answer_is_returned_in_camel_case() -> None:
    client, _, _ = build_client()

    response = client.post("/api/chat", json=BODY)

    assert response.status_code == 200
    body = response.json()
    assert body["explanationAvailable"] is True
    assert body["answer"].startswith(WIDGET)
    assert body["evidence"][0]["periodStart"] == "2026-08-01"
    assert body["chartActions"] == [
        {
            "kind": "highlight-series",
            "metric": None,
            "grouping": None,
            "value": WIDGET,
            "start": None,
            "end": None,
        }
    ]


def test_a_model_timeout_still_returns_the_cost_evidence() -> None:
    client, _, _ = build_client(foundry=StubFoundry(FoundryTimeoutError("too slow")))

    response = client.post("/api/chat", json=BODY)

    assert response.status_code == 200
    body = response.json()
    assert body["explanationAvailable"] is False
    assert body["answer"] == EXPLANATION_UNAVAILABLE_ANSWER
    assert body["evidence"][0]["amount"] == 32.5


@pytest.mark.parametrize(
    ("error", "status", "detail"),
    [
        (CostAccessDeniedError(LEAK_PROBE), 502, UPSTREAM_UNAVAILABLE_DETAIL),
        (CostThrottledError(LEAK_PROBE), 429, UPSTREAM_THROTTLED_DETAIL),
    ],
)
def test_a_cost_failure_maps_to_a_safe_status_and_skips_the_model(
    error: Exception, status: int, detail: str
) -> None:
    client, _, foundry = build_client(cost=StubCostReporter(error=error))

    response = client.post("/api/chat", json=BODY)

    assert response.status_code == status
    assert response.json() == {"detail": detail}
    assert "contoso-internal" not in response.text
    assert foundry.awaited == 0


@pytest.mark.parametrize(
    "body",
    [
        pytest.param({"prompt": "", "filters": BODY["filters"]}, id="empty-prompt"),
        pytest.param({"prompt": "   ", "filters": BODY["filters"]}, id="blank-prompt"),
        pytest.param({"prompt": "x" * 4001, "filters": BODY["filters"]}, id="oversized-prompt"),
        pytest.param({"prompt": "why?"}, id="missing-filters"),
        pytest.param({"prompt": "why?", "filters": {}}, id="empty-filters"),
        pytest.param(
            {"prompt": "why?", "filters": {"start": "2026-08-17", "end": "2026-08-01"}},
            id="inverted-window",
        ),
        pytest.param({"filters": BODY["filters"]}, id="missing-prompt"),
    ],
)
def test_an_unusable_request_is_refused_before_any_upstream_call(body: dict[str, Any]) -> None:
    client, cost, foundry = build_client()

    response = client.post("/api/chat", json=body)

    assert response.status_code == 422
    assert cost.calls == []
    assert foundry.awaited == 0


def test_a_tag_filter_is_accepted_in_camel_case() -> None:
    client, cost, _ = build_client()

    response = client.post(
        "/api/chat",
        json={
            "prompt": "why?",
            "filters": {**BODY["filters"], "grouping": "Tag", "tagKey": "cost-center"},
        },
    )

    assert response.status_code == 200
    assert cost.calls[0].tag_key == "cost-center"


def test_the_chat_service_is_reported_unavailable_before_startup() -> None:
    app = create_app()
    app.dependency_overrides[verify_token] = lambda: CLAIMS

    response = TestClient(app, raise_server_exceptions=False).post("/api/chat", json=BODY)

    assert response.status_code == 503
    assert response.json() == {"detail": CHAT_UNAVAILABLE_DETAIL}


def test_a_request_the_service_cannot_ground_is_refused() -> None:
    """The service's own filter guard maps to a 422, not to a leaked 500."""

    class _Refusing:
        async def answer(self, request: Any) -> Any:
            raise ChatFiltersRequiredError("chat requires the active dashboard filters")

    app = create_app()
    app.dependency_overrides[verify_token] = lambda: CLAIMS
    app.dependency_overrides[get_chat_service] = _Refusing

    response = TestClient(app).post("/api/chat", json=BODY)

    assert response.status_code == 422
    assert response.json() == {"detail": FILTERS_REQUIRED_DETAIL}


def test_the_lifespan_wires_a_working_chat_service(monkeypatch: pytest.MonkeyPatch) -> None:
    """Exercises the real dependency, not an override, over stubbed upstreams."""
    monkeypatch.setattr(costs, "DefaultAzureCredential", _RecordingCredential)
    monkeypatch.setattr(
        costs, "build_cost_client", lambda settings, *, acquire_token: _StubCostQueryClient()
    )
    monkeypatch.setattr(
        chat, "build_foundry_client", lambda settings, *, acquire_token: StubFoundry()
    )
    app = create_app()
    app.dependency_overrides[verify_token] = lambda: CLAIMS

    with TestClient(app) as client:
        response = client.post("/api/chat", json=BODY)

    assert response.status_code == 200
    assert response.json()["explanationAvailable"] is True


class _RecordingCredential:
    def __init__(self) -> None:
        self.close_calls = 0

    def get_token(self, *scopes: str) -> object:  # pragma: no cover - no request is issued
        raise AssertionError("the shutdown test must not acquire a token")

    def close(self) -> None:
        self.close_calls += 1


def test_the_chat_client_shares_the_cost_credential_and_closes_on_shutdown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    credential = _RecordingCredential()
    monkeypatch.setattr(costs, "DefaultAzureCredential", lambda: credential)
    app = create_app()

    with TestClient(app):
        service = app.state.chat_service
        assert isinstance(service, ChatService)
        foundry_client = service.foundry
        assert isinstance(foundry_client, FoundryChatClient)
        assert not foundry_client.is_closed

    assert foundry_client.is_closed
    # Both providers read the one credential, so it is closed exactly once.
    assert credential.close_calls == 1


def test_a_failing_chat_client_shutdown_still_closes_the_credential(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    credential = _RecordingCredential()

    class _FailingFoundry:
        async def respond(
            self, *, prompt: str, grounding: Mapping[str, Any]
        ) -> ModelAnswer:  # pragma: no cover - never called
            raise AssertionError("the shutdown test must not query")

        async def aclose(self) -> None:
            raise RuntimeError("foundry shutdown failed")

    monkeypatch.setattr(costs, "DefaultAzureCredential", lambda: credential)
    monkeypatch.setattr(
        chat, "build_foundry_client", lambda settings, *, acquire_token: _FailingFoundry()
    )
    app = create_app()

    with pytest.raises(RuntimeError, match="foundry shutdown failed"), TestClient(app):
        pass

    assert credential.close_calls == 1
