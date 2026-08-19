#!/usr/bin/env bash
#
# configure-github.sh - apply this repository's branch, merge and environment
# governance through the GitHub REST API, idempotently.
#
# Unlike every other script here this one talks to GitHub, not Azure, so the
# Azure context guard (require_azure_context) does not apply. It sources lib.sh
# purely for logging (log/ok/warn/die), require_cmd and the config readers. It
# never prints a token: `gh` reads its own credentials (keyring or GH_TOKEN) and
# no secret is ever echoed or written into a request body.
#
# What it configures - all create-or-update, safe to re-run:
#
#   * a branch ruleset on `staging` and on `main` that requires a pull request,
#     the four CI status checks (frontend, backend, infrastructure,
#     container-build), CodeQL code-scanning results at "high or higher", and a
#     Copilot review, and that blocks branch deletion and force-pushes. It does
#     NOT require linear history: promotion from staging to main is a merge
#     commit, and deploy-production.yml reads the tested commit from that
#     merge's second parent (see staging-sha.sh).
#   * repository merge settings: merge commits allowed, squash and rebase merges
#     disabled, for the same provenance reason.
#   * the `staging` and `production` GitHub Environments; production also gets
#     required reviewers (when GitHub user logins are supplied) and a deployment
#     branch policy that restricts deployments to `main`.
#
# It only ever adds or tightens: existing reviewers and any longer wait timer
# are preserved, and rulesets it does not own (matched by name) are left alone.
#
# Usage:
#   gh auth login          # or export GH_TOKEN with repo admin scope
#   bash infra/scripts/configure-github.sh
#
# Environment:
#   DRY_RUN=1                 print the mutating calls instead of running them
#   GH_REPO=owner/repo        target repository (defaults to infra/config)
#   PRODUCTION_REVIEWERS      comma or space separated GitHub *user* logins to
#                             set as required reviewers on the production
#                             environment (existing reviewers are kept)
#   REQUIRED_STATUS_CHECKS    override the required check contexts (defaults to
#                             the four ci.yml job names)
#   CODE_SCANNING_THRESHOLD   security alert threshold (default high_or_higher)

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
. "${SCRIPT_DIR}/lib.sh"

INFRA_CONFIG_DIR="${INFRA_CONFIG_DIR:-${SCRIPT_DIR}/../config}"

DRY_RUN="${DRY_RUN:-0}"

# These four MUST match the job `name:` values in .github/workflows/ci.yml
# exactly - renaming a job there silently drops its gate here.
DEFAULT_STATUS_CHECKS="frontend backend infrastructure container-build"
CODE_SCANNING_THRESHOLD="${CODE_SCANNING_THRESHOLD:-high_or_higher}"

# Branches that receive the protection ruleset.
PROTECTED_BRANCHES=(staging main)

REPO=""

trap cleanup_temp_files EXIT

# ---------------------------------------------------------------------------
# GitHub API helper
# ---------------------------------------------------------------------------

# gh_api <method> <path> [json-body] - one mutating GitHub API call. The body,
# when given, is passed on stdin (--input -) so nothing ends up in the process
# table; governance bodies carry no secrets, but the discipline is kept anyway.
# Honors DRY_RUN and logs only the method and path, never the body.
gh_api() {
  local method="$1" path="$2" body="${3:-}"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: gh api --method ${method} ${path}"
    return 0
  fi
  if [ -n "$body" ]; then
    printf '%s' "$body" |
      gh api --method "$method" -H "Accept: application/vnd.github+json" "$path" --input - >/dev/null
  else
    gh api --method "$method" -H "Accept: application/vnd.github+json" "$path" >/dev/null
  fi
}

resolve_repo() {
  if [ -n "${GH_REPO:-}" ]; then
    REPO="$GH_REPO"
  else
    local owner="${GITHUB_OWNER:-}" name="${GITHUB_REPOSITORY:-}"
    case "$name" in
      */*) REPO="$name" ;; # already owner/repo (for example inside Actions)
      *) REPO="${owner}/${name}" ;;
    esac
  fi
  case "$REPO" in
    ?*/?*) : ;;
    *) die "could not determine the target repository (set GH_REPO=owner/repo)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Branch ruleset
# ---------------------------------------------------------------------------

