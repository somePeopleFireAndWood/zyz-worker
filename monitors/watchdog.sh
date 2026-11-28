#!/usr/bin/env bash
#
# watchdog.sh — L3 background watchdog monitor for the execute-task workflow.
#
# ## Trigger point
#
# Declared in monitors/monitors.json with `when: "always"` (see hooks/README.md
# for why not `on-skill-invoke:`): Claude Code starts it with the session and
# keeps it for the session's lifetime; it gates itself on the task pointer. Each stdout line is
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
#        ZYZ_WATCHDOG_NO_EXECUTOR_SEC    stopped-with-no-executor threshold
#                                        (default 600)
#        ZYZ_WATCHDOG_REMIND_SEC         re-reminder gap for a due wait
#                                        (default 1800)
#        ZYZ_WATCHDOG_OBSERVE_SEC        gap between "observing with nothing
#                                        scheduled" reports (default 10800)
#        ZYZ_WATCHDOG_SILENCE_SEC        whole-session silence threshold
#                                        (default 3600; repeats every
#                                        remind-sec)
#        ZYZ_WATCHDOG_FAILURE_COOLDOWN_SEC  min gap between API-failure
#                                        reports (default 600; records that
#                                        arrive inside it are batched)
#        ZYZ_WATCHDOG_ESCALATE_SEC       a finding unanswered this long pages
#                                        the user (default 600; see
#                                        notify_stuck)
#   A task's `- Tune:` row (expect.sh tune) may override status-stale-sec,
#   no-executor-sec, remind-sec and silence-sec for that task.
#        ZYZ_HOOKS_DISABLE=1             exit immediately
#
# ## Outputs (stdout, one line per event — each line wakes the main agent)
#
# - "[zyz-worker watchdog] role <key> (<agent_type>) has been silent for N
#    min with no clean finish — verify whether it is actually dead ... then
#    re-dispatch or mark it finished."
# - "[zyz-worker watchdog] status file <path> is N min stale during active
#    phase <phase> — persist progress now."
# - "[zyz-worker watchdog] task <id> is still in phase <phase> ... but has had
#    no executor ..." (#24): the main agent stopped with nothing in flight and
#    no declared wait (see scan_no_executor).
# - "[zyz-worker watchdog] time is up for the wait <key> ..." (#24): a declared
#    wait (expect.sh, or a legacy Waiting On row) has come due; repeated every
#    remind-sec while the row is left as is.
# - "... the background task <id> of wait <key> is no longer running" (#24).
# - "... task <id> is observing but nothing is scheduled" (#24).
# - "... the whole session has not moved for N min ..." (0.32.0): an active
#   task with work left, no tool call by anyone in the session (main agent,
#   subagent, teammate), no user prompt and no status write for silence-sec,
#   and nothing declared (see scan_declarations (5)). The floor check: it
#   needs neither the fixed-pack capability nor a role-name match.
#   In the design phase (#30) it needs one more fact: the main agent stopped
#   with an executor running (design review), so it is not the approval gate.
#   Role findings and declared waits are reported in the design phase too.
# - "... N subagents / teammates ended their turn on an API error ..." (0.32.0):
#   StopFailure records written by hooks/scripts/api-failure.sh (see
#   scan_failures). Each record is reported once.
# Findings are rate-limited per key via runtime/nag/watchdog-<key>.last.
# The user is paged (stuck IM) only by escalation: a finding the main agent
# left unanswered — see notify_stuck.
# The role threshold is deliberately higher than the L4 stop gate's: a
# healthy role can reason for a while without tool calls, and only L4 can
# cross-check background_tasks; L3 asks the main agent to verify, not to
# blindly restart.
#
# ## Failure behavior
#
# Never exits on scan errors; sleeps and retries. Exits 0 on SIGTERM/INT/HUP
# or when the base dir disappears. Silent when no task pointer of this session
# resolves (zyz_task_roots: .zyz-worker/sessions/<session-id>; the legacy
# .zyz-worker/current-task only when no session id is known at all; then
# $ZYZ_TASK_DIR). The session id comes from
# $ZYZ_SESSION_ID (the Codex starter sets it) or the Claude monitor's own
# $CLAUDE_CODE_SESSION_ID, plus the live id in ~/.claude/sessions/$CLAUDE_PID.json.
# Each task listed in the session pointer is scanned and reported separately.
# A session that never armed is silent, full stop: this monitor is armed
# `when: always`, so it runs in every session, and the task dirs, other
# sessions' pointers or a leftover current-task it can see in the directory say
# nothing about this session. (Until 0.32.1 it reported "未启用" once whenever
# an unfinished, unclaimed task dir existed — a false alarm in every plain
# session opened in a repo with an abandoned task. The narrowed hint now lives
# in status-freshness.sh, keyed on this session's own status writes.)
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
# and their escalated stuck IMs carry --origin subagent so notify.sh forwards
# them to the user even offline. A missing/corrupt state file fails open to
# full alerting.
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
NO_EXECUTOR="${ZYZ_WATCHDOG_NO_EXECUTOR_SEC:-600}"
case "$NO_EXECUTOR" in ''|*[!0-9]*) NO_EXECUTOR=600 ;; esac
REMIND="${ZYZ_WATCHDOG_REMIND_SEC:-1800}"
case "$REMIND" in ''|*[!0-9]*) REMIND=1800 ;; esac
OBSERVE="${ZYZ_WATCHDOG_OBSERVE_SEC:-10800}"
case "$OBSERVE" in ''|*[!0-9]*) OBSERVE=10800 ;; esac
SILENCE="${ZYZ_WATCHDOG_SILENCE_SEC:-3600}"
case "$SILENCE" in ''|*[!0-9]*) SILENCE=3600 ;; esac
FAILURE_COOLDOWN="${ZYZ_WATCHDOG_FAILURE_COOLDOWN_SEC:-600}"
case "$FAILURE_COOLDOWN" in ''|*[!0-9]*) FAILURE_COOLDOWN=600 ;; esac
# A finding the main agent left unanswered this long pages the user
# (notify_stuck).
ESCALATE="${ZYZ_WATCHDOG_ESCALATE_SEC:-600}"
case "$ESCALATE" in ''|*[!0-9]*) ESCALATE=600 ;; esac
TASK_EXPECT=""
SESSION_PROGRESS=""
ONCE="${ZYZ_WATCHDOG_ONCE:-0}"

