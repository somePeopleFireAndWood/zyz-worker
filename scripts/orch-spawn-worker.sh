#!/usr/bin/env bash
#
# orch-spawn-worker.sh — create the worktree + tmux session + in-pane heartbeat
# daemon for a single task. Does NOT execute the task; the worker (claude +
# /execute-task) is expected to be started by the user inside the tmux pane,
# unless --auto-start is passed.
#
# Contract:
#   Inputs:
#     $1  <task-id>               must match [A-Za-z0-9_-]+
#     $2  <list-dir>              master list directory
#     $3  --auto-start (optional) auto-type `claude` + `/execute-task` into the pane
#                                 (alternatively, set $ZYZ_AUTO_START_WORKER=1)
#
#   Side effects:
#     - Reads <list-dir>/tasks/<task-id>.md frontmatter.
#     - Creates <list-dir>/runtime/<task-id>/.
#     - Writes an initial <list-dir>/runtime/<task-id>/worker-status.md.
#     - `git worktree add <worktree> -b <branch> <base>` (creates the branch).
#     - `tmux new-session -d -s <tmux-session> -c <worktree>` (creates the session).
#     - Sends an in-pane background command to start the heartbeat daemon.
#     - Sends env-var exports into the pane.
#     - If --auto-start: types `claude --plugin-dir <plugin-root>` and a follow-up
#       `/execute-task <task-id>`.
#
#   Output (stdout):
#     session-name=<tmux-session>
#     worktree=<worktree>
#     auto-start=true|false
#
#   Exit codes:
#     0  success
#     2  argument error / invalid task-id
#     3  missing dependency (tmux / git)
#     4  <list-dir>/tasks/<task-id>.md missing or unreadable
#     5  worktree path conflict OR runtime dir conflict
#     6  tmux session name conflict
#     7  `git worktree add` failed
#
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <task-id> <list-dir> [--auto-start]" >&2
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    usage
    exit 2
fi

TASK_ID="$1"
LIST_DIR="$2"
AUTO_START="false"

if [ "$#" -eq 3 ]; then
    case "$3" in
        --auto-start) AUTO_START="true" ;;
        *) usage; exit 2 ;;
    esac
fi

# Environment-variable override.
if [ "${ZYZ_AUTO_START_WORKER:-0}" = "1" ]; then
    AUTO_START="true"
fi

# task-id whitelist.
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

# Dependencies.
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

# Frontmatter field extractor (same logic as the other helpers).
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

# Read frontmatter; apply defaults.
PROJECT="$(fm_field "$MASTER_ENTRY" project)"
[ -z "$PROJECT" ] && PROJECT="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"

BRANCH="$(fm_field "$MASTER_ENTRY" branch)"
[ -z "$BRANCH" ] && BRANCH="task/$TASK_ID"

BASE="$(fm_field "$MASTER_ENTRY" base)"
[ -z "$BASE" ] && BASE="main"

WORKTREE="$(fm_field "$MASTER_ENTRY" worktree)"
if [ -z "$WORKTREE" ]; then
    WORKTREE="$HOME/.zyz-worker/worktrees/$PROJECT/$BRANCH"
fi
# Expand a leading `~/` if present.
case "$WORKTREE" in
    "~/"*) WORKTREE="$HOME/${WORKTREE#~/}" ;;
esac

TMUX_SESSION="$(fm_field "$MASTER_ENTRY" tmux-session)"
[ -z "$TMUX_SESSION" ] && TMUX_SESSION="zyz-task-$TASK_ID"

# Runtime files.
RUNTIME_DIR="$LIST_DIR/runtime/$TASK_ID"
WORKER_STATUS_FILE="$RUNTIME_DIR/worker-status.md"
HEARTBEAT_FILE="$RUNTIME_DIR/heartbeat"
QUESTION_FILE="$RUNTIME_DIR/question.md"
ANSWER_FILE="$RUNTIME_DIR/answer.md"

# Step 3: cross-list / cross-source collision checks.
# - tmux session must not exist
# - worktree path must not exist
# - runtime dir must not exist
# - any other list's runtime/<task-id>/ must not exist (cross-list collision)

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "error: tmux session already exists: $TMUX_SESSION" >&2
    exit 6
fi

if [ -e "$WORKTREE" ]; then
    echo "error: worktree path already exists: $WORKTREE" >&2
    exit 5
fi

if [ -e "$RUNTIME_DIR" ]; then
    echo "error: runtime dir already exists: $RUNTIME_DIR" >&2
    exit 5
fi

