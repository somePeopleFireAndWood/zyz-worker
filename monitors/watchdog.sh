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
# ## Main-agent state gating (pure signal, no TTL)
#
# Each tick reads the main-agent state file (<root>/runtime/main-state via
# zyz_main_state_suppresses). When the main agent is awaiting-user or idle, the
# STATUS-STALE finding is suppressed — both its stdout and its main-origin stuck
# IM — because it is attributed to the main agent, which is legitimately not
# working (waiting on the user / stopped and handed back). This is a string
# compare only; the state's epoch is never read, so a 15-hour wait never
# "expires". The SUBAGENT findings (stale / tracking / probe / no-output /
# unharvested) are NEVER suppressed (A option): their stdout is always emitted
# and their stuck IMs carry --origin subagent so notify.sh forwards them to the
# user even offline. A missing/corrupt state file fails open to full alerting.
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
BASE="${1:-${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
INTERVAL="${ZYZ_WATCHDOG_INTERVAL_SEC:-60}"
ROLE_STALE="${ZYZ_WATCHDOG_ROLE_STALE_SEC:-1200}"
HORIZON="${ZYZ_ROLE_STALE_HORIZON_SEC:-21600}"
STATUS_STALE="${ZYZ_WATCHDOG_STATUS_STALE_SEC:-1800}"
COOLDOWN="${ZYZ_WATCHDOG_COOLDOWN_SEC:-900}"
ONCE="${ZYZ_WATCHDOG_ONCE:-0}"

WATCHDOG_PID_FILE="${ZYZ_WATCHDOG_PID_FILE:-}"
watchdog_cleanup() {
    [ -n "$WATCHDOG_PID_FILE" ] && rm -f "$WATCHDOG_PID_FILE" 2>/dev/null || true
}
trap 'exit 0' TERM INT HUP
trap watchdog_cleanup EXIT

# Unarmed-visibility state. An unarmed watchdog and a healthy quiet one are
# externally indistinguishable — that is how a whole task ran with every layer
# inert and nobody noticing. Report the miss ONCE (not every tick) so the main
# agent learns the layer is not protecting it, then stay quiet; re-arm resets it.
UNARMED_REPORTED="false"

# IM stop-notifier bridge (best-effort, fail-open). When a finding is emitted
# for the main agent, also forward a `stuck` event to the user's configured IM
# via hooks/scripts/notify.sh — this is the reuse of the existing monitor layer
# for the "agent got stuck / a role likely died" slice of abnormal
# interruption. Backgrounded so a slow IM command never delays the scan; the
# notifier itself is config-gated, workflow-scoped, and cooldown-limited, so
# calling it on every finding is safe. NOTE: a whole-process crash takes this
# monitor down with it, so this covers stalls, not host death.
NOTIFY_SH="$SCRIPT_DIR/../hooks/scripts/notify.sh"
notify_stuck() { # $1 = task root, $2 = short message, $3 = origin (main|subagent)
    [ -x "$NOTIFY_SH" ] || return 0
    "$NOTIFY_SH" --event stuck --task-root "$1" --message "$2" --origin "${3:-main}" >/dev/null 2>&1 &
}

