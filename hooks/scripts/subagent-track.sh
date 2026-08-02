#!/usr/bin/env bash
#
# subagent-track.sh — L0 dispatch bookkeeping (SubagentStart).
#
# ## Trigger point
#
# Registered in hooks/hooks.json for SubagentStart with an agent-type
# matcher scoped to the zyz-worker roles (implementation-agent / test-agent
# / review-agent, plugin-scoped or project-level).
#
# ## Inputs
#
# - stdin: hook JSON (cwd, agent_id, agent_type).
# - env: CLAUDE_PROJECT_DIR (fallback base dir), ZYZ_HOOKS_DISABLE=1 skips.
#
# ## Outputs
#
# - None on stdout.
# - Side effect: stamps `<task-root>/runtime/agents/<agent-key>.start`
#   (ISO time + agent_type). A `.start` without a matching `.done` (written
#   by stop-gate-subagent.sh) and without fresh heartbeats is what the L3
#   watchdog and L4 main stop gate treat as a dead or stuck role. Note that
#   SubagentStop is NOT guaranteed to fire when a subagent dies on an API
#   error — that gap is exactly what leaves `.done` missing, which is the
#   signal the watchdog needs.
#
# ## Failure behavior
#
# Fail open: missing input, missing task pointer, or write errors exit 0.
#
# ## Supported agents
#
# zyz-worker roles only (via the hooks.json matcher).

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
[ -n "$agent_id" ] || exit 0
key="$(zyz_sanitize "$agent_id")"

mkdir -p "$root/runtime/agents" 2>/dev/null || exit 0
zyz_write_atomic "$root/runtime/agents/$key.start" "$(zyz_iso) ${agent_type:-unknown}"
exit 0
