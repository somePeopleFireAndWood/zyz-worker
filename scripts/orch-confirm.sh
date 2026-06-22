#!/usr/bin/env bash
#
# orch-confirm.sh — mark a finished worker's master entry `state: completed`
# on explicit user confirmation, WITHOUT merging or cleaning up the worktree.
#
# This is the decoupled "done != merged" path: the user wrote `confirmed` in the
# master entry `## Pending Merge Approval` section to record delivery, but the
# task branch is NOT merged to base and the worktree is NOT removed. To merge,
# use orch-merge.sh separately; to clean up, use orch-cleanup-worker.sh (via the
# `cleanup-approved` token). The legacy combined path is orch-merge-and-cleanup.sh
# (the `approved` token).
#
# Contract:
#   Inputs:
#     $1  <task-id>           must match [A-Za-z0-9_-]+
#     $2  <list-dir>          master list directory
#
#   Side effects:
#     - Rewrites the master entry frontmatter `state:` to `completed` and bumps
#       `updated-at:` (tmpfile + rename). NO git, NO worktree cleanup.
#
#   Output (stdout):
#     confirm-status=success
#
#   Exit codes:
#     0   success
#     2   argument error / invalid task-id
#     4   master entry missing
#     10  `## Pending Merge Approval` does not contain `confirmed`
#
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <task-id> <list-dir>" >&2
}

if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi

TASK_ID="$1"
LIST_DIR="$2"

case "$TASK_ID" in
    ''|*[!A-Za-z0-9_-]*)
        echo "error: invalid task-id (must match [A-Za-z0-9_-]+): '$TASK_ID'" >&2
        exit 2
        ;;
esac

if [ -z "$LIST_DIR" ]; then
    usage
    exit 2
fi

MASTER_ENTRY="$LIST_DIR/tasks/$TASK_ID.md"
if [ ! -f "$MASTER_ENTRY" ] || [ ! -r "$MASTER_ENTRY" ]; then
    echo "error: master entry not found or unreadable: $MASTER_ENTRY" >&2
    exit 4
fi

# ---------------------------------------------------------------------------
# Step 1: preconditions — the `confirmed` token must be present.
# ---------------------------------------------------------------------------

# Check the body of the master entry for the literal `confirmed` token in the
# `## Pending Merge Approval` section. Word-ish boundaries mirror the `approved`
# scan in orch-merge-and-cleanup.sh; this never matches the `awaiting-confirmation`
# phase string (different word, and bounded by non-word chars).
CONFIRMED="false"
awk '
    BEGIN { in_section = 0 }
    /^## Pending Merge Approval[[:space:]]*$/ { in_section = 1; next }
    /^## / && in_section == 1 { in_section = 0 }
    in_section == 1 { print }
' "$MASTER_ENTRY" | grep -qE '(^|[^a-zA-Z0-9_])confirmed([^a-zA-Z0-9_]|$)' && CONFIRMED="true" || true

if [ "$CONFIRMED" != "true" ]; then
    echo "error: master entry has no 'confirmed' token in '## Pending Merge Approval': $MASTER_ENTRY" >&2
    exit 10
fi

# ---------------------------------------------------------------------------
# Step 2: write state=completed to the master entry frontmatter.
# Mirrors orch-merge-and-cleanup.sh step 3 (same in-frontmatter awk rewrite).
# No git, no cleanup.
# ---------------------------------------------------------------------------
NOW_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"
TMP_ENTRY="$MASTER_ENTRY.tmp.$$"
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

printf 'confirm-status=success\n'

exit 0
