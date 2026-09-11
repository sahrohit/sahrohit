#!/usr/bin/env bash
#
# Mirror one repo to the personal account with rewritten commit identities.
#
#   clone default branch -> rewrite identities -> verify -> force-push
#
# Every run starts from a fresh clone, so the pipeline is stateless. Because commit
# dates are preserved, the rewrite is deterministic and the push is a no-op when
# nothing changed upstream.
#
# Required env: SOURCE (owner/repo), NEW_NAME, NEW_EMAIL
# Optional env: TARGET, SOURCE_TOKEN, DEST_TOKEN, DRY_RUN, RESULT_FILE, SOURCE_OWNER,
#               DEST_OWNER, and the identity variables read by _prelude.py.
#               SOURCE_URL / DEST_URL override the GitHub remotes, for local testing.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- inputs -----------------------------------------------------------------

: "${SOURCE:?set SOURCE to owner/repo}"
: "${NEW_NAME:?set NEW_NAME}"
: "${NEW_EMAIL:?set NEW_EMAIL}"

SOURCE_OWNER="${SOURCE_OWNER}"
DEST_OWNER="${DEST_OWNER:-sahrohit}"
TARGET="${TARGET:-${DEST_OWNER}/${SOURCE##*/}}"
DRY_RUN="${DRY_RUN:-false}"

