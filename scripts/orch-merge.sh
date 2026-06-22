#!/usr/bin/env bash
#
# orch-merge.sh — merge a finished worker's branch into the base branch and
# push, WITHOUT marking the master entry completed and WITHOUT cleaning up the
# worktree.
#
# This is the decoupled "merge only" path: the user wrote `merge` (or
# `merge: <base>`) in the master entry `## Pending Merge Approval` section to
# merge the task branch to base, but delivery is recorded separately (the
# `confirmed` token / orch-confirm.sh writes `state: completed`) and the worktree
# is removed separately (`cleanup-approved` / orch-cleanup-worker.sh). The legacy
# combined path is orch-merge-and-cleanup.sh (the `approved` token).
#
# Order (mirrors orch-merge-and-cleanup.sh, minus the state write and cleanup):
#
#   1. preconditions (`merge` token present; worktree clean; repo locatable)
#   2. merge        (gh pr merge --merge, OR fall back to local `git merge --no-ff`)
#   3. push         (only if origin exists)
#
# Contract:
#   Inputs:
#     $1  <task-id>           must match [A-Za-z0-9_-]+
#     $2  <list-dir>          master list directory
#     $3  <base-branch>       merge target (e.g. main); a base in the `merge:`
#                             token overrides this argument
#
#   Side effects:
#     - Merges <branch> into <base-branch> in the main checkout.
#     - Pushes <base-branch> to origin if origin is configured.
#     - Does NOT write `state:`; does NOT clean up the worktree.
#
#   Output (stdout):
#     merge-status=success
#     pr-url=<url-or-empty>
#     gh-fallback=true|false
#
#   Exit codes:
#     0   success
#     2   argument error / invalid task-id
#     3   missing dependency (git)
#     4   master entry missing
#     10  `## Pending Merge Approval` does not contain `merge`
#     11  worker worktree is dirty / repo not found
#     12  merge conflict (state UNCHANGED, no push)
#     13  push failed (merge already done; user can retry)
#
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <task-id> <list-dir> <base-branch>" >&2
}

if [ "$#" -ne 3 ]; then
    usage
    exit 2
fi

TASK_ID="$1"
LIST_DIR="$2"
BASE_BRANCH="$3"

case "$TASK_ID" in
    ''|*[!A-Za-z0-9_-]*)
        echo "error: invalid task-id (must match [A-Za-z0-9_-]+): '$TASK_ID'" >&2
        exit 2
        ;;
esac

if [ -z "$LIST_DIR" ] || [ -z "$BASE_BRANCH" ]; then
    usage
    exit 2
fi

# Dependency check (design §E top: every helper must `command -v tmux git`).
for dep in tmux git; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "error: missing dependency: $dep" >&2
        exit 3
    fi
done

MASTER_ENTRY="$LIST_DIR/tasks/$TASK_ID.md"
if [ ! -f "$MASTER_ENTRY" ] || [ ! -r "$MASTER_ENTRY" ]; then
    echo "error: master entry not found or unreadable: $MASTER_ENTRY" >&2
    exit 4
fi

fm_field() {
    local file="$1"
    local key="$2"
    awk -v k="$key" '
        BEGIN { in_fm = 0; fence = 0 }
        /^---[[:space:]]*$/ {
            fence++
            if (fence == 1) { in_fm = 1; next }
            if (fence == 2) { exit }
        }
        in_fm == 1 {
            if (match($0, "^[[:space:]]*" k "[[:space:]]*:")) {
                v = substr($0, RSTART + RLENGTH)
                sub(/^[[:space:]]+/, "", v)
                sub(/[[:space:]]+$/, "", v)
                sub(/[[:space:]]+#.*$/, "", v)
                if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2) }
                else if (v ~ /^'\''.*'\''$/) { v = substr(v, 2, length(v) - 2) }
                print v
                exit
            }
        }
    ' "$file"
}

BRANCH="$(fm_field "$MASTER_ENTRY" branch)"
[ -z "$BRANCH" ] && BRANCH="task/$TASK_ID"

WORKTREE="$(fm_field "$MASTER_ENTRY" worktree)"
case "$WORKTREE" in
    "~/"*) WORKTREE="$HOME/${WORKTREE#"~/"}" ;;
esac

# ---------------------------------------------------------------------------
# Step 1: preconditions
# ---------------------------------------------------------------------------

# Scan the `## Pending Merge Approval` section for a `merge` token. Accept both
# the bare `merge` form and `merge: <base>` (where the base overrides $3). The
# `confirmed` token must NOT satisfy this check, and the `awaiting-confirmation`
# phase string must never match — `merge` is bounded by non-word chars below.
SECTION="$(awk '
    BEGIN { in_section = 0 }
    /^## Pending Merge Approval[[:space:]]*$/ { in_section = 1; next }
    /^## / && in_section == 1 { in_section = 0 }
    in_section == 1 { print }
' "$MASTER_ENTRY")"

MERGE_TOKEN="false"
if printf '%s\n' "$SECTION" | grep -qE '(^|[^a-zA-Z0-9_-])merge([^a-zA-Z0-9_-]|$)'; then
    MERGE_TOKEN="true"
fi

if [ "$MERGE_TOKEN" != "true" ]; then
    echo "error: master entry has no 'merge' token in '## Pending Merge Approval': $MASTER_ENTRY" >&2
    exit 10
fi

