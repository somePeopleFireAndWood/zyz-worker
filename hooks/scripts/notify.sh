#!/usr/bin/env bash
#
# notify.sh — L7 IM notifier: forwards events to a user-configured command
# (Feishu / Telegram / any webhook).
#
# ## Policy (0.32.0)
#
# The user is paged only when the task needs a human or is done. While a task
# is executing, the watchdog wakes the MAIN agent instead; a stop, a subagent's
# step, a subagent's death are the main agent's business, not the user's.
#   - needs_input: a dialog is open (permission prompt, MCP elicitation,
#     agent_needs_input), the main agent called AskUserQuestion (heartbeat.sh),
#     or it declared `expect.sh set <key> user` for a question asked in prose.
#     The last two are deferred (--delay) and dropped if the user has spoken
#     since (--unless-user-since): an answer within a minute pages nobody.
#   - completed: the task entered a hand-off phase (awaiting-confirmation,
#     observing, done), fired once per entry by main-state.sh on Stop; or the
#     main agent stopped in the design phase with no executor and no
#     declaration (most likely at the approval gate, undeclared).
#   - failed: the MAIN agent's own turn ended on an API error (StopFailure
#     without agent_id) — nothing will resume it. A subagent's failure goes to
#     the main agent through the watchdog (api-failure.sh).
#   - stuck: escalation only — the watchdog reported a finding to the main
#     agent and, by its next report, nobody in the session had moved.
#   - session_end: OFF by default.
# A whole-process crash (kill -9 / OOM / terminal close) fires no hook and
# takes the monitor down with it, so it is NOT covered here.
#
# ## Trigger point
#
# Registered in hooks/hooks.json (all async) for Notification, StopFailure and
# SessionEnd; invoked directly (`--event ...`) by heartbeat.sh, expect.sh,
# main-state.sh and monitors/watchdog.sh.
#
# Every path is workflow-scoped: it no-ops unless a task pointer of this
# session resolves (zyz_task_roots) — exactly like the rest of the layer — so
# ordinary interactive sessions are never touched.
#
# ## Inputs
#
# - Hook mode: hook JSON on stdin (hook_event_name, notification_type?, cwd,
#   session_id?, message?, title?, error?, reason?).
# - Direct mode: `--event <category> [--title T] [--message M]
#   [--base DIR | --task-root DIR] [--session-id S] [--transcript PATH]
#   [--origin main|subagent|stall] [--task-id LABEL] [--delay SEC]
#   [--unless-user-since EPOCH]`. `--delay` sleeps first (callers background
#   the call); `--unless-user-since` then drops the event if the task's
#   runtime/user-prompt-epoch is later than EPOCH (the user already answered). `--task-id` overrides the reported task id: the
#   watchdog passes every task of a multi-task session for a subagent finding,
#   whose owning task it cannot know (#23).
#   `--origin` (default main) splits stuck delivery (F2): a main-origin stuck
#   (status-stale derived) is suppressed while the main agent is awaiting-user /
#   idle; a subagent-origin stuck (a truly dead role) bypasses that suppression,
#   and so does a stall-origin stuck (#24: the task has no executor at all —
#   the main agent being idle is the symptom being reported, not an excuse).
# - Config file `~/.zyz-worker/notify.json` (override with $ZYZ_NOTIFY_CONFIG).
# - env: ZYZ_HOOKS_DISABLE=1 or ZYZ_NOTIFY_DISABLE=1 skips the whole notifier.
#
# ## Config schema (~/.zyz-worker/notify.json)
#
#   { "enabled": true,
#     "command": "…user shell command…",
#     "events": ["needs_input","completed","failed","stuck"], // optional
#     "cooldown_sec": 30,          // optional, default 30
#     "include_message": true }    // optional, default true
#
# When "events" is absent the default set is needs_input/completed/failed/
# stuck (session_end excluded). The user command receives the event both as
# ZYZ_NOTIFY_* environment variables and as a JSON object on stdin, including
# the session's display name (ZYZ_NOTIFY_SESSION_NAME / session_name, see
# lib.sh zyz_session_name), which also prefixes the title so any renderer shows
# it. A Notification whose raw notification_type is one of permission_prompt /
# agent_needs_input / elicitation_dialog / elicitation_url_dialog records the
# main-agent state as `awaiting-user`; idle_prompt records `idle` and sends
# nothing (both before the config gate, so the state machine works even with
# no notify.json).
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
arg_origin="main"
arg_task_id=""
arg_transcript=""
arg_delay=0
arg_unless=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --event) category="${2:-}"; shift 2 ;;
        --title) arg_title="${2:-}"; shift 2 ;;
        --message) arg_message="${2:-}"; shift 2 ;;
        --base) arg_base="${2:-}"; shift 2 ;;
        --task-root) arg_root="${2:-}"; shift 2 ;;
        --session-id) arg_session="${2:-}"; shift 2 ;;
        --origin) arg_origin="${2:-}"; shift 2 ;;
        --task-id) arg_task_id="${2:-}"; shift 2 ;;
        --transcript) arg_transcript="${2:-}"; shift 2 ;;
        --delay) arg_delay="${2:-0}"; shift 2 ;;
        --unless-user-since) arg_unless="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

