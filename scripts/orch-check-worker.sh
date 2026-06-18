#!/usr/bin/env bash
#
# orch-check-worker.sh — inspect a single worker's runtime state.
#
# Contract:
#   Inputs:
#     $1  <task-id>          must match [A-Za-z0-9_-]+
#     $2  <list-dir>         master list directory
#
#   Side effects:
#     None. Read-only.
#
#   Output (stdout):
#     Multi-line key=value report. Always emits the following keys:
#       session-alive=true|false
#       heartbeat-status=fresh|suspect|stale|missing
#       heartbeat-mtime=<iso-or-empty>
#       phase=<value-or-empty>
#       phase-since=<iso-or-empty>
#       wait-state=<value-or-empty>
#       waiting-reason=<value-or-empty>
#       expected-resume-by=<iso-or-empty>
#
#   Heartbeat thresholds:
#     Base threshold S = max(per-task `heartbeat-stale-sec` frontmatter,
#                            $ZYZ_HEARTBEAT_STALE_SEC, default 300).
#     If wait-state=waiting-user → threshold = max(S, $ZYZ_HEARTBEAT_WAITING_USER_SEC, 900).
#     fresh   : age <= threshold
#     suspect : threshold < age <= 3 * threshold
#     stale   : age > 3 * threshold
#     missing : the heartbeat file does not exist
#
#   Exit codes:
#     0  always when arguments parse (including worker dead — that is a legal report)
#     2  argument error / invalid task-id
#     3  missing required dependency (`tmux`)
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

# Dependency: tmux.
if ! command -v tmux >/dev/null 2>&1; then
    echo "error: missing dependency: tmux" >&2
    exit 3
fi

MASTER_ENTRY="$LIST_DIR/tasks/$TASK_ID.md"
RUNTIME_DIR="$LIST_DIR/runtime/$TASK_ID"
WORKER_STATUS_FILE="$RUNTIME_DIR/worker-status.md"
HEARTBEAT_FILE="$RUNTIME_DIR/heartbeat"

# Extract a frontmatter field. Same logic as orch-scan-tasks.sh.
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

# Determine tmux session name. Prefer the master entry frontmatter; fall back
# to the conventional prefix.
TMUX_SESSION="$(fm_field "$MASTER_ENTRY" tmux-session)"
if [ -z "$TMUX_SESSION" ]; then
    TMUX_SESSION="zyz-task-$TASK_ID"
fi

# session-alive check.
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    SESSION_ALIVE="true"
else
    SESSION_ALIVE="false"
fi

# Worker-status fields.
PHASE="$(fm_field "$WORKER_STATUS_FILE" phase)"
PHASE_SINCE="$(fm_field "$WORKER_STATUS_FILE" phase-since)"
WAIT_STATE="$(fm_field "$WORKER_STATUS_FILE" wait-state)"
WAITING_REASON="$(fm_field "$WORKER_STATUS_FILE" waiting-reason)"
EXPECTED_RESUME_BY="$(fm_field "$WORKER_STATUS_FILE" expected-resume-by)"

# Compute the heartbeat threshold.
BASE_THRESHOLD="${ZYZ_HEARTBEAT_STALE_SEC:-300}"
PER_TASK_THRESHOLD="$(fm_field "$MASTER_ENTRY" heartbeat-stale-sec)"
if [ -n "$PER_TASK_THRESHOLD" ]; then
    case "$PER_TASK_THRESHOLD" in
        ''|*[!0-9]*) ;;  # ignore malformed
        *)
            if [ "$PER_TASK_THRESHOLD" -gt "$BASE_THRESHOLD" ]; then
                BASE_THRESHOLD="$PER_TASK_THRESHOLD"
            fi
            ;;
    esac
fi

# Widen for waiting-user.
THRESHOLD="$BASE_THRESHOLD"
if [ "$WAIT_STATE" = "waiting-user" ]; then
    WIDE="${ZYZ_HEARTBEAT_WAITING_USER_SEC:-900}"
    if [ "$WIDE" -gt "$THRESHOLD" ]; then
        THRESHOLD="$WIDE"
    fi
fi

# Heartbeat status.
HEARTBEAT_STATUS="missing"
HEARTBEAT_MTIME=""

if [ -f "$HEARTBEAT_FILE" ] && [ -r "$HEARTBEAT_FILE" ]; then
    # mtime in epoch seconds. Try GNU `stat -c %Y` then BSD `stat -f %m`.
    if mtime_epoch="$(stat -c %Y "$HEARTBEAT_FILE" 2>/dev/null)"; then
        :
    elif mtime_epoch="$(stat -f %m "$HEARTBEAT_FILE" 2>/dev/null)"; then
        :
    else
        mtime_epoch=""
    fi

    if [ -n "$mtime_epoch" ]; then
        now_epoch="$(date +%s)"
        age=$(( now_epoch - mtime_epoch ))
        if [ "$age" -lt 0 ]; then
            age=0
        fi
        triple=$(( THRESHOLD * 3 ))
        if [ "$age" -le "$THRESHOLD" ]; then
            HEARTBEAT_STATUS="fresh"
        elif [ "$age" -le "$triple" ]; then
            HEARTBEAT_STATUS="suspect"
        else
            HEARTBEAT_STATUS="stale"
        fi

        # Format the mtime as ISO timestamp. Use GNU `date -d @epoch` or BSD `date -r epoch`.
        if iso="$(date -d "@$mtime_epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null)"; then
            HEARTBEAT_MTIME="$iso"
        elif iso="$(date -r "$mtime_epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null)"; then
            HEARTBEAT_MTIME="$iso"
        else
            HEARTBEAT_MTIME=""
        fi
    fi
fi

printf 'session-alive=%s\n' "$SESSION_ALIVE"
printf 'heartbeat-status=%s\n' "$HEARTBEAT_STATUS"
printf 'heartbeat-mtime=%s\n' "$HEARTBEAT_MTIME"
printf 'phase=%s\n' "$PHASE"
printf 'phase-since=%s\n' "$PHASE_SINCE"
printf 'wait-state=%s\n' "$WAIT_STATE"
printf 'waiting-reason=%s\n' "$WAITING_REASON"
printf 'expected-resume-by=%s\n' "$EXPECTED_RESUME_BY"

exit 0
