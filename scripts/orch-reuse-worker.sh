#!/usr/bin/env bash
#
# orch-reuse-worker.sh — associate a COMPLETED old task's leftover tmux session
# and/or git worktree to a NEW task, instead of building a fresh container the
# way orch-spawn-worker.sh does. This is the reuse counterpart to spawn: spawn
# always builds a brand-new container; reuse binds the new task's runtime onto an
# existing one. Like spawn, it builds/associates the container and writes the
# Phase-1 dispatch.md, and it NEVER starts claude (the L2 orch-driver-agent with
# intent=reuse-dispatch is the sole launcher).
#
# The new task declares its reuse intent in its OWN master-entry frontmatter:
#   reuse-from: <old-task-id>   present => reuse; same <list-dir>, must be completed
#   reuse-scope: worktree|tmux|both
#   reuse-claude: true|false    (only meaningful when reusing tmux)
#
# Scope -> container action matrix (see design §Proposed Design):
#   worktree                  : reuse old worktree, NEW tmux session zyz-task-<new-id>,
#                               in-pane daemon (same as spawn), NEW claude (env clean).
#                               reuse-claude is IGNORED -> reuse-claude-effective=n/a.
#   tmux  (reuse-claude:true)  : reuse old session, worktree = old pane's worktree
#                               (cwd is immutable; the `worktree:` field is ignored),
#                               heartbeat via a NEW window in the reused session,
#                               SAME claude process (in-band runtime-config block).
#   tmux  (reuse-claude:false) : as above but RESTART claude in the reused session.
#   both  (reuse-claude:true)  : reuse old session + old worktree, new-window daemon,
#                               SAME claude.
#   both  (reuse-claude:false) : reuse old session + old worktree, new-window daemon,
#                               RESTART claude.
#
# Contract:
#   Inputs:
#     $1  <new-task-id>           must match [A-Za-z0-9_-]+
#     $2  <list-dir>              master list directory (same list as reuse-from)
#
#   Side effects:
#     - Reads <list-dir>/tasks/<new-task-id>.md frontmatter (reuse-from / reuse-scope /
#       reuse-claude / worktree / branch / tmux-session / source-repo).
#     - Reads <list-dir>/tasks/<old-task-id>.md frontmatter and
#       <list-dir>/runtime/<old-task-id>/dispatch.md (old container coordinates).
#     - Creates <list-dir>/runtime/<new-task-id>/.
#     - Writes the INITIAL <list-dir>/runtime/<new-task-id>/worker-status.md
#       (phase=design). After this preflight write the file is owned exclusively
#       by L3 (the worker); reuse never rewrites it.
#     - worktree scope only: `git worktree add` is NOT run (the old worktree is
#       reused as-is); a NEW tmux session is created and an in-pane heartbeat
#       daemon started (same as spawn).
#     - tmux / both scope: NO new session; a NEW tmux WINDOW is opened in the
#       reused session and the heartbeat daemon started in that window's pane.
#     - Writes <list-dir>/runtime/<new-task-id>/dispatch.md (Phase-1) including the
#       four reuse fields (reuse-from / reuse-scope / reuse-claude-effective /
#       heartbeat-window-id) and, for same-claude reuse, a reuse-aware `## Recovery`
#       note.
#     Does NOT start claude (that is the L2 driver subagent's job).
#
#   Output (stdout):
#     session-name=<tmux-session>
#     worktree=<worktree>
#     reuse-from=<old-task-id>
#     reuse-scope=<worktree|tmux|both>
#     reuse-claude-effective=<true|false|n/a>
#     heartbeat-window-id=<window id or empty>
#
#   Exit codes:
#     0  success
#     2  argument error / invalid task-id
#     3  missing dependency (tmux / git)
#     4  <list-dir>/tasks/<new-task-id>.md missing or unreadable
#     5  reuse precondition failed. Two classes, validated at DIFFERENT points so
#        the tmux-free negative paths fire even on a host without tmux:
#        - tmux-FREE (validated BEFORE the dependency check): reuse-from missing /
#          old master entry missing or unreadable / reuse-scope illegal / old task
#          not `completed` / reusing worktree but the old worktree path is gone /
#          reusing tmux/both but the old dispatch.md lacks pane coordinates
#          (shell-pid/pane-id, needed to bind the same-claude reuse) / new runtime
#          dir already exists.
#          NOTE: the (worktree-scope) "new tmux session name already taken" case
#          is NOT in this class — it needs tmux to test, runs AFTER the dependency
#          check, and exits 6 (see the exit-6 line below), not 5.
#        - tmux-DEPENDENT (validated AFTER the dependency check): reusing tmux but
#          the old session is not alive (`tmux has-session`).
#     6  new tmux session creation failed / (worktree-scope) session name conflict
#     7  container association/creation failed (e.g. `tmux new-window` failed)
#
#   Exit-code precedence (evaluated in this order, first match wins):
#     2  argv shape / task-id charset
#     4  new master entry missing
#     5-tmux-free  the first class of reuse preconditions above
#     3  tmux / git not on PATH
#     5-tmux-dep   old session not alive
#     6  session conflict / new-session creation failure
#     7  container creation failure
#   This mirrors spawn's "source-repo validated before the tmux/git dependency
#   check, tmux session conflict validated after it" structure, so the tmux-free
#   negative paths are reproducible on a tmux-less host.
#
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <new-task-id> <list-dir>" >&2
}

