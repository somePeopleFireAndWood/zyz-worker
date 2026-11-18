#!/usr/bin/env bash
#
# status-freshness.sh — L1 status-file freshness reminder (PostToolUse).
#
# ## Trigger point
#
# Registered in hooks/hooks.json for PostToolUse with matcher "*", sync
# (must be sync so additionalContext lands next to the tool result). Fires
# in the main agent and inside every subagent.
#
# ## Inputs
#
# - stdin: hook JSON (cwd, agent_id?, agent_type?).
# - env: CLAUDE_PROJECT_DIR (fallback base dir), ZYZ_HOOKS_DISABLE=1 skips,
#   ZYZ_STATUS_STALE_SEC (default 600) staleness threshold,
#   ZYZ_STATUS_NAG_COOLDOWN_SEC (default 300) min gap between reminders per
#   audience.
#
# ## Outputs
#
# - For each task of the session (only the primary task for a subagent
#   audience): when `<task-root>/status.md` exists, its mtime is older than
#   ZYZ_STATUS_STALE_SEC, the task phase is an active execution phase, and
#   the per-audience cooldown has elapsed: prints hookSpecificOutput
#   additionalContext telling the CURRENT context (main agent or the
#   subagent that made the tool call) to persist progress into the status
#   file now — one line per stale task. Otherwise prints nothing.
# - Side effect: stamps `<task-root>/runtime/nag/<audience>.last` (epoch)
#   for the cooldown.
#
# ## Failure behavior
#
# Fail open: any missing input/pointer/parser exits 0 with no output. The
# reminder is advisory context, never a block.
#
# ## Supported agents
#
# All (main agent and subagents). Review-agent is excluded from the
# subagent reminder text (it must not write files); it still triggers no
# output because the audience filter skips it.

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

# Defer to post-agent-flush.sh on an Agent return. Both hooks are sync
# PostToolUse and both read this same status-file mtime, so on a stale-status
# Agent return they BOTH injected the same "persist the status file" instruction
# into one turn (verified) — their cooldowns are independent, so neither
# suppressed the other. post-agent-flush.sh owns that moment: its message is
# more specific (it names the just-received subagent result and says to persist
# it before dispatching further work) and its threshold is tighter. Everything
# else still gets this hook's reminder.
case "$(zyz_get tool_name)" in Agent|spawn_agent|collaboration.spawn_agent) exit 0 ;; esac

agent_type="$(zyz_get agent_type)"
role="$(zyz_role_of "$agent_type")"
case "$role" in
    review-agent) exit 0 ;;
    implementation-agent|test-agent) audience="$role" ;;
    "") audience="main" ;;
    *) exit 0 ;;
esac

# The main agent owns every task of its session; a subagent belongs to the
# primary task (first pointer line), where subagent-track registered it.
[ "$audience" = main ] || roots="${roots%%
*}"

stale_sec="${ZYZ_STATUS_STALE_SEC:-600}"
cooldown="${ZYZ_STATUS_NAG_COOLDOWN_SEC:-300}"
now="$(zyz_now)"

# Prints the reminder for one task root, or nothing.
freshness_msg() {
    local root status_file phase mtime age mins expect
    root="$1"
    status_file="$root/status.md"
    [ -f "$status_file" ] || return 0
    phase="$(zyz_phase_of "$status_file")"
    zyz_phase_active "$phase" || return 0
    mtime="$(zyz_mtime "$status_file")"
    [ -n "$mtime" ] || return 0
    age=$((now - mtime))
    [ "$age" -gt "$stale_sec" ] || return 0

    # A valid wait/user declaration (legacy Waiting On, or expect.sh) only
    # suppresses the MAIN audience's generic status-stale reminder, and a
    # per-task `Tune: status-stale-sec` may raise its threshold. Parsed only
    # once the cheap default-threshold check above has passed (Tune cannot go
    # below the default). Role liveness and post-result flushing are
    # orthogonal.
    if [ "$audience" = main ]; then
        zyz_status_waiting "$status_file" && return 0
        # L1 sees no background task list, so a `wait --ref` counts here
        # until its time even if its task has ended (L3/L4 do check the ref).
        expect="$(zyz_expect_eval "$root" unknown)"
        [ "$(zyz_expect_field "$expect" mutes)" = 1 ] && return 0
        [ "$age" -gt "$(zyz_expect_tune "$expect" status-stale-sec "$stale_sec")" ] || return 0
    fi

    zyz_cooldown_ok "$root/runtime/nag/$audience.last" "$cooldown" || return 0

    mins=$((age / 60))
    if [ "$audience" = "main" ]; then
        printf '%s' "[zyz-worker watchdog] 任务状态文件已有 ${mins} 分钟没有更新（${status_file}）。现在就把当前进度、活跃角色、阻塞项和下一步写进去——状态保存在磁盘上，而不是会话上下文里。"
    else
        printf '%s' "[zyz-worker watchdog] 任务状态文件已有 ${mins} 分钟没有更新。请尽快通过你的常规输出汇报当前进度；如果你维护着 SubTask 状态文件，现在就更新它（${status_file} 是主 agent 负责的总状态文件）。"
    fi
}

msg=""
while IFS= read -r root; do
    [ -n "$root" ] || continue
    one="$(freshness_msg "$root")"
    [ -n "$one" ] || continue
    msg="${msg:+$msg
}$one"
done <<EOF
$roots
EOF
[ -n "$msg" ] || exit 0
zyz_emit_context "PostToolUse" "$msg"
exit 0
