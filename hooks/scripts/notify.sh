#!/usr/bin/env bash
#
# notify.sh — L7 IM notifier: forwards agent-stop events to a user-configured
# command (Feishu / Telegram / any webhook) so the user is pinged when the
# workflow needs them or finishes.
#
# ## Trigger point
#
# Registered in hooks/hooks.json (all async, so IM latency never slows the
# workflow) for the events that are actually catchable by a hook:
#   - Notification  (permission_prompt / idle_prompt / agent_needs_input /
#                    agent_completed / elicitation_*) — "the agent stopped and
#                    needs / awaits you". Fires only when the user is away
#                    (~6s permission / ~60s idle), so it does not spam an
#                    actively-typing user.
#   - StopFailure   (API-error terminations: rate_limit / authentication /
#                    overloaded / server_error) — the catchable slice of
#                    "abnormal interruption".
#   - SessionEnd    (graceful close: logout / prompt_input_exit / clear /
#                    resume / other) — OFF by default (the user quit; they
#                    already know).
# Also invoked directly by monitors/watchdog.sh with `--event stuck ...` when a
# role goes silent / a status file goes stale / a completion is unharvested —
# the in-session portion of "agent crashed / got stuck". A true whole-process
# crash (kill -9 / OOM / terminal close / network drop) fires no hook and takes
# the monitor down with it, so it is NOT covered here (documented in README).
#
# Every path is workflow-scoped: it no-ops unless a `.zyz-worker/current-task`
# pointer resolves — exactly like the rest of the layer — so ordinary
# interactive sessions are never touched.
#
# ## Inputs
#
# - Hook mode: hook JSON on stdin (hook_event_name, notification_type?, cwd,
#   session_id?, message?, title?, error?, reason?).
# - Direct mode: `--event <category> [--title T] [--message M]
#   [--base DIR | --task-root DIR] [--session-id S]`.
# - Config file `~/.zyz-worker/notify.json` (override with $ZYZ_NOTIFY_CONFIG).
# - env: ZYZ_HOOKS_DISABLE=1 or ZYZ_NOTIFY_DISABLE=1 skips the whole notifier.
#
# ## Config schema (~/.zyz-worker/notify.json)
#
#   { "enabled": true,
#     "command": "…user shell command…",
#     "events": ["needs_input","completed","failed","stuck"],  // optional
#     "cooldown_sec": 30,          // optional, default 30
#     "include_message": true }    // optional, default true
#
# When "events" is absent the default set is
# needs_input/completed/failed/stuck (session_end excluded). The user command
# receives the event both as ZYZ_NOTIFY_* environment variables and as a JSON
# object on stdin.
#
# ## Outputs
#
# - None on stdout (notification hooks cannot influence Claude anyway). Side
#   effect: runs the configured command with the payload; stamps
#   `<task-root>/runtime/nag/notify-<category>.last` for the per-category
#   cooldown.
#
# ## Failure behavior
#
# Fail open: any missing input/config/parser/pointer, a disabled config, a
# filtered-out event, or an active cooldown exits 0 with no side effect. A
# failing user command never propagates. The notifier must never break or slow
# the workflow it observes.
#
# ## Supported agents
#
# Main agent (Notification/StopFailure/SessionEnd are main-session events) plus
# the watchdog monitor (stuck). macOS bash 3.2 + Linux compatible.

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0
[ "${ZYZ_NOTIFY_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

zyz_json_ok || exit 0

# ---- argument / mode parsing -------------------------------------------------
category=""
arg_title=""
arg_message=""
arg_base=""
arg_root=""
arg_session=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --event) category="${2:-}"; shift 2 ;;
        --title) arg_title="${2:-}"; shift 2 ;;
        --message) arg_message="${2:-}"; shift 2 ;;
        --base) arg_base="${2:-}"; shift 2 ;;
        --task-root) arg_root="${2:-}"; shift 2 ;;
        --session-id) arg_session="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

event_message=""
event_title=""
session_id="$arg_session"

if [ -z "$category" ]; then
    # Hook mode: read stdin JSON and map the event to a category.
    ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"
    [ -n "$ZYZ_HOOK_INPUT" ] || exit 0
    hook_event="$(zyz_get hook_event_name)"
    session_id="$(zyz_get session_id)"
    case "$hook_event" in
        Notification)
            ntype="$(zyz_get notification_type)"
            case "$ntype" in
                permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog)
                    category="needs_input" ;;
                agent_completed|idle_prompt)
                    category="completed" ;;
                *) exit 0 ;;
            esac
            event_message="$(zyz_get message)"
            ;;
        StopFailure)
            category="failed"
            event_message="$(zyz_get error)"
            [ -n "$event_message" ] || event_message="$(zyz_get message)"
            ;;
        SessionEnd)
            category="session_end"
            event_message="$(zyz_get reason)"
            ;;
        *) exit 0 ;;
    esac
    arg_base="$(zyz_get cwd)"
else
    # Direct mode (watchdog): trust the passed category and text.
    event_message="$arg_message"
    event_title="$arg_title"
fi

case "$category" in
    needs_input|completed|failed|stuck|session_end) ;;
    *) exit 0 ;;
esac

