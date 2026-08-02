#!/usr/bin/env bash
#
# Static + smoke-check suite for the watchdog hooks/monitors layer.
#
# Test groups:
#   T1  file layout + executable bits + bash -n syntax
#   T2  hooks.json / monitors.json validity and required registrations
#   T3  heartbeat + subagent-track behavior (smoke, tmp sandbox)
#   T4  status-freshness + post-agent-flush behavior (smoke)
#   T5  stop-gate-subagent + stop-gate-main behavior (smoke)
#   T6  doc wiring + version consistency across the three manifests
#   T7  L5 dispatch scope guard: capped-phrasing denial, continuation
#       exemption (false-positive guard), scoping, disable switch, fail-open
#
# Usage:
#   bash scripts/test-watchdog-hooks.sh
#
# Behavior:
#   - Runs all groups to completion (does NOT bail on first failure).
#   - Prints PASS / FAIL / SKIP per check.
#   - Summary line: RESULT: <passed>/<total> checks passed [(<n> skipped)]
#   - Exits 0 on success, 1 if any check failed.
#
# Compatibility: macOS bash 3.2 + Linux bash. Smoke tests need jq or python3
# (same requirement as the hooks themselves); they SKIP when neither exists.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
cd "$REPO_ROOT" || { echo "FATAL: cannot cd into '$REPO_ROOT'" >&2; exit 2; }

TOTAL=0; PASSED=0; FAILED=0; SKIPPED=0
EXPECTED_VERSION="0.14.0"
EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/\./\\./g')"

pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); echo "PASS  $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); echo "FAIL  $1${2:+ — $2}"; }
skip() { TOTAL=$((TOTAL+1)); SKIPPED=$((SKIPPED+1)); echo "SKIP  $1${2:+ — $2}"; }

json_tool() {
    command -v jq >/dev/null 2>&1 && return 0
    command -v python3 >/dev/null 2>&1 && return 0
    return 1
}

# ---------------------------------------------------------------------------
# T1 — layout, exec bits, syntax
# ---------------------------------------------------------------------------
HOOK_SCRIPTS="hooks/scripts/lib.sh hooks/scripts/heartbeat.sh hooks/scripts/subagent-track.sh hooks/scripts/status-freshness.sh hooks/scripts/post-agent-flush.sh hooks/scripts/stop-gate-subagent.sh hooks/scripts/stop-gate-main.sh hooks/scripts/dispatch-scope-guard.sh"
for f in $HOOK_SCRIPTS monitors/watchdog.sh hooks/hooks.json monitors/monitors.json hooks/README.md; do
    if [ -f "$f" ]; then pass "T1 exists: $f"; else fail "T1 exists: $f" "missing"; fi
done
for f in $HOOK_SCRIPTS monitors/watchdog.sh; do
    [ -f "$f" ] || continue
    case "$f" in
        */lib.sh) : ;; # sourced, exec bit not required
        *) if [ -x "$f" ]; then pass "T1 executable: $f"; else fail "T1 executable: $f"; fi ;;
    esac
    if bash -n "$f" 2>/dev/null; then pass "T1 syntax: $f"; else fail "T1 syntax: $f"; fi
done

# ---------------------------------------------------------------------------
# T2 — manifest validity and registrations
# ---------------------------------------------------------------------------
if json_tool; then
    for j in hooks/hooks.json monitors/monitors.json; do
        [ -f "$j" ] || continue
        if command -v jq >/dev/null 2>&1; then ok=$(jq . "$j" >/dev/null 2>&1 && echo y || echo n)
        else ok=$(python3 -m json.tool < "$j" >/dev/null 2>&1 && echo y || echo n); fi
        if [ "$ok" = "y" ]; then pass "T2 valid JSON: $j"; else fail "T2 valid JSON: $j"; fi
    done
else
    skip "T2 JSON validity" "no jq/python3"
fi
for ev in PreToolUse PostToolUse SubagentStart SubagentStop Stop; do
    if grep -q "\"$ev\"" hooks/hooks.json 2>/dev/null; then
        pass "T2 hooks.json registers $ev"
    else
        fail "T2 hooks.json registers $ev"
    fi
