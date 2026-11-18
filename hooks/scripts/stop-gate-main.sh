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
# - stdin: hook JSON (cwd, stop_hook_active, background_tasks[], session_crons[]).
# - env: CLAUDE_PROJECT_DIR (fallback base dir), ZYZ_HOOKS_DISABLE=1 skips,
#   ZYZ_ROLE_STALE_SEC (default 900) role-silence threshold,
#   ZYZ_ROLE_STALE_HORIZON_SEC (default 21600) ignore-older-than horizon,
#   ZYZ_STOP_STATUS_STALE_SEC (default 1200) status-age threshold at stop,
#   ZYZ_STOP_GATE_COOLDOWN_SEC (default 600) min gap between blocks.
#
# ## Outputs
#
# - Normally nothing (allow stop).
# - Blocks (top-level {"decision":"block","reason":...}) when a task of this
#   session (every line of its session pointer) is in an active execution
#   phase AND either:
#     (a) a fixed-pack role instance is non-terminal and its latest logical
#         START/HEARTBEAT fact is stale, or its tracking state is unverifiable
#         (covers subagents killed by API errors, where SubagentStop never
#         fired); or
#     (b) the overall status file is older than ZYZ_STOP_STATUS_STALE_SEC; or
#     (c) the task has no executor (#24): it still has work (an active phase
#         other than delivery, or an uncommitted SubTask), yet the host reports
#         no in-flight background task or session cron (plugin monitors and
#         declared residents excluded), the observer sees no non-terminal role
#         instance, and status.md declares no wait (see below). Fails open when
#         the input has no background_tasks array.
#   It also blocks (own cooldown) an `observing`-phase task that has no
#   scheduled wait (#24): nothing would wake the main agent to observe.
#   Declarations are read through expect_state.py (expect.sh writes them):
#   `kind=wait|user` mute (b)/(c), `kind=resident` tasks are not executors, and
#   `Tune: status-stale-sec` may relax (b).
#   The reason tells the main agent exactly which roles to check/restart
#   and/or to flush the status file. Never blocks when stop_hook_active is
#   true, and at most once per cooldown window per task; reasons for several
#   tasks are joined into one block.
# - Side effect, on every Stop (blocked or not): writes
#   <task-dir>/runtime/stop-snapshot = `<epoch> <executor-count|unknown>
#   <running-ids|-|unknown> <non-resident-cron-count>` for the L3 scans.
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

base="$(zyz_get cwd)"
[ -n "$base" ] || base="${CODEX_PROJECT_DIR:-}"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || base="$PWD"

roots="$(zyz_task_roots "$base")"
[ -n "$roots" ] || exit 0

# Stop snapshot for the L3 no-executor scan (#24): `<epoch> <executors>`. The
# monitor cannot see background_tasks, so every Stop — blocked or not, and
# before the stop_hook_active exit — leaves what the harness reported here.
# heartbeat.sh deletes it on the next main-agent tool call and main-state.sh on
# the next user prompt, so it exists only while the main agent has done nothing
# since this Stop.
# Declared resident tasks (dev servers, `tail -f` Monitors, ...) never end and
# never move the task, so they are not executors. Background tasks are
# session-scoped, so a declaration in any task of the session counts. The
# snapshot's third field keeps the running ids, so L3 can tell a `wait --ref`
# whose task is gone.
bg_ids="$(zyz_bg_executor_ids)"
residents=""
expect_dir="$(mktemp -d "${TMPDIR:-/tmp}/zyz-expect.XXXXXX" 2>/dev/null)" || expect_dir=""
expect_for() { # <root> -> zyz_expect_eval output, cached per Stop
    local f
    [ -n "$expect_dir" ] || { zyz_expect_eval "$1" "${bg_ids:--}"; return 0; }
    f="$expect_dir/$(printf '%s' "$1" | cksum | tr -d ' ')"
    [ -f "$f" ] || zyz_expect_eval "$1" "${bg_ids:--}" > "$f" 2>/dev/null
    cat "$f" 2>/dev/null
}
while IFS= read -r root; do
    [ -n "$root" ] || continue
    residents="${residents},$(zyz_expect_field "$(expect_for "$root")" residents)"
