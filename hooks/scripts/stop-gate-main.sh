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
#     (a) a fixed-pack role instance is non-terminal and its latest logical
#         START/HEARTBEAT fact is stale, or its tracking state is unverifiable
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
[ -n "$base" ] || base="${CODEX_PROJECT_DIR:-}"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || base="$PWD"

root="$(zyz_task_root "$base")"
[ -n "$root" ] || exit 0
status_file="$root/status.md"
[ -f "$status_file" ] || exit 0

phase="$(zyz_phase_of "$status_file")"
zyz_phase_active "$phase" || exit 0

stale_sec="${ZYZ_ROLE_STALE_SEC:-900}"
horizon="${ZYZ_ROLE_STALE_HORIZON_SEC:-21600}"
runtime_observation="$(zyz_runtime_observe "$root" false)"
stale_roles="$(printf '%s' "$runtime_observation" | python3 -c '
import json,sys
try:
 stale,horizon,now=map(int,sys.argv[1:4]);data=json.load(sys.stdin)
 if data.get("ok") is not True or data.get("state")!="observed":raise ValueError()
 for item in data.get("instances",[]):
  if item.get("terminal"):continue
  key=item.get("instance_key");role=item.get("role") or "unknown";cap=item.get("tracking_capability")
  last=item.get("last_liveness_epoch")
  if not isinstance(last,int):last=item.get("start_epoch")
  # Grace period: hook-start is fail-open by design (lock timeout, capacity
  # pressure), so a fresh non-armed instance is not evidence of death. Only
  # raise either signal once the newest known fact is older than stale-sec;
  # with no epoch at all fall back to horizon/2 age so it still surfaces.
  age=(now-last) if isinstance(last,int) else horizon//2
  if age<=stale or age>=horizon:continue
  if cap!="armed":print(f"{key}\t{age}\t{role}\t{cap}")
  else:print(f"{key}\t{age}\t{role}\tstale-liveness")
except Exception:pass
' "$stale_sec" "$horizon" "$(zyz_now)" 2>/dev/null || true)"
running_types="$(zyz_bg_running_types)"

status_stale_sec="${ZYZ_STOP_STATUS_STALE_SEC:-1200}"
status_age=0
mtime="$(zyz_mtime "$status_file")"
[ -n "$mtime" ] && status_age=$(( $(zyz_now) - mtime ))

reason=""
if [ -n "$stale_roles" ]; then
    # Normalize scope prefixes on both sides: the logical START role and
    # background_tasks may disagree on "zyz-worker:role" vs bare "role".
    running_roles=""
    if [ -n "$running_types" ]; then
        running_roles="$(printf '%s\n' "$running_types" | while IFS= read -r t; do
            [ -n "$t" ] && zyz_role_of "$t" && printf '\n'
        done)"
    fi
    detail=""
    while IFS="$(printf '\t')" read -r key age role_type stale_kind; do
        [ -n "$key" ] || continue
        # A still-running background subagent of the same role is not dead —
        # it may just be reasoning without tool calls. Skip it.
        if [ -n "$running_roles" ] && [ -n "$role_type" ] \
            && printf '%s\n' "$running_roles" | grep -qxF "$(zyz_role_of "$role_type")" 2>/dev/null; then
            continue
        fi
        detail="${detail}${key} (${role_type}, ${stale_kind}, silent $((age / 60)) min); "
    done <<EOF
$stale_roles
EOF
    if [ -n "$detail" ]; then
        reason="Dispatched role(s) look dead or stuck with no clean finish: ${detail}They may have been killed by an API error without SubagentStop. Verify platform status, then use the supported runtime protocol: create an exact probe and investigate its ACK; after confirmed death run agent-runtime-state.sh finalize <task-dir> <agent-id> <role> <reason> [replacement-id]. Never delete or fabricate runtime markers by hand."
    fi
fi

if [ "$status_age" -gt "$status_stale_sec" ] && ! zyz_status_waiting "$status_file"; then
    [ -n "$reason" ] && reason="${reason} "
    reason="${reason}The overall status file (${status_file}) is $((status_age / 60)) minutes stale for an active phase (${phase}). Persist current progress, active roles, blockers, and the next step into it before idling."
fi

# Terminal-but-unharvested detection (L4 primary): a role reached a terminal
# state (clean DONE / adjudicated FINALIZED) but the main agent has been idle
# since — its last tool call predates completion (main_heartbeat_epoch <=
# terminal_epoch) AND no status was written since (status.md mtime <=
# terminal_epoch). Reuses the SAME observer snapshot. Every epoch is
# isinstance(int)-guarded before comparison so a missing epoch is skipped, never
# thrown (an unguarded None<=int would abort the whole filter). Fails open
# (observer error / macOS genesis-unavailable → empty → no block), like the
# stale-role branch above.
status_mtime=0
[ -n "$mtime" ] && status_mtime="$mtime"
unharvested_roles="$(printf '%s' "$runtime_observation" | python3 -c '
import json,sys
try:
 status_mtime=int(sys.argv[1]);data=json.load(sys.stdin)
 if data.get("ok") is not True or data.get("state")!="observed":raise ValueError()
 main_hb=data.get("main_heartbeat_epoch")
 if not isinstance(main_hb,int):sys.exit(0)
 for item in data.get("instances",[]):
  if not item.get("terminal"):continue
  te=item.get("terminal_epoch")
  if not isinstance(te,int):continue
  if main_hb<=te and status_mtime<=te:
   key=item.get("instance_key");role=item.get("role") or "unknown"
   print(f"{key}\t{role}")
except Exception:pass
' "$status_mtime" 2>/dev/null || true)"
if [ -n "$unharvested_roles" ]; then
    udetail=""
    while IFS="$(printf '\t')" read -r key role; do
        [ -n "$key" ] || continue
        udetail="${udetail}${role} (${key}, its result SubTask file under ${root}/subtasks/ and its durable log); "
    done <<EOF
$unharvested_roles
EOF
    if [ -n "$udetail" ]; then
        [ -n "$reason" ] && reason="${reason} "
        reason="${reason}Completed role(s) look unharvested — they reached a terminal state (DONE/FINALIZED) but the main agent has been idle since, so the completion may not have been processed (a dropped completion notification): ${udetail}Read each named result now, record it in ${status_file}, then continue — that clears this block."
    fi
fi

[ -n "$reason" ] || exit 0

cooldown="${ZYZ_STOP_GATE_COOLDOWN_SEC:-600}"
zyz_cooldown_ok "$root/runtime/nag/stopgate.last" "$cooldown" || exit 0

zyz_emit_block "[zyz-worker watchdog] ${reason}"
exit 0
