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
#        ZYZ_WATCHDOG_NO_EXECUTOR_SEC    stopped-with-no-executor threshold
#                                        (default 600)
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
# - "[zyz-worker watchdog] you declared waiting on <key> ... the re-check time
#    has arrived" (#24): a Waiting On row's next-check-epoch passed.
# Findings are rate-limited per key via runtime/nag/watchdog-<key>.last.
# The role threshold is deliberately higher than the L4 stop gate's: a
# healthy role can reason for a while without tool calls, and only L4 can
# cross-check background_tasks; L3 asks the main agent to verify, not to
# blindly restart.
#
# ## Failure behavior
#
# Never exits on scan errors; sleeps and retries. Exits 0 on SIGTERM/INT/HUP
# or when the base dir disappears. Silent when no task pointer of this session
# resolves (zyz_task_roots: .zyz-worker/sessions/<session-id>, then the legacy
# .zyz-worker/current-task, then $ZYZ_TASK_DIR). The session id comes from
# $ZYZ_SESSION_ID (the Codex starter sets it) or the Claude monitor's own
# $CLAUDE_CODE_SESSION_ID, plus the live id in ~/.claude/sessions/$CLAUDE_PID.json.
# Each task listed in the session pointer is scanned and reported separately.
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
NO_EXECUTOR="${ZYZ_WATCHDOG_NO_EXECUTOR_SEC:-600}"
case "$NO_EXECUTOR" in ''|*[!0-9]*) NO_EXECUTOR=600 ;; esac
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
notify_stuck() { # $1 = task root, $2 = short message, $3 = origin (main|subagent),
                # $4 = task label for the IM (default: basename of $1)
    [ -x "$NOTIFY_SH" ] || return 0
    "$NOTIFY_SH" --event stuck --task-root "$1" --message "$2" --origin "${3:-main}" \
        ${4:+--task-id "$4"} >/dev/null 2>&1 &
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
    local d claimed
    claimed="$(zyz_claimed_task_dirs)"
    for d in "$BASE"/.zyz-worker/tasks/*/; do
        [ -d "$d" ] || continue
        # A task dir counts as evidence only while it is not finished; completed
        # tasks legitimately leave their directories behind forever.
        zyz_task_is_done "${d%/}" && continue
        [ -f "${d%/}/status.md" ] || continue
        # A task another session's pointer claims is that session's, not a sign
        # that ours went missing (#23): several sessions may share this dir.
        [ -n "$claimed" ] && printf '%s\n' "$claimed" \
            | grep -qxF "$(cd "$d" 2>/dev/null && pwd -P)" 2>/dev/null && continue
        return 0
    done
    return 1
}

# Physical paths of every task dir named by any session pointer under $BASE,
# one per line. Read only by the unarmed check above; resolution never uses it.
zyz_claimed_task_dirs() {
    local f line dir
    for f in "$BASE"/.zyz-worker/sessions/*; do
        [ -f "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            dir="$(zyz_resolve_ref_at "$BASE" "$line")"
            [ -n "$dir" ] && (cd "$dir" 2>/dev/null && pwd -P)
        done < "$f"
    done
    return 0
}

# One scan of one task dir. Every task of this session is scanned on its own
# (#23): a session pointer may list several tasks, and each gets its own
# findings, cooldown markers and IMs, all keyed under that task's runtime/.
#
# The two halves are scoped differently. (a) Subagent findings read the runtime
# records stored under this dir, but no hook input says which task a role was
# dispatched FOR (records sit under the primary task), so they are
# session-scoped: the caller runs this only while SOME task of the session is
# active, the unharvested predicate compares against the newest status write
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
                    printf '[zyz-worker watchdog] 角色 %s（%s）已完成（DONE/FINALIZED），但看起来没有被处理——它结束后主 agent 一直空闲，所以它的完成通知可能没有送达（这是 watchdog 路径上的备份信号）。到它所属任务的 subtasks/ 下读取它的结果 SubTask 文件及其持久日志，记录到该任务的 status.md，然后继续。%s\n' "$key" "$role_line" "$scope_note"
                else
                    printf '[zyz-worker watchdog] 角色 %s（%s）已完成（DONE/FINALIZED），但看起来没有被处理——它结束后主 agent 一直空闲，所以它的完成通知可能没有送达（这是 watchdog 路径上的备份信号）。读取 %s/subtasks/ 下它的结果 SubTask 文件及其持久日志，记录到 %s，然后继续。\n' "$key" "$role_line" "$root" "$status_file"
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

    # (c) Waiting On rows whose next-check-epoch has arrived (#24). A valid row
    # only mutes the status-stale finding; once it is due nothing else would
    # wake an idle main agent to re-check. Once per (key, next-check-epoch) —
    # renewing the row with a new check time re-arms it — and at most once per
    # cooldown per key. Not gated by main-state: the reminder exists for idle.
    local wkey wnext wreason wmark
    while IFS="$(printf '\t')" read -r wkey wnext wreason; do
        [ -n "$wkey" ] || continue
        wmark="$root/runtime/nag/watchdog-wait-$wkey.next"
        [ "$(zyz_epoch_in "$wmark")" = "$wnext" ] && continue
        zyz_cooldown_ok "$root/runtime/nag/watchdog-wait-$wkey.last" "$COOLDOWN" || continue
        zyz_write_atomic "$wmark" "$wnext"
        printf '[zyz-worker watchdog] 你在 %s 里声明在等 %s（%s），复查时间（next-check-epoch=%s）已到。现在就复查：结果到了就收取、记录并删除这一行；还没到就先核实它是否真的还在进行（ps / ListAgents / 后台任务的输出文件），仍在进行才写一条新的有时限 Waiting On 行，已经结束或死亡就按恢复协议处理。\n' \
            "$status_file" "$wkey" "$wreason" "$wnext"
    done <<ZYZ_WATCHDOG_WAITS
$(zyz_status_waits_due "$status_file")
ZYZ_WATCHDOG_WAITS

    suppress="$(zyz_main_state_suppresses "$root" && echo 1 || echo 0)"
    mtime="$(zyz_mtime "$status_file")"
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
}

# No-executor scan (#24), the periodic backstop of the L4 clause: this task
# still has work, the main agent stopped at least NO_EXECUTOR seconds ago and
# has made no tool call or received no user prompt since (the stop-snapshot
# still exists), the host reported zero executors at that Stop, no dispatched
# role is still open (SESSION_LIVE, summed over the session), and status.md
# declares no wait. Catches what L4 let through — a Stop inside its cooldown,
# or a lane that ended after the Stop. Deliberately NOT muted by main-state
# idle/awaiting-user: a Notification marks idle_prompt as awaiting-user a
# minute after every Stop, so only an explicit declaration may mute it. Its IM
# uses --origin stall so notify.sh's idle suppression does not drop it either.
# Silent when the snapshot says `unknown` (no background_tasks: Codex).
scan_no_executor() {
    local root status_file phase snap snap_epoch snap_count pending
    root="$1"
    status_file="$root/status.md"
    [ -f "$status_file" ] || return 0
    phase="$(zyz_phase_of "$status_file")"
    zyz_phase_active "$phase" || return 0
    [ "$SESSION_LIVE" = 0 ] || return 0
    snap="$(head -n1 "$root/runtime/stop-snapshot" 2>/dev/null)"
    snap_epoch="${snap%% *}"; snap_count="${snap#* }"
    case "$snap_epoch" in ''|*[!0-9]*) return 0 ;; esac
    [ "$snap_count" = 0 ] || return 0
    [ $(( $(zyz_now) - snap_epoch )) -ge "$NO_EXECUTOR" ] || return 0
    pending="$(zyz_status_uncommitted "$status_file")"
    pending="${pending#*	}"
    zyz_task_has_pending_work "$phase" "$pending" || return 0
    zyz_status_waiting "$status_file" && return 0
    zyz_status_awaiting_user "$status_file" "$root" && return 0
    zyz_cooldown_ok "$root/runtime/nag/watchdog-no-executor.last" "$COOLDOWN" || return 0
    printf '[zyz-worker watchdog] %s\n' "$(zyz_no_executor_msg "$root" "$phase" "$pending" watchdog)"
    notify_stuck "$root" "任务仍在 ${phase} 阶段，但已没有任何执行者，正在静默搁置" stall
}

while :; do
    case "${ZYZ_WATCHDOG_PARENT_PID:-}" in
        ''|*[!0-9]*) ;;
        *) kill -0 "$ZYZ_WATCHDOG_PARENT_PID" 2>/dev/null || exit 0 ;;
    esac
    [ -d "$BASE" ] || exit 0
    roots="$(zyz_task_roots "$BASE")"
    if [ -z "$roots" ] && [ "$UNARMED_REPORTED" = "false" ] && zyz_unarmed_is_suspicious; then
        UNARMED_REPORTED="true"
        printf '[zyz-worker watchdog] 未启用：无法从 %s 解析到任务指针（已尝试该目录下本会话的 .zyz-worker/sessions/<session-id>、共享的 .zyz-worker/current-task 和 $ZYZ_TASK_DIR；解析器有意不搜索同级 worktree，也不按“最新”或“未完成”去挑别的会话的指针——那些任务可能属于另一个并发会话）。本会话的 watchdog 层处于失效状态——死掉的 subagent 不会被报告，空闲门也不会拦住停止。如果有正在运行的 execute-task，请用 hooks/scripts/task-pointer.sh arm <任务目录绝对路径> 写入本会话的指针。每次未命中只报告一次，不会每轮扫描都报一次。\n' "$BASE"
    fi
    if [ -n "$roots" ]; then
        UNARMED_REPORTED="false"
    fi
    if [ -n "$roots" ] && zyz_roots_any_active "$roots"; then
        SESSION_STATUS_MTIME="$(zyz_roots_latest_status_mtime "$roots")"
        SESSION_LABEL="$(zyz_roots_label "$roots")"
        SESSION_LIVE=0
        while IFS= read -r root; do
            [ -n "$root" ] && scan_task "$root" </dev/null
        done <<ZYZ_WATCHDOG_ROOTS
$roots
ZYZ_WATCHDOG_ROOTS
        # Needs SESSION_LIVE from every task's scan, so it runs after them.
        while IFS= read -r root; do
            [ -n "$root" ] && scan_no_executor "$root" </dev/null
        done <<ZYZ_WATCHDOG_ROOTS
$roots
ZYZ_WATCHDOG_ROOTS
    fi
    [ "$ONCE" = 1 ] && exit 0
    sleep "$INTERVAL"
done