# Cross-list collision check: scan sibling directories of <list-dir> for any
# orchestration dir that already has runtime/<task-id>/.
LIST_PARENT="$(cd "$LIST_DIR/.." 2>/dev/null && pwd || true)"
LIST_BASE="$(basename "$LIST_DIR")"
if [ -n "$LIST_PARENT" ] && [ -d "$LIST_PARENT" ]; then
    for other in "$LIST_PARENT"/*/; do
        [ -d "$other" ] || continue
        other_base="$(basename "$other")"
        [ "$other_base" = "$LIST_BASE" ] && continue
        if [ -e "${other}runtime/$TASK_ID" ]; then
            echo "error: task-id collision in another list: ${other}runtime/$TASK_ID" >&2
            exit 5
        fi
    done
fi

# Step 4: create the worktree.
mkdir -p "$(dirname "$WORKTREE")"
if ! git worktree add "$WORKTREE" -b "$BRANCH" "$BASE" >/dev/null 2>&1; then
    # Try again without -b (branch may already exist locally).
    if ! git worktree add "$WORKTREE" "$BRANCH" >/dev/null 2>&1; then
        echo "error: git worktree add failed (branch=$BRANCH base=$BASE target=$WORKTREE)" >&2
        exit 7
    fi
fi

# Step 5: create the runtime dir.
mkdir -p "$RUNTIME_DIR"

# Step 6: write initial worker-status.md (atomic).
NOW_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"
TMP_STATUS="$WORKER_STATUS_FILE.tmp.$$"
cat > "$TMP_STATUS" <<EOF
---
task-id: $TASK_ID
phase: design
phase-since: $NOW_ISO
wait-state: none
waiting-reason:
expected-resume-by:
last-flush: $NOW_ISO
---

# Worker Status

## Current Activity

(initialized by orchestrator; awaiting worker start)

## Last Output Summary

(none yet)

## Next Action

Start the worker: attach to tmux session $TMUX_SESSION, then run claude + /execute-task.
EOF
mv -f "$TMP_STATUS" "$WORKER_STATUS_FILE"

# Step 7: create the tmux session (detached). This MUST come before launching
# the heartbeat daemon — the daemon must live inside the pane's process group
# so the pane's death sends SIGHUP and tears the daemon down.
if ! tmux new-session -d -s "$TMUX_SESSION" -c "$WORKTREE" 2>/dev/null; then
    echo "error: failed to create tmux session: $TMUX_SESSION" >&2
    exit 6
fi

# Resolve where this script lives, so we can address sibling helpers by
# absolute path even when the user invokes us from a different cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_SCRIPT="$SCRIPT_DIR/orch-heartbeat-daemon.sh"

# Step 8: start the heartbeat daemon INSIDE the tmux pane via `send-keys`.
# `... &` puts it in the background of the pane's shell.
#
# Critical: do NOT wrap the daemon in `nohup` — `nohup` makes the daemon
# immune to SIGHUP, which is exactly the signal we want to propagate when
# the pane / session dies. On macOS bash, `shopt -s huponexit` is off by
# default so background children may not receive SIGHUP from the shell on
# exit either; therefore the daemon ALSO actively watchdogs the tmux
# session via `tmux has-session` (see orch-heartbeat-daemon.sh). We pass
# the session name through the `ZYZ_TMUX_SESSION` env var.
tmux send-keys -t "$TMUX_SESSION" \
    "ZYZ_TMUX_SESSION='$TMUX_SESSION' '$DAEMON_SCRIPT' '$HEARTBEAT_FILE' 30 >/dev/null 2>&1 &" Enter

# Step 9: export env vars into the pane so the worker (claude + execute-task)
# sees them when started.
tmux send-keys -t "$TMUX_SESSION" \
    "export ZYZ_WORKER_STATUS_FILE='$WORKER_STATUS_FILE' ZYZ_TASK_ID='$TASK_ID' ZYZ_QUESTION_FILE='$QUESTION_FILE' ZYZ_ANSWER_FILE='$ANSWER_FILE' ZYZ_HEARTBEAT_FILE='$HEARTBEAT_FILE'" \
    Enter

# Step 10: optionally auto-start claude + /execute-task. Default OFF.
if [ "$AUTO_START" = "true" ]; then
    PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
    if [ -n "$PLUGIN_ROOT" ]; then
        tmux send-keys -t "$TMUX_SESSION" "claude --plugin-dir '$PLUGIN_ROOT'" Enter
    else
        tmux send-keys -t "$TMUX_SESSION" "claude" Enter
    fi
    # Allow claude to settle before typing the slash command.
    sleep 2 || true
    tmux send-keys -t "$TMUX_SESSION" "/execute-task $TASK_ID" Enter
fi

# Step 11: stdout report.
printf 'session-name=%s\n' "$TMUX_SESSION"
printf 'worktree=%s\n' "$WORKTREE"
printf 'auto-start=%s\n' "$AUTO_START"

exit 0
