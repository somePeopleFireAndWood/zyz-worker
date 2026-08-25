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
# - Side effect: reserves the hash-keyed instance and commits logical IDENTITY
#   and START records in its fixed audit/work packs. Missing terminal truth plus
#   stale logical HEARTBEAT is what L3/L4 treat as dead or stuck. SubagentStop
#   is not guaranteed after an API error; confirmed death is recorded with the
#   supported `finalize` command.
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
[ -n "$base" ] || base="${CODEX_PROJECT_DIR:-}"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || base="$PWD"

root="$(zyz_task_root "$base")"
[ -n "$root" ] || exit 0

agent_id="$(zyz_get agent_id)"
agent_type="$(zyz_get agent_type)"
[ -n "$agent_id" ] || exit 0
role="$(zyz_canonical_role "$agent_type" 2>/dev/null)" || exit 0

# The backend owns identity selection, collision latching, transition locking
# and WAL ordering. This state-writing hook remains host-fail-open: a tracking
# failure is diagnostic and never prevents the host from starting the role.
if command -v python3 >/dev/null 2>&1; then
    (cd "$base" 2>/dev/null && python3 "$SCRIPT_DIR/runtime_state.py" hook-start "$root" "$agent_id" "$role" >/dev/null) \
        || printf 'zyz-worker: SubagentStart runtime tracking unavailable\n' >&2
else
    printf 'zyz-worker: event-randomness-unavailable (python3 missing)\n' >&2
fi
# Tokenless host-only failure taxonomy: event-lock-unavailable,
# event-randomness-unavailable, event-inventory-invalid, event-token-collision,
# primary-diagnostic-write-failed. None creates a reconcilable token.
exit 0
