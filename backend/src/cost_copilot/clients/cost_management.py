"""Client for the Cost Management `Query - Usage` API.

Contract this module is written against (api-version 2026-06-01):
`POST {scope}/providers/Microsoft.CostManagement/query` returns
`properties.columns` (name/type pairs) plus `properties.rows`, where each row is
a positional array aligned to those columns. Column names vary by offer, so every
value here is located by column name and never by a fixed index.
"""

import asyncio
import logging
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import date
from typing import Any, Protocol
from uuid import UUID

import httpx
from anyio import to_thread

from cost_copilot.config import Settings
from cost_copilot.models.cost import CostFilter, CostGrouping

logger = logging.getLogger(__name__)

API_VERSION = "2026-06-01"
MANAGEMENT_HOST = "management.azure.com"
MANAGEMENT_SCOPE = "https://management.azure.com/.default"
NEXT_LINK_PREFIX = f"https://{MANAGEMENT_HOST}/"

COST_AGGREGATION_ALIAS = "totalCost"
REQUESTED_COST_COLUMN = "Cost"
UNASSIGNED_DIMENSION = "Unassigned"

REQUEST_TIMEOUT_SECONDS = 30.0
MAX_RETRIES = 3
MAX_PAGES = 50
BASE_RETRY_DELAY_SECONDS = 1.0
MAX_RETRY_DELAY_SECONDS = 30.0
RETRYABLE_STATUS_CODES = frozenset({429, 502, 503, 504})
# 429 answers carry a Consumption-specific header; 503 answers use the standard one.
RETRY_AFTER_HEADERS = ("x-ms-ratelimit-microsoft.consumption-retry-after", "retry-after")

DATE_COLUMN_NAMES = frozenset({"usagedate", "billingmonth"})
CURRENCY_COLUMN_NAMES = frozenset({"currency", "billingcurrency", "billingcurrencycode"})
NUMBER_COLUMN_TYPE = "number"
STRING_COLUMN_TYPE = "string"


class CostQueryError(Exception):
    """Base for Cost Management failures. Messages never quote an ARM response."""


class CostAccessDeniedError(CostQueryError):
    """The API's own identity was rejected by ARM (401/403)."""


class CostThrottledError(CostQueryError):
    """ARM kept throttling the query after the retry budget was spent."""


class CostUpstreamTimeoutError(CostQueryError):
    """Cost Management did not answer within the request timeout."""


class CostUpstreamError(CostQueryError):
    """Cost Management could not be reached or returned an unusable status."""


class CostResponseError(CostQueryError):
    """Cost Management answered with a body this client cannot trust."""


@dataclass(frozen=True, slots=True)
class CostRecord:
    """One parsed row: an optional day, the grouped value, and its amount."""

    usage_date: date | None
    dimension: str
    amount: float


@dataclass(frozen=True, slots=True)
class CostDataset:
    currency: str | None
    records: tuple[CostRecord, ...]


def build_query(filters: CostFilter, granularity: str) -> dict[str, Any]:
    """Build the query body. Values travel in JSON, never in the URL."""
    grouping_type = "TagKey" if filters.grouping is CostGrouping.TAG else "Dimension"
    return {
        "type": filters.metric.value,
        "timeframe": "Custom",
        "timePeriod": {"from": filters.start.isoformat(), "to": filters.end.isoformat()},
        "dataset": {
            "granularity": granularity,
            "aggregation": {
                COST_AGGREGATION_ALIAS: {"name": REQUESTED_COST_COLUMN, "function": "Sum"}
            },
            "grouping": [{"type": grouping_type, "name": filters.azure_dimension}],
        },
    }


def query_url(subscription_id: UUID) -> str:
    """The only URL this client posts to; the scope comes from settings alone."""
    return (
        f"https://{MANAGEMENT_HOST}/subscriptions/{subscription_id}"
        f"/providers/Microsoft.CostManagement/query?api-version={API_VERSION}"
    )


def _require_mapping(payload: Mapping[str, Any]) -> Mapping[str, Any] | None:
    properties = payload.get("properties")
    if properties is None and "properties" not in payload:
        return None  # a 204 answer, normalized to an empty payload upstream
    if not isinstance(properties, Mapping):
        raise CostResponseError("Cost Management response has no usable properties object")
    return properties