done <<EOF
$roots
EOF
bg_executors="$(zyz_executors_left "$bg_ids" "$residents")"
# Host-scheduled wakeups that are not residents: they bring the main agent back,
# which also satisfies an observing task (recorded for L3 in the snapshot).
crons_left="$(zyz_executors_left "$(zyz_bg_cron_ids)" "$residents")"
while IFS= read -r root; do
    [ -n "$root" ] || continue
    mkdir -p "$root/runtime" 2>/dev/null \
        && zyz_write_atomic "$root/runtime/stop-snapshot" "$(zyz_now) $bg_executors ${bg_ids:--} $crons_left"
done <<EOF
$roots
EOF

[ "$(zyz_get stop_hook_active)" = "true" ] && { [ -z "$expect_dir" ] || rm -rf "$expect_dir"; exit 0; }

# Observing phase (#24): main work delivered, the task kept open to check on
# something later. None of the "is anyone working?" clauses apply, but it must
# have a scheduled wait, or nothing will bring the main agent back when it is
# time to look. Blocks once per cooldown window; resolved by scheduling one
# (expect.sh set <key> wait --at ...) or moving the phase to done.
observing_reasons=""
while IFS= read -r root; do
    [ -n "$root" ] || continue
    zyz_phase_observing "$(zyz_phase_of "$root/status.md")" || continue
    ev="$(expect_for "$root")"
    # Unknown declarations (no python3, evaluator failure) -> fail open.
    zyz_expect_known "$ev" || continue
    [ "$(zyz_expect_field "$ev" next)" = 1 ] && continue
    # A host-scheduled wakeup that is not declared resident also brings the
    # main agent back (observed facts count).
    [ "$crons_left" = 0 ] || continue
    zyz_cooldown_ok "$root/runtime/nag/stopgate-observing.last" "${ZYZ_STOP_GATE_COOLDOWN_SEC:-600}" || continue
    observing_reasons="${observing_reasons:+$observing_reasons }$(zyz_observing_msg "$root" stop)"
done <<EOF
$roots
EOF

if ! zyz_roots_any_active "$roots"; then
    [ -z "$expect_dir" ] || rm -rf "$expect_dir"
    [ -z "$observing_reasons" ] || zyz_emit_block "[zyz-worker watchdog] ${observing_reasons}"
    exit 0
fi
running_types="$(zyz_bg_running_types)"

# One observer snapshot per task, shared by the per-task clauses below and the
# session-wide live-role count of the no-executor clause. Without a temp dir
# each caller observes on its own (slower, same answers).
obs_dir="$(mktemp -d "${TMPDIR:-/tmp}/zyz-stopgate.XXXXXX" 2>/dev/null)" || obs_dir=""
trap 'rm -rf ${obs_dir:+"$obs_dir"} ${expect_dir:+"$expect_dir"} 2>/dev/null' EXIT
observation_for() {
    local f
    [ -n "$obs_dir" ] || { zyz_runtime_observe "$1" false; return 0; }
    f="$obs_dir/$(printf '%s' "$1" | cksum | tr -d ' ')"
    [ -f "$f" ] || zyz_runtime_observe "$1" false > "$f" 2>/dev/null
    cat "$f" 2>/dev/null
}
# Dispatched roles that have not ended, summed over the session's tasks (their
# records sit under the primary task). Stays empty when no task could be
# observed (macOS genesis-unavailable); the clause then relies on
# background_tasks alone, which already lists every background subagent.
session_live_roles=""
while IFS= read -r root; do
    [ -n "$root" ] || continue
    n="$(observation_for "$root" | zyz_live_role_count "${ZYZ_ROLE_STALE_HORIZON_SEC:-21600}")"
    [ -n "$n" ] && session_live_roles=$(( ${session_live_roles:-0} + n ))