done
if grep -q 'CLAUDE_PLUGIN_ROOT' hooks/hooks.json 2>/dev/null; then
    pass "T2 hooks.json uses \${CLAUDE_PLUGIN_ROOT}"
else
    fail "T2 hooks.json uses \${CLAUDE_PLUGIN_ROOT}"
fi
if grep -q 'on-skill-invoke:execute-task' monitors/monitors.json 2>/dev/null; then
    pass "T2 monitors.json gated on execute-task"
else
    fail "T2 monitors.json gated on execute-task"
fi
if grep -q 'zyz-worker:.*implementation-agent\|implementation-agent' hooks/hooks.json 2>/dev/null \
    && grep -q 'test-agent' hooks/hooks.json 2>/dev/null \
    && grep -q 'review-agent' hooks/hooks.json 2>/dev/null; then
    pass "T2 role matcher covers all three roles"
else
    fail "T2 role matcher covers all three roles"
fi

# ---------------------------------------------------------------------------
# Smoke sandbox setup (T3-T5)
# ---------------------------------------------------------------------------
SANDBOX=""
if json_tool; then
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/zyz-watchdog-test.XXXXXX")"
fi
backdate() { # $1 minutes-ago, remaining: files
    local m="$1"; shift
    if touch -t "$(date -v-"${m}"M +%Y%m%d%H%M 2>/dev/null)" "$@" 2>/dev/null; then return 0; fi
    touch -d "-${m} minutes" "$@" 2>/dev/null
}

