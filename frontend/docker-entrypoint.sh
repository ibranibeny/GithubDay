#!/bin/sh
# Renders /usr/share/nginx/html/config.js from the baked-in template at container
# start, so one image serves every environment.
set -eu

TEMPLATE=/etc/nginx/config.template.js
OUTPUT=/usr/share/nginx/html/config.js

if ! command -v envsubst >/dev/null 2>&1; then
    echo "config-entrypoint: envsubst not found in the image" >&2
    exit 1
fi

# Every placeholder is interpolated inside a double-quoted JS string literal, so
# a raw backslash, double quote, CR or LF in an environment variable would end
# that literal and let a bad config value inject arbitrary JavaScript. Escape \
# and ", and drop CR/LF outright - none of these six values is ever legitimately
# multi-line, so removing the control characters cannot lose real data.
js_escape() {
    _escaped=$(printf '%s' "$1" | tr -d '\r\n')
    if [ "$_escaped" != "$1" ]; then
        echo "config-entrypoint: stripped CR/LF from a runtime config value" >&2
    fi
    printf '%s' "$_escaped" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

APP_ENVIRONMENT=$(js_escape "${APP_ENVIRONMENT:-}")
ENTRA_TENANT_ID=$(js_escape "${ENTRA_TENANT_ID:-}")
ENTRA_SPA_CLIENT_ID=$(js_escape "${ENTRA_SPA_CLIENT_ID:-}")
ENTRA_API_CLIENT_ID=$(js_escape "${ENTRA_API_CLIENT_ID:-}")
API_BASE_URL=$(js_escape "${API_BASE_URL:-}")
APPLICATIONINSIGHTS_CONNECTION_STRING=$(js_escape "${APPLICATIONINSIGHTS_CONNECTION_STRING:-}")

export APP_ENVIRONMENT ENTRA_TENANT_ID ENTRA_SPA_CLIENT_ID ENTRA_API_CLIENT_ID
export API_BASE_URL APPLICATIONINSIGHTS_CONNECTION_STRING

for _required in ENTRA_TENANT_ID ENTRA_SPA_CLIENT_ID ENTRA_API_CLIENT_ID API_BASE_URL; do
    eval "_value=\${$_required}"
    if [ -z "$_value" ]; then
        echo "config-entrypoint: $_required is empty; the SPA will fail to sign in" >&2
    fi
done

# The explicit variable list keeps envsubst from touching anything else in the
# template, and envsubst substitutes literally, so the escaping above survives.
envsubst '${APP_ENVIRONMENT} ${ENTRA_TENANT_ID} ${ENTRA_SPA_CLIENT_ID} ${ENTRA_API_CLIENT_ID} ${API_BASE_URL} ${APPLICATIONINSIGHTS_CONNECTION_STRING}' \
    <"$TEMPLATE" >"$OUTPUT"

exec "$@"