WATCHDOG_PID_FILE="${ZYZ_WATCHDOG_PID_FILE:-}"
watchdog_cleanup() {
    [ -n "$WATCHDOG_PID_FILE" ] && rm -f "$WATCHDOG_PID_FILE" 2>/dev/null || true
}
trap 'exit 0' TERM INT HUP
trap watchdog_cleanup EXIT

# IM escalation (0.32.0, best-effort, fail-open). Every finding goes to the
# MAIN agent first (the stdout line wakes it); the user is paged only when
# that did not help — this task already had a finding reported at least
# ESCALATE seconds ago and nobody in the session has moved since
# (SESSION_PROGRESS unchanged: no tool call, no user prompt, no status write).
# One page per silent stretch per task; any progress starts a new stretch.
# Before, every finding paged the user too, so a subagent's step the main
# agent was already handling, or a reminder it answered a minute later, sent
# a pointless IM (notify.sh Policy). On Codex nobody reads the stdout line, so
# the second report pages — the user is still told. Backgrounded so a slow IM
# command never delays the scan. NOTE: a whole-process crash takes this
# monitor down with it, so this covers stalls, not host death.
NOTIFY_SH="$SCRIPT_DIR/../hooks/scripts/notify.sh"
notify_stuck() { # $1 = task root, $2 = short message, $3 = origin (main|subagent|stall),
                # $4 = task label for the IM (default: basename of $1)
    [ -x "$NOTIFY_SH" ] || return 0
    local mark cur prog state first now
    mark="$1/runtime/nag/watchdog-escalate"
    cur="${SESSION_PROGRESS:-none}"
    now="$(zyz_now)"
    prog=""; state=""; first=""
    [ -f "$mark" ] && read -r prog state first <"$mark"
    case "${first:-}" in ''|*[!0-9]*) prog="" ;; esac
    if [ "${prog:-}" != "$cur" ]; then
        mkdir -p "${mark%/*}" 2>/dev/null
        zyz_write_atomic "$mark" "$cur reported $now"
        return 0
    fi
    [ "$state" != paged ] || return 0
    [ $((now - first)) -ge "$ESCALATE" ] || return 0
    zyz_write_atomic "$mark" "$cur paged $first"
    "$NOTIFY_SH" --event stuck --task-root "$1" --origin "${3:-main}" ${4:+--task-id "$4"} \
        --message "watchdog $(( (now - first) / 60 )) 分钟前提醒过主 agent，此后会话里没有任何动作：$2" \
        </dev/null >/dev/null 2>&1 &
}

