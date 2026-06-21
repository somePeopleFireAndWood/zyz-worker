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
#     source-repo=<expanded-absolute-path>
#
#   Exit codes:
#     0  success
#     2  argument error / invalid task-id
#     3  missing dependency (tmux / git)
#     4  <list-dir>/tasks/<task-id>.md missing or unreadable
#     5  worktree path conflict OR runtime dir conflict OR source-repo
#        missing / non-absolute / non-existent / not a git work tree
#     6  tmux session name conflict
#     7  `git worktree add` failed
#
#   Exit-code precedence (evaluated in this order):
#     2  argv shape / task-id charset
#     4  master entry file missing
#     5  source-repo missing / invalid (validated before tmux/git)
#     3  tmux / git not on PATH
#     5/6/7  remaining collision / git-worktree-add checks
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

# source-repo validation. Runs BEFORE the tmux/git dependency check so that
# the negative spawn cases (T4' in scripts/test-orchestration-helpers.sh)
# fire even on hosts without tmux. The order matters: argv (2) → master
# entry missing (4) → source-repo invalid (5) → tmux/git missing (3) →
# rest.
SOURCE_REPO="$(fm_field "$MASTER_ENTRY" source-repo)"
if [ -z "$SOURCE_REPO" ]; then
    echo "error: master entry has no source-repo field: $MASTER_ENTRY" >&2
    exit 5
fi
# Expand a leading `~/` if present (bash does not expand ~ inside a
# variable). The `~/` pattern MUST be quoted inside ${…#PAT} — otherwise
# bash treats the leading `~` as the tilde-expansion metachar and the
# strip silently becomes a no-op, leaving e.g. `$HOME/~/workspace/...`
# which then fails the path-existence check below.
case "$SOURCE_REPO" in
    "~/"*) SOURCE_REPO="$HOME/${SOURCE_REPO#"~/"}" ;;
