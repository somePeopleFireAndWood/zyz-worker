#!/usr/bin/env bash
#
# main-state.sh — main-agent state machine writer (UserPromptSubmit / Stop /
# SessionEnd). Pure signal driven, NO TTL.
#
# ## Trigger point
#
# Registered in hooks/hooks.json for UserPromptSubmit (write `working`), Stop
# (write `idle`), and SessionEnd (write `ended`). All three fire only in the
# main session, so this only ever records main-agent state. Runs alongside
# stop-gate-main.sh (Stop) and notify.sh (SessionEnd) without depending on
# their order — it only writes, they only read.
#
# `awaiting-user` means a dialog is open right now (AskUserQuestion, a
# permission prompt, an MCP elicitation). A Stop means the turn has ended, so
# any such dialog is closed: Stop always writes `idle`. (Before 0.32.0 a Stop
# left an existing awaiting-user in place; that kept a stale "dialog open"
# after a denied permission prompt, and idle_prompt — "stopped ~60 s ago, user
# away", no dialog involved — made awaiting-user mean nothing more than
# "stopped".)
#
# ## Inputs
#
# - stdin: hook JSON (hook_event_name, cwd, agent_id?).
# - env: CLAUDE_PROJECT_DIR (fallback base dir), ZYZ_HOOKS_DISABLE=1 skips.
#
# ## Outputs
#
# - None on stdout.
# - Side effect: atomically writes `<state> <epoch>` to
#   <task-root>/runtime/main-state. On a Stop, also fires notify.sh --event
#   completed in the background when the task has just been handed to the user
#   (see below) — never for an ordinary stop of an executing task.
#   On UserPromptSubmit, also writes <task-root>/runtime/user-prompt-epoch (the
#   lapse point of Awaiting-User declarations) and deletes the L3 no-executor
#   stop-snapshot (#24).
#
# ## Failure behavior
#
# Fail open: missing input, missing task pointer, missing JSON parser, a
# non-empty agent_id (subagent), an unmapped event, or a write error exits 0
# with no side effect. Never blocks or slows the agent loop.
#
# ## Supported agents
#
# Main agent only. No-op unless a task pointer of this session resolves
# (zyz_task_roots); every task of the session gets its own state write.
# macOS bash 3.2 + Linux compatible.

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

zyz_json_ok || exit 0
ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"
[ -n "$ZYZ_HOOK_INPUT" ] || exit 0

base="$(zyz_get cwd)"
[ -n "$base" ] || base="${CODEX_PROJECT_DIR:-}"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || base="$PWD"
roots="$(zyz_task_roots "$base")"
[ -n "$roots" ] || exit 0

# main-state is written only by main-agent events. UserPromptSubmit/Stop/
# SessionEnd never fire inside a subagent, so this is defensive redundancy
# consistent with heartbeat.sh's convention (empty agent_id == main).
agent_id="$(zyz_get agent_id)"
[ -n "$agent_id" ] && exit 0

hook_event="$(zyz_get hook_event_name)"
case "$hook_event" in
    UserPromptSubmit|Stop|SessionEnd) ;;
    *) exit 0 ;;
esac

# The main agent owns every task of its session, so each task's state machine
# moves on its own.
apply_state() {
    local root state phase
    root="$1"
    case "$hook_event" in
        UserPromptSubmit)
            state=working
            ;;
        Stop)
            state=idle
            ;;
        SessionEnd)
            state=ended
            ;;
    esac

    zyz_main_state_set "$root" "$state"

    # The user just spoke (#24): record when, so an Awaiting-User declaration
    # written before this moment lapses (expect_state.py kind=user), and end the
    # L3 no-executor window opened by the previous Stop.
    if [ "$hook_event" = UserPromptSubmit ]; then
        mkdir -p "$root/runtime" 2>/dev/null \
            && zyz_write_atomic "$root/runtime/user-prompt-epoch" "$(zyz_now)"
        rm -f "$root/runtime/stop-snapshot" 2>/dev/null
    fi

    [ "$hook_event" = Stop ] && stop_notify "$root"
}

# The user is paged when the task is handed to them, not on every stop (0.32.0;
# before, every Stop of an active task sent an `idle` IM, so each step of a
# subagent the main agent merely relayed paged the user). Two shapes:
#   - the task entered a hand-off phase (awaiting-confirmation, observing,
#     done): once per entry — runtime/nag/handoff-phase remembers the phase
#     announced, and any non-hand-off phase forgets it;
#   - (needs_input) the main agent stopped in the design phase with no executor and no valid
#     user declaration: most likely at the approval gate, undeclared. The
#     design phase has no stop gate (it promises to idle there), so this is
#     the only guard that tells the user. Unknown executors (no
#     background_tasks, Codex) fail closed to silence.
# A question asked while executing pages through AskUserQuestion / expect.sh
# user instead. Backgrounded and fully redirected so it never blocks Stop.
stop_notify() {
    local root phase mark expect left msg="" event=completed
    root="$1"
    phase="$(zyz_phase_of "$root/status.md")"
    mark="$root/runtime/nag/handoff-phase"
    if zyz_phase_handoff "$phase"; then
        [ "$(head -n1 "$mark" 2>/dev/null)" != "$phase" ] || return 0
        mkdir -p "$root/runtime/nag" 2>/dev/null && zyz_write_atomic "$mark" "$phase"
        if zyz_phase_terminal "$phase"; then
            msg="任务已完成（${phase}）"
        elif zyz_phase_observing "$phase"; then
            msg="主体已交付，进入观察期（${phase}），之后按排定的时间复查"
        else
            msg="任务已交付，等你确认（${phase}）"
        fi
    else
        rm -f "$mark" 2>/dev/null
        case "$phase" in *design*) ;; *) return 0 ;; esac
        expect="$(zyz_expect_eval "$root" unknown)"
        zyz_expect_known "$expect" || return 0
        [ "$(zyz_expect_field "$expect" users)" = 0 ] || return 0
        left="$(zyz_executors_left "$(zyz_bg_executor_ids)" "$(zyz_expect_field "$expect" residents)")"
        [ "$left" = 0 ] || return 0
        event=needs_input
        msg="主 agent 在设计阶段停下了，没有在跑的执行者——多半在等你批准设计或回答问题"
    fi
    "$SCRIPT_DIR/notify.sh" --event "$event" --task-root "$root" --message "$msg" \
        --session-id "$(zyz_get session_id)" --transcript "$(zyz_get transcript_path)" \
        </dev/null >/dev/null 2>&1 &
}

while IFS= read -r root; do
    [ -n "$root" ] || continue
    apply_state "$root"
done <<EOF
$roots
EOF

exit 0