# One scan of one task dir. Every task of this session is scanned on its own
# (#23): a session pointer may list several tasks, and each gets its own
# findings, cooldown markers and IMs, all keyed under that task's runtime/.
#
# The two halves are scoped differently. (a) Subagent findings read the runtime
# records stored under this dir, but no hook input says which task a role was
# dispatched FOR (records sit under the primary task), so they are
# session-scoped: the caller runs this only while SOME task of the session is
# active or in design (roots_any_dispatching; design review dispatches roles
# too, #30), the unharvested predicate compares against the newest status write
# of ANY task ($SESSION_STATUS_MTIME), and for a multi-task session the message
# names no owning task — the main agent decides from its dispatch record.
# (b) The status-stale finding is about THIS task's status.md, so it needs
# THIS task to be active.
scan_task() {
    local root status_file phase suppress mtime runtime_observation runtime_events
    local event_kind key role_line age detail scope_note im_task
    root="$1"
    status_file="$root/status.md"
    phase="$(zyz_phase_of "$status_file")"
    scope_note="$(zyz_subagent_scope_note "$roots" "$root")"
    im_task=""
    [ -z "$scope_note" ] || im_task="$SESSION_LABEL"

    # (a) Fixed-pack liveness, tracking, probe, no-output, and
    # terminal-but-unharvested signals. One authenticated observer snapshot
    # owns enumeration; shell never treats pathname membership as new-format
    # state authority. The subagent findings are NEVER suppress-gated (A option)
    # and their stuck IMs carry --origin subagent to bypass notify.sh's
    # suppression.
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
  # A dispatched role that has not ended: an executor for the no-executor scan.
  if age<horizon:print(f"live\t{key}\t{role}\t{age}\t-")
  if stale<age<horizon:
   if cap!="armed":print(f"tracking\t{key}\t{role}\t{age}\t{cap}")
   else:print(f"stale\t{key}\t{role}\t{age}\t-")
  if item.get("probe_state")=="overdue":print("probe\t{}\t{}\t0\t{}".format(key,role,item.get("probe_id") or "unknown"))
  if item.get("no_output_state")=="unchanged":print(f"no-output\t{key}\t{role}\t0\t-")
except Exception:pass
' "$ROLE_STALE" "$HORIZON" "$(zyz_now)" "$SESSION_STATUS_MTIME" 2>/dev/null || true)"
    while IFS="$(printf '\t')" read -r event_kind key role_line age detail; do
        [ -n "$event_kind" ] || continue
        case "$event_kind" in
            live)
                SESSION_LIVE=$((SESSION_LIVE + 1))
                ;;
            stale)
                zyz_cooldown_ok "$root/runtime/nag/watchdog-$key.last" "$COOLDOWN" || continue
                printf '[zyz-worker watchdog] 角色 %s（%s）已静默 %s 分钟且没有正常结束——请核实平台状态，发送一个精确的重连 probe，确认死亡后先用 agent-runtime-state.sh finalize 收尾，再重新派发。%s\n' "$key" "$role_line" "$((age / 60))" "$scope_note"
                notify_stuck "$root" "角色 ${role_line} 已静默 $((age / 60)) 分钟，且没有正常结束" subagent "$im_task"
                ;;
            tracking)
                zyz_cooldown_ok "$root/runtime/nag/watchdog-tracking-$key-$detail.last" "$COOLDOWN" || continue
                printf '[zyz-worker watchdog] 角色 %s（%s）的 fixed-pack 跟踪状态为 %s——有可用的确切持久化事件时就据此对账；不要把无法核实的实例当作健康的安静状态。%s\n' "$key" "$role_line" "$detail" "$scope_note"
                notify_stuck "$root" "角色 ${role_line} 的跟踪状态尚未对账（${detail}）" subagent "$im_task"
                ;;
            probe)
                zyz_cooldown_ok "$root/runtime/nag/watchdog-probe-$key-$detail.last" "$COOLDOWN" || continue
                printf '[zyz-worker watchdog] 重连 probe %s（角色实例 %s）已逾期，且没有收到明确匹配的 ACK；单有心跳不算 ACK。现在就查询平台的 running/inflight 状态，并按有界恢复协议处理。%s\n' "$detail" "$key" "$scope_note"
                notify_stuck "$root" "角色 ${role_line} 的重连 probe 已逾期，且没有 ACK" subagent "$im_task"
                ;;
            no-output)
                zyz_cooldown_ok "$root/runtime/nag/watchdog-no-output-$key.last" "$COOLDOWN" || continue
                printf '[zyz-worker watchdog] 角色实例 %s 已达到无输出阈值，而它固定的 LIVE_INVENTORY 基线仍与当前受描述符约束的物理树一致；这个并行通道（lane）可能已经丢失。%s\n' "$key" "$scope_note"
                notify_stuck "$root" "角色 ${role_line} 已达到无输出阈值；这个 lane 可能已经丢失" subagent "$im_task"
                ;;
            unharvested)
                zyz_cooldown_ok "$root/runtime/nag/watchdog-unharvested-$key.last" "$COOLDOWN" || continue
                if [ -n "$scope_note" ]; then
                    printf '[zyz-worker watchdog] 角色 %s（%s）已完成（DONE/FINALIZED），但看起来没有被处理——它结束后主 agent 一直空闲，所以它的完成通知可能没有送达（这是 watchdog 路径上的备份信号）。到它所属任务的 lanes/ 下读取它的 lane 报告（旧任务在所属任务的 subtasks/ 下，是结果 SubTask 文件）及其持久日志，记录到该任务的 status.md，然后继续。%s\n' "$key" "$role_line" "$scope_note"
                else
                    printf '[zyz-worker watchdog] 角色 %s（%s）已完成（DONE/FINALIZED），但看起来没有被处理——它结束后主 agent 一直空闲，所以它的完成通知可能没有送达（这是 watchdog 路径上的备份信号）。读取 %s/lanes/ 下它的 lane 报告（旧任务为 %s/subtasks/ 下的结果 SubTask 文件）及其持久日志，记录到 %s，然后继续。\n' "$key" "$role_line" "$root" "$root" "$status_file"
                fi
                notify_stuck "$root" "角色 ${role_line} 已结束，但其结果尚未处理" subagent "$im_task"
                ;;
        esac
    done <<EOF
