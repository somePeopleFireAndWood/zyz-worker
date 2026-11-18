#!/usr/bin/env bash
#
# expect.sh — the main agent's interface to the watchdog (#24).
#
# The watchdog does not guess why a task is quiet; the main agent DECLARES it,
# and the watchdog holds it to the declaration. Run by the MAIN agent in its
# own Bash (never by a subagent). Writes only to the `## Agent State` section
# of <task-dir>/status.md, atomically, and validates every row before writing —
# a hand-written row with a typo silently does nothing, this refuses it.
#
# Usage:
#   expect.sh set <key> wait     --at <when> [--ref <bg-task-id>] --reason <text>
#   expect.sh set <key> user     --reason <text>
#   expect.sh set <key> resident --ref <bg-task-id> --reason <text>
#   expect.sh clear <key> | --all
#   expect.sh tune status-stale-sec=<n> no-executor-sec=<n> remind-sec=<n> | --clear
#   expect.sh list
#   <when>: +30m / +2h / +1d, an epoch, or ISO `2026-11-19T02:30[+08:00]`.
#   --task <task-dir> picks the task; default is this session's primary task
#   (the first line of its task pointer, see task-pointer.sh).
#
# Kinds:
#   wait      something moves the task by <when>: a background run (give its id
#             as --ref; the row lapses as soon as that task is gone), an outside
#             batch job, or a scheduled re-check in the `observing` phase. Mutes
#             the status-stale and no-executor findings until <when>; then the
#             watchdog wakes you, and repeats every remind-sec until you clear
#             or move the row.
#   user      you are stopping to wait on the user. Lapses at the user's next
#             message; set it again if you are still waiting after that.
#   resident  a background task that never ends and never moves the task (dev
#             server, `tail -f` Monitor, unrelated cron); not counted as an
#             executor. Use the id the Bash/Monitor/CronCreate tool returned.
#
# Exit: 0 ok; non-zero with a one-line diagnostic on any invalid input.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || { echo "expect: cannot load lib.sh" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "expect: python3 is required" >&2; exit 2; }

task=""
args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --task) task="${2:-}"; shift 2 || { echo "expect: --task needs a dir" >&2; exit 2; } ;;
        *) args+=("$1"); shift ;;
    esac
done
if [ "${#args[@]}" -eq 0 ]; then
    sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

if [ -z "$task" ]; then
    task="$(zyz_task_root "$PWD")"
    if [ -z "$task" ]; then
        echo "expect: no task pointer resolves for this session — run task-pointer.sh arm <task-dir> first, or pass --task <task-dir>" >&2
        exit 2
    fi
fi
[ -d "$task" ] || { echo "expect: task dir not found: $task" >&2; exit 2; }
status="$task/status.md"
[ -f "$status" ] || { echo "expect: $status does not exist" >&2; exit 2; }

prompt_epoch="$(zyz_epoch_in "$task/runtime/user-prompt-epoch")"
ZYZ_EXPECT_PROMPT_EPOCH="${prompt_epoch:-0}" exec python3 "$SCRIPT_DIR/expect_state.py" "${args[0]}" "$status" "${args[@]:1}"
