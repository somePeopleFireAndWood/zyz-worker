#!/usr/bin/env bash
#
# heartbeat.sh — L0 automatic liveness heartbeat (PreToolUse + PostToolUse).
#
# ## Trigger point
#
# Registered in hooks/hooks.json for PreToolUse and PostToolUse with matcher
# "*", async. Fires for every tool call in the main agent AND inside every
# subagent (hooks run inside subagents; input carries agent_id/agent_type).
#
# ## Inputs
#
# - stdin: hook JSON (cwd, agent_id?, agent_type?, ...).
# - env: CLAUDE_PROJECT_DIR (fallback base dir), ZYZ_HOOKS_DISABLE=1 skips.
#
# ## Outputs
#
# - None on stdout.
# - Side effect: stamps `<task-root>/runtime/agents/<agent-key>.heartbeat`
#   (agent-key = sanitized agent_id, or "main" for the main agent). Liveness
#   is the file's mtime; the content (ISO time + agent_type) is informational.
#
# ## Failure behavior
#
# Fail open: any missing input, missing task pointer, missing JSON parser, or
# write error exits 0 silently. This hook must never slow or break the loop.
#
# ## Supported agents
#
# All (main agent and every subagent type). No-op unless the session cwd has
# a `.zyz-worker/current-task` pointer to an existing task directory.

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

zyz_json_ok || exit 0
ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"
[ -n "$ZYZ_HOOK_INPUT" ] || exit 0

base="$(zyz_get cwd)"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || exit 0

root="$(zyz_task_root "$base")"
[ -n "$root" ] || exit 0

agent_id="$(zyz_get agent_id)"
agent_type="$(zyz_get agent_type)"
key="main"
[ -n "$agent_id" ] && key="$(zyz_sanitize "$agent_id")"

mkdir -p "$root/runtime/agents" 2>/dev/null || exit 0
zyz_write_atomic "$root/runtime/agents/$key.heartbeat" "$(zyz_iso) ${agent_type:-main}"
exit 0