$runtime_events
EOF

    # (b) stale overall status file of THIS task during its active phase.
    # Suppressed when the main agent is awaiting-user / idle (main-state read
    # once per task per tick): this is a main-agent-attributed finding, so its
    # stdout and its main-origin stuck IM both go silent while the main agent is
    # not working.
    zyz_phase_active "$phase" || return 0

    suppress="$(zyz_main_state_suppresses "$root" && echo 1 || echo 0)"
    mtime="$(zyz_mtime "$status_file")"
    if [ -n "$mtime" ]; then
        age=$(( $(zyz_now) - mtime ))
        # A wait declaration mutes this, judged with the running ids of the
        # last Stop (a `wait --ref` whose task is gone mutes nothing).
        if [ "$age" -gt "$(zyz_expect_tune "$TASK_EXPECT" status-stale-sec "$STATUS_STALE")" ] \
            && [ "$suppress" = 0 ] && ! zyz_status_waiting "$status_file" \
            && [ "$(zyz_expect_field "$TASK_EXPECT" mutes)" != 1 ]; then
            if zyz_cooldown_ok "$root/runtime/nag/watchdog-status.last" "$COOLDOWN"; then
                printf '[zyz-worker watchdog] 状态文件 %s 已有 %s 分钟没有更新，当前处于活跃阶段 %s——现在就把当前进度、活跃角色、阻塞项和下一步写进去。\n' \
                    "$status_file" "$((age / 60))" "$phase"
                notify_stuck "$root" "状态文件已有 $((age / 60)) 分钟没有更新，当前处于活跃阶段 ${phase}" main
            fi
        fi
    fi
}

# Stop snapshot fields (written by L4 at every Stop, deleted by the next
# main-agent tool call or user prompt):
# `<epoch> <executors|unknown> <ids|-|unknown> <non-resident-crons>`.
read_snapshot() { # <root> -> sets SNAP_EPOCH SNAP_COUNT SNAP_IDS SNAP_CRONS
    local snap
    SNAP_EPOCH=""; SNAP_COUNT=""; SNAP_IDS="unknown"; SNAP_CRONS=0
    snap="$(head -n1 "$1/runtime/stop-snapshot" 2>/dev/null)"
    [ -n "$snap" ] || return 0
    set -- $snap
    case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
    SNAP_EPOCH="$1"; SNAP_COUNT="${2:-unknown}"
    # The ids are a fact only for a snapshot that has them; `-` means none ran.
    case "${3:-}" in '') ;; *) SNAP_IDS="$3" ;; esac
    case "${4:-}" in ''|*[!0-9]*) ;; *) SNAP_CRONS="$4" ;; esac
}