# ---- scope gate: only inside an execute-task / orchestrate workflow ----------
root="$arg_root"
if [ -z "$root" ]; then
    base="$arg_base"
    [ -n "$base" ] || base="${CODEX_PROJECT_DIR:-}"
    [ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
    [ -n "$base" ] || base="$PWD"
    root="$(zyz_task_root "$base")"
fi
[ -n "$root" ] || exit 0

# ---- config -----------------------------------------------------------------
config="${ZYZ_NOTIFY_CONFIG:-$HOME/.zyz-worker/notify.json}"
[ -f "$config" ] || exit 0

notify_cfg() {
    # $1 = top-level scalar key. Prints its value or empty. Uses has()+tostring
    # rather than `// empty` on purpose: jq's `//` treats a literal `false` as
    # empty, which would silently turn `include_message:false` / `enabled:false`
    # into their defaults.
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$1" 'if has($k) and (.[$k] != null) then (.[$k] | tostring) else empty end' "$config" 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    v = d.get(sys.argv[2])
    if v is None:
        sys.exit(0)
    if isinstance(v, bool):
        print("true" if v else "false")
    elif isinstance(v, (dict, list)):
        sys.exit(0)
    else:
        print(v)
except Exception:
    pass
' "$config" "$1" 2>/dev/null
        return 0
    fi
    return 0
}

notify_event_enabled() {
    # 0 when $1 (category) is enabled: in the explicit "events" array, or — when
    # "events" is absent — in the default set (session_end excluded).
    if command -v jq >/dev/null 2>&1; then
        jq -e --arg c "$1" '
            if has("events")
            then ((.events // []) | index($c) != null)
            else (["needs_input","completed","failed","stuck"] | index($c) != null)
            end' "$config" >/dev/null 2>&1
        return $?
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    cat = sys.argv[2]
    if "events" in d:
        allowed = d.get("events") or []
    else:
        allowed = ["needs_input", "completed", "failed", "stuck"]
    sys.exit(0 if cat in allowed else 1)
except Exception:
    sys.exit(1)
' "$config" "$1"
        return $?
    fi
    return 1
}

[ "$(notify_cfg enabled)" = "true" ] || exit 0
command_line="$(notify_cfg command)"
[ -n "$command_line" ] || exit 0
notify_event_enabled "$category" || exit 0

include_message="$(notify_cfg include_message)"
[ "$include_message" = "false" ] || include_message="true"

# ---- per-category cooldown ---------------------------------------------------
cooldown="$(notify_cfg cooldown_sec)"
case "$cooldown" in ''|*[!0-9]*) cooldown=30 ;; esac
zyz_cooldown_ok "$root/runtime/nag/notify-$category.last" "$cooldown" || exit 0

# ---- build payload ----------------------------------------------------------
task_id="$(basename "$root" 2>/dev/null)"
phase="$(zyz_phase_of "$root/status.md")"
host="$(hostname 2>/dev/null || echo unknown)"
timestamp="$(zyz_iso)"

# title: our own category label (always safe to send). message: the event's
# free text, sent only when include_message is true (privacy control).
if [ -z "$event_title" ]; then
    case "$category" in
        needs_input) event_title="Agent needs your input" ;;
        completed)   event_title="Agent finished and is waiting" ;;
        failed)      event_title="Agent interrupted by an error" ;;
        stuck)       event_title="Agent appears stuck" ;;
        session_end) event_title="Session ended" ;;
    esac
fi
[ "$include_message" = "true" ] || event_message=""

payload=""
if command -v jq >/dev/null 2>&1; then
    payload="$(jq -cn \
        --arg event "$category" --arg title "$event_title" \
        --arg message "$event_message" --arg task_id "$task_id" \
        --arg phase "$phase" --arg cwd "$root" --arg session_id "$session_id" \
        --arg host "$host" --arg timestamp "$timestamp" \
        '{event:$event,title:$title,message:$message,task_id:$task_id,phase:$phase,cwd:$cwd,session_id:$session_id,host:$host,timestamp:$timestamp}' \
        2>/dev/null)"
elif command -v python3 >/dev/null 2>&1; then
    payload="$(EV="$category" TI="$event_title" MS="$event_message" TK="$task_id" \
        PH="$phase" CW="$root" SE="$session_id" HO="$host" TS="$timestamp" \
        python3 -c '
import json, os
print(json.dumps({
    "event": os.environ["EV"], "title": os.environ["TI"],
    "message": os.environ["MS"], "task_id": os.environ["TK"],
    "phase": os.environ["PH"], "cwd": os.environ["CW"],
    "session_id": os.environ["SE"], "host": os.environ["HO"],
    "timestamp": os.environ["TS"],
})' 2>/dev/null)"
fi

# ---- dispatch (fail-open; asynchrony is provided by the async hook
# registration and by the watchdog backgrounding its call) --------------------
ZYZ_NOTIFY_EVENT="$category" \
ZYZ_NOTIFY_TITLE="$event_title" \
ZYZ_NOTIFY_MESSAGE="$event_message" \
ZYZ_NOTIFY_TASK_ID="$task_id" \
ZYZ_NOTIFY_PHASE="$phase" \
ZYZ_NOTIFY_CWD="$root" \
ZYZ_NOTIFY_SESSION_ID="$session_id" \
ZYZ_NOTIFY_HOST="$host" \
ZYZ_NOTIFY_TIMESTAMP="$timestamp" \
ZYZ_NOTIFY_PAYLOAD="$payload" \
    sh -c "$command_line" <<EOF >/dev/null 2>&1 || true
$payload
EOF
exit 0
