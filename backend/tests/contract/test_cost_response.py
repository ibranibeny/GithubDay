"""Contract tests for the Cost Management query response shape.

Every fixture is synthetic. The rules under test come from the documented
`QueryResult` shape: `properties.columns` names the positional values in
`properties.rows`, so nothing may be read by a hard-coded index.
"""

from datetime import date
from typing import Any

import pytest

from cost_copilot.clients.cost_management import (
    CostResponseError,
    RequestedGrouping,
    parse_query_result,
)
from fixture_data import cost_fixture


def test_columns_are_mapped_by_name() -> None:
    dataset = parse_query_result(cost_fixture("groupedDaily"))

    assert dataset.currency == "USD"
    assert [(record.usage_date, record.dimension, record.amount) for record in dataset.records] == [
        (date(2026, 8, 1), "Fabrikam Widget Service", 12.5),
        (date(2026, 8, 1), "Fabrikam Ledger Service", 7.5),
        (date(2026, 8, 2), "Fabrikam Widget Service", 20.0),
        (date(2026, 8, 2), "Fabrikam Ledger Service", 5.0),
    ]


def test_shuffling_the_column_order_does_not_change_the_result() -> None:
    ordered = parse_query_result(cost_fixture("groupedDaily"))
    shuffled = parse_query_result(cost_fixture("groupedDailyShuffledColumns"))

    assert shuffled == ordered


def test_an_offer_specific_cost_column_is_found_by_name() -> None:
    dataset = parse_query_result(cost_fixture("preTaxCostOffer"))

    assert dataset.currency == "EUR"
    assert [record.amount for record in dataset.records] == [41.25, 108.75]
    assert [record.dimension for record in dataset.records] == [
        "rg-fabrikam-dev",
        "rg-fabrikam-prod",
    ]
    assert {record.usage_date for record in dataset.records} == {date(2026, 8, 1)}


def test_a_known_offer_cost_column_wins_over_another_number_column() -> None:
    dataset = parse_query_result(cost_fixture("preTaxCostOfferWithQuantity"))

    assert [record.amount for record in dataset.records] == [41.25, 108.75]


def test_the_aggregation_alias_column_is_preferred() -> None:
    payload = cost_fixture("preTaxCostOfferWithQuantity")
    payload["properties"]["columns"][1]["name"] = "totalCost"

    assert [record.amount for record in parse_query_result(payload).records] == [3.0, 9.0]


def test_an_unknown_cost_column_name_falls_back_to_the_only_other_number_column() -> None:
    payload = cost_fixture("groupedDaily")
    payload["properties"]["columns"][0]["name"] = "BilledCost"

    assert [record.amount for record in parse_query_result(payload).records] == [
        12.5,
        7.5,
        20.0,
        5.0,
    ]


def test_a_tag_grouped_result_binds_the_tag_value_column() -> None:
    dataset = parse_query_result(
        cost_fixture("tagGrouped"), grouping=RequestedGrouping("cost-center", is_tag=True)
    )

    assert [record.dimension for record in dataset.records] == ["fin-ops", "platform"]


def test_a_tag_grouped_result_without_a_tag_value_column_is_unassigned() -> None:
    """The TagKey column repeats the requested key, so it is never a group label."""
    dataset = parse_query_result(
        cost_fixture("tagGroupedWithoutTagValue"),
        grouping=RequestedGrouping("cost-center", is_tag=True),
    )

    assert [record.dimension for record in dataset.records] == ["Unassigned"]


def test_a_dimension_grouped_result_binds_the_requested_dimension() -> None:
    dataset = parse_query_result(
        cost_fixture("dimensionGroupedWithExtraString"),
        grouping=RequestedGrouping("ServiceName", is_tag=False),
    )

    assert [record.dimension for record in dataset.records] == [
        "Fabrikam Widget Service",
        "Fabrikam Ledger Service",
    ]


def test_a_requested_dimension_the_answer_omits_falls_back_to_the_first_label_column() -> None:
    dataset = parse_query_result(
        cost_fixture("groupedDaily"), grouping=RequestedGrouping("ResourceGroupName", is_tag=False)
    )

    assert dataset.records[0].dimension == "Fabrikam Widget Service"


