#!/usr/bin/env bash
#
# heartbeat.sh — L0 automatic liveness heartbeat (PreToolUse + PostToolUse).
#
# ## Trigger point
#
# Registered in hooks/hooks.json for PreToolUse and PostToolUse with matcher
# "*", synchronous. Fires for every tool call in the main agent AND inside
# every subagent (hooks run inside subagents; input carries agent_id/agent_type).
#
# ## Inputs
#
# - stdin: hook JSON (cwd, agent_id?, agent_type?, ...).
# - env: CLAUDE_PROJECT_DIR (fallback base dir), ZYZ_HOOKS_DISABLE=1 skips.
#
# ## Outputs
#
# - None on stdout.
# - Side effect: advances a fixed HEARTBEAT A/B record for a role instance, or
#   the fixed catalog PACK_HEADER heartbeat record for main; and, for every
#   caller (main agent, subagent, agent-team teammate), stamps
#   <task-dir>/runtime/activity — the session-silence floor (0.32.0), which
#   needs neither the fixed-pack capability nor a role-name match.
#
# ## Failure behavior
#
# Fail open: any missing input, missing task pointer, missing JSON parser, or
# write error exits 0 silently. This hook must never slow or break the loop.
#
# ## Supported agents
#
# All (main agent and every subagent type). No-op unless a task pointer of this
# session resolves (zyz_task_roots: the per-session pointer, the legacy
# `.zyz-worker/current-task`, or $ZYZ_TASK_DIR). A subagent's beat goes to the
# primary task (first pointer line), where subagent-track registered it; the
# main agent's beat and state go to every task of the session.

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

zyz_json_ok || exit 0
ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"
[ -n "$ZYZ_HOOK_INPUT" ] || exit 0

# Opt-in protocol diagnostics for cross-runtime smoke tests. Never enabled by
# the plugin itself; callers must provide an explicit file path.
if [ -n "${ZYZ_HOOK_DEBUG_FILE:-}" ]; then
    umask 077
    printf '%s\n' "$ZYZ_HOOK_INPUT" >> "$ZYZ_HOOK_DEBUG_FILE" 2>/dev/null || true
fi

base="$(zyz_get cwd)"
[ -n "$base" ] || base="${CODEX_PROJECT_DIR:-}"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || base="$PWD"

roots="$(zyz_task_roots "$base")"
[ -n "$roots" ] || exit 0
root="${roots%%
*}"

agent_id="$(zyz_get agent_id)"
agent_type="$(zyz_get agent_type)"
key="main"
[ -n "$agent_id" ] && key="$(zyz_instance_key "$agent_id" 2>/dev/null || true)"
[ -n "$key" ] || exit 0

# Dynamic instances keep heartbeat and inflight authority in their preallocated
# audit/work packs.  The Python mutator revalidates AMBIGUOUS/terminal slots and
# the persistent instance lock; this shell layer intentionally performs no
# pathname existence test for new-format control records.
if [ "$key" != main ]; then
    # Any agent's tool call moves the session (read by the L3 session-silence
    # scan). Recorded under the primary task, where every subagent record lives.
    zyz_activity_mark "$root" "$agent_id"
    # An agent-team teammate calling a tool is in a turn (lib.sh `idle
    # agent-team teammates`), whatever woke it; a background task it starts
    # is recorded as its own, since only the teammate would read the result.
    teammate="$(zyz_teammate_name "$agent_id" "$agent_type")"
    if [ -n "$teammate" ]; then
        zyz_teammate_mark "$root" "$teammate" busy
        if [ "$(zyz_get hook_event_name)" = PostToolUse ] \
            && case "$(zyz_get tool_name)" in Bash|Monitor) true ;; *) false ;; esac; then
            bg_task="$(zyz_get tool_response.backgroundTaskId)"
            [ -n "$bg_task" ] || bg_task="$(zyz_get tool_response.taskId)"
            case "$bg_task" in
                ''|*[!A-Za-z0-9._:-]*) ;;
                *) mkdir -p "$root/runtime/teammates/owned" 2>/dev/null \
                       && zyz_write_atomic "$root/runtime/teammates/owned/$bg_task" "$(zyz_sanitize "$teammate")" ;;
            esac
        fi
    fi
    # A subagent moving on after its own permission prompt closes that dialog
    # (it is recorded with this agent as owner); any other dialog stays open.
    while IFS= read -r state_root; do
        [ -n "$state_root" ] && zyz_dialog_close_by "$state_root" "$agent_id"
    done <<ZYZ_HB_ROOTS