# But this monitor is armed `when: always`, so it starts in EVERY session —
# including the overwhelming majority that never run execute-task. Reporting a
# bare resolution miss there is a false alarm that tells the user dead subagents
# will not be reported when there is nothing to report on, and a warning that
# cries wolf in ordinary sessions is worse than no warning: it trains people to
# ignore the one that matters. So only speak up when a task plausibly EXISTS but
# the pointer cannot be found — i.e. some `.zyz-worker/tasks/<id>/` is present
# under the base yet resolution still came back empty. A repo with no task dirs
# at all, or one whose task dirs are all finished, stays silent.
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
    case "${ZYZ_WATCHDOG_PARENT_PID:-}" in
        ''|*[!0-9]*) ;;
        *) kill -0 "$ZYZ_WATCHDOG_PARENT_PID" 2>/dev/null || exit 0 ;;
    esac
    [ -d "$BASE" ] || exit 0
    root="$(zyz_task_root "$BASE")"
    if [ -z "$root" ] && [ "$UNARMED_REPORTED" = "false" ] && zyz_unarmed_is_suspicious; then
        UNARMED_REPORTED="true"
        printf '[zyz-worker watchdog] 未启用：无法从 %s 解析到任务指针（已尝试该目录下的 .zyz-worker/current-task 和 $ZYZ_TASK_DIR；解析器有意不搜索同级 worktree——在那里找到的任务可能属于另一个并发会话）。本会话的 watchdog 层处于失效状态——死掉的 subagent 不会被报告，空闲门也不会拦住停止。如果有正在运行的 execute-task，请在会话 cwd 下写入指针，或者把指针内容改为任务目录的绝对路径。每次未命中只报告一次，不会每轮扫描都报一次。\n' "$BASE"
    fi
    if [ -n "$root" ]; then
        UNARMED_REPORTED="false"
        status_file="$root/status.md"
        phase="$(zyz_phase_of "$status_file")"
        if zyz_phase_active "$phase"; then
            # main-state suppression gate (read once per tick). When the main
            # agent is awaiting-user / idle (zyz_main_state_suppresses), the
            # status-stale branch below is silenced (main-agent-attributed). The
            # subagent findings are NEVER suppress-gated (A option) and their
            # stuck IMs carry --origin subagent to bypass notify.sh's suppression.
            suppress="$(zyz_main_state_suppresses "$root" && echo 1 || echo 0)"
            # (a) Fixed-pack liveness, tracking, probe, no-output, and
            # terminal-but-unharvested signals. One authenticated observer
            # snapshot owns enumeration; shell never treats pathname membership
            # as new-format state authority. Status mtime is read first so the
            # terminal-unharvested predicate can consume it.
            mtime="$(zyz_mtime "$status_file")"
            status_mtime_arg=0
            [ -n "$mtime" ] && status_mtime_arg="$mtime"
            runtime_observation="$(zyz_runtime_observe "$root" true)"
            runtime_events="$(printf '%s' "$runtime_observation" | python3 -c '
import json,sys
try:
 stale,horizon,now,status_mtime=map(int,sys.argv[1:5]);data=json.load(sys.stdin)
 if data.get("ok") is not True or data.get("state")!="observed":raise ValueError()
 main_hb=data.get("main_heartbeat_epoch")
 for item in data.get("instances",[]):
  key=item.get("instance_key");role=item.get("role") or "unknown"
  if item.get("terminal"):
   # Terminal-but-unharvested: role finished (DONE/FINALIZED) but the main
   # agent has been idle since (main_heartbeat_epoch <= terminal_epoch) and
   # wrote no status since (status.md mtime <= terminal_epoch). Every epoch is
   # isinstance(int)-guarded before comparison and the item skipped on absence
   # — an unguarded None<=int would throw and abort the whole shared loop,
   # dropping every other instance event.
   te=item.get("terminal_epoch")
   if not isinstance(main_hb,int) or not isinstance(te,int):continue
   if main_hb<=te and status_mtime<=te:print(f"unharvested\t{key}\t{role}\t0\t-")
   continue
  cap=item.get("tracking_capability")
  last=item.get("last_liveness_epoch")
  if not isinstance(last,int):last=item.get("start_epoch")
  # Same grace as L4: fail-open starts leave non-armed instances that are not
  # yet evidence of death; only report past stale-sec (no-epoch -> horizon/2).
  age=(now-last) if isinstance(last,int) else horizon//2
  if stale<age<horizon:
   if cap!="armed":print(f"tracking\t{key}\t{role}\t{age}\t{cap}")
   else:print(f"stale\t{key}\t{role}\t{age}\t-")
  if item.get("probe_state")=="overdue":print("probe\t{}\t{}\t0\t{}".format(key,role,item.get("probe_id") or "unknown"))
  if item.get("no_output_state")=="unchanged":print(f"no-output\t{key}\t{role}\t0\t-")