if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi

TASK_ID="$1"
LIST_DIR="$2"

# task-id whitelist. This also structurally forbids a `reuse-from` that is an
# absolute path or crosses lists: the old entry path is computed from the same
# <list-dir>, and a path-like value fails the charset check below (see S3).
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
    [ -f "$file" ] && [ -r "$file" ] || { printf ''; return 0; }
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

# expand_tilde <value> — echo the value with a leading `~/` expanded to $HOME.
# The `~/` pattern MUST be quoted inside ${…#PAT} (see spawn's source-repo note):
# bash otherwise treats the leading `~` as the tilde-expansion metachar and the
# strip silently becomes a no-op.
expand_tilde() {
    local v="$1"
    case "$v" in
        "~/"*) printf '%s\n' "$HOME/${v#"~/"}" ;;
        *) printf '%s\n' "$v" ;;
    esac
}

# ─── Read the NEW task's reuse intent ────────────────────────────────────────
REUSE_FROM="$(fm_field "$MASTER_ENTRY" reuse-from)"
REUSE_SCOPE="$(fm_field "$MASTER_ENTRY" reuse-scope)"
REUSE_CLAUDE="$(fm_field "$MASTER_ENTRY" reuse-claude)"

# ─── 5-tmux-free preconditions (validated BEFORE the tmux/git dependency check
#     so they fire on a tmux-less host, mirroring spawn's source-repo ordering) ─

# (a) reuse-from must be present.
if [ -z "$REUSE_FROM" ]; then
    echo "error: master entry has no reuse-from field (not a reuse task): $MASTER_ENTRY" >&2
    exit 5
fi

# reuse-from is a task-id within the SAME list (S3). Validate its charset too,
# so a path-like / cross-list value is rejected up front.
case "$REUSE_FROM" in
    *[!A-Za-z0-9_-]*)
        echo "error: invalid reuse-from (must be a task-id [A-Za-z0-9_-]+ in the same list): '$REUSE_FROM'" >&2
        exit 5
        ;;
esac

# (b) reuse-scope default + legality.
[ -z "$REUSE_SCOPE" ] && REUSE_SCOPE="both"
case "$REUSE_SCOPE" in
    worktree|tmux|both) : ;;
    *)
        echo "error: invalid reuse-scope (must be worktree|tmux|both): '$REUSE_SCOPE'" >&2
        exit 5
        ;;
esac

