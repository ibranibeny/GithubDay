"""Client for the Cost Management `Query - Usage` API.

Contract this module is written against (api-version 2026-06-01):
`POST {scope}/providers/Microsoft.CostManagement/query` returns
`properties.columns` (name/type pairs) plus `properties.rows`, where each row is
a positional array aligned to those columns. Column names vary by offer, so every
value here is located by column name and never by a fixed index.
"""

import asyncio
import logging
import secrets
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime, time
from time import monotonic
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

# `QueryTimePeriod.from`/`.to` are date-time, and both filter days are inclusive, so the
# window runs from the first day's midnight to the last day's final second in UTC.
DAY_START = time(0, 0, 0, tzinfo=UTC)
DAY_END = time(23, 59, 59, tzinfo=UTC)

REQUEST_TIMEOUT_SECONDS = 30.0
# One wall-clock budget for a whole query: without it a per-attempt timeout would
# multiply across retries and pages, so a single request could hang for minutes.
QUERY_DEADLINE_SECONDS = 75.0
MAX_RETRIES = 3
MAX_PAGES = 50
BASE_RETRY_DELAY_SECONDS = 1.0
MAX_RETRY_DELAY_SECONDS = 30.0
RETRY_JITTER_FRACTION = 0.25
RETRYABLE_STATUS_CODES = frozenset({429, 502, 503, 504})
# 429 answers carry a Consumption-specific header; 503 answers use the standard one.
RETRY_AFTER_HEADERS = ("x-ms-ratelimit-microsoft.consumption-retry-after", "retry-after")

DATE_COLUMN_NAMES = frozenset({"usagedate", "billingmonth"})
CURRENCY_COLUMN_NAMES = frozenset({"currency", "billingcurrency", "billingcurrencycode"})
# The cost column is named per offer: MCA answers with Cost, EA and legacy with PreTaxCost.
KNOWN_COST_COLUMN_NAMES = frozenset(
    {"cost", "costusd", "pretaxcost", "pretaxcostusd", "costinbillingcurrency"}
)
# A TagKey grouping answers with a TagKey/TagValue pair; the value carries the group label.
TAG_VALUE_COLUMN_NAMES = frozenset({"tagvalue"})
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
class _NoContent:
    """A genuine 204: the query ran and there is nothing to bill.

    Kept distinct from a decoded body so a 200 that lost its payload can never be
    mistaken for "no cost".
    """


NO_CONTENT = _NoContent()


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


@dataclass(frozen=True, slots=True)
class RequestedGrouping:
    """What the caller asked to group by, so the label column is bound by name."""

    name: str
    is_tag: bool


def requested_grouping(filters: CostFilter) -> RequestedGrouping:
    return RequestedGrouping(filters.azure_dimension, filters.grouping is CostGrouping.TAG)


