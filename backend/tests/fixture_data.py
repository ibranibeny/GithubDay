"""Loader for the sanitized Cost Management contract fixtures."""

import json
from copy import deepcopy
from functools import lru_cache
from pathlib import Path
from typing import Any

COST_QUERY_FIXTURE = Path(__file__).resolve().parent / "fixtures" / "cost-query.json"


@lru_cache
def _fixture_document() -> dict[str, Any]:
    return dict(json.loads(COST_QUERY_FIXTURE.read_text(encoding="utf-8")))


def cost_fixture(name: str) -> dict[str, Any]:
    """Return an independent copy so one test's mutation cannot reach another."""
    payload = _fixture_document()[name]
    return deepcopy(dict(payload))