# (c) old master entry must exist in the SAME list and be readable.
OLD_ENTRY="$LIST_DIR/tasks/$REUSE_FROM.md"
if [ ! -f "$OLD_ENTRY" ] || [ ! -r "$OLD_ENTRY" ]; then
    echo "error: reuse-from old master entry not found or unreadable: $OLD_ENTRY" >&2
    exit 5
fi

# (d) old task must be completed (G4). Reuse only associates; it never advances
#     the old task.
OLD_STATE="$(fm_field "$OLD_ENTRY" state)"
if [ "$OLD_STATE" != "completed" ]; then
    echo "error: reuse-from task '$REUSE_FROM' is not completed (state=$OLD_STATE); reuse requires the old task to be completed" >&2
    exit 5
fi

# Read the old container coordinates from the old dispatch.md (authoritative
# Phase-1 snapshot) with the old master entry as fallback.
OLD_DISPATCH="$LIST_DIR/runtime/$REUSE_FROM/dispatch.md"

OLD_TMUX_SESSION="$(fm_field "$OLD_DISPATCH" tmux-session)"
[ -z "$OLD_TMUX_SESSION" ] && OLD_TMUX_SESSION="$(fm_field "$OLD_ENTRY" tmux-session)"
[ -z "$OLD_TMUX_SESSION" ] && OLD_TMUX_SESSION="zyz-task-$REUSE_FROM"

OLD_WORKTREE="$(fm_field "$OLD_DISPATCH" worktree)"
[ -z "$OLD_WORKTREE" ] && OLD_WORKTREE="$(fm_field "$OLD_ENTRY" worktree)"
OLD_WORKTREE="$(expand_tilde "$OLD_WORKTREE")"

OLD_SHELL_PID="$(fm_field "$OLD_DISPATCH" shell-pid)"
OLD_TMUX_PANE_ID="$(fm_field "$OLD_DISPATCH" tmux-pane-id)"
OLD_TMUX_WINDOW_ID="$(fm_field "$OLD_DISPATCH" tmux-window-id)"
OLD_SOURCE_REPO="$(fm_field "$OLD_DISPATCH" source-repo)"
[ -z "$OLD_SOURCE_REPO" ] && OLD_SOURCE_REPO="$(fm_field "$OLD_ENTRY" source-repo)"
OLD_SOURCE_REPO="$(expand_tilde "$OLD_SOURCE_REPO")"
OLD_BRANCH="$(fm_field "$OLD_DISPATCH" branch)"
[ -z "$OLD_BRANCH" ] && OLD_BRANCH="$(fm_field "$OLD_ENTRY" branch)"
OLD_BASE="$(fm_field "$OLD_DISPATCH" base)"
[ -z "$OLD_BASE" ] && OLD_BASE="$(fm_field "$OLD_ENTRY" base)"
OLD_PLUGIN_ROOT="$(fm_field "$OLD_DISPATCH" plugin-root)"

