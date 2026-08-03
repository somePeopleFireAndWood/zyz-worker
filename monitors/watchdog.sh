#!/usr/bin/env bash
#
# watchdog.sh — L3 background watchdog monitor for the execute-task workflow.
#
# ## Trigger point
#
# Declared in monitors/monitors.json with `when: "on-skill-invoke:execute-task"`.
# Claude Code starts it the first time the execute-task skill is dispatched
# in a session and keeps it for the session's lifetime. Each stdout line is
# delivered to the MAIN agent as a notification that can wake an idle
# session — this is the layer that catches subagents killed by API errors
# (where SubagentStop never fires) and main-agent inaction.
#
# ## Inputs
#
# - $1 (optional) base dir; defaults to CLAUDE_PROJECT_DIR, then PWD.
# - env: ZYZ_WATCHDOG_INTERVAL_SEC       poll interval          (default 60)
#        ZYZ_WATCHDOG_ROLE_STALE_SEC     role-silence threshold (default 1200)
#        ZYZ_ROLE_STALE_HORIZON_SEC      ignore-older-than      (default 21600)
#        ZYZ_WATCHDOG_STATUS_STALE_SEC   status-age threshold   (default 1800)
#        ZYZ_WATCHDOG_COOLDOWN_SEC       min gap per finding    (default 900)
#        ZYZ_HOOKS_DISABLE=1             exit immediately
#
# ## Outputs (stdout, one line per event — each line wakes the main agent)
#
# - "[zyz-worker watchdog] role <key> (<agent_type>) has been silent for N
#    min with no clean finish — verify whether it is actually dead ... then
#    re-dispatch or mark it finished."
# - "[zyz-worker watchdog] status file <path> is N min stale during active
#    phase <phase> — persist progress now."
# Findings are rate-limited per key via runtime/nag/watchdog-<key>.last.
# The role threshold is deliberately higher than the L4 stop gate's: a
# healthy role can reason for a while without tool calls, and only L4 can
# cross-check background_tasks; L3 asks the main agent to verify, not to
# blindly restart.
#
# ## Failure behavior
#
# Never exits on scan errors; sleeps and retries. Exits 0 on SIGTERM/INT/HUP
# or when the base dir disappears. Silent when no current-task pointer.
#
# ## Supported agents
#
# Observes all roles; talks only to the main agent (via stdout lines).

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../hooks/scripts/lib.sh
. "$SCRIPT_DIR/../hooks/scripts/lib.sh" 2>/dev/null || exit 0

# monitors.json interpolates "${CLAUDE_PROJECT_DIR}" straight into argv, so an
# unset variable invokes this with an EMPTY first argument. That is already
# handled: `${1:-word}` substitutes when $1 is unset OR empty (it is `${1-word}`
# that distinguishes them), so an empty $1 falls through to CLAUDE_PROJECT_DIR
# and then $PWD. Verified across all nine arg/env combinations — do not "fix"
# this into a two-step form believing empty defeats the default; it does not.
BASE="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
INTERVAL="${ZYZ_WATCHDOG_INTERVAL_SEC:-60}"
ROLE_STALE="${ZYZ_WATCHDOG_ROLE_STALE_SEC:-1200}"
HORIZON="${ZYZ_ROLE_STALE_HORIZON_SEC:-21600}"
STATUS_STALE="${ZYZ_WATCHDOG_STATUS_STALE_SEC:-1800}"
COOLDOWN="${ZYZ_WATCHDOG_COOLDOWN_SEC:-900}"

trap 'exit 0' TERM INT HUP

# Unarmed-visibility state. An unarmed watchdog and a healthy quiet one are
# externally indistinguishable — that is how a whole task ran with every layer
# inert and nobody noticing. Report the miss ONCE (not every tick) so the main
# agent learns the layer is not protecting it, then stay quiet; re-arm resets it.
UNARMED_REPORTED="false"

# But this monitor is armed `when: always`, so it starts in EVERY session —
# including the overwhelming majority that never run execute-task. Reporting a
# bare resolution miss there is a false alarm that tells the user dead subagents
# will not be reported when there is nothing to report on, and a warning that
# cries wolf in ordinary sessions is worse than no warning: it trains people to
# ignore the one that matters. So only speak up when a task plausibly EXISTS but
# the pointer cannot be found — i.e. some `.zyz-worker/tasks/<id>/` is present
# (here or in a sibling worktree) yet resolution still came back empty. A repo
# with no task dirs at all, or one whose task dirs are all finished, stays silent.
zyz_unarmed_is_suspicious() {
    local d
    for d in "$BASE"/.zyz-worker/tasks/*/; do
        [ -d "$d" ] || continue
        # A task dir counts as evidence only while it is not finished; completed
        # tasks legitimately leave their directories behind forever.
        zyz_task_is_done "${d%/}" && continue
        [ -f "${d%/}/status.md" ] || continue
        return 0
    done
    return 1
}

while :; do
    [ -d "$BASE" ] || exit 0
    root="$(zyz_task_root "$BASE")"
    if [ -z "$root" ] && [ "$UNARMED_REPORTED" = "false" ] && zyz_unarmed_is_suspicious; then
        UNARMED_REPORTED="true"
        printf '[zyz-worker watchdog] NOT ARMED: no task pointer resolved from %s (tried that dir, $ZYZ_TASK_DIR, and sibling git worktrees of the same repo). The watchdog layer is inert for this session — dead subagents will NOT be reported and the idle gate will NOT hold. If an execute-task run is active, its .zyz-worker/current-task is somewhere this cannot see: write the pointer under the session cwd, or make its contents an ABSOLUTE path to the task dir. This is reported once per miss, not per tick.\n' "$BASE"
    fi
    if [ -n "$root" ]; then
        UNARMED_REPORTED="false"
        status_file="$root/status.md"
        phase="$(zyz_phase_of "$status_file")"
        if zyz_phase_active "$phase"; then
            # (a) dead/stuck roles: .start without .done, silent too long.
            zyz_scan_stale "$root/runtime/agents" "$ROLE_STALE" "$HORIZON" \
            | while IFS="$(printf '\t')" read -r key age; do
                [ -n "$key" ] || continue
                zyz_cooldown_ok "$root/runtime/nag/watchdog-$key.last" "$COOLDOWN" || continue
                role_line="$(head -n1 "$root/runtime/agents/$key.start" 2>/dev/null || true)"
                printf '[zyz-worker watchdog] role %s (%s) has been silent for %s min with no clean finish — verify whether it is actually dead (check its background task status / result; API-error kills skip SubagentStop, but a healthy role may also just be reasoning without tool calls). If dead, re-dispatch it with the latest design and status summary; if it finished, mark it in the status file.\n' \
                    "$key" "${role_line#* }" "$((age / 60))"
            done

            # (b) stale overall status file during an active phase.
            mtime="$(zyz_mtime "$status_file")"
            if [ -n "$mtime" ]; then
                age=$(( $(zyz_now) - mtime ))
                if [ "$age" -gt "$STATUS_STALE" ]; then
                    if zyz_cooldown_ok "$root/runtime/nag/watchdog-status.last" "$COOLDOWN"; then
                        printf '[zyz-worker watchdog] status file %s is %s min stale during active phase %s — persist current progress, active roles, blockers, and next step into it now.\n' \
                            "$status_file" "$((age / 60))" "$phase"
                    fi
                fi
            fi
        fi
    fi
    sleep "$INTERVAL"
done