def _page_parts(
    payload: Mapping[str, Any],
) -> tuple[list[Mapping[str, Any]], list[Sequence[Any]], str | None]:
    """Split one response page into columns, rows, and the paging link."""
    properties = _require_mapping(payload)
    if properties is None:
        return [], [], None

    columns = properties.get("columns", [])
    if not isinstance(columns, list):
        raise CostResponseError("Cost Management response columns are not a list")
    rows = properties.get("rows", [])
    if not isinstance(rows, list):
        raise CostResponseError("Cost Management response rows are not a list")

    next_link = properties.get("nextLink")
    if next_link is not None and not isinstance(next_link, str):
        raise CostResponseError("Cost Management returned an unexpected paging link")
    return list(columns), list(rows), next_link


def _column_names(columns: Sequence[Mapping[str, Any]]) -> list[str]:
    return [str(column.get("name", "")) for column in columns]


def _column_types(columns: Sequence[Mapping[str, Any]]) -> list[str]:
    return [str(column.get("type", "")).casefold() for column in columns]


def _index_of_named(names: Sequence[str], candidates: frozenset[str]) -> int | None:
    for index, name in enumerate(names):
        if name.casefold() in candidates:
            return index
    return None


def _cost_index(names: Sequence[str], types: Sequence[str], date_index: int | None) -> int:
    """Prefer the requested aggregation, then any numeric column that is not the date."""
    preferred = {COST_AGGREGATION_ALIAS.casefold(), REQUESTED_COST_COLUMN.casefold()}
    for index, name in enumerate(names):
        if name.casefold() in preferred and types[index] == NUMBER_COLUMN_TYPE:
            return index
    for index, column_type in enumerate(types):
        if column_type == NUMBER_COLUMN_TYPE and index != date_index:
            return index
    raise CostResponseError("Cost Management response has no usable cost column")


def _dimension_index(types: Sequence[str], currency_index: int | None) -> int | None:
    for index, column_type in enumerate(types):
        if column_type == STRING_COLUMN_TYPE and index != currency_index:
            return index
    return None


def _parse_usage_date(value: Any) -> date:
    if isinstance(value, bool) or not isinstance(value, int | str):
        raise CostResponseError("Cost Management returned an unusable usage date")
    text = str(value).strip()
    try:
        if len(text) == 8 and text.isdigit():
            return date(int(text[:4]), int(text[4:6]), int(text[6:]))
        return date.fromisoformat(text[:10])
    except ValueError as error:
        raise CostResponseError("Cost Management returned an unusable usage date") from error


def _parse_amount(value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, int | float | str):
        raise CostResponseError("Cost Management returned an unusable cost value")
    try:
        return float(value)
    except ValueError as error:
        raise CostResponseError("Cost Management returned an unusable cost value") from error


def parse_query_result(payload: Mapping[str, Any]) -> CostDataset:
    """Normalize one merged query result, mapping every value by column name."""
    columns, rows, _ = _page_parts(payload)
    if not rows:
        return CostDataset(currency=None, records=())

    names = _column_names(columns)
    types = _column_types(columns)
    date_index = _index_of_named(names, DATE_COLUMN_NAMES)
    currency_index = _index_of_named(names, CURRENCY_COLUMN_NAMES)
    cost_index = _cost_index(names, types, date_index)
    dimension_index = _dimension_index(types, currency_index)

    records: list[CostRecord] = []
    currencies: set[str] = set()
    for row in rows:
        if not isinstance(row, Sequence) or isinstance(row, str) or len(row) != len(columns):
            raise CostResponseError("Cost Management returned a row that does not match columns")
        if currency_index is not None:
            currencies.add(str(row[currency_index]))
        records.append(
            CostRecord(
                usage_date=None if date_index is None else _parse_usage_date(row[date_index]),
                dimension=(
                    UNASSIGNED_DIMENSION if dimension_index is None else str(row[dimension_index])
                ),
                amount=_parse_amount(row[cost_index]),
            )
        )

    if len(currencies) > 1:
        raise CostResponseError("Cost Management returned mixed currencies for one query")
    return CostDataset(currency=next(iter(currencies), None), records=tuple(records))


class AccessTokenLike(Protocol):
    @property
    def token(self) -> str: ...


class SupportsGetToken(Protocol):
    def get_token(self, *scopes: str) -> AccessTokenLike: ...


TokenProvider = Callable[[], Awaitable[str]]
Sleeper = Callable[[float], Awaitable[None]]


class CredentialTokenProvider:
    """Acquires an ARM token off the event loop.

    The synchronous credential is deliberate: `azure.identity.aio` needs
    azure-core's aiohttp transport, and aiohttp is not in this project's
    lockfile, so the async credential would fail on its first token request.
    Token acquisition is cached inside the credential and runs in a worker
    thread, so the blocking call does not stall the loop.
    """

    def __init__(self, credential: SupportsGetToken, *, scope: str = MANAGEMENT_SCOPE) -> None:
        self._credential = credential
        self._scope = scope

    def _token(self) -> str:
        return self._credential.get_token(self._scope).token

    async def __call__(self) -> str:
        return await to_thread.run_sync(self._token)