# ─── Old worktree SET (D4) ───────────────────────────────────────────────────
#
# The reuse axis is the old task's worktree SET, not just its primary worktree.
# Index 0 = primary = repo 1 (the fields read above, dispatch-first / master
# fallback — byte-identical to the historical single-repo path). Indices 1..N-1
# come from the old dispatch.md's RESOLVED numbered group (worktree-2 /
# source-repo-2 / branch-2 / base-2, …), the single authoritative source for the
# repo set (02-D0). The master entry has no reliable resolved numbered group, so
# the numbered tail is dispatch-only; a single-repo old task (dispatch absent or
# carrying no numbered group) yields a 1-element set and every downstream path
# stays byte-identical.
OLD_WT=("$OLD_WORKTREE")
OLD_SR=("$OLD_SOURCE_REPO")
OLD_BR=("$OLD_BRANCH")
OLD_BS=("$OLD_BASE")
if [ -f "$OLD_DISPATCH" ]; then
    i=2
    while :; do
        wv="$(fm_field "$OLD_DISPATCH" "worktree-$i")"
        if [ -z "$wv" ]; then
            # Numbering-gap detection, mirroring orch-spawn-worker.sh's probe. A
            # hole would silently truncate the inherited worktree set, so the new
            # task would take over only part of the old container while reuse
            # reports success. Spawn rejects such an entry with exit 5; a reader
            # must not be more permissive than the writer.
            gap_probe="$i"
            while [ "$gap_probe" -le 9 ]; do
                if [ -n "$(fm_field "$OLD_DISPATCH" "worktree-$gap_probe")" ]; then
                    echo "error: worktree numbering gap in $OLD_DISPATCH: worktree-$i is missing but worktree-$gap_probe is present" >&2
                    exit 5
                fi
                gap_probe=$((gap_probe + 1))
            done
            break
        fi
        OLD_WT+=("$(expand_tilde "$wv")")
        OLD_SR+=("$(expand_tilde "$(fm_field "$OLD_DISPATCH" "source-repo-$i")")")
        OLD_BR+=("$(fm_field "$OLD_DISPATCH" "branch-$i")")
        OLD_BS+=("$(fm_field "$OLD_DISPATCH" "base-$i")")
        i=$((i + 1))
    done
fi

# (e) reusing worktree (worktree/both) -> EVERY worktree in the old set must
# still exist. Any missing repo aborts with exit 5 naming which one. The primary
# (index 0) keeps its historical diagnostic text; extra repos name their number.
case "$REUSE_SCOPE" in
    worktree|both)
        idx=0
        while [ "$idx" -lt "${#OLD_WT[@]}" ]; do
            owt="${OLD_WT[$idx]}"
            if [ "$idx" -eq 0 ]; then
                if [ -z "$owt" ]; then
                    echo "error: reuse-from old task has no worktree recorded (entry/dispatch): $REUSE_FROM" >&2
                    exit 5
                fi
                if [ ! -e "$owt" ]; then
                    echo "error: reuse-from old worktree path no longer exists: $owt" >&2
                    exit 5
                fi
            else
                if [ -z "$owt" ]; then
                    echo "error: reuse-from old task repo $((idx + 1)) has no worktree recorded in dispatch.md: $REUSE_FROM" >&2
                    exit 5
                fi
                if [ ! -e "$owt" ]; then
                    echo "error: reuse-from old worktree path (repo $((idx + 1))) no longer exists: $owt" >&2
                    exit 5
                fi
            fi
            idx=$((idx + 1))
        done
        ;;
esac

# (e2) reusing tmux (tmux/both) -> the old dispatch.md must carry the pane
# coordinates we copy verbatim into the same-claude NEW dispatch.md. Unlike
# session/worktree/etc. these fields (shell-pid, tmux-pane-id) exist ONLY in
# dispatch.md and have no master-entry fallback, so a missing/crash-incomplete/
# pre-feature old dispatch.md would otherwise yield an empty shell-pid in the new
# dispatch.md. That silently breaks orch-check-worker.sh Step A
# (`pgrep -P "$DISPATCH_SHELL_PID"` is `[ -n … ]`-guarded), so claude-pid never
# binds, dispatch-bound stays false forever, and the same-claude worker is
# un-pollable with no diagnostic. This is a pure file read, so it belongs in the
# 5-tmux-free group BEFORE the tmux/git dependency gate (fires on a tmux-less host
# too).
case "$REUSE_SCOPE" in
    tmux|both)
        if [ -z "$OLD_SHELL_PID" ] || [ -z "$OLD_TMUX_PANE_ID" ]; then
            echo "error: reuse-from old dispatch.md has no shell-pid/pane-id; cannot bind same-claude reuse: $OLD_DISPATCH" >&2
            exit 5
        fi
        ;;
esac

