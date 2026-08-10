#!/usr/bin/env bash
#
# status-freshness.sh — L1 status-file freshness reminder (PostToolUse).
#
# ## Trigger point
#
# Registered in hooks/hooks.json for PostToolUse with matcher "*", sync
# (must be sync so additionalContext lands next to the tool result). Fires
# in the main agent and inside every subagent.
#
# ## Inputs
#
# - stdin: hook JSON (cwd, agent_id?, agent_type?).
# - env: CLAUDE_PROJECT_DIR (fallback base dir), ZYZ_HOOKS_DISABLE=1 skips,
#   ZYZ_STATUS_STALE_SEC (default 600) staleness threshold,
#   ZYZ_STATUS_NAG_COOLDOWN_SEC (default 300) min gap between reminders per
#   audience.
#
# ## Outputs
#
# - When `<task-root>/status.md` exists, its mtime is older than
#   ZYZ_STATUS_STALE_SEC, the task phase is an active execution phase, and
#   the per-audience cooldown has elapsed: prints hookSpecificOutput
#   additionalContext telling the CURRENT context (main agent or the
#   subagent that made the tool call) to persist progress into the status
#   file now. Otherwise prints nothing.
# - Side effect: stamps `<task-root>/runtime/nag/<audience>.last` (epoch)
#   for the cooldown.
#
# ## Failure behavior
#
# Fail open: any missing input/pointer/parser exits 0 with no output. The
# reminder is advisory context, never a block.
#
# ## Supported agents
#
# All (main agent and subagents). Review-agent is excluded from the
# subagent reminder text (it must not write files); it still triggers no
# output because the audience filter skips it.

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

root="$(zyz_task_root "$base")"
[ -n "$root" ] || exit 0
status_file="$root/status.md"
[ -f "$status_file" ] || exit 0

# Defer to post-agent-flush.sh on an Agent return. Both hooks are sync
# PostToolUse and both read this same status-file mtime, so on a stale-status
# Agent return they BOTH injected the same "persist the status file" instruction
# into one turn (verified) — their cooldowns are independent, so neither
# suppressed the other. post-agent-flush.sh owns that moment: its message is
# more specific (it names the just-received subagent result and says to persist
# it before dispatching further work) and its threshold is tighter. Everything
# else still gets this hook's reminder.
case "$(zyz_get tool_name)" in Agent|spawn_agent|collaboration.spawn_agent) exit 0 ;; esac

phase="$(zyz_phase_of "$status_file")"
zyz_phase_active "$phase" || exit 0

stale_sec="${ZYZ_STATUS_STALE_SEC:-600}"
mtime="$(zyz_mtime "$status_file")"
[ -n "$mtime" ] || exit 0
now="$(zyz_now)"
age=$((now - mtime))
[ "$age" -gt "$stale_sec" ] || exit 0

agent_type="$(zyz_get agent_type)"
role="$(zyz_role_of "$agent_type")"
case "$role" in
    review-agent) exit 0 ;;
    implementation-agent|test-agent) audience="$role" ;;
    "") audience="main" ;;
    *) exit 0 ;;
esac

cooldown="${ZYZ_STATUS_NAG_COOLDOWN_SEC:-300}"
zyz_cooldown_ok "$root/runtime/nag/$audience.last" "$cooldown" || exit 0

mins=$((age / 60))
if [ "$audience" = "main" ]; then
    msg="[zyz-worker watchdog] The task status file has not been updated for ${mins} minutes (${status_file}). Persist current progress, active roles, blockers, and the next step into it now — status lives on disk, not in conversation context."
else
    msg="[zyz-worker watchdog] The task status file has not been updated for ${mins} minutes. Report your current progress back through your normal output soon, and if you maintain a SubTask-status file, update it now (${status_file} is the overall file the main agent owns)."
fi
zyz_emit_context "PostToolUse" "$msg"
exit 0