if [ -n "$SANDBOX" ]; then
    T="$SANDBOX/.zyz-worker/tasks/t1"
    mkdir -p "$T"
    echo "t1" > "$SANDBOX/.zyz-worker/current-task"
    printf -- '## Metadata\n\n- Current Phase: implementation\n' > "$T/status.md"
    H="$REPO_ROOT/hooks/scripts"

    # T3 heartbeat + tracking
    echo '{"cwd":"'"$SANDBOX"'","tool_name":"Bash"}' | bash "$H/heartbeat.sh"
    if [ -f "$T/runtime/agents/main.heartbeat" ]; then pass "T3 main heartbeat stamped"; else fail "T3 main heartbeat stamped"; fi
    echo '{"cwd":"'"$SANDBOX"'","agent_id":"a1","agent_type":"zyz-worker:implementation-agent"}' | bash "$H/heartbeat.sh"
    if [ -f "$T/runtime/agents/a1.heartbeat" ]; then pass "T3 subagent heartbeat stamped"; else fail "T3 subagent heartbeat stamped"; fi
    echo '{"cwd":"'"$SANDBOX"'","hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"zyz-worker:implementation-agent"}' | bash "$H/subagent-track.sh"
    if [ -f "$T/runtime/agents/a1.start" ]; then pass "T3 .start stamped"; else fail "T3 .start stamped"; fi
    rm -f "$SANDBOX/.zyz-worker/current-task"
    out="$(echo '{"cwd":"'"$SANDBOX"'","tool_name":"Bash"}' | bash "$H/heartbeat.sh"; echo "rc=$?")"
    if [ "$out" = "rc=0" ]; then pass "T3 no pointer -> silent exit 0"; else fail "T3 no pointer -> silent exit 0" "$out"; fi
    echo "t1" > "$SANDBOX/.zyz-worker/current-task"

    # T4 freshness + post-agent-flush
    out="$(echo '{"cwd":"'"$SANDBOX"'","tool_name":"Bash"}' | bash "$H/status-freshness.sh")"
    if [ -z "$out" ]; then pass "T4 fresh status -> no nag"; else fail "T4 fresh status -> no nag"; fi
    backdate 20 "$T/status.md"
    out="$(echo '{"cwd":"'"$SANDBOX"'","tool_name":"Bash"}' | bash "$H/status-freshness.sh")"
    if printf '%s' "$out" | grep -q 'additionalContext'; then pass "T4 stale status -> main nag"; else fail "T4 stale status -> main nag" "$out"; fi
    out="$(echo '{"cwd":"'"$SANDBOX"'","tool_name":"Bash"}' | bash "$H/status-freshness.sh")"
    if [ -z "$out" ]; then pass "T4 cooldown suppresses repeat nag"; else fail "T4 cooldown suppresses repeat nag"; fi
    out="$(echo '{"cwd":"'"$SANDBOX"'","tool_name":"Read","agent_id":"r1","agent_type":"zyz-worker:review-agent"}' | bash "$H/status-freshness.sh")"
    if [ -z "$out" ]; then pass "T4 review-agent never nagged"; else fail "T4 review-agent never nagged"; fi
    out="$(echo '{"cwd":"'"$SANDBOX"'","tool_name":"Agent","tool_response":{"status":"completed"}}' | bash "$H/post-agent-flush.sh")"
    if printf '%s' "$out" | grep -q 'additionalContext'; then pass "T4 post-Agent stale -> flush nag"; else fail "T4 post-Agent stale -> flush nag" "$out"; fi
    rm -f "$T/runtime/nag/postflush.last"
    out="$(echo '{"cwd":"'"$SANDBOX"'","tool_name":"Agent","tool_response":{"status":"async_launched"}}' | bash "$H/post-agent-flush.sh")"
    if [ -z "$out" ]; then pass "T4 async_launched -> silent"; else fail "T4 async_launched -> silent"; fi

    # T5 stop gates
    out="$(echo '{"cwd":"'"$SANDBOX"'","agent_id":"a1","agent_type":"zyz-worker:implementation-agent","stop_hook_active":false,"last_assistant_message":"done"}' | bash "$H/stop-gate-subagent.sh")"
    if printf '%s' "$out" | grep -q '"decision":"block"'; then pass "T5 short final msg -> block"; else fail "T5 short final msg -> block" "$out"; fi
    if [ ! -f "$T/runtime/agents/a1.done" ]; then pass "T5 blocked stop leaves no .done"; else fail "T5 blocked stop leaves no .done"; fi
    rm -f "$SANDBOX/.zyz-worker/current-task"
    out="$(echo '{"cwd":"'"$SANDBOX"'","agent_id":"a1","agent_type":"zyz-worker:implementation-agent","stop_hook_active":false,"last_assistant_message":"done"}' | bash "$H/stop-gate-subagent.sh")"
    if [ -z "$out" ]; then pass "T5 L2 no pointer -> no gate"; else fail "T5 L2 no pointer -> no gate" "$out"; fi
    echo "t1" > "$SANDBOX/.zyz-worker/current-task"
    LONGMSG="Completed implementation: files a.go b.go c.go changed; tests pass; no blockers; next step review. All acceptance criteria satisfied."
    out="$(echo '{"cwd":"'"$SANDBOX"'","agent_id":"a1","agent_type":"zyz-worker:implementation-agent","stop_hook_active":false,"last_assistant_message":"'"$LONGMSG"'"}' | bash "$H/stop-gate-subagent.sh")"
    if [ -z "$out" ] && [ -f "$T/runtime/agents/a1.done" ]; then pass "T5 long final msg -> allow + .done"; else fail "T5 long final msg -> allow + .done" "$out"; fi

    rm -f "$T/runtime/agents/a1.done" "$T/runtime/nag/stopgate.last"
    backdate 20 "$T/runtime/agents/a1.start" "$T/runtime/agents/a1.heartbeat" "$T/status.md"
    out="$(echo '{"cwd":"'"$SANDBOX"'","stop_hook_active":false,"background_tasks":[]}' | bash "$H/stop-gate-main.sh")"
    if printf '%s' "$out" | grep -q '"decision":"block"' && printf '%s' "$out" | grep -q 'a1'; then
        pass "T5 dead role -> main stop blocked, role named"
    else
        fail "T5 dead role -> main stop blocked, role named" "$out"
    fi
    rm -f "$T/runtime/nag/stopgate.last"
    out="$(echo '{"cwd":"'"$SANDBOX"'","stop_hook_active":false,"background_tasks":[{"id":"1","type":"subagent","status":"running","agent_type":"zyz-worker:implementation-agent"}]}' | bash "$H/stop-gate-main.sh")"
    if printf '%s' "$out" | grep -q 'a1'; then
        fail "T5 running bg subagent not flagged dead" "$out"
    else
        pass "T5 running bg subagent not flagged dead"
    fi
    rm -f "$T/runtime/nag/stopgate.last"
    out="$(echo '{"cwd":"'"$SANDBOX"'","stop_hook_active":false,"background_tasks":[{"id":"1","type":"subagent","status":"running","agent_type":"implementation-agent"}]}' | bash "$H/stop-gate-main.sh")"
    if printf '%s' "$out" | grep -q 'a1'; then
        fail "T5 bare-name bg agent_type matches scoped .start" "$out"
    else
        pass "T5 bare-name bg agent_type matches scoped .start"
    fi
    out="$(echo '{"cwd":"'"$SANDBOX"'","stop_hook_active":true,"background_tasks":[]}' | bash "$H/stop-gate-main.sh")"
    if [ -z "$out" ]; then pass "T5 stop_hook_active -> never re-block"; else fail "T5 stop_hook_active -> never re-block"; fi
    echo "$(date +%Y-%m-%dT%H:%M:%S%z) x" > "$T/runtime/agents/a1.done"
    touch "$T/status.md"
    rm -f "$T/runtime/nag/stopgate.last"
    out="$(echo '{"cwd":"'"$SANDBOX"'","stop_hook_active":false,"background_tasks":[]}' | bash "$H/stop-gate-main.sh")"
    if [ -z "$out" ]; then pass "T5 clean state -> allow stop"; else fail "T5 clean state -> allow stop" "$out"; fi

    out="$(ZYZ_HOOKS_DISABLE=1 sh -c 'echo "{}" | bash '"$H"'/heartbeat.sh'; echo "rc=$?")"
    if [ "$out" = "rc=0" ]; then pass "T5 ZYZ_HOOKS_DISABLE=1 -> no-op"; else fail "T5 ZYZ_HOOKS_DISABLE=1 -> no-op"; fi

    # -----------------------------------------------------------------------
    # T7 — L5 dispatch scope guard
    # -----------------------------------------------------------------------
    G="$H/dispatch-scope-guard.sh"
    sg() { # $1 subagent_type, $2 prompt
        printf '{"cwd":"%s","tool_name":"Agent","tool_input":{"subagent_type":"%s","prompt":"%s"}}' \
            "$SANDBOX" "$1" "$2" | bash "$G"
    }
    printf -- '## Metadata\n\n- Current Phase: review\n' > "$T/status.md"

    # Scope-capping phrasings must be denied.
    blocked=0; capped_total=0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        capped_total=$((capped_total+1))
        if printf '%s' "$(sg 'zyz-worker:review-agent' "$p")" | grep -q '"deny"'; then
            blocked=$((blocked+1))
        else
            echo "      (missed) $p"
        fi
    done <<'ZYZ_T7_CAPPED'