# Declaration scan (#24), for every task of the session that is not finished.
# The agent declares why a task may be quiet (expect.sh); this scan holds it to
# the declaration and is the only thing that wakes an idle main agent for it:
#  (1) a `wait` whose time has come: wake the main agent; repeat every
#      remind-sec (Tune, default ZYZ_WATCHDOG_REMIND_SEC) while the row stays,
#      and page the user after the second unanswered reminder. Moving the row
#      (a new --at) or clearing it re-arms / ends this.
#  (2) a `wait --ref <id>` whose background task is gone from the host's list
#      at the last Stop (observed facts beat declarations): say so once.
#  (3) an `observing` task with no scheduled wait: nothing will bring the main
#      agent back to observe. Long cooldown (ZYZ_WATCHDOG_OBSERVE_SEC).
#  (4) no executor: the periodic backstop of the L4 clause — this task still has
#      work, the main agent stopped at least no-executor-sec ago and has done
#      nothing since (the stop-snapshot still exists), the host reported zero
#      executors at that Stop (residents excluded), no dispatched role is open
#      (SESSION_LIVE), and no wait/user declaration mutes it. Catches a Stop
#      inside L4's cooldown, or a lane that ended after the Stop.
#  (5) session silence (0.32.0): this task still has work, nobody in the
#      session has moved it for silence-sec (SESSION_PROGRESS: the newest tool
#      call by any agent, user prompt or status write of the session), no
#      dialog is open, and the same declarations as (4) do not mute it. The
#      floor under every other check; repeats every remind-sec.
# Design phase (#30): (1) and (2) hold as anywhere — a declaration is honoured
# in every phase that is not finished or awaiting confirmation. (4) never
# applies: stopping with nothing running is what the approval gate looks
# like. (5) applies only when the main agent stopped with something running
# (the stop-snapshot counted an executor, or a dispatched role is open): the
# task then waits on that, not on the user, and nobody has moved for
# silence-sec. A `user` declaration mutes it as usual.
# None of these is muted by main-state idle: a Stop always records idle, so
# only an explicit declaration may mute them (or, for (5), a dialog opened
# after the last progress). Their IMs use --origin stall so
# notify.sh's idle suppression does not drop them either. (4) is silent when
# the snapshot says `unknown` (no background_tasks: Codex).
scan_declarations() {
    local root status_file phase expect pending key at reason ref kind rest
    local mark remind last now n design
    root="$1"
    status_file="$root/status.md"
    [ -f "$status_file" ] || return 0
    phase="$(zyz_phase_of "$status_file")"
    zyz_phase_terminal "$phase" && return 0
    design=0
    zyz_phase_design "$phase" && design=1
    [ "$design" = 1 ] || zyz_phase_active "$phase" || zyz_phase_observing "$phase" || return 0
    now="$(zyz_now)"
    read_snapshot "$root"
    expect="$(zyz_expect_eval "$root" "$SNAP_IDS")"
    # Unknown declarations (no python3, evaluator failure): fail open.
    zyz_expect_known "$expect" || return 0
    remind="$(zyz_expect_tune "$expect" remind-sec "$REMIND")"
    mkdir -p "$root/runtime/nag" 2>/dev/null

    while IFS="$(printf '\t')" read -r kind key at reason when; do
        case "$kind" in
            due)
                mark="$root/runtime/nag/expect-due-$key"
                set -- $(head -n1 "$mark" 2>/dev/null)
                # Marker: `<at> <last-reminder-epoch> <reminders-sent>`.
                if [ "${1:-}" = "$at" ]; then
                    last="${2:-0}"; n="${3:-0}"
                    case "$last$n" in *[!0-9]*) last=0; n=0 ;; esac
                    [ $((now - last)) -ge "$remind" ] || continue
                else
                    n=0
                fi
                n=$((n + 1))
                zyz_write_atomic "$mark" "$at $now $n"
                if [ "$n" = 1 ]; then
                    printf '[zyz-worker watchdog] 到点了：你声明的等待 %s 的时间已到（%s）。现在就去看：%s。看完之后用 %s 处理这一行——结果已到就 clear %s 并继续；还要再等就用新的时间重新 set（例如 --at +1h）；任务已无后续就把 Current Phase 改成 done。\n' \
                        "$key" "${when:-$at}" "$reason" "$(zyz_expect_cli) --task $root" "$key"
                else
                    printf '[zyz-worker watchdog] 第 %s 次提醒：等待 %s 早已到点，这一行还没有处理（%s）。现在就去看，然后 clear 它或用新的时间重新 set（%s）。\n' \
                        "$n" "$key" "$reason" "$(zyz_expect_cli) --task $root"
                fi
                notify_stuck "$root" "等待 ${key} 已到点（第 ${n} 次提醒），这一行还没有处理" stall
                ;;
            dead)
                ref="$at"
                mark="$root/runtime/nag/expect-dead-$key-$ref"
                [ -e "$mark" ] && continue
                zyz_write_atomic "$mark" "$now"
                printf '[zyz-worker watchdog] 你声明在等的 %s 绑定的后台任务 %s 已经不在运行了（它可能已结束，结束通知也许没送到你这里）。现在就去读它的输出 / 结果并 clear %s；它其实只是被换掉了的话，用新的任务 id 重新 set（%s）。\n' \
                    "$key" "$ref" "$key" "$(zyz_expect_cli) --task $root"
                ;;
        esac
    done <<ZYZ_EXPECT_EVENTS