except Exception:pass
' "$ROLE_STALE" "$HORIZON" "$(zyz_now)" "$status_mtime_arg" 2>/dev/null || true)"
            while IFS="$(printf '\t')" read -r event_kind key role_line age detail; do
                [ -n "$event_kind" ] || continue
                case "$event_kind" in
                    stale)
                        zyz_cooldown_ok "$root/runtime/nag/watchdog-$key.last" "$COOLDOWN" || continue
                        printf '[zyz-worker watchdog] 角色 %s（%s）已静默 %s 分钟且没有正常结束——请核实平台状态，发送一个精确的重连 probe，确认死亡后先用 agent-runtime-state.sh finalize 收尾，再重新派发。\n' "$key" "$role_line" "$((age / 60))"
                        notify_stuck "$root" "角色 ${role_line} 已静默 $((age / 60)) 分钟，且没有正常结束" subagent
                        ;;
                    tracking)
                        zyz_cooldown_ok "$root/runtime/nag/watchdog-tracking-$key-$detail.last" "$COOLDOWN" || continue
                        printf '[zyz-worker watchdog] 角色 %s（%s）的 fixed-pack 跟踪状态为 %s——有可用的确切持久化事件时就据此对账；不要把无法核实的实例当作健康的安静状态。\n' "$key" "$role_line" "$detail"
                        notify_stuck "$root" "角色 ${role_line} 的跟踪状态尚未对账（${detail}）" subagent
                        ;;
                    probe)
                        zyz_cooldown_ok "$root/runtime/nag/watchdog-probe-$key-$detail.last" "$COOLDOWN" || continue
                        printf '[zyz-worker watchdog] 重连 probe %s（角色实例 %s）已逾期，且没有收到明确匹配的 ACK；单有心跳不算 ACK。现在就查询平台的 running/inflight 状态，并按有界恢复协议处理。\n' "$detail" "$key"
                        notify_stuck "$root" "角色 ${role_line} 的重连 probe 已逾期，且没有 ACK" subagent
                        ;;
                    no-output)
                        zyz_cooldown_ok "$root/runtime/nag/watchdog-no-output-$key.last" "$COOLDOWN" || continue
                        printf '[zyz-worker watchdog] 角色实例 %s 已达到无输出阈值，而它固定的 LIVE_INVENTORY 基线仍与当前受描述符约束的物理树一致；这个并行通道（lane）可能已经丢失。\n' "$key"
                        notify_stuck "$root" "角色 ${role_line} 已达到无输出阈值；这个 lane 可能已经丢失" subagent
                        ;;
                    unharvested)
                        zyz_cooldown_ok "$root/runtime/nag/watchdog-unharvested-$key.last" "$COOLDOWN" || continue
                        printf '[zyz-worker watchdog] 角色 %s（%s）已完成（DONE/FINALIZED），但看起来没有被处理——它结束后主 agent 一直空闲，所以它的完成通知可能没有送达（这是 watchdog 路径上的备份信号）。读取 %s/subtasks/ 下它的结果 SubTask 文件及其持久日志，记录到 %s，然后继续。\n' "$key" "$role_line" "$root" "$status_file"
                        notify_stuck "$root" "角色 ${role_line} 已结束，但其结果尚未处理" subagent
                        ;;
                esac
            done <<EOF
$runtime_events
EOF

            # (b) stale overall status file during an active phase. Reuses the
            # $mtime read above for the unharvested predicate. Suppressed when
            # the main agent is awaiting-user / idle (suppress=1): this is a
            # main-agent-attributed finding, so its stdout and its main-origin
            # stuck IM both go silent while the main agent is not working.
            if [ -n "$mtime" ]; then
                age=$(( $(zyz_now) - mtime ))
                if [ "$age" -gt "$STATUS_STALE" ] && [ "$suppress" = 0 ] && ! zyz_status_waiting "$status_file"; then
                    if zyz_cooldown_ok "$root/runtime/nag/watchdog-status.last" "$COOLDOWN"; then
                        printf '[zyz-worker watchdog] 状态文件 %s 已有 %s 分钟没有更新，当前处于活跃阶段 %s——现在就把当前进度、活跃角色、阻塞项和下一步写进去。\n' \
                            "$status_file" "$((age / 60))" "$phase"
                        notify_stuck "$root" "状态文件已有 $((age / 60)) 分钟没有更新，当前处于活跃阶段 ${phase}" main
                    fi
                fi
            fi
        fi
    fi
    [ "$ONCE" = 1 ] && exit 0
    sleep "$INTERVAL"
done