def test_a_result_without_a_grouping_column_is_still_parsed() -> None:
    dataset = parse_query_result(cost_fixture("ungrouped"))

    assert len(dataset.records) == 1
    assert dataset.records[0].usage_date is None
    assert dataset.records[0].dimension == "Unassigned"
    assert dataset.records[0].amount == 45.0


def test_an_empty_row_set_produces_an_empty_dataset() -> None:
    dataset = parse_query_result(cost_fixture("emptyRows"))

    assert dataset.records == ()
    assert dataset.currency is None


def test_a_body_without_properties_is_rejected() -> None:
    """Only a 204 means "no cost"; a 200 that lost its payload must not read as zero."""
    with pytest.raises(CostResponseError, match="properties"):
        parse_query_result({})


def test_a_result_without_a_currency_column_reports_no_currency() -> None:
    dataset = parse_query_result(cost_fixture("noCurrencyColumn"))

    assert dataset.currency is None
    assert dataset.records[0].amount == 3.25
    assert dataset.records[0].dimension == "Fabrikam Widget Service"


def test_currency_codes_are_normalized_and_unusable_values_are_ignored() -> None:
    """Padding, casing, a blank cell, and a null must not read as separate currencies."""
    dataset = parse_query_result(cost_fixture("paddedCurrency"))

    assert dataset.currency == "USD"
    assert len(dataset.records) == 4


def test_mixed_currencies_are_rejected() -> None:
    with pytest.raises(CostResponseError, match="currenc"):
        parse_query_result(cost_fixture("mixedCurrency"))


@pytest.mark.parametrize("bad_date", [20261301, "not-a-date", None, 3.5])
def test_an_unusable_date_value_is_rejected(bad_date: Any) -> None:
    payload = cost_fixture("groupedDaily")
    payload["properties"]["rows"][0][1] = bad_date

    with pytest.raises(CostResponseError, match="date"):
        parse_query_result(payload)


def test_an_iso_date_column_is_accepted() -> None:
    payload = cost_fixture("groupedDaily")
    payload["properties"]["rows"][0][1] = "2026-08-01T00:00:00"

    assert parse_query_result(payload).records[0].usage_date == date(2026, 8, 1)


@pytest.mark.parametrize("bad_amount", ["free", None, True])
def test_an_unusable_cost_value_is_rejected(bad_amount: Any) -> None:
    payload = cost_fixture("groupedDaily")
    payload["properties"]["rows"][0][0] = bad_amount

    with pytest.raises(CostResponseError, match="cost"):
        parse_query_result(payload)


@pytest.mark.parametrize(
    "non_finite", [float("nan"), float("inf"), float("-inf"), "NaN", "Infinity", "-Infinity"]
)
def test_a_non_finite_cost_value_is_rejected(non_finite: Any) -> None:
    """JSON decoding accepts a bare NaN or Infinity, but no bill may be one."""
    payload = cost_fixture("groupedDaily")
    payload["properties"]["rows"][0][0] = non_finite

    with pytest.raises(CostResponseError, match="cost"):
        parse_query_result(payload)


def test_a_row_that_does_not_match_the_columns_is_rejected() -> None:
    payload = cost_fixture("groupedDaily")
    payload["properties"]["rows"][0] = [1.0, 20260801]

    with pytest.raises(CostResponseError, match="row"):
        parse_query_result(payload)


def test_a_result_without_any_numeric_column_is_rejected() -> None:
    payload = cost_fixture("groupedDaily")
    for column in payload["properties"]["columns"]:
        column["type"] = "String"

    with pytest.raises(CostResponseError, match="cost column"):
        parse_query_result(payload)


@pytest.mark.parametrize("properties", ["not-an-object", None])
def test_a_malformed_envelope_is_rejected(properties: Any) -> None:
    with pytest.raises(CostResponseError, match="properties"):
        parse_query_result({"properties": properties})


def test_malformed_columns_are_rejected() -> None:
    with pytest.raises(CostResponseError, match="columns"):
        parse_query_result({"properties": {"columns": "nope", "rows": []}})


def test_malformed_rows_are_rejected() -> None:
    with pytest.raises(CostResponseError, match="rows"):
        parse_query_result({"properties": {"columns": [], "rows": "nope"}})


def test_a_non_string_paging_link_is_rejected() -> None:
    payload = cost_fixture("groupedDaily")
    payload["properties"]["nextLink"] = {"href": "https://management.azure.com/"}

    with pytest.raises(CostResponseError, match="paging link"):
        parse_query_result(payload)