def build_query(filters: CostFilter, granularity: str) -> dict[str, Any]:
    """Build the query body. Values travel in JSON, never in the URL."""
    grouping_type = "TagKey" if filters.grouping is CostGrouping.TAG else "Dimension"
    return {
        "type": filters.metric.value,
        "timeframe": "Custom",
        "timePeriod": {
            "from": datetime.combine(filters.start, DAY_START).isoformat(),
            "to": datetime.combine(filters.end, DAY_END).isoformat(),
        },
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


def _properties(payload: Mapping[str, Any]) -> Mapping[str, Any]:
    """Money must fail closed: only a 204 means "nothing", never a body without properties."""
    properties = payload.get("properties")
    if not isinstance(properties, Mapping):
        raise CostResponseError("Cost Management response has no usable properties object")
    return properties


def _page_parts(
    payload: Mapping[str, Any],
) -> tuple[list[Mapping[str, Any]], list[Sequence[Any]], str | None]:
    """Split one response page into columns, rows, and the paging link."""
    properties = _properties(payload)

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


def _named_index(
    names: Sequence[str], types: Sequence[str], candidates: frozenset[str], column_type: str
) -> int | None:
    for index, name in enumerate(names):
        if name.casefold() in candidates and types[index] == column_type:
            return index
    return None


def _cost_index(names: Sequence[str], types: Sequence[str], date_index: int | None) -> int:
    """Bind the amount offer-agnostically: alias, then a known cost column, then any number."""
    alias = _named_index(
        names, types, frozenset({COST_AGGREGATION_ALIAS.casefold()}), NUMBER_COLUMN_TYPE
    )
    if alias is not None:
        return alias
    known = _named_index(names, types, KNOWN_COST_COLUMN_NAMES, NUMBER_COLUMN_TYPE)
    if known is not None:
        return known
    for index, column_type in enumerate(types):
        if column_type == NUMBER_COLUMN_TYPE and index != date_index:
            return index
    raise CostResponseError("Cost Management response has no usable cost column")


def _dimension_index(
    names: Sequence[str],
    types: Sequence[str],
    currency_index: int | None,
    grouping: RequestedGrouping | None,
) -> int | None:
    if grouping is not None:
        if grouping.is_tag:
            # A TagKey column only repeats the key that was asked for, so when the
            # answer carries no TagValue there is no label to bind at all.
            return _named_index(names, types, TAG_VALUE_COLUMN_NAMES, STRING_COLUMN_TYPE)
        requested = _named_index(
            names, types, frozenset({grouping.name.casefold()}), STRING_COLUMN_TYPE
        )
        if requested is not None:
            return requested
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
    # A null cost is rejected rather than read as zero: an unknown charge must not
    # silently understate a bill.
    if isinstance(value, bool) or not isinstance(value, int | float | str):
        raise CostResponseError("Cost Management returned an unusable cost value")
    try:
        return float(value)
    except ValueError as error:
        raise CostResponseError("Cost Management returned an unusable cost value") from error


def _normalized_currency(value: Any) -> str | None:
    """ISO codes are compared case- and padding-insensitively; a blank cell says nothing."""
    if not isinstance(value, str):
        return None
    return value.strip().upper() or None


def parse_query_result(
    payload: Mapping[str, Any], *, grouping: RequestedGrouping | None = None
) -> CostDataset:
    """Normalize one merged query result, mapping every value by column name."""
    columns, rows, _ = _page_parts(payload)
    if not rows:
        return CostDataset(currency=None, records=())

    names = _column_names(columns)
    types = _column_types(columns)
    date_index = _index_of_named(names, DATE_COLUMN_NAMES)
    currency_index = _index_of_named(names, CURRENCY_COLUMN_NAMES)
    cost_index = _cost_index(names, types, date_index)
    dimension_index = _dimension_index(names, types, currency_index, grouping)

    records: list[CostRecord] = []
    currencies: set[str] = set()
    for row in rows:
        if not isinstance(row, Sequence) or isinstance(row, str) or len(row) != len(columns):
            raise CostResponseError("Cost Management returned a row that does not match columns")
        if currency_index is not None:
            currency = _normalized_currency(row[currency_index])
            if currency is not None:
                currencies.add(currency)
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

    def close(self) -> None: ...


TokenProvider = Callable[[], Awaitable[str]]
Sleeper = Callable[[float], Awaitable[None]]
Clock = Callable[[], float]
Jitter = Callable[[], float]

_JITTER_SOURCE = secrets.SystemRandom()


class _Deadline:
    """One monotonic budget shared by every attempt and page of a single query."""

    __slots__ = ("_clock", "_expires_at")

    def __init__(self, clock: Clock, budget: float) -> None:
        self._clock = clock
        self._expires_at = clock() + budget

    def remaining(self) -> float:
        return self._expires_at - self._clock()


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

    async def aclose(self) -> None:
        """Releases the credential's own transport; called by whoever created it."""
        await to_thread.run_sync(self._credential.close)


class CostManagementClient:
    """Posts bounded queries to one fixed subscription scope."""

    def __init__(
        self,
        *,
        settings: Settings,
        http_client: httpx.AsyncClient,
        acquire_token: TokenProvider,
        sleep: Sleeper = asyncio.sleep,
        clock: Clock = monotonic,
        jitter: Jitter = _JITTER_SOURCE.random,
        owns_client: bool = False,
    ) -> None:
        self._url = query_url(settings.azure_subscription_id)
        self._http = http_client
        self._acquire_token = acquire_token
        self._sleep = sleep
        self._clock = clock
        self._jitter = jitter
        self._owns_client = owns_client
        self._token_lock = asyncio.Lock()

    @property
    def url(self) -> str:
        return self._url

    @property
    def is_closed(self) -> bool:
        return self._http.is_closed

    async def aclose(self) -> None:
        """Closes only what this client owns, so a caller's pool is never double-closed."""
        if self._owns_client:
            await self._http.aclose()

    async def run_query(self, filters: CostFilter, granularity: str) -> CostDataset:
        payload = await self._fetch_all_pages(build_query(filters, granularity))
        return parse_query_result(payload, grouping=requested_grouping(filters))

    async def _authorization(self) -> str:
        # Single-flight: a cold credential is asked once while other callers wait,
        # instead of every in-flight query racing to warm the same cache.
        async with self._token_lock:
            return f"Bearer {await self._acquire_token()}"

    async def _fetch_all_pages(self, body: Mapping[str, Any]) -> Mapping[str, Any]:
        deadline = _Deadline(self._clock, QUERY_DEADLINE_SECONDS)
        url = self._url
        columns: list[Mapping[str, Any]] = []
        rows: list[Sequence[Any]] = []

        for _ in range(MAX_PAGES):
            # Re-acquired per page: the credential caches, so this is cheap, and a
            # long paging loop must not keep using a token that has since expired.
            headers = {
                "Authorization": await self._authorization(),
                "Content-Type": "application/json",
            }
            page = await self._post(url, body, headers, deadline)
            if isinstance(page, _NoContent):
                break
            page_columns, page_rows, next_link = _page_parts(page)
            if not columns:
                columns = page_columns
            elif _column_names(page_columns) != _column_names(columns):
                raise CostResponseError("Cost Management changed the result schema between pages")
            rows.extend(page_rows)
            if next_link is None:
                break
            url = _validated_next_link(next_link)
        else:
            raise CostUpstreamError("Cost Management returned more result pages than allowed")

        return {"properties": {"columns": columns, "rows": rows, "nextLink": None}}

    async def _wait(self, delay: float, deadline: _Deadline) -> None:
        """Never sleep past the budget: a retry that could not run must fail now."""
        remaining = deadline.remaining()
        if remaining <= 0:
            raise CostUpstreamTimeoutError("Cost Management did not answer within the query budget")
        await self._sleep(min(delay, remaining))

    async def _post(
        self,
        url: str,
        body: Mapping[str, Any],
        headers: Mapping[str, str],
        deadline: _Deadline,
    ) -> Mapping[str, Any] | _NoContent:
        for attempt in range(MAX_RETRIES + 1):
            remaining = deadline.remaining()
            if remaining <= 0:
                raise CostUpstreamTimeoutError(
                    "Cost Management did not answer within the query budget"
                )
            try:
                response = await self._http.post(
                    url,
                    json=body,
                    headers=dict(headers),
                    timeout=min(REQUEST_TIMEOUT_SECONDS, remaining),
                )
            except httpx.TimeoutException as error:
                if attempt == MAX_RETRIES:
                    raise CostUpstreamTimeoutError(
                        "Cost Management did not respond in time"
                    ) from error
                logger.warning("Cost Management request timed out; retrying")
                await self._wait(_backoff(attempt, self._jitter()), deadline)
                continue
            except httpx.HTTPError as error:
                raise CostUpstreamError("Cost Management could not be reached") from error

            status = response.status_code
            if status in (401, 403):
                logger.warning("Cost Management returned status %s", status)
                raise CostAccessDeniedError("Cost Management rejected the API identity")
            if status == 204:
                return NO_CONTENT
            if status in RETRYABLE_STATUS_CODES:
                if attempt == MAX_RETRIES:
                    logger.warning("Cost Management returned status %s", status)
                    raise _retry_budget_error(status)
                logger.warning("Cost Management returned status %s; retrying", status)
                await self._wait(_retry_delay(response, attempt, self._jitter()), deadline)
                continue
            if status >= 400:
                # Only the status is logged: an ARM error body can quote tenant detail.
                logger.warning("Cost Management returned status %s", status)
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


def _retry_delay(response: httpx.Response, attempt: int, jitter: float) -> float:
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
    return _backoff(attempt, jitter)


def _backoff(attempt: int, jitter: float) -> float:
    """Exponential, plus jitter so retries from many instances do not resynchronize."""
    delay = BASE_RETRY_DELAY_SECONDS * float(2**attempt) * (1.0 + RETRY_JITTER_FRACTION * jitter)
    return min(delay, MAX_RETRY_DELAY_SECONDS)
