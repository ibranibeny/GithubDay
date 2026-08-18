# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Builder: resolve the virtualenv from the committed lockfile only.
# ---------------------------------------------------------------------------
FROM ghcr.io/astral-sh/uv:python3.13-trixie-slim AS builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv

WORKDIR /app

# Only the lockfile inputs land in this layer, so it stays cached until a
# dependency actually changes. --frozen forbids re-resolving: the image gets
# exactly what uv.lock pins, never a newer release that appeared since.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# ---------------------------------------------------------------------------
# Runtime: the same Debian release as the builder so the venv ABI matches.
# ---------------------------------------------------------------------------
FROM python:3.13-slim-trixie AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    PATH="/app/.venv/bin:$PATH"

# Fixed high UID so the filesystem ownership is stable no matter which host or
# orchestrator runs the image.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin app

WORKDIR /app

COPY --from=builder --chown=10001:10001 /app/.venv /app/.venv
COPY --chown=10001:10001 src /app/src

USER 10001

EXPOSE 8000

# No curl or wget in python:slim, so the venv interpreter does the probe.
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
    CMD ["python", "-c", "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health/live',timeout=2).read()"]

# main.py exposes a module-level `app` built by create_app(), so uvicorn imports
# it directly; --factory would build a second application on top of that one.
CMD ["uvicorn", "cost_copilot.main:app", "--host", "0.0.0.0", "--port", "8000"]