$roots
ZYZ_HB_ROOTS
    # Claude Code names the per-call correlation field tool_use_id; Codex
    # payloads use tool_call_id/call_id. Read them in that order — the
    # INFLIGHT table is keyed by whichever the host actually sends.
    call_id="$(zyz_get tool_use_id)"
    [ -n "$call_id" ] || call_id="$(zyz_get tool_call_id)"
    [ -n "$call_id" ] || call_id="$(zyz_get call_id)"
    "$SCRIPT_DIR/agent-runtime-state.sh" hook-heartbeat "$root" "$agent_id" \
        "${agent_type:-}" "$(zyz_get hook_event_name)" "$call_id" \
        "$(zyz_get tool_name)" >/dev/null 2>&1 || true
    exit 0
fi

# Main-agent state machine: every main-agent tool call refreshes `working`,
# which is the primary signal that pulls the state back out of awaiting-user
# once the user answers. Independent of the runtime_state.py python3 call in
# the loop below: reaching here (past the §zyz_json_ok gate and the main-branch
# split) is enough to record liveness even when python3 is unavailable for the
# heartbeat mutator.
#
# Exception: PreToolUse of AskUserQuestion is the platform-confirmed moment the
# main agent blocks on the user, so it records awaiting-user instead. Claude
# Code does not reliably emit a Notification hook for an AskUserQuestion dialog
# (observed: 1 needs_input across 10 questions, incl. a 10-hour wait), so
# notify.sh alone left the state at `working` and the watchdog nagged every
# cooldown for the whole wait. The matching PostToolUse (the user answered)
# falls through to `working` below.
main_state=working
hook_event="$(zyz_get hook_event_name)"
tool_name="$(zyz_get tool_name)"
if [ "$hook_event" = PreToolUse ] && [ "$tool_name" = AskUserQuestion ]; then
    main_state=awaiting-user
fi
# The user answering an AskUserQuestion is the user speaking: it lapses a
# `kind=user` declaration exactly like a typed prompt (UserPromptSubmit), or a
# declaration written before asking would keep muting no-executor and
# session silence after the answer, until the user next typed.
answered=0
[ "$hook_event" = PostToolUse ] && [ "$tool_name" = AskUserQuestion ] && answered=1
# The main agent asking the user is one of the two moments the user is paged
# (notify.sh Policy). Deferred and dropped if answered by then, so a user at
# the keyboard is not pinged for a question already on their screen.
if [ "$main_state" = awaiting-user ]; then
    question="$(printf '%s' "$ZYZ_HOOK_INPUT" | python3 -c '
import json, sys
try:
    q = json.load(sys.stdin)["tool_input"]["questions"]
    print(" / ".join(" ".join(str(x.get("question") or "").split()) for x in q if isinstance(x, dict))[:300], end="")
except Exception:
    pass
' 2>/dev/null)"
    sid="$(zyz_get session_id)"
    ZYZ_SESSION_ID="${sid:-${ZYZ_SESSION_ID:-}}" "$SCRIPT_DIR/notify.sh" --event needs_input --base "$base" \
        --session-id "$sid" --transcript "$(zyz_get transcript_path)" \
        --message "主 agent 在问你：${question:-（见会话）}" \
        --delay "${ZYZ_NOTIFY_ASK_DELAY_SEC:-60}" --unless-user-since "$(zyz_now)" \
        </dev/null >/dev/null 2>&1 &
fi

while IFS= read -r root; do
    [ -n "$root" ] || continue
    if command -v python3 >/dev/null 2>&1; then
        python3 "$SCRIPT_DIR/runtime_state.py" hook-main-heartbeat "$root" \
            "${agent_type:-main}" >/dev/null 2>&1 || true
    fi
    zyz_activity_mark "$root" main
    zyz_main_state_set "$root" "$main_state" main
    [ "$answered" = 0 ] || zyz_write_atomic "$root/runtime/user-prompt-epoch" "$(zyz_now)"
    # Any main-agent tool call ends the "stopped since the last Stop" window
    # the L3 no-executor scan reads (#24).
    rm -f "$root/runtime/stop-snapshot" 2>/dev/null
done <<EOF
$roots
EOF

exit 0
