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
# Fail open: missing input, missing JSON parser, missing `.zyz-worker/
# current-task` pointer, or any error exits 0 (allow). Only inspects
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

zyz_emit_deny "PreToolUse" "[zyz-worker watchdog] This dispatch caps what ${target} must deliver (matched: \"${hit}\"). Reducing a role's total deliverable to get a result out of it is not allowed — a review that reports only its worst few findings passes every downstream gate while the rest ride into delivery. What IS allowed: reduce PER-ROUND output volume, not total scope. Re-dispatch at the SAME full scope and ask for it in labeled steps, one message per step (for a review, split along the coverage dimensions: design conformance, correctness, test quality, regression risk), and drive it with follow-ups. Only genuinely stage a first installment when you actually intend to collect the remainder in the following messages — a token phrase added to pass this check, with no real follow-through, is the same defect this guard exists to stop."
exit 0