done <<EOF
$roots
EOF
# Subagent clauses are session-scoped (#23): records live under one task dir,
# but nothing says which task a role serves, so they are judged against the
# newest status write of ANY task and never name an owning task.
session_status_mtime="$(zyz_roots_latest_status_mtime "$roots")"

# Prints the block reason for one task root (with its cooldown applied), or
# nothing. The main agent owns every task of its session, so each task is gated
# on its own and the reasons are joined into one block. The status clause needs
# THIS task to be active; the subagent clauses only need some task of the
# session to be (checked above), since a role's records may sit under a task
# that is not the one it was dispatched for.
gate_reason() {
    local root status_file phase own_active stale_sec horizon runtime_observation
    local stale_roles status_stale_sec status_age mtime reason running_roles detail
    local key age role_type stale_kind unharvested_roles udetail role cooldown
    local scope_note pending expect
    root="$1"
    status_file="$root/status.md"
    phase="$(zyz_phase_of "$status_file")"
    own_active=0
    [ -f "$status_file" ] && zyz_phase_active "$phase" && own_active=1
    scope_note="$(zyz_subagent_scope_note "$roots" "$root")"
    expect="$(expect_for "$root")"

    stale_sec="${ZYZ_ROLE_STALE_SEC:-900}"
    horizon="${ZYZ_ROLE_STALE_HORIZON_SEC:-21600}"
    runtime_observation="$(observation_for "$root")"
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

    # A per-task `Tune: status-stale-sec` may only relax the threshold.
    status_stale_sec="$(zyz_expect_tune "$expect" status-stale-sec "${ZYZ_STOP_STATUS_STALE_SEC:-1200}")"
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
            detail="${detail}${key}（${role_type}，${stale_kind}，已静默 $((age / 60)) 分钟）；"
        done <<EOF
$stale_roles
EOF
        if [ -n "$detail" ]; then
            reason="已派发的角色看起来已经死亡或卡住，且没有正常结束：${detail}它们可能已被 API 错误杀掉，而 SubagentStop 没有触发。先核实平台状态，再走受支持的 runtime 协议：创建一个精确的 probe 并调查它的 ACK；确认死亡后运行 agent-runtime-state.sh finalize <task-dir> <agent-id> <role> <reason> [replacement-id]。绝不手工删除或伪造 runtime 标记。${scope_note}"
        fi
    fi

    # Status-stale attribution clause. Gated by BOTH the agent's declarations
    # (a valid legacy Waiting On row, or a valid Expect wait/user row) AND the
    # signal-driven main-state suppression
    # (zyz_main_state_suppresses is true when the main agent is awaiting-user /
    # idle): either being active means the main agent is legitimately not writing
    # status, so status-stale must not block idle. The stale-role and unharvested
    # clauses are NOT gated — those are subagent-attributed (A option).
    if [ "$own_active" = 1 ] && [ "$status_age" -gt "$status_stale_sec" ] \
        && ! zyz_status_waiting "$status_file" \
        && [ "$(zyz_expect_field "$expect" mutes)" != 1 ] \
        && ! zyz_main_state_suppresses "$root"; then
        [ -n "$reason" ] && reason="${reason} "
        reason="${reason}总状态文件（${status_file}）在活跃阶段（${phase}）已有 $((status_age / 60)) 分钟没有更新。停下空闲之前，先把当前进度、活跃角色、阻塞项和下一步写进去。"
    fi

    # Terminal-but-unharvested detection (L4 primary): a role reached a terminal
    # state (clean DONE / adjudicated FINALIZED) but the main agent has been idle
    # since — its last tool call predates completion (main_heartbeat_epoch <=
    # terminal_epoch) AND no status was written since (status.md mtime <=
    # terminal_epoch). Reuses the SAME observer snapshot. Every epoch is
    # isinstance(int)-guarded before comparison so a missing epoch is skipped, never
    # thrown (an unguarded None<=int would abort the whole filter). Fails open
    # (observer error / macOS genesis-unavailable → empty → no block), like the
    # stale-role branch above. "No status written since" spans every task of the
    # session: the result may have been recorded in another task's status.md.
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
' "$session_status_mtime" 2>/dev/null || true)"
    if [ -n "$unharvested_roles" ]; then
        udetail=""
        while IFS="$(printf '\t')" read -r key role; do
            [ -n "$key" ] || continue
            if [ -n "$scope_note" ]; then
                udetail="${udetail}${role}（${key}）；"
            else
                udetail="${udetail}${role}（${key}；它在 ${root}/subtasks/ 下的结果 SubTask 文件及其持久日志）；"
            fi
        done <<EOF
$unharvested_roles
EOF
        if [ -n "$udetail" ]; then
            [ -n "$reason" ] && reason="${reason} "
            if [ -n "$scope_note" ]; then
                reason="${reason}已完成的角色看起来没有被收取——它们已到达终止状态（DONE/FINALIZED），但主 agent 此后一直空闲，所以这次完成可能没有被处理（完成通知丢失）：${udetail}现在就到它所属任务的 subtasks/ 下读取它的结果 SubTask 文件及其持久日志，记录到该任务的 status.md，然后继续——这样即可解除本次阻断。${scope_note}"
            else
                reason="${reason}已完成的角色看起来没有被收取——它们已到达终止状态（DONE/FINALIZED），但主 agent 此后一直空闲，所以这次完成可能没有被处理（完成通知丢失）：${udetail}现在就读取上面列出的每个结果，记录到 ${status_file}，然后继续——这样即可解除本次阻断。"
            fi
        fi
    fi

    # No-executor clause (#24): this task still has work, yet nothing will move
    # it once the main agent stops — no in-flight background task or scheduled
    # wakeup (background_tasks / session_crons), no dispatched role that has
    # not ended, and no explicit wait. Every per-role check above is silent in
    # exactly this shape (the role ended DONE, the main agent was busy elsewhere
    # so nothing looks unharvested, status was just written), which is how a
    # task sat idle for half an hour while the main agent said a lane was still
    # running. NOT gated by main-state: idle is the symptom, not an excuse. Only
    # an explicit declaration mutes it — a valid legacy Waiting On row, an
    # Expect wait not yet due (whose ref task, if any, is still running), or an
    # Expect user row written since the user last spoke. Unknown declarations
    # (evaluator unavailable) fail open. An absent
    # background_tasks array (Codex, unreachable registry) means unknown and
    # fails open.
    if [ "$own_active" = 1 ] && [ "$bg_executors" = 0 ] && [ "${session_live_roles:-0}" = 0 ]; then
        pending="$(zyz_status_uncommitted "$status_file")"
        pending="${pending#*	}"
        if zyz_task_has_pending_work "$phase" "$pending" \
            && zyz_expect_known "$expect" \
            && ! zyz_status_waiting "$status_file" \
            && [ "$(zyz_expect_field "$expect" mutes_noexec)" != 1 ]; then
            [ -n "$reason" ] && reason="${reason} "
            reason="${reason}$(zyz_no_executor_msg "$root" "$phase" "$pending" stop)"
        fi
    fi

    [ -n "$reason" ] || return 0

    cooldown="${ZYZ_STOP_GATE_COOLDOWN_SEC:-600}"
    zyz_cooldown_ok "$root/runtime/nag/stopgate.last" "$cooldown" || return 0

    printf '%s' "$reason"
}

reasons=""
while IFS= read -r root; do
    [ -n "$root" ] || continue
    one="$(gate_reason "$root")"
    [ -n "$one" ] || continue
    reasons="${reasons:+$reasons }$one"
done <<EOF
$roots
EOF

reasons="${observing_reasons:+$observing_reasons }${reasons}"
[ -n "$reasons" ] || exit 0
zyz_emit_block "[zyz-worker watchdog] ${reasons}"
exit 0