# Guard rails. A typo in repos.json must never push rewritten history into the org.
[[ "$SOURCE" == */* && "$SOURCE" != */*/* ]] || die "SOURCE must be owner/repo, got '$SOURCE'"
[[ "$TARGET" == */* && "$TARGET" != */*/* ]] || die "TARGET must be owner/repo, got '$TARGET'"
[[ "${SOURCE%%/*}" == "$SOURCE_OWNER" ]] || die "source owner is '${SOURCE%%/*}', expected '$SOURCE_OWNER'"
[[ "${TARGET%%/*}" == "$DEST_OWNER" ]]   || die "target owner is '${TARGET%%/*}', expected '$DEST_OWNER'"

# Resolve before the cd below: the script works inside a temp dir that is deleted
# on exit, so a relative RESULT_FILE would be written and then thrown away.
if [[ -n "${RESULT_FILE:-}" ]]; then
  mkdir -p "$(dirname "$RESULT_FILE")"
  RESULT_FILE="$(cd -- "$(dirname -- "$RESULT_FILE")" && pwd)/$(basename -- "$RESULT_FILE")"
fi

command -v git >/dev/null || die "git not found"
git filter-repo --version >/dev/null 2>&1 || die "git-filter-repo not found; pip install -r sync/requirements.txt"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log "$SOURCE -> $TARGET"

# --- 1. clone ---------------------------------------------------------------

if [[ -n "${SOURCE_URL:-}" ]]; then
  # Escape hatch for local testing against a path or a non-github remote.
  clone_url="$SOURCE_URL"
elif [[ -n "${SOURCE_TOKEN:-}" ]]; then
  clone_url="https://x-access-token:${SOURCE_TOKEN}@github.com/${SOURCE}.git"
else
  # No token: fall back to whatever credential helper the machine already has.
  clone_url="https://github.com/${SOURCE}.git"
fi

git clone --quiet --single-branch --no-tags "$clone_url" "$WORK/repo" \
  || die "clone of $SOURCE failed; check SOURCE_TOKEN access and SAML SSO authorization"
cd "$WORK/repo"
git remote set-url origin "https://github.com/${SOURCE}.git"   # keep the token out of .git/config

if ! git rev-parse --verify --quiet HEAD >/dev/null; then
  warn "$SOURCE has no commits on its default branch; nothing to sync"
  exit 0
fi

BRANCH=$(git symbolic-ref --short HEAD)
BEFORE_COUNT=$(git rev-list --count HEAD)
git log --format='%ad|%cd' --date=raw | sort > "$WORK/dates.before"
log "default branch '$BRANCH', $BEFORE_COUNT commits"

# --- 2. rewrite -------------------------------------------------------------

# Never prune: we change no file content, so the commit graph must map 1:1. Pinning
# this makes the count check below a real assertion rather than a coincidence.
# --preserve-commit-encoding keeps non-UTF-8 messages byte-identical; supported since
# well before the floor pinned in requirements.txt. Do not feature-probe it via --help,
# which prints a single line and would silently drop the flag.
log "rewriting identities"
git filter-repo --force --quiet \
  --prune-empty never --prune-degenerate never --preserve-commit-encoding \
  --commit-callback "$(cat "$SCRIPT_DIR/_prelude.py" "$SCRIPT_DIR/commit_callback.py")"

# --- 3. verify --------------------------------------------------------------

AFTER_COUNT=$(git rev-list --count HEAD)
git log --format='%ad|%cd' --date=raw | sort > "$WORK/dates.after"

[[ "$BEFORE_COUNT" == "$AFTER_COUNT" ]] \
  || die "commit count changed: $BEFORE_COUNT -> $AFTER_COUNT"
diff -q "$WORK/dates.before" "$WORK/dates.after" >/dev/null \
  || die "commit dates changed during the rewrite; refusing to push"
log "verified: $AFTER_COUNT commits, every author and commit date unchanged"

git log --format='%an%n%ae%n%cn%n%ce' | sort -u > "$WORK/identities"
git log --format='%B' > "$WORK/messages"      # dumped once; the loop below may be long

leaked=0
IFS=',' read -r -a forbidden <<< "${FORBIDDEN:-}"
for token in "${forbidden[@]}"; do
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"
  [[ -n "$token" ]] || continue

  if grep -iqF -- "$token" "$WORK/identities"; then
    printf 'still present in commit identities:\n' >&2
    grep -iF -- "$token" "$WORK/identities" | head -n 5 >&2
    leaked=1
  fi

  hits=$(grep -icF -- "$token" "$WORK/messages" || true)
  if [[ "$hits" -gt 0 ]]; then
    if [[ "${STRICT_MESSAGES:-false}" == "true" ]]; then
      printf "forbidden string '%s' appears in %s commit message lines\n" "$token" "$hits" >&2
      leaked=1
    else
      # Internal URLs and ticket references legitimately mention the domain, so this
      # is a warning by default. Set STRICT_MESSAGES=true to make it fatal.
      warn "'$token' appears in $hits commit message line(s), e.g. ticket or wiki URLs"
    fi
  fi
done
[[ "$leaked" -eq 0 ]] || die "leak check failed for $SOURCE; nothing was pushed"

# --- 4. push ----------------------------------------------------------------

SHA=$(git rev-parse HEAD)

if [[ "$DRY_RUN" == "true" ]]; then
  log "dry run: not pushing. Most recent commits after rewriting:"
  git log --date=iso --format='%h  %ad  %an <%ae>  |  %s' -n 20
  log "author roster after rewriting:"
  git log --format='%an <%ae>' | sort | uniq -c | sort -rn
  exit 0
fi

if [[ -n "${DEST_URL:-}" ]]; then
  # Escape hatch for local testing against a scratch bare repo.
  push_url="$DEST_URL"
else
  : "${DEST_TOKEN:?set DEST_TOKEN to a personal access token that can write to $DEST_OWNER}"
  push_url="https://x-access-token:${DEST_TOKEN}@github.com/${TARGET}.git"
fi
command -v gh >/dev/null || die "gh CLI not found; needed to create the destination repo"

if gh repo view "$TARGET" >/dev/null 2>&1; then
  log "destination $TARGET already exists"
else
  log "creating private repo $TARGET"
  gh repo create "$TARGET" --private \
    --description "Mirror of ${SOURCE}. History rewritten, do not commit here directly." >/dev/null
  gh api -X PATCH "repos/$TARGET" -F has_issues=false -F has_wiki=false -F has_projects=false \
    >/dev/null 2>&1 || warn "could not disable issues/wiki on $TARGET"
fi

log "pushing $BRANCH to $TARGET"
git remote add dest "$push_url"
git push --force --quiet dest "refs/heads/${BRANCH}:refs/heads/${BRANCH}"
git remote set-url dest "https://github.com/${TARGET}.git"
log "done: $TARGET@$BRANCH is at ${SHA:0:10} ($AFTER_COUNT commits)"

# --- 5. report --------------------------------------------------------------

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '| `%s` | `%s` | `%s` | %s | `%s` |\n' \
    "$SOURCE" "$TARGET" "$BRANCH" "$AFTER_COUNT" "${SHA:0:10}" >> "$GITHUB_STEP_SUMMARY"
fi

if [[ -n "${RESULT_FILE:-}" ]]; then
  cat > "$RESULT_FILE" <<JSON
{
  "source": "$SOURCE",
  "target": "$TARGET",
  "branch": "$BRANCH",
  "commits": $AFTER_COUNT,
  "head": "$SHA",
  "status": "ok"
}
JSON
fi
