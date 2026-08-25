#!/usr/bin/env bash
#
# stop-gate-subagent.sh — L2 subagent exit gate (SubagentStop).
#
# ## Trigger point
#
# Registered in hooks/hooks.json for SubagentStop with the zyz-worker role
# matcher. Fires when a role subagent finishes responding. NOT guaranteed
# to fire when the subagent dies on an API error — the L3 watchdog covers
# that gap via missing logical DONE terminal truth.
#
# ## Inputs
#
# - stdin: hook JSON (cwd, agent_id, agent_type, stop_hook_active,
#   last_assistant_message).
# - env: CLAUDE_PROJECT_DIR (fallback base dir), ZYZ_HOOKS_DISABLE=1 skips,
#   ZYZ_SUBAGENT_MIN_FINAL_CHARS (default 80) minimum final-message length.
#
# ## Outputs
#
# - Normally nothing; side effect: stamps
#   the instance audit pack's logical DONE record,
#   which tells L3/L4 the role ended cleanly.
# - When the role's final message is missing or shorter than the minimum
#   (an empty/truncated ending gives the main agent nothing to persist):
#   prints `{"decision":"block","reason":...}` ONCE, telling the role to
#   emit a proper final report (completed work, remaining work, blockers,
#   file paths touched). The DONE commit is skipped on block so the role
#   still counts as running; it is written on the next clean stop.
#
# ## Failure behavior
#
# Fail open: missing input/pointer/parser exits 0 (allow stop). No-op when
# the session has no `.zyz-worker/current-task` pointer (the gate never
# applies outside an execute-task workflow). When stop_hook_active is true,
# never blocks again (no loops); the built-in 8-consecutive-block cap also
# applies.
#
# ## Supported agents
#
# zyz-worker roles only (via the hooks.json matcher).

set -u
# Tokenless host-only failure taxonomy mirrors SubagentStart:
# event-lock-unavailable event-randomness-unavailable event-inventory-invalid
# event-token-collision primary-diagnostic-write-failed.
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

mark_done() {
    [ -n "$agent_id" ] || return 0
    _role="$(zyz_canonical_role "$agent_type" 2>/dev/null)" || return 0
    if command -v python3 >/dev/null 2>&1; then
        (cd "$base" 2>/dev/null && python3 "$SCRIPT_DIR/runtime_state.py" hook-stop "$root" "$agent_id" "$_role" >/dev/null) \
            || printf 'zyz-worker: SubagentStop terminal commit pending\n' >&2
    else
        printf 'zyz-worker: event-randomness-unavailable (python3 missing)\n' >&2
    fi
}

if [ "$(zyz_get stop_hook_active)" = "true" ]; then
    mark_done
    exit 0
fi

min_chars="${ZYZ_SUBAGENT_MIN_FINAL_CHARS:-80}"
case "$min_chars" in
    ''|*[!0-9]*) min_chars=80 ;;
esac
final_msg="$(zyz_get last_assistant_message)"
# Measure BYTES, not `${#...}`. Bash's ${#var} counts characters under a UTF-8
# locale but bytes under LC_ALL=C, so the same message measured two different
# ways — and a COMPLETE CJK report would trip the gate: 45 Chinese characters is
# a full report but scores 45 against a threshold of 80, while its 135 bytes
# clearly clear it. The workflow explicitly supports Chinese output (SKILL.md
# `## Core Rules`), so the character reading blocked valid work. Bytes are
# locale-independent and the threshold is calibrated for them: 80 bytes is ~80
# ASCII characters or ~26 CJK characters, both of which are genuinely too short.
msg_len="$(printf '%s' "$final_msg" | wc -c 2>/dev/null | tr -d '[:space:]')"
case "$msg_len" in
    ''|*[!0-9]*) msg_len="${#final_msg}" ;;
esac
if [ "$msg_len" -lt "$min_chars" ]; then
    role="$(zyz_role_of "${agent_type:-subagent}")"
    zyz_emit_block "[zyz-worker watchdog] Your final message is too short for the main agent to persist into the task status file. Before finishing, emit a complete final report for your role (${role}): what you completed, what remains, blockers, decisions made, and the exact file paths you touched. If you already did the work, summarize it now — do not redo it."
    exit 0
fi

mark_done
exit 0