# status_checks_json - the required_status_checks array, one object per context.
status_checks_json() {
  local raw="${REQUIRED_STATUS_CHECKS:-$DEFAULT_STATUS_CHECKS}"
  local -a contexts
  read -r -a contexts <<<"${raw//,/ }"
  printf '%s\n' "${contexts[@]}" | jq -R 'select(length > 0) | {context: .}' | jq -sc '.'
}

# ruleset_payload <branch> <name> - the full create/update body. Copilot review
# is its own `copilot_code_review` rule (not a pull_request parameter), and
# `required_linear_history` is deliberately absent so merge-commit promotion
# keeps a usable second parent.
ruleset_payload() {
  local branch="$1" name="$2" checks
  checks="$(status_checks_json)"
  jq -n \
    --arg name "$name" \
    --arg ref "refs/heads/${branch}" \
    --arg threshold "$CODE_SCANNING_THRESHOLD" \
    --argjson checks "$checks" \
    '{
      name: $name,
      target: "branch",
      enforcement: "active",
      conditions: { ref_name: { include: [$ref], exclude: [] } },
      rules: [
        { type: "deletion" },
        { type: "non_fast_forward" },
        {
          type: "pull_request",
          parameters: {
            required_approving_review_count: 1,
            dismiss_stale_reviews_on_push: true,
            require_code_owner_review: false,
            require_last_push_approval: false,
            required_review_thread_resolution: false,
            allowed_merge_methods: ["merge"]
          }
        },
        {
          type: "required_status_checks",
          parameters: {
            strict_required_status_checks_policy: true,
            do_not_enforce_on_create: false,
            required_status_checks: $checks
          }
        },
        {
          type: "code_scanning",
          parameters: {
            code_scanning_tools: [
              { tool: "CodeQL", security_alerts_threshold: $threshold, alerts_threshold: "errors" }
            ]
          }
        },
        {
          type: "copilot_code_review",
          parameters: { review_on_push: true, review_draft_pull_requests: false }
        }
      ]
    }'
}

# ensure_branch_ruleset <branch> - create the ruleset, or update the one this
# script already owns (matched by name), so re-runs converge instead of piling
# up duplicates. A ruleset owned by anyone else is never touched, so this only
# ever adds or tightens protection.
ensure_branch_ruleset() {
  local branch="$1" name="cost-copilot-${branch}" payload existing_id
  payload="$(ruleset_payload "$branch" "$name")"

  existing_id="$(gh api --paginate "repos/${REPO}/rulesets" \
    --jq ".[] | select(.name == \"${name}\") | .id" 2>/dev/null | head -n1 || true)"

  if [ -n "$existing_id" ]; then
    gh_api PUT "repos/${REPO}/rulesets/${existing_id}" "$payload"
    ok "ruleset ${name} updated (#${existing_id})"
  else
    gh_api POST "repos/${REPO}/rulesets" "$payload"
    ok "ruleset ${name} created"
  fi

  # A required status check only actually blocks once GitHub has seen that check
  # report a conclusion on the branch at least once; until the first CI run of
  # each context the contexts are recorded but not yet enforced. Nothing to do
  # here - they "stick" automatically after that first run.
}

# ---------------------------------------------------------------------------
# Merge settings
# ---------------------------------------------------------------------------

configure_merge_settings() {
  # Merge commits stay on so a staging->main promotion keeps a real second
  # parent; squash and rebase are turned off so that provenance cannot be
  # flattened away.
  gh_api PATCH "repos/${REPO}" \
    '{"allow_merge_commit":true,"allow_squash_merge":false,"allow_rebase_merge":false}'
  ok "merge settings: merge commits only (squash and rebase disabled)"
}

# ---------------------------------------------------------------------------
# Environments
# ---------------------------------------------------------------------------

ensure_environment() {
  local env="$1"
  gh_api PUT "repos/${REPO}/environments/${env}" '{}'
  ok "environment ${env} present"
}