event_message=""
event_title=""
session_id="$arg_session"
transcript="$arg_transcript"

if [ -z "$category" ]; then
    # Hook mode: read stdin JSON and map the event to a category.
    ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"
    [ -n "$ZYZ_HOOK_INPUT" ] || exit 0
    hook_event="$(zyz_get hook_event_name)"
    session_id="$(zyz_get session_id)"
    transcript="$(zyz_get transcript_path)"
    case "$hook_event" in
        Notification)
            ntype="$(zyz_get notification_type)"
            case "$ntype" in
                permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog)
                    category="needs_input" ;;
                # "Stopped ~60 s ago, user away" (after every stop) and a
                # background agent finishing are not a reason to page: the
                # stop itself is the main agent's business (see Policy).
                # idle_prompt still moves the state machine below.
                idle_prompt) category="state_only" ;;
                *) exit 0 ;;
            esac
            event_message="$(zyz_get message)"
            ;;
        StopFailure)
            # A subagent / teammate failure is reported to the main agent by
            # the watchdog (api-failure.sh); only the main agent's own failure
            # needs a human.
            [ -z "$(zyz_get agent_id)" ] || exit 0
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
    needs_input|completed|failed|stuck|session_end|state_only) ;;
    *) exit 0 ;;
esac

# ---- scope gate: only inside an execute-task / orchestrate workflow ----------
root="$arg_root"
roots="$arg_root"
if [ -z "$root" ]; then
    base="$arg_base"
    [ -n "$base" ] || base="${CODEX_PROJECT_DIR:-}"
    [ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
    [ -n "$base" ] || base="$PWD"
    # Every task of this session. One host event still sends at most one
    # message; it is stamped under the primary (first) task's runtime/ and
    # names every task, since the event belongs to the session, not to one task.
    roots="$(zyz_task_roots "$base")"
    root="${roots%%
*}"
    if [ -z "$arg_task_id" ] && [ "$(zyz_roots_count "$roots")" -gt 1 ]; then
        arg_task_id="$(zyz_roots_label "$roots")"
    fi
fi
[ -n "$root" ] || exit 0

# ---- main-agent state machine: record the dialog state (before config gate) --
# The state write must not depend on whether the user configured IM (notify.json):
# even with no config, an open dialog records awaiting-user. Judgement is on the
# RAW notification_type (ntype), not the folded category. awaiting-user means
# "a dialog is open right now" (permission prompt, MCP elicitation, a teammate's
# setup question); idle_prompt — "Claude finished responding ~60 s ago and you
# haven't interacted" — is NOT a dialog and records idle, or a stop with the
# user away would read as "waiting on the user" a minute later and mute any
# check that honours an open dialog (the session-silence scan). set -u safe:
# hook_event/ntype are unset in direct mode and for StopFailure/SessionEnd, so
# guard with ${var:-} and require hook_event == Notification first.
if [ "${hook_event:-}" = Notification ]; then
    case "${ntype:-}" in
        permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog) dialog_state=awaiting-user ;;
        idle_prompt) dialog_state=idle ;;
        *) dialog_state="" ;;
    esac
    # A dialog's owner: the subagent / teammate whose tool call raised it (the
    # hook carries its agent_id), else the main agent. Only the owner's next
    # step closes it (lib.sh zyz_user_dialog_open).
    dialog_owner="$(zyz_get agent_id)"
    if [ -n "$dialog_state" ]; then
        while IFS= read -r state_root; do
            [ -n "$state_root" ] && zyz_main_state_set "$state_root" "$dialog_state" "${dialog_owner:-main}"
        done <<ZYZ_NOTIFY_ROOTS