$(printf '%s\n' "$expect" | awk -F '\t' '$1 == "due" || $1 == "dead" { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }')
ZYZ_EXPECT_EVENTS

    if zyz_phase_observing "$phase"; then
        [ "$(zyz_expect_field "$expect" next)" = 1 ] && return 0
        # A host-scheduled wakeup (not declared resident) seen at the last Stop.
        [ "$SNAP_CRONS" = 0 ] || return 0
        zyz_cooldown_ok "$root/runtime/nag/watchdog-observing.last" "$OBSERVE" || return 0
        printf '[zyz-worker watchdog] %s\n' "$(zyz_observing_msg "$root" watchdog)"
        notify_stuck "$root" "任务处于观察期，但没有排定下一次检查" stall
        return 0
    fi

    # (4) no executor and (5) session silence are two views of one finding —
    # nobody is moving this task — so they share one set of mutes and never
    # both fire for the same tick: (4) is the fast, precise one (the host said
    # nothing was running when the main agent stopped); (5) is the floor that
    # holds whatever the host's list still shows (a dead teammate, an entry that
    # will never move the task) and on every platform: nobody in the session
    # has called a tool, the user has not spoken and no status was written for
    # silence-sec. A dialog opened since then (AskUserQuestion, a permission
    # prompt) means the main agent is legitimately blocked on the user.
    local noexec=0 silent="" noexec_sec snap_left snap_ids
    noexec_sec="$(zyz_expect_tune "$expect" no-executor-sec "$NO_EXECUTOR")"
    # The executors counted at the Stop, minus agent-team teammates that have
    # ended their turn since and stayed idle for no-executor-sec (with the
    # background tasks they started): nobody will move them again unless
    # messaged, and the main agent's missed idle notice is exactly the case
    # this scan exists for. Teammate records live under the primary task.
    snap_left="$SNAP_COUNT"
    case "$SNAP_COUNT" in
        ''|0|*[!0-9]*) ;;
        *)
            if [ -s "$root/runtime/stop-teammates" ]; then
                snap_ids="$SNAP_IDS"
                case "$snap_ids" in -|unknown) snap_ids="" ;; esac
                snap_left="$(zyz_executors_left "$snap_ids" "$(zyz_expect_field "$expect" residents),$(zyz_teammates_idle_ids "${roots%%
*}" "$root/runtime/stop-teammates" "$noexec_sec")")"
            fi
            ;;
    esac
    if [ "$SESSION_LIVE" = 0 ] && [ -n "$SNAP_EPOCH" ] && [ "$snap_left" = 0 ] \
        && [ $((now - SNAP_EPOCH)) -ge "$noexec_sec" ]; then
        noexec=1
    fi
    local silence_sec
    silence_sec="$(zyz_expect_tune "$expect" silence-sec "$SILENCE")"
    if [ -n "$SESSION_PROGRESS" ] && [ $((now - SESSION_PROGRESS)) -ge "$silence_sec" ] \
        && ! zyz_user_dialog_open "$root"; then
        silent=$(( (now - SESSION_PROGRESS) / 60 ))
        # A wakeup the host had scheduled at the last Stop (ScheduleWakeup /
        # CronCreate / loop, not declared resident) will bring the main agent
        # back, so the silence is planned — but only for a bounded time past
        # silence-sec (a ScheduleWakeup is at most an hour out). A cron that
        # never fires, or fires a day later, still gets reported.
        if [ "$SNAP_CRONS" != 0 ] && [ -n "$SNAP_EPOCH" ] \
            && [ $((now - SNAP_EPOCH)) -lt $((silence_sec + 3600)) ]; then
            silent=""
        fi
    fi
    # Design (#30): waiting on the user is the normal state there, so the
    # no-executor finding never applies, and the silence floor applies only
    # when the main agent stopped with something still running (the host listed
    # an executor at that Stop, or a dispatched role is open): then the task
    # waits on that, not on the user. It is the complement of main-state.sh's
    # design fallback, which pages the user when that same count is zero. No
    # snapshot, or `unknown` (Codex): quiet.
    if [ "$design" = 1 ]; then
        noexec=0
        case "$SNAP_COUNT" in
            ''|0|*[!0-9]*) [ "$SESSION_LIVE" != 0 ] || silent="" ;;
        esac
    fi
    [ "$noexec" = 1 ] || [ -n "$silent" ] || return 0
    # A due wait already has its own, more specific reminder above.
    printf '%s\n' "$expect" | grep -q "^due$(printf '\t')" && return 0
    pending="$(zyz_status_uncommitted "$status_file")"
    pending="${pending#*	}"
    [ "$design" = 1 ] || zyz_task_has_pending_work "$phase" "$pending" || return 0
    zyz_status_waiting "$status_file" && return 0
    [ "$(zyz_expect_field "$expect" mutes_noexec)" = 1 ] && return 0
    if [ "$noexec" = 1 ]; then
        zyz_cooldown_ok "$root/runtime/nag/watchdog-no-executor.last" "$COOLDOWN" || return 0
        printf '[zyz-worker watchdog] %s\n' "$(zyz_no_executor_msg "$root" "$phase" "$pending" watchdog)"
        notify_stuck "$root" "任务仍在 ${phase} 阶段，但已没有任何执行者，正在静默搁置" stall
        return 0
    fi
    zyz_cooldown_ok "$root/runtime/nag/watchdog-silence.last" "$remind" || return 0
    printf '[zyz-worker watchdog] %s\n' "$(zyz_silence_msg "$root" "$phase" "$pending" "$silent" "$(failure_note "$SESSION_PROGRESS")")"
    notify_stuck "$root" "任务仍在 ${phase} 阶段，但整个会话已 ${silent} 分钟没有任何动静" stall
}

