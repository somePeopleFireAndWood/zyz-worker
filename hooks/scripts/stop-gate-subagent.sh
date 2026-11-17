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
#   last_assistant_message, agent_transcript_path).
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
# - When the final message ends by "waiting for the notification / monitor /
#   background run" and the role's transcript (agent_transcript_path) shows it
#   started one (#24): blocks ONCE per role instance — even under
#   stop_hook_active — telling it to wait in the foreground or hand the run's
#   id/output path/ETA to the main agent explicitly. Marker:
#   runtime/nag/subagent-waiting-<agent-id>.
#
# ## Failure behavior
#
# Fail open: missing input/pointer/parser exits 0 (allow stop). No-op when
# no task pointer of the session resolves (the gate never
# applies outside an execute-task workflow). When stop_hook_active is true,
# the short-message check never blocks again (no loops); the waiting check is
# bounded by its per-instance marker; the built-in 8-consecutive-block cap also
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
    stop_hook_active=true
else
    stop_hook_active=false
fi
final_msg="$(zyz_get last_assistant_message)"

# Waiting-ending check (#24). A role that starts a background run (Bash
# run_in_background, Monitor, nohup/setsid/&) and then ends its turn "waiting
# for the notification" is never woken again: once it stops it is DONE, and the
# main agent has no reason to wait on a process it does not know about — that is
# how a test run finished green and nobody looked for half an hour. Heuristic
# (phrase on the tail of the final message, plus background evidence in the
# role's own transcript when the host provides one), so it blocks at most ONCE
# per role instance — and, unlike the short-message check, also while
# stop_hook_active is set, because the incident's waiting line was the role's
# answer to the short-message block.
waiting_ending() {
    command -v python3 >/dev/null 2>&1 || return 1
    printf '%s' "$final_msg" | python3 -c '
import json, re, sys
msg = sys.stdin.read()
lines = [l.strip() for l in msg.strip().splitlines() if l.strip()]
tail = " ".join(lines[-3:]).lower()
pats = [
    r"\b(waiting|wait|await(ing)?)\b[^.\n]{0,40}\b(notification|notify|completion|complete|finish|monitor|background|process|job|run|test|suite|result|output)s?\b",
    r"\b(will|i.ll|i will)\s+(be\s+)?(notified|woken|pinged)\b",
    r"等(待|着)?[^。\n]{0,20}(通知|完成|结束|跑完|结果|monitor|后台)",
    r"(后台|monitor)[^。\n]{0,20}(运行中|还在跑|在跑|执行中)",
]
if not any(re.search(p, tail) for p in pats):
    sys.exit(1)
# The compliant alternative — handing the still-running job to the main agent
# with its id/output path/ETA — also mentions a running background job; it is
# what the block asks for, so it must not be blocked.
if re.search(r"主 ?agent|main agent|主代理|hand(ing|ed)? (it )?(off|over)", tail):
    sys.exit(1)
path = sys.argv[1]
if not path:
    sys.exit(0)
try:
    f = open(path, encoding="utf-8", errors="replace")
except OSError:
    sys.exit(0)
def uses(node):
    if isinstance(node, dict):
        if node.get("type") == "tool_use":
            name, inp = node.get("name"), node.get("input") or {}
            if name == "Monitor": return True
            if isinstance(inp, dict):
                if inp.get("run_in_background") is True: return True
                cmd = inp.get("command")
                if isinstance(cmd, str) and re.search(r"\bnohup\b|\bsetsid\b|&\s*(disown\s*)?$", cmd.strip()): return True
        return any(uses(v) for v in node.values())
    if isinstance(node, list):
        return any(uses(v) for v in node)
    return False
with f:
    for line in f:
        try:
            if uses(json.loads(line)): sys.exit(0)
        except ValueError:
            continue
sys.exit(1)
' "$(zyz_get agent_transcript_path)" 2>/dev/null
}

wait_mark="$root/runtime/nag/subagent-waiting-$(zyz_sanitize "${agent_id:-unknown}")"
if [ -n "$agent_id" ] && [ ! -e "$wait_mark" ] && waiting_ending; then
    mkdir -p "$(dirname "$wait_mark")" 2>/dev/null && zyz_write_atomic "$wait_mark" "$(zyz_now)"
    zyz_emit_block "[zyz-worker watchdog] 你以「等待后台任务 / monitor 的通知」收尾，但 subagent 一旦结束本轮就算完成：monitor 和后台进程都不会再唤醒你，主 agent 也不知道要去等它——结果出来时没有人会看。二选一：(1) 现在就在前台等到结果出来（阻塞地轮询它的退出码 / 输出文件），再输出完整的最终报告；(2) 如果确实无法等待，就在最终报告里写明后台任务的 id、命令、输出 / 日志路径、预计完成时间，以及结果出来后要做什么，明确交给主 agent 跟进——不要写成「我在等待」。"
    exit 0
fi

if [ "$stop_hook_active" = true ]; then
    mark_done
    exit 0
fi

min_chars="${ZYZ_SUBAGENT_MIN_FINAL_CHARS:-80}"
case "$min_chars" in
    ''|*[!0-9]*) min_chars=80 ;;
esac
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
    zyz_emit_block "[zyz-worker watchdog] 你的最终消息太短，主 agent 无法据此写入任务状态文件。结束之前，请为你的角色（${role}）输出一份完整的最终报告：完成了什么、还剩什么、阻塞项、做出的决策，以及你改动过的确切文件路径。如果工作已经做完，现在就把它总结出来——不要重做。"
    exit 0
fi

mark_done
exit 0
