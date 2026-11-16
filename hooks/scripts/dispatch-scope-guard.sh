#!/usr/bin/env bash
#
# dispatch-scope-guard.sh — L5 dispatch-side scope guard (PreToolUse, Agent).
#
# ## Trigger point
#
# Registered in hooks/hooks.json for PreToolUse with matcher "^Agent$", sync
# (a deny decision requires sync). Fires when the main agent is about to
# dispatch a subagent — BEFORE the reduced-scope instruction reaches it.
# This is the only watchdog layer that inspects what the dispatch asks for;
# every other layer observes after the fact.
#
# ## Inputs
#
# - stdin: hook JSON (cwd, tool_input.prompt, tool_input.subagent_type,
#   agent_id?).
# - env: CLAUDE_PROJECT_DIR (fallback base dir), ZYZ_HOOKS_DISABLE=1 skips,
#   ZYZ_SCOPE_GUARD_DISABLE=1 skips just this guard.
#
# ## Outputs
#
# - Normally nothing (allow).
# - When the dispatch prompt caps the deliverable ("only the top 3
#   findings", "just the overall verdict", "只要总结论", "最严重 3 条",
#   "一句话结论") AND carries no commitment to deliver the remainder
#   ("then continue", "remaining", "all dimensions", "分步", "step 1 of"):
#   emits a PreToolUse deny with a reason telling the main agent to
#   re-dispatch at full scope, split into steps instead. Reducing per-round
#   output volume is fine; reducing the total deliverable is not.
# - Side effect: appends the blocked attempt to
#   `<task-root>/runtime/scope-guard.log` for auditability.
#
# ## Failure behavior
#
# Fail open: missing input, missing JSON parser, no resolvable task pointer
# for this session, or any error exits 0 (allow). Only inspects
# dispatches to the zyz-worker roles; other subagent types pass untouched.
#
# ## Supported agents
#
# Main agent dispatching implementation-agent / test-agent / review-agent.

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0
[ "${ZYZ_SCOPE_GUARD_DISABLE:-0}" = "1" ] && exit 0

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

target="$(zyz_role_of "$(zyz_get tool_input.subagent_type)")"
[ -n "$target" ] || target="$(zyz_role_of "$(zyz_get tool_input.task_name)")"
case "$target" in
    implementation-agent|test-agent|review-agent) ;;
    *) exit 0 ;;
esac

prompt="$(zyz_get tool_input.prompt)"
[ -n "$prompt" ] || prompt="$(zyz_get tool_input.message)"
[ -n "$prompt" ] || exit 0

hit="$(zyz_scope_cap_hit "$prompt")"
[ -n "$hit" ] || exit 0
zyz_scope_continuation "$prompt" && exit 0

mkdir -p "$root/runtime" 2>/dev/null
printf '%s\t%s\t%s\n' "$(zyz_iso)" "$target" "$hit" \
    >> "$root/runtime/scope-guard.log" 2>/dev/null

zyz_emit_deny "PreToolUse" "[zyz-worker watchdog] 这次派发限缩了 ${target} 必须交付的内容（匹配到：\"${hit}\"）。不允许为了从某个角色那里拿到结果而缩减它的总交付——一份只报告最严重几条发现的评审能通过下游每一道闸门，其余问题则会一路带进交付。允许的是：缩减每一轮的输出量，而不是总范围。请以同样完整的范围重新派发，要求它分成带标签的步骤、每条消息一步来交付（对评审而言，按覆盖维度拆分：设计符合度、正确性、测试质量、回归风险），并用后续消息推动它做完。只有当你确实打算在接下来的消息里收齐剩余部分时，才把这次真正安排为第一批交付——为了通过这项检查而加上一句敷衍的话、却没有真正跟进，正是本守卫要阻止的同一种缺陷。"
exit 0
