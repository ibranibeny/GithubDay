#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib.sh - shared helpers for the Azure Cost Copilot infrastructure scripts.
#
# Source this file, never execute it:
#
#   set -Eeuo pipefail
#   SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=./lib.sh
#   . "${SCRIPT_DIR}/lib.sh"
#
# Logging rule: print resource names, resource IDs, states and versions only.
# Access tokens, registry passwords, client secrets, instrumentation keys and
# connection strings must never reach stdout or stderr.

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "lib.sh must be sourced, not executed" >&2
  exit 64
fi

if [ -n "${COST_COPILOT_LIB_LOADED:-}" ]; then
  return 0
fi
COST_COPILOT_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# All logging goes to stderr so stdout stays machine readable (READY, IDs, JSON).

_log_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

log() {
  printf '[%s] [info] %s\n' "$(_log_timestamp)" "$*" >&2
}

ok() {
  printf '[%s] [ ok ] %s\n' "$(_log_timestamp)" "$*" >&2
}

warn() {
  printf '[%s] [warn] %s\n' "$(_log_timestamp)" "$*" >&2
}

err() {
  printf '[%s] [fail] %s\n' "$(_log_timestamp)" "$*" >&2
}

die() {
  err "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# Azure CLI value capture
# ---------------------------------------------------------------------------

# azval runs the Azure CLI and strips carriage returns from its output.
#
# On this workshop laptop `az` resolves to the Windows `az.cmd` through WSL,
# which terminates every line with CRLF. A plain "$(az ... -o tsv)" therefore
# keeps a trailing \r that breaks string comparisons, `grep` patterns and any
# value interpolated into a URL. Every scalar captured from the Azure CLI must
# go through azval (or an explicit `tr -d '\r'`).
azval() {
  local out rc=0
  out="$(command az "$@")" || rc=$?
  printf '%s' "${out//$'\r'/}"
  return "$rc"
}

# True when `az` is the Windows executable reached through WSL interop. Such an
# `az` cannot read POSIX paths, so file arguments have to be translated.
az_is_windows_binary() {
  local resolved
  resolved="$(command -v az 2>/dev/null || true)"
  case "$resolved" in
    /mnt/[a-z]/*) return 0 ;;
    *.cmd | *.CMD | *.exe | *.EXE) return 0 ;;
    *) return 1 ;;
  esac
}

# Path of a temporary file rendered so that the resolved `az` can open it.
az_path() {
  local path="$1" translated=""
  if az_is_windows_binary && command -v wslpath >/dev/null 2>&1; then
    translated="$(wslpath -w "$path" 2>/dev/null | tr -d '\r')" || translated=""
    if [ -n "$translated" ]; then
      printf '%s' "$translated"
      return 0
    fi
    warn "wslpath could not translate ${path}; passing the POSIX path to az"
  fi
  printf '%s' "$path"
}

# Temporary files created by az_body_file, removed by cleanup_temp_files.
COST_COPILOT_TEMP_FILES=()

# Path of the request body written by the last successful az_body_file call.
AZ_BODY_FILE=""

# az_body_file <json> - write a request body to a temporary file and set
# AZ_BODY_FILE to a path the resolved `az` can read. Passing bodies by file
# avoids quoting JSON through the WSL/cmd.exe argument boundary.
#
# The result is returned through a global rather than stdout on purpose: a
# command substitution would run this in a subshell, and the bookkeeping needed
# by cleanup_temp_files would be lost.
az_body_file() {
  local payload="$1" file
  AZ_BODY_FILE=""
  file="$(mktemp)" || return 1
  printf '%s' "$payload" >"$file"
  COST_COPILOT_TEMP_FILES+=("$file")
  AZ_BODY_FILE="$(az_path "$file")"
  [ -n "$AZ_BODY_FILE" ]
}

cleanup_temp_files() {
  local file
  if [ "${#COST_COPILOT_TEMP_FILES[@]}" -eq 0 ]; then
    return 0
  fi
  for file in "${COST_COPILOT_TEMP_FILES[@]}"; do
    rm -f -- "$file"
  done
  COST_COPILOT_TEMP_FILES=()
}

# ---------------------------------------------------------------------------
# Environment and tooling guards
# ---------------------------------------------------------------------------

# require_cmd <command>... - returns non-zero when any command is missing.
require_cmd() {
  local command_name missing=0
  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      err "required command not found on PATH: ${command_name}"
      missing=1
    fi
  done
  return "$missing"
}

# require_env <VAR>... - returns non-zero when any variable is unset or empty.
require_env() {
  local name missing=0
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      err "required environment variable is not set: ${name}"
      missing=1
    fi
  done
  return "$missing"
}

is_guid() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

lowercase() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

# extract_version <text> - echo the first dotted version found in <text>.
# Handles "2.84.0", "gh version 2.62.0 (2024-11-14)" and "jq-1.7.1".
extract_version() {
  local text="${1:-}"
  if [[ "$text" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# version_ge <have> <want> - succeed when <have> is at least <want>.
version_ge() {
  local -a have_parts want_parts
  local index have_field want_field
  IFS='.' read -r -a have_parts <<<"${1:-0}"
  IFS='.' read -r -a want_parts <<<"${2:-0}"
  for index in 0 1 2; do
    have_field="${have_parts[index]:-0}"
    want_field="${want_parts[index]:-0}"
    have_field="${have_field//[!0-9]/}"
    want_field="${want_field//[!0-9]/}"
    if ((10#${have_field:-0} > 10#${want_field:-0})); then
      return 0
    fi
    if ((10#${have_field:-0} < 10#${want_field:-0})); then
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Configuration files
# ---------------------------------------------------------------------------

# _parse_config_line <line> - sets _config_key and _config_value, or returns 1
# for blank lines, comments and malformed entries.
_config_key=""
_config_value=""
_parse_config_line() {
  local line="${1-}"
  _config_key=""
  _config_value=""
  line="${line%$'\r'}"
  case "$line" in
    '' | '#'*) return 1 ;;
    *=*) ;;
    *) return 1 ;;
  esac
  local key="${line%%=*}"
  local value="${line#*=}"
  key="${key#export }"
  key="${key//[[:space:]]/}"
  if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    return 1
  fi
  case "$value" in
    \"*\") value="${value#\"}" && value="${value%\"}" ;;
    \'*\') value="${value#\'}" && value="${value%\'}" ;;
  esac
  _config_key="$key"
  _config_value="$value"
  return 0
}

# load_config <file> - export every KEY=VALUE entry that is not already set.
# The current environment always wins so CI variables override the files.
load_config() {
  local file="${1:?load_config requires a file path}" line
  [ -f "$file" ] || die "configuration file not found: ${file}"
  while IFS= read -r line || [ -n "$line" ]; do
    if ! _parse_config_line "$line"; then
      continue
    fi
    if [ -z "${!_config_key:-}" ]; then
      printf -v "$_config_key" '%s' "$_config_value"
      export "${_config_key?}"
    fi
  done <"$file"
}

# config_value <file> <key> - echo one value without exporting anything.
config_value() {
  local file="${1:?config_value requires a file path}"
  local key="${2:?config_value requires a key}"
  local line
  [ -f "$file" ] || die "configuration file not found: ${file}"
  while IFS= read -r line || [ -n "$line" ]; do
    if ! _parse_config_line "$line"; then
      continue
    fi
    if [ "$_config_key" = "$key" ]; then
      printf '%s' "$_config_value"
      return 0
    fi
  done <"$file"
  return 1
}

# ---------------------------------------------------------------------------
# Azure context guard
# ---------------------------------------------------------------------------

# check_azure_context - returns non-zero (with an explanation) when the signed
# in Azure CLI context is not the expected tenant and subscription.
check_azure_context() {
  require_env AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID || return 1

  local account tenant subscription signed_in_as
  if ! account="$(azval account show --output tsv --query '[tenantId,id,user.name]' 2>/dev/null)"; then
    err "'az account show' failed. Run 'az login' (device code is fine) and retry."
    return 1
  fi
  # `--query '[a,b,c]' -o tsv` prints one value per line (an array becomes rows),
  # not a single tab-delimited row, so read the fields line by line.
  {
    IFS= read -r tenant
    IFS= read -r subscription
    IFS= read -r signed_in_as
  } <<<"$account" || true

  local failed=0
  if [ "$tenant" != "$AZURE_TENANT_ID" ]; then
    err "wrong Entra ID tenant: active '${tenant:-<none>}', expected '${AZURE_TENANT_ID}'"
    failed=1
  fi
  if [ "$subscription" != "$AZURE_SUBSCRIPTION_ID" ]; then
    err "wrong subscription: active '${subscription:-<none>}', expected '${AZURE_SUBSCRIPTION_ID}'"
    err "run: az account set --subscription ${AZURE_SUBSCRIPTION_ID}"
    failed=1
  fi
  if [ "$failed" -ne 0 ]; then
    return 1
  fi

  ok "Azure context: subscription ${subscription} in tenant ${tenant} as ${signed_in_as:-<service principal>}"
  return 0
}

# require_azure_context - same guard, but fatal.
require_azure_context() {
  check_azure_context || die "Azure CLI context guard failed; nothing was changed."
}