# Runtime files for the NEW task.
RUNTIME_DIR="$LIST_DIR/runtime/$TASK_ID"
WORKER_STATUS_FILE="$RUNTIME_DIR/worker-status.md"
HEARTBEAT_FILE="$RUNTIME_DIR/heartbeat"
QUESTION_FILE="$RUNTIME_DIR/question.md"
ANSWER_FILE="$RUNTIME_DIR/answer.md"
DISPATCH_FILE="$RUNTIME_DIR/dispatch.md"

# (f) the new runtime dir must not already exist.
if [ -e "$RUNTIME_DIR" ]; then
    echo "error: runtime dir already exists: $RUNTIME_DIR" >&2
    exit 5
fi

# ─── reuse-claude-effective + the new task's tmux session / worktree resolution ─
#
# reuse-claude-effective:
#   worktree scope     -> n/a   (always a new session => new claude; reuse-claude
#                                 is ignored, even when explicitly false)
#   tmux/both scope    -> reuse-claude (default true)
case "$REUSE_SCOPE" in
    worktree)
        REUSE_CLAUDE_EFFECTIVE="n/a"
        ;;
    tmux|both)
        if [ -z "$REUSE_CLAUDE" ]; then
            REUSE_CLAUDE_EFFECTIVE="true"
        else
            case "$REUSE_CLAUDE" in
                true|false) REUSE_CLAUDE_EFFECTIVE="$REUSE_CLAUDE" ;;
                *) REUSE_CLAUDE_EFFECTIVE="true" ;;
            esac
        fi
        ;;
esac

# The NEW task's session name and worktree:
#   worktree scope : new session zyz-task-<new-id> (or the entry override),
#                    reusing the OLD worktree.
#   tmux/both scope: the OLD session is reused, and the worktree is ALWAYS the old
#                    pane's worktree (= old worktree). For `tmux` scope the new
#                    task's `worktree:` frontmatter field is intentionally ignored
#                    (cwd is immutable for the same claude; even on restart claude
#                    stays in the same pane). To use a different worktree, use
#                    `both` (reuse the old worktree) or a plain spawn.
NEW_SESSION_OVERRIDE="$(fm_field "$MASTER_ENTRY" tmux-session)"
case "$REUSE_SCOPE" in
    worktree)
        if [ -n "$NEW_SESSION_OVERRIDE" ]; then
            TMUX_SESSION="$NEW_SESSION_OVERRIDE"
        else
            TMUX_SESSION="zyz-task-$TASK_ID"
        fi
        WORKTREE="$OLD_WORKTREE"
        ;;
    tmux|both)
        TMUX_SESSION="$OLD_TMUX_SESSION"
        WORKTREE="$OLD_WORKTREE"
        ;;
esac

# ZYZ_WORKTREES: colon-separated worktree set, primary first (01-D4-6). Only
# meaningful for a >=2 worktree set; a single-worktree set leaves it EMPTY so
# worktree-scope env injection stays byte-compatible with the single-repo case
# (variable absent = single-worktree behavior).
ZYZ_WORKTREES=""
if [ "${#OLD_WT[@]}" -ge 2 ]; then
    for _owt in "${OLD_WT[@]}"; do
        if [ -z "$ZYZ_WORKTREES" ]; then
            ZYZ_WORKTREES="$_owt"
        else
            ZYZ_WORKTREES="$ZYZ_WORKTREES:$_owt"
        fi
    done
fi

# ─── Dependencies (checked AFTER the tmux-free preconditions above) ───────────
for dep in tmux git; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "error: missing dependency: $dep" >&2
        exit 3
    fi
done

# ─── 5-tmux-dep precondition: reusing tmux -> old session must be alive ───────
case "$REUSE_SCOPE" in
    tmux|both)
        if ! tmux has-session -t "$OLD_TMUX_SESSION" 2>/dev/null; then
            echo "error: reuse-from old tmux session is not alive: $OLD_TMUX_SESSION" >&2
            exit 5
        fi
        ;;
esac

# Resolve where this script lives so we can address sibling helpers (the
# heartbeat daemon) by absolute path even when invoked from a different cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_SCRIPT="$SCRIPT_DIR/orch-heartbeat-daemon.sh"

