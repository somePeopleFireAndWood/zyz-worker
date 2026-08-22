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
#   the fixed catalog PACK_HEADER heartbeat record for main.
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

root="$(zyz_task_root "$base")"
[ -n "$root" ] || exit 0

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

if command -v python3 >/dev/null 2>&1; then
    python3 "$SCRIPT_DIR/runtime_state.py" hook-main-heartbeat "$root" \
        "${agent_type:-main}" >/dev/null 2>&1 || true
fi

exit 0
