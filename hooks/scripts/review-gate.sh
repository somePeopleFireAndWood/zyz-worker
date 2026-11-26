#!/usr/bin/env bash
#
# review-gate.sh — review-round gate (PreToolUse, Agent).
#
# ## Trigger point
#
# Registered in hooks/hooks.json for PreToolUse with the dispatch matcher
# "^(Agent|spawn_agent|collaboration\.spawn_agent)$", sync (a deny decision
# requires sync), next to the L5 scope guard. Fires when the main agent is
# about to dispatch a subagent; only review-agent dispatches are inspected.
#
# Round caps and strict-tier convergence checks are enforced by
# review-round.sh `start`; this gate makes sure no review runs outside a
# started round. A tiered task's review-agent dispatch must carry
#
#   review-point=<id> round=<n> mode=<full|incremental>
#
# matching the latest round review-round.sh started for <id> and that round's
# recorded mode (full for round 1 and `start --full` rounds, incremental
# otherwise), as long as that round has no result yet (§10.8-2: a resulted
# round's marker would let reviews go past the cap); a closed point accepts no
# marker until it is reopened.
#
# ## Inputs
#
# - stdin: hook JSON (cwd, tool_input.prompt|message,
#   tool_input.subagent_type|task_name).
# - env: CLAUDE_PROJECT_DIR / CODEX_PROJECT_DIR (fallback base dir),
#   ZYZ_HOOKS_DISABLE=1 skips, ZYZ_REVIEW_GATE_DISABLE=1 skips just this gate.
#
# ## Outputs
#
# - Normally nothing (allow).
# - Marker missing, malformed, for an unknown point, or not the latest
#   started round: a PreToolUse deny whose reason names the command to run
#   first (`review-round.sh start <point>` / `open …`). The attempt is
#   appended to `<task-root>/runtime/review-gate.log`.
#
# ## Failure behavior
#
# Fail open: missing input or parser, no resolvable task pointer, no task of
# this session with a valid `- Tier:` line (tasks from before the tiers), or
# any error exits 0 (allow). Other subagent types pass untouched.
#
# ## Supported agents
#
# Main agent dispatching review-agent (bare or `zyz-worker:` scoped).

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0
[ "${ZYZ_REVIEW_GATE_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

zyz_json_ok || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"
[ -n "$ZYZ_HOOK_INPUT" ] || exit 0

target="$(zyz_role_of "$(zyz_get tool_input.subagent_type)")"
[ -n "$target" ] || target="$(zyz_role_of "$(zyz_get tool_input.task_name)")"
[ "$target" = review-agent ] || exit 0

base="$(zyz_get cwd)"
[ -n "$base" ] || base="${CODEX_PROJECT_DIR:-}"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || base="$PWD"

roots="$(zyz_task_roots "$base")"
[ -n "$roots" ] || exit 0
files=()
while IFS= read -r r; do
    [ -n "$r" ] && [ -f "$r/status.md" ] && files+=("$r/status.md")
done <<ZYZ_ROOTS
$roots
ZYZ_ROOTS
[ "${#files[@]}" -gt 0 ] || exit 0

prompt="$(zyz_get tool_input.prompt)"
[ -n "$prompt" ] || prompt="$(zyz_get tool_input.message)"

verdict="$(printf '%s' "$prompt" | ZYZ_REVIEW_ROUND_CLI="$(zyz_review_round_cli)" \
    python3 "$SCRIPT_DIR/review_round.py" gate "${files[@]}" 2>/dev/null)" || exit 0
tab="$(printf '\t')"
case "$verdict" in
    "deny$tab"*) reason="${verdict#deny"$tab"}" ;;
    *) exit 0 ;;
esac

root="${roots%%
*}"
mkdir -p "$root/runtime" 2>/dev/null
printf '%s\t%s\n' "$(zyz_iso)" "$(printf '%s' "$reason" | tr '\t\n' '  ' | cut -c1-300)" \
    >> "$root/runtime/review-gate.log" 2>/dev/null

zyz_emit_deny "PreToolUse" "[zyz-worker watchdog] 评审轮次闸门拒绝了这次 review-agent 派发：${reason}没有登记过的一轮评审会绕开档位的轮次上限和收口检查（§4.4–§4.6）。按上面的命令处理后，用同样的范围重新派发。"
exit 0