# Resolve the plugin root. Prefer the old dispatch.md value (the reused container
# was launched with it) so `claude --plugin-dir <plugin-root>` on recovery stays
# consistent; fall back to CLAUDE_PLUGIN_ROOT / the script's parent.
PLUGIN_ROOT="${OLD_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
if [ ! -d "$PLUGIN_ROOT/skills/execute-task" ]; then
    echo "warn: PLUGIN_ROOT=$PLUGIN_ROOT does not contain skills/execute-task" >&2
fi

# Branch / base for the NEW task. The new task runs on the reused worktree's
# branch (we do not cut a new branch — that would diverge the reused worktree).
BRANCH="$OLD_BRANCH"
BASE="$OLD_BASE"
SOURCE_REPO="$OLD_SOURCE_REPO"

# ─── Create the NEW runtime dir + initial worker-status.md ───────────────────
mkdir -p "$RUNTIME_DIR"

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

(initialized by orchestrator for a reused container; awaiting worker start)

## Last Output Summary

(none yet)

## Next Action

Start the worker: drive tmux session $TMUX_SESSION (reuse-dispatch), then run claude (or reuse the running claude) + /execute-task.
EOF
mv -f "$TMP_STATUS" "$WORKER_STATUS_FILE"

# ─── Associate / create the container per scope, and start the heartbeat ──────
#
# HEARTBEAT_WINDOW_ID: only set for tmux/both (same-session new-window daemon).
# For worktree scope it stays empty (the daemon runs in the new session's only
# pane, same as spawn). It is DIAGNOSTICS ONLY (S1): cleanup kills the whole
# session, and orch-heartbeat-daemon.sh's `tmux has-session` watchdog
# (ZYZ_TMUX_SESSION carries the session name, not a window) tears the new-window
# daemon down with the session. Never derive kill logic from this field.
HEARTBEAT_WINDOW_ID=""

