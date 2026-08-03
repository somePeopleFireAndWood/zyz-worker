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
EXPECTED_VERSION="0.16.0"
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
# The monitor's `when` must be a value Claude Code can actually ARM.
# Arming compares `when` as an EXACT string against the emitted skill name
# (`a.when === "on-skill-invoke:" + s`), and a plugin-loaded skill emits the
# QUALIFIED name (`zyz-worker:execute-task`) while the same skill used in project
# mode emits the bare name (`execute-task`) — verified: ~/.claude.json skillUsage
# holds BOTH forms. So no single `on-skill-invoke:` literal covers both install
# modes, and the previously-shipped bare form armed only in project mode.
# `when: "always"` sidesteps the coupling; watchdog.sh is itself gated on the
# .zyz-worker/current-task pointer, so arming it always is equivalent in effect.
# A bare `on-skill-invoke:execute-task` is explicitly rejected here — the old
# substring grep passed for it, which is why the dead arming went unnoticed.
mon_when="$(python3 -c 'import json;print(json.load(open("monitors/monitors.json"))[0].get("when",""))' 2>/dev/null || true)"
case "$mon_when" in
    always)
        pass "T2 monitors.json when=always (arms in both plugin and project mode)" ;;
    on-skill-invoke:*:*)
        pass "T2 monitors.json when=$mon_when (qualified plugin-mode trigger)" ;;
    on-skill-invoke:*)
        fail "T2 monitors.json when=$mon_when is a BARE skill name" \
            "a plugin-loaded skill emits the qualified 'zyz-worker:<skill>' form, so this never arms under a normal plugin install; use when=always" ;;
    *)
        fail "T2 monitors.json has no armable 'when' value" "got [$mon_when]" ;;
esac
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

    # Re-stamp .start/.heartbeat WITH CONTENT before backdating. The clean stop
    # above now DELETES this role's .start/.heartbeat (that deletion is what makes
    # a dead-role block clearable by compliance instead of only by timeout), so a
    # bare `touch` here would recreate .start EMPTY — and stop-gate-main.sh reads
    # the role type from its first line, so the block detail would lose the role
    # name and the running-background-subagent skip could never match it.
    rm -f "$T/runtime/agents/a1.done" "$T/runtime/nag/stopgate.last"
    mkdir -p "$T/runtime/agents"
    printf '%s zyz-worker:implementation-agent\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$T/runtime/agents/a1.start"
    printf '%s zyz-worker:implementation-agent\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$T/runtime/agents/a1.heartbeat"
    backdate 20 "$T/runtime/agents/a1.start" "$T/runtime/agents/a1.heartbeat" "$T/status.md"
    out="$(echo '{"cwd":"'"$SANDBOX"'","stop_hook_active":false,"background_tasks":[]}' | bash "$H/stop-gate-main.sh")"
    if printf '%s' "$out" | grep -q '"decision":"block"' && printf '%s' "$out" | grep -q 'a1'; then
        pass "T5 dead role -> main stop blocked, role named"
    else
        fail "T5 dead role -> main stop blocked, role named" "$out"
    fi
    # These two cases test the DEAD-ROLE branch only, so isolate them from the
    # status-stale branch. `backdate 20` puts status.md at exactly 1200s, and the
    # gate fires on age STRICTLY > ZYZ_STOP_STATUS_STALE_SEC (default 1200) — so
    # whether the status-stale text also appears depends on how many seconds the
    # suite has been running. That knife-edge made these assertions flaky: green
    # in isolation, red inside a longer back-to-back sweep. Pinning the status
    # threshold out of range keeps the assertion about the role branch alone.
    rm -f "$T/runtime/nag/stopgate.last"
    out="$(echo '{"cwd":"'"$SANDBOX"'","stop_hook_active":false,"background_tasks":[{"id":"1","type":"subagent","status":"running","agent_type":"zyz-worker:implementation-agent"}]}' | ZYZ_STOP_STATUS_STALE_SEC=999999 bash "$H/stop-gate-main.sh")"
    if printf '%s' "$out" | grep -q 'a1'; then
        fail "T5 running bg subagent not flagged dead" "$out"
    else
        pass "T5 running bg subagent not flagged dead"
    fi
    rm -f "$T/runtime/nag/stopgate.last"
    out="$(echo '{"cwd":"'"$SANDBOX"'","stop_hook_active":false,"background_tasks":[{"id":"1","type":"subagent","status":"running","agent_type":"implementation-agent"}]}' | ZYZ_STOP_STATUS_STALE_SEC=999999 bash "$H/stop-gate-main.sh")"
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
        # The prompt MUST be JSON-escaped. Raw interpolation of a prompt that
        # itself contains a double quote (which the quote-skip fixtures below do,
        # deliberately) yields invalid JSON; the guard then fails open and the
        # assertion passes VACUOUSLY — green for the wrong reason. Build the
        # payload with a real JSON encoder, falling back to raw printf only if
        # python3 is unavailable.
        if command -v python3 >/dev/null 2>&1; then
            python3 -c 'import json,sys