# If the token carries an explicit base (`merge: <base>`), it overrides $3.
# The `|| true` guards against `set -o pipefail` aborting when the bare `merge`
# token (no `: <base>`) yields no grep match.
TOKEN_BASE="$( { printf '%s\n' "$SECTION" \
    | grep -oE '(^|[^a-zA-Z0-9_-])merge[[:space:]]*:[[:space:]]*[^[:space:]]+' \
    | head -n1 \
    | sed -E 's/.*merge[[:space:]]*:[[:space:]]*//'; } || true)"
if [ -n "$TOKEN_BASE" ]; then
    BASE_BRANCH="$TOKEN_BASE"
fi

if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
    echo "error: worktree path missing or invalid: $WORKTREE" >&2
    exit 11
fi

# Worktree must be clean.
if porcelain="$(git -C "$WORKTREE" status --porcelain 2>/dev/null)"; then
    if [ -n "$porcelain" ]; then
        echo "error: worktree is dirty: $WORKTREE" >&2
        exit 11
    fi
else
    echo "error: cannot read git status in $WORKTREE" >&2
    exit 11
fi

# ---------------------------------------------------------------------------
# Step 2: merge
# ---------------------------------------------------------------------------

# Locate the main checkout via the worktree's git common-dir (same approach as
# orch-merge-and-cleanup.sh — we cannot merge a branch into the worktree that has
# it checked out).
COMMON_DIR="$(git -C "$WORKTREE" rev-parse --git-common-dir 2>/dev/null)"
if [ -n "$COMMON_DIR" ]; then
    case "$COMMON_DIR" in
        /*) ;;
        *) COMMON_DIR="$(cd "$WORKTREE" && cd "$COMMON_DIR" && pwd)" ;;
    esac
    MAIN_REPO="$(dirname "$COMMON_DIR")"
else
    MAIN_REPO=""
fi

if [ -z "$MAIN_REPO" ] || [ ! -d "$MAIN_REPO" ]; then
    echo "error: cannot locate main repo checkout for worktree $WORKTREE" >&2
    exit 11
fi

PR_URL=""
GH_FALLBACK="false"
MERGE_OK="false"

# Decide whether origin exists.
HAS_ORIGIN="false"
if git -C "$MAIN_REPO" remote get-url origin >/dev/null 2>&1; then
    HAS_ORIGIN="true"
fi

if command -v gh >/dev/null 2>&1 && [ "$HAS_ORIGIN" = "true" ]; then
    # Try gh first.
    gh_stderr="$(mktemp -t gh.XXXXXX 2>/dev/null || echo "/tmp/gh.$$")"
    # Push the branch so gh has something to PR against.
    if git -C "$MAIN_REPO" push origin "$BRANCH" >/dev/null 2>"$gh_stderr"; then
        :
    else
        :
    fi
    if gh_out="$(gh pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "$TASK_ID" --body "Auto-created by orchestrator for task $TASK_ID" 2>"$gh_stderr")"; then
        PR_URL="$(printf '%s\n' "$gh_out" | grep -Eo 'https://[^[:space:]]+' | tail -n1 || true)"
        if gh pr merge "$BRANCH" --merge 2>>"$gh_stderr"; then
            MERGE_OK="true"
        fi
    fi

    if [ "$MERGE_OK" != "true" ]; then
        gh_err_lc="$(LC_ALL=C tr '[:upper:]' '[:lower:]' < "$gh_stderr" 2>/dev/null || true)"
        if printf '%s' "$gh_err_lc" | grep -Eq 'auth|unauthenticated|not logged in'; then
            GH_FALLBACK="true"
            PR_URL=""
        else
            rm -f "$gh_stderr"
            echo "error: gh merge failed without auth-error indicator; treating as merge conflict" >&2
            exit 12
        fi
    fi
    rm -f "$gh_stderr"
fi

# Fallback / no-gh path: local `git merge --no-ff`.
if [ "$MERGE_OK" != "true" ]; then
    if ! git -C "$MAIN_REPO" checkout "$BASE_BRANCH" >/dev/null 2>&1; then
        echo "error: failed to checkout $BASE_BRANCH in $MAIN_REPO" >&2
        exit 11
    fi
    if git -C "$MAIN_REPO" merge --no-ff "$BRANCH" >/dev/null 2>&1; then
        MERGE_OK="true"
    else
        git -C "$MAIN_REPO" merge --abort >/dev/null 2>&1 || true
        echo "error: local merge conflict between $BRANCH and $BASE_BRANCH" >&2
        exit 12
    fi
fi

if [ "$MERGE_OK" != "true" ]; then
    echo "error: merge did not complete" >&2
    exit 12
fi

# ---------------------------------------------------------------------------
# Step 3: push (only if origin exists). NO state write, NO cleanup.
# ---------------------------------------------------------------------------
if [ "$HAS_ORIGIN" = "true" ]; then
    if ! git -C "$MAIN_REPO" push origin "$BASE_BRANCH" >/dev/null 2>&1; then
        echo "warning: push of $BASE_BRANCH failed; merge already done; you can retry by re-running this script" >&2
        printf 'merge-status=push-failed\n'
        printf 'pr-url=%s\n' "$PR_URL"
        printf 'gh-fallback=%s\n' "$GH_FALLBACK"
        exit 13
    fi
fi

printf 'merge-status=success\n'
printf 'pr-url=%s\n' "$PR_URL"
printf 'gh-fallback=%s\n' "$GH_FALLBACK"

exit 0