case "$REUSE_SCOPE" in
    worktree)
        # New session, reusing the OLD worktree. Same shape as spawn from here:
        # create the session, start an in-pane daemon, read back pane info.
        if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            echo "error: new tmux session name already exists: $TMUX_SESSION" >&2
            exit 6
        fi
        if ! tmux new-session -d -s "$TMUX_SESSION" -c "$WORKTREE" 2>/dev/null; then
            echo "error: failed to create tmux session: $TMUX_SESSION" >&2
            exit 6
        fi
        # In-pane heartbeat daemon (same as spawn: lives in the pane's process
        # group; dies with the session via SIGHUP + the has-session watchdog).
        tmux send-keys -t "$TMUX_SESSION" \
            "ZYZ_TMUX_SESSION='$TMUX_SESSION' '$DAEMON_SCRIPT' '$HEARTBEAT_FILE' 30 >/dev/null 2>&1 &" Enter
        # Export env into the new pane so the freshly-launched claude inherits
        # the new task's paths (a clean handshake; no in-band block needed for
        # worktree scope). The L2 reuse-dispatch driver still launches claude.
        tmux send-keys -t "$TMUX_SESSION" \
            "export ZYZ_WORKER_STATUS_FILE='$WORKER_STATUS_FILE' ZYZ_TASK_ID='$TASK_ID' ZYZ_QUESTION_FILE='$QUESTION_FILE' ZYZ_ANSWER_FILE='$ANSWER_FILE' ZYZ_HEARTBEAT_FILE='$HEARTBEAT_FILE'" \
            Enter
        # Multi-repo (>=2 worktree set): export ZYZ_WORKTREES so the reused
        # worker has write scope over the whole inherited set (01-D4-6, mirrors
        # spawn's Step 9 multi-repo export). Emitted as a SEPARATE export ONLY
        # when the set has >=2 worktrees, so the single-worktree case above is
        # byte-identical (variable absent = single-worktree behavior).
        if [ -n "$ZYZ_WORKTREES" ]; then
            tmux send-keys -t "$TMUX_SESSION" \
                "export ZYZ_WORKTREES='$ZYZ_WORKTREES'" \
                Enter
        fi
        # Inject Go build I/O optimization (worktree scope ONLY: new session/new
        # pane/new claude, same shape as spawn). The tmux|both branches reuse an
        # already-started claude whose env is frozen, so they do NOT get this.
        BUILD_ENV_LINE="$("$SCRIPT_DIR/orch-build-env.sh" 2>/dev/null || true)"
        if [ -n "$BUILD_ENV_LINE" ]; then
            tmux send-keys -t "$TMUX_SESSION" "$BUILD_ENV_LINE" Enter
        fi
        # Read back the new session's pane coordinates (one window, one pane).
        TMUX_PANE_INFO="$(tmux list-panes -t "$TMUX_SESSION" -F '#{window_id} #{pane_id} #{pane_pid}' | head -1)"
        TMUX_WINDOW_ID="$(echo "$TMUX_PANE_INFO" | awk '{print $1}')"
        TMUX_PANE_ID="$(echo "$TMUX_PANE_INFO" | awk '{print $2}')"
        SHELL_PID="$(echo "$TMUX_PANE_INFO" | awk '{print $3}')"
        ;;
    tmux|both)
        # Reuse the OLD session. The dispatch.md pane coordinates are the OLD
        # pane's (where claude lives), because same-claude binding does
        # `pgrep -P <old shell-pid>` and a restart also happens in that pane.
        TMUX_WINDOW_ID="$OLD_TMUX_WINDOW_ID"
        TMUX_PANE_ID="$OLD_TMUX_PANE_ID"
        SHELL_PID="$OLD_SHELL_PID"
        # Heartbeat for the new task: a NEW window in the reused session (D2).
        # claude occupies the original window/pane, so we cannot start a shell
        # daemon there. The new-window daemon points at the NEW task's heartbeat
        # file and dies with the reused session (ZYZ_TMUX_SESSION carries the
        # SESSION name, so the watchdog stays correct for the new window too).
        if ! NEW_WINDOW_INFO="$(tmux new-window -t "$OLD_TMUX_SESSION" -c "$WORKTREE" -P -F '#{window_id} #{pane_id}' 2>/dev/null)"; then
            echo "error: failed to open a heartbeat window in reused session: $OLD_TMUX_SESSION" >&2
            exit 7
        fi
        HEARTBEAT_WINDOW_ID="$(echo "$NEW_WINDOW_INFO" | awk '{print $1}')"
        HEARTBEAT_PANE_ID="$(echo "$NEW_WINDOW_INFO" | awk '{print $2}')"
        tmux send-keys -t "$HEARTBEAT_PANE_ID" \
            "ZYZ_TMUX_SESSION='$OLD_TMUX_SESSION' '$DAEMON_SCRIPT' '$HEARTBEAT_FILE' 30 >/dev/null 2>&1 &" Enter
        ;;
esac

# encoded-cwd from the PHYSICAL worktree path (matches Claude Code's
# ~/.claude/projects/<dir> naming; diagnostics + recovery path only — transcript
# discovery is by session-id). Guard the cd in case the worktree path is odd.
if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    WORKTREE_PHYS="$(cd "$WORKTREE" && pwd -P)"
    ENCODED_CWD="$(echo "$WORKTREE_PHYS" | tr '/.' '--' | tr -s '-')"
else
    ENCODED_CWD=""
fi