$roots
ZYZ_NOTIFY_ROOTS
    fi
fi

[ "$category" != state_only ] || exit 0

# ---- deferred questions: drop once the user has answered --------------------
case "$arg_delay" in ''|*[!0-9]*) arg_delay=0 ;; esac
[ "$arg_delay" -eq 0 ] || sleep "$arg_delay"
case "$arg_unless" in
    ''|*[!0-9]*) ;;
    *) spoke="$(zyz_epoch_in "$root/runtime/user-prompt-epoch")"
       [ -n "$spoke" ] && [ "$spoke" -gt "$arg_unless" ] && exit 0 ;;
esac

# ---- stuck IM origin gate (F2) ----------------------------------------------
# main-origin stuck (status-stale derived) is suppressed while the main agent is
# awaiting-user / idle; subagent-origin stuck (a truly dead/silent role) bypasses
# the suppression so an offline user is still paged. set -u safe throughout.
if [ "${category:-}" = stuck ] && [ "${arg_origin:-main}" = main ] \
    && zyz_main_state_suppresses "$root"; then
    exit 0
fi

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
task_id="${arg_task_id:-$(basename "$root" 2>/dev/null)}"
phase="$(zyz_phase_of "$root/status.md")"
host="$(hostname 2>/dev/null || echo unknown)"
timestamp="$(zyz_iso)"

# title: our own category label (always safe to send). message: the event's
# free text, sent only when include_message is true (privacy control).
if [ -z "$event_title" ]; then
    case "$category" in
        needs_input) event_title="Agent 需要你的输入" ;;
        completed)   event_title="Agent 已完成，正在等你" ;;
        failed)      event_title="Agent 因错误中断" ;;
        stuck)       event_title="Agent 似乎卡住了" ;;
        session_end) event_title="会话已结束" ;;
    esac
fi
[ "$include_message" = "true" ] || event_message=""
# Which session to open. The name is derived from the conversation, so it
# follows include_message; without it the short session id still points there.
[ -n "$session_id" ] || session_id="$(zyz_session_id)"
session_name=""
if [ "$include_message" = "true" ]; then
    session_name="$(zyz_session_name "$session_id" "$transcript")"
fi
session_label="$session_name"
[ -n "$session_label" ] || session_label="${session_id:0:8}"
[ -z "$session_label" ] || event_title="【${session_label}】${event_title}"

payload=""
if command -v jq >/dev/null 2>&1; then
    payload="$(jq -cn \
        --arg event "$category" --arg title "$event_title" \
        --arg message "$event_message" --arg task_id "$task_id" \
        --arg phase "$phase" --arg cwd "$root" --arg session_id "$session_id" \
        --arg host "$host" --arg timestamp "$timestamp" --arg session_name "$session_name" \
        '{event:$event,title:$title,message:$message,task_id:$task_id,phase:$phase,cwd:$cwd,session_id:$session_id,session_name:$session_name,host:$host,timestamp:$timestamp}' \
        2>/dev/null)"
elif command -v python3 >/dev/null 2>&1; then
    payload="$(EV="$category" TI="$event_title" MS="$event_message" TK="$task_id" \
        PH="$phase" CW="$root" SE="$session_id" SN="$session_name" HO="$host" TS="$timestamp" \
        python3 -c '
import json, os
print(json.dumps({
    "event": os.environ["EV"], "title": os.environ["TI"],
    "message": os.environ["MS"], "task_id": os.environ["TK"],
    "phase": os.environ["PH"], "cwd": os.environ["CW"],
    "session_id": os.environ["SE"], "session_name": os.environ["SN"],
    "host": os.environ["HO"],
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
ZYZ_NOTIFY_SESSION_NAME="$session_name" \
ZYZ_NOTIFY_HOST="$host" \
ZYZ_NOTIFY_TIMESTAMP="$timestamp" \
ZYZ_NOTIFY_PAYLOAD="$payload" \
    sh -c "$command_line" <<EOF >/dev/null 2>&1 || true
$payload
EOF
exit 0
