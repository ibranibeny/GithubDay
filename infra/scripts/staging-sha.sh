#!/usr/bin/env bash
#
# staging-sha.sh - print the tested staging commit that a merge into `main`
# promoted, and refuse when there is none.
#
# Production is promoted from staging by a MERGE commit. Squash and rebase
# merges are disabled on this repository (configure-github.sh enforces it)
# precisely so this stays true: the second parent of the head of `main` is the
# staging commit that deploy-staging.yml already built, deployed and verified.
# deploy-production.yml deploys the EXACT images that commit produced - it never
# rebuilds - so it has to resolve that commit deterministically.
#
#   staging_sha="$(bash infra/scripts/staging-sha.sh)"          # <HEAD>^2
#   staging_sha="$(bash infra/scripts/staging-sha.sh <commit>)" # <commit>^2
#
# A commit with no second parent is a squash, a rebase or a direct push. None of
# those carry a tested staging commit, so the script fails and the production
# deployment refuses to run rather than shipping un-promoted bytes.
#
# stdout is the commit sha and nothing else; every message goes to stderr, so a
# "$(...)" capture always yields a clean value.

set -Eeuo pipefail

# staging_sha_from <commit-ish> - echo the second parent of <commit-ish>, or
# fail when it has none.
staging_sha_from() {
  local ref="${1:-HEAD}" parent=""

  # --verify --quiet resolves exactly one object and stays silent on failure, so
  # a non-merge commit (no `^2`) returns non-zero here instead of printing a git
  # error, and this function - not git - decides what that means.
  if ! parent="$(git rev-parse --verify --quiet "${ref}^2" 2>/dev/null)"; then
    printf 'refusing to deploy: %s is not a merge commit (no second parent)\n' "$ref" >&2
    printf 'production is promoted only by a staging->main merge commit; a squash, rebase or direct push carries no tested staging commit\n' >&2
    return 1
  fi

  printf '%s' "$parent"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  staging_sha_from "${1:-HEAD}"
fi
