#!/usr/bin/env bash
#
# Read .env and publish every variable it defines to the rest of the job.
#
# .env is committed, so it holds configuration only. Tokens are Actions secrets.
# A repository secret named REPOS overrides the committed repo list, which keeps
# the repo names out of a public repository.

set -euo pipefail

ENV_FILE="${ENV_FILE:-.env}"
[[ -f "$ENV_FILE" ]] || { printf 'ERROR: %s not found\n' "$ENV_FILE" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

if [[ -n "${REPOS_SECRET:-}" ]]; then
  REPOS="$REPOS_SECRET"
  printf 'Using the REPOS secret instead of the list in %s\n' "$ENV_FILE"
fi

# sed, not tr: tr -d '[:space:]' would eat the newlines and merge every key into one.
keys=$(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" \
       | sed -E 's/[[:space:]]//g; s/=$//' | sort -u)

printf 'Loaded configuration:\n'
for key in $keys; do
  value="${!key-}"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    # Heredoc form so multi-line values (REPOS) survive intact.
    {
      printf '%s<<__SYNC_ENV__\n' "$key"
      printf '%s\n' "$value"
      printf '__SYNC_ENV__\n'
    } >> "$GITHUB_ENV"
  fi
  printf '  %s=%s\n' "$key" "$(printf '%s' "$value" | tr '\n' ' ')"
done