esac
# After expansion, the path must be absolute. Reject everything that is
# neither `/...` nor a `~/...` that just got expanded. (`~` alone with no
# trailing `/` also lands here — see §Important Details > Quoting and `~`.)
case "$SOURCE_REPO" in
    /*) : ;;
    *)
        echo "error: source-repo must be an absolute path or start with ~/: $SOURCE_REPO" >&2
        exit 5
        ;;
esac
if [ ! -e "$SOURCE_REPO" ]; then
    echo "error: source-repo path does not exist: $SOURCE_REPO" >&2
    exit 5
fi
if ! git -C "$SOURCE_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: source-repo is not a git work tree: $SOURCE_REPO" >&2
    exit 5
fi

# Dependencies. Checked AFTER source-repo so the source-repo negative
# tests fire even when tmux is absent. (Note: the source-repo git
# rev-parse above requires `git`; if `git` is missing it will fall
# through to the rev-parse failure branch above and exit 5 with the
# "not a git work tree" message — that is acceptable because no host
# realistically has `git` missing.)
for dep in tmux git; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "error: missing dependency: $dep" >&2
        exit 3
    fi
done

# Resolve where this script lives, so we can address sibling helpers by
# absolute path even when the user invokes us from a different cwd. Hoisted
# above PLUGIN_ROOT (which derives from $SCRIPT_DIR/..) and the dispatch.md
# Phase-1 write.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the plugin root (hoisted to top-level so both the auto-start
# `claude --plugin-dir` launch AND the dispatch.md Phase-1 write can record
# it). The warn-only sanity check now fires on every spawn — a missing
# skills/execute-task directory is a misconfiguration regardless of how the
# worker is started (auto-start vs. manual). We only warn (not exit) because
# a heterogenous install layout could legitimately put skills elsewhere; the
# run-report's Unknown-command failure will still be caught downstream by the
# §4e check during auto-start.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
if [ ! -d "$PLUGIN_ROOT/skills/execute-task" ]; then
    echo "warn: PLUGIN_ROOT=$PLUGIN_ROOT does not contain skills/execute-task" >&2
fi

# Read frontmatter; apply defaults.
PROJECT="$(fm_field "$MASTER_ENTRY" project)"
PROJECT="${PROJECT:-$(basename "$SOURCE_REPO")}"

BRANCH="$(fm_field "$MASTER_ENTRY" branch)"
[ -z "$BRANCH" ] && BRANCH="task/$TASK_ID"

BASE="$(fm_field "$MASTER_ENTRY" base)"
[ -z "$BASE" ] && BASE="main"

WORKTREE="$(fm_field "$MASTER_ENTRY" worktree)"
if [ -z "$WORKTREE" ]; then
    WORKTREE="$HOME/.zyz-worker/worktrees/$PROJECT/$BRANCH"
fi
# Expand a leading `~/` if present. Quote the pattern — see the
# source-repo expansion above for why the bare `~/` form is a no-op.
case "$WORKTREE" in
    "~/"*) WORKTREE="$HOME/${WORKTREE#"~/"}" ;;
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
if ! git -C "$SOURCE_REPO" worktree add "$WORKTREE" -b "$BRANCH" "$BASE" >/dev/null 2>&1; then
    # Try again without -b (branch may already exist locally).
    if ! git -C "$SOURCE_REPO" worktree add "$WORKTREE" "$BRANCH" >/dev/null 2>&1; then
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

# SCRIPT_DIR was resolved earlier (above the PLUGIN_ROOT hoist). Address the
# sibling heartbeat daemon by absolute path even when the user invokes us
# from a different cwd.
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

# Step 10: write the Phase-1 dispatch.md (atomic). This is the LAST preflight
# step — it runs for BOTH non-auto-start and auto-start spawns, so dispatch.md
# presence reliably means "spawn ran preflight to completion". The check
# helper (orch-check-worker.sh) lazily fills the Phase-2 fields on later polls.
#
# tmux-window-id / tmux-pane-id / shell-pid are read back from the session we
# created seconds ago (Step 7). It has exactly one window with one pane, so
# `head -1` is correct. set -e is in effect: if list-panes returned no rows
# the spawn fails fast (the session vanishing microseconds after creation is
# not recoverable).
#
# encoded-cwd is computed from the PHYSICAL path (`pwd -P`) of the worktree,
# NOT the raw $WORKTREE: claude records the cwd it actually entered, and on
# macOS standard temp dirs (/var/folders/...) are symlinks to /private/var/...
# Using the symlinked form would make transcript-path never bind.
DISPATCH_FILE="$RUNTIME_DIR/dispatch.md"
TMUX_PANE_INFO="$(tmux list-panes -t "$TMUX_SESSION" -F '#{window_id} #{pane_id} #{pane_pid}' | head -1)"
TMUX_WINDOW_ID="$(echo "$TMUX_PANE_INFO" | awk '{print $1}')"
TMUX_PANE_ID="$(echo "$TMUX_PANE_INFO" | awk '{print $2}')"
SHELL_PID="$(echo "$TMUX_PANE_INFO" | awk '{print $3}')"
WORKTREE_PHYS="$(cd "$WORKTREE" && pwd -P)"
ENCODED_CWD="$(echo "$WORKTREE_PHYS" | tr '/' '-')"

TMP_DISPATCH="$DISPATCH_FILE.tmp.$$"
cat > "$TMP_DISPATCH" <<EOF
---
task-id: $TASK_ID
spawn-iso: $NOW_ISO
tmux-session: $TMUX_SESSION
tmux-window-id: $TMUX_WINDOW_ID
tmux-pane-id: $TMUX_PANE_ID
shell-pid: $SHELL_PID
worktree: $WORKTREE
source-repo: $SOURCE_REPO
branch: $BRANCH
base: $BASE
plugin-root: $PLUGIN_ROOT
encoded-cwd: $ENCODED_CWD
claude-pid:
claude-session-id:
transcript-path:
first-seen-iso:
---

# Dispatch Info

## Recovery

(awaiting claude startup; orch-check-worker.sh populates this on the first poll where claude has registered AND first LLM round-trip has produced a transcript)
EOF
mv -f "$TMP_DISPATCH" "$DISPATCH_FILE"

# Step 11: optionally auto-start claude + /execute-task. Default OFF.
#
# Failure modes this block defends against (see RUN_REPORT_2026-06-20_zh.md):
#   §3a Worker pane didn't have the plugin registered → derive PLUGIN_ROOT
#        from $SCRIPT_DIR/.. so we don't depend on $CLAUDE_PLUGIN_ROOT being
#        inherited from the orchestrator's env.
#   §2   `claude` hangs at every permission prompt → default the launch
#        flags to bypass mode. Override with $ZYZ_WORKER_CLAUDE_FLAGS.
#   §3b  `sleep 2` raced the claude welcome screen → poll the pane until
#        a prompt indicator appears (30s timeout, 1s tick) before typing
#        the slash command.
#   §4e  `/execute-task` got rejected as Unknown command and the
#        orchestrator never noticed → after sending it, check the pane
#        for that error string and atomically rewrite worker-status.md
#        with phase=error so the next poll surfaces the failure.
if [ "$AUTO_START" = "true" ]; then
    # PLUGIN_ROOT and its warn-only sanity check were hoisted to top-level
    # (above, after the tmux/git dependency loop) so the dispatch.md Phase-1
    # write can also record it. We just reference $PLUGIN_ROOT here.
    CLAUDE_FLAGS="${ZYZ_WORKER_CLAUDE_FLAGS---permission-mode bypassPermissions --dangerously-skip-permissions}"

    tmux send-keys -t "$TMUX_SESSION" \
        "claude --plugin-dir '$PLUGIN_ROOT' $CLAUDE_FLAGS" Enter

    # Poll the pane until claude looks ready. We look for the `❯ ` prompt
    # glyph that the welcome screen renders once it accepts input. Bound
    # the wait at 30s so a totally broken launch (no `claude` on PATH,
    # etc.) does not stall spawn indefinitely.
    READY="false"
    for _ in $(seq 1 30); do
        if tmux capture-pane -t "$TMUX_SESSION" -p -S -30 2>/dev/null | grep -q '❯ '; then
            READY="true"
            break
        fi
        sleep 1
    done
    if [ "$READY" != "true" ]; then
        echo "warn: claude did not show a prompt in 30s; sending /execute-task anyway" >&2
    fi

    tmux send-keys -t "$TMUX_SESSION" "/execute-task $TASK_ID" Enter

    # Give claude a beat to either accept or reject the command, then
    # inspect the pane. `Unknown command` is the exact toast string claude
    # prints when a slash command isn't registered — we treat that as a
    # hard dispatch failure and reflect it in worker-status.md so the
    # orchestrator's next poll (which only reads worker-status.md, not the
    # pane) surfaces it instead of seeing fresh-heartbeat + phase=design.
    sleep 1
    if tmux capture-pane -t "$TMUX_SESSION" -p -S -30 2>/dev/null | grep -q 'Unknown command'; then
        FAIL_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"
        TMP_FAIL="$WORKER_STATUS_FILE.tmp.$$"
        cat > "$TMP_FAIL" <<EOF
---
task-id: $TASK_ID
phase: error
phase-since: $FAIL_ISO
wait-state: none
waiting-reason:
expected-resume-by:
last-flush: $FAIL_ISO
---

# Worker Status

## Current Activity

(spawn aborted: claude rejected /execute-task as Unknown command)

## Last Output Summary

claude pane reported \`Unknown command: /execute-task\` after auto-start.
The plugin's slash command is not registered in this session even though
\`claude --plugin-dir '$PLUGIN_ROOT'\` was passed. Likely causes:
  - --plugin-dir does not register marketplace plugins in this claude version
  - PLUGIN_ROOT path is wrong: $PLUGIN_ROOT
  - the plugin's command manifest is malformed

Diagnose by attaching to the pane and restarting with --debug:
  tmux attach -t $TMUX_SESSION
  # then in the pane, after Ctrl-C-ing the broken claude:
  claude --debug --plugin-dir '$PLUGIN_ROOT'
  # type /execute-task $TASK_ID and read the debug log.

## Next Action

Operator intervention required. The orchestrator will not retry this
spawn automatically.
EOF
        mv -f "$TMP_FAIL" "$WORKER_STATUS_FILE"
        echo "warn: claude rejected /execute-task as Unknown command; worker-status.md set to phase=error" >&2
    fi
fi

# Step 12: stdout report.
printf 'session-name=%s\n' "$TMUX_SESSION"
printf 'worktree=%s\n' "$WORKTREE"
printf 'auto-start=%s\n' "$AUTO_START"
printf 'source-repo=%s\n' "$SOURCE_REPO"

exit 0