# reviewers_json <existing-json> - union the reviewers already on the
# environment with the user logins in PRODUCTION_REVIEWERS, resolved to IDs.
# Existing reviewers are always kept, so this never removes an approval gate.
reviewers_json() {
  local existing="${1:-[]}" combined login id
  combined="$existing"
  [ -n "$combined" ] || combined='[]'
  if [ -n "${PRODUCTION_REVIEWERS:-}" ]; then
    local -a wanted
    read -r -a wanted <<<"${PRODUCTION_REVIEWERS//,/ }"
    for login in "${wanted[@]}"; do
      [ -n "$login" ] || continue
      id="$(gh api "users/${login}" --jq '.id' 2>/dev/null || true)"
      if [ -z "$id" ]; then
        warn "could not resolve GitHub user '${login}'; not adding it as a reviewer"
        continue
      fi
      combined="$(jq -c --argjson id "$id" '. + [{type: "User", id: $id}]' <<<"$combined")"
    done
  fi
  jq -cS 'unique_by(.type, .id)' <<<"$combined"
}

# ensure_production_environment - required reviewers plus a deployment branch
# policy that restricts deployments to `main`. Existing reviewers and any longer
# wait timer are preserved; an empty reviewer set is never asserted, so a gate
# configured elsewhere is not wiped out.
ensure_production_environment() {
  local env="production" current existing_reviewers wait_timer reviewers count payload
  current="$(gh api "repos/${REPO}/environments/${env}" 2>/dev/null || true)"
  [ -n "$current" ] || current='{}'

  existing_reviewers="$(printf '%s' "$current" |
    jq -c '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]? | {type: .type, id: .reviewer.id}]' 2>/dev/null || printf '[]')"
  [ -n "$existing_reviewers" ] || existing_reviewers='[]'

  # Preserve any wait timer already configured; never shorten it.
  wait_timer="$(printf '%s' "$current" | jq -r '.wait_timer // 0' 2>/dev/null || printf '0')"
  case "$wait_timer" in '' | *[!0-9]*) wait_timer=0 ;; esac

  reviewers="$(reviewers_json "$existing_reviewers")"
  count="$(printf '%s' "$reviewers" | jq 'length' 2>/dev/null || printf '0')"

  if [ "${count:-0}" -gt 0 ]; then
    payload="$(jq -n --argjson reviewers "$reviewers" --argjson wait "$wait_timer" '{
      wait_timer: $wait,
      prevent_self_review: true,
      reviewers: $reviewers,
      deployment_branch_policy: { protected_branches: false, custom_branch_policies: true }
    }')"
    gh_api PUT "repos/${REPO}/environments/${env}" "$payload"
    ok "production environment configured with ${count} required reviewer(s)"
  else
    # No reviewers known and none preserved: set the branch policy but leave the
    # reviewer collection untouched rather than asserting an empty one.
    payload="$(jq -n --argjson wait "$wait_timer" '{
      wait_timer: $wait,
      prevent_self_review: true,
      deployment_branch_policy: { protected_branches: false, custom_branch_policies: true }
    }')"
    gh_api PUT "repos/${REPO}/environments/${env}" "$payload"
    warn "production has no required reviewers yet; set PRODUCTION_REVIEWERS=<login,...> and re-run to add the human approval gate"
  fi

  ensure_deployment_branch_policy "$env" main
}

# ensure_deployment_branch_policy <env> <branch> - restrict deployments to a
# single branch, idempotently.
ensure_deployment_branch_policy() {
  local env="$1" branch="$2" existing
  existing="$(gh api "repos/${REPO}/environments/${env}/deployment-branch-policies" \
    --jq ".branch_policies[]? | select(.name == \"${branch}\") | .id" 2>/dev/null | head -n1 || true)"
  if [ -n "$existing" ]; then
    ok "deployment branch policy '${branch}' already restricts ${env}"
    return 0
  fi
  gh_api POST "repos/${REPO}/environments/${env}/deployment-branch-policies" \
    "$(jq -n --arg n "$branch" '{name: $n, type: "branch"}')"
  ok "deployment branch policy '${branch}' now restricts ${env}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  load_config "${INFRA_CONFIG_DIR}/shared.env"
  require_cmd gh jq || die "install the missing command-line tools and re-run"
  if ! gh auth status >/dev/null 2>&1; then
    die "the GitHub CLI is not authenticated; run 'gh auth login' (or export GH_TOKEN with repo admin scope) first"
  fi
  resolve_repo
  log "configuring repository governance on ${REPO}"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1: no GitHub object will be changed"
  fi

  configure_merge_settings

  local branch
  for branch in "${PROTECTED_BRANCHES[@]}"; do
    ensure_branch_ruleset "$branch"
  done

  ensure_environment staging
  ensure_production_environment

  ok "repository governance configuration complete for ${REPO}"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