# ─── Write the Phase-1 dispatch.md (atomic, LAST step) ───────────────────────
#
# The four reuse fields are written so the schema matches spawn's (which writes
# them empty) and survives orch-check-worker.sh's Phase-2 rewrites (which now
# reads them back). For same-claude reuse the `## Recovery` body is seeded with a
# reuse-aware note (shared session, attach-only, no independent --resume); the
# definitive reuse-aware body is regenerated by orch-check-worker.sh once the
# Phase-2 trio completes.
if [ "$REUSE_FROM" != "" ] && [ "$REUSE_CLAUDE_EFFECTIVE" = "true" ]; then
    RECOVERY_BODY="This task REUSES a shared claude session from task \`$REUSE_FROM\` (reuse-scope=$REUSE_SCOPE, same claude process). Recovery: ONLY \`tmux attach -t $TMUX_SESSION\`. Do NOT run an independent \`claude --resume\` for this task — its session-id, once bound, points at the shared (old+new merged) session, and resuming it from two dispatch.md files is a known footgun.

(orch-check-worker.sh will regenerate this reuse-aware note once claude has registered AND the first LLM round-trip has produced a transcript.)"
else
    RECOVERY_BODY="(awaiting claude startup; orch-check-worker.sh populates this on the first poll where claude has registered AND first LLM round-trip has produced a transcript)"
fi

# Build the numbered field group (repos 2..N) inherited from the old worktree
# SET, matching the exact format spawn emits: after `base:`, append
# worktree-N / source-repo-N / branch-N / base-N per extra repo. Accumulated
# into a variable (heredocs can't inline a loop; same idiom as spawn's Phase-1
# and check's rewrite_dispatch_atomic). Empty for a single-repo set, so the
# heredoc inlines it right before `plugin-root:` with NO extra blank line ->
# single-repo dispatch.md stays byte-identical.
NUMBERED_GROUP=""
if [ "${#OLD_WT[@]}" -ge 2 ]; then
    idx=1
    while [ "$idx" -lt "${#OLD_WT[@]}" ]; do
        n=$((idx + 1))
        NUMBERED_GROUP="${NUMBERED_GROUP}worktree-$n: ${OLD_WT[$idx]}
source-repo-$n: ${OLD_SR[$idx]}
branch-$n: ${OLD_BR[$idx]}
base-$n: ${OLD_BS[$idx]}
"
        idx=$((idx + 1))
    done
fi

TMP_DISPATCH="$DISPATCH_FILE.tmp.$$"
# MCP inheritance policy snapshot (issue #2) — same call as spawn's. Note it
# only takes effect where a claude is actually (re)launched: the restart and
# new-session reuse branches. A same-claude reuse keeps the already-running
# process, whose MCP set was fixed at ITS launch — recorded here anyway so the
# recovery command and any future restart use the current policy.
WORKER_MCP_ARGS="$("$SCRIPT_DIR/orch-worker-mcp-args.sh" 2>/dev/null || true)"
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
${NUMBERED_GROUP}plugin-root: $PLUGIN_ROOT
encoded-cwd: $ENCODED_CWD
worker-mcp-args: $WORKER_MCP_ARGS
reuse-from: $REUSE_FROM
reuse-scope: $REUSE_SCOPE
reuse-claude-effective: $REUSE_CLAUDE_EFFECTIVE
heartbeat-window-id: $HEARTBEAT_WINDOW_ID
claude-pid:
claude-session-id:
transcript-path:
first-seen-iso:
---

# Dispatch Info

## Recovery

$RECOVERY_BODY
EOF
mv -f "$TMP_DISPATCH" "$DISPATCH_FILE"

# ─── stdout report. reuse never starts claude — that is the L2 reuse-dispatch
#     driver's job. reuse's job ends here, with the container associated and
#     dispatch.md written. ─────────────────────────────────────────────────────
printf 'session-name=%s\n' "$TMUX_SESSION"
printf 'worktree=%s\n' "$WORKTREE"
printf 'reuse-from=%s\n' "$REUSE_FROM"
printf 'reuse-scope=%s\n' "$REUSE_SCOPE"
printf 'reuse-claude-effective=%s\n' "$REUSE_CLAUDE_EFFECTIVE"
printf 'heartbeat-window-id=%s\n' "$HEARTBEAT_WINDOW_ID"

exit 0
