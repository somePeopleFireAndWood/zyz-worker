#!/usr/bin/env bash
#
# main-state.sh — main-agent state machine writer (UserPromptSubmit / Stop /
# SessionEnd). Pure signal driven, NO TTL.
#
# ## Trigger point
#
# Registered in hooks/hooks.json for UserPromptSubmit (write `working`), Stop
# (write `idle`, with awaiting-user overwrite immunity), and SessionEnd (write
# `ended`). All three fire only in the main session, so this only ever records
# main-agent state. Runs alongside stop-gate-main.sh (Stop) and notify.sh
# (SessionEnd) without depending on their order — it only writes, they only read.
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
#   <task-root>/runtime/main-state. On a Stop that actually wrote `idle` during
#   an active phase, also fires notify.sh --event idle in the background (F4).
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
            # Stop overwrite immunity: if the state is already awaiting-user, do
            # NOT overwrite it to idle and do NOT fire the idle IM — the user is
            # still being waited on (a needs_input round that then hit Stop),
            # which is not "stopped and handed back". Leaving awaiting-user in
            # place keeps the suppression correct and avoids a misleading idle
            # IM. Only working->idle and no-state->idle actually write idle.
            if zyz_main_state_awaiting "$root"; then
                return 0
            fi
            state=idle
            ;;
        SessionEnd)
            state=ended
            ;;
    esac

    zyz_main_state_set "$root" "$state"

    # The user just spoke (#24): record when, so an Awaiting-User declaration
    # written before this moment lapses (zyz_status_awaiting_user), and end the
    # L3 no-executor window opened by the previous Stop.
    if [ "$hook_event" = UserPromptSubmit ]; then
        mkdir -p "$root/runtime" 2>/dev/null \
            && zyz_write_atomic "$root/runtime/user-prompt-epoch" "$(zyz_now)"
        rm -f "$root/runtime/stop-snapshot" 2>/dev/null
    fi

    # F4: when a Stop actually wrote idle during an active execution phase, fire
    # an independent `idle` IM in the background so the user learns the main
    # agent stopped and handed control back. The active-phase filter lives here
    # (not in notify.sh) because only this script holds both "the event was
    # Stop" and "idle was actually written (not immunity-skipped)". Non-active
    # phases (design / terminal) do not fire — matching the watchdog's
    # active-phase scope. notify.sh then applies its own config gate +
    # per-category cooldown. Backgrounded and fully redirected so it never
    # blocks Stop.
    if [ "$hook_event" = Stop ] && [ "$state" = idle ]; then
        phase="$(zyz_phase_of "$root/status.md")"
        if zyz_phase_active "$phase"; then
            "$SCRIPT_DIR/notify.sh" --event idle --task-root "$root" >/dev/null 2>&1 &
        fi
    fi
}

while IFS= read -r root; do
    [ -n "$root" ] || continue
    apply_state "$root"
done <<EOF
$roots
EOF

exit 0