Review ST5. Only the top 3 findings is enough.
st5-review: just give me the overall verdict.
降级要求：只要总结论 + 最严重 3 条。
实在不行就先给一句话结论。
Review this. A brief summary is enough, skip the details.
只需给出结论就行
最严重的三条即可
细节可以省
Top 5 issues is fine.
just report the conclusion
Focus only on blockers.
Limit to 3 findings.
No more than 3 findings please.
at most 3 issues
cap it at 5 findings
high-severity issues only
P0 only
verdict-only is fine
don't be exhaustive
重点问题就行
挑最重要的几条
关键的几条就行
一句话结论也行
ZYZ_T7_CAPPED
    if [ "$blocked" -eq "$capped_total" ]; then
        pass "T7 all $capped_total scope-capping phrasings denied"
    else
        fail "T7 all $capped_total scope-capping phrasings denied" "only $blocked denied"
    fi

    # Legitimate dispatches must pass untouched (false-positive guard).
    allowed=0; legit_total=0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        legit_total=$((legit_total+1))
        if [ -z "$(sg 'zyz-worker:review-agent' "$p")" ]; then
            allowed=$((allowed+1))
        else
            echo "      (false positive) $p"
        fi
    done <<'ZYZ_T7_LEGIT'
Start with the 3 most severe findings, then continue with the rest in later messages.
分四步交付：第1步 设计符合性，后续继续其余维度。
Deliver step 1 of 4: design conformance only. Register all four coverage dimensions.
Give the top 3 first; the remainder in subsequent messages.
分维度交付：先设计符合性，再继续正确性、测试质量、回归风险。
最严重的三条放前面，其余随后列出。
Top 3 first, plus the remaining findings, second pass.
剩余的发现后续再给。
Review ST5 implementation and tests against the design doc. Report all findings by severity.
Order findings by severity, most severe first. Cover all four dimensions.
Re-review after the fix. Include a summary of what changed plus all remaining findings.
Please provide a summary section at the top, then the full findings list.
The most severe issues should be listed first, followed by the rest.
请审查 ST5，逐维度登记覆盖情况，按严重程度排序所有发现。
Do not just report the verdict — list every finding.
只要总结论是不够的，请列出全部发现。
Not only the top 3 — cover everything.
More than just the verdict please — full detail.
不能只给最严重的几条，要全部登记。
Review just the first SubTask's changes.
Only the first 200 lines of the diff matter here.
ZYZ_T7_LEGIT
    if [ "$allowed" -eq "$legit_total" ]; then
        pass "T7 all $legit_total legitimate dispatches allowed (no false positives)"
    else
        fail "T7 all $legit_total legitimate dispatches allowed" "$((legit_total-allowed)) false positives"
    fi

    if [ -z "$(sg 'Explore' 'just give me the overall verdict')" ]; then
        pass "T7 non-role subagent dispatch ignored"
    else
        fail "T7 non-role subagent dispatch ignored"
    fi
    BADP="only the top 3 findings is enough"
    if [ -z "$(ZYZ_SCOPE_GUARD_DISABLE=1 sg 'zyz-worker:review-agent' "$BADP")" ]; then
        pass "T7 ZYZ_SCOPE_GUARD_DISABLE=1 -> no-op"
    else
        fail "T7 ZYZ_SCOPE_GUARD_DISABLE=1 -> no-op"
    fi
    if printf '%s' "$(sg 'review-agent' 'just give me the verdict')" | grep -q '"deny"'; then
        pass "T7 bare (unscoped) role name matched"
    else
        fail "T7 bare (unscoped) role name matched"
    fi
    out="$(sg 'zyz-worker:review-agent' "$BADP")"
    if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"' \
        && printf '%s' "$out" | grep -q 'permissionDecisionReason'; then
        pass "T7 deny uses PreToolUse hookSpecificOutput shape"
    else
        fail "T7 deny uses PreToolUse hookSpecificOutput shape" "$out"
    fi
    if [ -s "$T/runtime/scope-guard.log" ]; then
        pass "T7 blocked attempts appended to scope-guard.log"
    else
        fail "T7 blocked attempts appended to scope-guard.log"
    fi
    rm -f "$SANDBOX/.zyz-worker/current-task"
    if [ -z "$(sg 'zyz-worker:review-agent' "$BADP")" ]; then
        pass "T7 no pointer -> guard no-op"
    else
        fail "T7 no pointer -> guard no-op"
    fi
    echo "t1" > "$SANDBOX/.zyz-worker/current-task"
    out="$(printf 'not json' | bash "$G"; echo "rc=$?")"
    if [ "$out" = "rc=0" ]; then pass "T7 malformed input -> fail open"; else fail "T7 malformed input -> fail open" "$out"; fi

    rm -rf "$SANDBOX"
