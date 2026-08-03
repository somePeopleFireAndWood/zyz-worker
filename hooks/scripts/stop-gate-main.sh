#!/usr/bin/env bash
#
# stop-gate-main.sh — L4 main-agent stop gate (Stop).
#
# ## Trigger point
#
# Registered in hooks/hooks.json for the Stop event (main agent finished
# responding). Does not fire on user interrupt or API-error termination.
#
# ## Inputs
#
# - stdin: hook JSON (cwd, stop_hook_active, background_tasks[]).
# - env: CLAUDE_PROJECT_DIR (fallback base dir), ZYZ_HOOKS_DISABLE=1 skips,
#   ZYZ_ROLE_STALE_SEC (default 900) role-silence threshold,
#   ZYZ_ROLE_STALE_HORIZON_SEC (default 21600) ignore-older-than horizon,
#   ZYZ_STOP_STATUS_STALE_SEC (default 1200) status-age threshold at stop,
#   ZYZ_STOP_GATE_COOLDOWN_SEC (default 600) min gap between blocks.
#
# ## Outputs
#
# - Normally nothing (allow stop).
# - Blocks (top-level {"decision":"block","reason":...}) when the current
#   task is in an active execution phase AND either:
#     (a) a dispatched role looks dead or stuck — it has a `.start` marker,
#         no `.done` marker, and no heartbeat within ZYZ_ROLE_STALE_SEC
#         (covers subagents killed by API errors, where SubagentStop never
#         fired); or
#     (b) the overall status file is older than ZYZ_STOP_STATUS_STALE_SEC.
#   The reason tells the main agent exactly which roles to check/restart
#   and/or to flush the status file. Never blocks when stop_hook_active is
#   true, and at most once per cooldown window.
#
# ## Failure behavior
#
# Fail open: missing input/pointer/parser exits 0 (allow stop).
#
# ## Supported agents
#
# Main agent only (Stop event does not fire for subagents).

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

zyz_json_ok || exit 0
ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"
[ -n "$ZYZ_HOOK_INPUT" ] || exit 0

[ "$(zyz_get stop_hook_active)" = "true" ] && exit 0

base="$(zyz_get cwd)"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || exit 0

root="$(zyz_task_root "$base")"
[ -n "$root" ] || exit 0
status_file="$root/status.md"
[ -f "$status_file" ] || exit 0

phase="$(zyz_phase_of "$status_file")"
zyz_phase_active "$phase" || exit 0

stale_sec="${ZYZ_ROLE_STALE_SEC:-900}"
horizon="${ZYZ_ROLE_STALE_HORIZON_SEC:-21600}"
stale_roles="$(zyz_scan_stale "$root/runtime/agents" "$stale_sec" "$horizon")"
running_types="$(zyz_bg_running_types)"

status_stale_sec="${ZYZ_STOP_STATUS_STALE_SEC:-1200}"
status_age=0
mtime="$(zyz_mtime "$status_file")"
[ -n "$mtime" ] && status_age=$(( $(zyz_now) - mtime ))

reason=""
if [ -n "$stale_roles" ]; then
    # Normalize scope prefixes on both sides: the .start stamp and
    # background_tasks may disagree on "zyz-worker:role" vs bare "role".
    running_roles=""
    if [ -n "$running_types" ]; then
        running_roles="$(printf '%s\n' "$running_types" | while IFS= read -r t; do
            [ -n "$t" ] && zyz_role_of "$t" && printf '\n'
        done)"
    fi
    detail=""
    while IFS="$(printf '\t')" read -r key age; do
        [ -n "$key" ] || continue
        role_line="$(head -n1 "$root/runtime/agents/$key.start" 2>/dev/null || true)"
        role_type="${role_line#* }"
        # A still-running background subagent of the same role is not dead —
        # it may just be reasoning without tool calls. Skip it.
        if [ -n "$running_roles" ] && [ -n "$role_type" ] \
            && printf '%s\n' "$running_roles" | grep -qxF "$(zyz_role_of "$role_type")" 2>/dev/null; then
            continue
        fi
        detail="${detail}${key} (${role_type}, silent $((age / 60)) min); "
    done <<EOF
$stale_roles
EOF
    if [ -n "$detail" ]; then
        # The instruction MUST name an action that actually clears the trigger.
        # This gate reads only the runtime markers — never status.md — so telling
        # the agent to "mark it finished in the status file" was unsatisfiable:
        # it complied, the marker stayed, and the gate re-blocked until the
        # cooldown or the platform block cap timed out. A .start is cleared by a
        # clean SubagentStop, which by definition does not happen on an API-error
        # death, so the agent needs the explicit escape below.
        reason="Dispatched role(s) look dead or stuck with no clean finish: ${detail}They may have been killed by an API error without any SubagentStop. Do one of: (a) re-dispatch each unfinished role with the latest design and status summary, or (b) if its work actually completed, record that in the status file AND clear its stale marker with: rm -f '${root}/runtime/agents/'<key>.start '${root}/runtime/agents/'<key>.heartbeat  (<key> is the name shown above). This gate reads only those runtime markers, so a status-file note alone will not clear it."
    fi
fi

if [ "$status_age" -gt "$status_stale_sec" ]; then
    [ -n "$reason" ] && reason="${reason} "
    reason="${reason}The overall status file (${status_file}) is $((status_age / 60)) minutes stale for an active phase (${phase}). Persist current progress, active roles, blockers, and the next step into it before idling."
fi

[ -n "$reason" ] || exit 0

cooldown="${ZYZ_STOP_GATE_COOLDOWN_SEC:-600}"
zyz_cooldown_ok "$root/runtime/nag/stopgate.last" "$cooldown" || exit 0

zyz_emit_block "[zyz-worker watchdog] ${reason}"
exit 0