print(json.dumps({"cwd":sys.argv[1],"tool_name":"Agent",
                  "tool_input":{"subagent_type":sys.argv[2],"prompt":sys.argv[3]}}))' \
                "$SANDBOX" "$1" "$2" | bash "$G"
        else
            printf '{"cwd":"%s","tool_name":"Agent","tool_input":{"subagent_type":"%s","prompt":"%s"}}' \
                "$SANDBOX" "$1" "$2" | bash "$G"
        fi
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
Do not run this as a blockers only review.
This must not be a critical ones only pass; cover each dimension.
Not a high-priority only review — register every dimension.
Do not make this a p0 only sweep.
Add a test asserting that a dispatch saying "limit to 3 findings" is denied.
Implement the L5 scope guard. It must deny prompts like "only the top 3 findings" and "just the overall verdict".
Write the changelog entry describing that we now forbid '一句话结论' in recovery prompts.
Document that "只要总结论" is rejected by the guard.
Fix the pagination bug: the API should return no more than 3 items per page.
The retry budget must cap it at 3 attempts.
Update the docs: the CLI flag `--top 5 issues` is fine to keep.
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
# T10  Pointer resolution across a split base (issue #5).
#
# Every pre-existing fixture writes the pointer into the SAME directory it then
# passes as `cwd`, so the case that actually broke — pointer in tree A, hook cwd
# in tree B — had no coverage at all, and the missing-pointer no-op was pinned as
# if it were the only possible outcome. Real consequence: a task run inside a
# git-worktree-created worktree left every layer inert (no runtime/, two dead
# subagents unreported, idle gate open) while looking healthy.
#
# Guarded here: (a) resolution from the main checkout reaches a pointer held in a
# sibling worktree; (b) the newest live task wins, NOT the alphabetically first
# (git worktree list is path-ordered, so first-hit-wins picks by accident);
# (c) a task whose status.md phase is `done` is skipped, because pointers are
# never deleted and stale ones accumulate; (d) when nothing resolves the result
# is still empty with rc 0 — fail-open is preserved, not traded away.
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
    t10_root="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t10.XXXXXX")"
    (
        cd "$t10_root" || exit 1
        git init -q -b main main >/dev/null 2>&1
        cd main || exit 1
        git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init >/dev/null 2>&1
        git worktree add -q ../wtA -b tA >/dev/null 2>&1
        git worktree add -q ../wtB -b tB >/dev/null 2>&1
    ) >/dev/null 2>&1
    t10_mk() { # $1 worktree, $2 task-id, $3 phase, $4 mtime-stamp
        mkdir -p "$t10_root/$1/.zyz-worker/tasks/$2"
        printf '%s\n' "$2" > "$t10_root/$1/.zyz-worker/current-task"
        printf -- '## Metadata\n\n- Current Phase: %s\n' "$3" > "$t10_root/$1/.zyz-worker/tasks/$2/status.md"
        [ -n "${4:-}" ] && touch -t "$4" "$t10_root/$1/.zyz-worker/tasks/$2/status.md"
    }
    t10_resolve() { ( . hooks/scripts/lib.sh 2>/dev/null || exit 0; zyz_task_root "$t10_root/main" ); }

    if [ -d "$t10_root/wtB" ]; then
        t10_mk wtB live implementation ""
        t10_out="$(t10_resolve)"
        case "$t10_out" in
            */wtB/.zyz-worker/tasks/live) pass "T10 pointer in a sibling worktree resolves from the main checkout" ;;
            *) fail "T10 pointer in a sibling worktree resolves from the main checkout" "got [$t10_out]" ;;
        esac

        # wtA sorts BEFORE wtB but is older: newest must win.
        t10_mk wtA older implementation 202601010000
        t10_out="$(t10_resolve)"
        case "$t10_out" in
            */wtB/.zyz-worker/tasks/live) pass "T10 newest live task wins over the alphabetically-first stale one" ;;
            *) fail "T10 newest live task wins over the alphabetically-first stale one" "got [$t10_out]" ;;
        esac

        # Mark the newest done: a terminal task's leftover pointer must not win.
        printf -- '## Metadata\n\n- Current Phase: done\n' > "$t10_root/wtB/.zyz-worker/tasks/live/status.md"
        t10_out="$(t10_resolve)"
        case "$t10_out" in
            */wtA/.zyz-worker/tasks/older) pass "T10 phase=done pointer is skipped in favor of a live one" ;;
            *) fail "T10 phase=done pointer is skipped in favor of a live one" "got [$t10_out]" ;;
        esac

        # All done -> empty, rc 0 (byte-identical to the historical behavior).
        printf -- '## Metadata\n\n- Current Phase: done\n' > "$t10_root/wtA/.zyz-worker/tasks/older/status.md"
        t10_out="$(t10_resolve)"; t10_rc=$?
        if [ -z "$t10_out" ] && [ "$t10_rc" -eq 0 ]; then
            pass "T10 no live pointer anywhere -> empty result, rc 0 (fail-open preserved)"
        else
            fail "T10 no live pointer anywhere -> empty result, rc 0" "out=[$t10_out] rc=$t10_rc"
        fi
    else
        skip "T10 pointer in a sibling worktree resolves from the main checkout (worktree setup failed)"
        skip "T10 newest live task wins over the alphabetically-first stale one (worktree setup failed)"
        skip "T10 phase=done pointer is skipped in favor of a live one (worktree setup failed)"
        skip "T10 no live pointer anywhere -> empty result, rc 0 (fail-open preserved) (worktree setup failed)"
    fi
    rm -rf "$t10_root"
