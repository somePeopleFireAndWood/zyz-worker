#!/usr/bin/env bash
#
# orch-merge-and-cleanup.sh — merge a finished worker's branch into the base
# branch, mark the master entry completed, push, and clean up the worktree.
#
# Order (critical — see design-spec §E.6):
#
#   1. preconditions
#   2. merge        (gh pr merge --merge, OR fall back to local `git merge --no-ff`)
#   3. write `state: completed` into master entry frontmatter
#   4. push
#   5. cleanup (calls orch-cleanup-worker.sh --force)
#
# Step 3 must happen AFTER step 2 succeeds and BEFORE steps 4–5, so that if
# anything later crashes the user can re-run the script idempotently and
# recover from the documented intermediate state.
#
# Contract:
#   Inputs:
#     $1  <task-id>           must match [A-Za-z0-9_-]+
#     $2  <list-dir>          master list directory
#     $3  <base-branch>       merge target (e.g. main)
#
#   Side effects:
#     See above.
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
#     10  `## Pending Merge Approval` does not contain `approved`
#     11  worker worktree is dirty
#     12  merge conflict (state UNCHANGED, no push, no cleanup)
#     13  push failed (state already written `completed`; user can retry)
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

# Check the body of the master entry for the literal `approved` token in the
# `## Pending Merge Approval` section.
APPROVED="false"
awk '
    BEGIN { in_section = 0 }
    /^## Pending Merge Approval[[:space:]]*$/ { in_section = 1; next }
    /^## / && in_section == 1 { in_section = 0 }
    in_section == 1 { print }
' "$MASTER_ENTRY" | grep -qE '(^|[^a-zA-Z0-9_])approved([^a-zA-Z0-9_]|$)' && APPROVED="true" || true

if [ "$APPROVED" != "true" ]; then
    echo "error: master entry has no 'approved' token in '## Pending Merge Approval': $MASTER_ENTRY" >&2
    exit 10
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

# Identify the "main" repo (we cannot do git operations against the worktree's
# branch *into* the same worktree, so use the worktree's git common-dir to
# locate the main checkout).
COMMON_DIR="$(git -C "$WORKTREE" rev-parse --git-common-dir 2>/dev/null)"
# `git-common-dir` typically returns `<main-repo>/.git`; the main checkout is
# its parent. When the common dir is a relative path, resolve it against the
# worktree.
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
        # Push may legitimately fail (e.g. upstream rejects or auth); fall through.
        :
    fi
    if gh_out="$(gh pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "$TASK_ID" --body "Auto-created by orchestrator for task $TASK_ID" 2>"$gh_stderr")"; then
        # gh emits the URL on stdout.
        PR_URL="$(printf '%s\n' "$gh_out" | grep -Eo 'https://[^[:space:]]+' | tail -n1 || true)"
        if gh pr merge "$BRANCH" --merge 2>>"$gh_stderr"; then
            MERGE_OK="true"
        fi
    fi

    if [ "$MERGE_OK" != "true" ]; then
        # Inspect stderr for auth failure → fall back; otherwise treat as a
        # conflict (or transient gh error). We use a permissive auth pattern:
        # case-insensitive match on auth / unauthenticated / not logged in.
        gh_err_lc="$(LC_ALL=C tr '[:upper:]' '[:lower:]' < "$gh_stderr" 2>/dev/null || true)"
        if printf '%s' "$gh_err_lc" | grep -Eq 'auth|unauthenticated|not logged in'; then
            GH_FALLBACK="true"
            # Drop PR URL — local merge has no PR.
            PR_URL=""
        else
            # Non-auth gh failure: surface as merge conflict (or "unknown gh failure").
            # Be conservative — bail at exit 12 so the user resolves manually.
            rm -f "$gh_stderr"
            echo "error: gh merge failed without auth-error indicator; treating as merge conflict" >&2
            exit 12
        fi
    fi
    rm -f "$gh_stderr"
fi

# Fallback / no-gh path: local `git merge --no-ff`.
if [ "$MERGE_OK" != "true" ]; then
    # Ensure the main repo is on the base branch before merging.
    if ! git -C "$MAIN_REPO" checkout "$BASE_BRANCH" >/dev/null 2>&1; then
        echo "error: failed to checkout $BASE_BRANCH in $MAIN_REPO" >&2
        exit 11
    fi
    if git -C "$MAIN_REPO" merge --no-ff "$BRANCH" >/dev/null 2>&1; then
        MERGE_OK="true"
    else
        # Abort the in-progress merge so the repo is left in a sane state.
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
# Step 3: write state=completed to the master entry frontmatter.
# This MUST happen before push / cleanup so the user can recover from any
# subsequent failure (which would otherwise leave the merge done but state
# never advanced).
# ---------------------------------------------------------------------------
NOW_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"
TMP_ENTRY="$MASTER_ENTRY.tmp.$$"
# In-frontmatter rewrite: replace the `state:` and `updated-at:` lines.
awk -v now="$NOW_ISO" '
    BEGIN { in_fm = 0; fence = 0; saw_state = 0; saw_updated = 0 }
    /^---[[:space:]]*$/ {
        fence++
        if (fence == 1) { in_fm = 1; print; next }
        if (fence == 2) {
            # Insert any missing keys before closing the frontmatter.
            if (saw_state == 0) { print "state: completed" }
            if (saw_updated == 0) { print "updated-at: " now }
            in_fm = 0
            print; next
        }
    }
    in_fm == 1 {
        if (match($0, "^[[:space:]]*state[[:space:]]*:")) {
            print "state: completed"
            saw_state = 1
            next
        }
        if (match($0, "^[[:space:]]*updated-at[[:space:]]*:")) {
            print "updated-at: " now
            saw_updated = 1
            next
        }
    }
    { print }
' "$MASTER_ENTRY" > "$TMP_ENTRY"
mv -f "$TMP_ENTRY" "$MASTER_ENTRY"

# ---------------------------------------------------------------------------
# Step 4: push (only if origin exists).
# ---------------------------------------------------------------------------
if [ "$HAS_ORIGIN" = "true" ]; then
    if ! git -C "$MAIN_REPO" push origin "$BASE_BRANCH" >/dev/null 2>&1; then
        echo "warning: push of $BASE_BRANCH failed; state already written completed; you can retry by re-running this script" >&2
        # state is completed; do not cleanup.
        printf 'merge-status=push-failed\n'
        printf 'pr-url=%s\n' "$PR_URL"
        printf 'gh-fallback=%s\n' "$GH_FALLBACK"
        exit 13
    fi
fi

# ---------------------------------------------------------------------------
# Step 5: cleanup via orch-cleanup-worker.sh --force.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/orch-cleanup-worker.sh"
if [ -x "$CLEANUP_SCRIPT" ]; then
    # Cleanup errors do not undo the merge; surface them but still report success.
    "$CLEANUP_SCRIPT" "$TASK_ID" "$LIST_DIR" --force >/dev/null 2>&1 || \
        echo "warning: cleanup helper reported a failure; manual cleanup may be required" >&2
fi

printf 'merge-status=success\n'
printf 'pr-url=%s\n' "$PR_URL"
printf 'gh-fallback=%s\n' "$GH_FALLBACK"

exit 0