else
    skip "T3-T7 smoke tests" "no jq/python3"
fi

# ---------------------------------------------------------------------------
# T6 — doc wiring + version consistency
# ---------------------------------------------------------------------------
if grep -q '## Watchdog Enforcement' skills/execute-task/SKILL.md 2>/dev/null; then
    pass "T6 SKILL.md has Watchdog Enforcement section"
else
    fail "T6 SKILL.md has Watchdog Enforcement section"
fi
if grep -q 'current-task' skills/execute-task/SKILL.md 2>/dev/null; then
    pass "T6 SKILL.md documents current-task pointer"
else
    fail "T6 SKILL.md documents current-task pointer"
fi
if grep -q 'zyz-worker watchdog' skills/execute-task/prompts/main-agent.md 2>/dev/null; then
    pass "T6 main-agent.md handles watchdog messages"
else
    fail "T6 main-agent.md handles watchdog messages"
fi
if grep -q 'stop-gate-main' hooks/README.md 2>/dev/null && grep -q 'watchdog.sh' hooks/README.md 2>/dev/null \
    && grep -q 'dispatch-scope-guard' hooks/README.md 2>/dev/null; then
    pass "T6 hooks/README.md documents scripts"
else
    fail "T6 hooks/README.md documents scripts"
fi
# Anti-degradation prompt rules (L1) and review coverage registration (L2).
if grep -qi 'never trade scope for a delivery' skills/execute-task/prompts/main-agent.md 2>/dev/null \
    && grep -qi 'never trade scope for a delivery' skills/execute-task/SKILL.md 2>/dev/null; then
    pass "T6 anti-degradation recovery rule in prompt + SKILL"
