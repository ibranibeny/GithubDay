#!/usr/bin/env bats
#
# Unit tests for the production promotion gate and the repository governance
# script:
#
#   * infra/scripts/staging-sha.sh must read the tested staging commit from the
#     merge's SECOND parent (HEAD^2) and REFUSE when there is none - a squash, a
#     rebase or a direct push to main carries no tested staging commit.
#   * infra/scripts/configure-github.sh must send branch rulesets that require a
#     pull request, the four named CI checks, CodeQL at high-or-higher and a
#     Copilot review, and that block deletion and force-pushes - WITHOUT
#     requiring linear history (promotion is a merge commit).
#
# `gh` and `git` are PATH stubs. The gh stub records every request body sent via
# `--input -` as one compact JSON document per line, so the assertions read the
# exact payloads back with jq. No real GitHub or git call is ever made.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPTS_DIR="${REPO_ROOT}/infra/scripts"
  CONFIGURE_SCRIPT="${SCRIPTS_DIR}/configure-github.sh"
  STAGING_SHA_SCRIPT="${SCRIPTS_DIR}/staging-sha.sh"

  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  STUB_BIN="${TEST_TMPDIR}/bin"
  mkdir -p "${STUB_BIN}"

  GH_CALL_LOG="${TEST_TMPDIR}/gh-calls.log"
  GH_BODY_LOG="${TEST_TMPDIR}/gh-bodies.jsonl"
  : >"${GH_CALL_LOG}"
  : >"${GH_BODY_LOG}"
  export GH_CALL_LOG GH_BODY_LOG

  write_gh_stub
  write_git_stub
  PATH="${STUB_BIN}:${PATH}"
  export PATH
}

# gh: succeeds on `auth status`, records any `--input -` body as one compact
# JSON line, and answers every read with nothing (the script tolerates empty
# lookups and takes the create path).
write_gh_stub() {
  cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALL_LOG:-/dev/null}"

case "$*" in
  "auth status"*) exit 0 ;;
esac

has_stdin=0
for arg in "$@"; do
  if [ "$arg" = "-" ]; then
    has_stdin=1
    break
  fi
done
if [ "$has_stdin" -eq 1 ]; then
  body="$(cat)"
  if [ -n "$body" ]; then
    printf '%s\n' "$body" | jq -c . >>"${GH_BODY_LOG}" 2>/dev/null ||
      printf '%s\n' "$body" >>"${GH_BODY_LOG}"
  fi
fi

exit 0
STUB
  chmod +x "${STUB_BIN}/gh"
}

# git: only the one command staging-sha.sh runs is modelled. FAKE_MERGE=1 means
# a merge commit (a second parent exists); anything else means a squash, rebase
# or direct push, where HEAD^2 does not resolve and git exits non-zero.
write_git_stub() {
  cat >"${STUB_BIN}/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "rev-parse --verify --quiet HEAD^2")
    if [ "${FAKE_MERGE:-1}" = "1" ]; then
      printf '%s\n' "${FAKE_STAGING_SHA:-}"
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "${STUB_BIN}/git"
}

run_configure() {
  : >"${GH_CALL_LOG}"
  : >"${GH_BODY_LOG}"
  export DRY_RUN=0
  export PRODUCTION_REVIEWERS=""
  export GH_REPO="ibranibeny/GithubDay"
  run bash "${CONFIGURE_SCRIPT}"
}

# ruleset_bodies - the captured request bodies that are branch rulesets, one
# compact JSON document per line.
ruleset_bodies() {
  jq -c 'select(.target == "branch")' "${GH_BODY_LOG}"
}

# assert_all_rulesets <jq-condition> - fail unless every captured ruleset (at
# least the two expected) satisfies the condition.
assert_all_rulesets() {
  local condition="$1" total matched
  total="$(ruleset_bodies | jq -s 'length')"
  if [ "${total}" -lt 2 ]; then
    echo "expected at least 2 rulesets, captured ${total}" >&2
    return 1
  fi
  matched="$(ruleset_bodies | jq -c "select(${condition})" | jq -s 'length')"
  if [ "${matched}" -ne "${total}" ]; then
    echo "only ${matched}/${total} rulesets satisfied: ${condition}" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# staging-sha.sh: the production provenance gate
# ---------------------------------------------------------------------------

@test "staging-sha derives the tested commit from the merge's second parent" {
  export FAKE_MERGE=1
  export FAKE_STAGING_SHA="ec36640ec36640ec36640ec36640ec36640ec36"

  run bash "${STAGING_SHA_SCRIPT}"

  [ "$status" -eq 0 ]
  [ "$output" = "${FAKE_STAGING_SHA}" ]
}

@test "staging-sha refuses a squash or rebase (no second parent)" {
  export FAKE_MERGE=0

  run bash "${STAGING_SHA_SCRIPT}"

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "no second parent"
  echo "$output" | grep -qi "refusing to deploy"
}

# ---------------------------------------------------------------------------
# configure-github.sh: branch rulesets
# ---------------------------------------------------------------------------

@test "a branch ruleset is sent for staging and for main" {
  run_configure
  [ "$status" -eq 0 ]

  [ "$(ruleset_bodies | jq -s 'length')" -eq 2 ]
  ruleset_bodies | jq -e 'select(.conditions.ref_name.include[] == "refs/heads/staging")' >/dev/null
  ruleset_bodies | jq -e 'select(.conditions.ref_name.include[] == "refs/heads/main")' >/dev/null
}

@test "every ruleset requires a pull request before merging" {
  run_configure
  [ "$status" -eq 0 ]
  assert_all_rulesets 'any(.rules[]; .type == "pull_request")'
}

@test "every ruleset requires the four named CI status checks" {
  run_configure
  [ "$status" -eq 0 ]
  local check
  for check in frontend backend infrastructure container-build; do
    assert_all_rulesets "any(.rules[]; .type == \"required_status_checks\" and any(.parameters.required_status_checks[]; .context == \"${check}\"))"
  done
}

@test "every ruleset requires CodeQL results at high or higher" {
  run_configure
  [ "$status" -eq 0 ]
  assert_all_rulesets 'any(.rules[]; .type == "code_scanning" and any(.parameters.code_scanning_tools[]; .tool == "CodeQL" and .security_alerts_threshold == "high_or_higher"))'
}

@test "every ruleset requires a Copilot review" {
  run_configure
  [ "$status" -eq 0 ]
  assert_all_rulesets 'any(.rules[]; .type == "copilot_code_review")'
}

@test "every ruleset blocks branch deletion and force-pushes" {
  run_configure
  [ "$status" -eq 0 ]
  assert_all_rulesets '(any(.rules[]; .type == "deletion")) and (any(.rules[]; .type == "non_fast_forward"))'
}

@test "no ruleset requires linear history (promotion uses merge commits)" {
  run_configure
  [ "$status" -eq 0 ]
  assert_all_rulesets '(any(.rules[]; .type == "required_linear_history") | not)'
}

# ---------------------------------------------------------------------------
# configure-github.sh: merge settings
# ---------------------------------------------------------------------------

@test "merge settings keep merge commits and disable squash and rebase" {
  run_configure
  [ "$status" -eq 0 ]

  local body
  body="$(jq -c 'select(.allow_squash_merge != null)' "${GH_BODY_LOG}" | head -n1)"
  [ -n "$body" ]
  [ "$(jq -r '.allow_merge_commit' <<<"$body")" = "true" ]
  [ "$(jq -r '.allow_squash_merge' <<<"$body")" = "false" ]
  [ "$(jq -r '.allow_rebase_merge' <<<"$body")" = "false" ]
}
