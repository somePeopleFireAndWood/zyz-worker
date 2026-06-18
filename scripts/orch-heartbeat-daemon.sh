#!/usr/bin/env bash
#
# orch-heartbeat-daemon.sh — in-pane heartbeat daemon.
#
# Contract:
#   Inputs:
#     $1  <heartbeat-file>   absolute path of the heartbeat file to (over)write
#     $2  <interval-sec>     polling interval in seconds (positive integer)
#
#   Environment:
#     ZYZ_TMUX_SESSION  (optional) tmux session name this daemon is bound to.
#                       When set, the daemon ACTIVELY watchdogs the session
#                       via `tmux has-session` once per loop iteration; if the
#                       session is gone, the daemon exits 0. This is the
#                       second half of the "double-safety" lifecycle pattern
#                       documented in design-helpers-tests §E.2 / §E.4.
#                       When unset, this watchdog is skipped and the daemon
#                       relies solely on signal delivery (see Lifecycle).
#
#   Side effects:
#     1. Periodically (every <interval-sec>) overwrites <heartbeat-file>
#        with the current ISO 8601 timestamp on a single line.
#     2. When ZYZ_TMUX_SESSION is set and that tmux session no longer exists,
#        the daemon exits 0 on its own (active watchdog) — no signal needed.
#
#   Output (stdout):
#     None.
#
#   Lifecycle (double-safety):
#     1. SIGNAL PATH. The daemon traps SIGTERM, SIGINT, and SIGHUP and exits
#        0 on any of them. It MUST be launched WITHOUT `nohup` so that
#        SIGHUP can actually reach it when the tmux pane / session dies.
#        On a shell with `shopt -s huponexit` (Linux bash default in some
#        distros) this is enough on its own.
#     2. ACTIVE WATCHDOG PATH. macOS bash defaults to `huponexit=off`, so
#        background children may not receive SIGHUP when the parent shell
#        exits. To stay correct on macOS too, the daemon polls
#        `tmux has-session -t "$ZYZ_TMUX_SESSION"` once per loop iteration
#        and exits 0 when the session is gone. This guarantees teardown
#        even when SIGHUP is suppressed by the shell.
#     Either path is sufficient on its own; the design uses both so that
#     T6's "no daemon residue after teardown" check passes on every host
#     bash configuration (see design-helpers-tests §E.4 + T6 F8).
#
#   Exit codes:
#     0  normal termination (signal received OR tmux session disappeared)
#     2  argument error
#     3  missing required dependency (e.g. `date`)
#
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <heartbeat-file> <interval-sec>" >&2
}

if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi

HEARTBEAT_FILE="$1"
INTERVAL_SEC="$2"

if [ -z "$HEARTBEAT_FILE" ]; then
    usage
    exit 2
fi

# Validate interval is a positive integer.
case "$INTERVAL_SEC" in
    ''|*[!0-9]*)
        echo "error: <interval-sec> must be a positive integer, got: '$INTERVAL_SEC'" >&2
        exit 2
        ;;
esac

if [ "$INTERVAL_SEC" -le 0 ]; then
    echo "error: <interval-sec> must be > 0, got: $INTERVAL_SEC" >&2
    exit 2
fi

# Dependency check.
if ! command -v date >/dev/null 2>&1; then
    echo "error: missing dependency: date" >&2
    exit 3
fi

# Ensure the parent directory exists. (The spawn helper should have created it;
# this is a defensive no-op when it already exists.)
mkdir -p "$(dirname "$HEARTBEAT_FILE")"

# Signal-path half of the double safety. Trap the signals that arrive when the
# tmux pane / session is torn down on shells where SIGHUP actually propagates.
trap 'exit 0' TERM INT HUP

while :; do
    # Active-watchdog half of the double safety. When the spawn helper bound
    # this daemon to a specific tmux session via ZYZ_TMUX_SESSION, poll the
    # session's existence each loop iteration and exit 0 the moment it is
    # gone. This is what catches macOS bash's `huponexit=off` default and any
    # other config where the SIGHUP path silently fails.
    if [ -n "${ZYZ_TMUX_SESSION:-}" ]; then
        if command -v tmux >/dev/null 2>&1; then
            if ! tmux has-session -t "$ZYZ_TMUX_SESSION" 2>/dev/null; then
                exit 0
            fi
        fi
    fi

    # ISO 8601 with timezone offset, no fractional seconds.
    # macOS BSD date and GNU date both honor `+%Y-%m-%dT%H:%M:%S%z`.
    ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
    # Write atomically to avoid a partial read race with the orchestrator.
    tmpf="${HEARTBEAT_FILE}.tmp.$$"
    printf '%s\n' "$ts" > "$tmpf"
    mv -f "$tmpf" "$HEARTBEAT_FILE"
    sleep "$INTERVAL_SEC"
done