else
    skip "T10 pointer in a sibling worktree resolves from the main checkout (git unavailable)"
    skip "T10 newest live task wins over the alphabetically-first stale one (git unavailable)"
    skip "T10 phase=done pointer is skipped in favor of a live one (git unavailable)"
    skip "T10 no live pointer anywhere -> empty result, rc 0 (fail-open preserved) (git unavailable)"
fi

# ---------------------------------------------------------------------------
# T11  Watchdog reports being UNARMED (issue #5).
#
# The deeper defect: an inert layer and a healthy quiet one are externally
# identical, which is why a whole task ran unprotected without anyone noticing.
# The monitor must announce a resolution miss — once, not per tick.
# Also pinned: monitors.json interpolates "${CLAUDE_PROJECT_DIR}" into argv, so
# an unset variable yields an EMPTY $1. BASE must still fall through to
# CLAUDE_PROJECT_DIR. (This already held — `${1:-word}` substitutes on unset OR
# empty — so this case documents the behavior rather than guarding a fix; it
# would catch a future rewrite to `${1-word}`, which does NOT substitute on empty.)
# ---------------------------------------------------------------------------
t11_dir="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t11.XXXXXX")"
t11_out="$t11_dir/out.txt"
ZYZ_WATCHDOG_INTERVAL_SEC=1 bash monitors/watchdog.sh "$t11_dir" >"$t11_out" 2>&1 &
t11_pid=$!
sleep 3
kill "$t11_pid" 2>/dev/null || true
wait "$t11_pid" 2>/dev/null || true
t11_n="$(grep -c 'NOT ARMED' "$t11_out" 2>/dev/null || echo 0)"
if [ "$t11_n" -eq 1 ]; then
    pass "T11 unarmed watchdog reports the miss exactly once across several ticks"
else
    fail "T11 unarmed watchdog reports the miss exactly once" "saw $t11_n 'NOT ARMED' lines"
fi
t11_out2="$t11_dir/out2.txt"
CLAUDE_PROJECT_DIR="$t11_dir" ZYZ_WATCHDOG_INTERVAL_SEC=1 bash monitors/watchdog.sh "" >"$t11_out2" 2>&1 &
t11_pid2=$!
sleep 2
kill "$t11_pid2" 2>/dev/null || true
wait "$t11_pid2" 2>/dev/null || true
if grep -qF "resolved from $t11_dir" "$t11_out2" 2>/dev/null; then
    pass "T11 empty positional arg falls through to CLAUDE_PROJECT_DIR (not \$PWD)"