class CostManagementClient:
    """Posts bounded queries to one fixed subscription scope."""

    def __init__(
        self,
        *,
        settings: Settings,
        http_client: httpx.AsyncClient,
        acquire_token: TokenProvider,
        sleep: Sleeper = asyncio.sleep,
    ) -> None:
        self._url = query_url(settings.azure_subscription_id)
        self._http = http_client
        self._acquire_token = acquire_token
        self._sleep = sleep

    @property
    def url(self) -> str:
        return self._url

    async def aclose(self) -> None:
        await self._http.aclose()

    async def run_query(self, filters: CostFilter, granularity: str) -> CostDataset:
        return parse_query_result(await self._fetch_all_pages(build_query(filters, granularity)))

    async def _fetch_all_pages(self, body: Mapping[str, Any]) -> Mapping[str, Any]:
        token = await self._acquire_token()
        headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
        url = self._url
        columns: list[Mapping[str, Any]] = []
        rows: list[Sequence[Any]] = []

        for _ in range(MAX_PAGES):
            page_columns, page_rows, next_link = _page_parts(await self._post(url, body, headers))
            if not columns:
                columns = page_columns
            elif _column_names(page_columns) != _column_names(columns):
                raise CostResponseError("Cost Management changed the result schema between pages")
            rows.extend(page_rows)
            if next_link is None:
                return {"properties": {"columns": columns, "rows": rows, "nextLink": None}}
            url = _validated_next_link(next_link)

        raise CostUpstreamError("Cost Management returned more result pages than allowed")

    async def _post(
        self, url: str, body: Mapping[str, Any], headers: Mapping[str, str]
    ) -> Mapping[str, Any]:
        for attempt in range(MAX_RETRIES + 1):
            try:
                response = await self._http.post(
                    url, json=body, headers=dict(headers), timeout=REQUEST_TIMEOUT_SECONDS
                )
            except httpx.TimeoutException as error:
                if attempt == MAX_RETRIES:
                    raise CostUpstreamTimeoutError(
                        "Cost Management did not respond in time"
                    ) from error
                logger.warning("Cost Management request timed out; retrying")
                await self._sleep(_backoff(attempt))
                continue
            except httpx.HTTPError as error:
                raise CostUpstreamError("Cost Management could not be reached") from error

            status = response.status_code
            if status in (401, 403):
                raise CostAccessDeniedError("Cost Management rejected the API identity")
            if status == 204:
                return {}
            if status in RETRYABLE_STATUS_CODES:
                if attempt == MAX_RETRIES:
                    raise _retry_budget_error(status)
                logger.warning("Cost Management returned status %s; retrying", status)
                await self._sleep(_retry_delay(response, attempt))
                continue
            if status >= 400:
                raise CostUpstreamError(f"Cost Management returned status {status}")
            return _decoded(response)
        raise CostUpstreamError("Cost Management is unavailable")  # pragma: no cover


def _retry_budget_error(status: int) -> CostQueryError:
    if status == 429:
        return CostThrottledError("Cost Management is throttling cost queries")
    return CostUpstreamError(f"Cost Management is unavailable (status {status})")


def _decoded(response: httpx.Response) -> Mapping[str, Any]:
    try:
        payload = response.json()
    except ValueError as error:
        raise CostResponseError("Cost Management returned a body that is not JSON") from error
    if not isinstance(payload, Mapping):
        raise CostResponseError("Cost Management returned a body that is not an object")
    return payload


def _validated_next_link(next_link: str) -> str:
    """Keep paging on the management plane; a link is attacker-influenced input."""
    if not next_link.casefold().startswith(NEXT_LINK_PREFIX):
        raise CostResponseError("Cost Management returned an unexpected paging link")
    return next_link


def _retry_delay(response: httpx.Response, attempt: int) -> float:
    for header in RETRY_AFTER_HEADERS:
        raw = response.headers.get(header)
        if raw is None:
            continue
        try:
            seconds = float(raw)
        except ValueError:
            continue  # an HTTP-date form is ignored in favour of the local backoff
        if seconds >= 0:
            return min(seconds, MAX_RETRY_DELAY_SECONDS)
    return _backoff(attempt)


def _backoff(attempt: int) -> float:
    return min(BASE_RETRY_DELAY_SECONDS * float(2**attempt), MAX_RETRY_DELAY_SECONDS)