else
    fail "T6 anti-degradation recovery rule in prompt + SKILL"
fi
for f in subagents/review-agent.md agents/review-agent.md; do
    if grep -q 'Coverage Dimensions Are Registered' "$f" 2>/dev/null; then
        pass "T6 $f requires dimension registration"
    else
        fail "T6 $f requires dimension registration"
    fi
done
if grep -q '## Coverage Dimensions' skills/execute-task/templates/review-report.md 2>/dev/null; then
    pass "T6 review-report template has Coverage Dimensions"
else
    fail "T6 review-report template has Coverage Dimensions"
fi
if grep -q 'Coverage — Design Conformance' skills/execute-task/templates/task-status.md 2>/dev/null; then
    pass "T6 task-status template registers review coverage"
else
    fail "T6 task-status template registers review coverage"
fi
if grep -q 'every coverage dimension' skills/execute-task/SKILL.md 2>/dev/null; then
    pass "T6 delivery gate checks coverage dimensions"
else
    fail "T6 delivery gate checks coverage dimensions"
fi
if grep -q 'Coverage — Design Conformance' skills/execute-task/templates/final-report.md 2>/dev/null; then
    pass "T6 final report registers review coverage"
else
    fail "T6 final report registers review coverage"
fi
if grep -q 'registered every coverage dimension' skills/execute-task/SKILL.md 2>/dev/null; then
    pass "T6 per-SubTask Reviewed flag requires registration"
else
    fail "T6 per-SubTask Reviewed flag requires registration"
fi
if grep -qi 'staging is not a loophole' skills/execute-task/prompts/main-agent.md 2>/dev/null \
    && grep -q 'Outstanding Staged Installments' skills/execute-task/templates/task-status.md 2>/dev/null; then
    pass "T6 staged-installment follow-through tracked"
else
    fail "T6 staged-installment follow-through tracked"
fi
for m in .claude-plugin/plugin.json .claude-plugin/marketplace.json .codex-plugin/plugin.json; do
    if grep -Eq "\"version\"[[:space:]]*:[[:space:]]*\"$EXPECTED_VERSION_RE" "$m" 2>/dev/null; then
        pass "T6 $m at $EXPECTED_VERSION"
    else
        fail "T6 $m at $EXPECTED_VERSION"
    fi
done

# ---------------------------------------------------------------------------
echo
if [ "$SKIPPED" -gt 0 ]; then
    echo "RESULT: $PASSED/$TOTAL checks passed ($SKIPPED skipped)"
else
    echo "RESULT: $PASSED/$TOTAL checks passed"
fi
[ "$FAILED" -eq 0 ]