else
    fail "T11 empty positional arg falls through to CLAUDE_PROJECT_DIR" "$(head -c 200 "$t11_out2" 2>/dev/null)"
fi
rm -rf "$t11_dir"

# ---------------------------------------------------------------------------
# T9  Watchdog-audit regression guards. Three defects found by audit and each
# verified by execution before fixing; pinned here so they cannot return.
#
#  (a) Design phases must be QUIET. zyz_phase_active matched `*review*`, so
#      `design review` counted as an active execution phase. That made the L4
#      stop gate block the main agent from idling at §2 step 8 — the one gate the
#      workflow mandates waiting at indefinitely for human approval — while both
#      prompts promise the watchdog stays silent during design.
#  (b) A dead role's marker must be CLEARABLE by compliance. The gate reads only
#      the runtime markers, never status.md, so "mark it finished in the status
#      file" was an unsatisfiable instruction: the agent complied and the gate
#      re-blocked until a timeout. The reason string must name the marker path.
#  (c) The min-final-length check must be locale-independent. `${#var}` counts
#      characters under UTF-8 but bytes under LC_ALL=C, so a COMPLETE 45-char
#      Chinese report scored 45 against a threshold of 80 and was blocked, even
#      though the workflow explicitly supports Chinese output.
# ---------------------------------------------------------------------------
t9_phase="$(
    . hooks/scripts/lib.sh 2>/dev/null || exit 0
    for p in design designreview design-review implementation testing review delivery awaiting-confirmation done; do
        if zyz_phase_active "$p"; then printf 'A:%s ' "$p"; else printf 'q:%s ' "$p"; fi
    done
)"
t9_want='q:design q:designreview q:design-review A:implementation A:testing A:review A:delivery q:awaiting-confirmation q:done '
if [ "$t9_phase" = "$t9_want" ]; then
    pass "T9(a) design phases are quiet; only implementation/testing/review/delivery are active"
else
    fail "T9(a) zyz_phase_active classification changed" "got [$t9_phase]"
fi

if grep -q 'runtime/agents' hooks/scripts/stop-gate-main.sh 2>/dev/null \
    && grep -q 'rm -f' hooks/scripts/stop-gate-main.sh 2>/dev/null; then
    pass "T9(b) dead-role block reason names the marker path the agent must clear"
else
    fail "T9(b) dead-role block reason must name a clearing action" \
        "this gate reads only runtime markers, so a status-file-only instruction cannot be satisfied"
fi
if grep -q 'rm -f' hooks/scripts/stop-gate-subagent.sh 2>/dev/null; then
    pass "T9(b) clean SubagentStop clears .start/.heartbeat instead of only adding .done"
else
    fail "T9(b) clean SubagentStop must clear .start/.heartbeat" "otherwise runtime/ grows one triple per dispatch"
fi

# (d) No double-nag. status-freshness.sh and post-agent-flush.sh are both sync
#     PostToolUse hooks reading the same status-file mtime, with independent
#     cooldowns — so on a stale-status Agent return they both injected the same
#     "persist the status file" instruction into one turn. status-freshness now
#     defers on tool_name=Agent (post-agent-flush owns that moment: more
#     specific message, tighter threshold), and still fires for every other tool.
t9_dn="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t9dn.XXXXXX")"
mkdir -p "$t9_dn/.zyz-worker/tasks/t1"
printf 't1\n' > "$t9_dn/.zyz-worker/current-task"
printf '# Task Status\n\n- Current Phase: implementation\n' > "$t9_dn/.zyz-worker/tasks/t1/status.md"
backdate 60 "$t9_dn/.zyz-worker/tasks/t1/status.md"
t9_dn_run() { # $1 tool_name, $2 script
    rm -rf "$t9_dn/.zyz-worker/tasks/t1/runtime/nag"
    printf '{"cwd":"%s","tool_name":"%s","tool_response":{"status":"completed"}}' "$t9_dn" "$1" \
        | hooks/scripts/"$2" 2>/dev/null
}
t9_dn_agent_fresh="$(t9_dn_run Agent status-freshness.sh)"
t9_dn_agent_flush="$(t9_dn_run Agent post-agent-flush.sh)"
t9_dn_bash_fresh="$(t9_dn_run Bash status-freshness.sh)"
if [ -z "$t9_dn_agent_fresh" ] && [ -n "$t9_dn_agent_flush" ] && [ -n "$t9_dn_bash_fresh" ]; then
    pass "T9(d) exactly one L1 nag per tool call (post-agent-flush on Agent, status-freshness elsewhere)"
