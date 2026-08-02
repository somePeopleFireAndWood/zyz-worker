#!/usr/bin/env bash
#
# post-agent-flush.sh — L1 "flush status after subagent result" reminder
# (PostToolUse, matcher "Agent").
#
# ## Trigger point
#
# Registered in hooks/hooks.json for PostToolUse with matcher "^Agent$",
# sync. Fires in the main agent right after an Agent tool call returns a
# completed subagent result.
#
# ## Inputs
#
# - stdin: hook JSON (cwd, agent_id?, tool_response.status?).
# - env: CLAUDE_PROJECT_DIR (fallback base dir), ZYZ_HOOKS_DISABLE=1 skips,
#   ZYZ_POST_RESULT_FLUSH_SEC (default 120) status-age threshold,
#   ZYZ_POST_RESULT_COOLDOWN_SEC (default 60) min gap between reminders.
#
# ## Outputs
#
# - When the overall status file is older than the threshold at the moment
#   a foreground subagent result arrives: prints hookSpecificOutput
#   additionalContext reminding the main agent to write the status update
#   BEFORE dispatching further work (the workflow's "flush after receiving
#   a subagent result" rule). Background launches ("async_launched") and
#   calls made inside subagents are ignored.
# - Side effect: stamps `<task-root>/runtime/nag/postflush.last`.
#
# ## Failure behavior
#
# Fail open: missing input/pointer/parser exits 0 with no output.
#
# ## Supported agents
#
# Main agent only (exits when agent_id is present).

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

zyz_json_ok || exit 0
ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"
[ -n "$ZYZ_HOOK_INPUT" ] || exit 0

[ -z "$(zyz_get agent_id)" ] || exit 0

resp_status="$(zyz_get tool_response.status)"
[ "$resp_status" = "async_launched" ] && exit 0

base="$(zyz_get cwd)"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || exit 0

root="$(zyz_task_root "$base")"
[ -n "$root" ] || exit 0
status_file="$root/status.md"
[ -f "$status_file" ] || exit 0

threshold="${ZYZ_POST_RESULT_FLUSH_SEC:-120}"
mtime="$(zyz_mtime "$status_file")"
[ -n "$mtime" ] || exit 0
age=$(( $(zyz_now) - mtime ))
[ "$age" -gt "$threshold" ] || exit 0

cooldown="${ZYZ_POST_RESULT_COOLDOWN_SEC:-60}"
zyz_cooldown_ok "$root/runtime/nag/postflush.last" "$cooldown" || exit 0

mins=$((age / 60))
zyz_emit_context "PostToolUse" "[zyz-worker watchdog] A subagent result just arrived but the overall status file (${status_file}) was last written ${mins} minute(s) ago. Per the workflow, persist this result — progress, decisions, blockers, next step, SubTask flags — into the status file (and the SubTask-status file if one exists) BEFORE dispatching further work."
exit 0