# Every StopFailure record of this session, pending and reported, one line each
# (`<epoch>\t<agent_id>\t<agent_type>\t<error>\t<details>`, unordered; callers
# filter and sort).
failure_records_since() {
    local r f
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        for f in "$r"/runtime/api-failures/*.rec "$r"/runtime/api-failures/reported/*.rec; do
            [ -f "$f" ] && head -n1 "$f" 2>/dev/null
        done
    done <<ZYZ_ROOTS
$roots
ZYZ_ROOTS
} 2>/dev/null

# "<who> HH:MM <error>（<details>）" for one record line.
failure_label() {
    local epoch id type error details who when
    IFS="$(printf '\t')" read -r epoch id type error details <<EOF
$1
EOF
    if [ "${id:--}" = - ]; then who="主 agent"; else who="${type:--}（${id}）"; fi
    when="$(date -r "$epoch" +%H:%M 2>/dev/null || date -d "@$epoch" +%H:%M 2>/dev/null || printf '%s' "$epoch")"
    printf '%s %s 报 %s' "$who" "$when" "${error:-unknown}"
    [ "${details:--}" = - ] || printf '（%s）' "$details"
}

# The silence finding's note on the API errors that ended the MAIN agent's own
# turn since the session last moved — often the very reason it stopped (a 402
# on the main agent). Subagent / teammate failures have their own report
# (scan_failures), so they are not repeated here.
failure_note() {
    local recs line note=""
    recs="$(failure_records_since | awk -F '\t' -v s="${1:-0}" '$1 ~ /^[0-9]+$/ && $1 >= s && $2 == "-"' | sort -n | tail -n 3)"
    [ -n "$recs" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] && note="${note:+${note}；}$(failure_label "$line")"
    done <<EOF
$recs
EOF
    printf '此后宿主报告过主 agent 的 API 错误中断：%s——同一个错误反复出现时（billing_error / authentication_failed / rate_limit），先别急着重派，告诉用户并用 wait 声明过一段时间再试。' "$note"
}

# API-error terminations (0.32.0). hooks/scripts/api-failure.sh records every
# StopFailure under the primary task; the host ignores that hook's output, so
# this scan is the only path by which a lane that died on an API error reaches
# the main agent — before it, the user got an IM and the main agent waited all
# night for a result that would never arrive. Subagent / teammate records are
# reported once each (batched while inside FAILURE_COOLDOWN, so a persistent
# provider error cannot turn re-dispatch into a fast loop) and then moved to
# reported/. A record of the main agent's own turn (no agent_id) is not
# reported here: waking a main agent that just failed would loop at the poll
# interval on a persistent error. The session-silence finding names it instead,
# at its remind-sec cadence.
scan_failures() {
    local root r f line epoch id rest n=0 detail="" batch=""
    root="${roots%%
*}"
    # Records sit under the primary task at the time they were written; the
    # primary may have changed since (a re-arm), so every task's dir is read.
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        for f in "$r"/runtime/api-failures/*.rec; do
            [ -f "$f" ] || continue
            line="$(head -n1 "$f" 2>/dev/null)"
            IFS="$(printf '\t')" read -r epoch id rest <<EOF
$line
EOF
            # A malformed record and the main agent's own failure are filed,
            # not reported (see above).
            case "$epoch" in ''|*[!0-9]*) id=- ;; esac
            if [ "${id:--}" = - ]; then
                mkdir -p "${f%/*}/reported" 2>/dev/null && mv -f "$f" "${f%/*}/reported/" 2>/dev/null
                continue
            fi
            n=$((n + 1))
            detail="${detail:+${detail}；}$(failure_label "$line")"
            batch="${batch}${f}
"
        done
    done <<ZYZ_ROOTS
$roots
ZYZ_ROOTS
    [ "$n" -gt 0 ] || return 0
    zyz_cooldown_ok "$root/runtime/nag/watchdog-api-failure.last" "$FAILURE_COOLDOWN" || return 0
    printf '[zyz-worker watchdog] 有 %s 个 subagent / teammate 的这一轮因 API 错误中断：%s。如果你还没有处理过它的失败（后台派发的角色，失败结果可能根本没送到你这里），就不要再等它的结果。现在：(1) 用 ListAgents、它的会话记录和它写过的文件核实它停在哪、你是否已经重派过；(2) 还没重派的，盘点它已经落盘的产出，按"续做而非重做"、用同样的完整范围重新派发（teammate 可以直接 SendMessage 让它从会话记录接着做；fixed-pack 跟踪的角色先 agent-runtime-state.sh finalize）；(3) 同一个错误反复出现（billing_error / authentication_failed / rate_limit）时先别立刻重派：告诉用户，并用 %s set <key> wait --at +30m --reason … 声明过一段时间再试。%s\n' \
        "$n" "$detail" "$(zyz_expect_cli) --task $root" "$(zyz_subagent_scope_note "$roots" "$root")"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        mkdir -p "${f%/*}/reported" 2>/dev/null && mv -f "$f" "${f%/*}/reported/" 2>/dev/null
    done <<EOF
$batch
EOF
    return 0
}

# 0 when some task of the session is not finished.
roots_any_open() {
    local r
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        zyz_task_is_done "$r" || return 0
    done <<ZYZ_ROOTS
$roots
ZYZ_ROOTS
    return 1
}

# 0 when some task of the session is in a phase that dispatches roles: an
# active phase, or design (#30: a stuck design-review role must be reported).
roots_any_dispatching() {
    local r phase
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        phase="$(zyz_phase_of "$r/status.md")"
        if zyz_phase_active "$phase" || zyz_phase_design "$phase"; then return 0; fi
    done <<ZYZ_ROOTS
$roots
ZYZ_ROOTS
    return 1
}

while :; do
    case "${ZYZ_WATCHDOG_PARENT_PID:-}" in
        ''|*[!0-9]*) ;;
        *) kill -0 "$ZYZ_WATCHDOG_PARENT_PID" 2>/dev/null || exit 0 ;;
    esac
    [ -d "$BASE" ] || exit 0
    roots="$(zyz_task_roots "$BASE")"
    SESSION_LIVE=0
    # The last moment anyone moved the session: the silence floor and the IM
    # escalation (notify_stuck) both read it, so it is taken before any scan.
    SESSION_PROGRESS=""
    [ -z "$roots" ] || SESSION_PROGRESS="$(zyz_roots_last_progress "$roots")"
    if [ -n "$roots" ] && roots_any_dispatching; then
        SESSION_STATUS_MTIME="$(zyz_roots_latest_status_mtime "$roots")"
        SESSION_LABEL="$(zyz_roots_label "$roots")"
        while IFS= read -r root; do
            [ -n "$root" ] || continue
            read_snapshot "$root"
            TASK_EXPECT="$(zyz_expect_eval "$root" "$SNAP_IDS")"
            scan_task "$root" </dev/null
        done <<ZYZ_WATCHDOG_ROOTS
$roots
ZYZ_WATCHDOG_ROOTS
    fi
    # Declarations are honoured in the observing and design phases too, which
    # are not active phases. Needs SESSION_LIVE from every task's scan, so it
    # runs after.
    if [ -n "$roots" ]; then
        while IFS= read -r root; do
            [ -n "$root" ] && scan_declarations "$root" </dev/null
        done <<ZYZ_WATCHDOG_ROOTS
$roots
ZYZ_WATCHDOG_ROOTS
        # A lane that died on an API error matters in every phase but a
        # finished one (a design-review lane dying leaves design waiting too).
        roots_any_open && scan_failures </dev/null
    fi
    [ "$ONCE" = 1 ] && exit 0
    sleep "$INTERVAL"
done