else
    fail "T9(d) L1 double-nag or lost nag" \
        "agent/freshness=[${t9_dn_agent_fresh:+NAG}] agent/flush=[${t9_dn_agent_flush:+NAG}] bash/freshness=[${t9_dn_bash_fresh:+NAG}]"
fi
rm -rf "$t9_dn"

t9_cjk='实现已完成：修改了三个文件，新增两个测试用例，全部通过。存在一个已记录的风险点待评审确认。'
t9_sandbox="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t9.XXXXXX")"
mkdir -p "$t9_sandbox/.zyz-worker/tasks/t1/runtime/agents"
printf 't1\n' > "$t9_sandbox/.zyz-worker/current-task"
printf '# Task Status\n\n- Current Phase: implementation\n' > "$t9_sandbox/.zyz-worker/tasks/t1/status.md"
t9_check() {
    printf 'y\n' > "$t9_sandbox/.zyz-worker/tasks/t1/runtime/agents/k.start"
    LC_ALL="$1" printf '{"cwd":"%s","agent_id":"k","agent_type":"review-agent","last_assistant_message":"%s","stop_hook_active":false}' \
        "$t9_sandbox" "$2" | LC_ALL="$1" hooks/scripts/stop-gate-subagent.sh 2>/dev/null
    rm -f "$t9_sandbox/.zyz-worker/tasks/t1/runtime/agents/k".* 2>/dev/null || true
}
t9_utf8="$(t9_check en_US.UTF-8 "$t9_cjk")"
t9_c="$(t9_check C "$t9_cjk")"
t9_short="$(t9_check en_US.UTF-8 '好了')"
if [ -z "$t9_utf8" ] && [ -z "$t9_c" ] && [ -n "$t9_short" ]; then
    pass "T9(c) complete CJK report passes in both locales; a 2-char reply still blocks"
else
    fail "T9(c) min-final-length check is locale-dependent or mis-thresholded" \
        "utf8-block=[${t9_utf8:0:40}] c-block=[${t9_c:0:40}] short-blocked=[${t9_short:+yes}]"
fi
rm -rf "$t9_sandbox"

# ---------------------------------------------------------------------------
# T8  zyz_get extraction shapes.
#
# zyz_get is the single field-extraction path every hook depends on, with two
# interchangeable backends (jq, python3). Pin the shapes the hooks actually rely
# on so a future change to either backend cannot silently alter what gets
# extracted: a plain string, a nested path, an absent key (must be empty), and
# the boolean the stop gates compare against the literal "true".
# ---------------------------------------------------------------------------
t8_out="$(
    . hooks/scripts/lib.sh 2>/dev/null || exit 0
    ZYZ_HOOK_INPUT='{"cwd":"/tmp/x","agent_id":"a1","stop_hook_active":true,"tool_input":{"prompt":"hi"}}'
    printf 'cwd=%s|id=%s|nested=%s|absent=%s|bool=%s' \
        "$(zyz_get cwd)" "$(zyz_get agent_id)" "$(zyz_get tool_input.prompt)" \
        "$(zyz_get nope)" "$(zyz_get stop_hook_active)"
)"
if [ "$t8_out" = 'cwd=/tmp/x|id=a1|nested=hi|absent=|bool=true' ]; then
    pass "T8 zyz_get extracts string / nested / absent / boolean shapes correctly"
else
    fail "T8 zyz_get extraction shapes changed" "got [$t8_out]"
fi

# ---------------------------------------------------------------------------
echo
if [ "$SKIPPED" -gt 0 ]; then
    echo "RESULT: $PASSED/$TOTAL checks passed ($SKIPPED skipped)"
else
    echo "RESULT: $PASSED/$TOTAL checks passed"
fi
[ "$FAILED" -eq 0 ]
