#!/usr/bin/env bash
#
# orch-cleanup-worker.sh — kill a worker's tmux session, remove its git
# worktree, and archive its runtime directory.
#
# Contract:
#   Inputs:
#     $1  <task-id>           must match [A-Za-z0-9_-]+
#     $2  <list-dir>          master list directory
#     $3  --force (optional)  actually perform the destructive actions (default
#                             is a dry-run that prints what would be done)
#
#   Side effects (when --force):
#     - `tmux kill-session -t <tmux-session>` (also kills the in-pane heartbeat
#       daemon via SIGHUP).
#     - `git worktree remove <worktree>` (or `--force` variant when forced).
#     - Moves <list-dir>/runtime/<task-id>/ to
#       <list-dir>/runtime/.archive/<task-id>-<timestamp>/ to preserve audit.
#
#   Output (stdout):
#     cleanup-status=dry-run|success
#     tmux-killed=true|false|skipped
#     worktree-removed=true|false|skipped
#     runtime-archived=true|false|skipped
#     archive-path=<path-or-empty>
#
#   Exit codes:
#     0  success (including dry-run)
#     2  argument error / invalid task-id
#     3  missing dependency (tmux / git)
#     4  master entry missing
#     8  worktree is dirty and --force was not passed
#     9  tmux kill-session failed
#
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <task-id> <list-dir> [--force]" >&2
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    usage
    exit 2
fi

TASK_ID="$1"
LIST_DIR="$2"
FORCE="false"

if [ "$#" -eq 3 ]; then
    case "$3" in
        --force) FORCE="true" ;;
        *) usage; exit 2 ;;
    esac
fi

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

TMUX_SESSION="$(fm_field "$MASTER_ENTRY" tmux-session)"
[ -z "$TMUX_SESSION" ] && TMUX_SESSION="zyz-task-$TASK_ID"

WORKTREE="$(fm_field "$MASTER_ENTRY" worktree)"
case "$WORKTREE" in
    "~/"*) WORKTREE="$HOME/${WORKTREE#~/}" ;;
esac

RUNTIME_DIR="$LIST_DIR/runtime/$TASK_ID"

# Dry-run: report what would be done.
if [ "$FORCE" != "true" ]; then
    printf 'cleanup-status=dry-run\n'
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        printf 'tmux-killed=false\n'
        printf '# would: tmux kill-session -t %s\n' "$TMUX_SESSION"
    else
        printf 'tmux-killed=skipped\n'
    fi
    if [ -n "$WORKTREE" ] && [ -e "$WORKTREE" ]; then
        printf 'worktree-removed=false\n'
        printf '# would: git worktree remove %s\n' "$WORKTREE"
    else
        printf 'worktree-removed=skipped\n'
    fi
    if [ -d "$RUNTIME_DIR" ]; then
        printf 'runtime-archived=false\n'
        printf '# would: mv %s %s/runtime/.archive/%s-<timestamp>/\n' \
            "$RUNTIME_DIR" "$LIST_DIR" "$TASK_ID"
    else
        printf 'runtime-archived=skipped\n'
    fi
    printf 'archive-path=\n'
    exit 0
fi

# --force: actually perform the actions.
TMUX_KILLED="skipped"
WORKTREE_REMOVED="skipped"
RUNTIME_ARCHIVED="skipped"
ARCHIVE_PATH=""

# Kill tmux session if alive. Killing the session sends SIGHUP to all panes;
# the in-pane heartbeat daemon's trap handles SIGHUP and exits cleanly.
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    if tmux kill-session -t "$TMUX_SESSION" 2>/dev/null; then
        TMUX_KILLED="true"
    else
        echo "error: failed to kill tmux session: $TMUX_SESSION" >&2
        exit 9
    fi
fi

# Remove worktree.
if [ -n "$WORKTREE" ] && [ -e "$WORKTREE" ]; then
    # Probe dirtiness from inside the worktree.
    DIRTY="false"
    if porcelain="$(git -C "$WORKTREE" status --porcelain 2>/dev/null)"; then
        if [ -n "$porcelain" ]; then
            DIRTY="true"
        fi
    fi

    # Resolve the main repo so `git worktree remove` runs in a context that
    # can actually find the worktree registration. Without `-C <main-repo>`
    # this command silently fails when this helper is invoked from a cwd
    # that is not inside any git repo (e.g. the plugin root during T6
    # integration tests). See merge-and-cleanup.sh for the same pattern.
    COMMON_DIR="$(git -C "$WORKTREE" rev-parse --git-common-dir 2>/dev/null)"
    case "$COMMON_DIR" in
        /*) ;;
        *) COMMON_DIR="$(cd "$WORKTREE" && cd "$COMMON_DIR" && pwd)" ;;
    esac
    MAIN_REPO="$(dirname "$COMMON_DIR")"
    if [ -z "$MAIN_REPO" ] || [ ! -d "$MAIN_REPO" ]; then
        echo "error: cannot locate main repo checkout for worktree $WORKTREE" >&2
        exit 8
    fi

    # When --force is set, we still try to remove cleanly first; if the
    # worktree is dirty, `git worktree remove --force` is used. Let stderr
    # surface on failure — silently dropping it previously masked T6's
    # "worktree still present after cleanup" symptom.
    if [ "$DIRTY" = "true" ]; then
        # --force was explicitly given (we're in this branch), so use git's --force.
        if git -C "$MAIN_REPO" worktree remove --force "$WORKTREE" >/dev/null; then
            WORKTREE_REMOVED="true"
        else
            echo "error: failed to git worktree remove --force $WORKTREE (main repo: $MAIN_REPO)" >&2
            exit 8
        fi
    else
        if git -C "$MAIN_REPO" worktree remove "$WORKTREE" >/dev/null; then
            WORKTREE_REMOVED="true"
        else
            echo "error: failed to git worktree remove $WORKTREE (main repo: $MAIN_REPO)" >&2
            exit 8
        fi
    fi
fi

# Archive runtime dir.
if [ -d "$RUNTIME_DIR" ]; then
    TS="$(date +%Y%m%d-%H%M%S)"
    ARCHIVE_DIR="$LIST_DIR/runtime/.archive"
    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE_PATH="$ARCHIVE_DIR/$TASK_ID-$TS"
    mv "$RUNTIME_DIR" "$ARCHIVE_PATH"
    RUNTIME_ARCHIVED="true"
fi

printf 'cleanup-status=success\n'
printf 'tmux-killed=%s\n' "$TMUX_KILLED"
printf 'worktree-removed=%s\n' "$WORKTREE_REMOVED"
printf 'runtime-archived=%s\n' "$RUNTIME_ARCHIVED"
printf 'archive-path=%s\n' "$ARCHIVE_PATH"

exit 0
