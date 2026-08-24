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
#
# Observation boundary for the issue #7--#10 checks below: this suite can
# distinguish the public CLI/hook/monitor results and every persisted runtime
# artifact, and can exercise documented test-only fault barriers.  It cannot
# prove kernel process-birth identity, mount-id, bind-mount, raw-byte pathname,
# RLIMIT/RSS, or atomic-no-replace behavior on a host that does not expose the
# corresponding capability.  Those cases must SKIP with the capability named;
# do not read green fallback fixtures as proof of the unavailable kernel path.
# Cross-host Claude/Codex queue consumption and forced-interrupt semantics also
# require their real host-contract acceptance layer; static prompt checks only
# prove that the explicit probe protocol was documented.

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
EXPECTED_VERSION="0.17.0"
EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/\./\\./g')"

pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); echo "PASS  $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); echo "FAIL  $1${2:+ — $2}"; }
skip() { TOTAL=$((TOTAL+1)); SKIPPED=$((SKIPPED+1)); echo "SKIP  $1${2:+ — $2}"; }

json_tool() {
    command -v jq >/dev/null 2>&1 && return 0
    command -v python3 >/dev/null 2>&1 && return 0
    return 1
}

fixed_observer_genesis_unavailable() { # rc json task-dir include-no-output
    [ "$1" -eq 4 ] || return 1
    printf '%s' "$2" | python3 -c 'import json,sys
try:x=json.load(sys.stdin)
except Exception:raise SystemExit(1)
err=x.get("error");expected=["hook-observe",sys.argv[1],sys.argv[2]]
ok=(x.get("schema_version")==1 and x.get("command")=="hook-observe" and
 x.get("ok") is False and x.get("state")=="error" and x.get("argv")==expected and
 isinstance(err,dict) and set(err)=={"code","message","retryable"} and
 err.get("code")=="genesis-capability-unavailable" and err.get("retryable") is True and
 isinstance(err.get("message"),str) and bool(err["message"]))
raise SystemExit(0 if ok else 1)' "$3" "$4"
}

# ---------------------------------------------------------------------------
# T1 — layout, exec bits, syntax
# ---------------------------------------------------------------------------
HOOK_SCRIPTS="hooks/scripts/lib.sh hooks/scripts/heartbeat.sh hooks/scripts/subagent-track.sh hooks/scripts/status-freshness.sh hooks/scripts/post-agent-flush.sh hooks/scripts/stop-gate-subagent.sh hooks/scripts/stop-gate-main.sh hooks/scripts/dispatch-scope-guard.sh hooks/scripts/checkout-guard.sh hooks/scripts/start-watchdog.sh hooks/scripts/agent-runtime-state.sh"
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
for ev in PreToolUse PostToolUse SubagentStart SubagentStop Stop SessionStart; do
    if grep -q "\"$ev\"" hooks/hooks.json 2>/dev/null; then
        pass "T2 hooks.json registers $ev"
    else
        fail "T2 hooks.json registers $ev"
    fi
done
if grep -q 'CODEX_PLUGIN_ROOT' hooks/hooks.json 2>/dev/null \
    && grep -q 'ZYZ_PLUGIN_ROOT' hooks/hooks.json 2>/dev/null \
    && grep -q 'CLAUDE_PLUGIN_ROOT' hooks/hooks.json 2>/dev/null; then
    pass "T2 hooks.json resolves Codex/orchestrated/Claude plugin roots"
else
    fail "T2 hooks.json resolves Codex/orchestrated/Claude plugin roots"
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
    mkdir -p "$T/runtime"
    echo "t1" > "$SANDBOX/.zyz-worker/current-task"
    printf -- '## Metadata\n\n- Current Phase: implementation\n' > "$T/status.md"
    H="$REPO_ROOT/hooks/scripts"
    start_fixture_agent() { # $1 raw id, $2 role
        printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"%s","agent_type":"%s"}' \
            "$SANDBOX" "$1" "$2" | bash "$H/subagent-track.sh" 2>/dev/null
    }
    fixture_agent_key() { # $1 raw id; deterministic address, not storage oracle
        python3 -c 'import hashlib,re,sys;s=sys.argv[1];p=re.sub(r"[^A-Za-z0-9._-]","_",s)[:32] or "agent";print(p+"."+hashlib.sha256(s.encode()).hexdigest())' "$1"
    }

    # T3 heartbeat + tracking
    echo '{"cwd":"'"$SANDBOX"'","tool_name":"Bash"}' | bash "$H/heartbeat.sh"
    t3_main_observation="$(bash "$H/agent-runtime-state.sh" hook-observe "$T" false 2>/dev/null)"; t3_main_observation_rc=$?
    if fixed_observer_genesis_unavailable "$t3_main_observation_rc" "$t3_main_observation" "$T" false; then
        skip "T3 main heartbeat fixed observer requires supported durable GENESIS capability" "$t3_main_observation"
    elif [ "$t3_main_observation_rc" -eq 0 ] && printf '%s' "$t3_main_observation" | python3 -c 'import json,sys;x=json.load(sys.stdin);raise SystemExit(0 if x.get("ok") is True and x.get("state")=="observed" and type(x.get("main_heartbeat_epoch")) is int else 1)'; then
        pass "T3 main heartbeat hook commits fixed observer state"
    else
        fail "T3 main heartbeat hook commits fixed observer state" "rc=$t3_main_observation_rc out=$t3_main_observation"
    fi
    start_fixture_agent a1 zyz-worker:implementation-agent
    A1_KEY="$(fixture_agent_key a1)"
    if [ -n "$A1_KEY" ]; then pass "T3 full-hash instance address derived"; else fail "T3 full-hash instance address derived"; fi
    echo '{"cwd":"'"$SANDBOX"'","agent_id":"a1","agent_type":"zyz-worker:implementation-agent"}' | bash "$H/heartbeat.sh"
    if [ -z "$(printf '{"cwd":"%s","agent_id":"a1"}' "$SANDBOX" | bash "$H/heartbeat.sh" 2>/dev/null)" ]; then pass "T3 identity-validated subagent heartbeat is fail-open"; else fail "T3 identity-validated subagent heartbeat is fail-open"; fi
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
    if [ -n "$A1_KEY" ]; then pass "T5 blocked stop retains addressed instance"; else fail "T5 blocked stop retains addressed instance"; fi
    rm -f "$SANDBOX/.zyz-worker/current-task"
    out="$(echo '{"cwd":"'"$SANDBOX"'","agent_id":"a1","agent_type":"zyz-worker:implementation-agent","stop_hook_active":false,"last_assistant_message":"done"}' | bash "$H/stop-gate-subagent.sh")"
    if [ -z "$out" ]; then pass "T5 L2 no pointer -> no gate"; else fail "T5 L2 no pointer -> no gate" "$out"; fi
    echo "t1" > "$SANDBOX/.zyz-worker/current-task"
    LONGMSG="Completed implementation: files a.go b.go c.go changed; tests pass; no blockers; next step review. All acceptance criteria satisfied."
    out="$(echo '{"cwd":"'"$SANDBOX"'","agent_id":"a1","agent_type":"zyz-worker:implementation-agent","stop_hook_active":false,"last_assistant_message":"'"$LONGMSG"'"}' | bash "$H/stop-gate-subagent.sh")"
    if [ -z "$out" ]; then pass "T5 long final msg -> clean terminal transition"; else fail "T5 long final msg -> clean terminal transition" "$out"; fi

    # Fixed-pack stale-role/bg-role/finalize storage is exercised with raw
    # pack/CELL/terminal oracles in T34/T43. This early smoke layer retains only
    # hook decision behavior and never ages or fabricates logical records.
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
# The monitor is armed `when: always`, so it runs in EVERY session — including
# the vast majority that never touch execute-task. The unarmed report must
# therefore fire only when a task plausibly EXISTS but its pointer cannot be
# found; a bare miss in an ordinary repo is a false alarm, and a warning that
# cries wolf in normal use trains people to ignore the one that matters.
# (Observed for real: this monitor warned "dead subagents will NOT be reported"
# in a session that was not running a task at all.)
t11_run() { # $1 dir -> prints the NOT ARMED count
    ZYZ_WATCHDOG_INTERVAL_SEC=1 bash monitors/watchdog.sh "$1" >"$1/out.txt" 2>&1 &
    local p=$!
    sleep 3
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
    # NOT `grep -c ... || echo 0`: grep -c PRINTS 0 and ALSO exits 1 on no match,
    # so the fallback appends a second 0 and the caller's integer comparison dies
    # on "0\n0". Count with grep -c alone and normalize a non-numeric result.
    local n
    n="$(grep -c 'NOT ARMED' "$1/out.txt" 2>/dev/null)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}
t11_base="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t11.XXXXXX")"

# (i) live task dir, pointer missing -> the real issue-#5 bug, must report ONCE.
mkdir -p "$t11_base/live/.zyz-worker/tasks/t"
printf -- '## Metadata\n\n- Current Phase: implementation\n' > "$t11_base/live/.zyz-worker/tasks/t/status.md"
t11_n="$(t11_run "$t11_base/live")"
if [ "$t11_n" -eq 1 ]; then
    pass "T11 unarmed watchdog reports the miss exactly once across several ticks"
else
    fail "T11 unarmed watchdog reports the miss exactly once" "saw $t11_n 'NOT ARMED' lines"
fi

# (ii) no .zyz-worker at all -> ordinary session, must stay SILENT.
mkdir -p "$t11_base/plain"
t11_n="$(t11_run "$t11_base/plain")"
if [ "$t11_n" -eq 0 ]; then
    pass "T11 no unarmed report in a repo that never used the workflow (no false alarm)"
else
    fail "T11 no unarmed report in a repo that never used the workflow" "saw $t11_n 'NOT ARMED' lines"
fi

# (iii) task dirs present but all finished -> must stay SILENT (completed tasks
#       leave their directories behind forever, so their presence is not evidence).
mkdir -p "$t11_base/finished/.zyz-worker/tasks/old"
printf -- '## Metadata\n\n- Current Phase: done\n' > "$t11_base/finished/.zyz-worker/tasks/old/status.md"
t11_n="$(t11_run "$t11_base/finished")"
if [ "$t11_n" -eq 0 ]; then
    pass "T11 no unarmed report when every task dir is already done (no false alarm)"
else
    fail "T11 no unarmed report when every task dir is already done" "saw $t11_n 'NOT ARMED' lines"
fi
# Point CLAUDE_PROJECT_DIR at the `live` fixture, not the bare base: the report
# now requires a plausibly-active task (see the suspicion gate above), so a base
# with no task dirs would print nothing and the assertion would pass/fail for the
# wrong reason. The claim under test is only "an empty $1 falls through to
# CLAUDE_PROJECT_DIR", and the message naming that path is the evidence.
t11_dir="$t11_base/live"
t11_out="$t11_base/live/out.txt"
t11_out2="$t11_base/out2.txt"
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
#  (b) A dead role must be CLEARABLE by the supported runtime protocol. The gate
#      reads runtime state, never status.md, so "mark it finished in status" was
#      unsatisfiable. Direct marker deletion/fabrication is now forbidden too:
#      API-error death must instruct the main agent to probe/investigate/finalize.
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

if grep -q 'agent-runtime-state.sh finalize' hooks/scripts/stop-gate-main.sh 2>/dev/null \
    && grep -qi 'probe' hooks/scripts/stop-gate-main.sh 2>/dev/null \
    && grep -qi 'Never delete or fabricate runtime markers by hand' hooks/scripts/stop-gate-main.sh 2>/dev/null; then
    pass "T9(b) dead-role block reason names supported probe/finalize recovery and forbids marker forgery"
else
    fail "T9(b) dead-role block reason must name supported recovery" \
        "require probe/investigation/finalize; never instruct manual runtime deletion"
fi
t9_stop="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t9stop.XXXXXX")"
t9_stop_task="$t9_stop/.zyz-worker/tasks/t1"
mkdir -p "$t9_stop_task/runtime"
printf 't1\n' > "$t9_stop/.zyz-worker/current-task"
printf '# Task Status\n\n- Current Phase: implementation\n' > "$t9_stop_task/status.md"
printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"clean-stop","agent_type":"review-agent"}' "$t9_stop" \
    | hooks/scripts/subagent-track.sh 2>/dev/null
printf '{"cwd":"%s","hook_event_name":"PreToolUse","agent_id":"clean-stop","agent_type":"review-agent","tool_call_id":"call-1","tool_name":"Bash"}' "$t9_stop" \
    | hooks/scripts/heartbeat.sh 2>/dev/null
t9_stop_before="$(bash hooks/scripts/agent-runtime-state.sh hook-observe "$t9_stop_task" false 2>/dev/null)"; t9_stop_before_rc=$?
if fixed_observer_genesis_unavailable "$t9_stop_before_rc" "$t9_stop_before" "$t9_stop_task" false; then
    skip "T9(b) public clean-stop pre-observation requires supported durable GENESIS capability" "$t9_stop_before"
    skip "T9(b) clean SubagentStop terminal query requires supported durable GENESIS capability" "$t9_stop_before"
else
    if [ "$t9_stop_before_rc" -eq 0 ] && printf '%s' "$t9_stop_before" | python3 -c 'import json,sys;x=json.load(sys.stdin);rows=x.get("instances",[]);i=rows[0] if len(rows)==1 else {};ok=(x.get("ok") is True and x.get("state")=="observed" and len(rows)==1 and i.get("role")=="review-agent" and i.get("tracking_capability")=="armed" and i.get("terminal") is False and type(i.get("heartbeat_epoch")) is int and i.get("inflight_count")==1);raise SystemExit(0 if ok else 1)'; then
        pass "T9(b) public clean-stop fixture observes one armed heartbeat and INFLIGHT entry"
    else
        fail "T9(b) public clean-stop fixture observes one armed heartbeat and INFLIGHT entry" "rc=$t9_stop_before_rc out=$t9_stop_before"
    fi
    t9_stop_long='Completed review work with exact files, test coverage, mutation expectations, remaining risks, blockers, and the next implementation handoff fully recorded.'
    t9_stop_hook="$(printf '{"cwd":"%s","agent_id":"clean-stop","agent_type":"review-agent","stop_hook_active":false,"last_assistant_message":"%s"}' "$t9_stop" "$t9_stop_long" | hooks/scripts/stop-gate-subagent.sh 2>/dev/null)"
    t9_stop_after="$(bash hooks/scripts/agent-runtime-state.sh probe-status "$t9_stop_task" clean-stop 2>"$t9_stop/probe-status.err")"; t9_stop_after_rc=$?
    if [ -z "$t9_stop_hook" ] && [ "$t9_stop_after_rc" -eq 0 ] && [ ! -s "$t9_stop/probe-status.err" ] \
        && printf '%s' "$t9_stop_after" | python3 -c 'import json,sys;x=json.load(sys.stdin);ok=(x.get("ok") is True and x.get("state")=="terminal" and x.get("error") is None and x.get("trusted") is True and x.get("tracking_capability")=="armed" and x.get("terminal_kind")=="done" and type(x.get("terminal_epoch")) is int);raise SystemExit(0 if ok else 1)'; then
        pass "T9(b) clean SubagentStop is terminal done through the retained public authority"
    else
        fail "T9(b) clean SubagentStop is terminal done through the retained public authority" "hook=[$t9_stop_hook] query_rc=$t9_stop_after_rc query=[$t9_stop_after] stderr=$(tr '\n' ' ' < "$t9_stop/probe-status.err")"
    fi
fi
rm -rf "$t9_stop"

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
    t9_id="$3"
    printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"%s","agent_type":"review-agent"}' \
        "$t9_sandbox" "$t9_id" | hooks/scripts/subagent-track.sh 2>/dev/null
    LC_ALL="$1" printf '{"cwd":"%s","agent_id":"%s","agent_type":"review-agent","last_assistant_message":"%s","stop_hook_active":false}' \
        "$t9_sandbox" "$t9_id" "$2" | LC_ALL="$1" hooks/scripts/stop-gate-subagent.sh 2>/dev/null
}
t9_utf8="$(t9_check en_US.UTF-8 "$t9_cjk" locale-utf8)"
t9_c="$(t9_check C "$t9_cjk" locale-c)"
t9_short="$(t9_check en_US.UTF-8 '好了' locale-short)"
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
# T12  L6 checkout guard (issue #6).
#
# Real accident: on a SHARED worktree, an audit agent reverted its throwaway
# mutation with `git checkout <file>` — which resets to HEAD — and deleted
# another agent's UNCOMMITTED work in that file. Never-committed content is in
# no git recovery mechanism, and the build stayed green. The guard denies
# checkout/restore of a file with uncommitted modifications and the
# state-moving git stash forms, while leaving ordinary git usage alone.
# ---------------------------------------------------------------------------
if json_tool && command -v git >/dev/null 2>&1; then
    t12="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t12.XXXXXX")"
    (
        cd "$t12" || exit 1
        git init -q -b main . >/dev/null 2>&1
        mkdir -p .zyz-worker/tasks/t1
        printf 't1\n' > .zyz-worker/current-task
        printf -- '## Metadata\n\n- Current Phase: implementation\n' > .zyz-worker/tasks/t1/status.md
        printf 'v1\n' > f.go; printf 'v1\n' > clean.go
        git add . >/dev/null 2>&1
        git -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
        printf 'UNCOMMITTED\n' >> f.go
    ) >/dev/null 2>&1
    t12_sg() { # $1 command -> stdout of the guard
        python3 -c 'import json,sys
print(json.dumps({"cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$t12" "$1" \
            | bash "$REPO_ROOT/hooks/scripts/checkout-guard.sh" 2>/dev/null
    }
    t12_deny() {
        if printf '%s' "$(t12_sg "$1")" | grep -q '"deny"'; then pass "T12 denies: $1"; else fail "T12 denies: $1"; fi
    }
    t12_allow() {
        if [ -z "$(t12_sg "$1")" ]; then pass "T12 allows: $1"; else fail "T12 allows: $1" "$(t12_sg "$1" | head -c 120)"; fi
    }
    # The accident's exact shape, and its close variants:
    t12_deny 'git checkout f.go'
    t12_deny 'git checkout -- f.go'
    t12_deny 'git restore f.go'
    t12_deny 'git checkout .'
    t12_deny 'git stash'
    t12_deny 'git stash pop'
    # Ordinary git usage must be untouched:
    t12_allow 'git checkout clean.go'
    t12_allow 'git checkout -b feature/x'
    t12_allow 'git checkout main'
    t12_allow 'git stash list'
    t12_allow 'git show HEAD:f.go'
    t12_allow 'git status'
    # Compound command: words after a metacharacter are not checkout targets.
    t12_allow 'git checkout clean.go && echo f.go'
    # No task pointer -> guard does not apply (general sessions keep git freedom).
    rm -f "$t12/.zyz-worker/current-task"
    if [ -z "$(t12_sg 'git checkout f.go')" ]; then
        pass "T12 no pointer -> guard no-op (general git freedom preserved)"
    else
        fail "T12 no pointer -> guard no-op"
    fi
    printf 't1\n' > "$t12/.zyz-worker/current-task"
    # Per-guard disable switch.
    t12_out="$(python3 -c 'import json,sys
print(json.dumps({"cwd":sys.argv[1],"tool_input":{"command":"git checkout f.go"}}))' "$t12" \
        | ZYZ_CHECKOUT_GUARD_DISABLE=1 bash "$REPO_ROOT/hooks/scripts/checkout-guard.sh" 2>/dev/null)"
    if [ -z "$t12_out" ]; then
        pass "T12 ZYZ_CHECKOUT_GUARD_DISABLE=1 -> no-op"
    else
        fail "T12 ZYZ_CHECKOUT_GUARD_DISABLE=1 -> no-op"
    fi
    # Fail open on malformed input.
    t12_rc=0; printf 'not-json' | bash "$REPO_ROOT/hooks/scripts/checkout-guard.sh" >/dev/null 2>&1 || t12_rc=$?
    if [ "$t12_rc" -eq 0 ]; then
        pass "T12 malformed input -> fail open (rc 0)"
    else
        fail "T12 malformed input -> fail open" "rc=$t12_rc"
    fi
    rm -rf "$t12"
else
    for l in "denies: git checkout f.go" "denies: git checkout -- f.go" "denies: git restore f.go" \
             "denies: git checkout ." "denies: git stash" "denies: git stash pop" \
             "allows: git checkout clean.go" "allows: git checkout -b feature/x" "allows: git checkout main" \
             "allows: git stash list" "allows: git show HEAD:f.go" "allows: git status" \
             "allows: git checkout clean.go && echo f.go" \
             "no pointer -> guard no-op (general git freedom preserved)" \
             "ZYZ_CHECKOUT_GUARD_DISABLE=1 -> no-op" "malformed input -> fail open (rc 0)"; do
        skip "T12 $l (jq/python3 or git unavailable)"
    done
fi

# ---------------------------------------------------------------------------
# T13  Issue #10: strict, bounded, multi-lane Waiting On grammar.
#
# The oracle is deliberately literal and does not source the production parser.
# A malformed line in either lane invalidates the whole set.  This guards both
# directions: valid waits hide main status-stale, while every invalid/expired
# form below must NOT hide it.
# ---------------------------------------------------------------------------
if json_tool; then
    t13="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t13.XXXXXX")"
    t13_task="$t13/.zyz-worker/tasks/wait"
    mkdir -p "$t13_task/runtime/nag"
    printf 'wait\n' > "$t13/.zyz-worker/current-task"
    t13_now="$(date +%s)"
    t13_since=$((t13_now - 10)); t13_next=$((t13_now + 300))
    t13_write() { # remaining args are literal Agent State body lines
        {
            # Active phase is an explicit non-vacuity precondition: every L1/L3/L4
            # consumer exits before parsing Waiting On in a quiet design phase.
            # First real interception: the original fixture omitted this line,
            # making valid-wait silence vacuous and every expected nag unreachable.
            printf '# Task Status\n\n## Metadata\n\n- Current Phase: implementation\n\n## Agent State\n\n'
            printf '%s\n' "$@"
            printf '\n## Progress\n\n- unchanged\n'
        } > "$t13_task/status.md"
        backdate 30 "$t13_task/status.md"
        rm -rf "$t13_task/runtime/nag"
    }
    t13_nag() {
        printf '{"cwd":"%s","tool_name":"Bash"}' "$t13" \
            | bash hooks/scripts/status-freshness.sh 2>/dev/null
    }
    t13_expect_quiet() {
        if [ -z "$(t13_nag)" ]; then pass "T13 $1"; else fail "T13 $1" "valid wait did not suppress main freshness"; fi
    }
    t13_expect_nag() {
        if printf '%s' "$(t13_nag)" | grep -q 'additionalContext'; then pass "T13 $1"; else fail "T13 $1" "invalid wait hid stale status"; fi
    }

    t13_write \
        "- implementation-agent: running" \
        "- Waiting On: instance-key=impl.a1; since-epoch=$t13_since; next-check-epoch=$t13_next; reason=running a long tool" \
        "- Waiting On: instance-key=test.a2; since-epoch=$t13_since; next-check-epoch=$t13_next; reason=tests are still being authored"
    t13_expect_quiet "two valid lanes suppress main status-stale"

    t13_write "- implementation-agent: running"
    t13_expect_nag "zero candidates do not suppress"
    # Degradation guard: if the active-phase seed disappears, this baseline nag
    # is empty and turns red before any quiet assertion can be credited.
    if [ "$(. hooks/scripts/lib.sh 2>/dev/null; zyz_phase_of "$t13_task/status.md")" = implementation ]; then pass "T13 fixture is in an active implementation phase"; else fail "T13 fixture is in an active implementation phase" "restore Metadata/Current Phase before trusting Waiting On checks"; fi
    # Keep the real-clock integration case, but do not ask it to discriminate
    # equality: by hook execution time fixture-now is normally already past.
    t13_write "- Waiting On: instance-key=a; since-epoch=$t13_since; next-check-epoch=$t13_now; reason=real clock expired"
    t13_expect_nag "real-clock deadline at captured now is expired by hook observation"

    # Exact boundary seam: source the real shared parser, then override only its
    # clock function inside this test subshell. First real interception: changing
    # `now >= next` to `now > next` survived the old wall-clock case because a
    # later hook saw next strictly in the past. The adjacent +1 case proves the
    # controlled clock/parser path is live rather than always-invalid.
    t13_waiting_at() { # $1 fixed parser-observed now
        t13_fixed_now="$1"
        (
            . hooks/scripts/lib.sh 2>/dev/null || exit 2
            zyz_now() { printf '%s' "$t13_fixed_now"; }
            zyz_status_waiting "$t13_task/status.md"
        )
    }
    t13_fixed=2000000000
    t13_write "- Waiting On: instance-key=exact; since-epoch=1999999990; next-check-epoch=$t13_fixed; reason=exact equality"
    if t13_waiting_at "$t13_fixed"; then fail "T13 exact next-check == parser-observed now is expired" "equality was accepted"; else pass "T13 exact next-check == parser-observed now is expired"; fi
    t13_write "- Waiting On: instance-key=exact; since-epoch=1999999990; next-check-epoch=2000000001; reason=strictly future"
    if t13_waiting_at "$t13_fixed"; then pass "T13 exact next-check == now+1 remains valid"; else fail "T13 exact next-check == now+1 remains valid" "controlled-clock parser path is not live"; fi

    # Canonical-representation seam. Use a 9-digit clock so adding one leading
    # zero remains within the independent 10-byte ceiling; every invalid value
    # below is numerically in-domain, within horizon, and correctly ordered.
    # Thus widening the grammar to `[+-]?[0-9]+` cannot be rescued by another
    # range/length failure. Cover both authoritative epoch fields separately.
    t13_grammar_now=200000000
    t13_write "- Waiting On: instance-key=canonical; since-epoch=200000000; next-check-epoch=200000001; reason=canonical control"
    if t13_waiting_at "$t13_grammar_now"; then pass "T13 canonical fixed-clock epochs remain valid"; else fail "T13 canonical fixed-clock epochs remain valid" "representation seam/parser path is not live"; fi
    t13_write "- Waiting On: instance-key=bad-since-zero; since-epoch=0199999990; next-check-epoch=200000001; reason=leading zero since"
    if t13_waiting_at "$t13_grammar_now"; then fail "T13 otherwise-valid since with leading zero is rejected" "noncanonical since accepted"; else pass "T13 otherwise-valid since with leading zero is rejected"; fi
    t13_write "- Waiting On: instance-key=bad-since-plus; since-epoch=+200000000; next-check-epoch=200000001; reason=positive sign since"
    if t13_waiting_at "$t13_grammar_now"; then fail "T13 otherwise-valid since with plus sign is rejected" "noncanonical since accepted"; else pass "T13 otherwise-valid since with plus sign is rejected"; fi
    t13_write "- Waiting On: instance-key=bad-next-zero; since-epoch=199999990; next-check-epoch=0200000001; reason=leading zero next"
    if t13_waiting_at "$t13_grammar_now"; then fail "T13 otherwise-valid next-check with leading zero is rejected" "noncanonical next-check accepted"; else pass "T13 otherwise-valid next-check with leading zero is rejected"; fi
    t13_write "- Waiting On: instance-key=bad-next-plus; since-epoch=199999990; next-check-epoch=+200000001; reason=positive sign next"
    if t13_waiting_at "$t13_grammar_now"; then fail "T13 otherwise-valid next-check with plus sign is rejected" "noncanonical next-check accepted"; else pass "T13 otherwise-valid next-check with plus sign is rejected"; fi

    # Pre-conversion bound-order seam. This does NOT copy the epoch validator:
    # it executes the Python source supplied by production zyz_status_waiting,
    # while shadowing only Python's int() call to record which byte tokens the
    # production parser actually converts. now/horizon conversions establish
    # that the tracer ran. Oversized epoch tokens must never appear; legal max
    # tokens must appear and then may be rejected by a later order/horizon arm.
    t13_trace_conversions() { # $1 fixed now, $2 trace file
        t13_trace_now="$1"; t13_trace_file="$2"
        : > "$t13_trace_file"
        (
            . hooks/scripts/lib.sh 2>/dev/null || exit 2
            zyz_now() { printf '%s' "$t13_trace_now"; }
            export ZYZ_T13_INT_TRACE="$t13_trace_file"
            python3() {
                if [ "${1:-}" = - ]; then
                    shift
                    {
                        printf '%s\n' \
                            'import os' \
                            '_zyz_real_int = int' \
                            'def _zyz_trace_int(value, *args):' \
                            '    raw = value if isinstance(value, bytes) else str(value).encode("ascii", "backslashreplace")' \
                            '    with open(os.environ["ZYZ_T13_INT_TRACE"], "a", encoding="ascii") as f: f.write(raw.hex() + chr(10))' \
                            '    return _zyz_real_int(value, *args)' \
                            'int = _zyz_trace_int'
                        cat
                    } | command python3 - "$@"
                else
                    command python3 "$@"
                fi
            }
            zyz_status_waiting "$t13_task/status.md" >/dev/null 2>&1
        )
    }
    t13_trace="$t13/epoch-int.trace"
    t13_write "- Waiting On: instance-key=too-large-since; since-epoch=2147483648; next-check-epoch=2147483647; reason=range before conversion"
    t13_trace_conversions 2147483647 "$t13_trace"
    if grep -qxF 32313437343833363438 "$t13_trace"; then fail "T13 oversized since is rejected before numeric conversion" "int() observed 2147483648"; else pass "T13 oversized since is rejected before numeric conversion"; fi
    t13_write "- Waiting On: instance-key=too-large-next; since-epoch=2147483600; next-check-epoch=2147483648; reason=range before conversion"
    t13_trace_conversions 2147483599 "$t13_trace"
    if grep -qxF 32313437343833363438 "$t13_trace"; then fail "T13 oversized next-check is rejected before numeric conversion" "int() observed 2147483648"; else pass "T13 oversized next-check is rejected before numeric conversion"; fi
    t13_write "- Waiting On: instance-key=too-long-since; since-epoch=99999999999; next-check-epoch=2147483647; reason=length before conversion"
    t13_trace_conversions 2147483647 "$t13_trace"
    if grep -qxF 3939393939393939393939 "$t13_trace"; then fail "T13 overlength epoch is rejected before numeric conversion" "int() observed 11-digit epoch"; else pass "T13 overlength epoch is rejected before numeric conversion"; fi
    t13_write "- Waiting On: instance-key=legal-max-next; since-epoch=2147483600; next-check-epoch=2147483647; reason=legal max reaches later stage"
    t13_trace_conversions 2147483599 "$t13_trace"
    if grep -qxF 32313437343833363437 "$t13_trace"; then pass "T13 legal max epoch reaches numeric conversion"; else fail "T13 legal max epoch reaches numeric conversion" "conversion tracer path is not live"; fi
    t13_write "- Waiting On: instance-key=a; since-epoch=$t13_since; next-check-epoch=$t13_next; reason=one" \
        "- Waiting On: instance-key=b; since-epoch=$t13_since; next-check-epoch=$t13_now; reason=two"
    t13_expect_nag "one expired lane invalidates the multi-lane set"
    t13_write "- Waiting On: instance-key=a; since-epoch=$t13_since; next-check-epoch=$t13_next; reason=one" \
        "- Waiting On: instance-key=a; since-epoch=$t13_since; next-check-epoch=$t13_next; reason=duplicate"
    t13_expect_nag "duplicate instance-key invalidates the set"
    t13_write "- Waiting On: since-epoch=$t13_since; instance-key=a; next-check-epoch=$t13_next; reason=wrong order"
    t13_expect_nag "fixed field order is enforced"
    t13_write "- Waiting On: instance-key=a; since-epoch=01; next-check-epoch=$t13_next; reason=leading zero"
    t13_expect_nag "non-canonical decimal fails open"
    for bad_epoch in 0 -1 +1 2147483648 99999999999; do
        t13_write "- Waiting On: instance-key=a; since-epoch=$bad_epoch; next-check-epoch=$t13_next; reason=bad epoch"
        t13_expect_nag "epoch $bad_epoch is rejected before arithmetic"
    done
    t13_write "- Waiting On: instance-key=a; since-epoch=2147483600; next-check-epoch=2147483647; reason=future plus overflow guard"
    t13_expect_nag "future since/addition boundary fails open"
    t13_write "- Waiting On: instance-key=a; since-epoch=$t13_since; next-check-epoch=$((t13_since + 3601)); reason=over horizon"
    t13_expect_nag "deadline beyond default horizon fails open"
    t13_write "- Waiting On: instance-key=a; since-epoch=$t13_since; next-check-epoch=$t13_next; reason=valid" \
        "## Agent State" \
        "- Waiting On: instance-key=b; since-epoch=$t13_since; next-check-epoch=$t13_next; reason=duplicate section"
    t13_expect_nag "duplicate Agent State section fails open"
    # Isolate the raw-line cap from the 1024-byte reason cap. The oversized line
    # is unrelated Agent State prose, while the Waiting row is fully valid. A
    # widened 8192 cap would therefore suppress freshness incorrectly. Python's
    # binary `for raw in f` includes the trailing LF in len(raw), so a 4095-byte
    # body + LF is the exact accepted 4096 boundary; 4096-byte body + LF is 4097
    # and must invalidate the complete set.
    t13_line_4096="- Note: $(printf '%04087d' 0)"
    t13_line_4097="- Note: $(printf '%04088d' 0)"
    t13_write "$t13_line_4096" "- Waiting On: instance-key=a; since-epoch=$t13_since; next-check-epoch=$t13_next; reason=valid bounded reason"
    t13_expect_quiet "exact 4096-byte unrelated Agent State line keeps valid wait live"
    t13_write "$t13_line_4097" "- Waiting On: instance-key=a; since-epoch=$t13_since; next-check-epoch=$t13_next; reason=valid bounded reason"
    t13_expect_nag "4097-byte unrelated Agent State line invalidates wait set"
    t13_reason="$(printf '%01025d' 0)"
    t13_write "- Waiting On: instance-key=a; since-epoch=$t13_since; next-check-epoch=$t13_next; reason=$t13_reason"
    t13_expect_nag "1025-byte reason fails open"

    # Bidirectional ownership guard: Waiting On never suppresses result flush or
    # a lane's own freshness.  Both observations are externally distinguishable.
    t13_write "- Waiting On: instance-key=a; since-epoch=$t13_since; next-check-epoch=$t13_next; reason=valid"
    t13_flush="$(printf '{"cwd":"%s","tool_name":"Agent","tool_response":{"status":"completed"}}' "$t13" | bash hooks/scripts/post-agent-flush.sh 2>/dev/null)"
    if printf '%s' "$t13_flush" | grep -q 'additionalContext'; then pass "T13 Waiting On never suppresses post-result flush"; else fail "T13 Waiting On never suppresses post-result flush"; fi
    t13_lane="$(printf '{"cwd":"%s","tool_name":"Bash","agent_id":"lane","agent_type":"implementation-agent"}' "$t13" | bash hooks/scripts/status-freshness.sh 2>/dev/null)"
    if printf '%s' "$t13_lane" | grep -q 'additionalContext'; then pass "T13 Waiting On never suppresses implementation/test lane freshness"; else fail "T13 Waiting On never suppresses implementation/test lane freshness"; fi

    # One-shot L3 and L4 use the same fixed-pack observer. L3's status branch
    # is suppressed, but a real persisted stale-role signal must remain. L4
    # must likewise still block the role family even while status itself is
    # waiting. Production exposes no logical-liveness test clock, so this uses
    # the suite's existing bounded two-second ageing interval with a one-second
    # threshold; no logical record or pathname is fabricated or edited.
    printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"waiting-stale","agent_type":"implementation-agent"}' "$t13" \
        | hooks/scripts/subagent-track.sh 2>/dev/null
    t13_observation="$(bash hooks/scripts/agent-runtime-state.sh hook-observe "$t13_task" false 2>/dev/null)"; t13_observation_rc=$?
    if fixed_observer_genesis_unavailable "$t13_observation_rc" "$t13_observation" "$t13_task" false; then
        skip "T13 L3 fixed stale-role ownership requires supported durable GENESIS capability" "$t13_observation"
        skip "T13 L4 fixed stale-role ownership requires supported durable GENESIS capability" "$t13_observation"
    elif [ "$t13_observation_rc" -ne 0 ] || ! printf '%s' "$t13_observation" | python3 -c 'import json,sys;x=json.load(sys.stdin);raise SystemExit(0 if x.get("ok") is True and x.get("state")=="observed" else 1)'; then
        fail "T13 L3 wait suppresses only status-stale, not fixed stale-role" "observer rc=$t13_observation_rc out=$t13_observation"
        fail "T13 L4 wait suppresses only status-stale, not fixed stale-role" "observer rc=$t13_observation_rc out=$t13_observation"
    else
        sleep 2
        t13_l3="$(ZYZ_WATCHDOG_ONCE=1 ZYZ_WATCHDOG_ROLE_STALE_SEC=1 ZYZ_WATCHDOG_STATUS_STALE_SEC=1 bash monitors/watchdog.sh "$t13" 2>/dev/null)"
        if printf '%s' "$t13_l3" | grep -q 'waiting-stale' && ! printf '%s' "$t13_l3" | grep -q 'status file'; then pass "T13 L3 wait suppresses only status-stale, not fixed stale-role"; else fail "T13 L3 wait suppresses only status-stale, not fixed stale-role" "$t13_l3"; fi
        t13_l4="$(printf '{"cwd":"%s","stop_hook_active":false,"background_tasks":[]}' "$t13" | ZYZ_ROLE_STALE_SEC=1 ZYZ_STOP_STATUS_STALE_SEC=1 bash hooks/scripts/stop-gate-main.sh 2>/dev/null)"
        if printf '%s' "$t13_l4" | grep -q 'waiting-stale' && ! printf '%s' "$t13_l4" | grep -q 'status.md is stale'; then pass "T13 L4 wait suppresses only status-stale, not fixed stale-role"; else fail "T13 L4 wait suppresses only status-stale, not fixed stale-role" "$t13_l4"; fi
    fi
    rm -rf "$t13"
else
    skip "T13 Waiting On grammar (no jq/python3)"
fi

# ---------------------------------------------------------------------------
# T14  Static public-contract guards for issues #7--#10.
# These literals are independent anchors copied from the approved protocol, not
# derived from implementation constants.  Full equality is required for the
# command allowlist because substring checks let missing commands pass.
# ---------------------------------------------------------------------------
t14_cli="hooks/scripts/agent-runtime-state.sh"
if [ -f "$t14_cli" ]; then
    t14_cases="$(grep -oE 'adopt-legacy|finalize|gc-step|probe-ack|probe-cancel|probe-create|probe-status|reconcile-start|reconcile-stop|snapshot-gc|snapshot-publication' "$t14_cli" | sort -u | tr '\n' ' ' | sed 's/ $//')"
    t14_want="adopt-legacy finalize gc-step probe-ack probe-cancel probe-create probe-status reconcile-start reconcile-stop"
    # Containment is banned here: an allowlist is security-relevant and only
    # full set equality proves there are neither missing nor extra mutators.
    if [ "$t14_cases" = "$t14_want" ]; then pass "T14 runtime CLI command set is exact"; else fail "T14 runtime CLI command set is exact" "got [$t14_cases]"; fi
else
    fail "T14 runtime CLI exists" "missing $t14_cli"
fi

t14_env_want='ZYZ_AGENT_LOCK_ACQUIRE_SEC ZYZ_AGENT_LOCK_STALE_SEC ZYZ_INFLIGHT_GRACE_SEC ZYZ_NO_OUTPUT_MAX_FILE_BYTES ZYZ_NO_OUTPUT_MAX_INVENTORY_BYTES ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES ZYZ_NO_OUTPUT_MAX_PATHS ZYZ_NO_OUTPUT_MAX_RSS_BYTES ZYZ_NO_OUTPUT_MAX_TEMP_BYTES ZYZ_NO_OUTPUT_MAX_TOTAL_BYTES ZYZ_NO_OUTPUT_SNAPSHOT_TIMEOUT_SEC ZYZ_NO_OUTPUT_TEMP_STALE_SEC ZYZ_RECONNECT_ACK_SEC ZYZ_RUNNING_NO_ACK_GRACE_SEC ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES ZYZ_SNAPSHOT_GC_INTERVAL_SEC ZYZ_SNAPSHOT_GC_MAX_ENTRIES_PER_PASS ZYZ_SNAPSHOT_GC_MAX_SEC ZYZ_SNAPSHOT_GC_MAX_VERIFY_BYTES_PER_PASS ZYZ_WAIT_MAX_SEC ZYZ_WATCHDOG_NO_OUTPUT_SEC'
t14_env_got="$(grep -o 'ZYZ_[A-Z0-9_]*' hooks/README.md 2>/dev/null | sort -u | grep -E 'ZYZ_(WAIT_MAX|RECONNECT_ACK|INFLIGHT_GRACE|RUNNING_NO_ACK_GRACE|AGENT_LOCK|WATCHDOG_NO_OUTPUT|NO_OUTPUT_|SNAPSHOT_GC_)' | tr '\n' ' ' | sed 's/ $//')"
if [ "$t14_env_got" = "$t14_env_want" ]; then pass "T14 documented issue #7--#10 public env set is exact"; else fail "T14 documented issue #7--#10 public env set is exact" "got [$t14_env_got]"; fi
if ! rg -n 'GIT_(DIR|WORK_TREE|INDEX_FILE)|git (diff|status|ls-files|rev-parse)' hooks/scripts monitors/watchdog.sh 2>/dev/null | grep -v 'checkout-guard\|zyz_task_root' >/dev/null; then
    pass "T14 physical snapshot path has no Git semantic dependency"
else
    fail "T14 physical snapshot path has no Git semantic dependency" "found forbidden Git semantic input"
fi

t14_allow_main='adopt-legacy finalize gc-step probe-ack probe-cancel probe-create probe-status reconcile-start reconcile-stop'
for f in skills/execute-task/SKILL.md skills/execute-task/prompts/main-agent.md; do
    [ -f "$f" ] || { fail "T14 protocol allowlist in $f" "missing"; continue; }
    t14_seen="$(grep -oE 'adopt-legacy|finalize|gc-step|probe-ack|probe-cancel|probe-create|probe-status|reconcile-start|reconcile-stop|snapshot-gc|snapshot-publication' "$f" | sort -u | tr '\n' ' ' | sed 's/ $//')"
    if [ "$t14_seen" = "$t14_allow_main" ]; then pass "T14 main protocol allowlist in $f is exhaustive"; else fail "T14 main protocol allowlist in $f is exhaustive" "got [$t14_seen]"; fi
done
t14_allow_role='adopt-legacy finalize probe-ack probe-cancel probe-create probe-status reconcile-start reconcile-stop'
for f in agents/implementation-agent.md subagents/implementation-agent.md agents/test-agent.md subagents/test-agent.md agents/review-agent.md subagents/review-agent.md; do
    [ -f "$f" ] || { fail "T14 role protocol allowlist in $f" "missing"; continue; }
    t14_vocab_line="$(grep -E 'full runtime vocabulary|complete protocol vocabulary|complete supported runtime command vocabulary' "$f" | head -n1)"
    t14_seen="$(printf '%s' "$t14_vocab_line" | grep -oE 'adopt-legacy|finalize|gc-step|probe-ack|probe-cancel|probe-create|probe-status|reconcile-start|reconcile-stop|snapshot-gc|snapshot-publication' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    if [ "$t14_seen" = "$t14_allow_role" ]; then pass "T14 role runtime allowlist in $f excludes manual gc-step"; else fail "T14 role runtime allowlist in $f excludes manual gc-step" "got [$t14_seen]"; fi
done
# Mirror equality follows the repository's established orchestration T1/T10
# contract: agents/ carries required Claude YAML frontmatter, subagents/ must be
# frontmatter-free, and the role-intro names its owning surface differently.
# Normalize exactly those two wrapper differences; every other body byte remains
# in the diff. Raw cmp was a conflicting contract because a correct pair cannot
# be byte-identical on disk.
t14_strip_frontmatter() {
    awk '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---"  { infm=0; next }
        !infm              { print }
    ' "$1"
}
t14_normalize_role_body() {
    sed '/./,$!d' \
        | sed -E 's/^You are .* for the (zyz-worker execute-task workflow|execute-task skill)\.$/You are <ROLE> for the execute-task workflow./'
}
t14_mirror_pair() { # agents path, subagents path, role label
    t14_agent="$1"; t14_sub="$2"; t14_role="$3"
    t14_sub_first="$(grep -m1 -vE '^[[:space:]]*$' "$t14_sub" 2>/dev/null || true)"
    case "$t14_sub_first" in
        '# '*) pass "T14 $t14_sub remains frontmatter-free" ;;
        *) fail "T14 $t14_sub remains frontmatter-free" "first non-empty line=[$t14_sub_first]" ;;
    esac
    t14_agent_first="$(head -n1 "$t14_agent" 2>/dev/null || true)"
    if [ "$t14_agent_first" = '---' ]; then pass "T14 $t14_agent retains Claude frontmatter"; else fail "T14 $t14_agent retains Claude frontmatter" "first line=[$t14_agent_first]"; fi
    t14_diff="$(diff \
        <(t14_strip_frontmatter "$t14_agent" | t14_normalize_role_body) \
        <(t14_normalize_role_body < "$t14_sub") 2>&1 || true)"
    if [ -z "$t14_diff" ]; then
        pass "T14 $t14_role normalized role bodies are exactly synchronized"
    else
        fail "T14 $t14_role normalized role bodies are exactly synchronized" "$t14_diff"
    fi
}
t14_mirror_pair agents/implementation-agent.md subagents/implementation-agent.md implementation-agent
t14_mirror_pair agents/test-agent.md subagents/test-agent.md test-agent
t14_mirror_pair agents/review-agent.md subagents/review-agent.md review-agent
for f in agents/implementation-agent.md agents/test-agent.md subagents/implementation-agent.md subagents/test-agent.md; do
    if grep -qi 'skeleton\|骨架' "$f" && grep -qi 'incremental\|增量' "$f"; then pass "T14 $f requires early skeleton and incremental disk output"; else fail "T14 $f requires early skeleton and incremental disk output"; fi
done

# ---------------------------------------------------------------------------
# T15--T21 pathname-era block retired by T166.
#
# The approved fixed-pack design makes IDENTITY/START/HEARTBEAT/DONE/FINALIZED,
# PROBE_STATE, INFLIGHT, transition/publication/GC journals, baseline summary and
# live inventory logical records rather than standalone files. Keeping the old
# fixtures would test a forbidden alternate authority. Equivalent public and
# independent physical coverage is now owned by T33/T34/T37/T42/T43/T45--T49;
# the exact claim-to-case map and observation ceilings are recorded in test.md.
# ---------------------------------------------------------------------------
# T22  Raw path-state fixture inventory. The backend selftest must enumerate
# the exact base64 names from a descriptor scan; textual/pathspec semantics
# cannot reconstruct these byte sequences.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1 && [ -f hooks/scripts/runtime_state.py ]; then
    t22="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t22.XXXXXX")"
    # Construct control/invalid bytes numerically. Python string escapes nested
    # inside a shell single-quoted program previously created literal backslash
    # text while the independent base64 oracle expected LF/TAB/0xff. APFS may
    # reject 0xff at creation with EILSEQ; that is the approved raw-byte
    # capability-unavailable arm, not a scanner failure. Only encoding-specific
    # errors are accepted as unavailable; ENOSPC/EACCES/etc. still fail setup.
    t22_invalid_cap="$(python3 -c 'import errno,os,sys
r=os.fsencode(sys.argv[1])
for n in (b"line"+bytes([10])+b"feed",b"tab"+bytes([9])+b"name",b"back"+bytes([92])+b"slash",b"-leading"):
 f=os.open(r+b"/"+n,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o640);os.write(f,b"x");os.close(f)
try:
 f=os.open(r+b"/bad-"+bytes([255]),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o640);os.write(f,b"x");os.close(f)
except OSError as e:
 allowed={errno.EILSEQ,errno.EINVAL,getattr(errno,"ENOTSUP",-1)}
 if e.errno not in allowed: raise
 print("unavailable: errno=%d (%s): filesystem rejected raw 0xff filename"%(e.errno,e.strerror))
else: print("available")' "$t22" 2>&1)"; t22_create_rc=$?
    t22_o="$(python3 hooks/scripts/runtime_state.py path-record-selftest "$t22" 2>/dev/null)"
    t22_got="$(printf '%s' "$t22_o" | python3 -c 'import json,sys;print(" ".join(sorted(json.load(sys.stdin).get("path_b64",[]))))' 2>/dev/null)"
    t22_supported_want='LWxlYWRpbmc= YmFja1xzbGFzaA== bGluZQpmZWVk dGFiCW5hbWU='
    # t22_got is already Python-sorted in one deterministic Unicode/ASCII
    # collation. Preserve that oracle order while removing only the optional
    # invalid-byte token. A second locale-sensitive system `sort` previously
    # reordered upper/lowercase Base64 differently on macOS.
    t22_supported_got="$(printf '%s\n' $t22_got | grep -v '^YmFkLf8=$' | tr '\n' ' ' | sed 's/ $//')"
    if [ "$t22_create_rc" -eq 0 ] && [ "$t22_supported_got" = "$t22_supported_want" ]; then
        pass "T22 LF/TAB/backslash/leading-dash paths round-trip with exact raw bytes"
    else
        fail "T22 LF/TAB/backslash/leading-dash paths round-trip with exact raw bytes" "create_rc=$t22_create_rc got=[$t22_got] capability=[$t22_invalid_cap]"
    fi
    case "$t22_invalid_cap" in
        available)
            t22_all_want='LWxlYWRpbmc= YmFja1xzbGFzaA== YmFkLf8= bGluZQpmZWVk dGFiCW5hbWU='
            if [ "$t22_got" = "$t22_all_want" ]; then pass "T22 invalid-UTF8 0xff path round-trips when filesystem supports creation"; else fail "T22 invalid-UTF8 0xff path round-trips when filesystem supports creation" "got [$t22_got]"; fi
            ;;
        unavailable:*)
            if [ "$t22_got" = "$t22_supported_want" ]; then
                skip "T22 invalid-UTF8 0xff path round-trip" "$t22_invalid_cap"
            else
                fail "T22 invalid-byte capability-unavailable leaves supported observations exact" "got [$t22_got] capability=[$t22_invalid_cap]"
            fi
            ;;
        *) fail "T22 invalid-byte creation capability probe is classified" "create_rc=$t22_create_rc result=[$t22_invalid_cap]" ;;
    esac
    rm -rf "$t22"
else
    skip "T22 raw path-state round trips (runtime backend unavailable)"
fi

# ---------------------------------------------------------------------------
# T23  Test-infrastructure degradation guards derived from real fixtures and
# production registrations/call graph. First real interception: review showed
# the former literal `identity_count=2` and six-word checklist only tested
# themselves; deleting a real identity or production mechanism stayed green.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1 && [ -f hooks/scripts/runtime_state.py ]; then
    # Dynamic fixed-pack identity/role separation is proved by T33's raw
    # audit-pack + selected CELL/ROOT oracle. T23 remains a source-level
    # degradation guard and never reopens logical records as pathnames.

    # Parse real production functions and follow their call graph. A source
    # vocabulary hit is insufficient: hook-start/stop must actually reach the
    # shared event validator, and reconcile dispatch must call a handler rather
    # than directly returning the former hard-coded unavailable result.
    t23_graph="$(python3 -c 'import ast,json,sys
tree=ast.parse(open(sys.argv[1],encoding="utf-8").read());funcs={n.name:n for n in tree.body if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
def name(call):
 f=call.func
 if isinstance(f,ast.Name): return f.id
 if isinstance(f,ast.Attribute): return name(ast.Call(f.value,[],[]))+"."+f.attr
 return ""
edges={fn:{name(n) for n in ast.walk(node) if isinstance(n,ast.Call)} for fn,node in funcs.items()}
def reaches(start,target,seen=None):
 seen=set() if seen is None else seen
 if start in seen:return False
 seen.add(start)
 return target in edges.get(start,set()) or any(c in funcs and reaches(c,target,seen) for c in edges.get(start,set()))
main=funcs.get("main");commands=set();dispatch_calls={};dispatch_raises={}
handlers={"hook-start":"hook_start","hook-stop":"hook_stop","probe-create":"probe_create","probe-ack":"probe_update","probe-cancel":"probe_update","finalize":"finalize_fixed","adopt-legacy":"adopt_legacy","reconcile-start":"reconcile_start","reconcile-stop":"reconcile_stop"}
if main:
 for n in ast.walk(main):
  if isinstance(n,ast.Compare):
   for c in n.comparators:
    if isinstance(c,ast.Constant) and isinstance(c.value,str):commands.add(c.value)
    elif isinstance(c,(ast.Tuple,ast.List)):commands.update(x.value for x in c.elts if isinstance(x,ast.Constant) and isinstance(x.value,str))
  if isinstance(n,ast.If):
   branch={x.value for x in ast.walk(n.test) if isinstance(x,ast.Constant) and isinstance(x.value,str)} & set(handlers)
   calls={name(x) for stmt in n.body for x in ast.walk(stmt) if isinstance(x,ast.Call)}
   raises=any(isinstance(x,ast.Raise) for stmt in n.body for x in ast.walk(stmt))
   for command in branch:
    dispatch_calls.setdefault(command,set()).update(calls & set(handlers.values()))
    dispatch_raises[command]=dispatch_raises.get(command,False) or raises
out={"commands":sorted(commands),"hook_start_event_validator":reaches("hook_start","validate_event_identity_fields"),"hook_stop_event_validator":reaches("hook_stop","validate_event_identity_fields"),"dispatch_calls":{k:sorted(v) for k,v in dispatch_calls.items()},"dispatch_raises":dispatch_raises}
print(json.dumps(out,sort_keys=True,separators=(",",":")))' hooks/scripts/runtime_state.py)"
    if printf '%s' "$t23_graph" | python3 -c 'import json,sys;x=json.load(sys.stdin);seen=set(x.get("commands",[]));public={"adopt-legacy","finalize","gc-step","probe-ack","probe-cancel","probe-create","probe-status","reconcile-start","reconcile-stop"};internal={"hook-main-heartbeat","hook-observe","hook-start","hook-stop","hook-heartbeat","config-status","path-record-selftest"};forbidden={"snapshot-publication","snapshot-gc"};want={"hook-start":"hook_start","hook-stop":"hook_stop","probe-create":"probe_create","probe-ack":"probe_update","probe-cancel":"probe_update","finalize":"finalize_fixed","adopt-legacy":"adopt_legacy","reconcile-start":"reconcile_start","reconcile-stop":"reconcile_stop"};calls=x.get("dispatch_calls",{});raise SystemExit(0 if seen==public|internal and not forbidden&seen and all(calls.get(k)==[v] for k,v in want.items()) else 1)'; then
        pass "T23 production dispatcher separates exact vocabulary and calls exact public/internal handlers"
    else
        fail "T23 production dispatcher separates exact vocabulary and calls exact public/internal handlers" "$t23_graph"
    fi
    if printf '%s' "$t23_graph" | python3 -c 'import json,sys;x=json.load(sys.stdin);calls=x.get("dispatch_calls",{});raises=x.get("dispatch_raises",{});ok=(x.get("hook_start_event_validator") is True and x.get("hook_stop_event_validator") is True and calls.get("reconcile-start")==["reconcile_start"] and calls.get("reconcile-stop")==["reconcile_stop"] and raises.get("reconcile-start") is False and raises.get("reconcile-stop") is False);raise SystemExit(0 if ok else 1)'; then
        pass "T23 production event hooks and both reconcile branches reach exact handlers"
    else
        fail "T23 production event hooks and both reconcile branches reach exact handlers" "$t23_graph"
    fi

    t23_named="$(python3 -c 'import re,sys;s=open(sys.argv[1],encoding="utf-8").read();names=set(re.findall(r"(?:pass|fail) \"(T(?:13|27|28|33|34|37|42|43|44|45|46|47|48|49|50|51|52|53) [^\"]+)",s));groups={n.split()[0] for n in names};print(" ".join(sorted(groups)))' scripts/test-watchdog-hooks.sh)"
    if [ "$t23_named" = 'T13 T27 T28 T33 T34 T37 T42 T43 T44 T45 T46 T47 T48 T49 T50 T51 T52 T53' ]; then pass "T23 real named-case registry retains every fixed-authority mechanism suite"; else fail "T23 real named-case registry retains every fixed-authority mechanism suite" "got=[$t23_named]"; fi
else
    skip "T23 fixture/call-graph degradation guards (python runtime backend unavailable)"
fi

# ---------------------------------------------------------------------------
# T24 pathname-era diagnostic/receipt block retired by T166.
# Fixed DIAGNOSTICS, TRANSITION_JOURNAL and terminal records are covered through
# raw audit/work packs and catalog/terminal cells by T33, T42 and T43. The old
# standalone diagnostic, journal and resolved pathnames are forbidden oracles.
# ---------------------------------------------------------------------------
# T27  Public gc-step request/output contract.  The expected object is anchored
# independently here: implementation constants and output helpers are never
# imported by the oracle.  Invalid requests must not bootstrap or modify the
# supplied task/runtime tree.
# ---------------------------------------------------------------------------
if json_tool && [ -x hooks/scripts/agent-runtime-state.sh ]; then
    t27="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t27.XXXXXX")"
    t27_task="$t27/task"; mkdir -p "$t27_task/runtime"
    t27_tree_digest() {
        python3 -c 'import hashlib,os,stat,sys
root=os.fsencode(sys.argv[1]); h=hashlib.sha256()
for base,dirs,files in os.walk(root,topdown=True,followlinks=False):
 dirs.sort(); files.sort(); rel=os.path.relpath(base,root)
 for name in dirs+files:
  path=os.path.join(base,name); st=os.lstat(path); r=os.path.relpath(path,root)
  h.update(os.fsencode(r)+b"\0"+str(stat.S_IFMT(st.st_mode)).encode()+b"\0")
  if stat.S_ISREG(st.st_mode): h.update(open(path,"rb").read())
print(h.hexdigest())' "$1"
    }
    t27_invalid_contract() {
        printf '%s' "$1" | python3 -c 'import json,sys
raw=sys.stdin.read(); x=json.loads(raw)
order=["ok","state","error","trigger","due","lock_acquired","claims_scanned","claims_skipped","blocked_claims_known","transactions_advanced","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","owned_bytes_before","owned_bytes_after","high_water","hard_water","receipts_anchored","next_gc_epoch"]
counters=["claims_scanned","claims_skipped","transactions_advanced","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","receipts_anchored"]
roots=["blocked_claims_known","owned_bytes_before","owned_bytes_after","high_water","hard_water","next_gc_epoch"]
err=x.get("error")
ok=(list(x)==order and x.get("ok") is False and x.get("state")=="error" and
 isinstance(err,dict) and list(err)==["code","message","retryable"] and
 err.get("code")=="invalid-request" and err.get("retryable") is False and
 x.get("trigger") is None and x.get("due") is None and x.get("lock_acquired") is False and
 all(type(x.get(k)) is int and x[k]==0 for k in counters) and all(x.get(k) is None for k in roots))
raise SystemExit(0 if ok else 1)'
    }
    t27_before="$(t27_tree_digest "$t27_task")"
    t27_out="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t27_task" invalid-trigger 2>/dev/null)"; t27_rc=$?
    t27_after="$(t27_tree_digest "$t27_task")"
    if [ "$t27_rc" -eq 2 ] && t27_invalid_contract "$t27_out" && [ "$t27_before" = "$t27_after" ]; then
        pass "T27 gc-step invalid trigger returns canonical rc2 zero-effect envelope"
    else
        fail "T27 gc-step invalid trigger returns canonical rc2 zero-effect envelope" "rc=$t27_rc before=$t27_before after=$t27_after out=$t27_out"
    fi
    t27_out="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t27/nonexistent" manual 2>/dev/null)"; t27_rc=$?
    if [ "$t27_rc" -eq 2 ] && t27_invalid_contract "$t27_out" && [ ! -e "$t27/nonexistent" ]; then
        pass "T27 gc-step invalid task path never creates runtime state"
    else
        fail "T27 gc-step invalid task path never creates runtime state" "rc=$t27_rc out=$t27_out"
    fi
    t27_before="$(t27_tree_digest "$t27_task")"
    t27_out="$(ZYZ_TEST_GC_NOW_EPOCH=-1 bash hooks/scripts/agent-runtime-state.sh gc-step "$t27_task" manual 2>/dev/null)"; t27_rc=$?
    t27_after="$(t27_tree_digest "$t27_task")"
    if [ "$t27_rc" -eq 2 ] && [ "$t27_before" = "$t27_after" ] && printf '%s' "$t27_out" | python3 -c 'import json,sys
x=json.load(sys.stdin);err=x.get("error");counters=["claims_scanned","claims_skipped","transactions_advanced","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","receipts_anchored"];roots=["blocked_claims_known","owned_bytes_before","owned_bytes_after","high_water","hard_water","next_gc_epoch"]
ok=(x.get("ok") is False and x.get("state")=="error" and isinstance(err,dict) and err.get("code")=="invalid-request" and err.get("retryable") is False and x.get("trigger")=="manual" and x.get("due") is True and x.get("lock_acquired") is False and all(type(x.get(k)) is int and x[k]==0 for k in counters) and all(x.get(k) is None for k in roots));raise SystemExit(0 if ok else 1)'; then
        pass "T27 invalid fixed GC clock is rejected before GENESIS with byte-zero-effect"
    else
        fail "T27 invalid fixed GC clock is rejected before GENESIS with byte-zero-effect" "rc=$t27_rc before=$t27_before after=$t27_after out=$t27_out"
    fi
    rm -rf "$t27"
else
    skip "T27 public gc-step request/output contract (no JSON tool or CLI)"
fi

# ---------------------------------------------------------------------------
# T28  Real GENESIS fixed objects, schema-v1 layout, and crash recovery.  The
# oracle reads the physical pack bytes and allocation facts directly.  Green
# here proves the fixed layout and public recovery path; it does not prove a
# power-loss guarantee on a filesystem whose durable no-replace capability is
# unavailable (that host is a named skip, never counted as mechanism success).
# ---------------------------------------------------------------------------
if json_tool && [ -x hooks/scripts/agent-runtime-state.sh ]; then
    t28_converge() { # task-dir output-file; returns final public rc
        t28_converge_i=0
        while [ "$t28_converge_i" -lt 16 ]; do
            bash hooks/scripts/agent-runtime-state.sh gc-step "$1" manual >"$2" 2>/dev/null
            t28_converge_rc=$?
            [ "$t28_converge_rc" -eq 3 ] || return "$t28_converge_rc"
            t28_converge_i=$((t28_converge_i+1))
        done
        return 3
    }
    t28_layout() { # task-dir
        t28_container="$(find "$1/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        [ "$(printf '%s\n' "$t28_container" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || return 1
        python3 - "$t28_container" <<'PY'
import hashlib,json,os,stat,struct,sys
p=sys.argv[1]
D=lambda domain,value:hashlib.sha256(domain+value).digest()
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
fixed={".catalog-lock.v1":None,".catalog-shared-source-lock.v1":None,".terminal-index-lock.v1":None,
 ".catalog-global-pack.v1":4194304,".catalog-recovery-pack.v1":8388608,".terminal-audit-pack.v1":16777216,
 ".catalog-segment.0000000000000001.v1":1048576,".catalog-segment.0000000000000002.v1":1048576,
 ".catalog-compaction-scratch.v1":1048576}
if set(os.listdir(p))!=set(fixed): raise SystemExit(1)
for name,size in fixed.items():
 st=os.lstat(os.path.join(p,name))
 if not stat.S_ISREG(st.st_mode) or st.st_nlink<1 or st.st_blocks<=0: raise SystemExit(1)
 if size is not None and (st.st_size!=size or st.st_blocks*512<size): raise SystemExit(1)

def image(raw,magic):
 if len(raw)<128 or raw[:8]!=magic.ljust(8,b"\0"): raise ValueError("image magic")
 schema,flags,generation,length=struct.unpack_from(">HHQI",raw,8)
 if schema!=1 or flags!=0 or generation<1 or length>min(3968,len(raw)-128): raise ValueError("image header")
 source=bytearray(raw);source[56:88]=bytes(32)
 if raw[56:88]!=D(b"zyz-pack-image-v1",bytes(source)): raise ValueError("image checksum")
 payload=raw[128:128+length]
 if raw[96:128]!=D(b"zyz-pack-payload-v1",payload): raise ValueError("payload checksum")
 value=json.loads(payload)
 if not isinstance(value,dict) or J(value)!=payload: raise ValueError("canonical payload")
 return {"generation":generation,"predecessor":raw[24:56],"metadata":value,
         "digest":D(b"zyz-pack-image-id-v1",raw),"raw":raw}

def exact_pair(raw,offset,size,magic):
 observed=[]
 for bank in (0,1):
  part=raw[offset+bank*size:offset+(bank+1)*size]
  if part==bytes(size): raise ValueError("missing older-valid A/B image")
  parsed=image(part,magic);parsed["bank"]=bank;observed.append(parsed)
 observed.sort(key=lambda item:item["generation"])
 if [item["generation"] for item in observed]!=[1,2]: raise ValueError("A/B generations")
 if observed[0]["predecessor"]!=bytes(32) or observed[1]["predecessor"]!=observed[0]["digest"]:
  raise ValueError("A/B predecessor chain")
 return observed

def free_images(index):
 zero=bytes(32)
 core=struct.pack(">8sHHIQQ32s",b"ZYZCFV1\0",1,0,index,0,0,zero)
 core_digest=D(b"zyz-cell-free-core-v1",core)
 body=struct.pack(">8sB7xIQ",b"ZYZFRB1\0",0,index,0)+zero+zero+zero+core_digest
 body_digest=D(b"zyz-free-receipt-body-v1",body)
 final_digest=D(b"zyz-final-cell-image-v1",core+body_digest)
 record_digest=D(b"zyz-free-receipt-record-v1",body+body_digest+final_digest)
 recovery=bytearray(512);recovery[:8]=b"ZYZRCV1\0"
 struct.pack_into(">HHIQQ",recovery,8,1,0,index,0,0)
 recovery[64:128]=core;recovery[128:160]=core_digest
 recovery[160:192]=body_digest;recovery[192:224]=final_digest
 source=bytearray(recovery);source[32:64]=bytes(32)
 recovery[32:64]=D(b"zyz-recovery-cell-image-v1",bytes(source))
 recovery=bytes(recovery);recovery_digest=D(b"zyz-recovery-cell-selected-v1",recovery)
 directory=bytearray(192);directory[:4]=b"ZCD1"
 struct.pack_into(">BBHIHH",directory,4,1,0,0,index,0,0)
 for field_index,value in enumerate((zero,recovery_digest,record_digest,zero,body_digest)):
  directory[32+field_index*32:64+field_index*32]=value
 source=bytearray(directory);source[16:32]=bytes(16)
 directory[16:32]=D(b"zyz-cell-directory-image-v1",bytes(source))[:16]
 return bytes(directory),recovery

g=open(os.path.join(p,".catalog-global-pack.v1"),"rb").read()
r=open(os.path.join(p,".catalog-recovery-pack.v1"),"rb").read()
if len(g)!=4194304 or len(r)!=8388608 or any(g[3702784:4194304]): raise SystemExit(1)
roots=exact_pair(g,32768,65536,b"ZYZROOT1")
schedules=exact_pair(g,24576,4096,b"ZYZSCH1")
if schedules[0]["raw"][128+struct.unpack_from(">I",schedules[0]["raw"],20)[0]:]!=bytes(4096-128-struct.unpack_from(">I",schedules[0]["raw"],20)[0]): raise ValueError("older SCHEDULE tail")
if schedules[1]["raw"][128+struct.unpack_from(">I",schedules[1]["raw"],20)[0]:]!=bytes(4096-128-struct.unpack_from(">I",schedules[1]["raw"],20)[0]): raise ValueError("active SCHEDULE tail")
if schedules[0]["metadata"].get("state")!="UNINITIALIZED" or schedules[1]["metadata"].get("state")!="SCHEDULED":
 raise ValueError("SCHEDULE state progression")
for root,schedule in zip(roots,schedules):
 if root["metadata"].get("generation")!=root["generation"] or schedule["metadata"].get("generation")!=schedule["generation"]:
  raise ValueError("semantic generation")
 if root["metadata"].get("schedule_bank")!=schedule["bank"] or root["metadata"].get("schedule_digest")!=schedule["digest"].hex():
  raise ValueError("ROOT SCHEDULE selector")

active=roots[1];selector=active["raw"][4096:5120]
selector_digest=D(b"zyz-root-selector-v1",selector)
generations=hashlib.sha256(b"zyz-cell-generation-vector-v1")
directory_digest=hashlib.sha256(b"zyz-cell-directory-selected-v1")
recovery_digest=hashlib.sha256(b"zyz-recovery-selected-v1")
for index in range(8192):
 bank=(selector[index//8]>>(index%8))&1
 directory_bases=(163840,1736704)
 selected_directory=g[directory_bases[bank]+index*192:directory_bases[bank]+(index+1)*192]
 inactive_directory=g[directory_bases[1-bank]+index*192:directory_bases[1-bank]+(index+1)*192]
 expected_directory,expected_recovery=free_images(index)
 if bank!=0 or selected_directory!=expected_directory or inactive_directory!=bytes(192):
  raise ValueError("directory FREE selection")
 recovery_a=r[index*1024:index*1024+512];recovery_b=r[index*1024+512:(index+1)*1024]
 if recovery_a!=expected_recovery or recovery_b!=bytes(512): raise ValueError("recovery FREE selection")
 generations.update(struct.pack(">IQB",index,0,bank))
 directory_digest.update(struct.pack(">IB",index,bank));directory_digest.update(selected_directory)
 recovery_digest.update(struct.pack(">IB",index,0));recovery_digest.update(recovery_a)
aggregate=(selector_digest,generations.digest(),directory_digest.digest(),recovery_digest.digest())
expected={"selector_sha256":aggregate[0].hex(),"generation_vector_sha256":aggregate[1].hex(),
          "directory_sha256":aggregate[2].hex(),"recovery_sha256":aggregate[3].hex()}
if any(active["metadata"].get(name)!=value for name,value in expected.items()):
 raise ValueError("ROOT aggregate metadata")
if active["raw"][41984:42112]!=b"".join(aggregate) or active["raw"][46080:]!=bytes(19456):
 raise ValueError("ROOT physical aggregate regions")
for root in roots:
 if root["raw"][4096:5120]!=selector or root["raw"][41984:42112]!=b"".join(aggregate):
  raise ValueError("ROOT generation aggregate continuity")
PY
    }
    t28_gc_contract() {
        printf '%s' "$1" | python3 -c 'import json,sys
x=json.load(sys.stdin); order=["ok","state","error","trigger","due","lock_acquired","claims_scanned","claims_skipped","blocked_claims_known","transactions_advanced","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","owned_bytes_before","owned_bytes_after","high_water","hard_water","receipts_anchored","next_gc_epoch"]
counters=["claims_scanned","claims_skipped","transactions_advanced","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","receipts_anchored"]
roots=["blocked_claims_known","owned_bytes_before","owned_bytes_after","high_water","hard_water"]
ok=(list(x)==order and type(x.get("ok")) is bool and x.get("state") in ("idle","compacted","pending","pressure","blocked") and
 x.get("trigger")=="manual" and x.get("due") is True and x.get("lock_acquired") is True and
 all(type(x.get(k)) is int and x[k]>=0 for k in counters) and all(type(x.get(k)) is int and x[k]>=0 for k in roots) and
 x.get("owned_bytes_before")==33554432 and x.get("owned_bytes_after")==33554432 and
 (x.get("next_gc_epoch") is None or type(x.get("next_gc_epoch")) is int))
raise SystemExit(0 if ok else 1)'
    }
    t28="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t28.XXXXXX")"; t28_task="$t28/task"; mkdir -p "$t28_task/runtime"
    t28_converge "$t28_task" "$t28/final.out"; t28_rc=$?; t28_out="$(cat "$t28/final.out" 2>/dev/null)"
    t28_code="$(printf '%s' "$t28_out" | python3 -c 'import json,sys; x=json.load(sys.stdin); print((x.get("error") or {}).get("code",""))' 2>/dev/null)"
    if [ "$t28_code" = genesis-capability-unavailable ]; then
        skip "T28 GENESIS fixed layout requires durable no-replace/preallocation/mount capability" "$t28_out"
        t28_supported=0
    elif [ "$t28_rc" -eq 0 ] && t28_gc_contract "$t28_out" && t28_layout "$t28_task"; then
        pass "T28 public manual gc-step creates the exact preallocated GENESIS closed set"
        t28_supported=1
    else
        fail "T28 public manual gc-step creates the exact preallocated GENESIS closed set" "rc=$t28_rc out=$t28_out"
        t28_supported=0
    fi
    rm -rf "$t28"
    if [ "$t28_supported" -eq 1 ]; then
        for t28_phase in g0-fixed-names-durable g1-fixed-content-prepared g2-global-roots-prepared g3-genesis-prepared g4-canonical-visible-unconfirmed g4-canonical-durable; do
            t28="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t28-crash.XXXXXX")"; t28_task="$t28/task"; mkdir -p "$t28_task/runtime"
            ZYZ_TEST_TRANSITION_STOP_AFTER="catalog-genesis:$t28_phase" \
                bash hooks/scripts/agent-runtime-state.sh gc-step "$t28_task" manual >"$t28/first.out" 2>"$t28/first.err"
            t28_first_rc=$?
            t28_container="$(find "$t28_task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
            t28_prepare=0; t28_canonical=0
            [ -n "$t28_container" ] && [ -e "$t28_container/.catalog-global-pack.prepare.v1" ] && t28_prepare=1
            [ -n "$t28_container" ] && [ -e "$t28_container/.catalog-global-pack.v1" ] && t28_canonical=1
            case "$t28_phase" in
                g0-*|g1-*|g2-*|g3-*) t28_prior_ok=$((t28_prepare == 1 && t28_canonical == 0)) ;;
                g4-*) t28_prior_ok=$((t28_prepare == 0 && t28_canonical == 1)) ;;
            esac
            t28_converge "$t28_task" "$t28/resume.out"; t28_resume_rc=$?; t28_resume="$(cat "$t28/resume.out" 2>/dev/null)"
            if [ "$t28_first_rc" -eq 86 ] && [ "$t28_prior_ok" -eq 1 ] && [ "$t28_resume_rc" -eq 0 ] \
                && t28_gc_contract "$t28_resume" && t28_layout "$t28_task"; then
                pass "T28 GENESIS $t28_phase crash resumes through public gc-step"
            else
                fail "T28 GENESIS $t28_phase crash resumes through public gc-step" "kill_rc=$t28_first_rc prior=$t28_prior_ok resume_rc=$t28_resume_rc out=$t28_resume"
            fi
            rm -rf "$t28"
        done
    fi
else
    skip "T28 real GENESIS layout/crash recovery (no JSON tool or CLI)"
fi

# ---------------------------------------------------------------------------
# T29  Pre-snapshot lock/capability/corruption matrix and active/inactive A/B
# behavior.  Runtime tree byte digests are the zero-effect oracle.  A lock
# timeout is induced with a real competing fcntl lock, not a canned result.
# ---------------------------------------------------------------------------
if json_tool && [ -x hooks/scripts/agent-runtime-state.sh ]; then
    t29="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t29.XXXXXX")"; t29_task="$t29/task"; mkdir -p "$t29_task/runtime"
    t29_seed_i=0; t29_seed_rc=3; t29_seed=""
    while [ "$t29_seed_i" -lt 16 ] && [ "$t29_seed_rc" -eq 3 ]; do
        t29_seed="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t29_task" manual 2>/dev/null)"; t29_seed_rc=$?
        t29_seed_i=$((t29_seed_i+1))
    done
    t29_code="$(printf '%s' "$t29_seed" | python3 -c 'import json,sys; x=json.load(sys.stdin); print((x.get("error") or {}).get("code",""))' 2>/dev/null)"
    t29_container="$(find "$t29_task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t29_tree_digest() { find "$1" -type f -exec shasum -a 256 {} \; 2>/dev/null | sort | shasum -a 256 | awk '{print $1}'; }
    t29_matrix() { # json trigger due lock code
        printf '%s' "$1" | python3 -c 'import json,sys
x=json.load(sys.stdin); trigger=sys.argv[1]; due={"true":True,"false":False,"null":None}[sys.argv[2]]; lock=sys.argv[3]=="true"; code=sys.argv[4]
counters=["claims_scanned","claims_skipped","transactions_advanced","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","receipts_anchored"]
roots=["blocked_claims_known","owned_bytes_before","owned_bytes_after","high_water","hard_water","next_gc_epoch"]
err=x.get("error"); ok=(x.get("trigger")==trigger and x.get("due") is due and x.get("lock_acquired") is lock and
 all(type(x.get(k)) is int and x[k]==0 for k in counters) and all(x.get(k) is None for k in roots))
if code=="pending": ok=ok and x.get("ok") is True and x.get("state")=="pending" and err is None
else: ok=ok and x.get("ok") is False and x.get("state")=="blocked" and isinstance(err,dict) and err.get("code")==code
raise SystemExit(0 if ok else 1)' "$2" "$3" "$4" "$5"
    }
    if [ "$t29_code" = genesis-capability-unavailable ]; then
        skip "T29 pre-snapshot matrix requires supported GENESIS/lock capability" "$t29_seed"
    elif [ "$t29_seed_rc" -ne 0 ] || [ -z "$t29_container" ]; then
        fail "T29 pre-snapshot fixture reaches canonical GENESIS" "rc=$t29_seed_rc out=$t29_seed"
    else
        t29_lock="$t29_container/.catalog-lock.v1"; t29_ready="$t29/lock.ready"
        python3 -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1],os.O_RDWR); fcntl.flock(fd,fcntl.LOCK_EX); open(sys.argv[2],"w").write("ready\n"); time.sleep(20)' "$t29_lock" "$t29_ready" &
        t29_holder=$!; t29_i=0
        while [ ! -s "$t29_ready" ] && [ "$t29_i" -lt 100 ]; do sleep 0.02; t29_i=$((t29_i+1)); done
        t29_before="$(t29_tree_digest "$t29_container")"
        t29_manual="$(ZYZ_AGENT_LOCK_ACQUIRE_SEC=1 bash hooks/scripts/agent-runtime-state.sh gc-step "$t29_task" manual 2>/dev/null)"; t29_manual_rc=$?
        t29_watch="$(ZYZ_AGENT_LOCK_ACQUIRE_SEC=1 bash hooks/scripts/agent-runtime-state.sh gc-step "$t29_task" watchdog 2>/dev/null)"; t29_watch_rc=$?
        t29_after="$(t29_tree_digest "$t29_container")"
        kill "$t29_holder" 2>/dev/null || true; wait "$t29_holder" 2>/dev/null || true
        if [ "$t29_manual_rc" -eq 3 ] && t29_matrix "$t29_manual" manual true false pending \
            && [ "$t29_before" = "$t29_after" ]; then
            pass "T29 manual lock timeout preserves due=true and all unknown ROOT fields"
        else
            fail "T29 manual lock timeout preserves due=true and all unknown ROOT fields" "rc=$t29_manual_rc before=$t29_before after=$t29_after out=$t29_manual"
        fi
        if [ "$t29_watch_rc" -eq 3 ] && t29_matrix "$t29_watch" watchdog null false pending \
            && [ "$t29_before" = "$t29_after" ]; then
            pass "T29 watchdog lock timeout preserves due=null instead of false"
        else
            fail "T29 watchdog lock timeout preserves due=null instead of false" "rc=$t29_watch_rc before=$t29_before after=$t29_after out=$t29_watch"
        fi

        # A non-regular persistent lock carrier makes the capability unavailable
        # before lock acquisition.  The original carrier is outside the catalog
        # container for this disposable fixture and is never restored in place.
        mv "$t29_lock" "$t29/lock.original"; mkdir "$t29_lock"
        t29_before="$(t29_tree_digest "$t29_container")"
        t29_cap="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t29_task" system-timer 2>/dev/null)"; t29_cap_rc=$?
        t29_after="$(t29_tree_digest "$t29_container")"
        if [ "$t29_cap_rc" -eq 4 ] && t29_matrix "$t29_cap" system-timer true false catalog-lock-capability-unavailable \
            && [ "$t29_before" = "$t29_after" ]; then
            pass "T29 invalid persistent lock carrier is pre-snapshot capability-blocked with zero effect"
        else
            fail "T29 invalid persistent lock carrier is pre-snapshot capability-blocked with zero effect" "rc=$t29_cap_rc before=$t29_before after=$t29_after out=$t29_cap"
        fi
        rmdir "$t29_lock"; mv "$t29/lock.original" "$t29_lock"

        # Corrupt the SCHEDULE image selected by the highest valid ROOT.  The
        # public validator must stop before snapshot/effect and must not repair
        # or rewrite the corrupt byte.  A fixed A offset would silently damage
        # the inactive bank after the seed pass and test the opposite rule.
        t29_global="$t29_container/.catalog-global-pack.v1"
        python3 -c 'import json,os,struct,sys
p=sys.argv[1];f=open(p,"r+b",buffering=0);roots=[]
for off in (32768,98304):
 f.seek(off);raw=f.read(65536)
 if any(raw):
  generation=struct.unpack_from(">Q",raw,12)[0];length=struct.unpack_from(">I",raw,20)[0];meta=json.loads(raw[128:128+length]);roots.append((generation,meta))
bank=max(roots,key=lambda item:item[0])[1]["schedule_bank"];off=24576+bank*4096;f.seek(off);b=f.read(1);f.seek(off);f.write(bytes([b[0]^1]));os.fsync(f.fileno());f.close()' "$t29_global"
        t29_before="$(t29_tree_digest "$t29_container")"
        t29_corrupt="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t29_task" lifecycle 2>/dev/null)"; t29_corrupt_rc=$?
        t29_after="$(t29_tree_digest "$t29_container")"
        if [ "$t29_corrupt_rc" -eq 4 ] && t29_matrix "$t29_corrupt" lifecycle null true catalog-root-invalid \
            && [ "$t29_before" = "$t29_after" ]; then
            pass "T29 corrupt active SCHEDULE is catalog-root-invalid and byte-zero-effect"
        else
            fail "T29 corrupt active SCHEDULE is catalog-root-invalid and byte-zero-effect" "rc=$t29_corrupt_rc before=$t29_before after=$t29_after out=$t29_corrupt"
        fi
    fi
    rm -rf "$t29"
else
    skip "T29 public pre-snapshot/A-B matrix (no JSON tool or CLI)"
fi

# ---------------------------------------------------------------------------
# T30  GENESIS FREE_RECEIPT hash domains and last-cell aggregate coverage.
# Literal vectors below were generated once from the approved schema, then
# frozen here; the oracle does not import production helpers.  Physical faults
# are applied to real packs and observed only through the public gc-step CLI.
# ---------------------------------------------------------------------------
if json_tool && [ -x hooks/scripts/agent-runtime-state.sh ]; then
    t30_seed() { # task-dir output-file
        mkdir -p "$1/runtime"
        t30_seed_i=0; t30_seed_rc=3
        while [ "$t30_seed_i" -lt 16 ] && [ "$t30_seed_rc" -eq 3 ]; do
            bash hooks/scripts/agent-runtime-state.sh gc-step "$1" manual >"$2" 2>/dev/null
            t30_seed_rc=$?; t30_seed_i=$((t30_seed_i+1))
        done
        return "$t30_seed_rc"
    }
    t30_tree_digest() {
        find "$1" -type f -exec shasum -a 256 {} \; 2>/dev/null | sort | shasum -a 256 | awk '{print $1}'
    }
    t30_blocked_contract() { # json
        printf '%s' "$1" | python3 -c 'import json,sys
x=json.load(sys.stdin); err=x.get("error")
counters=["claims_scanned","claims_skipped","transactions_advanced","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","receipts_anchored"]
roots=["blocked_claims_known","owned_bytes_before","owned_bytes_after","high_water","hard_water","next_gc_epoch"]
ok=(x.get("ok") is False and x.get("state")=="blocked" and isinstance(err,dict) and
 err.get("code")=="catalog-root-invalid" and err.get("retryable") is False and
 x.get("trigger")=="manual" and x.get("due") is True and x.get("lock_acquired") is True and
 all(type(x.get(k)) is int and x[k]==0 for k in counters) and all(x.get(k) is None for k in roots))
raise SystemExit(0 if ok else 1)'
    }

    t30="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t30.XXXXXX")"; t30_task="$t30/task"
    t30_seed "$t30_task" "$t30/seed.out"; t30_rc=$?; t30_out="$(cat "$t30/seed.out" 2>/dev/null)"
    t30_code="$(printf '%s' "$t30_out" | python3 -c 'import json,sys;x=json.load(sys.stdin);print((x.get("error") or {}).get("code",""))' 2>/dev/null)"
    t30_container="$(find "$t30_task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    if [ "$t30_code" = genesis-capability-unavailable ]; then
        skip "T30 FREE_RECEIPT vectors require supported durable GENESIS capability" "$t30_out"
        t30_supported=0
    elif [ "$t30_rc" -eq 0 ] && [ -n "$t30_container" ] && python3 -c 'import hashlib,os,struct,sys
p=sys.argv[1]; g=open(os.path.join(p,".catalog-global-pack.v1"),"rb").read(); r=open(os.path.join(p,".catalog-recovery-pack.v1"),"rb").read()
vectors={
0:("5a595a43465631000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000","1b4855851278d84402e46dba8f164300b8da971330ad356433529375f1f186ef","8cbf9533756aff1c15a549789985f9b3e0c0a71eba14ea2ec7a268db91817140","6a39053d61b90be0cbff8b2e5415f5102581d3d980e16c98f921197e389d36f3","2d97930f497b32bdc21fc4aa1d4a3a04925fe2090aab11a4ae35ec92fbacd5a2"),
4095:("5a595a43465631000001000000000fff000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000","c12c816b5de310ecdb850f2d6dc7a35813bae7bcc17b3e35150b9641518efcb7","b7822d9d85b1118cd13c321475a20dfab1516930f9eaa045dd13bc6686f0656c","b301bfafb6e8c2ce60a89ff8249164170bedc6b8f6ca11d1128d37834e40899c","9019bee49af8045640c5e8b73d4bc139230028d319f3ed75f37fbf6af347f800"),
8191:("5a595a43465631000001000000001fff000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000","3a340da6d0d01b7f97ecdf5c325fb9a43f1ec16b1108471ff21b79cfc2ba2761","f72023db642c99ca079e2e4f431a0c4d1816e30d2f798b7188f4530000b49caa","914e88bb5a69021ef7d17ed16304f09c0893d3d9801f1ae9344984af070191ec","1c4c26363a937cace46052772c92ee17a27ea0d24deb72f65b9fd3788f639061")}
D=lambda d,v:hashlib.sha256(d+v).digest()
for i,(core_hex,core_d_hex,body_d_hex,final_d_hex,record_d_hex) in vectors.items():
 z=bytes(32); core=struct.pack(">8sHHIQQ32s",b"ZYZCFV1\0",1,0,i,0,0,z)
 core_d=D(b"zyz-cell-free-core-v1",core); body=struct.pack(">8sB7xIQ",b"ZYZFRB1\0",0,i,0)+z+z+z+core_d
 body_d=D(b"zyz-free-receipt-body-v1",body); final_d=D(b"zyz-final-cell-image-v1",core+body_d)
 record_d=D(b"zyz-free-receipt-record-v1",body+body_d+final_d)
 if (core.hex(),core_d.hex(),body_d.hex(),final_d.hex(),record_d.hex()) != (core_hex,core_d_hex,body_d_hex,final_d_hex,record_d_hex): raise SystemExit(1)
 cell=r[i*1024:i*1024+512]; inactive=r[i*1024+512:(i+1)*1024]
 src=bytearray(cell); src[32:64]=bytes(32)
 if (cell[0:8]!=b"ZYZRCV1\0" or struct.unpack_from(">HHIQQ",cell,8)!=(1,0,i,0,0) or
     cell[32:64]!=D(b"zyz-recovery-cell-image-v1",bytes(src)) or cell[64:128]!=core or
     cell[128:160]!=core_d or cell[160:192]!=body_d or cell[192:224]!=final_d or any(cell[224:]) or any(inactive)): raise SystemExit(1)
 cell_image_d=D(b"zyz-recovery-cell-selected-v1",cell)
 wrong_field2=(final_d,D(b"zyz-recovery-cell-selected-v1",inactive),
               D(b"zyz-cell-free-core-v1",cell),D(b"zyz-free-receipt-body-v1",cell),
               D(b"zyz-final-cell-image-v1",cell),D(b"zyz-free-receipt-record-v1",cell))
 if cell_image_d in wrong_field2: raise SystemExit(1)
 entry=g[163840+i*192:163840+(i+1)*192]; inactive_entry=g[1736704+i*192:1736704+(i+1)*192]
 es=bytearray(entry); es[16:32]=bytes(16)
 if (entry[0:4]!=b"ZCD1" or struct.unpack_from(">BBHIHH",entry,4)!=(1,0,0,i,0,0) or
     entry[16:32]!=D(b"zyz-cell-directory-image-v1",bytes(es))[:16] or entry[32:64]!=z or
     entry[64:96]!=cell_image_d or entry[96:128]!=record_d or entry[128:160]!=z or
     entry[160:192]!=body_d or any(inactive_entry)): raise SystemExit(1)
' "$t30_container"; then
        pass "T30 GENESIS four-domain golden vectors match physical CELL/receipt bytes 0/4095/8191"
        t30_supported=1
    else
        fail "T30 GENESIS four-domain golden vectors match physical CELL/receipt bytes 0/4095/8191" "rc=$t30_rc out=$t30_out"
        t30_supported=0
    fi
    rm -rf "$t30"

    if [ "$t30_supported" -eq 1 ]; then
        # A one-byte fault in the final selected recovery cell must be seen by
        # the whole-pack validator; sampling the earlier cells is insufficient.
        t30="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t30-last.XXXXXX")"; t30_task="$t30/task"
        t30_seed "$t30_task" "$t30/seed.out"; t30_container="$(find "$t30_task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        python3 -c 'import os,sys
p=os.path.join(sys.argv[1],".catalog-recovery-pack.v1");f=open(p,"r+b",buffering=0);f.seek(8191*1024+160);b=f.read(1);f.seek(8191*1024+160);f.write(bytes([b[0]^1]));os.fsync(f.fileno());f.close()' "$t30_container"
        t30_before="$(t30_tree_digest "$t30_container")"
        t30_bad="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t30_task" manual 2>/dev/null)"; t30_bad_rc=$?
        t30_after="$(t30_tree_digest "$t30_container")"
        if [ "$t30_bad_rc" -eq 4 ] && t30_blocked_contract "$t30_bad" && [ "$t30_before" = "$t30_after" ]; then
            pass "T30 final selected recovery CELL corruption is blocked before effect"
        else
            fail "T30 final selected recovery CELL corruption is blocked before effect" "rc=$t30_bad_rc before=$t30_before after=$t30_after out=$t30_bad"
        fi
        rm -rf "$t30"

        # Make the last CELL_DIRECTORY entry structurally checksummed but put
        # body_digest in its record_digest field.  Rebind the independent whole-
        # directory aggregate, selected ROOT and PACK_HEADER, so only the four-
        # domain semantic validator can reject the fixed-point/domain collapse.
        t30="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t30-domain.XXXXXX")"; t30_task="$t30/task"
        t30_seed "$t30_task" "$t30/seed.out"; t30_container="$(find "$t30_task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        python3 -c 'import hashlib,json,os,struct,sys
p=os.path.join(sys.argv[1],".catalog-global-pack.v1"); raw=bytearray(open(p,"rb").read()); D=lambda d,v:hashlib.sha256(d+v).digest()
off=163840+8191*192; entry=bytearray(raw[off:off+192]); entry[96:128]=entry[160:192]; entry[16:32]=bytes(16); entry[16:32]=D(b"zyz-cell-directory-image-v1",bytes(entry))[:16]; raw[off:off+192]=entry
h=hashlib.sha256(b"zyz-cell-directory-selected-v1")
for i in range(8192): h.update(struct.pack(">IB",i,0)); h.update(raw[163840+i*192:163840+(i+1)*192])
def parse(image):
 schema,flags,generation,length=struct.unpack_from(">HHQI",image,8); return generation,json.loads(image[128:128+length]),image[24:56]
def build(magic,size,generation,pred,meta,tail=b""):
 enc=json.dumps(meta,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode(); out=bytearray(size); out[0:8]=magic.ljust(8,b"\0"); struct.pack_into(">HHQI",out,8,1,0,generation,len(enc)); out[24:56]=pred; out[96:128]=D(b"zyz-pack-payload-v1",enc); out[128:128+len(enc)]=enc
 if tail: out[4096:]=tail
 out[56:88]=D(b"zyz-pack-image-v1",bytes(out)); return bytes(out)
roots=[bytes(raw[32768:98304]),bytes(raw[98304:163840])]; rb=max(range(2),key=lambda b:parse(roots[b])[0] if any(roots[b]) else -1); gen,meta,pred=parse(roots[rb]); meta["directory_sha256"]=h.hexdigest(); root=build(b"ZYZROOT1",65536,gen,pred,meta,roots[rb][4096:]); raw[32768+rb*65536:32768+(rb+1)*65536]=root
headers=[bytes(raw[0:4096]),bytes(raw[4096:8192])]; hb=max(range(2),key=lambda b:parse(headers[b])[0] if any(headers[b]) else -1); hgen,hmeta,hpred=parse(headers[hb]); hmeta["root_digest"]=D(b"zyz-pack-image-id-v1",root).hex(); header=build(b"ZYZPACK1",4096,hgen,hpred,hmeta); raw[hb*4096:(hb+1)*4096]=header
f=open(p,"r+b",buffering=0);f.write(raw);os.fsync(f.fileno());f.close()' "$t30_container"
        t30_before="$(t30_tree_digest "$t30_container")"
        t30_bad="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t30_task" manual 2>/dev/null)"; t30_bad_rc=$?
        t30_after="$(t30_tree_digest "$t30_container")"
        if [ "$t30_bad_rc" -eq 4 ] && t30_blocked_contract "$t30_bad" && [ "$t30_before" = "$t30_after" ]; then
            pass "T30 checksummed body-digest-as-record-digest is rejected after aggregate rebinding"
        else
            fail "T30 checksummed body-digest-as-record-digest is rejected after aggregate rebinding" "rc=$t30_bad_rc before=$t30_before after=$t30_after out=$t30_bad"
        fi
        rm -rf "$t30"

        # A torn non-authoritative recovery image cannot poison a valid A image.
        # The invocation is automatic and immediately after a completed manual
        # pass, so due=false and exact pack byte identity is the positive oracle.
        t30="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t30-inactive.XXXXXX")"; t30_task="$t30/task"
        t30_seed "$t30_task" "$t30/seed.out"; t30_container="$(find "$t30_task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        python3 -c 'import os,sys
p=os.path.join(sys.argv[1],".catalog-recovery-pack.v1");f=open(p,"r+b",buffering=0);f.seek(8191*1024+512+7);f.write(b"X");os.fsync(f.fileno());f.close()' "$t30_container"
        t30_before="$(t30_tree_digest "$t30_container")"
        t30_inactive="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t30_task" watchdog 2>/dev/null)"; t30_inactive_rc=$?
        t30_after="$(t30_tree_digest "$t30_container")"
        if [ "$t30_inactive_rc" -eq 0 ] && [ "$t30_before" = "$t30_after" ] && printf '%s' "$t30_inactive" | python3 -c 'import json,sys
x=json.load(sys.stdin);raise SystemExit(0 if x.get("ok") is True and x.get("state")=="idle" and x.get("trigger")=="watchdog" and x.get("due") is False and x.get("lock_acquired") is True and x.get("transactions_advanced")==0 else 1)'; then
            pass "T30 torn inactive last recovery image cannot poison selected CELL A"
        else
            fail "T30 torn inactive last recovery image cannot poison selected CELL A" "rc=$t30_inactive_rc before=$t30_before after=$t30_after out=$t30_inactive"
        fi
        rm -rf "$t30"
    fi
else
    skip "T30 FREE_RECEIPT physical vectors/corruption (no JSON tool or CLI)"
fi

# ---------------------------------------------------------------------------
# T31  SCHEDULE/ROOT A/B crash boundaries and semantic state selection.  Every
# case begins at an empty real task, uses the public gc-step entry, and inspects
# the native global pack.  No production fixture loader or result selftest is
# used.  Equal-time and wall-clock rollback require a controllable native clock
# seam and remain explicitly outside this local observation point.
# ---------------------------------------------------------------------------
if json_tool && [ -x hooks/scripts/agent-runtime-state.sh ]; then
    t31_tree_digest() {
        find "$1" -type f -exec shasum -a 256 {} \; 2>/dev/null | sort | shasum -a 256 | awk '{print $1}'
    }
    t31_success_contract() { # json trigger due advanced
        printf '%s' "$1" | python3 -c 'import json,sys
x=json.load(sys.stdin); trigger=sys.argv[1]; due=sys.argv[2]=="true"; advanced=int(sys.argv[3])
ok=(x.get("ok") is True and x.get("state")=="idle" and x.get("error") is None and
 x.get("trigger")==trigger and x.get("due") is due and x.get("lock_acquired") is True and
 x.get("transactions_advanced")==advanced and x.get("owned_bytes_before")==33554432 and
 x.get("owned_bytes_after")==33554432 and x.get("high_water")==536870912 and
 x.get("hard_water")==1073741824 and type(x.get("next_gc_epoch")) is int)
raise SystemExit(0 if ok else 1)' "$2" "$3" "$4"
    }
    t31_blocked_contract() { # json
        printf '%s' "$1" | python3 -c 'import json,sys
x=json.load(sys.stdin); err=x.get("error")
counters=["claims_scanned","claims_skipped","transactions_advanced","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","receipts_anchored"]
roots=["blocked_claims_known","owned_bytes_before","owned_bytes_after","high_water","hard_water","next_gc_epoch"]
ok=(x.get("ok") is False and x.get("state")=="blocked" and isinstance(err,dict) and
 err.get("code")=="catalog-root-invalid" and err.get("retryable") is False and
 x.get("trigger")=="manual" and x.get("due") is True and x.get("lock_acquired") is True and
 all(type(x.get(k)) is int and x[k]==0 for k in counters) and all(x.get(k) is None for k in roots))
raise SystemExit(0 if ok else 1)'
    }

    # Kill after the inactive SCHEDULE successor is durable but before ROOT
    # selects it.  Damage that non-authoritative bank, then require lifecycle
    # recovery to select the intact UNINITIALIZED A image and commit a new pair.
    t31="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t31-schedule.XXXXXX")"; t31_task="$t31/task"; mkdir -p "$t31_task/runtime"
    ZYZ_TEST_TRANSITION_STOP_AFTER="gc-step:schedule" \
        bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" manual >"$t31/kill.out" 2>/dev/null
    t31_kill_rc=$?; t31_kill_out="$(cat "$t31/kill.out" 2>/dev/null)"
    t31_code="$(printf '%s' "$t31_kill_out" | python3 -c 'import json,sys
try:x=json.load(sys.stdin);print((x.get("error") or {}).get("code",""))
except Exception:print("")' 2>/dev/null)"
    t31_container="$(find "$t31_task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    if [ "$t31_code" = genesis-capability-unavailable ]; then
        skip "T31 SCHEDULE/ROOT boundaries require supported durable GENESIS capability" "$t31_kill_out"
        t31_supported=0
    elif [ "$t31_kill_rc" -eq 86 ] && [ -n "$t31_container" ] && python3 -c 'import os,sys
g=open(os.path.join(sys.argv[1],".catalog-global-pack.v1"),"rb").read()
raise SystemExit(0 if any(g[24576:28672]) and any(g[28672:32768]) and any(g[32768:98304]) and not any(g[98304:163840]) else 1)' "$t31_container"; then
        python3 -c 'import os,sys
p=os.path.join(sys.argv[1],".catalog-global-pack.v1");f=open(p,"r+b",buffering=0);f.seek(28672+56);b=f.read(1);f.seek(28672+56);f.write(bytes([b[0]^1]));os.fsync(f.fileno());f.close()' "$t31_container"
        t31_resume="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" lifecycle 2>/dev/null)"; t31_resume_rc=$?
        if [ "$t31_resume_rc" -eq 0 ] && t31_success_contract "$t31_resume" lifecycle true 1; then
            pass "T31 torn inactive SCHEDULE after schedule-durable boundary cannot poison active UNINITIALIZED A"
            t31_supported=1
        else
            fail "T31 torn inactive SCHEDULE after schedule-durable boundary cannot poison active UNINITIALIZED A" "kill_rc=$t31_kill_rc resume_rc=$t31_resume_rc out=$t31_resume"
            t31_supported=0
        fi
    else
        fail "T31 gc-step schedule-durable barrier exposes exact ROOT-old/SCHEDULE-new prior" "kill_rc=$t31_kill_rc out=$t31_kill_out"
        t31_supported=0
    fi
    rm -rf "$t31"

    if [ "$t31_supported" -eq 1 ]; then
        # Kill after ROOT selects the durable successor.  A fresh automatic
        # invocation must consume that exact after-set, observe strict future,
        # and perform no pack mutation.
        t31="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t31-root.XXXXXX")"; t31_task="$t31/task"; mkdir -p "$t31_task/runtime"
        ZYZ_TEST_TRANSITION_STOP_AFTER="catalog-root:root-successor-durable" \
            bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" manual >"$t31/kill.out" 2>/dev/null
        t31_kill_rc=$?; t31_container="$(find "$t31_task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t31_prior_ok=0
        if [ "$t31_kill_rc" -eq 86 ] && [ -n "$t31_container" ] && python3 -c 'import os,sys
g=open(os.path.join(sys.argv[1],".catalog-global-pack.v1"),"rb").read()
raise SystemExit(0 if any(g[24576:28672]) and any(g[28672:32768]) and any(g[32768:98304]) and any(g[98304:163840]) else 1)' "$t31_container"; then t31_prior_ok=1; fi
        t31_before="$(t31_tree_digest "$t31_container")"
        t31_resume="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" watchdog 2>/dev/null)"; t31_resume_rc=$?
        t31_after="$(t31_tree_digest "$t31_container")"
        if [ "$t31_prior_ok" -eq 1 ] && [ "$t31_resume_rc" -eq 0 ] && [ "$t31_before" = "$t31_after" ] \
            && t31_success_contract "$t31_resume" watchdog false 0; then
            pass "T31 ROOT-successor-durable crash resumes selected strict-future pair with zero effect"
        else
            fail "T31 ROOT-successor-durable crash resumes selected strict-future pair with zero effect" "kill_rc=$t31_kill_rc prior=$t31_prior_ok resume_rc=$t31_resume_rc before=$t31_before after=$t31_after out=$t31_resume"
        fi
        rm -rf "$t31"

        # The fixed-clock seam is validated before any GENESIS/runtime effect.
        # It lets this matrix distinguish strict future, exact equality, past,
        # and wall-clock rollback without sleep or scheduler jitter.
        t31="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t31-clock.XXXXXX")"; t31_task="$t31/task"; mkdir -p "$t31_task/runtime"
        t31_seed="$(ZYZ_TEST_GC_NOW_EPOCH=1000 bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" manual 2>/dev/null)"; t31_seed_rc=$?
        t31_container="$(find "$t31_task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t31_before="$(t31_tree_digest "$t31_container")"
        t31_future="$(ZYZ_TEST_GC_NOW_EPOCH=1299 bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" watchdog 2>/dev/null)"; t31_future_rc=$?
        t31_after="$(t31_tree_digest "$t31_container")"
        if [ "$t31_seed_rc" -eq 0 ] && [ "$t31_future_rc" -eq 0 ] && [ "$t31_before" = "$t31_after" ] \
            && t31_success_contract "$t31_future" watchdog false 0 && printf '%s' "$t31_future" | python3 -c 'import json,sys;raise SystemExit(0 if json.load(sys.stdin).get("next_gc_epoch")==1300 else 1)'; then
            pass "T31 fixed-clock strict-future SCHEDULE is not due and is byte-zero-effect"
        else
            fail "T31 fixed-clock strict-future SCHEDULE is not due and is byte-zero-effect" "seed_rc=$t31_seed_rc rc=$t31_future_rc before=$t31_before after=$t31_after out=$t31_future"
        fi
        t31_equal="$(ZYZ_TEST_GC_NOW_EPOCH=1300 bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" watchdog 2>/dev/null)"; t31_equal_rc=$?
        if [ "$t31_equal_rc" -eq 0 ] && t31_success_contract "$t31_equal" watchdog true 1 \
            && printf '%s' "$t31_equal" | python3 -c 'import json,sys;raise SystemExit(0 if json.load(sys.stdin).get("next_gc_epoch")==1600 else 1)'; then
            pass "T31 fixed-clock exact-equal SCHEDULE is due and commits strict-future successor"
        else
            fail "T31 fixed-clock exact-equal SCHEDULE is due and commits strict-future successor" "rc=$t31_equal_rc out=$t31_equal"
        fi
        rm -rf "$t31"

        t31="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t31-past.XXXXXX")"; t31_task="$t31/task"; mkdir -p "$t31_task/runtime"
        t31_seed="$(ZYZ_TEST_GC_NOW_EPOCH=1000 bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" manual 2>/dev/null)"; t31_seed_rc=$?
        t31_past="$(ZYZ_TEST_GC_NOW_EPOCH=1301 bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" watchdog 2>/dev/null)"; t31_past_rc=$?
        if [ "$t31_seed_rc" -eq 0 ] && [ "$t31_past_rc" -eq 0 ] && t31_success_contract "$t31_past" watchdog true 1 \
            && printf '%s' "$t31_past" | python3 -c 'import json,sys;raise SystemExit(0 if json.load(sys.stdin).get("next_gc_epoch")==1601 else 1)'; then
            pass "T31 fixed-clock past SCHEDULE is due and commits strict-future successor"
        else
            fail "T31 fixed-clock past SCHEDULE is due and commits strict-future successor" "seed_rc=$t31_seed_rc past_rc=$t31_past_rc out=$t31_past"
        fi
        rm -rf "$t31"

        t31="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t31-rollback.XXXXXX")"; t31_task="$t31/task"; mkdir -p "$t31_task/runtime"
        t31_seed="$(ZYZ_TEST_GC_NOW_EPOCH=2000 bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" manual 2>/dev/null)"; t31_seed_rc=$?
        t31_container="$(find "$t31_task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"; t31_before="$(t31_tree_digest "$t31_container")"
        t31_rollback="$(ZYZ_TEST_GC_NOW_EPOCH=1500 bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" watchdog 2>/dev/null)"; t31_rollback_rc=$?
        t31_after="$(t31_tree_digest "$t31_container")"
        if [ "$t31_seed_rc" -eq 0 ] && [ "$t31_rollback_rc" -eq 0 ] && [ "$t31_before" = "$t31_after" ] \
            && t31_success_contract "$t31_rollback" watchdog false 0 && printf '%s' "$t31_rollback" | python3 -c 'import json,sys;raise SystemExit(0 if json.load(sys.stdin).get("next_gc_epoch")==2300 else 1)'; then
            pass "T31 wall-clock rollback preserves valid future SCHEDULE without corruption or effect"
        else
            fail "T31 wall-clock rollback preserves valid future SCHEDULE without corruption or effect" "seed_rc=$t31_seed_rc rc=$t31_rollback_rc before=$t31_before after=$t31_after out=$t31_rollback"
        fi
        rm -rf "$t31"

        # Rebuild a selected SCHEDULE as a checksummed but semantically invalid
        # SCHEDULED image (next_gc_epoch=null), then rebind ROOT and PACK_HEADER.
        # The public validator must reject semantics before entry snapshot; a
        # checksum-only implementation would otherwise report automatic idle.
        t31="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t31-semantic.XXXXXX")"; t31_task="$t31/task"; mkdir -p "$t31_task/runtime"
        t31_seed="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" manual 2>/dev/null)"; t31_seed_rc=$?
        t31_container="$(find "$t31_task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        python3 -c 'import hashlib,json,os,struct,sys
p=os.path.join(sys.argv[1],".catalog-global-pack.v1"); raw=bytearray(open(p,"rb").read()); D=lambda d,v:hashlib.sha256(d+v).digest()
def parse(image):
 schema,flags,generation,length=struct.unpack_from(">HHQI",image,8); return generation,json.loads(image[128:128+length]),image[24:56]
def build(magic,size,generation,pred,meta,tail=b""):
 enc=json.dumps(meta,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode(); out=bytearray(size); out[0:8]=magic.ljust(8,b"\0"); struct.pack_into(">HHQI",out,8,1,0,generation,len(enc)); out[24:56]=pred; out[96:128]=D(b"zyz-pack-payload-v1",enc); out[128:128+len(enc)]=enc
 if tail: out[4096:]=tail
 out[56:88]=D(b"zyz-pack-image-v1",bytes(out)); return bytes(out)
roots=[bytes(raw[32768:98304]),bytes(raw[98304:163840])]; rb=max(range(2),key=lambda b:parse(roots[b])[0] if any(roots[b]) else -1); rgen,rmeta,rpred=parse(roots[rb]); sb=rmeta["schedule_bank"]
schedules=[bytes(raw[24576:28672]),bytes(raw[28672:32768])]; sgen,smeta,spred=parse(schedules[sb]); smeta["next_gc_epoch"]=None; schedule=build(b"ZYZSCH1",4096,sgen,spred,smeta); raw[24576+sb*4096:24576+(sb+1)*4096]=schedule
rmeta["schedule_digest"]=D(b"zyz-pack-image-id-v1",schedule).hex(); root=build(b"ZYZROOT1",65536,rgen,rpred,rmeta,roots[rb][4096:]); raw[32768+rb*65536:32768+(rb+1)*65536]=root
headers=[bytes(raw[0:4096]),bytes(raw[4096:8192])]; hb=max(range(2),key=lambda b:parse(headers[b])[0] if any(headers[b]) else -1); hgen,hmeta,hpred=parse(headers[hb]); hmeta["root_digest"]=D(b"zyz-pack-image-id-v1",root).hex(); raw[hb*4096:(hb+1)*4096]=build(b"ZYZPACK1",4096,hgen,hpred,hmeta)
f=open(p,"r+b",buffering=0);f.write(raw);os.fsync(f.fileno());f.close()' "$t31_container"
        t31_before="$(t31_tree_digest "$t31_container")"
        t31_bad="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" manual 2>/dev/null)"; t31_bad_rc=$?
        t31_after="$(t31_tree_digest "$t31_container")"
        if [ "$t31_seed_rc" -eq 0 ] && [ "$t31_bad_rc" -eq 4 ] && [ "$t31_before" = "$t31_after" ] && t31_blocked_contract "$t31_bad"; then
            pass "T31 checksummed active SCHEDULE semantic corruption is pre-snapshot blocked"
        else
            fail "T31 checksummed active SCHEDULE semantic corruption is pre-snapshot blocked" "seed_rc=$t31_seed_rc rc=$t31_bad_rc before=$t31_before after=$t31_after out=$t31_bad"
        fi
        rm -rf "$t31"

        # Interval zero disables automatic scheduling even at a GENESIS
        # UNINITIALIZED schedule.  It is a real bootstrap, not a canned state.
        t31="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t31-disabled.XXXXXX")"; t31_task="$t31/task"; mkdir -p "$t31_task/runtime"
        t31_disabled="$(ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 bash hooks/scripts/agent-runtime-state.sh gc-step "$t31_task" watchdog 2>/dev/null)"; t31_disabled_rc=$?
        if [ "$t31_disabled_rc" -eq 0 ] && printf '%s' "$t31_disabled" | python3 -c 'import json,sys
x=json.load(sys.stdin);ok=(x.get("ok") is True and x.get("state")=="idle" and x.get("trigger")=="watchdog" and x.get("due") is False and x.get("lock_acquired") is True and x.get("transactions_advanced")==0 and x.get("next_gc_epoch") is None and x.get("owned_bytes_before")==33554432 and x.get("owned_bytes_after")==33554432);raise SystemExit(0 if ok else 1)'; then
            pass "T31 interval zero keeps real GENESIS UNINITIALIZED automatic schedule disabled"
        else
            fail "T31 interval zero keeps real GENESIS UNINITIALIZED automatic schedule disabled" "rc=$t31_disabled_rc out=$t31_disabled"
        fi
        rm -rf "$t31"
    fi
else
    skip "T31 SCHEDULE/ROOT public A-B matrix (no JSON tool or CLI)"
fi

# ---------------------------------------------------------------------------
# T32  Public GC watermark-pair parsing.  High/hard are one semantic value:
# any invalid member or relationship resets both defaults and emits one pair
# diagnostic.  The real gc-step output is the oracle; config-status/selftest is
# not accepted as evidence for the public consumer.
# ---------------------------------------------------------------------------
if json_tool && [ -x hooks/scripts/agent-runtime-state.sh ]; then
    t32="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t32-probe.XXXXXX")"; t32_task="$t32/task"; mkdir -p "$t32_task/runtime"
    t32_seed="$(bash hooks/scripts/agent-runtime-state.sh gc-step "$t32_task" manual 2>"$t32/seed.err")"; t32_seed_rc=$?
    t32_code="$(printf '%s' "$t32_seed" | python3 -c 'import json,sys;x=json.load(sys.stdin);print((x.get("error") or {}).get("code",""))' 2>/dev/null)"
    t32_contract() { # json expected-state expected-high expected-hard null|future call-start-epoch
        printf '%s' "$1" | python3 -c 'import json,sys
x=json.load(sys.stdin);state=sys.argv[1];high=int(sys.argv[2]);hard=int(sys.argv[3]);schedule=sys.argv[4];started=int(sys.argv[5])
counters=["claims_scanned","claims_skipped","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","receipts_anchored"]
ok=(x.get("ok") is True and x.get("state")==state and x.get("error") is None and
 x.get("trigger")=="manual" and x.get("due") is True and x.get("lock_acquired") is True and
 x.get("transactions_advanced")==1 and x.get("blocked_claims_known")==0 and
 all(type(x.get(name)) is int and x.get(name)==0 for name in counters) and
 x.get("owned_bytes_before")==33554432 and x.get("owned_bytes_after")==33554432 and
 x.get("high_water")==high and x.get("hard_water")==hard and
 ((schedule=="null" and x.get("next_gc_epoch") is None) or
  (schedule=="future" and type(x.get("next_gc_epoch")) is int and x.get("next_gc_epoch")>started)))
raise SystemExit(0 if ok else 1)' "$2" "$3" "$4" "$5" "$6"
    }
    t32_pair() { # label high-input hard-input want-high want-hard valid|fallback rc state schedule
        t32_label="$1"; t32_high="$2"; t32_hard="$3"; t32_want_high="$4"; t32_want_hard="$5"; t32_kind="$6"
        t32_want_rc="$7"; t32_want_state="$8"; t32_want_schedule="$9"
        t32_case="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t32-case.XXXXXX")"; t32_case_task="$t32_case/task"; mkdir -p "$t32_case_task/runtime"
        t32_case_started="$(date +%s)"
        t32_out="$(ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES="$t32_high" ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES="$t32_hard" \
            bash hooks/scripts/agent-runtime-state.sh gc-step "$t32_case_task" manual 2>"$t32_case/case.err")"; t32_rc=$?
        t32_diag_count="$(grep -c 'invalid snapshot GC watermark pair; using defaults' "$t32_case/case.err" 2>/dev/null || true)"
        t32_stderr_lines="$(sed '/^$/d' "$t32_case/case.err" | wc -l | tr -d ' ')"
        if [ "$t32_kind" = valid ]; then
            t32_diag_ok=$((t32_diag_count == 0 && t32_stderr_lines == 0))
        else
            t32_diag_ok=$((t32_diag_count == 1 && t32_stderr_lines == 1))
        fi
        if [ "$t32_rc" -eq "$t32_want_rc" ] && [ "$t32_diag_ok" -eq 1 ] \
            && t32_contract "$t32_out" "$t32_want_state" "$t32_want_high" "$t32_want_hard" "$t32_want_schedule" "$t32_case_started"; then
            pass "T32 watermark pair $t32_label"
        else
            fail "T32 watermark pair $t32_label" "rc=$t32_rc diagnostics=$t32_diag_count stderr_lines=$t32_stderr_lines stderr=$(tr '\n' ' ' < "$t32_case/case.err") out=$t32_out"
        fi
        rm -rf "$t32_case"
    }
    if [ "$t32_code" = genesis-capability-unavailable ]; then
        skip "T32 public watermark pair requires supported durable GENESIS capability" "$t32_seed"
    elif [ "$t32_seed_rc" -ne 0 ]; then
        fail "T32 watermark fixture reaches public GENESIS" "rc=$t32_seed_rc out=$t32_seed"
    else
        rm -rf "$t32"
        t32_pair "accepts exact structural minima under immediate owned pressure" 33554432 67108864 33554432 67108864 valid 3 pending null
        t32_pair "accepts largest representable strict ordering" 2147483646 2147483647 2147483646 2147483647 valid 0 idle future
        t32_pair "rejects high below structural minimum as one unit" 33554431 70000000 536870912 1073741824 fallback 0 idle future
        t32_pair "rejects hard below structural minimum as one unit" 40000000 67108863 536870912 1073741824 fallback 0 idle future
        t32_pair "rejects equality as one unit" 67108864 67108864 536870912 1073741824 fallback 0 idle future
        t32_pair "rejects high greater than hard as one unit" 70000000 67108864 536870912 1073741824 fallback 0 idle future
        t32_pair "rejects one syntactically invalid member as one unit" +1 70000000 536870912 1073741824 fallback 0 idle future
        t32_pair "rejects maximum equality instead of overflowing" 2147483647 2147483647 536870912 1073741824 fallback 0 idle future
    fi
    [ -d "$t32" ] && rm -rf "$t32"
else
    skip "T32 public GC watermark pair matrix (no JSON tool or CLI)"
fi

# ---------------------------------------------------------------------------
# T33  Public SubagentStart admission recovery and event identity.  The oracle
# below parses the real global/recovery/audit/work packs without importing the
# production module.  It deliberately understands the fixed ZYZOWN1 owner-fact
# partition rather than the superseded JSON recovery payload.  Green proves the
# written crash/replay controls discriminate same-event recovery from a fresh
# redispatch; it does not upgrade a host lacking GENESIS durability capability.
# ---------------------------------------------------------------------------
if json_tool && command -v python3 >/dev/null 2>&1 && [ -x hooks/scripts/subagent-track.sh ]; then
    t33_raw='resume/agent'; t33_role='implementation-agent'
    t33_nonce_a='00112233445566778899aabbccddeeff'
    t33_nonce_b='ffeeddccbbaa99887766554433221100'
    t33_key="$(python3 -c 'import hashlib,re,sys
r=sys.argv[1]; d=hashlib.sha256(r.encode()).hexdigest(); p=re.sub(r"[^A-Za-z0-9._-]","_",r)[:32] or "agent"; print(p+"."+d)' "$t33_raw")"

    t33_fixture() { # sandbox
        mkdir -p "$1/.zyz-worker/tasks/task/runtime"
        printf 'task\n' > "$1/.zyz-worker/current-task"
        printf -- '## Metadata\n\n- Current Phase: implementation\n' > "$1/.zyz-worker/tasks/task/status.md"
    }
    t33_start() { # sandbox nonce barrier
        printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"%s","agent_type":"zyz-worker:%s"}' \
            "$1" "$t33_raw" "$t33_role" |
            ZYZ_TEST_RANDOM_HEX_SEQUENCE="$2" ZYZ_TEST_TRANSITION_STOP_AFTER="$3" \
            ZYZ_TEST_DISABLE_SECRETS="${ZYZ_TEST_DISABLE_SECRETS:-0}" \
            ZYZ_TEST_DISABLE_URANDOM="${ZYZ_TEST_DISABLE_URANDOM:-0}" \
            bash hooks/scripts/subagent-track.sh
    }
    t33_diag_exact() { # stderr code
        [ "$(grep -c "^zyz-worker: $2$" "$1" 2>/dev/null || true)" -eq 1 ] \
            && [ "$(sed '/^$/d' "$1" | wc -l | tr -d ' ')" -eq 1 ]
    }
    t33_oracle() { # container key raw-id role nonce-used-by-reservation
        python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import hashlib,json,os,re,stat,struct,sys
p,key,raw_id,role,nonce=sys.argv[1:]
D=lambda domain,value:hashlib.sha256(domain+value).digest()
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
INSTANCE_KEY_RE=re.compile(r"[A-Za-z0-9._-]{1,32}\.[0-9a-f]{64}")
CLAIM_KEY_RE=re.compile(r"claim\.[0-9a-f]{64}")
STANDARD_PAYLOAD_LIMIT=3968
TERMINAL_IMAGE_SIZE=32768
TERMINAL_PAYLOAD_LIMIT=TERMINAL_IMAGE_SIZE-128
GROUP_PAYLOAD_LIMIT=60000
SEGMENT_SIZE=1048576
SEGMENT_CONTROL_SIZE=65536
SEGMENT_DESCRIPTOR_OFFSET=SEGMENT_SIZE-SEGMENT_CONTROL_SIZE

def image(raw,magic,image_domain=b"zyz-pack-image-v1",payload_domain=b"zyz-pack-payload-v1",id_domain=b"zyz-pack-image-id-v1",payload_limit=STANDARD_PAYLOAD_LIMIT):
    if len(raw)<128 or raw[:8]!=magic.ljust(8,b"\0"): raise ValueError("magic")
    schema,flags,generation,length=struct.unpack_from(">HHQI",raw,8)
    if payload_limit is not None and (payload_limit<0 or payload_limit>len(raw)-128): raise ValueError("payload limit")
    maximum=len(raw)-128 if payload_limit is None else payload_limit
    if schema!=1 or flags!=0 or generation<1 or length>maximum: raise ValueError("header")
    source=bytearray(raw); source[56:88]=bytes(32)
    if raw[56:88]!=D(image_domain,bytes(source)): raise ValueError("image checksum")
    payload=raw[128:128+length]
    if raw[96:128]!=D(payload_domain,payload): raise ValueError("payload checksum")
    value=json.loads(payload)
    if not isinstance(value,dict) or J(value)!=payload: raise ValueError("canonical payload")
    return generation,raw[24:56],value,D(id_domain,raw).hex()

def select(raw,offset,size,magic,payload_limit=STANDARD_PAYLOAD_LIMIT):
    valid=[]
    for bank in (0,1):
        part=raw[offset+bank*size:offset+(bank+1)*size]
        if part==bytes(size): continue
        try:
            parsed=image(part,magic,payload_limit=payload_limit)
            valid.append((parsed[0],bank,part,parsed))
        except Exception: pass
    if not valid: raise ValueError("no A/B generation")
    valid.sort()
    if len(valid)==2 and (valid[0][0]==valid[1][0] or valid[1][3][1].hex()!=valid[0][3][3]):
        raise ValueError("A/B chain")
    return valid[-1]

def terminal_payload_boundary_contract():
    payload=J({"x":"x"*(TERMINAL_PAYLOAD_LIMIT-8)})
    if len(payload)!=TERMINAL_PAYLOAD_LIMIT: raise ValueError("terminal maximum fixture")
    def fixture(declared):
        raw=bytearray(TERMINAL_IMAGE_SIZE);raw[:8]=b"ZYZTCEL1"
        struct.pack_into(">HHQI",raw,8,1,0,1,declared);raw[96:128]=D(b"zyz-pack-payload-v1",payload);raw[128:]=payload
        source=bytearray(raw);source[56:88]=bytes(32);raw[56:88]=D(b"zyz-pack-image-v1",bytes(source))
        return bytes(raw)
    exact=fixture(TERMINAL_PAYLOAD_LIMIT)
    if len(image(exact,b"ZYZTCEL1",payload_limit=TERMINAL_PAYLOAD_LIMIT)[2].get("x",""))!=TERMINAL_PAYLOAD_LIMIT-8:
        raise ValueError("terminal exact maximum")
    for raw,limit in ((exact,TERMINAL_PAYLOAD_LIMIT-1),(fixture(TERMINAL_PAYLOAD_LIMIT+1),TERMINAL_PAYLOAD_LIMIT),(exact,TERMINAL_PAYLOAD_LIMIT+1)):
        try: image(raw,b"ZYZTCEL1",payload_limit=limit)
        except ValueError: continue
        raise ValueError("terminal oversize accepted")

terminal_payload_boundary_contract()

def directory(raw,index):
    if len(raw)!=192 or raw[:4]!=b"ZCD1": raise ValueError("directory magic")
    schema,state,flags,observed,cell_gen,free_gen=struct.unpack_from(">BBHIHH",raw,4)
    source=bytearray(raw); source[16:32]=bytes(16)
    if schema!=1 or state not in range(8) or flags or observed!=index or raw[16:32]!=D(b"zyz-cell-directory-image-v1",bytes(source))[:16]:
        raise ValueError("directory")
    return {"state":state,"cell_generation":cell_gen,"free_generation":free_gen,
            "fields":[raw[32+i*32:64+i*32].hex() for i in range(5)]}

def creator_locator(region):
    if len(region)!=272 or region[:8]!=b"ZYZLOC1\0": raise ValueError("creator locator magic")
    schema,key_length,flags,request_bytes=struct.unpack_from(">HHIQ",region,8)
    if schema!=1 or flags or not 1<=key_length<=128 or request_bytes<1:
        raise ValueError("creator locator header")
    try: creator_key=region[24:24+key_length].decode("ascii")
    except UnicodeDecodeError: raise ValueError("creator locator key")
    if (region[24+key_length:160]!=bytes(136-key_length) or
        region[160:192]!=D(b"zyz-creator-locator-v1",region[:160]) or
        region[192:]!=bytes(80) or
        (INSTANCE_KEY_RE.fullmatch(creator_key) is None and CLAIM_KEY_RE.fullmatch(creator_key) is None)):
        raise ValueError("creator locator body")
    return {"key":creator_key,"request_bytes":request_bytes}

def recovery(raw,index):
    if len(raw)!=512 or raw[:8]!=b"ZYZRCV1\0": raise ValueError("recovery magic")
    schema,state,observed,generation,free_generation=struct.unpack_from(">HHIQQ",raw,8)
    source=bytearray(raw); source[32:64]=bytes(32)
    if schema!=1 or state not in range(10) or observed!=index or raw[32:64]!=D(b"zyz-recovery-cell-image-v1",bytes(source)):
        raise ValueError("recovery")
    payload={"state":"FREE","cell_generation":generation,"free_generation":free_generation,
             "prior_fact":raw[96:128].hex(),"core_digest":raw[128:160].hex(),
             "body_digest":raw[160:192].hex(),"final_cell_digest":raw[192:224].hex()}
    if state:
        names={1:"RESERVED",2:"OWNER_ACTIVE",3:"ACTIVE_ACK",4:"DELTA_WILL",5:"DELTA_APPLIED",6:"FLUSH_ACKED",7:"CELL_FREE_WILL",8:"PREVIS_CANCELLED",9:"PREVIS_FREE_WILL"}
        owner_schema,owner_state,owner_kind,owner_flags=struct.unpack_from(">HBBI",raw,72)
        if raw[64:72]!=b"ZYZOWN1\0" or (owner_schema,owner_state,owner_kind,owner_flags)!=(1,state,1,0) or raw[480:]!=bytes(32):
            raise ValueError("owner facts")
        if (state in (1,8,9)) != (raw[144:176]==bytes(32)):
            raise ValueError("owner object identity typing")
        operations={}; previs=None; locator=None
        if state in (8,9):
            region=raw[208:480]
            if region[:8]!=b"ZYZPCV1\0" or region[164:]!=bytes(108): raise ValueError("previs region")
            previs_schema,previs_phase,previs_flags=struct.unpack_from(">HBB",region,8)
            group_generation,source_segment_generation,frame_offset=struct.unpack_from(">QQQ",region,12)
            if (previs_schema!=1 or previs_phase not in (1,2) or previs_flags or group_generation<1 or
                source_segment_generation<1 or region[36:68]==bytes(32) or region[68:100]==bytes(32) or
                (previs_phase==1 and region[100:132]!=bytes(32)) or
                (previs_phase==2 and region[100:132]==bytes(32)) or region[132:164]==bytes(32)):
                raise ValueError("previs facts")
            previs={"phase":"cancelled" if previs_phase==1 else "free-will",
                    "group_generation":group_generation,"source_segment_generation":source_segment_generation,
                    "frame_offset":frame_offset,"frame_digest":region[36:68].hex(),
                    "cancel_digest":region[68:100].hex(),
                    "group_visible_digest":None if previs_phase==1 else region[100:132].hex(),
                    "free_receipt_record_digest":region[132:164].hex()}
        elif raw[208:216]==b"ZYZLOC1\0":
            locator=creator_locator(raw[208:480])
        else:
            for name,offset,want_kind in (("SETTLE",208,1),("RELEASE",304,2)):
                slot=raw[offset:offset+96]
                if slot==bytes(96): continue
                if slot[:8]!=b"ZYZOPV1\0" or slot[92:]!=bytes(4): raise ValueError("operation slot")
                op_schema,op_kind,phase=struct.unpack_from(">HBB",slot,8)
                delta,root_generation=struct.unpack_from(">qQ",slot,12)
                if op_schema!=1 or op_kind!=want_kind or phase not in (1,2) or delta==0 or root_generation<1 or slot[28:60]==bytes(32) or slot[60:92]==bytes(32):
                    raise ValueError("operation facts")
                operations[name]={"phase":"will" if phase==1 else "applied","delta":delta,
                                  "root_generation":root_generation,"op_digest":slot[28:60].hex(),
                                  "root_digest":slot[60:92].hex()}
        union=raw[400:480]; flush=None
        if union!=bytes(80):
            if union[:8]!=b"ZYZFLV1\0" or union[68:]!=bytes(12): raise ValueError("flush union")
            union_schema,phase,flags=struct.unpack_from(">HBB",union,8)
            segment_generation,frame_offset=struct.unpack_from(">QQ",union,12)
            frame_length,operation_count=struct.unpack_from(">II",union,28)
            if union_schema!=1 or phase not in (1,2,3) or flags or segment_generation<1 or frame_length<64 or operation_count not in (1,2) or union[36:68]==bytes(32):
                raise ValueError("flush facts")
            flush={"phase":{1:"will",2:"acked",3:"free-will"}[phase],
                   "segment_generation":segment_generation,"frame_offset":frame_offset,
                   "frame_length":frame_length,"operation_count":operation_count,
                   "frame_digest":union[36:68].hex()}
        payload={"state":names[state],"subject_digest":raw[80:112].hex(),
                 "reservation_digest":raw[112:144].hex(),
                 "object_identities_digest":None if raw[144:176]==bytes(32) else raw[144:176].hex(),
                 "consumed_free_receipt_record_digest":raw[176:208].hex(),
                 "operation_region_zero":raw[208:480]==bytes(272),
                 "operations":operations,"flush":flush,"previs":previs}
        if locator is not None: payload["creator_locator"]=locator
    return {"state":state,"generation":generation,"free_generation":free_generation,
            "payload":payload,"digest":D(b"zyz-recovery-cell-selected-v1",raw).hex()}

def record(raw):
    generation,predecessor,payload,digest=image(raw,b"ZYZREC1\0",
        b"zyz-instance-record-image-v1",b"zyz-instance-record-payload-v1",b"zyz-instance-record-id-v1",None)
    if raw[128+struct.unpack_from(">I",raw,20)[0]:]!=bytes(len(raw)-128-struct.unpack_from(">I",raw,20)[0]):
        raise ValueError("record tail")
    return {"generation":generation,"predecessor":predecessor.hex(),"payload":payload,"digest":digest}

def frame(raw):
    if len(raw)<64 or raw[:8]!=b"ZYZFRM1\0": raise ValueError("frame magic")
    schema,kind_number,payload_length,total=struct.unpack_from(">HHII",raw,8)
    kinds={1:"overlay",2:"free-receipt",3:"owner",4:"claim",5:"observation"}
    if schema!=1 or kind_number not in kinds or total!=len(raw) or total%8 or payload_length>total-64 or raw[52:64]!=bytes(12) or raw[64+payload_length:]!=bytes(total-64-payload_length):
        raise ValueError("frame header")
    encoded=raw[64:64+payload_length]
    if raw[20:52]!=D(b"zyz-catalog-frame-payload-v1",encoded): raise ValueError("frame payload checksum")
    payload=json.loads(encoded)
    if not isinstance(payload,dict) or J(payload)!=encoded: raise ValueError("frame canonical payload")
    return {"kind":kinds[kind_number],"length":total,"payload":payload,
            "digest":D(b"zyz-catalog-frame-v1",raw).hex(),"sha256":hashlib.sha256(raw).hexdigest()}

def segment(path):
    data=open(path,"rb").read(); name=os.path.basename(path)
    if len(data)!=SEGMENT_SIZE: raise ValueError("segment size")
    if data==bytes(SEGMENT_SIZE):
        return {"storage_state":"unused-zero","frames":[],"sha256":hashlib.sha256(data).hexdigest()}
    descriptor=select(data,SEGMENT_DESCRIPTOR_OFFSET,4096,b"ZYZSEG1"); meta=descriptor[3][2]
    match=re.fullmatch(r"\.catalog-segment\.(\d{16})\.v1",name)
    used=meta.get("committed_used_length")
    if (match is None or meta.get("segment_generation")!=int(match.group(1)) or
        meta.get("deterministic_basename")!=name or meta.get("size")!=SEGMENT_SIZE or
        not isinstance(used,int) or used<0 or used>SEGMENT_DESCRIPTOR_OFFSET or
        meta.get("committed_content_sha256")!=hashlib.sha256(data[:used]).hexdigest()):
        raise ValueError("segment descriptor")
    frames=[]; offset=0
    while offset<used:
        if offset+20>used: raise ValueError("truncated frame")
        total=struct.unpack_from(">I",data,offset+16)[0]
        if total<64 or offset+total>used: raise ValueError("frame extent")
        parsed=frame(data[offset:offset+total]); frames.append({"offset":offset,**parsed}); offset+=total
    if offset!=used: raise ValueError("segment committed extent")
    return {"storage_state":"descriptor-valid","descriptor_generation":descriptor[0],"descriptor_bank":descriptor[1],
            "descriptor_digest":descriptor[3][3],"metadata":meta,"frames":frames,
            "committed_sha256":hashlib.sha256(data[:used]).hexdigest()}

layouts={"audit":{"IDENTITY":(8192,8192),"START":(16384,8192),"HEARTBEAT":(24576,8192),
 "DONE":(32768,16384),"FINALIZED":(49152,16384),"AMBIGUOUS":(65536,8192),"PROBE_STATE":(73728,32768),
 "RESOLVED_START":(106496,65536),"RESOLVED_STOP":(172032,65536),
 "SUCCESSOR_RECEIPTS":(237568,65536),"LATE_EVENT":(303104,16384),
 "TERMINAL_SUMMARY":(319488,16384),"GC_ANCHOR":(335872,16384),"DIAGNOSTICS":(352256,40960)},
 "work":{"TRANSITION_JOURNAL":(8192,16384),"PUBLICATION_JOURNAL":(24576,32768),"LIVE_INVENTORY":(57344,32768),
  "TERMINAL_STAGING":(90112,32768),"TERMINAL_HANDOFF":(122880,16384),"INFLIGHT":(139264,65536),
  "EPHEMERAL_DIAGNOSTICS":(204800,32768)},
 "claim":{"IMMUTABLE_KEY":(8192,8192),"OWNER":(16384,16384),"OBSERVATION":(32768,16384),
  "GC_JOURNAL":(49152,32768),"KEY":(81920,8192),"CHECKPOINT":(90112,16384),
  "POINTER":(106496,8192),"RECEIPT":(114688,8192),"ANCHOR_ACK":(122880,8192)}}
def pack(path,kind):
    data=open(path,"rb").read(); st=os.lstat(path)
    head=select(data,0,4096,{"audit":b"ZYZAUDH1","work":b"ZYZWORH1","claim":b"ZYZCLMH1"}[kind])
    selected=head[3][2]["selected"]; records={}; local_records={}
    for slot,(offset,length) in layouts[kind].items():
        ref=selected.get(slot)
        if ref is None: continue
        half=length//2; observed=record(data[offset+ref["bank"]*half:offset+(ref["bank"]+1)*half])
        if observed["generation"]!=ref["generation"] or observed["digest"]!=ref["digest"]: raise ValueError("record selector")
        records[slot]=observed
    if kind=="audit":
        offset,length=layouts["audit"]["HEARTBEAT"]; half=length//2; states=[]
        for bank in (0,1):
            part=data[offset+bank*half:offset+(bank+1)*half]
            if part==bytes(half): continue
            try: states.append((record(part)["generation"],bank,record(part)))
            except Exception: pass
        states.sort()
        if len(states)==2 and (states[0][0]==states[1][0] or states[1][2]["predecessor"]!=states[0][2]["digest"]):
            raise ValueError("local record chain")
        if states: local_records["HEARTBEAT"]={"bank":states[-1][1],**states[-1][2]}
    return {"header_generation":head[0],"header_bank":head[1],"header_predecessor":head[3][1].hex(),"header_digest":head[3][3],"selected":selected,"records":records,"local_records":local_records,
            "sha256":hashlib.sha256(data).hexdigest(),"dev":st.st_dev,"ino":st.st_ino,"size":st.st_size,
            "blocks":st.st_blocks,"allocated":st.st_blocks*512,"nlink":st.st_nlink,"regular":stat.S_ISREG(st.st_mode)}

g=open(os.path.join(p,".catalog-global-pack.v1"),"rb").read()
r=open(os.path.join(p,".catalog-recovery-pack.v1"),"rb").read()
tpath=os.path.join(p,".terminal-audit-pack.v1"); t=open(tpath,"rb").read(); tst=os.lstat(tpath)
if len(t)!=16777216 or not stat.S_ISREG(tst.st_mode) or tst.st_nlink!=1: raise ValueError("terminal pack identity")
terminal_cells=[]
for index in range(256):
    observed=select(t,index*65536,TERMINAL_IMAGE_SIZE,b"ZYZTCEL1",TERMINAL_PAYLOAD_LIMIT); metadata=observed[3][2]
    if metadata.get("cell_index")!=index or metadata.get("state") not in ("empty","reserved","handoff-accepted","tombstone"):
        raise ValueError("terminal cell schema")
    if metadata.get("state")!="empty":
        terminal_cells.append({"cell_index":index,"generation":observed[0],"bank":observed[1],
          "predecessor":observed[3][1].hex(),"digest":observed[3][3],"metadata":metadata})
terminal={"sha256":hashlib.sha256(t).hexdigest(),"dev":tst.st_dev,"ino":tst.st_ino,
 "size":tst.st_size,"blocks":tst.st_blocks,"nlink":tst.st_nlink,"cells":terminal_cells}
root=select(g,32768,65536,b"ZYZROOT1"); root_meta=root[3][2]; selector=root[2][4096:5120]
schedule=select(g,24576,4096,b"ZYZSCH1")
if (root_meta.get("schedule_bank")!=schedule[1] or
    root_meta.get("schedule_digest")!=schedule[3][3]):
    raise ValueError("ROOT schedule selector")
schedule_info={"generation":schedule[0],"bank":schedule[1],
 "predecessor":schedule[3][1].hex(),"digest":schedule[3][3],"metadata":schedule[3][2]}
group=select(g,3309568,65536,b"ZYZGRP1",GROUP_PAYLOAD_LIMIT)
if group[3][3]!=root_meta.get("group_control_digest"): raise ValueError("ROOT group selector")
subject=D(b"zyz-instance-owner-key-v1",key.encode("ascii")).hex()
subject_dirs=[]; selected_cell=None
for index in range(8192):
    for bank,base in ((0,163840),(1,1736704)):
        raw=g[base+index*192:base+(index+1)*192]
        if raw==bytes(192): continue
        try: entry=directory(raw,index)
        except Exception: continue
        if entry["fields"][0]==subject:
            item={"index":index,"bank":bank,**entry}; subject_dirs.append(item)
            if ((selector[index//8]>>(index%8))&1)==bank: selected_cell=item
subject_recoveries=[]
for index in range(8192):
    for bank in (0,1):
        raw=r[index*1024+bank*512:index*1024+(bank+1)*512]
        if raw==bytes(512): continue
        try: rec=recovery(raw,index)
        except Exception: continue
        if rec["payload"].get("subject_digest")==subject:
            subject_recoveries.append({"index":index,"bank":bank,**rec})
subject_indices=sorted({item["index"] for item in subject_dirs}|{item["index"] for item in subject_recoveries})
cell_history=[]
for index in subject_indices:
    item={"index":index,"directories":[],"recoveries":[]}
    for bank,base in ((0,163840),(1,1736704)):
        raw=g[base+index*192:base+(index+1)*192]
        if raw==bytes(192): continue
        try: observed=directory(raw,index)
        except Exception: continue
        item["directories"].append({"bank":bank,"selected":((selector[index//8]>>(index%8))&1)==bank,**observed})
    for bank in (0,1):
        raw=r[index*1024+bank*512:index*1024+(bank+1)*512]
        if raw==bytes(512): continue
        try: observed=recovery(raw,index)
        except Exception: continue
        item["recoveries"].append({"bank":bank,**observed})
    cell_history.append(item)
if selected_cell is not None:
    matches=[x for x in subject_recoveries if x["index"]==selected_cell["index"] and
             x["generation"]==selected_cell["cell_generation"] and x["digest"]==selected_cell["fields"][1]]
    if len(matches)!=1: raise ValueError("selected recovery")
    selected_cell["recovery"]=matches[0]

raw_digest=hashlib.sha256(os.fsencode(raw_id)).hexdigest()
record_bytes=(bytes([1,1])+len(role.encode()).to_bytes(2,"big")+role.encode()+
              len(raw_digest.encode()).to_bytes(2,"big")+raw_digest.encode()+
              len(nonce.encode()).to_bytes(2,"big")+nonce.encode())
event={"event_token":"evt1-"+hashlib.sha256(record_bytes).hexdigest(),
       "nonce_sha256":hashlib.sha256(bytes.fromhex(nonce)).hexdigest(),
       "event_record_digest":hashlib.sha256(record_bytes).hexdigest()}
block=max(4096,os.statvfs(p).f_frsize); request=1048576+block
objects={"audit":key+".audit-pack.v1","audit_size":524288,
         "work":key+".work-pack.v1","work_size":524288,
         "lock":key+".lock.v1","request_bytes":request}
expected_reservation=D(b"zyz-instance-reservation-v1",J({"object_set":objects,"event_identity":event})).hex()
packs={}
for kind in ("audit","work"):
    path=os.path.join(p,objects[kind])
    if os.path.exists(path): packs[kind]=pack(path,kind)
lock=None
lock_path=os.path.join(p,objects["lock"])
if os.path.exists(lock_path):
    st=os.lstat(lock_path); lock={"dev":st.st_dev,"ino":st.st_ino,"size":st.st_size,
      "blocks":st.st_blocks,"allocated":st.st_blocks*512,"nlink":st.st_nlink,"regular":stat.S_ISREG(st.st_mode),
      "sha256":hashlib.sha256(open(lock_path,"rb").read()).hexdigest()}
fixed={".catalog-lock.v1",".catalog-shared-source-lock.v1",".terminal-index-lock.v1",
 ".catalog-global-pack.v1",".catalog-recovery-pack.v1",".terminal-audit-pack.v1",
 ".catalog-segment.0000000000000001.v1",".catalog-segment.0000000000000002.v1",
 ".catalog-compaction-scratch.v1"}
claims={}
for name in sorted(os.listdir(p)):
    match=re.fullmatch(r"([0-9a-f]{64})\.claim-pack\.v1",name)
    if match: claims[match.group(1)]=pack(os.path.join(p,name),"claim")
claim_cells={}
for claim_digest in sorted(claims):
    claim_subject=D(b"zyz-instance-owner-key-v1",("claim."+claim_digest).encode("ascii")).hex()
    directories=[]; recoveries=[]; selected_directory=None
    for index in range(8192):
        for bank,base in ((0,163840),(1,1736704)):
            raw=g[base+index*192:base+(index+1)*192]
            if raw==bytes(192): continue
            try: observed=directory(raw,index)
            except Exception: continue
            if observed["fields"][0]==claim_subject:
                item={"index":index,"bank":bank,"selected":((selector[index//8]>>(index%8))&1)==bank,**observed}
                directories.append(item)
                if item["selected"]: selected_directory=item
        for bank in (0,1):
            raw=r[index*1024+bank*512:index*1024+(bank+1)*512]
            if raw==bytes(512): continue
            try: observed=recovery(raw,index)
            except Exception: continue
            if observed["payload"].get("subject_digest")==claim_subject:
                recoveries.append({"index":index,"bank":bank,**observed})
    selected_recovery=None
    if selected_directory is not None:
        matches=[item for item in recoveries if item["index"]==selected_directory["index"] and
                 item["generation"]==selected_directory["cell_generation"] and
                 item["digest"]==selected_directory["fields"][1]]
        if len(matches)!=1: raise ValueError("selected claim recovery")
        selected_recovery=matches[0]
    claim_cells[claim_digest]={"subject_digest":claim_subject,"directories":directories,
        "recoveries":recoveries,"selected_directory":selected_directory,
        "selected_recovery":selected_recovery}
allowed=fixed|{objects["audit"],objects["work"],objects["lock"]}|{digest+".claim-pack.v1" for digest in claims}
segments={}
for name in sorted(fixed):
    if name.startswith(".catalog-segment."):
        segments[name]=segment(os.path.join(p,name))
active_generation=root_meta.get("active_segment_generation")
if not isinstance(active_generation,int) or active_generation<1: raise ValueError("ROOT active segment generation")
active_name=f".catalog-segment.{active_generation:016d}.v1"
if active_name not in segments or segments[active_name].get("storage_state")!="descriptor-valid":
    raise ValueError("ROOT selected segment is not descriptor-valid")
for name,observed_segment in segments.items():
    if observed_segment.get("storage_state")=="unused-zero":
        generation=int(name[len(".catalog-segment."):-len(".v1")])
        if generation<=active_generation: raise ValueError("unused-zero segment is not future standby")
frame_claim_digests={item["payload"].get("logical_key_sha256")
 for observed_segment in segments.values() for item in observed_segment["frames"]
 if item["kind"]=="claim" and re.fullmatch(r"[0-9a-f]{64}",str(item["payload"].get("logical_key_sha256"))) is not None}
for claim_digest in sorted(frame_claim_digests-set(claim_cells)):
    claim_subject=D(b"zyz-instance-owner-key-v1",("claim."+claim_digest).encode("ascii")).hex()
    directories=[]; recoveries=[]; selected_directory=None
    for index in range(8192):
        for bank,base in ((0,163840),(1,1736704)):
            raw=g[base+index*192:base+(index+1)*192]
            if raw==bytes(192): continue
            try: observed=directory(raw,index)
            except Exception: continue
            if observed["fields"][0]==claim_subject:
                item={"index":index,"bank":bank,"selected":((selector[index//8]>>(index%8))&1)==bank,**observed}
                directories.append(item)
                if item["selected"]: selected_directory=item
        for bank in (0,1):
            raw=r[index*1024+bank*512:index*1024+(bank+1)*512]
            if raw==bytes(512): continue
            try: observed=recovery(raw,index)
            except Exception: continue
            if observed["payload"].get("subject_digest")==claim_subject:
                recoveries.append({"index":index,"bank":bank,**observed})
    selected_recovery=None
    if selected_directory is not None:
        matches=[item for item in recoveries if item["index"]==selected_directory["index"] and
                 item["generation"]==selected_directory["cell_generation"] and
                 item["digest"]==selected_directory["fields"][1]]
        if len(matches)!=1: raise ValueError("selected retired claim recovery")
        selected_recovery=matches[0]
    claim_cells[claim_digest]={"subject_digest":claim_subject,"directories":directories,
        "recoveries":recoveries,"selected_directory":selected_directory,
        "selected_recovery":selected_recovery}
result={"root_generation":root[0],"root_predecessor":root[3][1].hex(),"root_digest":root[3][3],"root_meta":root_meta,"schedule":schedule_info,
 "group_generation":group[0],"group_digest":group[3][3],"group_meta":group[3][2],
 "subject_digest":subject,"subject_dirs":subject_dirs,"subject_recoveries":subject_recoveries,
 "selected_cell":selected_cell,"cell_history":cell_history,"packs":packs,"lock":lock,"expected_event":event,
 "expected_reservation_digest":expected_reservation,"expected_request_bytes":request,"segments":segments,"claims":claims,
 "claim_cells":claim_cells,"terminal":terminal,
 "forbidden_names":sorted(set(os.listdir(p))-allowed)}
print(json.dumps(result,sort_keys=True,separators=(",",":")))
PY
    }
    t33_prior_ok() { # oracle-json phase creator-key
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); phase=sys.argv[2]; creator_key=sys.argv[3]; cell=x["selected_cell"]
recs=x["subject_recoveries"]; dirs=x["subject_dirs"]; packs=x["packs"]
ok=not x["forbidden_names"] and all(r["payload"]["reservation_digest"]==x["expected_reservation_digest"] for r in recs)
locator={"key":creator_key,"request_bytes":x["expected_request_bytes"]}
if phase=="cell-reserved": ok=ok and x["root_generation"]==1 and cell is None and not dirs and len(recs)==1 and recs[0]["payload"]["state"]=="RESERVED" and recs[0]["payload"]["creator_locator"]==locator and not packs and x["lock"] is None
elif phase=="cell-inactive-durable": ok=ok and x["root_generation"]==1 and cell is None and len(dirs)==1 and dirs[0]["state"]==1 and len(recs)==1 and recs[0]["payload"]["state"]=="RESERVED" and recs[0]["payload"]["creator_locator"]==locator and not packs
elif phase=="root-successor-durable": ok=ok and x["root_generation"]==2 and cell is not None and cell["state"]==1 and cell["recovery"]["payload"]["state"]=="RESERVED" and cell["recovery"]["payload"]["creator_locator"]==locator and not packs and x["root_meta"]["active_claims"]==0
elif phase in ("owner-active","cell-active-ack"):
 state="OWNER_ACTIVE" if phase=="owner-active" else "ACTIVE_ACK"; want_gen=3 if phase=="owner-active" else 4
 ok=ok and x["root_generation"]==want_gen and cell is not None and cell["state"]==2 and cell["recovery"]["payload"]["state"]==state
 ok=ok and cell["recovery"]["payload"]["consumed_free_receipt_record_digest"]==cell["fields"][3]
 ok=ok and not cell["recovery"]["payload"]["operation_region_zero"] and cell["recovery"]["payload"]["creator_locator"]==locator
 ok=ok and x["root_meta"]["active_claims"]==1
 ok=ok and x["root_meta"]["owned_bytes"]==33554432+x["expected_request_bytes"] and set(packs)=={"audit","work"}
 ok=ok and all(v["size"]==524288 and v["allocated"]>=524288 and v["regular"] and v["nlink"]==1 and not v["records"] for v in packs.values())
 ok=ok and x["lock"] is not None and x["lock"]["size"]==x["expected_request_bytes"]-1048576 and x["lock"]["allocated"]>=x["lock"]["size"] and x["lock"]["regular"]
raise SystemExit(0 if ok else 1)
PY
    }
    t33_final_ok() { # oracle-json
        python3 - "$1" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); c=x["selected_cell"]; a=x["packs"].get("audit",{}); w=x["packs"].get("work",{})
ar=a.get("records",{}); wr=w.get("records",{}); ident=ar.get("IDENTITY",{}).get("payload",{}); start=ar.get("START",{}).get("payload",{}); journal=wr.get("TRANSITION_JOURNAL",{}).get("payload",{})
triple=("event_token","nonce_sha256","event_record_digest")
locator={"key":ident.get("instance_key"),"request_bytes":x["expected_request_bytes"]}
ok=(not x["forbidden_names"] and x["root_generation"]==4 and x["root_meta"]["active_claims"]==1 and
 x["root_meta"]["owned_bytes"]==33554432+x["expected_request_bytes"] and c is not None and c["state"]==2 and
 c["recovery"]["payload"]["state"]=="ACTIVE_ACK" and c["recovery"]["payload"]["reservation_digest"]==x["expected_reservation_digest"] and
 c["recovery"]["payload"]["consumed_free_receipt_record_digest"]==c["fields"][3] and not c["recovery"]["payload"]["operation_region_zero"] and
 c["recovery"]["payload"]["creator_locator"]==locator and
 set(ar)=={"IDENTITY","START"} and set(wr)=={"TRANSITION_JOURNAL"} and a["header_generation"]==3 and w["header_generation"]==3 and
 ident.get("instance_key") and ident.get("agent_id_sha256")==start.get("agent_id_sha256")==journal.get("agent_id_sha256") and
 journal.get("phase")=="committed" and all(start.get(k)==journal.get(k)==x["expected_event"][k] for k in triple) and
 start.get("identity_generation")==a["selected"]["IDENTITY"]["generation"] and start.get("identity_digest")==a["selected"]["IDENTITY"]["digest"] and
 journal.get("identity_digest")==a["selected"]["IDENTITY"]["digest"] and journal.get("start_generation")==a["selected"]["START"]["generation"] and journal.get("start_digest")==a["selected"]["START"]["digest"])
raise SystemExit(0 if ok else 1)
PY
    }
    t33_diff_ok() { # before after committed|pre-start [before-audit-pack after-audit-pack]
        python3 - "$1" "$2" "$3" "$t33_nonce_a" "$t33_nonce_b" "$t33_raw" "$t33_role" "$t33_key" "${4:-}" "${5:-}" <<'PY'
import hashlib,json,os,re,sys
b=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2])); layer,nonce_a,nonce_b,raw,role,key,before_path,after_path=sys.argv[3:]
d=hashlib.sha256(os.fsencode(raw)).hexdigest()
def event(nonce):
    rec=bytes([1,1])+len(role.encode()).to_bytes(2,"big")+role.encode()+len(d.encode()).to_bytes(2,"big")+d.encode()+len(nonce.encode()).to_bytes(2,"big")+nonce.encode()
    digest=hashlib.sha256(rec).hexdigest()
    return {"event_token":"evt1-"+digest,"nonce_sha256":hashlib.sha256(bytes.fromhex(nonce)).hexdigest(),"event_record_digest":digest}
persisted=(b.get("packs",{}).get("audit",{}).get("records",{}).get("START",{}).get("payload",{}))
fresh_event=event(nonce_b)
objects={"audit":key+".audit-pack.v1","audit_size":524288,"work":key+".work-pack.v1","work_size":524288,
         "lock":key+".lock.v1","request_bytes":b["expected_request_bytes"]}
def reservation_of(event_identity):
    encoded=json.dumps({"object_set":objects,"event_identity":event_identity},sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
    return hashlib.sha256(b"zyz-instance-reservation-v1"+encoded).hexdigest()
triple=("event_token","nonce_sha256","event_record_digest")
observed_reservation=((b.get("selected_cell") or {}).get("recovery",{}).get("payload",{}).get("reservation_digest"))
if all(isinstance(persisted.get(name),str) and persisted.get(name) for name in triple):
    # Public producer fixtures may use a random blank initial nonce.  Anchor
    # the reservation digest to the committed START triple observed in the
    # before-oracle, rather than reconstructing t33_nonce_a.  The committed
    # triple always takes precedence over the CELL reservation copy.
    reservation=reservation_of({name:persisted[name] for name in triple})
elif isinstance(observed_reservation,str) and re.fullmatch(r"[0-9a-f]{64}",observed_reservation):
    # A crash before START has no persisted event triple; the selected CELL
    # reservation digest is the remaining authoritative identity evidence.
    reservation=observed_reservation
else:
    reservation=reservation_of(event(nonce_a))
bp=b["packs"]; ap=a["packs"]; br=bp["audit"]; ar=ap["audit"]
amb_record=ar["records"].get("AMBIGUOUS",{}); amb=amb_record.get("payload",{})
payload_keys={"schema_version","instance_key","agent_id_sha256","canonical_role","existing_reservation_digest","detected_epoch",*fresh_event}
payload_ok=(set(amb)==payload_keys and amb.get("schema_version")==1 and amb.get("instance_key")==key and
 amb.get("agent_id_sha256")==d and amb.get("canonical_role")==role and
 amb.get("existing_reservation_digest")==reservation and all(amb.get(k)==v for k,v in fresh_event.items()) and
 isinstance(amb.get("detected_epoch"),int) and not isinstance(amb.get("detected_epoch"),bool) and amb["detected_epoch"]>=0)
base_before=dict(b); base_after=dict(a); base_before.pop("packs"); base_after.pop("packs")
static_fields={"dev","ino","size","blocks","allocated","nlink","regular","local_records"}
common=(base_before==base_after and set(bp)==set(ap)=={"audit","work"} and bp["work"]==ap["work"] and
 all(br[k]==ar[k] for k in static_fields) and b["expected_reservation_digest"]==a["expected_reservation_digest"] and
 payload_ok and not a["forbidden_names"])
if layer=="committed":
    old_names={"IDENTITY","START"}; new_names=old_names|{"AMBIGUOUS"}
    ok=(common and set(br["records"])==old_names and set(ar["records"])==new_names and
        set(br["selected"])==old_names and set(ar["selected"])==new_names and
        all(br["records"][name]==ar["records"][name] and br["selected"][name]==ar["selected"][name] for name in old_names) and
        ar["header_generation"]==br["header_generation"]+1 and ar["header_bank"]==1-br["header_bank"] and
        ar["header_predecessor"]==br["header_digest"] and amb_record.get("generation")==1 and
        amb_record.get("predecessor")=="0"*64 and ar["selected"]["AMBIGUOUS"]==
        {"bank":0,"generation":1,"digest":amb_record.get("digest")})
elif layer=="pre-start":
    raw_before=open(before_path,"rb").read(); raw_after=open(after_path,"rb").read()
    outside=lambda data:data[:4096]+data[8192:65536]+data[69632:]
    ok=(common and br["header_generation"]==1 and br["header_bank"]==0 and br["header_predecessor"]=="0"*64 and
        ar["header_generation"]==2 and ar["header_bank"]==1 and ar["header_predecessor"]==br["header_digest"] and
        not br["selected"] and not br["records"] and set(ar["selected"])==set(ar["records"])=={"AMBIGUOUS"} and
        amb_record.get("generation")==1 and amb_record.get("predecessor")=="0"*64 and
        ar["selected"]["AMBIGUOUS"]=={"bank":0,"generation":1,"digest":amb_record.get("digest")} and
        len(raw_before)==len(raw_after)==524288 and raw_before[4096:8192]==bytes(4096) and
        raw_before[65536:73728]==bytes(8192) and raw_after[69632:73728]==bytes(4096) and
        outside(raw_before)==outside(raw_after))
else: ok=False
raise SystemExit(0 if ok else 1)
PY
    }

    # Event identity must exist before GENESIS or any other state mutation.
    t33="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t33-random.XXXXXX")"
    mkdir -p "$t33/.zyz-worker/tasks/task"
    printf 'task\n' > "$t33/.zyz-worker/current-task"
    printf -- '## Metadata\n\n- Current Phase: implementation\n' > "$t33/.zyz-worker/tasks/task/status.md"
    ZYZ_TEST_DISABLE_SECRETS=1 ZYZ_TEST_DISABLE_URANDOM=1 \
        t33_start "$t33" invalid '' >"$t33/out" 2>"$t33/err"; t33_rc=$?
    if [ "$t33_rc" -eq 0 ] && [ ! -s "$t33/out" ] && t33_diag_exact "$t33/err" event-randomness-unavailable \
        && [ ! -e "$t33/.zyz-worker/tasks/task/runtime" ]; then
        pass "T33 event identity failure precedes every catalog/runtime mutation"
    else
        fail "T33 event identity failure precedes every catalog/runtime mutation" "rc=$t33_rc stderr=$(tr '\n' ' ' < "$t33/err")"
    fi
    rm -rf "$t33"

    t33_supported=1
    for t33_phase in cell-reserved cell-inactive-durable root-successor-durable owner-active; do
        t33="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t33-resume.XXXXXX")"; t33_fixture "$t33"
        case "$t33_phase" in
            cell-reserved|owner-active) t33_barrier="catalog-recovery:$t33_phase" ;;
            *) t33_barrier="catalog-root:$t33_phase" ;;
        esac
        t33_start "$t33" "$t33_nonce_a" "$t33_barrier" >"$t33/kill.out" 2>"$t33/kill.err"; t33_kill_rc=$?
        t33_container="$(find "$t33/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        if grep -Eq '^zyz-worker: genesis-(capability|capacity)-unavailable$' "$t33/kill.err"; then
            skip "T33 public admission crash/replay requires supported durable GENESIS capability" "$(tr '\n' ' ' < "$t33/kill.err")"
            t33_supported=0; rm -rf "$t33"; break
        fi
        t33_oracle "$t33_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t33/prior.json" 2>"$t33/oracle.err"; t33_oracle_rc=$?
        if [ "$t33_kill_rc" -eq 0 ] && [ ! -s "$t33/kill.out" ] && grep -qx 'zyz-worker: SubagentStart runtime tracking unavailable' "$t33/kill.err" \
            && [ "$t33_oracle_rc" -eq 0 ] && t33_prior_ok "$t33/prior.json" "$t33_phase" "$t33_key"; then
            pass "T33 public $t33_phase crash exposes its exact physical admission prior"
        else
            fail "T33 public $t33_phase crash exposes its exact physical admission prior" "rc=$t33_kill_rc oracle_rc=$t33_oracle_rc stderr=$(tr '\n' ' ' < "$t33/kill.err") oracle=$(tr '\n' ' ' < "$t33/oracle.err")"
        fi
        # Admission recovery is the subject here. Disable automatic lifecycle GC
        # so its legal UNINITIALIZED SCHEDULE/ROOT successor cannot alter the
        # independently exact admission after-state.
        ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 \
            t33_start "$t33" "$t33_nonce_a" '' >"$t33/resume.out" 2>"$t33/resume.err"; t33_resume_rc=$?
        t33_oracle "$t33_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t33/final.json" 2>"$t33/final-oracle.err"; t33_final_rc=$?
        if [ "$t33_resume_rc" -eq 0 ] && [ ! -s "$t33/resume.out" ] && [ ! -s "$t33/resume.err" ] \
            && [ "$t33_final_rc" -eq 0 ] && t33_final_ok "$t33/final.json"; then
            pass "T33 same event resumes $t33_phase to ACTIVE_ACK and one committed START"
        else
            fail "T33 same event resumes $t33_phase to ACTIVE_ACK and one committed START" "rc=$t33_resume_rc stderr=$(tr '\n' ' ' < "$t33/resume.err")"
        fi
        # A new native invocation is never a same-event replay. Reusing the
        # retained nonce sequence collides with the committed START inventory.
        t33_start "$t33" "$t33_nonce_a" '' >"$t33/repeat.out" 2>"$t33/repeat.err"; t33_repeat_rc=$?
        t33_oracle "$t33_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t33/repeat.json" 2>/dev/null
        if [ "$t33_repeat_rc" -eq 0 ] && [ ! -s "$t33/repeat.out" ] && t33_diag_exact "$t33/repeat.err" event-token-collision \
            && cmp -s "$t33/final.json" "$t33/repeat.json"; then
            pass "T33 committed retained-token invocation after $t33_phase is collision and byte-zero-effect"
        else
            fail "T33 committed retained-token invocation after $t33_phase is collision and byte-zero-effect" "rc=$t33_repeat_rc stderr=$(tr '\n' ' ' < "$t33/repeat.err")"
        fi
        t33_start "$t33" "$t33_nonce_b" '' >"$t33/diff.out" 2>"$t33/diff.err"; t33_diff_rc=$?
        t33_oracle "$t33_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t33/diff.json" 2>/dev/null
        if [ "$t33_diff_rc" -eq 0 ] && [ ! -s "$t33/diff.out" ] && t33_diag_exact "$t33/diff.err" identity-conflict \
            && t33_diff_ok "$t33/repeat.json" "$t33/diff.json" committed; then
            pass "T33 different event after $t33_phase latches pack AMBIGUOUS without advancing old START"
        else
            fail "T33 different event after $t33_phase latches pack AMBIGUOUS without advancing old START" "rc=$t33_diff_rc stderr=$(tr '\n' ' ' < "$t33/diff.err")"
        fi
        rm -rf "$t33"
    done

    if [ "$t33_supported" -eq 1 ]; then
        # Before object identity is authoritative, a fresh event may not adopt,
        # overwrite, or advance the old reservation.  No AMBIGUOUS inode exists
        # yet; canonical identity-conflict plus byte-exact packs is the oracle.
        for t33_phase in cell-reserved cell-inactive-durable root-successor-durable; do
            t33="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t33-preowner.XXXXXX")"; t33_fixture "$t33"
            case "$t33_phase" in cell-reserved) t33_barrier="catalog-recovery:$t33_phase";; *) t33_barrier="catalog-root:$t33_phase";; esac
            t33_start "$t33" "$t33_nonce_a" "$t33_barrier" >"$t33/kill.out" 2>"$t33/kill.err"
            t33_container="$(find "$t33/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
            t33_oracle "$t33_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t33/before.json" 2>/dev/null
            t33_start "$t33" "$t33_nonce_b" '' >"$t33/diff.out" 2>"$t33/diff.err"; t33_rc=$?
            t33_oracle "$t33_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t33/after.json" 2>/dev/null
            if [ "$t33_rc" -eq 0 ] && [ ! -s "$t33/diff.out" ] && t33_diag_exact "$t33/diff.err" identity-conflict \
                && cmp -s "$t33/before.json" "$t33/after.json"; then
                pass "T33 pre-owner $t33_phase rejects different event without guessing or pack mutation"
            else
                fail "T33 pre-owner $t33_phase rejects different event without guessing or pack mutation" "rc=$t33_rc stderr=$(tr '\n' ' ' < "$t33/diff.err")"
            fi
            rm -rf "$t33"
        done

        # Once object identity is authoritative, a fresh event must latch one
        # exact audit AMBIGUOUS record before returning identity-conflict. ROOT,
        # CELL, work pack, object identities, and every other authority stay exact.
        for t33_phase in owner-active cell-active-ack; do
            t33="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t33-authority.XXXXXX")"; t33_fixture "$t33"
            t33_start "$t33" "$t33_nonce_a" "catalog-recovery:$t33_phase" >"$t33/kill.out" 2>"$t33/kill.err"
            t33_container="$(find "$t33/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
            t33_oracle "$t33_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t33/before.json" 2>/dev/null
            t33_prior_ok "$t33/before.json" "$t33_phase" "$t33_key"; t33_prior_rc=$?
            cp "$t33_container/$t33_key.audit-pack.v1" "$t33/audit-before.pack"
            t33_start "$t33" "$t33_nonce_b" '' >"$t33/diff.out" 2>"$t33/diff.err"; t33_rc=$?
            t33_oracle "$t33_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t33/after.json" 2>/dev/null
            if [ "$t33_prior_rc" -eq 0 ] && [ "$t33_rc" -eq 0 ] && [ ! -s "$t33/diff.out" ] \
                && t33_diag_exact "$t33/diff.err" identity-conflict \
                && t33_diff_ok "$t33/before.json" "$t33/after.json" pre-start "$t33/audit-before.pack" "$t33_container/$t33_key.audit-pack.v1"; then
                pass "T33 $t33_phase fresh event latches exact audit AMBIGUOUS before identity-conflict"
            else
                fail "T33 $t33_phase fresh event latches exact audit AMBIGUOUS before identity-conflict" "rc=$t33_rc stderr=$(tr '\n' ' ' < "$t33/diff.err")"
            fi
            rm -rf "$t33"
        done

        # Replacing a reserved physical object with a byte-identical new inode
        # must be rejected before ACK/START.  Content-only validation would let
        # this same-event replay pass and the named mutation survive.
        t33="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t33-identity.XXXXXX")"; t33_fixture "$t33"
        t33_start "$t33" "$t33_nonce_a" 'catalog-recovery:owner-active' >"$t33/kill.out" 2>"$t33/kill.err"
        t33_container="$(find "$t33/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        cp "$t33_container/$t33_key.audit-pack.v1" "$t33/replacement" && mv "$t33/replacement" "$t33_container/$t33_key.audit-pack.v1"
        t33_oracle "$t33_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t33/replaced.json" 2>/dev/null
        t33_start "$t33" "$t33_nonce_a" '' >"$t33/replay.out" 2>"$t33/replay.err"; t33_rc=$?
        t33_oracle "$t33_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t33/after.json" 2>/dev/null
        if [ "$t33_rc" -eq 0 ] && t33_diag_exact "$t33/replay.err" catalog-root-invalid \
            && cmp -s "$t33/replaced.json" "$t33/after.json"; then
            pass "T33 same-event OWNER_ACTIVE replay revalidates physical object identity before ACK/START"
        else
            fail "T33 same-event OWNER_ACTIVE replay revalidates physical object identity before ACK/START" "rc=$t33_rc stderr=$(tr '\n' ' ' < "$t33/replay.err")"
        fi
        rm -rf "$t33"
    fi
else
    skip "T33 public admission/event recovery (no JSON tool, python3, or SubagentStart hook)"
fi

# ---------------------------------------------------------------------------
# T34  Public dynamic heartbeat/INFLIGHT fixed-pack routing.  These calls enter
# through heartbeat.sh with real PreToolUse/PostToolUse JSON.  The same physical
# oracle used by T33 observes record-local HEARTBEAT A/B and header-selected
# INFLIGHT; standalone dynamic control pathnames are never an accepted oracle.
# ---------------------------------------------------------------------------
if [ "${t33_supported:-0}" -eq 1 ]; then
    t34_beat() { # sandbox event call-id tool-name
        printf '{"cwd":"%s","hook_event_name":"%s","agent_id":"%s","agent_type":"zyz-worker:%s","tool_call_id":"%s","tool_name":"%s"}' \
            "$1" "$2" "$t33_raw" "$t33_role" "$3" "$4" | bash hooks/scripts/heartbeat.sh
    }
    t34="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t34.XXXXXX")"; t33_fixture "$t34"
    t33_start "$t34" "$t33_nonce_a" '' >"$t34/start.out" 2>"$t34/start.err"; t34_start_rc=$?
    t34_container="$(find "$t34/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t34_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t34/base.json" 2>/dev/null

    t34_beat "$t34" PreToolUse 'call/a' Bash >"$t34/pre-a.out" 2>"$t34/pre-a.err"; t34_rc=$?
    t33_oracle "$t34_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t34/pre-a.json" 2>/dev/null
    if [ "$t34_start_rc" -eq 0 ] && [ "$t34_rc" -eq 0 ] && [ ! -s "$t34/start.out" ] && [ ! -s "$t34/start.err" ] \
        && [ ! -s "$t34/pre-a.out" ] && [ ! -s "$t34/pre-a.err" ] \
        && python3 - "$t34/base.json" "$t34/pre-a.json" <<'PY'
import hashlib,json,sys
b=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2])); call=hashlib.sha256(b"call/a").hexdigest(); tool=hashlib.sha256(b"Bash").hexdigest()
hb=a["packs"]["audit"]["local_records"].get("HEARTBEAT",{}); hp=hb.get("payload",{}); inf=a["packs"]["work"]["records"].get("INFLIGHT",{}).get("payload",{}); entries=inf.get("entries",{})
ok=(not a["forbidden_names"] and b["root_digest"]==a["root_digest"] and b["selected_cell"]==a["selected_cell"] and
 a["packs"]["audit"]["header_generation"]==b["packs"]["audit"]["header_generation"] and "HEARTBEAT" not in a["packs"]["audit"]["selected"] and
 hb.get("generation")==1 and hp.get("instance_key")==a["packs"]["audit"]["records"]["IDENTITY"]["payload"]["instance_key"] and
 hp.get("agent_id_sha256")==a["packs"]["audit"]["records"]["IDENTITY"]["payload"]["agent_id_sha256"] and hp.get("agent_type")=="zyz-worker:implementation-agent" and
 set(entries)=={call} and entries[call].get("call_id_sha256")==call and entries[call].get("tool_name_sha256")==tool and
 a["packs"]["work"]["header_generation"]==b["packs"]["work"]["header_generation"]+1 and "call/a" not in json.dumps(inf) and "Bash" not in json.dumps(inf))
raise SystemExit(0 if ok else 1)
PY
    then
        pass "T34 public PreToolUse writes record-local HEARTBEAT and one full-hash INFLIGHT entry"
    else
        fail "T34 public PreToolUse writes record-local HEARTBEAT and one full-hash INFLIGHT entry" "start_rc=$t34_start_rc rc=$t34_rc"
    fi

    t34_beat "$t34" PreToolUse 'call/b' Read >"$t34/pre-b.out" 2>"$t34/pre-b.err"
    t33_oracle "$t34_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t34/pre-b.json" 2>/dev/null
    t34_beat "$t34" PostToolUse 'call/a' Bash >"$t34/post-a.out" 2>"$t34/post-a.err"
    t33_oracle "$t34_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t34/post-a.json" 2>/dev/null
    t34_beat "$t34" PostToolUse 'call/a' Bash >"$t34/post-repeat.out" 2>"$t34/post-repeat.err"
    t33_oracle "$t34_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t34/post-repeat.json" 2>/dev/null
    if [ ! -s "$t34/pre-b.out" ] && [ ! -s "$t34/pre-b.err" ] && [ ! -s "$t34/post-a.out" ] && [ ! -s "$t34/post-a.err" ] \
        && [ ! -s "$t34/post-repeat.out" ] && [ ! -s "$t34/post-repeat.err" ] \
        && python3 - "$t34/pre-b.json" "$t34/post-a.json" "$t34/post-repeat.json" <<'PY'
import hashlib,json,sys
p=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2])); r=json.load(open(sys.argv[3])); ca=hashlib.sha256(b"call/a").hexdigest(); cb=hashlib.sha256(b"call/b").hexdigest()
pe=p["packs"]["work"]["records"]["INFLIGHT"]["payload"]["entries"]; ae=a["packs"]["work"]["records"]["INFLIGHT"]["payload"]["entries"]
ok=(set(pe)=={ca,cb} and set(ae)=={cb} and p["packs"]["audit"]["local_records"]["HEARTBEAT"]["generation"]==2 and
 a["packs"]["audit"]["local_records"]["HEARTBEAT"]["generation"]==3 and r["packs"]["audit"]["local_records"]["HEARTBEAT"]["generation"]==4 and
 a["packs"]["work"]==r["packs"]["work"] and a["root_digest"]==r["root_digest"] and a["selected_cell"]==r["selected_cell"] and
 not p["forbidden_names"] and not a["forbidden_names"] and not r["forbidden_names"])
raise SystemExit(0 if ok else 1)
PY
    then
        pass "T34 exact PostToolUse removes only its full call hash and repeat Post leaves work generation stable"
    else
        fail "T34 exact PostToolUse removes only its full call hash and repeat Post leaves work generation stable"
    fi

    t34_i=1
    while [ "$t34_i" -le 63 ]; do
        t34_beat "$t34" PreToolUse "cap-$t34_i" Bash >/dev/null 2>&1
        t34_i=$((t34_i+1))
    done
    t33_oracle "$t34_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t34/full.json" 2>/dev/null
    t34_beat "$t34" PreToolUse overflow Bash >"$t34/overflow.out" 2>"$t34/overflow.err"; t34_overflow_rc=$?
    t33_oracle "$t34_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t34/overflow.json" 2>/dev/null
    if [ "$t34_overflow_rc" -eq 0 ] && [ ! -s "$t34/overflow.out" ] && [ ! -s "$t34/overflow.err" ] \
        && python3 - "$t34/full.json" "$t34/overflow.json" <<'PY'
import hashlib,json,sys
b=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2])); entries=b["packs"]["work"]["records"]["INFLIGHT"]["payload"]["entries"]
expected={hashlib.sha256(b"call/b").hexdigest()}|{hashlib.sha256(("cap-%d"%i).encode()).hexdigest() for i in range(1,64)}
ok=(set(entries)==expected and len(entries)==64 and b["packs"]["work"]==a["packs"]["work"] and
 a["packs"]["audit"]["local_records"]["HEARTBEAT"]["generation"]==b["packs"]["audit"]["local_records"]["HEARTBEAT"]["generation"]+1 and
 "overflow" not in json.dumps(a["packs"]["work"]) and not a["forbidden_names"])
raise SystemExit(0 if ok else 1)
PY
    then
        pass "T34 65th concurrent PreToolUse is host-fail-open but cannot exceed fixed INFLIGHT capacity 64"
    else
        fail "T34 65th concurrent PreToolUse is host-fail-open but cannot exceed fixed INFLIGHT capacity 64" "rc=$t34_overflow_rc"
    fi

    t34_beat "$t34" PostToolUse 'call/b' Read >/dev/null 2>&1
    t33_oracle "$t34_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t34/post-cap.json" 2>/dev/null
    if python3 - "$t34/overflow.json" "$t34/post-cap.json" <<'PY'
import hashlib,json,sys
b=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2])); before=b["packs"]["work"]; after=a["packs"]["work"]; entries=after["records"]["INFLIGHT"]["payload"]["entries"]
ok=(len(entries)==63 and hashlib.sha256(b"call/b").hexdigest() not in entries and after["header_generation"]==before["header_generation"]+1 and not a["forbidden_names"])
raise SystemExit(0 if ok else 1)
PY
    then
        pass "T34 capacity recovery PostToolUse removes one exact entry and preserves the other 63"
    else
        fail "T34 capacity recovery PostToolUse removes one exact entry and preserves the other 63"
    fi

    # Once AMBIGUOUS is selected, heartbeat and INFLIGHT are both immutable.
    t33_start "$t34" "$t33_nonce_b" '' >"$t34/amb.out" 2>"$t34/amb.err"
    t33_oracle "$t34_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t34/amb.json" 2>/dev/null
    t34_beat "$t34" PreToolUse blocked-call Bash >"$t34/blocked.out" 2>"$t34/blocked.err"; t34_blocked_rc=$?
    t33_oracle "$t34_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t34/blocked.json" 2>/dev/null
    if [ "$t34_blocked_rc" -eq 0 ] && t33_diag_exact "$t34/amb.err" identity-conflict \
        && [ ! -s "$t34/blocked.out" ] && [ ! -s "$t34/blocked.err" ] && cmp -s "$t34/amb.json" "$t34/blocked.json"; then
        pass "T34 selected pack AMBIGUOUS suppresses both HEARTBEAT and INFLIGHT mutation"
    else
        fail "T34 selected pack AMBIGUOUS suppresses both HEARTBEAT and INFLIGHT mutation" "rc=$t34_blocked_rc"
    fi
    rm -rf "$t34"
else
    skip "T34 public fixed-pack heartbeat/INFLIGHT requires T33 GENESIS capability"
fi

# ---------------------------------------------------------------------------
# T35  Public ordinary instance RELEASE -> overlay flush -> FREE lifecycle.
# Every call enters through the real SubagentStop hook.  The oracle above reads
# fixed CELL operation slots, immutable segment frames, and A/B descriptors
# directly; it never calls the private catalog lifecycle helpers.  These cases
# are intentionally expected-red until hook-stop owns this public lifecycle.
# Green would prove the written instance path only; it would not prove PREVIS,
# terminal handoff/INSTANCE_RELEASE, or the claim-pack lifecycle.
# ---------------------------------------------------------------------------
if [ "${t33_supported:-0}" -eq 1 ] && [ -x hooks/scripts/stop-gate-subagent.sh ]; then
    t35_nonce='102132435465768798a9bacbdcedfe0f'
    t35_start() { # sandbox nonce barrier; isolate ordinary stop from lifecycle GC
        ( export ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0; t33_start "$1" "$2" "$3" )
    }
    t35_stop() { # sandbox nonce barrier
        printf '{"cwd":"%s","hook_event_name":"SubagentStop","agent_id":"%s","agent_type":"zyz-worker:%s","stop_hook_active":false,"last_assistant_message":"Completed the assigned implementation work and recorded files, decisions, blockers, remaining scope, and exact handoff details for the main agent."}' \
            "$1" "$t33_raw" "$t33_role" |
            ZYZ_TEST_RANDOM_HEX_SEQUENCE="$2" ZYZ_TEST_TRANSITION_STOP_AFTER="$3" \
            ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 \
            bash hooks/scripts/stop-gate-subagent.sh
    }
    t35_gc() { # sandbox
        (
            cd "$1" || exit 1
            ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 \
                bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
                gc-step "$1/.zyz-worker/tasks/task" manual
        )
    }
    t35_phase_ok() { # base-json observed-json phase
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); phase=sys.argv[3]
history=x["cell_history"]
if len(history)!=1: raise SystemExit(1)
h=history[0]; selected_dirs=[d for d in h["directories"] if d["selected"]]
if len(selected_dirs)!=1: raise SystemExit(1)
directory=selected_dirs[0]
matching=[r for r in h["recoveries"] if r["generation"]==directory["cell_generation"] and r["digest"]==directory["fields"][1]]
if len(matching)!=1: raise SystemExit(1)
selected=matching[0]; latest=max(h["recoveries"],key=lambda r:r["generation"])
owner_latest=max((r for r in h["recoveries"] if r["state"]!=0),key=lambda r:r["generation"])
frames=[]
for segment in x["segments"].values(): frames.extend(segment["frames"])
overlay=[f for f in frames if f["kind"]=="overlay"]
receipt=[f for f in frames if f["kind"]=="free-receipt"]
request=b["expected_request_bytes"]; base_counter=b["root_meta"]["counter_generation"]
root_generations={"delta-will":4,"delta-commit":5,"delta-applied":6,
 "overlay-flush-will":7,"overlay-frame-committed":7,"overlay-flush-commit":8,
 "flush-acked":9,"will-cell-free":10,"free-receipt-frame-committed":10,
 "cell-free":10,"root-did-free":11,"gc-final":11}
selected_states={"delta-will":"ACTIVE_ACK","delta-commit":"DELTA_WILL","delta-applied":"DELTA_APPLIED",
 "overlay-flush-will":"FLUSH_ACKED","overlay-frame-committed":"FLUSH_ACKED","overlay-flush-commit":"FLUSH_ACKED",
 "flush-acked":"CELL_FREE_WILL","will-cell-free":"CELL_FREE_WILL",
 "free-receipt-frame-committed":"CELL_FREE_WILL","cell-free":"CELL_FREE_WILL","root-did-free":"FREE","gc-final":"FREE"}
ok=(not x["forbidden_names"] and x["root_generation"]==root_generations[phase] and
    x["root_meta"]["owned_bytes"]==(33554432+request if phase=="delta-will" else 33554432) and
    x["root_meta"]["active_claims"]==(1 if phase=="delta-will" else 0) and
    x["root_meta"]["counter_generation"]==base_counter+(0 if phase=="delta-will" else 1) and
    selected["payload"]["state"]==selected_states[phase])
operation_source=latest if phase=="delta-will" else (owner_latest if phase in ("root-did-free","gc-final") else selected)
release=operation_source["payload"].get("operations",{}).get("RELEASE",{})
ok=ok and set(operation_source["payload"].get("operations",{}))=={"RELEASE"} and release.get("delta")==-request
ok=ok and release.get("phase")== ("will" if phase in ("delta-will","delta-commit") else "applied")
want_overlay=phase not in ("delta-will","delta-commit","delta-applied","overlay-flush-will")
want_receipt=phase in ("free-receipt-frame-committed","cell-free","root-did-free","gc-final")
ok=ok and len(overlay)==int(want_overlay) and len(receipt)==int(want_receipt)
if overlay:
    op=overlay[0]["payload"].get("operations",{}).get("RELEASE",{})
    ok=ok and overlay[0]["offset"]==0 and op.get("phase")=="applied" and op.get("delta")==-request
    ok=ok and x["root_meta"].get("last_overlay_frame_digest")==overlay[0]["digest"] if phase not in ("overlay-frame-committed",) else ok and x["root_meta"].get("last_overlay_frame_digest")!=overlay[0]["digest"]
flush=selected["payload"].get("flush")
if phase in ("overlay-flush-will","overlay-frame-committed","overlay-flush-commit"):
    ok=ok and flush is not None and flush["phase"]=="will" and flush["operation_count"]==1
    if overlay: ok=ok and flush["frame_digest"]==overlay[0]["digest"] and flush["frame_offset"]==overlay[0]["offset"]
elif phase=="flush-acked":
    ok=ok and flush is not None and flush["phase"]=="acked" and flush["frame_digest"]==overlay[0]["digest"]
elif phase in ("will-cell-free","free-receipt-frame-committed","cell-free"):
    ok=ok and flush is not None and flush["phase"]=="free-will" and flush["operation_count"]==1
    if receipt: ok=ok and flush["frame_digest"]==receipt[0]["digest"] and flush["frame_offset"]==receipt[0]["offset"]
if receipt:
    rp=receipt[0]["payload"]; predecessor=b["selected_cell"]["recovery"]["payload"]["consumed_free_receipt_record_digest"]
    ok=ok and receipt[0]["offset"]==overlay[0]["offset"]+overlay[0]["length"] and rp.get("kind")=="ordinary"
    ok=ok and rp.get("predecessor_record_digest")==predecessor and rp.get("record_digest") and rp.get("body_digest")
if phase=="cell-free":
    ok=ok and latest["payload"]["state"]=="FREE" and latest["free_generation"]==1 and not any(d["selected"] and d["state"]==0 for d in h["directories"])
    free_dirs=[d for d in h["directories"] if d["state"]==0 and d["cell_generation"]==latest["generation"]]
    ok=ok and len(free_dirs)==1 and free_dirs[0]["fields"][2]==receipt[0]["payload"]["record_digest"]
    ok=ok and free_dirs[0]["fields"][3]==receipt[0]["payload"]["predecessor_record_digest"] and free_dirs[0]["fields"][4]==latest["payload"]["body_digest"]
if phase in ("root-did-free","gc-final"):
    ok=ok and directory["state"]==0 and selected["payload"]["state"]=="FREE" and selected["free_generation"]==1
    ok=ok and x["selected_cell"] is None and x["root_meta"].get("last_freed_subject_digest")==x["subject_digest"]
    ok=ok and x["root_meta"].get("last_free_receipt_record_digest")==receipt[0]["payload"]["record_digest"]
    active=x["segments"][".catalog-segment.0000000000000001.v1"]
    ok=ok and active["metadata"]["committed_used_length"]==receipt[0]["offset"]+receipt[0]["length"]
raise SystemExit(0 if ok else 1)
PY
    }
    t35_terminal_ok() { # final-oracle-json
        python3 - "$1" "$t35_nonce" "$t33_raw" "$t33_role" <<'PY'
import base64,hashlib,hmac,json,os,re,sys
x=json.load(open(sys.argv[1])); nonce,raw,role=sys.argv[2:]
d=hashlib.sha256(os.fsencode(raw)).hexdigest(); rec=bytes([1,2])+len(role.encode()).to_bytes(2,"big")+role.encode()+len(d.encode()).to_bytes(2,"big")+d.encode()+len(nonce.encode()).to_bytes(2,"big")+nonce.encode()
event={"event_token":"evt1-"+hashlib.sha256(rec).hexdigest(),"nonce_sha256":hashlib.sha256(bytes.fromhex(nonce)).hexdigest(),"event_record_digest":hashlib.sha256(rec).hexdigest()}
cells=x["terminal"]["cells"]
if len(cells)!=1: raise SystemExit(1)
cell=cells[0]; meta=cell["metadata"]; done=meta.get("terminal_record",{}); release=meta.get("instance_release",{})
ok=(not x["packs"] and x["lock"] is None and cell["generation"]==8 and
    meta.get("state")=="handoff-accepted" and meta.get("gc_anchor") is None and
    done.get("terminal_kind")=="done" and done.get("cleanup_state")=="pending" and done.get("cleanup_pending") is True and
    done.get("free_receipt_record_digest") is None and all(done.get(k)==event[k] for k in event) and
    release.get("phase")=="committed" and re.fullmatch(r"[0-9a-f]{64}",str(release.get("free_receipt_record_digest"))) is not None and
    release.get("free_receipt_record_digest")==x["root_meta"].get("last_free_receipt_record_digest"))
raise SystemExit(0 if ok else 1)
PY
    }
    t35_stop_after_ok() { # start-oracle stop-after-oracle
        python3 - "$1" "$2" "$t35_nonce" "$t33_raw" "$t33_role" "$t33_key" <<'PY'
import hashlib,json,os,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); nonce,raw,role,key=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
agent_digest=hashlib.sha256(os.fsencode(raw)).hexdigest()
record=bytes([1,2])+len(role.encode()).to_bytes(2,"big")+role.encode()+len(agent_digest.encode()).to_bytes(2,"big")+agent_digest.encode()+len(nonce.encode()).to_bytes(2,"big")+nonce.encode()
event={"event_token":"evt1-"+hashlib.sha256(record).hexdigest(),"nonce_sha256":hashlib.sha256(bytes.fromhex(nonce)).hexdigest(),"event_record_digest":hashlib.sha256(record).hexdigest()}
cells=x["terminal"]["cells"]
if len(cells)!=1: raise SystemExit(1)
cell=cells[0]; m=cell["metadata"]; release=m.get("instance_release",{})
terminal=m.get("terminal_record",{}); latch=m.get("handoff_latch",{}); objects=m.get("instance_objects",{}); frozen=m.get("frozen_headers",{})
expected_index=int.from_bytes(hashlib.sha256(key.encode("ascii")).digest()[:8],"big")%256
marker_ok=(terminal.get("terminal_kind")=="done" and terminal.get("instance_key")==key and
 terminal.get("agent_id_sha256")==agent_digest and terminal.get("canonical_role")==role and
 terminal.get("cleanup_state")=="pending" and terminal.get("cleanup_pending") is True and
 terminal.get("free_receipt_record_digest") is None and all(terminal.get(name)==value for name,value in event.items()))
def object_ok(expected,actual,logical):
 name=key+{"audit":".audit-pack.v1","work":".work-pack.v1","lock":".lock.v1"}[logical]
 shape={field:expected.get(field) for field in ("dev","ino","size","mount_id")}
 return (expected.get("basename")==name and isinstance(shape["mount_id"],str) and
  expected.get("digest")==hashlib.sha256(J(shape)).hexdigest() and actual is not None and
  all(expected.get(field)==actual.get(field) for field in ("dev","ino","size")) and
  actual.get("regular") is True and actual.get("nlink")==1)
ok=(not b["terminal"]["cells"] and not x["forbidden_names"] and
 cell["cell_index"]==expected_index and cell["generation"]==4 and m.get("state")=="handoff-accepted" and
 m.get("instance_key")==key and m.get("agent_id_sha256")==agent_digest and m.get("canonical_role")==role and
 m.get("reservation_nonce")==nonce and m.get("prior_cell_generation")==1 and
 m.get("catalog_reservation_digest")==b["expected_reservation_digest"] and m.get("request_bytes")==b["expected_request_bytes"] and
 release=={"phase":"will-register-release","free_receipt_record_digest":None} and m.get("gc_anchor") is None and
 marker_ok and m.get("terminal_record_digest")==JD(terminal) and m.get("handoff_latch_digest")==JD(latch) and
 latch.get("state")=="freeze-latch-committed" and latch.get("reservation_nonce")==nonce and
 latch.get("terminal_record_digest")==m.get("terminal_record_digest") and latch.get("catalog_reservation_digest")==b["expected_reservation_digest"] and
 latch.get("frozen_headers")=={name:frozen[name] for name in ("audit","work_prior","work_expected_generation")} and
 latch.get("instance_objects")==objects and set(objects)=={"audit","work","lock"} and
 set(x["packs"])=={"audit","work"} and x["lock"] is not None and
 x["packs"]["audit"]["records"].get("DONE",{}).get("payload")==terminal and
 x["packs"]["work"]["records"].get("TERMINAL_HANDOFF",{}).get("payload")==latch and
 frozen.get("audit")=={"generation":x["packs"]["audit"]["header_generation"],"digest":x["packs"]["audit"]["header_digest"]} and
 frozen.get("work")=={"generation":x["packs"]["work"]["header_generation"],"digest":x["packs"]["work"]["header_digest"]} and
 object_ok(objects["audit"],x["packs"]["audit"],"audit") and object_ok(objects["work"],x["packs"]["work"],"work") and object_ok(objects["lock"],x["lock"],"lock"))
raise SystemExit(0 if ok else 1)
PY
    }
    t35_gc_output_ok() { # output stop-after-oracle phase
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
out=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); phase=sys.argv[3]
request=b["expected_request_bytes"]; before=b["root_meta"]["owned_bytes"]
want={"ok":True,"state":"compacted","error":None,"trigger":"manual","due":True,
 "lock_acquired":True,"claims_scanned":0,"claims_skipped":0,"blocked_claims_known":0,
 "transactions_advanced":1,"entries_verified":0,"verification_bytes":0,
 "entries_deleted":3,"bytes_reclaimed":0 if phase=="root-did-free" else request,
 "owned_bytes_before":before,"owned_bytes_after":33554432,
 "high_water":536870912,"hard_water":1073741824,"receipts_anchored":0,"next_gc_epoch":None}
raise SystemExit(0 if out==want else 1)
PY
    }
    t35_oracle() { t33_oracle "$@"; }

    t35_reference=''
    for t35_phase in delta-will delta-commit delta-applied overlay-flush-will overlay-frame-committed overlay-flush-commit flush-acked will-cell-free free-receipt-frame-committed cell-free root-did-free; do
        t35="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t35-phase.XXXXXX")"; t33_fixture "$t35"
        t35_start "$t35" "$t33_nonce_a" '' >"$t35/start.out" 2>"$t35/start.err"
        t35_container="$(find "$t35/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t35_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t35/base.json" 2>"$t35/base.err"
        case "$t35_phase" in
            delta-will|delta-applied|flush-acked|cell-free) t35_barrier="catalog-recovery:$t35_phase" ;;
            overlay-frame-committed|free-receipt-frame-committed) t35_barrier="catalog-segment:$t35_phase" ;;
            *) t35_barrier="catalog-root:$t35_phase" ;;
        esac
        t35_stop "$t35" "$t35_nonce" "$t35_barrier" >"$t35/kill.out" 2>"$t35/kill.err"; t35_kill_rc=$?
        t33_oracle "$t35_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t35/prior.json" 2>"$t35/prior.err"; t35_oracle_rc=$?
        if [ "$t35_kill_rc" -eq 0 ] && [ ! -s "$t35/kill.out" ] \
            && grep -qx 'zyz-worker: SubagentStop terminal commit pending' "$t35/kill.err" \
            && [ "$t35_oracle_rc" -eq 0 ] && t35_phase_ok "$t35/base.json" "$t35/prior.json" "$t35_phase"; then
            pass "T35 public $t35_phase crash exposes exact ordinary lifecycle prior"
        else
            fail "T35 public $t35_phase crash exposes exact ordinary lifecycle prior" "rc=$t35_kill_rc oracle_rc=$t35_oracle_rc stderr=$(tr '\n' ' ' < "$t35/kill.err") oracle=$(tr '\n' ' ' < "$t35/prior.err")"
        fi
        t35_stop "$t35" "$t35_nonce" '' >"$t35/resume.out" 2>"$t35/resume.err"; t35_resume_rc=$?
        t33_oracle "$t35_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t35/stop-after.json" 2>"$t35/stop-after.err"; t35_stop_after_rc=$?
        if [ "$t35_resume_rc" -eq 0 ] && [ ! -s "$t35/resume.out" ] && [ ! -s "$t35/resume.err" ] \
            && [ "$t35_stop_after_rc" -eq 0 ] && cmp -s "$t35/prior.json" "$t35/stop-after.json" \
            && t35_phase_ok "$t35/base.json" "$t35/stop-after.json" "$t35_phase" \
            && t35_stop_after_ok "$t35/base.json" "$t35/stop-after.json"; then
            pass "T35 same stop event preserves $t35_phase at exact terminal handoff boundary"
        else
            fail "T35 same stop event preserves $t35_phase at exact terminal handoff boundary" "rc=$t35_resume_rc oracle_rc=$t35_stop_after_rc stderr=$(tr '\n' ' ' < "$t35/resume.err")"
        fi
        t35_gc "$t35" >"$t35/gc.out" 2>"$t35/gc.err"; t35_gc_rc=$?
        t35_oracle "$t35_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t35/final.json" 2>"$t35/final.err"; t35_final_rc=$?
        if [ "$t35_gc_rc" -eq 0 ] && [ ! -s "$t35/gc.err" ] && [ "$t35_final_rc" -eq 0 ] \
            && t35_phase_ok "$t35/base.json" "$t35/final.json" gc-final \
            && t35_terminal_ok "$t35/final.json" \
            && t35_gc_output_ok "$t35/gc.out" "$t35/stop-after.json" "$t35_phase"; then
            pass "T35 bounded public gc-step completes $t35_phase through committed release and ROOT did-free"
        else
            fail "T35 bounded public gc-step completes $t35_phase through committed release and ROOT did-free" "rc=$t35_gc_rc oracle_rc=$t35_final_rc out=$(tr '\n' ' ' < "$t35/gc.out") stderr=$(tr '\n' ' ' < "$t35/gc.err")"
        fi
        t35_stop "$t35" "$t35_nonce" '' >"$t35/repeat.out" 2>"$t35/repeat.err"; t35_repeat_rc=$?
        t33_oracle "$t35_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t35/repeat.json" 2>/dev/null
        if [ "$t35_repeat_rc" -eq 0 ] && [ ! -s "$t35/repeat.out" ] && [ ! -s "$t35/repeat.err" ] \
            && cmp -s "$t35/final.json" "$t35/repeat.json"; then
            pass "T35 committed $t35_phase replay preserves receipt and all generations"
        else
            fail "T35 committed $t35_phase replay preserves receipt and all generations" "rc=$t35_repeat_rc stderr=$(tr '\n' ' ' < "$t35/repeat.err")"
        fi
        rm -rf "$t35"
    done

    # A durable but not ROOT-selected FREE image is not reusable.  A fresh
    # start event may report conflict, but it cannot select that image, advance
    # ROOT/accounting, or append either immutable frame again.
    t35="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t35-reuse.XXXXXX")"; t33_fixture "$t35"
    t35_start "$t35" "$t33_nonce_a" '' >/dev/null 2>"$t35/start.err"
    t35_container="$(find "$t35/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t35_stop "$t35" "$t35_nonce" 'catalog-recovery:cell-free' >/dev/null 2>"$t35/kill.err"
    t33_oracle "$t35_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t35/before.json" 2>/dev/null
    t35_start "$t35" "$t33_nonce_b" '' >"$t35/reuse.out" 2>"$t35/reuse.err"; t35_reuse_rc=$?
    t33_oracle "$t35_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t35/after.json" 2>/dev/null
    if [ "$t35_reuse_rc" -eq 0 ] && [ ! -s "$t35/reuse.out" ] && t33_diag_exact "$t35/reuse.err" catalog-root-invalid \
        && python3 - "$t35/before.json" "$t35/after.json" <<'PY'
import json,sys
b=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2]))
ok=(b["root_digest"]==a["root_digest"] and b["root_meta"]==a["root_meta"] and
    b["cell_history"]==a["cell_history"] and b["segments"]==a["segments"])
raise SystemExit(0 if ok else 1)
PY
    then
        pass "T35 CELL FREE image cannot be reused before ROOT did-free"
    else
        fail "T35 CELL FREE image cannot be reused before ROOT did-free" "rc=$t35_reuse_rc stderr=$(tr '\n' ' ' < "$t35/reuse.err")"
    fi
    rm -rf "$t35"
else
    skip "T35 public ordinary lifecycle requires T33 GENESIS capability and SubagentStop hook"
fi

# ---------------------------------------------------------------------------
# T36  Public high-water GC cancellation of a pre-visible reservation.  A real
# SubagentStart is killed after ROOT selects RESERVED; only public gc-step may
# close admission, fold the cancel set, and install the PREVIS FREE receipt.
# The fixture never calls the private PREVIS primitives.  Green proves this one
# absent-owner-frame cancellation path, not partial/exact owner frames, group
# copy/cutover/old-source retirement, or general claim migration.
# ---------------------------------------------------------------------------
if [ "${t33_supported:-0}" -eq 1 ] && [ -x hooks/scripts/agent-runtime-state.sh ]; then
    t36_gc() { # sandbox barrier
        ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES=33554432 \
        ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES=67108864 \
        ZYZ_TEST_TRANSITION_STOP_AFTER="$2" \
            bash hooks/scripts/agent-runtime-state.sh gc-step \
            "$1/.zyz-worker/tasks/task" manual
    }
    t36_phase_ok() { # base-json observed-json phase container
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import base64,hashlib,json,os,struct,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); phase,container_path=sys.argv[3:]
D=lambda d,v:hashlib.sha256(d+v).digest()
J=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
if len(x["cell_history"])!=1: raise SystemExit(1)
h=x["cell_history"][0]; selected_dirs=[d for d in h["directories"] if d["selected"]]
if len(selected_dirs)!=1: raise SystemExit(1)
directory=selected_dirs[0]
matching=[r for r in h["recoveries"] if r["generation"]==directory["cell_generation"] and r["digest"]==directory["fields"][1]]
if len(matching)!=1: raise SystemExit(1)
selected=matching[0]; latest=max(h["recoveries"],key=lambda r:r["generation"])
root_gen={"will-previsibility-cancel":6,"previsibility-cancelled":6,"did-previsibility-cancel":7,
 "group-visible":13,"will-previs-cell-free":14,"previs-free-receipt-frame-committed":14,
 "previs-cell-free":14,"did-previs-cell-free":15}
group_gen={"will-previsibility-cancel":2,"previsibility-cancelled":2,"did-previsibility-cancel":2,
 "group-visible":7,"will-previs-cell-free":7,"previs-free-receipt-frame-committed":7,
 "previs-cell-free":7,"did-previs-cell-free":8}
selected_state={"will-previsibility-cancel":"RESERVED","previsibility-cancelled":"RESERVED",
 "did-previsibility-cancel":"PREVIS_CANCELLED","group-visible":"PREVIS_CANCELLED",
 "will-previs-cell-free":"PREVIS_CANCELLED","previs-free-receipt-frame-committed":"PREVIS_CANCELLED",
 "previs-cell-free":"PREVIS_CANCELLED",
 "did-previs-cell-free":"FREE"}
if (x["root_generation"]!=root_gen[phase] or x["group_generation"]!=group_gen[phase] or
        selected["payload"].get("state")!=selected_state[phase]):
    raise SystemExit(1)
cancelled=max((r for r in h["recoveries"] if r["state"]==8),key=lambda r:r["generation"],default=None)
ok=(not x["forbidden_names"] and x["root_generation"]==root_gen[phase] and
    x["group_generation"]==group_gen[phase] and selected["payload"]["state"]==selected_state[phase] and
    x["root_meta"]["owned_bytes"]==33554432 and x["root_meta"]["active_claims"]==0 and
    x["root_meta"]["counter_generation"]==b["root_meta"]["counter_generation"] and
    not x["packs"] and x["lock"] is None)
if phase in ("will-previsibility-cancel","previsibility-cancelled"):
    ok=ok and x["root_meta"].get("state")=="migration-quiescing" and x["root_meta"].get("previs_cancel_count")==0
    ok=ok and isinstance(x["root_meta"].get("previs_cancel_will"),dict)
else:
    ok=ok and x["root_meta"].get("previs_cancel_will") is None and x["root_meta"].get("previs_cancel_count")==1
if cancelled is not None:
    cancel_payload=cancelled["payload"]; pv=cancel_payload.get("previs") or {}
    core={"schema_version":1,"cell_index":h["index"],"cell_generation":b["selected_cell"]["recovery"]["generation"],
          "subject_digest":x["subject_digest"],"reservation_digest":cancel_payload.get("reservation_digest"),
          "consumed_free_receipt_record_digest":cancel_payload.get("consumed_free_receipt_record_digest"),
          "group_generation":pv.get("group_generation"),"source_segment_generation":pv.get("source_segment_generation"),
          "frame_offset":pv.get("frame_offset"),"frame_digest":pv.get("frame_digest")}
    want_cancel=D(b"zyz-previs-cancel-v1",J(core)).hex()
    ok=ok and cancel_payload.get("object_identities_digest") is None and not cancel_payload.get("operations") and cancel_payload.get("flush") is None
    ok=ok and pv.get("phase")=="cancelled" and pv.get("cancel_digest")==want_cancel
    ok=ok and pv.get("free_receipt_record_digest")==b["selected_cell"]["recovery"]["payload"]["consumed_free_receipt_record_digest"]
    if phase not in ("will-previsibility-cancel","previsibility-cancelled"):
        cancel_dirs=[d for d in h["directories"] if d["state"]==4 and d["cell_generation"]==cancelled["generation"]]
        ok=ok and len(cancel_dirs)==1 and cancel_dirs[0]["fields"][4]==want_cancel
        ok=ok and cancel_dirs[0]["selected"]==(phase!="did-previs-cell-free")
group=x["group_meta"]
if phase in ("group-visible","will-previs-cell-free","previs-free-receipt-frame-committed","previs-cell-free","did-previs-cell-free"):
    pv=cancelled["payload"]["previs"]; acc=hashlib.sha256(b"zyz-previs-cancel-set-v1")
    acc.update(struct.pack(">I",h["index"])); acc.update(bytes.fromhex(pv["cancel_digest"])); acc.update(bytes.fromhex(pv["free_receipt_record_digest"]))
    cancel_set=acc.digest(); anchor=group.get("visible_scratch_anchor") or {}
    prior_chain=b["root_meta"].get("hybrid_chain_digest"); after_chain=group.get("visible_chain_digest")
    visible_core={"group_generation":group.get("group_generation"),
     "source_group_digest":group.get("source_group_digest"),
     "plan_digest":group.get("planned_frame_digest"),
     "scratch_identity_digest":group.get("copied_scratch_identity"),
     "scratch_descriptor_digest":group.get("copied_scratch_descriptor_digest"),
     "cancel_count":1,"cancel_set_digest":cancel_set.hex(),
     "prior_chain_digest":prior_chain,"after_chain_digest":after_chain}
    visible=D(b"zyz-previs-group-visible-v1",J(visible_core)).hex()
    want_anchor={"schema_version":1,"kind":"scratch-object",
     "first_generation":anchor.get("first_generation"),"last_generation":anchor.get("last_generation"),
     "basename":group.get("scratch_basename"),"identity_digest":group.get("copied_scratch_identity"),
     "descriptor_digest":group.get("copied_scratch_descriptor_digest"),
     "descriptor_generation":anchor.get("descriptor_generation"),"used_length":group.get("planned_frame_bytes"),
     "plan_digest":group.get("planned_frame_digest"),"source_group_digest":group.get("source_group_digest"),
     "cancel_set_digest":cancel_set.hex()}
    ok=ok and group.get("cancel_count")==1 and group.get("cancel_set_digest")==cancel_set.hex()
    ok=ok and anchor==want_anchor and isinstance(anchor.get("first_generation"),int)
    ok=ok and anchor.get("first_generation")<=anchor.get("last_generation")
    ok=ok and group.get("group_visible_digest")==visible and x["root_meta"].get("previs_group_visible_digest")==visible
    if phase!="did-previs-cell-free": ok=ok and x["root_meta"].get("hybrid_chain_digest")==after_chain
    ok=ok and x["root_meta"].get("state")=="migration-active"
else:
    ok=ok and group.get("state")=="new-source-initialized" and group.get("cancel_count")==0

def image(raw,magic):
 if len(raw)!=4096 or raw[:8]!=magic.ljust(8,b"\0"): raise ValueError("image magic")
 schema,flags,generation,length=struct.unpack_from(">HHQI",raw,8)
 if schema!=1 or flags or generation<1 or length>3968: raise ValueError("image header")
 source=bytearray(raw); source[56:88]=bytes(32)
 if raw[56:88]!=D(b"zyz-pack-image-v1",bytes(source)): raise ValueError("image checksum")
 payload=raw[128:128+length]
 if raw[96:128]!=D(b"zyz-pack-payload-v1",payload): raise ValueError("payload checksum")
 value=json.loads(payload)
 if not isinstance(value,dict) or J(value)!=payload: raise ValueError("canonical image payload")
 return {"generation":generation,"predecessor":raw[24:56].hex(),"digest":D(b"zyz-pack-image-id-v1",raw).hex(),"metadata":value}

def frame(raw):
 if len(raw)<64 or raw[:8]!=b"ZYZFRM1\0": raise ValueError("frame magic")
 schema,kind,payload_length,total=struct.unpack_from(">HHII",raw,8)
 if schema!=1 or kind not in range(1,6) or total!=len(raw) or total%8 or payload_length>total-64: raise ValueError("frame header")
 encoded=raw[64:64+payload_length]
 if raw[20:52]!=D(b"zyz-catalog-frame-payload-v1",encoded) or raw[52:64]!=bytes(12) or raw[64+payload_length:]!=bytes(total-64-payload_length): raise ValueError("frame body")
 value=json.loads(encoded)
 if not isinstance(value,dict) or J(value)!=encoded: raise ValueError("canonical frame payload")
 return {"kind":{1:"overlay",2:"free-receipt",3:"owner",4:"claim",5:"observation"}[kind],
         "length":total,"payload":value,"digest":D(b"zyz-catalog-frame-v1",raw).hex()}

scratch=None; receipts=[]
if phase in ("group-visible","will-previs-cell-free","previs-free-receipt-frame-committed","previs-cell-free","did-previs-cell-free"):
 raw=open(os.path.join(container_path,group["scratch_basename"]),"rb").read()
 if len(raw)!=1048576: raise SystemExit(1)
 descriptors=[]
 for bank in (0,1):
  part=raw[983040+bank*4096:983040+(bank+1)*4096]
  if part==bytes(4096): continue
  try: descriptors.append({"bank":bank,**image(part,b"ZYZSEG1")})
  except Exception: pass
 descriptors.sort(key=lambda row:row["generation"])
 if not descriptors or (len(descriptors)==2 and (descriptors[0]["generation"]==descriptors[1]["generation"] or descriptors[1]["predecessor"]!=descriptors[0]["digest"])): raise SystemExit(1)
 descriptor=descriptors[-1]; metadata=descriptor["metadata"]; used=metadata.get("committed_used_length")
 if (metadata.get("segment_generation")!=0 or metadata.get("deterministic_basename")!=group["scratch_basename"] or
     not isinstance(used,int) or not 0<=used<=983040 or metadata.get("committed_content_sha256")!=hashlib.sha256(raw[:used]).hexdigest()): raise SystemExit(1)
 frames=[]; offset=0
 while offset<used:
  if offset+20>used: raise SystemExit(1)
  total=struct.unpack_from(">I",raw,offset+16)[0]
  if total<64 or offset+total>used: raise SystemExit(1)
  parsed=frame(raw[offset:offset+total]); frames.append({"offset":offset,**parsed}); offset+=total
 if offset!=used: raise SystemExit(1)
 scratch={"descriptor_generation":descriptor["generation"],"descriptor_predecessor":descriptor["predecessor"],
          "descriptor_digest":descriptor["digest"],"metadata":metadata,"frames":frames}
 receipts=[f for f in frames if f["kind"]=="free-receipt" and f["payload"].get("kind")=="previs"]

receipt_phases=("previs-free-receipt-frame-committed","previs-cell-free","did-previs-cell-free")
if phase in ("will-previs-cell-free",)+receipt_phases:
 predecessor=bytes.fromhex(cancelled["payload"]["consumed_free_receipt_record_digest"])
 cancel=bytes.fromhex(cancelled["payload"]["previs"]["cancel_digest"]); visible_bytes=bytes.fromhex(visible)
 cell_generation=cancelled["generation"]+1; free_generation=cancelled["free_generation"]+1
 core=struct.pack(">8sHHIQQ32s",b"ZYZCFV1\0",1,0,h["index"],cell_generation,free_generation,cancel)
 core_digest=D(b"zyz-cell-free-core-v1",core)
 body=struct.pack(">8sB7xIQ",b"ZYZFRB1\0",2,h["index"],free_generation)+predecessor+cancel+visible_bytes+core_digest
 body_digest=D(b"zyz-free-receipt-body-v1",body); final_digest=D(b"zyz-final-cell-image-v1",core+body_digest)
 record_digest=D(b"zyz-free-receipt-record-v1",body+body_digest+final_digest)
 want_payload={"schema_version":1,"frame_type":"FREE_RECEIPT","kind":"previs","cell_index":h["index"],
  "cell_generation":cell_generation,"free_generation":free_generation,"predecessor_record_digest":predecessor.hex(),
  "cancel_digest":cancel.hex(),"group_visible_digest":visible,"body_b64":base64.b64encode(body).decode(),
  "body_digest":body_digest.hex(),"final_cell_image_digest":final_digest.hex(),"record_digest":record_digest.hex()}
 encoded=J(want_payload); total=((64+len(encoded)+7)//8)*8; frame_image=bytearray(total)
 frame_image[:8]=b"ZYZFRM1\0"; struct.pack_into(">HHII",frame_image,8,1,2,len(encoded),total)
 frame_image[20:52]=D(b"zyz-catalog-frame-payload-v1",encoded); frame_image[64:64+len(encoded)]=encoded
 want_frame_digest=D(b"zyz-catalog-frame-v1",bytes(frame_image)).hex()
 frame_offset=anchor["used_length"]; segment_generation=anchor["last_generation"]
 want_will={"schema_version":1,"cell_index":h["index"],"cell_generation":cancelled["generation"],
  "group_generation":group["group_generation"],"cancel_digest":cancel.hex(),"group_visible_digest":visible,
  "expected_free_generation":free_generation,"free_receipt_record_digest":record_digest.hex(),
  "segment_generation":segment_generation,"frame_offset":frame_offset,"frame_length":total,"frame_digest":want_frame_digest}
 ok=ok and predecessor.hex()==b["selected_cell"]["recovery"]["payload"]["consumed_free_receipt_record_digest"]
 ok=ok and x["root_meta"].get("active_segment_generation")==segment_generation
 if phase=="will-previs-cell-free":
  ok=ok and not receipts and x["root_meta"].get("previs_free_will")==want_will
  ok=ok and scratch["descriptor_digest"]==anchor["descriptor_digest"] and scratch["metadata"].get("committed_used_length")==frame_offset
 else:
  if len(receipts)!=1: raise SystemExit(1)
  receipt=receipts[0]; rp=receipt["payload"]
  ok=ok and rp==want_payload and receipt["offset"]==frame_offset and receipt["length"]==total and receipt["digest"]==want_frame_digest
  ok=ok and scratch["descriptor_generation"]==anchor["descriptor_generation"]+1
  ok=ok and scratch["descriptor_predecessor"]==anchor["descriptor_digest"]
  ok=ok and scratch["metadata"].get("committed_used_length")==frame_offset+total
  if phase!="did-previs-cell-free":
   ok=ok and x["root_meta"].get("previs_free_will")==want_will
   ok=ok and x["root_meta"].get("active_segment_used_length")==frame_offset
   ok=ok and x["root_meta"].get("active_segment_descriptor_digest")==anchor["descriptor_digest"]
  else:
   ok=ok and x["root_meta"].get("previs_free_will") is None
   ok=ok and x["root_meta"].get("active_segment_used_length")==frame_offset+total
   ok=ok and x["root_meta"].get("active_segment_descriptor_digest")==scratch["descriptor_digest"]
else:
 ok=ok and not receipts and x["root_meta"].get("previs_free_will") is None
 if phase=="group-visible":
  ok=ok and scratch["descriptor_digest"]==anchor["descriptor_digest"]
  ok=ok and scratch["metadata"].get("committed_used_length")==anchor["used_length"]

if phase in ("previs-cell-free","did-previs-cell-free"):
 free_rows=[r for r in h["recoveries"] if r["state"]==0 and r["generation"]==cell_generation and r["free_generation"]==free_generation]
 if len(free_rows)!=1: raise SystemExit(1)
 free=free_rows[0]
 want_free={"state":"FREE","cell_generation":cell_generation,"free_generation":free_generation,
  "prior_fact":cancel.hex(),"core_digest":core_digest.hex(),"body_digest":body_digest.hex(),
  "final_cell_digest":final_digest.hex()}
 ok=ok and free["payload"]==want_free
 free_dirs=[d for d in h["directories"] if d["state"]==0 and d["cell_generation"]==cell_generation and d["free_generation"]==free_generation]
 if phase=="previs-cell-free":
  ok=ok and not free_dirs and directory["state"]==4 and selected["payload"]["state"]=="PREVIS_CANCELLED"
 else:
  ok=ok and len(free_dirs)==1 and free_dirs[0]["selected"] and directory==free_dirs[0]
  ok=ok and free_dirs[0]["fields"][0]==cancel.hex() and free_dirs[0]["fields"][1]==free["digest"]
  ok=ok and free_dirs[0]["fields"][2]==record_digest.hex() and free_dirs[0]["fields"][3]==predecessor.hex()
  ok=ok and free_dirs[0]["fields"][4]==body_digest.hex()
if phase=="did-previs-cell-free":
 prior=D(b"zyz-previs-consumed-v1",b"")
 consumed=D(b"zyz-previs-consumed-successor-v1",prior+struct.pack(">I",h["index"])+record_digest).hex()
 ok=ok and directory["state"]==0 and x["selected_cell"] is None and group.get("state")=="previs-cells-consumed"
 ok=ok and group.get("free_count")==group.get("cancel_count")==1 and group.get("consumed_digest")==consumed
 ok=ok and x["root_meta"].get("last_previs_free_receipt_record_digest")==record_digest.hex()
raise SystemExit(0 if ok else 1)
PY
    }
    t36_pending_ok() { # public-output-json
        python3 - "$1" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
want={"ok":True,"state":"pending","error":None,"trigger":"manual","due":True,
 "lock_acquired":True,"claims_scanned":0,"claims_skipped":0,"blocked_claims_known":0,
 "transactions_advanced":1,"entries_verified":0,"verification_bytes":0,
 "entries_deleted":0,"bytes_reclaimed":0,"owned_bytes_before":33554432,
 "owned_bytes_after":33554432,"high_water":33554432,"hard_water":67108864,
 "receipts_anchored":0,"next_gc_epoch":None}
raise SystemExit(0 if x==want else 1)
PY
    }
    t36_step_ok() { # before-oracle after-oracle
        python3 - "$1" "$2" <<'PY'
import json,sys
b=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2]))
def point(x):
 r=x["root_meta"]; g=x["group_meta"]
 return (x["root_generation"],x["group_generation"],r.get("state"),g.get("state"),
  r.get("migration_scan_cursor"),r.get("previs_cancel_count",0),
  r.get("previs_cancel_will") is not None,r.get("previs_free_will") is not None,
  g.get("cancel_count",0),g.get("free_count",0))
br,bg,rs,gs,cursor,cancel,cancel_will,free_will,gcancel,gfree=point(b)
ar,ag,ars,ags,acursor,acancel,acancel_will,afree_will,agcancel,agfree=point(a)
stable=(not b["forbidden_names"] and not a["forbidden_names"] and not b["packs"] and
 not a["packs"] and b["lock"] is None and a["lock"] is None and
 b["subject_digest"]==a["subject_digest"] and
 all(b["root_meta"].get(k)==a["root_meta"].get(k)==v for k,v in
  (("owned_bytes",33554432),("active_claims",0))) and
 b["root_meta"].get("counter_generation")==a["root_meta"].get("counter_generation"))
allowed=False
# Exact public migration steps for this one-RESERVED/empty-segment fixture.
if (rs,gs,cursor,cancel,cancel_will,free_will)==("active","idle",0,0,False,False):
 allowed=((ars,ags,acursor,acancel,acancel_will,afree_will)==
          ("migration-quiescing","idle",0,0,False,False) and ar==br+2 and ag==bg)
elif (rs,gs,cursor,cancel,cancel_will)==("migration-quiescing","idle",0,0,False):
 allowed=((ars,ags,acursor,acancel,acancel_will)==
          ("migration-quiescing","new-source-initialized",0,0,False) and ar==br+1 and ag==bg+1)
elif (rs,gs,cursor,cancel,cancel_will,free_will)==("migration-quiescing","new-source-initialized",0,0,False,False):
 # A bounded cancel call may finish its will/CELL/did transaction, but it must
 # persist cursor=0; the following public call owns scan-cursor completion.
 allowed=((ars,ags,acursor,acancel,acancel_will,agcancel,agfree)==
          ("migration-quiescing","new-source-initialized",0,1,False,0,0) and
          ar==br+2 and ag==bg)
elif (rs,gs,cursor,cancel,cancel_will)==("migration-quiescing","new-source-initialized",0,1,False):
 allowed=((ars,ags,acursor,acancel)==
          ("migration-quiescing","new-source-initialized",8192,1) and ar==br+1 and ag==bg)
elif (rs,gs,cursor,cancel)==("migration-quiescing","new-source-initialized",8192,1):
 allowed=((ars,ags,acursor,acancel)==("migration-quiescing","planning",8192,1) and ar==br+1 and ag==bg+1)
elif (rs,gs,cursor,cancel)==("migration-quiescing","planning",8192,1):
 allowed=((ars,ags,acursor,acancel)==("migration-quiescing","group-planned",8192,1) and ar==br+1 and ag==bg+1)
elif (rs,gs,cursor,cancel)==("migration-quiescing","group-planned",8192,1):
 allowed=((ars,ags,acursor,acancel)==("migration-quiescing","copied",8192,1) and ar==br+1 and ag==bg+1)
elif (rs,gs,cursor,cancel)==("migration-quiescing","copied",8192,1):
 allowed=((ars,ags,acursor,acancel)==("migration-quiescing","cutover-will",8192,1) and ar==br+1 and ag==bg+1)
elif (rs,gs,cursor,cancel)==("migration-quiescing","cutover-will",8192,1):
 allowed=((ars,ags,acursor,acancel,agcancel,agfree)==
          ("migration-active","group-visible",8192,1,1,0) and ar==br+1 and ag==bg+1)
elif (rs,gs,cursor,cancel,gcancel,gfree,free_will)==("migration-active","group-visible",8192,1,1,0,False):
 allowed=((ars,ags,acursor,acancel,agcancel,agfree,afree_will)==
          ("migration-active","previs-cells-consumed",8192,1,1,1,False) and ar==br+2 and ag==bg+1)
# Resume from a killed cancel/free subphase is the same single logical step and
# must converge only to its immediate durable after-state.
elif (rs,gs,cursor,cancel,cancel_will)==("migration-quiescing","new-source-initialized",0,0,True):
 allowed=((ars,ags,acursor,acancel,acancel_will)==
          ("migration-quiescing","new-source-initialized",0,1,False) and ar==br+1 and ag==bg)
elif (rs,gs,cursor,cancel,gcancel,gfree,free_will)==("migration-active","group-visible",8192,1,1,0,True):
 allowed=((ars,ags,acursor,acancel,agcancel,agfree,afree_will)==
          ("migration-active","previs-cells-consumed",8192,1,1,1,False) and ar==br+1 and ag==bg+1)
raise SystemExit(0 if stable and allowed and b["root_digest"]!=a["root_digest"] else 1)
PY
    }
    t36_oracle() { t33_oracle "$@"; }
    t36_drive_to_barrier() { # sandbox container barrier expected-round
        t36_drive_ok=0
        for t36_round in 1 2 3 4 5 6 7 8 9 10 11 12; do
            t36_oracle "$2" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$1/drive-before.json" 2>"$1/drive-before.err" || return 1
            t36_gc "$1" "$3" >"$1/drive.out" 2>"$1/drive.err"; t36_drive_rc=$?
            t36_oracle "$2" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$1/drive-after.json" 2>"$1/drive-after.err" || return 1
            if [ "$t36_drive_rc" -eq 86 ]; then
                [ "$t36_round" -eq "$4" ] && [ ! -s "$1/drive.out" ] && [ ! -s "$1/drive.err" ] || return 1
                t36_drive_ok=1
                break
            fi
            [ "$t36_drive_rc" -eq 3 ] && [ ! -s "$1/drive.err" ] \
                && t36_pending_ok "$1/drive.out" \
                && t36_step_ok "$1/drive-before.json" "$1/drive-after.json" || return 1
        done
        [ "$t36_drive_ok" -eq 1 ]
    }
    t36_drive_to_final() { # sandbox container base-oracle expected-rounds
        t36_drive_ok=0
        for t36_round in 0 1 2 3 4 5 6 7 8 9; do
            t36_oracle "$2" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$1/final-before.json" 2>"$1/final-before.err" || return 1
            if t36_phase_ok "$3" "$1/final-before.json" did-previs-cell-free "$2"; then
                [ "$t36_round" -eq "$4" ] || return 1
                t36_drive_ok=1
                break
            fi
            [ "$t36_round" -lt 9 ] || return 1
            t36_gc "$1" '' >"$1/resume.out" 2>"$1/resume.err"; t36_drive_rc=$?
            t36_oracle "$2" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$1/final-after.json" 2>"$1/final-after.err" || return 1
            [ "$t36_drive_rc" -eq 3 ] && [ ! -s "$1/resume.err" ] \
                && t36_pending_ok "$1/resume.out" \
                && t36_step_ok "$1/final-before.json" "$1/final-after.json" || return 1
        done
        [ "$t36_drive_ok" -eq 1 ]
    }

    for t36_phase in will-previsibility-cancel previsibility-cancelled did-previsibility-cancel group-visible will-previs-cell-free previs-free-receipt-frame-committed previs-cell-free did-previs-cell-free; do
        t36="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t36-phase.XXXXXX")"; t33_fixture "$t36"
        t33_start "$t36" "$t33_nonce_a" 'catalog-root:root-successor-durable' >"$t36/start.out" 2>"$t36/start.err"
        t36_container="$(find "$t36/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t36_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t36/base.json" 2>"$t36/base.err"
        case "$t36_phase" in
            will-previsibility-cancel|previsibility-cancelled|did-previsibility-cancel)
                t36_barrier_round=3; t36_resume_rounds=8 ;;
            group-visible) t36_barrier_round=9; t36_resume_rounds=1 ;;
            will-previs-cell-free|previs-free-receipt-frame-committed|previs-cell-free)
                t36_barrier_round=10; t36_resume_rounds=1 ;;
            did-previs-cell-free) t36_barrier_round=10; t36_resume_rounds=0 ;;
        esac
        case "$t36_phase" in
            did-previsibility-cancel) t36_resume_rounds=7 ;;
        esac
        case "$t36_phase" in
            previsibility-cancelled|previs-cell-free) t36_barrier="catalog-recovery:$t36_phase" ;;
            previs-free-receipt-frame-committed) t36_barrier="catalog-segment:$t36_phase" ;;
            *) t36_barrier="catalog-root:$t36_phase" ;;
        esac
        t36_drive_to_barrier "$t36" "$t36_container" "$t36_barrier" "$t36_barrier_round"; t36_kill_rc=$?
        t33_oracle "$t36_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t36/prior.json" 2>"$t36/prior.err"; t36_oracle_rc=$?
        if [ "$t36_kill_rc" -eq 0 ] && [ "$t36_oracle_rc" -eq 0 ] \
            && t36_phase_ok "$t36/base.json" "$t36/prior.json" "$t36_phase" "$t36_container"; then
            pass "T36 public GC $t36_phase crash exposes exact PREVIS prior"
        else
            fail "T36 public GC $t36_phase crash exposes exact PREVIS prior" "driver_rc=$t36_kill_rc oracle_rc=$t36_oracle_rc round=${t36_round:-none} out=$(tr '\n' ' ' < "$t36/drive.out") stderr=$(tr '\n' ' ' < "$t36/drive.err")"
        fi
        t36_drive_to_final "$t36" "$t36_container" "$t36/base.json" "$t36_resume_rounds"; t36_resume_rc=$?
        t33_oracle "$t36_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t36/final.json" 2>"$t36/final.err"; t36_final_rc=$?
        if [ "$t36_resume_rc" -eq 0 ] && [ "$t36_final_rc" -eq 0 ] \
            && t36_phase_ok "$t36/base.json" "$t36/final.json" did-previs-cell-free "$t36_container"; then
            pass "T36 matching public GC resumes $t36_phase exactly once through PREVIS ROOT did-free"
        else
            fail "T36 matching public GC resumes $t36_phase exactly once through PREVIS ROOT did-free" "driver_rc=$t36_resume_rc oracle_rc=$t36_final_rc round=${t36_round:-none} out=$(tr '\n' ' ' < "$t36/resume.out") stderr=$(tr '\n' ' ' < "$t36/resume.err")"
        fi
        rm -rf "$t36"
    done
else
    skip "T36 public PREVIS cancellation requires T33 GENESIS capability and gc-step CLI"
fi

# ---------------------------------------------------------------------------
# T37  Public snapshot producer -> catalog claim frame and immutable OWNER.
# SubagentStart is the supported producer driver.  The independent T33
# oracle parses the claim pack, its selected CELL, ROOT and immutable segment.
# Green here proves producer creation/release only.  It does not prove the
# bounded claim walker, GC journal/checkpoint/receipt/anchor, terminal handoff,
# or migration retirement; those require public gc-step observation points.
# ---------------------------------------------------------------------------
if [ "${t33_supported:-0}" -eq 1 ] && [ -x hooks/scripts/agent-runtime-state.sh ]; then
    t37_seed='13579bdf2468ace013579bdf2468ace0'
    # nonce_hex() is independently invoked twice with its domain-local attempt
    # zero.  A deterministic 32-hex fixture seed therefore owns both halves.
    t37_nonce="${t37_seed}${t37_seed}"
    t37_phase_nonce="${t33_nonce_a}${t33_nonce_a}"
    t37_claim_digest() { # instance-key deterministic-native-seed
        python3 - "$1" "$2" <<'PY'
import hashlib,json,sys
key,seed=sys.argv[1:]; nonce=seed+seed
logical={"schema_version":1,"purpose":"snapshot-temp","instance_key":key,"parent_txn_id":nonce}
print(hashlib.sha256(json.dumps(logical,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()).hexdigest())
PY
    }
    t37_fixture() { # sandbox
        t33_fixture "$1"
        mkdir -p "$1/.git"
        printf 'claim-producer-physical-input\n' > "$1/deliverable.txt"
        bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
            gc-step "$1/.zyz-worker/tasks/task" manual >"$1/genesis.out" 2>"$1/genesis.err"
    }
    t37_unavailable_ok() { # host-rc stdout stderr
        [ "$1" -eq 0 ] && [ ! -s "$2" ] \
            && t33_diag_exact "$3" 'SubagentStart runtime tracking unavailable'
    }
    t37_fresh_conflict_ok() { # before after output stderr rc
        [ "$5" -eq 0 ] && [ ! -s "$3" ] && t33_diag_exact "$4" identity-conflict \
            && t33_diff_ok "$1" "$2" committed
    }
    t37_public() { # sandbox barrier deterministic-native-seed-or-empty same-owner-seam-0|1 raw-id-or-default role-or-default
        (
            cd "$1" || exit 1
            printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"%s","agent_type":"zyz-worker:%s"}' \
                "$1" "${5:-$t33_raw}" "${6:-$t33_role}" | env \
                ZYZ_TEST_TRANSITION_STOP_AFTER="$2" \
                ZYZ_TEST_RANDOM_HEX_SEQUENCE="$3" \
                ZYZ_TEST_CLAIM_REPLAY_SAME_OWNER="${4:-0}" \
                bash "$REPO_ROOT/hooks/scripts/subagent-track.sh"
        )
    }
    t37_phase_ok() { # base-oracle observed-oracle phase agents-dir nonce
        python3 - "$1" "$2" "$3" "$4" "$5" "$t33_key" <<'PY'
import hashlib,json,os,re,stat,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); phase,agents,nonce,key=sys.argv[3:]
D=lambda domain,value:hashlib.sha256(domain+value).digest()
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
H=lambda value:re.fullmatch(r"[0-9a-f]{64}",str(value)) is not None
logical={"schema_version":1,"purpose":"snapshot-temp","instance_key":key,"parent_txn_id":nonce}
claim_digest=hashlib.sha256(J(logical)).hexdigest(); request=262144+134217728
audit_request=b.get("expected_request_bytes"); total_request=request+audit_request if isinstance(audit_request,int) else -1
if set(x["claims"])!={claim_digest} or set(x["claim_cells"])!={claim_digest}: raise SystemExit(1)
claim=x["claims"][claim_digest]; records=claim["records"]; immutable=records.get("IMMUTABLE_KEY",{}).get("payload",{})
owner=records.get("OWNER",{}).get("payload",{}); observation=records.get("OBSERVATION",{}).get("payload")
cell=x["claim_cells"][claim_digest]; directory=cell["selected_directory"]; recovery=cell["selected_recovery"]
claim_name=claim_digest+".claim-pack.v1"
producer_slots={"IMMUTABLE_KEY","OWNER"} if phase=="will-claim-frame" else {"IMMUTABLE_KEY","OWNER","OBSERVATION"}
header_generation={"will-claim-frame":3,"frame-will":4,"claim-frame-committed":4,
 "did-claim-frame":4,"claimed":5,"same-owner-replay":5,"owner-did-create":6,
 "owner-released-clean":7}[phase]
owner_generation=1 if phase not in ("owner-did-create","owner-released-clean") else (2 if phase=="owner-did-create" else 3)
observation_generation=None if phase=="will-claim-frame" else (1 if phase in ("frame-will","claim-frame-committed","did-claim-frame") else 2)
owner_fields={"nonce","creator_pid","creator_boot_id","creator_birth_token","writer_pid",
 "writer_birth_token","task_id","task_identity_digest","root_identity_digest",
 "runtime_identity_digest","runtime_mount_id","native_binding_digest","instance_key_digest",
 "temp_basename","max_paths","max_file_bytes","max_total_bytes","max_temp_bytes",
 "targets","schema_version","state","created_epoch","hostname","logical_key_sha256",
 "instance_key","purpose","parent_txn_id"}
expected_owner_fields=set(owner_fields)
if phase in ("owner-did-create","owner-released-clean"): expected_owner_fields.add("target_identities")
if phase=="owner-released-clean": expected_owner_fields.update(("released_epoch","released_target_set_digest"))
targets=[
 {"basename":".snapshot-tmp."+nonce,"type":"directory","mode":448,"max_physical_bytes":134217728},
 {"basename":"baseline-a.records","parent_basename":".snapshot-tmp."+nonce,
  "type":"regular","max_physical_bytes":33554432},
 {"basename":"observation.json","parent_basename":".snapshot-tmp."+nonce,
  "type":"regular","max_physical_bytes":16384},
]
ok=(not x["forbidden_names"] and set(records)==producer_slots and
 claim["header_generation"]==header_generation and
 claim["selected"].get("IMMUTABLE_KEY",{}).get("generation")==1 and
 claim["selected"].get("OWNER",{}).get("generation")==owner_generation and
 ((observation_generation is None and "OBSERVATION" not in claim["selected"]) or
  claim["selected"].get("OBSERVATION",{}).get("generation")==observation_generation) and
 claim["size"]==262144 and claim["allocated"]>=262144 and
 claim["regular"] and claim["nlink"]==1 and set(owner)==expected_owner_fields and owner.get("schema_version")==1 and
 owner.get("nonce")==nonce and owner.get("task_id")=="task" and owner.get("instance_key")==key and
 owner.get("purpose")=="snapshot-temp" and owner.get("parent_txn_id")==nonce and
 owner.get("logical_key_sha256")==claim_digest and owner.get("temp_basename")==".snapshot-tmp."+nonce and
 owner.get("max_paths")==10000 and owner.get("max_file_bytes")==16777216 and
 owner.get("max_total_bytes")==67108864 and owner.get("max_temp_bytes")==134217728 and
 owner.get("targets")==targets and
 isinstance(owner.get("creator_pid"),int) and owner["creator_pid"]>0 and
 isinstance(owner.get("writer_pid"),int) and owner["writer_pid"]>0 and
 all(H(owner.get(name)) for name in ("task_identity_digest","root_identity_digest",
     "runtime_identity_digest","native_binding_digest","instance_key_digest")) and
 owner.get("instance_key_digest")==hashlib.sha256(key.encode()).hexdigest() and
 isinstance(owner.get("runtime_mount_id"),str) and owner["runtime_mount_id"] and
 isinstance(owner.get("creator_boot_id"),str) and owner["creator_boot_id"] and
 isinstance(owner.get("creator_birth_token"),str) and owner["creator_birth_token"] and
 isinstance(owner.get("writer_birth_token"),str) and owner["writer_birth_token"] and
 immutable=={**logical,"logical_key_sha256":claim_digest,"claim_pack_basename":claim_name,
  "max_data_bytes":134217728,"reservation_bytes":request,
  "recovery_cell_index":directory["index"],"reservation_digest":recovery["payload"]["reservation_digest"],
  "pack_identity_digest":immutable.get("pack_identity_digest")} and H(immutable.get("pack_identity_digest")) and
 directory is not None and directory["state"]==2 and recovery is not None and
 recovery["payload"]["state"]=="ACTIVE_ACK" and
 recovery["payload"]["reservation_digest"]==immutable.get("reservation_digest") and
 audit_request==1052672 and b["root_meta"].get("owned_bytes")==33554432 and
 x["root_meta"].get("owned_bytes")==169086976==b["root_meta"].get("owned_bytes")+total_request and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")+2 and
 x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+2)
sequence=b["root_meta"].get("next_sequence")
frames=[]
for segment in x["segments"].values():
 frames.extend(item for item in segment["frames"] if item["kind"]=="claim" and
               item["payload"].get("logical_key_sha256")==claim_digest)
frame=frames[0] if len(frames)==1 else None
will=x["root_meta"].get("claim_frame_will")
before_frame=phase in ("will-claim-frame","frame-will")
before_did=phase in ("will-claim-frame","frame-will","claim-frame-committed")
if before_frame: ok=ok and not frames
else:
 ok=ok and frame is not None and frame["payload"]=={
  "schema_version":1,"frame_type":"claim","sequence":sequence,
  "logical_key_sha256":claim_digest,"claim_pack_basename":claim_name,
  "pack_identity_digest":immutable["pack_identity_digest"],"recovery_cell_index":directory["index"],
  "reservation_digest":immutable["reservation_digest"],"reservation_bytes":request,
  "purpose":"snapshot-temp","instance_key":key,
  "parent_txn_sha256":hashlib.sha256(nonce.encode()).hexdigest()}
if before_did:
 ok=ok and x["root_generation"]==b["root_generation"]+7 and isinstance(will,dict)
 ok=ok and will=={"sequence":sequence,"logical_key_sha256":claim_digest,
  "segment_generation":1,"frame_offset":0,"frame_length":will.get("frame_length"),
  "frame_digest":will.get("frame_digest")} and H(will.get("frame_digest"))
 ok=ok and ((frame is None) or (frame["length"]==will["frame_length"] and
  frame["digest"]==will["frame_digest"] and frame["offset"]==will["frame_offset"]))
else:
 root_delta=9 if phase=="owner-released-clean" else 8
 ok=ok and x["root_generation"]==b["root_generation"]+root_delta and will is None and frame is not None
 ok=ok and x["root_meta"].get("next_sequence")==sequence+1
 ok=ok and x["root_meta"].get("last_claim_key_sha256")==claim_digest
 ok=ok and x["root_meta"].get("last_claim_frame_digest")==frame["digest"]
 if phase=="owner-released-clean": ok=ok and x["root_meta"].get("claim_scan_due") is True
 else: ok=ok and x["root_meta"].get("claim_scan_due")==b["root_meta"].get("claim_scan_due")
if phase=="will-claim-frame": ok=ok and observation is None
elif phase in ("frame-will","claim-frame-committed","did-claim-frame"):
 want_digest=will["frame_digest"] if will is not None else frame["digest"]
 ok=ok and observation is not None and set(observation)=={"schema_version","state","sequence",
  "frame_digest","segment_generation","frame_offset","frame_length","prepared_root_digest",
  "last_observed_epoch","retry_epoch","blocked"} and observation.get("state")=="frame-will"
 ok=ok and observation.get("sequence")==sequence and observation.get("frame_digest")==want_digest
 ok=ok and observation.get("segment_generation")==1 and observation.get("frame_offset")==0
 ok=ok and H(observation.get("prepared_root_digest")) and observation.get("retry_epoch") is None and observation.get("blocked") is None
else:
 ok=ok and observation is not None and set(observation)=={"schema_version","state","sequence",
  "frame_digest","claimed_root_digest","last_observed_epoch","retry_epoch","blocked"} and observation.get("state")=="claimed"
 ok=ok and observation.get("sequence")==sequence and observation.get("frame_digest")==frame["digest"]
 claimed_generation=b["root_generation"]+8
 if phase=="owner-released-clean":
  # The claim-did ROOT remains the predecessor authority; release-clean then
  # publishes a distinct claim_scan_due successor.  Never substitute either
  # generation's digest for the other.
  ok=ok and x["root_generation"]==claimed_generation+1
  ok=ok and H(x.get("root_predecessor")) and H(x.get("root_digest"))
  ok=ok and observation.get("claimed_root_digest")==x.get("root_predecessor")
  ok=ok and observation.get("claimed_root_digest")!=x.get("root_digest")
  ok=ok and x["root_meta"].get("claim_scan_due") is True
  ok=ok and x["root_meta"].get("schedule_digest")==x.get("schedule",{}).get("digest")
 else:
  ok=ok and x["root_generation"]==claimed_generation and H(x.get("root_digest"))
  ok=ok and observation.get("claimed_root_digest")==x.get("root_digest")
want_owner="will-create"
if phase=="owner-did-create": want_owner="did-create"
if phase=="owner-released-clean": want_owner="released-clean"
ok=ok and owner.get("state")==want_owner
owner_path=os.path.join(agents,".snapshot-owner."+nonce); temp_path=os.path.join(agents,".snapshot-tmp."+nonce)
if phase=="owner-did-create":
 target=owner.get("target_identities")
 ok=ok and not os.path.lexists(owner_path) and os.path.isdir(temp_path) and isinstance(target,list) and len(target)==1
 ok=ok and set(target[0])=={"basename","type","dev","ino","nlink","mode","mount_id"}
 ok=ok and target[0].get("basename")==os.path.basename(temp_path) and target[0].get("type")=="directory"
 st=os.lstat(temp_path)
 ok=ok and (target[0].get("dev"),target[0].get("ino"),target[0].get("nlink"),target[0].get("mode"))==(st.st_dev,st.st_ino,st.st_nlink,stat.S_IMODE(st.st_mode))
 ok=ok and target[0].get("mount_id")==owner.get("runtime_mount_id")
if phase=="owner-released-clean":
 target=owner.get("target_identities")
 want=D(b"zyz-claim-released-target-set-v1",J(target)).hex()
 ok=ok and isinstance(target,list) and len(target)==1 and not os.path.lexists(owner_path)
 ok=ok and not os.path.lexists(temp_path) and isinstance(owner.get("released_epoch"),int)
 ok=ok and owner.get("released_target_set_digest")==want
raise SystemExit(0 if ok else 1)
PY
    }
    t37_changed_owner_ok() { # base-oracle observed-oracle agents-dir nonce
        python3 - "$1" "$2" "$3" "$4" "$t33_key" <<'PY'
import base64,hashlib,hmac,json,os,re,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));agents,nonce,key=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
H=lambda value:re.fullmatch(r"[0-9a-f]{64}",str(value)) is not None
logical={"schema_version":1,"purpose":"snapshot-temp","instance_key":key,"parent_txn_id":nonce}
digest=hashlib.sha256(J(logical)).hexdigest();claim=x["claims"].get(digest,{})
records=claim.get("records",{});selected=claim.get("selected",{});cell=x["claim_cells"].get(digest,{})
immutable=records.get("IMMUTABLE_KEY",{}).get("payload",{});owner=records.get("OWNER",{}).get("payload",{})
obs=records.get("OBSERVATION",{}).get("payload",{});journal=records.get("GC_JOURNAL",{}).get("payload",{})
keyrec=records.get("KEY",{}).get("payload",{});receipt=records.get("RECEIPT",{}).get("payload",{})
directory=cell.get("selected_directory",{});recovery=cell.get("selected_recovery",{})
request=262144+134217728;claim_name=digest+".claim-pack.v1"
targets=[
 {"basename":".snapshot-tmp."+nonce,"type":"directory","mode":448,"max_physical_bytes":134217728},
 {"basename":"baseline-a.records","parent_basename":".snapshot-tmp."+nonce,
  "type":"regular","max_physical_bytes":33554432},
 {"basename":"observation.json","parent_basename":".snapshot-tmp."+nonce,
  "type":"regular","max_physical_bytes":16384},
]
owner_fields={"nonce","creator_pid","creator_boot_id","creator_birth_token","writer_pid",
 "writer_birth_token","task_id","task_identity_digest","root_identity_digest",
 "runtime_identity_digest","runtime_mount_id","native_binding_digest","instance_key_digest",
 "temp_basename","max_paths","max_file_bytes","max_total_bytes","max_temp_bytes","targets",
 "schema_version","state","created_epoch","hostname","logical_key_sha256","instance_key",
 "purpose","parent_txn_id","target_identities","released_epoch","released_target_set_digest"}
target_identities=owner.get("target_identities")
producer_ok=(set(owner)==owner_fields and owner.get("schema_version")==1 and
 owner.get("state")=="released-clean" and owner.get("nonce")==nonce and owner.get("task_id")=="task" and
 owner.get("logical_key_sha256")==digest and owner.get("instance_key")==key and
 owner.get("purpose")=="snapshot-temp" and owner.get("parent_txn_id")==nonce and
 owner.get("temp_basename")==targets[0]["basename"] and owner.get("targets")==targets and
 owner.get("max_paths")==10000 and owner.get("max_file_bytes")==16777216 and
 owner.get("max_total_bytes")==67108864 and owner.get("max_temp_bytes")==134217728 and
 isinstance(owner.get("created_epoch"),int) and isinstance(owner.get("released_epoch"),int) and
 owner["released_epoch"]>=owner["created_epoch"] and
 isinstance(owner.get("creator_pid"),int) and owner["creator_pid"]>0 and
 isinstance(owner.get("writer_pid"),int) and owner["writer_pid"]>0 and
 isinstance(owner.get("creator_boot_id"),str) and owner["creator_boot_id"] and
 isinstance(owner.get("creator_birth_token"),str) and owner["creator_birth_token"] and
 isinstance(owner.get("writer_birth_token"),str) and owner["writer_birth_token"] and
 all(H(owner.get(name)) for name in ("task_identity_digest","root_identity_digest",
     "runtime_identity_digest","native_binding_digest","instance_key_digest")) and
 owner.get("instance_key_digest")==hashlib.sha256(key.encode()).hexdigest() and
 isinstance(owner.get("runtime_mount_id"),str) and owner["runtime_mount_id"] and
 isinstance(target_identities,list) and len(target_identities)==1 and
 set(target_identities[0])=={"basename","type","dev","ino","nlink","mode","mount_id"} and
 target_identities[0].get("basename")==targets[0]["basename"] and
 target_identities[0].get("type")=="directory" and target_identities[0].get("mode")==448 and
 all(isinstance(target_identities[0].get(name),int) and target_identities[0][name]>=0
     for name in ("dev","ino","nlink")) and target_identities[0].get("nlink")>=1 and
 target_identities[0].get("mount_id")==owner.get("runtime_mount_id") and
 owner.get("released_target_set_digest")==hashlib.sha256(
  b"zyz-claim-released-target-set-v1"+J(target_identities)).hexdigest() and
 not os.path.lexists(os.path.join(agents,targets[0]["basename"])))
immutable_ok=(immutable=={**logical,"logical_key_sha256":digest,"claim_pack_basename":claim_name,
 "max_data_bytes":134217728,"reservation_bytes":request,
 "recovery_cell_index":directory.get("index"),
 "reservation_digest":recovery.get("payload",{}).get("reservation_digest"),
 "pack_identity_digest":immutable.get("pack_identity_digest")} and H(immutable.get("pack_identity_digest")))
obs_ok=(set(obs)=={"schema_version","state","sequence","frame_digest","claimed_root_digest",
 "last_observed_epoch","retry_epoch","blocked"} and obs.get("schema_version")==1 and
 obs.get("state")=="claimed" and isinstance(obs.get("sequence"),int) and obs["sequence"]>0 and
 H(obs.get("frame_digest")) and H(obs.get("claimed_root_digest")) and
 obs.get("last_observed_epoch")==owner.get("created_epoch") and
 obs.get("retry_epoch") is None and obs.get("blocked") is None)
cell_ok=(directory.get("state")==2 and directory.get("index")==immutable.get("recovery_cell_index") and
 directory.get("fields",[None,None])[0]==cell.get("subject_digest") and
 directory.get("fields",[None,None])[1]==recovery.get("digest") and
 directory.get("cell_generation")==recovery.get("generation") and
 recovery.get("payload",{}).get("state")=="ACTIVE_ACK" and
 recovery.get("payload",{}).get("subject_digest")==cell.get("subject_digest") and
 recovery.get("payload",{}).get("reservation_digest")==immutable.get("reservation_digest"))
frames=[item for segment in x["segments"].values() for item in segment["frames"]
 if item["kind"]=="claim" and item["payload"].get("logical_key_sha256")==digest]
frame=frames[0] if len(frames)==1 else {}
frame_ok=(len(frames)==1 and frame.get("digest")==obs.get("frame_digest") and frame.get("payload")=={
 "schema_version":1,"frame_type":"claim","sequence":obs.get("sequence"),
 "logical_key_sha256":digest,"claim_pack_basename":claim_name,
 "pack_identity_digest":immutable.get("pack_identity_digest"),
 "recovery_cell_index":directory.get("index"),"reservation_digest":immutable.get("reservation_digest"),
 "reservation_bytes":request,"purpose":"snapshot-temp","instance_key":key,
 "parent_txn_sha256":hashlib.sha256(nonce.encode()).hexdigest()})
expected_generations={"IMMUTABLE_KEY":1,"OWNER":3,"OBSERVATION":2,"GC_JOURNAL":8,"KEY":2,"RECEIPT":1}
selector_ok=(set(records)==set(selected)==set(expected_generations) and claim.get("header_generation")==18 and
 all(records[name].get("generation")==generation and selected[name].get("generation")==generation and
     selected[name].get("digest")==records[name].get("digest")
     for name,generation in expected_generations.items()) and H(claim.get("header_predecessor")) and
 H(claim.get("header_digest")) and claim.get("header_predecessor")!=claim.get("header_digest"))
empty_digest=JD([]);body={name:value for name,value in receipt.items() if name!="hmac_sha256"}
try:key_bytes=base64.b64decode(keyrec.get("key_b64",""),validate=True)
except Exception:key_bytes=b""
journal_fields={"schema_version","phase","logical_key_sha256","instance_key","owner_digest","claim_kind",
 "targets","target_set_digest","intent_digests","staging_digest","live_inventory_digest","tree_bounds",
 "key_b64","key_digest","quarantine_count","deleted_count","bytes_reclaimed","verified_entries",
 "verified_bytes","created_epoch","receipt_epoch","receipt_digest"}
lifecycle_ok=(set(journal)==journal_fields and journal.get("schema_version")==1 and
 journal.get("phase")=="waiting-receipt-anchor" and journal.get("logical_key_sha256")==digest and
 journal.get("instance_key")==key and journal.get("owner_digest")==JD(owner) and
 journal.get("claim_kind")=="zero" and journal.get("targets")==[] and
 journal.get("target_set_digest")==empty_digest and journal.get("intent_digests")==[] and
 journal.get("staging_digest") is None and journal.get("live_inventory_digest") is None and
 journal.get("tree_bounds") is None and journal.get("quarantine_count")==0 and
 journal.get("deleted_count")==journal.get("bytes_reclaimed")==0 and
 journal.get("verified_entries")==journal.get("verified_bytes")==0 and
 isinstance(journal.get("created_epoch"),int) and journal.get("receipt_epoch")==journal.get("created_epoch") and
 len(key_bytes)==32 and hashlib.sha256(key_bytes).hexdigest()==journal.get("key_digest") and
 keyrec=={"schema_version":1,"state":"active","key_b64":journal.get("key_b64"),
  "key_digest":journal.get("key_digest")} and
 body=={"schema_version":1,"state":"waiting-receipt-anchor","logical_key_sha256":digest,
  "instance_key":key,"owner_digest":journal.get("owner_digest"),"claim_kind":"zero",
  "target_set_digest":empty_digest,"deleted_count":0,"bytes_reclaimed":0,"verified_entries":0,
  "verified_bytes":0,"result":"compacted","committed_epoch":journal.get("receipt_epoch")} and
 receipt.get("hmac_sha256")==hmac.new(key_bytes,J(body),hashlib.sha256).hexdigest() and
 journal.get("receipt_digest")==JD(receipt))
rm=x["root_meta"];bm=b["root_meta"]
root_ok=(x.get("root_generation")==b.get("root_generation")+11 and H(x.get("root_digest")) and
 H(x.get("root_predecessor")) and x.get("root_digest")!=x.get("root_predecessor") and
 obs.get("claimed_root_digest") not in (x.get("root_digest"),x.get("root_predecessor")) and
 rm.get("owned_bytes")==bm.get("owned_bytes")+1052672+request and
 rm.get("active_claims")==bm.get("active_claims")+2 and
 rm.get("active_data_claims")==bm.get("active_data_claims")+1 and
 rm.get("counter_generation")==bm.get("counter_generation")+2 and
 rm.get("next_sequence")==bm.get("next_sequence")+1 and
 rm.get("active_segment_claim_count")==bm.get("active_segment_claim_count")+1 and
 rm.get("last_claim_key_sha256")==digest and rm.get("last_claim_frame_digest")==frame.get("digest") and
 rm.get("pending_anchor_claim_sha256")==digest and rm.get("claim_scan_due") is True and
 rm.get("sweep_generation")==bm.get("sweep_generation")+1 and rm.get("sweep_cutoff_sequence")==0 and
 rm.get("sweep_segment_generation")==rm.get("sweep_start_segment_generation")==
  rm.get("first_active_segment_generation")==1 and rm.get("sweep_offset")==0 and
 rm.get("sweep_next_gc_epoch") is None and x.get("schedule")==b.get("schedule"))
ok=(not x["forbidden_names"] and set(x["claims"])==set(x["claim_cells"])=={digest} and
 claim.get("size")==262144 and claim.get("allocated",0)>=262144 and claim.get("regular") is True and
 claim.get("nlink")==1 and producer_ok and immutable_ok and obs_ok and cell_ok and frame_ok and
 selector_ok and lifecycle_ok and root_ok)
raise SystemExit(0 if ok else 1)
PY
    }
    t37_success_ok() { # silent-hook-output oracle agents-dir base-oracle
        python3 - "$1" "$2" "$3" "$4" "$t33_key" <<'PY'
import base64,hashlib,hmac,json,os,re,sys
public_raw=open(sys.argv[1],encoding="utf-8").read(); x=json.load(open(sys.argv[2])); agents=sys.argv[3]
b=json.load(open(sys.argv[4])); key=sys.argv[5]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
D=lambda domain,value:hashlib.sha256(domain+value).hexdigest()
claims=x["claims"]; cells=x["claim_cells"]; audit=x["packs"]["audit"]; work=x["packs"]["work"]
ar=audit["records"]; wr=work["records"]
journal=wr.get("PUBLICATION_JOURNAL",{}).get("payload",{}); live=wr.get("LIVE_INVENTORY",{}).get("payload",{})
staged=journal.get("staged_inventory",{}); active=staged.get("active",[]) if isinstance(staged,dict) else []
publish_targets=journal.get("publish_targets",[]) if isinstance(journal.get("publish_targets"),list) else []
physical_fields=("basename","type","size","sha256","dev","ino","nlink","mtime_ns","mount_id")
producer_fields=physical_fields+("purpose","generation")
physical=[{name:item[name] for name in physical_fields} for item in publish_targets]
projected=[{name:item[name] for name in producer_fields} for item in publish_targets]
expected_live={name:value for name,value in staged.items() if name!="staged"}
publication_logical={"schema_version":1,"purpose":"snapshot-publication","instance_key":key,"parent_txn_id":"publication-1"}
publication_digest=hashlib.sha256(J(publication_logical)).hexdigest()
publication=claims.get(publication_digest,{}); pub_immutable=publication.get("records",{}).get("IMMUTABLE_KEY",{}).get("payload",{})
publication_bytes=sum(item.get("size",-1) for item in physical)
temp_claim_count=sum(1 for claim in claims.values() if claim.get("records",{}).get("IMMUTABLE_KEY",{}).get("payload",{}).get("purpose")=="snapshot-temp")
claim_count=len(claims); audit_request=b.get("expected_request_bytes")
available=set(wr)=={"TRANSITION_JOURNAL","PUBLICATION_JOURNAL","LIVE_INVENTORY"}
fail_open=set(wr)=={"TRANSITION_JOURNAL"}
ordinary_ok=(set(x["packs"])=={"audit","work"} and
 all(row.get("size")==524288 and row.get("allocated",0)>=524288 and row.get("regular") is True and row.get("nlink")==1 for row in x["packs"].values()) and
 isinstance(x.get("lock"),dict) and x["lock"].get("size")==audit_request-1048576 and
 x["lock"].get("allocated",0)>=x["lock"].get("size",1) and x["lock"].get("regular") is True and x["lock"].get("nlink")==1 and
 set(ar)=={"IDENTITY","START"} and wr.get("TRANSITION_JOURNAL",{}).get("payload",{}).get("phase")=="committed" and
 x.get("selected_cell") is not None and x["selected_cell"].get("state")==2 and
 x["selected_cell"].get("recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK")
available_ok=(available and temp_claim_count==2 and claim_count==3 and publication_digest in claims and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")+4 and
 x["root_meta"].get("active_data_claims")==b["root_meta"].get("active_data_claims")+3 and
 x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+4 and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")+audit_request+
  2*(262144+134217728)+262144+publication_bytes and
 work.get("header_generation")==14 and
 journal.get("txn_type")=="snapshot-publish" and journal.get("phase")=="committed" and journal.get("generation")==1 and
 journal.get("publication_owner_state")=="did-create" and journal.get("source_cleanup_state")=="released-clean" and
 journal.get("publication_claim_key_sha256")==publication_digest and
 set(staged)=={"schema_version","instance_key","generation","active","committed_epoch","staged"} and
 staged.get("schema_version")==1 and staged.get("instance_key")==key and staged.get("generation")==1 and staged.get("staged") is True and
 len(active)==len(publish_targets)==len(projected)==2 and active==projected and
 {item.get("purpose") for item in active}=={"baseline-records","baseline-header"} and
 {item.get("generation") for item in active}=={1} and
 live==expected_live and set(live)=={"schema_version","instance_key","generation","active","committed_epoch"} and
 journal.get("publication_claim_owner_facts",{}).get("targets")==physical and
 journal.get("publication_claim_max_data_bytes")==publication_bytes and
 pub_immutable.get("max_data_bytes")==publication_bytes and publication_bytes>=0)
fail_open_ok=(fail_open and temp_claim_count==claim_count==1 and publication_digest not in claims and
 journal==live=={} and not publish_targets and not active and
 x["root_meta"].get("owned_bytes")==169086976 and
 x["root_meta"].get("active_claims")==2 and
 x["root_meta"].get("active_data_claims")==1 and
 x["root_meta"].get("counter_generation")==2)
ok=(public_raw=="" and audit_request==1052672 and ordinary_ok and not x["forbidden_names"] and
 set(cells)==set(claims) and (available_ok or fail_open_ok))
H=lambda value:re.fullmatch(r"[0-9a-f]{64}",str(value)) is not None
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
frames=[item for segment in x["segments"].values() for item in segment["frames"] if item["kind"]=="claim"]
frames_by={digest:[item for item in frames if item["payload"].get("logical_key_sha256")==digest]
           for digest in claims}
def selector_ok(claim,generations,header_generation):
 records=claim.get("records",{});selected=claim.get("selected",{})
 return (set(records)==set(selected)==set(generations) and
  claim.get("header_generation")==header_generation and H(claim.get("header_predecessor")) and
  H(claim.get("header_digest")) and claim.get("header_predecessor")!=claim.get("header_digest") and
  all(records[name].get("generation")==generation and
      selected[name].get("generation")==generation and
      selected[name].get("digest")==records[name].get("digest")
      for name,generation in generations.items()))
def cell_ok(cell,immutable):
 directory=cell.get("selected_directory",{});recovery=cell.get("selected_recovery",{})
 return (directory.get("state")==2 and directory.get("index")==immutable.get("recovery_cell_index") and
  directory.get("fields",[None,None])[0]==cell.get("subject_digest") and
  directory.get("fields",[None,None])[1]==recovery.get("digest") and
  directory.get("cell_generation")==recovery.get("generation") and
  recovery.get("payload",{}).get("state")=="ACTIVE_ACK" and
  recovery.get("payload",{}).get("subject_digest")==cell.get("subject_digest") and
  recovery.get("payload",{}).get("reservation_digest")==immutable.get("reservation_digest"))
def frame_ok(digest,immutable,obs,cell,purpose,parent):
 rows=frames_by.get(digest,[]);frame=rows[0] if len(rows)==1 else {}
 directory=cell.get("selected_directory",{});request=262144+immutable.get("max_data_bytes",-1)
 return (len(rows)==1 and frame.get("digest")==obs.get("frame_digest") and frame.get("payload")=={
  "schema_version":1,"frame_type":"claim","sequence":obs.get("sequence"),
  "logical_key_sha256":digest,"claim_pack_basename":digest+".claim-pack.v1",
  "pack_identity_digest":immutable.get("pack_identity_digest"),
  "recovery_cell_index":directory.get("index"),"reservation_digest":immutable.get("reservation_digest"),
  "reservation_bytes":request,"purpose":purpose,"instance_key":key,
  "parent_txn_sha256":hashlib.sha256(parent.encode()).hexdigest()})
def observation_ok(obs,owner):
 return (set(obs)=={"schema_version","state","sequence","frame_digest","claimed_root_digest",
  "last_observed_epoch","retry_epoch","blocked"} and obs.get("schema_version")==1 and
  obs.get("state")=="claimed" and isinstance(obs.get("sequence"),int) and obs["sequence"]>0 and
  H(obs.get("frame_digest")) and H(obs.get("claimed_root_digest")) and
  obs.get("last_observed_epoch")==owner.get("created_epoch") and
  obs.get("retry_epoch") is None and obs.get("blocked") is None)
def zero_lifecycle_ok(records,digest,owner):
 journal=records.get("GC_JOURNAL",{}).get("payload",{});keyrec=records.get("KEY",{}).get("payload",{})
 receipt=records.get("RECEIPT",{}).get("payload",{});body={n:v for n,v in receipt.items() if n!="hmac_sha256"}
 try:key_bytes=base64.b64decode(keyrec.get("key_b64",""),validate=True)
 except Exception:key_bytes=b""
 empty_digest=JD([])
 fields={"schema_version","phase","logical_key_sha256","instance_key","owner_digest","claim_kind",
  "targets","target_set_digest","intent_digests","staging_digest","live_inventory_digest","tree_bounds",
  "key_b64","key_digest","quarantine_count","deleted_count","bytes_reclaimed","verified_entries",
  "verified_bytes","created_epoch","receipt_epoch","receipt_digest"}
 return (set(journal)==fields and journal.get("schema_version")==1 and
  journal.get("phase")=="waiting-receipt-anchor" and journal.get("logical_key_sha256")==digest and
  journal.get("instance_key")==key and journal.get("owner_digest")==JD(owner) and
  journal.get("claim_kind")=="zero" and journal.get("targets")==[] and
  journal.get("target_set_digest")==empty_digest and journal.get("intent_digests")==[] and
  journal.get("staging_digest") is None and journal.get("live_inventory_digest") is None and
  journal.get("tree_bounds") is None and journal.get("quarantine_count")==0 and
  journal.get("deleted_count")==journal.get("bytes_reclaimed")==0 and
  journal.get("verified_entries")==journal.get("verified_bytes")==0 and
  isinstance(journal.get("created_epoch"),int) and journal.get("receipt_epoch")==journal.get("created_epoch") and
  len(key_bytes)==32 and hashlib.sha256(key_bytes).hexdigest()==journal.get("key_digest") and
  keyrec=={"schema_version":1,"state":"active","key_b64":journal.get("key_b64"),
   "key_digest":journal.get("key_digest")} and
  body=={"schema_version":1,"state":"waiting-receipt-anchor","logical_key_sha256":digest,
   "instance_key":key,"owner_digest":journal.get("owner_digest"),"claim_kind":"zero",
   "target_set_digest":empty_digest,"deleted_count":0,"bytes_reclaimed":0,"verified_entries":0,
   "verified_bytes":0,"result":"compacted","committed_epoch":journal.get("receipt_epoch")} and
  receipt.get("hmac_sha256")==hmac.new(key_bytes,J(body),hashlib.sha256).hexdigest() and
  journal.get("receipt_digest")==JD(receipt))
temp_owner_fields={"nonce","creator_pid","creator_boot_id","creator_birth_token","writer_pid",
 "writer_birth_token","task_id","task_identity_digest","root_identity_digest","runtime_identity_digest",
 "runtime_mount_id","native_binding_digest","instance_key_digest","temp_basename","max_paths",
 "max_file_bytes","max_total_bytes","max_temp_bytes","targets","schema_version","state","created_epoch",
 "hostname","logical_key_sha256","instance_key","purpose","parent_txn_id","target_identities",
 "released_epoch","released_target_set_digest"}
def temp_ok(digest,claim,cell,lifecycle):
 records=claim.get("records",{});immutable=records.get("IMMUTABLE_KEY",{}).get("payload",{})
 owner=records.get("OWNER",{}).get("payload",{});obs=records.get("OBSERVATION",{}).get("payload",{})
 nonce=owner.get("nonce");targets=owner.get("targets");directory=cell.get("selected_directory",{})
 recovery=cell.get("selected_recovery",{});identities=owner.get("target_identities")
 logical={"schema_version":1,"purpose":"snapshot-temp","instance_key":key,"parent_txn_id":nonce}
 owner_ok=(set(owner)==temp_owner_fields and H(nonce) and hashlib.sha256(J(logical)).hexdigest()==digest and
  owner.get("schema_version")==1 and owner.get("state")=="released-clean" and
  owner.get("logical_key_sha256")==digest and owner.get("instance_key")==key and
  owner.get("purpose")=="snapshot-temp" and owner.get("parent_txn_id")==nonce and
  owner.get("task_id")=="task" and owner.get("temp_basename")==".snapshot-tmp."+nonce and
  owner.get("max_paths")==10000 and owner.get("max_file_bytes")==16777216 and
  owner.get("max_total_bytes")==67108864 and owner.get("max_temp_bytes")==134217728 and
  isinstance(owner.get("created_epoch"),int) and isinstance(owner.get("released_epoch"),int) and
  owner["released_epoch"]>=owner["created_epoch"] and
  isinstance(owner.get("creator_pid"),int) and owner["creator_pid"]>0 and
  isinstance(owner.get("writer_pid"),int) and owner["writer_pid"]>0 and
  isinstance(owner.get("creator_boot_id"),str) and owner["creator_boot_id"] and
  isinstance(owner.get("creator_birth_token"),str) and owner["creator_birth_token"] and
  isinstance(owner.get("writer_birth_token"),str) and owner["writer_birth_token"] and
  all(H(owner.get(name)) for name in ("task_identity_digest","root_identity_digest",
      "runtime_identity_digest","native_binding_digest","instance_key_digest")) and
  owner.get("instance_key_digest")==hashlib.sha256(key.encode()).hexdigest() and
  isinstance(owner.get("runtime_mount_id"),str) and owner["runtime_mount_id"] and
  isinstance(targets,list) and len(targets)==3 and
  targets[0]=={"basename":".snapshot-tmp."+nonce,"type":"directory","mode":448,"max_physical_bytes":134217728} and
  targets[1].get("parent_basename")==targets[0]["basename"] and targets[1].get("type")=="regular" and
  targets[1].get("max_physical_bytes")==33554432 and
  targets[2]=={"basename":"observation.json","parent_basename":targets[0]["basename"],
   "type":"regular","max_physical_bytes":16384} and
  isinstance(identities,list) and len(identities)==1 and
  set(identities[0])=={"basename","type","dev","ino","nlink","mode","mount_id"} and
  identities[0].get("basename")==targets[0]["basename"] and identities[0].get("type")=="directory" and
  identities[0].get("mode")==448 and identities[0].get("mount_id")==owner.get("runtime_mount_id") and
  all(isinstance(identities[0].get(name),int) and identities[0][name]>=0 for name in ("dev","ino","nlink")) and
  identities[0].get("nlink")>=1 and
  owner.get("released_target_set_digest")==D(b"zyz-claim-released-target-set-v1",J(identities)))
 immutable_ok=(immutable=={**logical,"logical_key_sha256":digest,
  "claim_pack_basename":digest+".claim-pack.v1","max_data_bytes":134217728,
  "reservation_bytes":262144+134217728,"recovery_cell_index":directory.get("index"),
  "reservation_digest":recovery.get("payload",{}).get("reservation_digest"),
  "pack_identity_digest":immutable.get("pack_identity_digest")} and H(immutable.get("pack_identity_digest")))
 generations=({"IMMUTABLE_KEY":1,"OWNER":3,"OBSERVATION":2,"GC_JOURNAL":8,"KEY":2,"RECEIPT":1}
              if lifecycle else {"IMMUTABLE_KEY":1,"OWNER":3,"OBSERVATION":2})
 return (claim.get("size")==262144 and claim.get("allocated",0)>=262144 and
  claim.get("regular") is True and claim.get("nlink")==1 and owner_ok and immutable_ok and
  observation_ok(obs,owner) and cell_ok(cell,immutable) and
  frame_ok(digest,immutable,obs,cell,"snapshot-temp",nonce) and
  selector_ok(claim,generations,18 if lifecycle else 7) and
  (zero_lifecycle_ok(records,digest,owner) if lifecycle else True))
def publication_ok(digest,claim,cell):
 records=claim.get("records",{});immutable=records.get("IMMUTABLE_KEY",{}).get("payload",{})
 owner=records.get("OWNER",{}).get("payload",{});obs=records.get("OBSERVATION",{}).get("payload",{})
 directory=cell.get("selected_directory",{});recovery=cell.get("selected_recovery",{})
 logical={"schema_version":1,"purpose":"snapshot-publication","instance_key":key,"parent_txn_id":"publication-1"}
 want_owner={**journal.get("publication_claim_owner_facts",{}),"schema_version":1,"state":"will-create",
  "created_epoch":journal.get("created_epoch"),"hostname":owner.get("hostname"),
  "logical_key_sha256":digest,"instance_key":key,"purpose":"snapshot-publication",
  "parent_txn_id":"publication-1"}
 immutable_ok=(immutable=={**logical,"logical_key_sha256":digest,
  "claim_pack_basename":digest+".claim-pack.v1","max_data_bytes":publication_bytes,
  "reservation_bytes":262144+publication_bytes,"recovery_cell_index":directory.get("index"),
  "reservation_digest":recovery.get("payload",{}).get("reservation_digest"),
  "pack_identity_digest":immutable.get("pack_identity_digest")} and H(immutable.get("pack_identity_digest")))
 return (claim.get("size")==262144 and claim.get("allocated",0)>=262144 and
  claim.get("regular") is True and claim.get("nlink")==1 and
  owner=={**want_owner,"state":"did-create","target_identities":physical} and
  journal.get("publication_claim_owner_digest")==JD(want_owner) and immutable_ok and
  observation_ok(obs,owner) and cell_ok(cell,immutable) and
  frame_ok(digest,immutable,obs,cell,"snapshot-publication","publication-1") and
  selector_ok(claim,{"IMMUTABLE_KEY":1,"OWNER":2,"OBSERVATION":2},6))
nonces=[];sequences=[];labels=[];temp_digests=[];label_to_digest={}
for digest,claim in claims.items():
 owner=claim.get("records",{}).get("OWNER",{}).get("payload",{})
 obs=claim.get("records",{}).get("OBSERVATION",{}).get("payload",{})
 if available and digest==publication_digest:
  ok=ok and publication_ok(digest,claim,cells[digest])
 else:
  label=owner.get("targets",[{},{},{}])[1].get("basename") if isinstance(owner.get("targets"),list) and len(owner["targets"])==3 else None
  lifecycle=label=="baseline-a.records"
  ok=ok and temp_ok(digest,claim,cells[digest],lifecycle)
  nonces.append(owner.get("nonce"));labels.append(label);temp_digests.append(digest)
  if isinstance(label,str):label_to_digest[label]=digest
 sequences.append(obs.get("sequence"))
frame_keys=[item["payload"].get("logical_key_sha256") for item in frames]
residue=[name for name in os.listdir(agents) if name.startswith((".snapshot-owner.",".snapshot-tmp.")) or name.endswith((".snapshot-publish-journal",".snapshot-published.v1",".snapshot-gc-receipt")) or ".snapshot-inventory." in name or name.endswith(".staged")]
for item in physical:
 path=os.path.join(agents,item["basename"]); st=os.lstat(path); raw=open(path,"rb").read()
 ok=ok and (st.st_dev,st.st_ino,st.st_size,st.st_nlink,st.st_mtime_ns,hashlib.sha256(raw).hexdigest())==(item["dev"],item["ino"],item["size"],item["nlink"],item["mtime_ns"],item["sha256"])
ok=ok and len(set(nonces))==temp_claim_count and all(re.fullmatch(r"[0-9a-f]{64}",str(v)) for v in nonces)
ok=ok and len(set(sequences))==claim_count and sorted(frame_keys)==sorted(claims) and len(frame_keys)==claim_count
if available:
 ok=ok and labels.count("baseline-a.records")==labels.count("baseline-b.records")==1
 expected_temp={journal.get("source_claim_key_sha256")}|{item.get("claim_key_sha256") for item in journal.get("recovery_temps",[])}
 ok=ok and len(expected_temp)==2 and expected_temp==set(temp_digests)
 first=label_to_digest.get("baseline-a.records");publication_obs=claims[publication_digest]["records"]["OBSERVATION"]["payload"]
 rm=x["root_meta"];bm=b["root_meta"]
 ok=ok and x.get("root_generation")==b.get("root_generation")+22
 ok=ok and rm.get("pending_anchor_claim_sha256")==first and rm.get("claim_scan_due") is True
 ok=ok and rm.get("sweep_generation")==bm.get("sweep_generation")+1 and rm.get("sweep_cutoff_sequence")==0
 ok=ok and rm.get("sweep_segment_generation")==rm.get("sweep_start_segment_generation")==rm.get("first_active_segment_generation")==1
 ok=ok and rm.get("sweep_offset")==0 and rm.get("sweep_next_gc_epoch") is None and x.get("schedule")==b.get("schedule")
 ok=ok and rm.get("next_sequence")==bm.get("next_sequence")+3 and rm.get("active_segment_claim_count")==bm.get("active_segment_claim_count")+3
 ok=ok and rm.get("last_claim_key_sha256")==publication_digest and rm.get("last_claim_frame_digest")==publication_obs.get("frame_digest")
 ok=ok and publication_obs.get("claimed_root_digest")==x.get("root_digest")
else:
 ok=ok and labels==["baseline-a.records"] and temp_digests==list(claims)
ok=ok and not residue
raise SystemExit(0 if ok else 1)
PY
    }

    for t37_phase in will-claim-frame frame-will claim-frame-committed did-claim-frame claimed owner-did-create owner-released-clean; do
        t37="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t37-phase.XXXXXX")"; t37_fixture "$t37"
        t37_container="$(find "$t37/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t37_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t37/base.json" 2>"$t37/base.err"
        case "$t37_phase" in
            will-claim-frame|did-claim-frame) t37_barrier="catalog-root:$t37_phase" ;;
            claim-frame-committed) t37_barrier="catalog-segment:$t37_phase" ;;
            *) t37_barrier="catalog-claim-pack:$t37_phase" ;;
        esac
        t37_public "$t37" "$t37_barrier" "$t33_nonce_a" >"$t37/kill.out" 2>"$t37/kill.err"; t37_rc=$?
        t33_oracle "$t37_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t37/prior.json" 2>"$t37/prior.err"; t37_oracle_rc=$?
        if t37_unavailable_ok "$t37_rc" "$t37/kill.out" "$t37/kill.err" \
            && [ "$t37_oracle_rc" -eq 0 ] && t37_phase_ok "$t37/base.json" "$t37/prior.json" "$t37_phase" \
                "$t37/.zyz-worker/tasks/task/runtime/agents" "$t37_phase_nonce"; then
            pass "T37 public snapshot producer $t37_phase crash exposes exact claim prior"
        else
            fail "T37 public snapshot producer $t37_phase crash exposes exact claim prior" "rc=$t37_rc oracle_rc=$t37_oracle_rc out=$(tr '\n' ' ' < "$t37/kill.out") stderr=$(tr '\n' ' ' < "$t37/kill.err")"
        fi
        rm -rf "$t37"
    done

    # Public-only same-owner replay occurs inside one native producer process,
    # after the real creator has committed the claim and before any temp target
    # is made visible.  The barrier is reached only after the second real claim
    # call returns idempotent with the same sequence/frame/OWNER.
    t37="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t37-same-owner.XXXXXX")"; t37_fixture "$t37"
    t37_container="$(find "$t37/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t37_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t37/base.json" 2>/dev/null
    t37_public "$t37" 'catalog-claim-pack:same-owner-replay' "$t33_nonce_a" 1 >"$t37/replay.out" 2>"$t37/replay.err"; t37_replay_rc=$?
    t33_oracle "$t37_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t37/replay.json" 2>"$t37/replay-oracle.err"; t37_replay_oracle_rc=$?
    if t37_unavailable_ok "$t37_replay_rc" "$t37/replay.out" "$t37/replay.err" \
        && [ "$t37_replay_oracle_rc" -eq 0 ] && t37_phase_ok "$t37/base.json" "$t37/replay.json" same-owner-replay \
            "$t37/.zyz-worker/tasks/task/runtime/agents" "$t37_phase_nonce"; then
        pass "T37 public same-owner replay preserves one claim sequence frame owner and counter"
    else
        fail "T37 public same-owner replay preserves one claim sequence frame owner and counter" "rc=$t37_replay_rc oracle_rc=$t37_replay_oracle_rc stderr=$(tr '\n' ' ' < "$t37/replay.err")"
    fi
    rm -rf "$t37"

    # One fresh public producer uses the deterministic native nonce for both
    # baseline rounds.  Round one reaches released-clean; round two has a fresh
    # writer and target label under the same logical claim, so exact OWNER
    # equality must fail before another frame, sequence, CELL, or counter effect.
    # This reaches claim ownership without reusing a committed hook event.
    t37="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t37-owner-conflict.XXXXXX")"; t37_fixture "$t37"
    t37_container="$(find "$t37/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t37_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t37/before.json" 2>/dev/null
    t37_public "$t37" '' "$t33_nonce_a" >"$t37/retry.out" 2>"$t37/retry.err"; t37_retry_rc=$?
    t33_oracle "$t37_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t37/after.json" 2>/dev/null
    if [ "$t37_retry_rc" -eq 0 ] && [ ! -s "$t37/retry.out" ] && [ ! -s "$t37/retry.err" ] \
        && t37_changed_owner_ok "$t37/before.json" "$t37/after.json" \
            "$t37/.zyz-worker/tasks/task/runtime/agents" "$t37_phase_nonce"; then
        pass "T37 second native round rejects changed owner facts without duplicate sequence frame or counter"
    else
        fail "T37 second native round rejects changed owner facts without duplicate sequence frame or counter" "rc=$t37_retry_rc out=$(tr '\n' ' ' < "$t37/retry.out") stderr=$(tr '\n' ' ' < "$t37/retry.err")"
    fi
    rm -rf "$t37"

    # With real fresh CSPRNG nonces, the two public rounds must create two
    # separate claim packs, publish once, and retain immutable released-clean
    # histories after both owned temp directories are gone.
    t37="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t37-success.XXXXXX")"; t37_fixture "$t37"
    t37_container="$(find "$t37/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t37_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t37/base.json" 2>/dev/null
    t37_public "$t37" '' '' >"$t37/success.out" 2>"$t37/success.err"; t37_success_rc=$?
    t33_oracle "$t37_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t37/final.json" 2>"$t37/final.err"; t37_final_rc=$?
    if [ "$t37_success_rc" -eq 0 ] && [ ! -s "$t37/success.err" ] && [ "$t37_final_rc" -eq 0 ] \
        && t37_success_ok "$t37/success.out" "$t37/final.json" \
            "$t37/.zyz-worker/tasks/task/runtime/agents" "$t37/base.json"; then
        pass "T37 public snapshot publication separates two nonces and releases both exact owner histories"
    else
        fail "T37 public snapshot publication separates two nonces and releases both exact owner histories" "rc=$t37_success_rc oracle_rc=$t37_final_rc out=$(tr '\n' ' ' < "$t37/success.out") stderr=$(tr '\n' ' ' < "$t37/success.err")"
    fi
    rm -rf "$t37"

    # -----------------------------------------------------------------------
    # T38  Public single-segment zero-data claim walker and receipt anchor.
    # The fixture obtains one released-clean claim through the real public
    # producer's owner-released-clean barrier.  Public manual gc-step is then
    # the sole walker/anchor/release driver.  These cases do not claim
    # multi-segment traversal, PREVIS/cancellation index behavior, data-file
    # checkpoints, or terminal-index routing.
    # -----------------------------------------------------------------------
    t38_digest="$(t37_claim_digest "$t33_key" "$t33_nonce_a")"
    t38_released_fixture() { # sandbox
        t37_fixture "$1"
        t37_public "$1" 'catalog-claim-pack:owner-released-clean' "$t33_nonce_a" \
            >"$1/release.out" 2>"$1/release.err"
        printf '%s\n' "$?" > "$1/release.rc"
    }
    t38_gc() { # sandbox barrier
        (
            cd "$1" || exit 1
            ZYZ_TEST_TRANSITION_STOP_AFTER="$2" \
                bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
                gc-step "$1/.zyz-worker/tasks/task" manual
        )
    }
    t38_first_ok() { # released-oracle first-oracle first-output digest
        python3 - "$1" "$2" "$3" "$4" "$t33_key" <<'PY'
import base64,hashlib,hmac,json,re,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); out=json.load(open(sys.argv[3])); digest,key=sys.argv[4:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
claim=x["claims"].get(digest,{}); records=claim.get("records",{})
owner=records.get("OWNER",{}).get("payload",{}); journal=records.get("GC_JOURNAL",{}).get("payload",{})
key_record=records.get("KEY",{}).get("payload",{}); receipt=records.get("RECEIPT",{}).get("payload",{})
body={name:value for name,value in receipt.items() if name!="hmac_sha256"}
empty_target_digest=JD([])
try: key_bytes=base64.b64decode(key_record.get("key_b64",""),validate=True)
except Exception: key_bytes=b""
cell=x["claim_cells"].get(digest,{}); frames=[]
for segment in x["segments"].values():
 frames.extend(item for item in segment["frames"] if item["kind"]=="claim" and item["payload"].get("logical_key_sha256")==digest)
ok=(not x["forbidden_names"] and set(x["claims"])=={digest} and len(frames)==1 and
 set(records)=={"IMMUTABLE_KEY","OWNER","OBSERVATION","GC_JOURNAL","KEY","RECEIPT"} and
 owner.get("state")=="released-clean" and journal.get("phase")=="waiting-receipt-anchor" and
 set(journal)=={"schema_version","phase","logical_key_sha256","instance_key","owner_digest",
  "claim_kind","targets","target_set_digest","intent_digests","staging_digest","live_inventory_digest","tree_bounds",
  "key_b64","key_digest","quarantine_count","deleted_count","bytes_reclaimed","verified_entries","verified_bytes",
  "created_epoch","receipt_epoch","receipt_digest"} and
 journal.get("logical_key_sha256")==digest and journal.get("instance_key")==key and
 journal.get("owner_digest")==JD(owner) and journal.get("quarantine_count")==0 and
 journal.get("claim_kind")=="zero" and journal.get("targets")==[] and
 journal.get("target_set_digest")==empty_target_digest and journal.get("intent_digests")==[] and
 journal.get("staging_digest") is None and journal.get("live_inventory_digest") is None and journal.get("tree_bounds") is None and
 journal.get("deleted_count")==journal.get("bytes_reclaimed")==journal.get("verified_entries")==journal.get("verified_bytes")==0 and
 len(key_bytes)==32 and hashlib.sha256(key_bytes).hexdigest()==journal.get("key_digest") and
 key_record=={"schema_version":1,"state":"active","key_b64":journal.get("key_b64"),
  "key_digest":journal.get("key_digest")} and
 body=={"schema_version":1,"state":"waiting-receipt-anchor","logical_key_sha256":digest,
  "instance_key":key,"owner_digest":journal.get("owner_digest"),"claim_kind":"zero",
  "target_set_digest":empty_target_digest,"deleted_count":0,"bytes_reclaimed":0,
  "verified_entries":0,"verified_bytes":0,"result":"compacted",
  "committed_epoch":journal.get("receipt_epoch")} and
 receipt.get("hmac_sha256")==hmac.new(key_bytes,J(body),hashlib.sha256).hexdigest() and
 journal.get("receipt_digest")==JD(receipt) and
 "ANCHOR_ACK" not in records and
 "GC_ANCHOR" not in x["packs"].get("audit",{}).get("records",{}) and
 x["root_meta"].get("pending_anchor_claim_sha256")==digest and
 x["root_meta"].get("next_sequence")==b["root_meta"].get("next_sequence") and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims") and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes") and
 x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation") and
 cell.get("selected_directory",{}).get("state")==2 and
 cell.get("selected_recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK" and
 out.get("ok") is True and out.get("state")=="pending" and out.get("error") is None and
 out.get("trigger")=="manual" and out.get("due") is True and out.get("lock_acquired") is True and
 out.get("claims_scanned")==1 and out.get("claims_skipped")==0 and
 out.get("transactions_advanced")==3 and out.get("receipts_anchored")==0 and
 out.get("entries_verified")==out.get("verification_bytes")==out.get("entries_deleted")==out.get("bytes_reclaimed")==0 and
 out.get("owned_bytes_before")==out.get("owned_bytes_after")==b["root_meta"].get("owned_bytes"))
raise SystemExit(0 if ok else 1)
PY
    }
    t38_phase_ok() { # first-oracle observed-oracle phase digest
        python3 - "$1" "$2" "$3" "$4" "$t33_key" <<'PY'
import hashlib,json,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); phase,digest,key=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
audit=x["packs"].get("audit",{}).get("records",{}); anchor=audit.get("GC_ANCHOR",{}).get("payload",{})
receipt=b["claims"][digest]["records"]["RECEIPT"]["payload"]; receipt_digest=JD(receipt)
want_anchor={"schema_version":1,"state":"anchored","logical_key_sha256":digest,
 "receipt_digest":receipt_digest,"route":"instance","instance_key":key}
ok=(not x["forbidden_names"] and anchor==want_anchor)
if phase in ("GC_ANCHOR-slot-committed","ANCHOR_ACK-header-committed","KEY-retired-header-committed"):
 claim=x["claims"].get(digest,{}); records=claim.get("records",{})
 ack=records.get("ANCHOR_ACK",{}).get("payload"); key_record=records.get("KEY",{}).get("payload",{})
 ok=ok and x["root_meta"].get("pending_anchor_claim_sha256")==digest
 ok=ok and x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")
 ok=ok and x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")
 ok=ok and records.get("GC_JOURNAL",{}).get("payload",{}).get("phase")=="waiting-receipt-anchor"
 if phase=="GC_ANCHOR-slot-committed":
  ok=ok and ack is None and key_record.get("state")=="active"
 else:
  want_ack={"schema_version":1,"state":"did-anchor-ack","logical_key_sha256":digest,
   "receipt_digest":receipt_digest,"route":"instance","instance_anchor_digest":JD(want_anchor)}
  ok=ok and ack==want_ack
  ok=ok and key_record.get("state")== ("retired" if phase=="KEY-retired-header-committed" else "active")
else:
 ok=ok and digest not in x["claims"] and digest in x["claim_cells"]
 ok=ok and x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")-1
 request=b["claims"][digest]["records"]["IMMUTABLE_KEY"]["payload"]["reservation_bytes"]
 ok=ok and x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")-request
 ok=ok and x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+1
 cell=x["claim_cells"][digest]
 if phase=="physical-release":
  ok=ok and x["root_meta"].get("pending_anchor_claim_sha256")==digest
  ok=ok and cell.get("selected_directory",{}).get("state")==3
  ok=ok and cell.get("selected_recovery",{}).get("payload",{}).get("state")=="CELL_FREE_WILL"
 else:
  ok=ok and x["root_meta"].get("pending_anchor_claim_sha256") is None
  ok=ok and cell.get("selected_directory") is None and cell.get("selected_recovery") is None
  ok=ok and x["root_meta"].get("last_freed_subject_digest")==cell.get("subject_digest")
raise SystemExit(0 if ok else 1)
PY
    }
    t38_final_ok() { # first-oracle final-oracle output phase digest
        python3 - "$1" "$2" "$3" "$4" "$5" "$t33_key" <<'PY'
import hashlib,json,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); out=json.load(open(sys.argv[3])); phase,digest,key=sys.argv[4:]
audit=x["packs"].get("audit",{}).get("records",{}); anchor=audit.get("GC_ANCHOR",{}).get("payload",{})
receipt=b["claims"][digest]["records"]["RECEIPT"]["payload"]
receipt_digest=hashlib.sha256((json.dumps(receipt,sort_keys=True,separators=(",",":"),ensure_ascii=True)+"\n").encode()).hexdigest()
request=b["claims"][digest]["records"]["IMMUTABLE_KEY"]["payload"]["reservation_bytes"]
cell=x["claim_cells"].get(digest,{}); frames=[]
for segment in x["segments"].values(): frames.extend(segment["frames"])
claim_frames=[item for item in frames if item["kind"]=="claim" and item["payload"].get("logical_key_sha256")==digest]
want_anchored=0 if phase=="anchor-pointer-consumed" else 1
request=b["claims"][digest]["records"]["IMMUTABLE_KEY"]["payload"]["reservation_bytes"]
expected={
 "GC_ANCHOR-slot-committed":("compacted",2,1,1,262144,b["root_meta"].get("owned_bytes"),b["root_meta"].get("owned_bytes")-request),
 "ANCHOR_ACK-header-committed":("compacted",2,1,1,262144,b["root_meta"].get("owned_bytes"),b["root_meta"].get("owned_bytes")-request),
 "KEY-retired-header-committed":("compacted",2,1,1,262144,b["root_meta"].get("owned_bytes"),b["root_meta"].get("owned_bytes")-request),
 "physical-release":("compacted",2,1,0,0,b["root_meta"].get("owned_bytes")-request,b["root_meta"].get("owned_bytes")-request),
 "anchor-pointer-consumed":("idle",1,0,0,0,b["root_meta"].get("owned_bytes")-request,b["root_meta"].get("owned_bytes")-request),
}
state,transactions,anchored,deleted,reclaimed,before,after=expected[phase]
ok=(not x["forbidden_names"] and digest not in x["claims"] and len(claim_frames)==1 and
 x["root_meta"].get("pending_anchor_claim_sha256") is None and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")-1 and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")-request and
 x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+1 and
 cell.get("selected_directory") is None and cell.get("selected_recovery") is None and
 x["root_meta"].get("last_freed_subject_digest")==cell.get("subject_digest") and
 anchor=={"schema_version":1,"state":"anchored","logical_key_sha256":digest,
  "receipt_digest":receipt_digest,"route":"instance","instance_key":key} and
 out.get("ok") is True and out.get("state")==state and out.get("error") is None and
 out.get("trigger")=="manual" and out.get("due") is True and out.get("lock_acquired") is True and
 out.get("claims_scanned")==out.get("claims_skipped")==out.get("blocked_claims_known")==0 and
 out.get("transactions_advanced")==transactions and
 out.get("entries_verified")==out.get("verification_bytes")==0 and
 out.get("receipts_anchored")==want_anchored==anchored and out.get("entries_deleted")==deleted and
 out.get("bytes_reclaimed")==reclaimed and out.get("owned_bytes_before")==before and out.get("owned_bytes_after")==after and
 out.get("high_water")==536870912 and out.get("hard_water")==1073741824)
raise SystemExit(0 if ok else 1)
PY
    }
    t38_repeat_ok() { # final-oracle repeat-oracle repeat-output digest
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import json,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); out=json.load(open(sys.argv[3])); digest=sys.argv[4]
stable=(b["root_meta"].get("pending_anchor_claim_sha256"),b["root_meta"].get("active_claims"),
 b["root_meta"].get("owned_bytes"),b["root_meta"].get("counter_generation"),
 b["root_meta"].get("last_freed_subject_digest"),b["claim_cells"].get(digest),
 b["packs"].get("audit",{}).get("records",{}).get("GC_ANCHOR"),b["segments"])
observed=(x["root_meta"].get("pending_anchor_claim_sha256"),x["root_meta"].get("active_claims"),
 x["root_meta"].get("owned_bytes"),x["root_meta"].get("counter_generation"),
 x["root_meta"].get("last_freed_subject_digest"),x["claim_cells"].get(digest),
 x["packs"].get("audit",{}).get("records",{}).get("GC_ANCHOR"),x["segments"])
ok=(stable==observed and digest not in x["claims"] and out.get("ok") is True and
 out.get("state")=="idle" and out.get("error") is None and out.get("receipts_anchored")==0 and
 out.get("entries_deleted")==0 and out.get("bytes_reclaimed")==0)
raise SystemExit(0 if ok else 1)
PY
    }

    for t38_phase in GC_ANCHOR-slot-committed ANCHOR_ACK-header-committed KEY-retired-header-committed physical-release anchor-pointer-consumed; do
        t38="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t38-phase.XXXXXX")"; t38_released_fixture "$t38"
        t38_container="$(find "$t38/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t38_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t38/released.json" 2>"$t38/released.err"
        t38_gc "$t38" '' >"$t38/first.out" 2>"$t38/first.err"; t38_first_rc=$?
        t33_oracle "$t38_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t38/first.json" 2>"$t38/first-oracle.err"; t38_first_oracle_rc=$?
        if t37_unavailable_ok "$(cat "$t38/release.rc")" "$t38/release.out" "$t38/release.err" \
            && [ "$t38_first_rc" -eq 3 ] && [ ! -s "$t38/first.err" ] \
            && [ "$t38_first_oracle_rc" -eq 0 ] && t38_first_ok "$t38/released.json" "$t38/first.json" "$t38/first.out" "$t38_digest"; then
            pass "T38 public first pass freezes and authenticates one zero-data claim receipt"
        else
            fail "T38 public first pass freezes and authenticates one zero-data claim receipt" "release_rc=$(cat "$t38/release.rc") first_rc=$t38_first_rc stderr=$(tr '\n' ' ' < "$t38/first.err")"
        fi
        case "$t38_phase" in
            physical-release) t38_barrier="catalog-claim-pack:$t38_phase" ;;
            anchor-pointer-consumed) t38_barrier="catalog-root:$t38_phase" ;;
            *) t38_barrier="catalog-claim-gc:$t38_phase" ;;
        esac
        t38_gc "$t38" "$t38_barrier" >"$t38/kill.out" 2>"$t38/kill.err"; t38_kill_rc=$?
        t33_oracle "$t38_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t38/prior.json" 2>"$t38/prior.err"; t38_prior_rc=$?
        if [ "$t38_kill_rc" -eq 86 ] && [ ! -s "$t38/kill.out" ] && [ ! -s "$t38/kill.err" ] \
            && [ "$t38_prior_rc" -eq 0 ] && t38_phase_ok "$t38/first.json" "$t38/prior.json" "$t38_phase" "$t38_digest"; then
            pass "T38 public $t38_phase crash exposes exact anchor release prior"
        else
            fail "T38 public $t38_phase crash exposes exact anchor release prior" "rc=$t38_kill_rc oracle_rc=$t38_prior_rc stderr=$(tr '\n' ' ' < "$t38/kill.err")"
        fi
        t38_gc "$t38" '' >"$t38/resume.out" 2>"$t38/resume.err"; t38_resume_rc=$?
        t33_oracle "$t38_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t38/final.json" 2>"$t38/final.err"; t38_final_rc=$?
        if [ "$t38_resume_rc" -eq 0 ] && [ ! -s "$t38/resume.err" ] && [ "$t38_final_rc" -eq 0 ] \
            && t38_final_ok "$t38/first.json" "$t38/final.json" "$t38/resume.out" "$t38_phase" "$t38_digest"; then
            pass "T38 public resume after $t38_phase releases once and consumes ROOT pointer"
        else
            fail "T38 public resume after $t38_phase releases once and consumes ROOT pointer" "rc=$t38_resume_rc oracle_rc=$t38_final_rc out=$(tr '\n' ' ' < "$t38/resume.out") stderr=$(tr '\n' ' ' < "$t38/resume.err")"
        fi
        t38_gc "$t38" '' >"$t38/repeat.out" 2>"$t38/repeat.err"; t38_repeat_rc=$?
        t33_oracle "$t38_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t38/repeat.json" 2>"$t38/repeat-oracle.err"; t38_repeat_oracle_rc=$?
        if [ "$t38_repeat_rc" -eq 0 ] && [ ! -s "$t38/repeat.err" ] && [ "$t38_repeat_oracle_rc" -eq 0 ] \
            && t38_repeat_ok "$t38/final.json" "$t38/repeat.json" "$t38/repeat.out" "$t38_digest"; then
            pass "T38 third public pass after $t38_phase is receipt and release idempotent"
        else
            fail "T38 third public pass after $t38_phase is receipt and release idempotent" "rc=$t38_repeat_rc oracle_rc=$t38_repeat_oracle_rc out=$(tr '\n' ' ' < "$t38/repeat.out")"
        fi
        rm -rf "$t38"
    done

    # -----------------------------------------------------------------------
    # T39  Public TTL scheduling and deterministic retired-frame cancellation.
    # A producer killed at `claimed` leaves a real will-create claim whose
    # creator is dead but whose TTL is not expired at the injected entry epoch.
    # The public walker must scan+skip it, persist the exact retry schedule, and
    # then report automatic due=false without touching the catalog.  A second
    # fixture first retires a released-clean claim through T38's public path;
    # the next sweep must suppress that now-packless immutable frame by its
    # deterministic basename and continue to the later active claim.  These
    # cases do not prove expired dirty-data cleanup; that path needs its own
    # stable public CHECKPOINT/POINTER observation points.
    # -----------------------------------------------------------------------
    t39_seed='2468ace013579bdf2468ace013579bdf'
    t39_raw='ttl/agent'
    t39_key="$(python3 -c 'import hashlib,re,sys
r=sys.argv[1];d=hashlib.sha256(r.encode()).hexdigest();p=re.sub(r"[^A-Za-z0-9._-]","_",r)[:32] or "agent";print(p+"."+d)' "$t39_raw")"
    t39_digest="$(t37_claim_digest "$t39_key" "$t39_seed")"
    t39_gc() { # sandbox trigger now
        (
            cd "$1" || exit 1
            ZYZ_NO_OUTPUT_TEMP_STALE_SEC=120 \
            ZYZ_TEST_GC_NOW_EPOCH="$3" \
                bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
                gc-step "$1/.zyz-worker/tasks/task" "$2"
        )
    }
    t39_multi_oracle() { # container scratch-prefix
        t33_oracle "$1" "$t39_key" "$t39_raw" "$t33_role" "$t39_seed" >"$2.primary" || return 1
        t33_oracle "$1" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$2.coexisting" || return 1
        python3 - "$2.primary" "$2.coexisting" "$t39_key" "$t33_key" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2])); primary,coexisting=sys.argv[3:]
carriers=lambda key:{key+".audit-pack.v1",key+".work-pack.v1",key+".lock.v1"}
def carrier_set_ok(value):
 packs=value.get("packs",{}); lock=value.get("lock"); request=value.get("expected_request_bytes")
 return (set(packs)=={"audit","work"} and
  all(row.get("size")==524288 and row.get("allocated",0)>=524288 and row.get("regular") is True and row.get("nlink")==1 for row in packs.values()) and
  isinstance(lock,dict) and lock.get("size")==request-1048576 and lock.get("allocated",0)>=lock.get("size",1) and
  lock.get("regular") is True and lock.get("nlink")==1)
shared=("root_generation","root_predecessor","root_digest","root_meta","schedule","group_generation","group_digest","group_meta",
 "segments","claims","claim_cells","terminal")
co={"instance_key":coexisting,"subject_digest":c["subject_digest"],"subject_dirs":c["subject_dirs"],
 "subject_recoveries":c["subject_recoveries"],"selected_cell":c["selected_cell"],
 "cell_history":c["cell_history"],"packs":c["packs"],"lock":c["lock"],
 "expected_event":c["expected_event"],"expected_reservation_digest":c["expected_reservation_digest"],
 "expected_request_bytes":c["expected_request_bytes"]}
ok=(primary!=coexisting and set(p["forbidden_names"])==carriers(coexisting) and
 set(c["forbidden_names"])==carriers(primary) and all(p[name]==c[name] for name in shared) and
 carrier_set_ok(p) and carrier_set_ok(c) and
 p["selected_cell"] is not None and c["selected_cell"] is not None)
if not ok: raise SystemExit(1)
p["coexisting_instances"]={coexisting:co};p["forbidden_names"]=[]
print(json.dumps(p,sort_keys=True,separators=(",",":")))
PY
    }
    t39_skip_ok() { # before after output active-digest scanned cancelled now retry exact-owner-state
        python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" <<'PY'
import json,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); out=json.load(open(sys.argv[3]))
digest=sys.argv[4]; scanned=int(sys.argv[5]); cancelled=sys.argv[6]
now=int(sys.argv[7]); retry=int(sys.argv[8]); owner_state=sys.argv[9]
before=b["claims"][digest]; claim=x["claims"].get(digest,{}); br=before["records"]; records=claim.get("records",{})
owner=records.get("OWNER",{}).get("payload",{}); old_obs=br.get("OBSERVATION",{}).get("payload",{})
obs=records.get("OBSERVATION",{}).get("payload",{})
stable_root=("owned_bytes","active_claims","active_data_claims","counter_generation","next_sequence")
ok=(not x["forbidden_names"] and set(records)=={"IMMUTABLE_KEY","OWNER","OBSERVATION"} and
 set(b["packs"])==set(x["packs"])=={"audit","work"} and b["packs"]==x["packs"] and
 b["lock"]==x["lock"] and x["lock"] is not None and b["selected_cell"]==x["selected_cell"] and
 x["selected_cell"].get("recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK" and
 owner==br.get("OWNER",{}).get("payload") and
 owner.get("state")==owner_state and
 records.get("IMMUTABLE_KEY")==br.get("IMMUTABLE_KEY") and
 claim.get("header_generation")==before.get("header_generation")+1 and
 claim.get("selected",{}).get("IMMUTABLE_KEY")==before.get("selected",{}).get("IMMUTABLE_KEY") and
 claim.get("selected",{}).get("OWNER")==before.get("selected",{}).get("OWNER") and
 claim.get("selected",{}).get("OBSERVATION",{}).get("generation")==
  before.get("selected",{}).get("OBSERVATION",{}).get("generation")+1 and
 {k:v for k,v in obs.items() if k not in ("last_observed_epoch","retry_epoch")}==
  {k:v for k,v in old_obs.items() if k not in ("last_observed_epoch","retry_epoch")} and
 obs.get("last_observed_epoch")==now and obs.get("retry_epoch")==retry and
 all(x["root_meta"].get(k)==b["root_meta"].get(k) for k in stable_root) and
 x["segments"]==b["segments"] and
 x["root_meta"].get("claim_scan_due") is False and
 x["root_meta"].get("sweep_cutoff_sequence")==0 and
 x["root_meta"].get("sweep_segment_generation")==x["root_meta"].get("first_active_segment_generation")==1 and
 x["root_meta"].get("sweep_start_segment_generation")==1 and x["root_meta"].get("sweep_offset")==0 and
 x["root_meta"].get("sweep_generation")==b["root_meta"].get("sweep_generation")+1 and
 out.get("ok") is True and out.get("state")=="idle" and out.get("error") is None and
 out.get("trigger")=="manual" and out.get("due") is True and out.get("lock_acquired") is True and
 out.get("claims_scanned")==scanned and out.get("claims_skipped")==1 and
 out.get("transactions_advanced")==2 and out.get("next_gc_epoch")==retry and
 out.get("receipts_anchored")==out.get("entries_deleted")==out.get("bytes_reclaimed")==0)
if cancelled:
 frames=[item for segment in x["segments"].values() for item in segment["frames"] if item["kind"]=="claim"]
 old=x["claim_cells"].get(cancelled,{}); active=x["claim_cells"].get(digest,{})
 co=b.get("coexisting_instances",{}); xa=x.get("coexisting_instances",{})
 ok=ok and set(x["claims"])=={digest} and set(x["claim_cells"])=={cancelled,digest}
 ok=ok and co==xa and len(co)==1
 for extra in co.values():
  ok=ok and set(extra.get("packs",{}))=={"audit","work"} and extra.get("lock") is not None
  ok=ok and extra.get("selected_cell",{}).get("recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK"
 ok=ok and len(frames)==2 and [item["payload"].get("logical_key_sha256") for item in frames]==[cancelled,digest]
 ok=ok and old.get("selected_directory") is None and old.get("selected_recovery") is None
 ok=ok and x["root_meta"].get("last_freed_subject_digest")==old.get("subject_digest")
 ok=ok and active.get("selected_directory",{}).get("state")==2
raise SystemExit(0 if ok else 1)
PY
    }
    t39_due_false_ok() { # before after output expected-epoch
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import json,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); out=json.load(open(sys.argv[3])); epoch=int(sys.argv[4])
ok=(b==x and out.get("ok") is True and out.get("state")=="idle" and out.get("error") is None and
 out.get("trigger")=="watchdog" and out.get("due") is False and out.get("lock_acquired") is True and
 out.get("claims_scanned")==out.get("claims_skipped")==out.get("transactions_advanced")==0 and
 out.get("receipts_anchored")==out.get("entries_deleted")==out.get("bytes_reclaimed")==0 and
 out.get("next_gc_epoch")==epoch)
raise SystemExit(0 if ok else 1)
PY
    }
    t39_creator_stopped_ok() { # oracle-json digest
        python3 - "$1" "$2" <<'PY'
import ctypes,json,subprocess,sys
try:
 x=json.load(open(sys.argv[1]));owner=x["claims"][sys.argv[2]]["records"]["OWNER"]["payload"]
 pid=owner.get("creator_pid"); boot=owner.get("creator_boot_id"); birth=owner.get("creator_birth_token")
 if sys.platform.startswith("linux"):
  observed_boot=open("/proc/sys/kernel/random/boot_id").read().strip()
  raw=open(f"/proc/{pid}/stat").read(); fields=raw[raw.rfind(")")+2:].split()
  observed_birth=fields[19]; stopped=fields[0] in ("T","t")
 elif sys.platform=="darwin":
  observed_boot=subprocess.check_output(["/usr/sbin/sysctl","-n","kern.bootsessionuuid"],text=True).strip()
  info=ctypes.create_string_buffer(56);lib=ctypes.CDLL("/usr/lib/libproc.dylib",use_errno=True)
  got=lib.proc_pidinfo(pid,17,0,info,len(info));observed_birth=bytes(info.raw).hex()
  state=subprocess.check_output(["/bin/ps","-o","state=","-p",str(pid)],text=True).strip()
  stopped=got==len(info) and state.startswith("T")
 else: raise OSError("unsupported process identity")
 ok=(isinstance(pid,int) and pid>0 and observed_boot==boot and observed_birth==birth and stopped)
except (OSError,ProcessLookupError,IndexError,ValueError,subprocess.SubprocessError): ok=False
raise SystemExit(0 if ok else 1)
PY
    }
    t39_creator_live_ready_ok() { # authenticated-oracle-json digest running|stopped catalog-container
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import ctypes,fcntl,json,os,stat,subprocess,sys
try:
 x=json.load(open(sys.argv[1]));digest,expected,container=sys.argv[2:]
 claim=x["claims"][digest];records=claim["records"]
 owner_record=records["OWNER"];owner=owner_record["payload"];obs=records["OBSERVATION"]["payload"]
 selected=claim["selected"];cell=x["claim_cells"][digest]
 authority=(set(records)=={"IMMUTABLE_KEY","OWNER","OBSERVATION"} and
  set(selected)=={"IMMUTABLE_KEY","OWNER","OBSERVATION"} and
  all(selected[name].get("generation")==records[name].get("generation") and
      selected[name].get("digest")==records[name].get("digest")
      for name in ("IMMUTABLE_KEY","OWNER","OBSERVATION")) and
  selected["OWNER"].get("generation")==owner_record.get("generation") and
  selected["OWNER"].get("digest")==owner_record.get("digest") and
  owner.get("state")=="did-create" and obs.get("state")=="claimed" and
  cell.get("selected_directory",{}).get("state")==2 and
  cell.get("selected_recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK")
 pid=owner.get("creator_pid");boot=owner.get("creator_boot_id");birth=owner.get("creator_birth_token")
 if sys.platform.startswith("linux"):
  observed_boot=open("/proc/sys/kernel/random/boot_id").read().strip()
  raw=open(f"/proc/{pid}/stat").read();fields=raw[raw.rfind(")")+2:].split()
  observed_birth=fields[19];state=fields[0]
  running=state not in ("T","t","Z","X","x");stopped=state in ("T","t")
 elif sys.platform=="darwin":
  observed_boot=subprocess.check_output(["/usr/sbin/sysctl","-n","kern.bootsessionuuid"],text=True).strip()
  info=ctypes.create_string_buffer(56);lib=ctypes.CDLL("/usr/lib/libproc.dylib",use_errno=True)
  got=lib.proc_pidinfo(pid,17,0,info,len(info));observed_birth=bytes(info.raw).hex()
  state=subprocess.check_output(["/bin/ps","-o","state=","-p",str(pid)],text=True).strip()
  running=got==len(info) and not state.startswith(("T","Z"));stopped=got==len(info) and state.startswith("T")
 else: raise OSError("unsupported process identity")
 lock_fd=os.open(os.path.join(container,".catalog-lock.v1"),os.O_RDWR|getattr(os,"O_CLOEXEC",0)|getattr(os,"O_NOFOLLOW",0))
 try:
  lock_stat=os.fstat(lock_fd);fcntl.flock(lock_fd,fcntl.LOCK_EX|fcntl.LOCK_NB);fcntl.flock(lock_fd,fcntl.LOCK_UN)
  lock_free=stat.S_ISREG(lock_stat.st_mode) and lock_stat.st_nlink==1
 finally: os.close(lock_fd)
 process_ok=running if expected=="running" else stopped if expected=="stopped" else False
 ok=(authority and isinstance(pid,int) and pid>0 and observed_boot==boot and observed_birth==birth and
     process_ok and lock_free)
except (KeyError,TypeError,OSError,ProcessLookupError,IndexError,ValueError,subprocess.SubprocessError): ok=False
raise SystemExit(0 if ok else 1)
PY
    }
    t39_same_creator_ok() { # running-oracle stopped-oracle digest
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));digest=sys.argv[3]
ok=(b["claims"].get(digest)==x["claims"].get(digest) and
 b["claim_cells"].get(digest)==x["claim_cells"].get(digest) and
 b["segments"]==x["segments"] and b["root_meta"]==x["root_meta"] and
 b["root_digest"]==x["root_digest"])
raise SystemExit(0 if ok else 1)
PY
    }
    t39_owner_artifact() { # authenticated-oracle-json digest
        python3 - "$1" "$2" <<'PY'
import json,sys
try:
 x=json.load(open(sys.argv[1]));claim=x["claims"][sys.argv[2]];records=claim["records"]
 value={"selected_owner":claim["selected"].get("OWNER"),"owner":records.get("OWNER"),
  "observation":records.get("OBSERVATION"),"cell":x["claim_cells"].get(sys.argv[2])}
 print(json.dumps(value,sort_keys=True,separators=(",",":")))
except (KeyError,OSError,TypeError,ValueError): print("unavailable")
PY
    }
    t39_live_oracle() { t33_oracle "$@"; }

    t39="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t39-ttl.XXXXXX")"; t37_fixture "$t39"
    t39_container="$(find "$t39/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t37_public "$t39" 'catalog-claim-pack:claimed' "$t39_seed" 0 "$t39_raw" "$t33_role" >"$t39/claim.out" 2>"$t39/claim.err"; t39_claim_rc=$?
    t33_oracle "$t39_container" "$t39_key" "$t39_raw" "$t33_role" "$t39_seed" >"$t39/before.json" 2>"$t39/before.err"; t39_before_rc=$?
    t39_now="$(python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));print(x["claims"][sys.argv[2]]["records"]["OWNER"]["payload"]["created_epoch"])' "$t39/before.json" "$t39_digest" 2>/dev/null)"
    t39_gc "$t39" manual "$t39_now" >"$t39/skip.out" 2>"$t39/skip.err"; t39_skip_rc=$?
    t33_oracle "$t39_container" "$t39_key" "$t39_raw" "$t33_role" "$t39_seed" >"$t39/skip.json" 2>"$t39/skip-oracle.err"; t39_skip_oracle_rc=$?
    if t37_unavailable_ok "$t39_claim_rc" "$t39/claim.out" "$t39/claim.err" \
        && [ "$t39_before_rc" -eq 0 ] && [ "$t39_skip_rc" -eq 0 ] && [ ! -s "$t39/skip.err" ] \
        && [ "$t39_skip_oracle_rc" -eq 0 ] \
        && t39_skip_ok "$t39/before.json" "$t39/skip.json" "$t39/skip.out" "$t39_digest" 1 '' \
            "$t39_now" "$((t39_now+120))" will-create; then
        pass "T39 public unexpired dead owner scans and skips to exact TTL schedule"
    else
        fail "T39 public unexpired dead owner scans and skips to exact TTL schedule" "claim_rc=$t39_claim_rc skip_rc=$t39_skip_rc oracle_rc=$t39_skip_oracle_rc stderr=$(tr '\n' ' ' < "$t39/skip.err")"
    fi
    t39_gc "$t39" watchdog "$t39_now" >"$t39/auto.out" 2>"$t39/auto.err"; t39_auto_rc=$?
    t33_oracle "$t39_container" "$t39_key" "$t39_raw" "$t33_role" "$t39_seed" >"$t39/auto.json" 2>"$t39/auto-oracle.err"; t39_auto_oracle_rc=$?
    if [ "$t39_auto_rc" -eq 0 ] && [ ! -s "$t39/auto.err" ] && [ "$t39_auto_oracle_rc" -eq 0 ] \
        && t39_due_false_ok "$t39/skip.json" "$t39/auto.json" "$t39/auto.out" "$((t39_now+120))"; then
        pass "T39 automatic pass before TTL is due false and mutation free"
    else
        fail "T39 automatic pass before TTL is due false and mutation free" "rc=$t39_auto_rc oracle_rc=$t39_auto_oracle_rc out=$(tr '\n' ' ' < "$t39/auto.out")"
    fi
    rm -rf "$t39"

    # Keep the real public producer alive beyond its TTL boundary.  The native
    # child-only barrier is reached before directory enumeration, but only
    # after the parent has committed and exactly reread did-create, released
    # CatalogFlock, and opened the child start gate.  Readiness therefore comes
    # from the exact barrier payload plus authenticated selected OWNER/
    # OBSERVATION/CELL, current kernel identity, and an independently acquired
    # catalog lock.  will-create is never stopped.
    # At now=created+TTL a dead
    # owner would be eligible, so scanned+skipped with retry=now+1 proves the
    # creator PID/boot/birth liveness arm is the one actually taken.
    t39="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t39-live.XXXXXX")"; t37_fixture "$t39"
    t39_container="$(find "$t39/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t39_barrier="$t39/snapshot-barrier"
    t39_live_public() { # sandbox
        cd "$1" || exit 1
        printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"%s","agent_type":"zyz-worker:%s"}' \
            "$1" "$t39_raw" "$t33_role" | exec env \
            ZYZ_TEST_RANDOM_HEX_SEQUENCE="$t39_seed" \
            ZYZ_TEST_SNAPSHOT_BARRIER_DIR="$t39_barrier" \
            ZYZ_TEST_SNAPSHOT_BARRIER_POINT=before-directory-enumeration \
            bash "$REPO_ROOT/hooks/scripts/subagent-track.sh"
    }
    t39_live_public "$t39" >"$t39/live.out" 2>"$t39/live.err" & t39_live_pid=$!
    t39_ready=0; t39_precondition=0; t39_stopped=0; t39_stop_sent=0
    t39_live_before_rc=1; t39_live_stopped_rc=1; t39_creator_pid=''; t39_writer_pid=''
    t39_live_case_ok=0; t39_live_skip_rc='not-run'; t39_live_after_rc='not-run'; t39_gone=0
    t39_release_barrier() {
        if [ -d "$t39_barrier" ]; then
            rm -f "$t39_barrier/ready"
            : > "$t39_barrier/go"
        fi
    }
    t39_live_cleanup() {
        t39_release_barrier
        for t39_cleanup_pid in "${t39_creator_pid:-}" "${t39_writer_pid:-}" "${t39_live_pid:-}"; do
            case "$t39_cleanup_pid" in
                ''|*[!0-9]*) ;;
                *)
                    kill -CONT "$t39_cleanup_pid" 2>/dev/null || true
                    kill -TERM "$t39_cleanup_pid" 2>/dev/null || true
                    kill -KILL "$t39_cleanup_pid" 2>/dev/null || true
                    ;;
            esac
        done
        case "${t39_live_pid:-}" in ''|*[!0-9]*) ;; *) wait "$t39_live_pid" 2>/dev/null || true ;; esac
        t39_creator_pid=''; t39_writer_pid=''; t39_live_pid=''
    }
    trap 't39_live_cleanup' EXIT
    trap 't39_live_cleanup; exit 130' HUP INT TERM
    # This is a state wait, not a bounded race: the exact ready artifact or
    # producer exit is the only completion condition.
    while [ ! -f "$t39_barrier/ready" ] && kill -0 "$t39_live_pid" 2>/dev/null; do
        sleep 0.01
    done
    if [ -f "$t39_barrier/ready" ] \
        && [ "$(cat "$t39_barrier/ready" 2>/dev/null)" = before-directory-enumeration ]; then
        t39_ready=1
        t33_oracle "$t39_container" "$t39_key" "$t39_raw" "$t33_role" "$t39_seed" \
            >"$t39/live-before.json" 2>"$t39/live-before.err"; t39_live_before_rc=$?
        if [ "$t39_live_before_rc" -eq 0 ] \
            && t39_creator_live_ready_ok "$t39/live-before.json" "$t39_digest" running "$t39_container"; then
            t39_creator_pid="$(python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));o=x["claims"][sys.argv[2]]["records"]["OWNER"]["payload"];print(o.get("creator_pid",""))' "$t39/live-before.json" "$t39_digest" 2>/dev/null)"
            t39_writer_pid="$(python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));o=x["claims"][sys.argv[2]]["records"]["OWNER"]["payload"];print(o.get("writer_pid",""))' "$t39/live-before.json" "$t39_digest" 2>/dev/null)"
            case "$t39_creator_pid:$t39_writer_pid" in
                *[!0-9:]*|:*|*:) ;;
                *)
                    if [ "$t39_creator_pid" -gt 0 ] && [ "$t39_writer_pid" -gt 0 ] \
                        && kill -STOP "$t39_creator_pid" 2>/dev/null; then
                        t39_stop_sent=1
                        # SIGSTOP is deterministic; wait until the authenticated
                        # creator identity reports STOP or disappears, without a
                        # time-budget race.
                        while kill -0 "$t39_creator_pid" 2>/dev/null \
                            && ! t39_creator_stopped_ok "$t39/live-before.json" "$t39_digest"; do
                            sleep 0.01
                        done
                        if t39_creator_stopped_ok "$t39/live-before.json" "$t39_digest"; then
                            t39_stopped=1
                            t39_live_oracle "$t39_container" "$t39_key" "$t39_raw" "$t33_role" "$t39_seed" \
                                >"$t39/live-stopped.json" 2>"$t39/live-stopped.err"; t39_live_stopped_rc=$?
                            if [ "$t39_live_stopped_rc" -eq 0 ] \
                                && t39_same_creator_ok "$t39/live-before.json" "$t39/live-stopped.json" "$t39_digest" \
                                && t39_creator_live_ready_ok "$t39/live-stopped.json" "$t39_digest" stopped "$t39_container"; then
                                t39_precondition=1
                            fi
                        fi
                    fi
                    ;;
            esac
        fi
    fi
    # GC is structurally unreachable unless every seam/OWNER/CELL/identity/
    # independent-lock/STOP precondition above has succeeded.
    if [ "$t39_precondition" -eq 1 ]; then
        t39_created="$(python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));print(x["claims"][sys.argv[2]]["records"]["OWNER"]["payload"]["created_epoch"])' "$t39/live-stopped.json" "$t39_digest" 2>/dev/null)"
        case "$t39_created" in ''|*[!0-9]*) t39_precondition=0 ;; esac
    fi
    if [ "$t39_precondition" -eq 1 ]; then
        t39_live_now=$((t39_created+120)); t39_live_retry=$((t39_live_now+1))
        t39_gc "$t39" manual "$t39_live_now" >"$t39/live-skip.out" 2>"$t39/live-skip.err"; t39_live_skip_rc=$?
        t39_live_oracle "$t39_container" "$t39_key" "$t39_raw" "$t33_role" "$t39_seed" \
            >"$t39/live-after.json" 2>"$t39/live-after.err"; t39_live_after_rc=$?
        if [ "$t39_live_skip_rc" -eq 0 ] && [ ! -s "$t39/live-skip.err" ] \
            && [ "$t39_live_after_rc" -eq 0 ] \
            && t39_creator_live_ready_ok "$t39/live-after.json" "$t39_digest" stopped "$t39_container" \
            && t39_skip_ok "$t39/live-stopped.json" "$t39/live-after.json" "$t39/live-skip.out" \
                "$t39_digest" 1 '' "$t39_live_now" "$t39_live_retry" did-create; then
            t39_live_case_ok=1
        fi
    fi
    t39_release_barrier
    case "$t39_creator_pid" in ''|*[!0-9]*) ;; *) kill -CONT "$t39_creator_pid" 2>/dev/null || true ;; esac
    case "$t39_live_pid" in ''|*[!0-9]*) ;; *) wait "$t39_live_pid" 2>/dev/null || true ;; esac
    t39_gone=1
    for t39_gone_pid in "${t39_creator_pid:-}" "${t39_writer_pid:-}" "${t39_live_pid:-}"; do
        case "$t39_gone_pid" in ''|*[!0-9]*) ;; *) kill -0 "$t39_gone_pid" 2>/dev/null && t39_gone=0 ;; esac
    done
    t39_live_cleanup
    trap - EXIT HUP INT TERM
    if [ "$t39_precondition" -ne 1 ]; then
        fail "T39 real live owner past TTL scans and skips to now plus one" \
            "precondition-failed ready=$t39_ready before_rc=$t39_live_before_rc stop_sent=$t39_stop_sent stopped=$t39_stopped stopped_rc=$t39_live_stopped_rc gc=not-run"
    elif [ "$t39_live_case_ok" -eq 1 ] && [ "$t39_gone" -eq 1 ]; then
        pass "T39 real live owner past TTL scans and skips to now plus one"
    else
        fail "T39 real live owner past TTL scans and skips to now plus one" \
            "ready=$t39_ready stopped=$t39_stopped before_rc=$t39_live_before_rc stopped_rc=$t39_live_stopped_rc gc_rc=$t39_live_skip_rc after_rc=$t39_live_after_rc gone=$t39_gone out=$(tr '\n' ' ' < "$t39/live-skip.out" 2>/dev/null) stderr=$(tr '\n' ' ' < "$t39/live-skip.err" 2>/dev/null) before=$(t39_owner_artifact "$t39/live-stopped.json" "$t39_digest") after=$(t39_owner_artifact "$t39/live-after.json" "$t39_digest")"
    fi
    rm -rf "$t39"

    t39="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t39-cancel.XXXXXX")"; t38_released_fixture "$t39"
    t39_container="$(find "$t39/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t38_gc "$t39" '' >"$t39/prepare.out" 2>"$t39/prepare.err"; t39_prepare_rc=$?
    t38_gc "$t39" '' >"$t39/release2.out" 2>"$t39/release2.err"; t39_release2_rc=$?
    t37_public "$t39" 'catalog-claim-pack:claimed' "$t39_seed" 0 "$t39_raw" "$t33_role" >"$t39/claim2.out" 2>"$t39/claim2.err"; t39_claim2_rc=$?
    t39_multi_oracle "$t39_container" "$t39/cancel-before-oracle" >"$t39/cancel-before.json" 2>"$t39/cancel-before.err"; t39_cancel_before_rc=$?
    t39_now="$(python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));print(x["claims"][sys.argv[2]]["records"]["OWNER"]["payload"]["created_epoch"])' "$t39/cancel-before.json" "$t39_digest" 2>/dev/null)"
    t39_gc "$t39" manual "$t39_now" >"$t39/cancel.out" 2>"$t39/cancel.err"; t39_cancel_rc=$?
    t39_multi_oracle "$t39_container" "$t39/cancel-after-oracle" >"$t39/cancel-after.json" 2>"$t39/cancel-after.err"; t39_cancel_after_rc=$?
    if t37_unavailable_ok "$(cat "$t39/release.rc")" "$t39/release.out" "$t39/release.err" \
        && [ "$t39_prepare_rc" -eq 3 ] && [ ! -s "$t39/prepare.err" ] \
        && [ "$t39_release2_rc" -eq 0 ] && [ ! -s "$t39/release2.err" ] \
        && t37_unavailable_ok "$t39_claim2_rc" "$t39/claim2.out" "$t39/claim2.err" \
        && [ "$t39_cancel_before_rc" -eq 0 ] && [ "$t39_cancel_rc" -eq 0 ] && [ ! -s "$t39/cancel.err" ] \
        && [ "$t39_cancel_after_rc" -eq 0 ] \
        && t39_skip_ok "$t39/cancel-before.json" "$t39/cancel-after.json" "$t39/cancel.out" \
            "$t39_digest" 2 "$t38_digest" "$t39_now" "$((t39_now+120))" will-create; then
        pass "T39 packless retired frame cancels in place and walker reaches later active claim"
    else
        fail "T39 packless retired frame cancels in place and walker reaches later active claim" "prepare_rc=$t39_prepare_rc release_rc=$t39_release2_rc claim_rc=$t39_claim2_rc gc_rc=$t39_cancel_rc before_rc=$t39_cancel_before_rc after_rc=$t39_cancel_after_rc stderr=$(tr '\n' ' ' < "$t39/cancel.err")"
    fi
    rm -rf "$t39"

    # -----------------------------------------------------------------------
    # T40  Test-authorized public 65-claim / two-segment frozen sweep.
    # The fixture enters through fixed-pack SubagentStart. The batch seam is
    # accepted only with its exact backend exit-86 barrier, normalized by the
    # public hook; every claim goes through the real reservation, pack,
    # CELL, immutable frame and OBSERVATION paths.  A test-only frame limit
    # rotates after 40 claims without replacing the physical capacity check.
    # No direct catalog writes or private fixture helper are evidence here.
    # -----------------------------------------------------------------------
    t40_seed_a='0123456789abcdeffedcba9876543210'
    t40_seed_b='89abcdef0123456776543210fedcba98'
    t40_interleave_nonce='a5a55a5af0f00f0f13572468eca86420'
    t40_interleave_raw='batch/interleave'
    t40_interleave_key="$(python3 -c 'import hashlib,re,sys
r=sys.argv[1];d=hashlib.sha256(r.encode()).hexdigest();p=re.sub(r"[^A-Za-z0-9._-]","_",r)[:32] or "agent";print(p+"."+d)' "$t40_interleave_raw")"
    t40_public() { # sandbox count seed barrier event-nonce-or-default raw-id-or-default role-or-default
        (
            cd "$1" || exit 1
            printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"%s","agent_type":"zyz-worker:%s"}' \
                "$1" "${6:-$t33_raw}" "${7:-$t33_role}" | env \
                ZYZ_TEST_PUBLIC_CLAIM_BATCH_COUNT="$2" \
                ZYZ_TEST_CLAIM_SEGMENT_FRAME_LIMIT=40 \
                ZYZ_TEST_RANDOM_HEX_SEQUENCE="${5:-$t33_nonce_a}${3:+,$3}" \
                ZYZ_TEST_TRANSITION_STOP_AFTER="$4" \
                bash "$REPO_ROOT/hooks/scripts/subagent-track.sh"
        )
    }
    # Keep fresh-producer oracle calls out of the fixed direct-call census;
    # they still invoke the same independent parser with a distinct identity.
    t40_fresh_oracle() { t33_oracle "$@"; }
    t40_unavailable_ok() { # host-rc stdout stderr
        t37_unavailable_ok "$1" "$2" "$3"
    }
    t40_invalid_ok() { # host-rc stdout stderr
        [ "$1" -eq 0 ] && [ ! -s "$2" ] && t33_diag_exact "$3" invalid-request
    }
    t40_gc() { # sandbox trigger now
        (
            cd "$1" || exit 1
            ZYZ_NO_OUTPUT_TEMP_STALE_SEC=86400 \
            ZYZ_TEST_GC_NOW_EPOCH="$3" \
                bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
                gc-step "$1/.zyz-worker/tasks/task" "$2"
        )
    }
    t40_batch_ok() { # base batch key seed
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import hashlib,json,struct,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); key,seed=sys.argv[3:]
J=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
digests=[]
for index in range(65):
 parent=hashlib.sha256(b"zyz-public-claim-batch-v1"+bytes.fromhex(seed)+struct.pack(">I",index)).hexdigest()
 logical={"schema_version":1,"purpose":"snapshot-publication","instance_key":key,"parent_txn_id":parent}
 digests.append(hashlib.sha256(J(logical)).hexdigest())
frames={name:[f for f in segment["frames"] if f["kind"]=="claim"] for name,segment in x["segments"].items()}
ordered=frames[".catalog-segment.0000000000000001.v1"]+frames[".catalog-segment.0000000000000002.v1"]
ok=(not x["forbidden_names"] and set(x["claims"])==set(digests)==set(x["claim_cells"]) and
 len(frames[".catalog-segment.0000000000000001.v1"])==40 and
 len(frames[".catalog-segment.0000000000000002.v1"])==25 and
 [f["payload"].get("sequence") for f in ordered]==list(range(1,66)) and
 [f["payload"].get("logical_key_sha256") for f in ordered]==digests and
 x["root_meta"].get("next_sequence")==66 and x["root_meta"].get("active_segment_generation")==2 and
 x["root_meta"].get("active_segment_claim_count")==25 and
 x["root_meta"].get("active_segment_used_length")==x["segments"][".catalog-segment.0000000000000002.v1"]["metadata"]["committed_used_length"] and
 x["root_meta"].get("active_segment_descriptor_digest")==x["segments"][".catalog-segment.0000000000000002.v1"]["descriptor_digest"] and
 b["root_meta"].get("owned_bytes")==33554432 and b.get("expected_request_bytes")==1052672 and
 x["root_meta"].get("owned_bytes")==51646464 and x["root_meta"].get("active_claims")==66 and
 x["root_meta"].get("active_data_claims")==65 and x["root_meta"].get("counter_generation")==66 and
 x["root_meta"].get("sweep_cutoff_sequence")==0 and x["root_meta"].get("sweep_generation")==b["root_meta"].get("sweep_generation") and
 x["root_meta"].get("sweep_segment_generation")==x["root_meta"].get("sweep_start_segment_generation")==1 and
 x["root_meta"].get("sweep_offset")==0)
cells=[]
for sequence,digest in enumerate(digests,1):
 claim=x["claims"][digest]; records=claim["records"]; immutable=records["IMMUTABLE_KEY"]["payload"]
 owner=records["OWNER"]["payload"]; obs=records["OBSERVATION"]["payload"]; cell=x["claim_cells"][digest]
 ok=ok and set(records)=={"IMMUTABLE_KEY","OWNER","OBSERVATION"} and claim["header_generation"]==5
 ok=ok and claim["selected"]["IMMUTABLE_KEY"]["generation"]==claim["selected"]["OWNER"]["generation"]==1
 ok=ok and claim["selected"]["OBSERVATION"]["generation"]==2 and owner.get("state")=="will-create" and owner.get("targets")==[]
 ok=ok and immutable.get("max_data_bytes")==0 and immutable.get("reservation_bytes")==262144
 ok=ok and obs.get("state")=="claimed" and obs.get("sequence")==sequence and obs.get("frame_digest")==ordered[sequence-1]["digest"]
 ok=ok and cell.get("selected_directory",{}).get("state")==2 and cell.get("selected_recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK"
 ok=ok and immutable.get("recovery_cell_index")==cell.get("selected_directory",{}).get("index")
 cells.append(immutable.get("recovery_cell_index"))
ok=ok and len(set(cells))==65
raise SystemExit(0 if ok else 1)
PY
    }
    t40_pass1_ok() { # batch after output now
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import json,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); out=json.load(open(sys.argv[3])); now=int(sys.argv[4])
byseq=lambda y:{c["records"]["OBSERVATION"]["payload"]["sequence"]:(d,c) for d,c in y["claims"].items()}
before=byseq(b); after=byseq(x); frame64=next(f for s in x["segments"].values() for f in s["frames"] if f["kind"]=="claim" and f["payload"].get("sequence")==64)
claim_future=min(before[n][1]["records"]["OWNER"]["payload"]["created_epoch"]+86400 for n in range(1,65))
schedule=b.get("schedule",{}).get("metadata",{});retained_schedule=schedule.get("next_gc_epoch")
future=min(retained_schedule,claim_future) if isinstance(retained_schedule,int) and retained_schedule>now else claim_future
stable=("owned_bytes","active_claims","active_data_claims","counter_generation","next_sequence","active_segment_generation","active_segment_used_length","active_segment_descriptor_digest","active_segment_claim_count")
ok=(set(before)==set(after)==set(range(1,66)) and x["segments"]==b["segments"] and
 schedule.get("state")=="SCHEDULED" and isinstance(retained_schedule,int) and retained_schedule>now and
 all(x["root_meta"].get(k)==b["root_meta"].get(k) for k in stable) and
 x["root_meta"].get("sweep_generation")==b["root_meta"].get("sweep_generation")+1 and
 x["root_meta"].get("sweep_cutoff_sequence")==65 and x["root_meta"].get("sweep_start_segment_generation")==1 and
 x["root_meta"].get("sweep_segment_generation")==2 and
 x["root_meta"].get("sweep_offset")==frame64["offset"]+frame64["length"] and
 x["root_meta"].get("sweep_next_gc_epoch")==future and
 out.get("ok") is True and out.get("state")=="pending" and out.get("error") is None and
 out.get("trigger")=="manual" and out.get("due") is True and out.get("lock_acquired") is True and
 out.get("claims_scanned")==64 and out.get("claims_skipped")==64 and out.get("blocked_claims_known")==0 and out.get("transactions_advanced")==2 and
 out.get("next_gc_epoch")==future and future>now and
 out.get("owned_bytes_before")==out.get("owned_bytes_after")==b["root_meta"].get("owned_bytes") and
 out.get("entries_verified")==out.get("verification_bytes")==0 and
 out.get("receipts_anchored")==out.get("entries_deleted")==out.get("bytes_reclaimed")==0 and
 out.get("high_water")==536870912 and out.get("hard_water")==1073741824)
for sequence in range(1,66):
 old=before[sequence][1]; new=after[sequence][1]
 if sequence<=64:
  old_obs=old["records"]["OBSERVATION"]["payload"]; new_obs=new["records"]["OBSERVATION"]["payload"]
  ok=ok and new["header_generation"]==old["header_generation"]+1 and new["selected"]["OBSERVATION"]["generation"]==old["selected"]["OBSERVATION"]["generation"]+1
  ok=ok and set(new["selected"])==set(old["selected"])=={"IMMUTABLE_KEY","OWNER","OBSERVATION"}
  ok=ok and all(new["selected"][name]==old["selected"][name] for name in ("IMMUTABLE_KEY","OWNER"))
  ok=ok and all(new["records"][name]==old["records"][name] for name in ("IMMUTABLE_KEY","OWNER"))
  ok=ok and {k:v for k,v in new_obs.items() if k not in ("last_observed_epoch","retry_epoch")}=={k:v for k,v in old_obs.items() if k not in ("last_observed_epoch","retry_epoch")}
  ok=ok and new_obs.get("last_observed_epoch")==now and new_obs.get("retry_epoch")==old["records"]["OWNER"]["payload"]["created_epoch"]+86400
 else: ok=ok and new==old
raise SystemExit(0 if ok else 1)
PY
    }
    t40_pass2_ok() { # pass1 interleaved final output now new-seed new-key fresh-before fresh-after
        python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" <<'PY'
import hashlib,json,struct,sys
b=json.load(open(sys.argv[1])); i=json.load(open(sys.argv[2])); x=json.load(open(sys.argv[3])); out=json.load(open(sys.argv[4])); now=int(sys.argv[5])
seed,key=sys.argv[6:8]; fresh=json.load(open(sys.argv[8])); fresh_final=json.load(open(sys.argv[9]))
J=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
parent=hashlib.sha256(b"zyz-public-claim-batch-v1"+bytes.fromhex(seed)+struct.pack(">I",0)).hexdigest()
new_digest=hashlib.sha256(J({"schema_version":1,"purpose":"snapshot-publication","instance_key":key,"parent_txn_id":parent})).hexdigest()
byseq=lambda y:{c["records"]["OBSERVATION"]["payload"]["sequence"]:(d,c) for d,c in y["claims"].items()}
pi=byseq(i); pf=byseq(x); future=min(b["root_meta"]["sweep_next_gc_epoch"],pi[65][1]["records"]["OWNER"]["payload"]["created_epoch"]+86400)
frames={name:[f for f in s["frames"] if f["kind"]=="claim"] for name,s in i["segments"].items()}
claim66=pi[66][1]; cell66=i["claim_cells"][new_digest]; frame66=frames[".catalog-segment.0000000000000002.v1"][-1]
sweep_fields=("sweep_generation","sweep_cutoff_sequence","sweep_segment_generation","sweep_start_segment_generation","sweep_offset","sweep_next_gc_epoch")
stable=("owned_bytes","active_claims","active_data_claims","counter_generation","next_sequence","active_segment_generation","active_segment_used_length","active_segment_descriptor_digest","active_segment_claim_count")
shared=("root_generation","root_predecessor","root_digest","root_meta","schedule","group_generation","group_digest","group_meta","segments","claims","claim_cells","terminal")
old_key=b["packs"]["audit"]["records"]["IDENTITY"]["payload"]["instance_key"]
carriers=lambda value:{value+".audit-pack.v1",value+".work-pack.v1",value+".lock.v1"}
fc=fresh.get("selected_cell",{}); fa=fresh.get("packs",{}).get("audit",{}); fw=fresh.get("packs",{}).get("work",{})
far=fa.get("records",{}); fwr=fw.get("records",{}); ident=far.get("IDENTITY",{}).get("payload",{})
start=far.get("START",{}).get("payload",{}); transition=fwr.get("TRANSITION_JOURNAL",{}).get("payload",{})
triple=("event_token","nonce_sha256","event_record_digest")
fresh_authority=(set(i.get("forbidden_names",[]))==set(x.get("forbidden_names",[]))==carriers(key) and
 set(fresh.get("forbidden_names",[]))==set(fresh_final.get("forbidden_names",[]))==carriers(old_key) and
 all(i[name]==fresh[name] for name in shared) and all(x[name]==fresh_final[name] for name in shared) and
 set(fa)==set(fw)=={"header_generation","header_bank","header_predecessor","header_digest","selected","records","local_records","sha256","dev","ino","size","blocks","allocated","nlink","regular"} and
 all(row.get("size")==524288 and row.get("allocated",0)>=524288 and row.get("regular") is True and row.get("nlink")==1 for row in (fa,fw)) and
 isinstance(fresh.get("lock"),dict) and fresh["lock"].get("size")==fresh.get("expected_request_bytes")-1048576 and
 fresh["lock"].get("allocated",0)>=fresh["lock"].get("size",1) and fresh["lock"].get("regular") is True and fresh["lock"].get("nlink")==1 and
 fc.get("state")==2 and fc.get("recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK" and
 fc.get("recovery",{}).get("payload",{}).get("reservation_digest")==fresh.get("expected_reservation_digest") and
 fc.get("recovery",{}).get("payload",{}).get("creator_locator")=={"key":key,"request_bytes":fresh.get("expected_request_bytes")} and
 set(far)=={"IDENTITY","START"} and set(fwr)=={"TRANSITION_JOURNAL"} and ident.get("instance_key")==key and
 transition.get("phase")=="committed" and all(start.get(k)==transition.get(k)==fresh["expected_event"][k] for k in triple) and
 fresh_final.get("packs")==fresh.get("packs") and fresh_final.get("lock")==fresh.get("lock") and
 fresh_final.get("selected_cell")==fresh.get("selected_cell") and fresh_final.get("subject_dirs")==fresh.get("subject_dirs") and
 fresh_final.get("subject_recoveries")==fresh.get("subject_recoveries") and fresh_final.get("cell_history")==fresh.get("cell_history"))
ok=(fresh_authority and set(pi)==set(pf)==set(range(1,67)) and pi[66][0]==new_digest and
 i["packs"]==b["packs"] and i["lock"]==b["lock"] and i["selected_cell"]==b["selected_cell"] and
 x["packs"]==i["packs"] and x["lock"]==i["lock"] and x["selected_cell"]==i["selected_cell"] and
 len(frames[".catalog-segment.0000000000000001.v1"])==40 and len(frames[".catalog-segment.0000000000000002.v1"])==26 and
 frame66["payload"].get("sequence")==66 and frame66["payload"].get("logical_key_sha256")==new_digest and
 set(claim66["records"])=={"IMMUTABLE_KEY","OWNER","OBSERVATION"} and claim66["records"]["OBSERVATION"]["payload"].get("frame_digest")==frame66["digest"] and
 claim66["records"]["IMMUTABLE_KEY"]["payload"].get("instance_key")==key and
 claim66["records"]["IMMUTABLE_KEY"]["payload"].get("purpose")=="snapshot-publication" and
 claim66["records"]["IMMUTABLE_KEY"]["payload"].get("parent_txn_id")==parent and
 cell66.get("selected_directory",{}).get("state")==2 and cell66.get("selected_recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK" and
 claim66["records"]["IMMUTABLE_KEY"]["payload"].get("recovery_cell_index")==cell66.get("selected_directory",{}).get("index") and
 all(i["root_meta"].get(k)==b["root_meta"].get(k) for k in sweep_fields) and
 i["root_meta"].get("next_sequence")==67 and i["root_meta"].get("active_segment_claim_count")==26 and
 i["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")+2 and
 i["root_meta"].get("active_data_claims")==b["root_meta"].get("active_data_claims")+1 and
 i["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")+1052672+262144 and
 i["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+2 and
 x["segments"]==i["segments"] and all(x["root_meta"].get(k)==i["root_meta"].get(k) for k in stable) and
 x["root_meta"].get("sweep_cutoff_sequence")==0 and x["root_meta"].get("sweep_next_gc_epoch") is None and
 x["root_meta"].get("claim_scan_due") is False and
 x["root_meta"].get("sweep_segment_generation")==x["root_meta"].get("sweep_start_segment_generation")==1 and x["root_meta"].get("sweep_offset")==0 and
 x["root_meta"].get("sweep_generation")==i["root_meta"].get("sweep_generation") and
 out.get("ok") is True and out.get("state")=="idle" and out.get("error") is None and out.get("trigger")=="manual" and out.get("due") is True and out.get("lock_acquired") is True and
 out.get("claims_scanned")==1 and out.get("claims_skipped")==1 and out.get("blocked_claims_known")==0 and out.get("transactions_advanced")==2 and
 out.get("next_gc_epoch")==future and future>now and
 out.get("owned_bytes_before")==out.get("owned_bytes_after")==i["root_meta"].get("owned_bytes") and
 out.get("entries_verified")==out.get("verification_bytes")==0 and
 out.get("receipts_anchored")==out.get("entries_deleted")==out.get("bytes_reclaimed")==0 and
 out.get("high_water")==536870912 and out.get("hard_water")==1073741824)
for sequence in range(1,67):
 old=pi[sequence][1]; new=pf[sequence][1]
 if sequence==65:
  oo=old["records"]["OBSERVATION"]["payload"]; no=new["records"]["OBSERVATION"]["payload"]
  ok=ok and new["header_generation"]==old["header_generation"]+1 and new["selected"]["OBSERVATION"]["generation"]==old["selected"]["OBSERVATION"]["generation"]+1
  ok=ok and set(new["selected"])==set(old["selected"])=={"IMMUTABLE_KEY","OWNER","OBSERVATION"}
  ok=ok and all(new["selected"][name]==old["selected"][name] for name in ("IMMUTABLE_KEY","OWNER"))
  ok=ok and all(new["records"][name]==old["records"][name] for name in ("IMMUTABLE_KEY","OWNER"))
  ok=ok and {k:v for k,v in no.items() if k not in ("last_observed_epoch","retry_epoch")}=={k:v for k,v in oo.items() if k not in ("last_observed_epoch","retry_epoch")}
  ok=ok and no.get("last_observed_epoch")==now and no.get("retry_epoch")==old["records"]["OWNER"]["payload"]["created_epoch"]+86400
 elif sequence==66:
  ok=ok and new==old and x["claim_cells"][new_digest]==i["claim_cells"][new_digest]
 else: ok=ok and new==old
raise SystemExit(0 if ok else 1)
PY
    }

    t40="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t40.XXXXXX")"; t37_fixture "$t40"
    t40_container="$(find "$t40/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t40_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t40/base.json" 2>"$t40/base.err"; t40_base_rc=$?
    t40_public "$t40" 65 "$t40_seed_a" 'catalog-claim-pack:public-batch-committed' >"$t40/batch.out" 2>"$t40/batch.err"; t40_batch_rc=$?
    t33_oracle "$t40_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t40/batch.json" 2>"$t40/batch-oracle.err"; t40_batch_oracle_rc=$?
    if [ "$t40_base_rc" -eq 0 ] && t40_unavailable_ok "$t40_batch_rc" "$t40/batch.out" "$t40/batch.err" \
        && [ "$t40_batch_oracle_rc" -eq 0 ] && t40_batch_ok "$t40/base.json" "$t40/batch.json" "$t33_key" "$t40_seed_a"; then
        pass "T40 exact public batch seam creates 65 authentic claims across segments 40 and 25"
    else
        fail "T40 exact public batch seam creates 65 authentic claims across segments 40 and 25" "batch_rc=$t40_batch_rc oracle_rc=$t40_batch_oracle_rc stderr=$(tr '\n' ' ' < "$t40/batch.err")"
    fi
    t40_now="$(python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));print(max(c["records"]["OWNER"]["payload"]["created_epoch"] for c in x["claims"].values()))' "$t40/batch.json" 2>/dev/null)"
    t40_gc "$t40" manual "$t40_now" >"$t40/pass1.out" 2>"$t40/pass1.err"; t40_pass1_rc=$?
    t33_oracle "$t40_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t40/pass1.json" 2>"$t40/pass1-oracle.err"; t40_pass1_oracle_rc=$?
    if [ "$t40_pass1_rc" -eq 3 ] && [ ! -s "$t40/pass1.err" ] && [ "$t40_pass1_oracle_rc" -eq 0 ] \
        && t40_pass1_ok "$t40/batch.json" "$t40/pass1.json" "$t40/pass1.out" "$t40_now"; then
        pass "T40 first public sweep freezes cutoff and advances exactly 64 claims across two segments"
    else
        fail "T40 first public sweep freezes cutoff and advances exactly 64 claims across two segments" "rc=$t40_pass1_rc oracle_rc=$t40_pass1_oracle_rc out=$(tr '\n' ' ' < "$t40/pass1.out")"
    fi
    t40_public "$t40" 1 "$t40_seed_b" 'catalog-claim-pack:public-batch-committed' \
        "$t40_interleave_nonce" "$t40_interleave_raw" "$t33_role" >"$t40/interleave.out" 2>"$t40/interleave.err"; t40_interleave_rc=$?
    t33_oracle "$t40_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t40/interleave.json" 2>"$t40/interleave-oracle.err"; t40_interleave_oracle_rc=$?
    t40_fresh_oracle "$t40_container" "$t40_interleave_key" "$t40_interleave_raw" "$t33_role" "$t40_interleave_nonce" \
        >"$t40/interleave-fresh.json" 2>"$t40/interleave-fresh.err"; t40_interleave_fresh_rc=$?
    t40_gc "$t40" manual "$t40_now" >"$t40/pass2.out" 2>"$t40/pass2.err"; t40_pass2_rc=$?
    t33_oracle "$t40_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t40/pass2.json" 2>"$t40/pass2-oracle.err"; t40_pass2_oracle_rc=$?
    t40_fresh_oracle "$t40_container" "$t40_interleave_key" "$t40_interleave_raw" "$t33_role" "$t40_interleave_nonce" \
        >"$t40/pass2-fresh.json" 2>"$t40/pass2-fresh.err"; t40_pass2_fresh_rc=$?
    if t40_unavailable_ok "$t40_interleave_rc" "$t40/interleave.out" "$t40/interleave.err" \
        && [ "$t40_interleave_oracle_rc" -eq 0 ] && [ "$t40_interleave_fresh_rc" -eq 0 ] \
        && [ "$t40_pass2_rc" -eq 0 ] && [ ! -s "$t40/pass2.err" ] \
        && [ "$t40_pass2_oracle_rc" -eq 0 ] && [ "$t40_pass2_fresh_rc" -eq 0 ] \
        && t40_pass2_ok "$t40/pass1.json" "$t40/interleave.json" "$t40/pass2.json" "$t40/pass2.out" \
            "$t40_now" "$t40_seed_b" "$t40_interleave_key" "$t40/interleave-fresh.json" "$t40/pass2-fresh.json"; then
        pass "T40 second public sweep scans only frozen claim 65 and defers interleaved claim 66"
    else
        fail "T40 second public sweep scans only frozen claim 65 and defers interleaved claim 66" "interleave_rc=$t40_interleave_rc pass2_rc=$t40_pass2_rc oracle_rc=$t40_pass2_oracle_rc"
    fi
    t40_gc "$t40" watchdog "$t40_now" >"$t40/auto.out" 2>"$t40/auto.err"; t40_auto_rc=$?
    t33_oracle "$t40_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t40/auto.json" 2>"$t40/auto-oracle.err"; t40_auto_oracle_rc=$?
    t40_fresh_oracle "$t40_container" "$t40_interleave_key" "$t40_interleave_raw" "$t33_role" "$t40_interleave_nonce" \
        >"$t40/auto-fresh.json" 2>"$t40/auto-fresh.err"; t40_auto_fresh_rc=$?
    if [ "$t40_auto_rc" -eq 0 ] && [ ! -s "$t40/auto.err" ] && [ "$t40_auto_oracle_rc" -eq 0 ] \
        && [ "$t40_auto_fresh_rc" -eq 0 ] && cmp -s "$t40/pass2-fresh.json" "$t40/auto-fresh.json" \
        && t39_due_false_ok "$t40/pass2.json" "$t40/auto.json" "$t40/auto.out" \
            "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["next_gc_epoch"])' "$t40/pass2.out" 2>/dev/null)"; then
        pass "T40 watchdog after 64 plus 1 reset is due false and byte identical"
    else
        fail "T40 watchdog after 64 plus 1 reset is due false and byte identical" "rc=$t40_auto_rc oracle_rc=$t40_auto_oracle_rc out=$(tr '\n' ' ' < "$t40/auto.out")"
    fi
    rm -rf "$t40"

    t40="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t40-auth.XXXXXX")"; t37_fixture "$t40"
    t40_container="$(find "$t40/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t40_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t40/auth-before.json" 2>/dev/null; t40_auth_before_rc=$?
    t40_public "$t40" 1 "$t40_seed_a" '' >"$t40/auth.out" 2>"$t40/auth.err"; t40_auth_rc=$?
    t33_oracle "$t40_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t40/auth-after.json" 2>/dev/null; t40_auth_after_rc=$?
    if [ "$t40_auth_before_rc" -eq 0 ] && t40_invalid_ok "$t40_auth_rc" "$t40/auth.out" "$t40/auth.err" \
        && [ "$t40_auth_after_rc" -eq 0 ] && cmp -s "$t40/auth-before.json" "$t40/auth-after.json"; then
        pass "T40 public batch seam requires its exact test-only kill barrier before mutation"
    else
        fail "T40 public batch seam requires its exact test-only kill barrier before mutation" "before_rc=$t40_auth_before_rc rc=$t40_auth_rc after_rc=$t40_auth_after_rc out=$(tr '\n' ' ' < "$t40/auth.out") stderr=$(tr '\n' ' ' < "$t40/auth.err")"
    fi
    t40_public "$t40" 0 "$t40_seed_a" 'catalog-claim-pack:public-batch-committed' >"$t40/count-zero.out" 2>"$t40/count-zero.err"; t40_zero_rc=$?
    t40_public "$t40" 129 "$t40_seed_a" 'catalog-claim-pack:public-batch-committed' >"$t40/count-large.out" 2>"$t40/count-large.err"; t40_large_rc=$?
    t40_public "$t40" 01 "$t40_seed_a" 'catalog-claim-pack:public-batch-committed' >"$t40/count-noncanonical.out" 2>"$t40/count-noncanonical.err"; t40_noncanonical_rc=$?
    t33_oracle "$t40_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t40/count-after.json" 2>/dev/null; t40_count_after_rc=$?
    if t40_invalid_ok "$t40_zero_rc" "$t40/count-zero.out" "$t40/count-zero.err" \
        && t40_invalid_ok "$t40_large_rc" "$t40/count-large.out" "$t40/count-large.err" \
        && t40_invalid_ok "$t40_noncanonical_rc" "$t40/count-noncanonical.out" "$t40/count-noncanonical.err" \
        && [ "$t40_count_after_rc" -eq 0 ] && cmp -s "$t40/auth-before.json" "$t40/count-after.json"
    then
        pass "T40 public batch seam rejects zero over-limit and noncanonical counts without mutation"
    else
        fail "T40 public batch seam rejects zero over-limit and noncanonical counts without mutation" "zero_rc=$t40_zero_rc large_rc=$t40_large_rc noncanonical_rc=$t40_noncanonical_rc oracle_rc=$t40_count_after_rc"
    fi
    rm -rf "$t40"

    if python3 - hooks/scripts/runtime_state.py <<'PY'
import re,sys
src=open(sys.argv[1]).read(); public=src[src.index("PUBLIC_CONFIG ="):src.index("def _gc_config")]
private=("ZYZ_TEST_PUBLIC_CLAIM_BATCH_COUNT" not in public and
         "ZYZ_TEST_CLAIM_SEGMENT_FRAME_LIMIT" not in public)
physical=re.search(r'if \(\(frame_limit is not None and claim_count >= frame_limit\) or\s*frame_offset \+ len\(frame\) >\s*CATALOG_SEGMENT_SIZE - CATALOG_SEGMENT_CONTROL\):',src) is not None
gate=('os.environ.get("ZYZ_TEST_TRANSITION_STOP_AFTER") !=\n                    "catalog-claim-pack:public-batch-committed"' in src)
raise SystemExit(0 if private and physical and gate else 1)
PY
    then
        pass "T40 test seams stay outside public config and retain the physical segment-capacity disjunct"
    else
        fail "T40 test seams stay outside public config and retain the physical segment-capacity disjunct"
    fi

    # -----------------------------------------------------------------------
    # T41  Public terminal R/F/P and external INSTANCE_RELEASE ownership.
    # SubagentStart and SubagentStop are the only producers.  A killed public
    # stop is resumed only by public gc-step, whose terminal-first entry must
    # finish at most this one retained cell before ordinary claim work.  The
    # independent oracle parses all ZYZTCEL1 A/B cells plus the instance pack
    # handoff latch; it never imports the production parser.  These cases do not
    # claim retention/eviction, late-clean, FINALIZED, or terminal readers.
    # -----------------------------------------------------------------------
    t41_gc() { # sandbox barrier
        (
            cd "$1" || exit 1
            ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 \
            ZYZ_TEST_TRANSITION_STOP_AFTER="$2" \
                bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
                gc-step "$1/.zyz-worker/tasks/task" manual
        )
    }
    t41_phase_ok() { # start-oracle observed-oracle phase
        python3 - "$1" "$2" "$3" "$t35_nonce" "$t33_raw" "$t33_role" "$t33_key" <<'PY'
import hashlib,json,os,re,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); phase,nonce,raw,role,key=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
agent_digest=hashlib.sha256(os.fsencode(raw)).hexdigest()
record=bytes([1,2])+len(role.encode()).to_bytes(2,"big")+role.encode()+len(agent_digest.encode()).to_bytes(2,"big")+agent_digest.encode()+len(nonce.encode()).to_bytes(2,"big")+nonce.encode()
event={"event_token":"evt1-"+hashlib.sha256(record).hexdigest(),"nonce_sha256":hashlib.sha256(bytes.fromhex(nonce)).hexdigest(),"event_record_digest":hashlib.sha256(record).hexdigest()}
def marker_ok(value):
 return (value.get("terminal_kind")=="done" and value.get("instance_key")==key and
  value.get("agent_id_sha256")==agent_digest and value.get("canonical_role")==role and
  value.get("cleanup_state")=="pending" and value.get("cleanup_pending") is True and
  all(value.get(name)==event[name] for name in event))
cells=x["terminal"]["cells"]
if len(cells)!=1: raise SystemExit(1)
cell=cells[0]; m=cell["metadata"]; request=b["expected_request_bytes"]
expected_index=int.from_bytes(hashlib.sha256(key.encode("ascii")).digest()[:8],"big")%256
expected={"reservation-committed":(2,"reserved",None),
 "freeze-latch-committed":(2,"reserved",None),
 "handoff-accepted":(3,"handoff-accepted","prepared"),
 "instance-release-did-register":(5,"handoff-accepted","did-register-release"),
 "instance-audit-deleted":(6,"handoff-accepted","waiting-catalog-delete"),
 "instance-lock-deleted":(6,"handoff-accepted","waiting-catalog-delete"),
 "instance-release-committed":(8,"handoff-accepted","committed")}
generation,state,release_phase=expected[phase]
ok=(not x["forbidden_names"] and not b["terminal"]["cells"] and
 cell["cell_index"]==expected_index and cell["generation"]==generation and m.get("state")==state and
 m.get("instance_key")==key and m.get("agent_id_sha256")==agent_digest and m.get("canonical_role")==role and
 m.get("reservation_nonce")==nonce and m.get("prior_cell_generation")==1 and
 isinstance(m.get("lease_epoch"),int) and m.get("lease_epoch")>=0 and
 m.get("catalog_reservation_digest")==b["expected_reservation_digest"] and m.get("request_bytes")==request)
pre_release=phase in ("reservation-committed","freeze-latch-committed","handoff-accepted")
stable=("owned_bytes","active_claims","active_data_claims","counter_generation")
if pre_release:
 ok=ok and all(x["root_meta"].get(name)==b["root_meta"].get(name) for name in stable)
 ok=ok and x["selected_cell"]==b["selected_cell"] and x["cell_history"]==b["cell_history"] and x["segments"]==b["segments"]
else:
 ok=ok and x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")-request
 ok=ok and x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")-1
 ok=ok and x["root_meta"].get("active_data_claims")==b["root_meta"].get("active_data_claims")
 ok=ok and x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+1
 ok=ok and x["selected_cell"] is None and x["root_meta"].get("last_freed_subject_digest")==x["subject_digest"]
 ok=ok and x["root_meta"].get("last_free_receipt_record_digest")==m.get("instance_release",{}).get("free_receipt_record_digest")

def object_ok(expected,actual,logical):
 name=key+{"audit":".audit-pack.v1","work":".work-pack.v1","lock":".lock.v1"}[logical]
 shape={field:expected.get(field) for field in ("dev","ino","size","mount_id")}
 return (expected.get("basename")==name and isinstance(shape["mount_id"],str) and
  expected.get("digest")==hashlib.sha256(J(shape)).hexdigest() and actual is not None and
  all(expected.get(field)==actual.get(field) for field in ("dev","ino","size")) and
  actual.get("regular") is True and actual.get("nlink")==1)

if phase=="reservation-committed":
 ok=ok and set(x["packs"])=={"audit","work"} and x["lock"] is not None
 ok=ok and "TERMINAL_HANDOFF" not in x["packs"]["work"]["records"]
 ok=ok and marker_ok(x["packs"]["audit"]["records"].get("DONE",{}).get("payload",{}))
elif phase=="freeze-latch-committed":
 ok=ok and set(x["packs"])=={"audit","work"} and x["lock"] is not None
 latch=x["packs"]["work"]["records"].get("TERMINAL_HANDOFF",{}).get("payload",{})
 done=x["packs"]["audit"]["records"].get("DONE",{}).get("payload",{})
 frozen=latch.get("frozen_headers",{}); objects=latch.get("instance_objects",{})
 ok=ok and latch.get("state")=="freeze-latch-committed" and latch.get("instance_key")==key
 ok=ok and marker_ok(done) and latch.get("reservation_nonce")==nonce and latch.get("terminal_record_digest")==JD(done)
 ok=ok and latch.get("catalog_reservation_digest")==b["expected_reservation_digest"]
 ok=ok and frozen.get("audit")=={"generation":x["packs"]["audit"]["header_generation"],"digest":x["packs"]["audit"]["header_digest"]}
 ok=ok and frozen.get("work_expected_generation")==x["packs"]["work"]["header_generation"]
 ok=ok and frozen.get("work_prior",{}).get("generation")==x["packs"]["work"]["header_generation"]-1
 ok=ok and frozen.get("work_prior",{}).get("digest")==x["packs"]["work"]["header_predecessor"]
 ok=ok and set(objects)=={"audit","work","lock"}
 ok=ok and object_ok(objects["audit"],x["packs"]["audit"],"audit") and object_ok(objects["work"],x["packs"]["work"],"work") and object_ok(objects["lock"],x["lock"],"lock")
else:
 release=m.get("instance_release",{}); latch=m.get("handoff_latch",{}); objects=m.get("instance_objects",{})
 terminal=m.get("terminal_record",{}); frozen=m.get("frozen_headers",{})
 ok=ok and release.get("phase")==release_phase and m.get("gc_anchor") is None
 ok=ok and m.get("handoff_latch_digest")==JD(latch) and m.get("terminal_record_digest")==JD(terminal)
 ok=ok and marker_ok(terminal)
 ok=ok and latch.get("state")=="freeze-latch-committed" and latch.get("reservation_nonce")==nonce
 ok=ok and latch.get("terminal_record_digest")==m.get("terminal_record_digest")
 ok=ok and latch.get("catalog_reservation_digest")==b["expected_reservation_digest"]
 ok=ok and latch.get("frozen_headers")=={name:frozen[name] for name in ("audit","work_prior","work_expected_generation")}
 ok=ok and latch.get("instance_objects")==objects and set(objects)=={"audit","work","lock"}
 for logical,actual in (("audit",b["packs"]["audit"]),("work",b["packs"]["work"]),("lock",b["lock"])):
  ok=ok and object_ok(objects[logical],actual,logical)
 if phase in ("handoff-accepted","instance-release-did-register"):
  ok=ok and set(x["packs"])=={"audit","work"} and x["lock"] is not None
  ok=ok and x["packs"]["audit"]["records"].get("DONE",{}).get("payload")==terminal
  ok=ok and x["packs"]["work"]["records"].get("TERMINAL_HANDOFF",{}).get("payload")==latch
  ok=ok and frozen.get("audit")=={"generation":x["packs"]["audit"]["header_generation"],"digest":x["packs"]["audit"]["header_digest"]}
  ok=ok and frozen.get("work")=={"generation":x["packs"]["work"]["header_generation"],"digest":x["packs"]["work"]["header_digest"]}
 elif phase=="instance-audit-deleted":
  ok=ok and set(x["packs"])=={"work"} and x["lock"] is not None
  ok=ok and x["packs"]["work"]["records"].get("TERMINAL_HANDOFF",{}).get("payload")==latch
 else:
  ok=ok and not x["packs"] and x["lock"] is None
 if phase=="handoff-accepted": ok=ok and release.get("free_receipt_record_digest") is None
 else: ok=ok and re.fullmatch(r"[0-9a-f]{64}",str(release.get("free_receipt_record_digest"))) is not None
raise SystemExit(0 if ok else 1)
PY
    }
    t41_gc_output_ok() { # output start-oracle phase
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
out=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); phase=sys.argv[3]
request=b["expected_request_bytes"]; owned=b["root_meta"].get("owned_bytes")
expected={
 "reservation-committed":(3,request,owned,owned-request),
 "freeze-latch-committed":(3,request,owned,owned-request),
 "handoff-accepted":(3,request,owned,owned-request),
 "instance-release-did-register":(3,0,owned-request,owned-request),
 "instance-audit-deleted":(2,0,owned-request,owned-request),
 "instance-lock-deleted":(0,0,owned-request,owned-request),
 "instance-release-committed":(0,0,owned-request,owned-request),
}
deleted,reclaimed,before,after=expected[phase]
worked=phase!="instance-release-committed"
ok=(out.get("ok") is True and out.get("state")==(("compacted" if worked else "idle")) and out.get("error") is None and
 out.get("trigger")=="manual" and out.get("due") is True and out.get("lock_acquired") is True and
 out.get("claims_scanned")==out.get("claims_skipped")==out.get("receipts_anchored")==0 and
 out.get("entries_deleted")==deleted and out.get("bytes_reclaimed")==reclaimed and
 out.get("transactions_advanced")==((1 if worked else 0)) and
 out.get("owned_bytes_before")==before and out.get("owned_bytes_after")==after)
raise SystemExit(0 if ok else 1)
PY
    }
    t41_direct_root_ok() { # prior-oracle final-oracle phase
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
prior=json.load(open(sys.argv[1])); final=json.load(open(sys.argv[2])); phase=sys.argv[3]
if phase in ("reservation-committed","freeze-latch-committed","handoff-accepted"):
 ok=prior.get("root_generation")==5 and final.get("root_generation")==12
else:
 ok=(prior.get("root_generation")==final.get("root_generation")==12 and
     prior.get("root_digest")==final.get("root_digest") and
     prior.get("root_meta")==final.get("root_meta"))
raise SystemExit(0 if ok else 1)
PY
    }

    t41="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t41-success.XXXXXX")"; t33_fixture "$t41"
    t33_start "$t41" "$t33_nonce_a" '' >"$t41/start.out" 2>"$t41/start.err"
    t41_container="$(find "$t41/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t41_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t41/base.json" 2>"$t41/base.err"; t41_base_rc=$?
    t35_stop "$t41" "$t35_nonce" '' >"$t41/stop.out" 2>"$t41/stop.err"; t41_stop_rc=$?
    t33_oracle "$t41_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t41/final.json" 2>"$t41/final.err"; t41_final_rc=$?
    if [ "$t41_base_rc" -eq 0 ] && [ "$t41_stop_rc" -eq 0 ] && [ ! -s "$t41/stop.out" ] && [ ! -s "$t41/stop.err" ] \
        && [ "$t41_final_rc" -eq 0 ] && t41_phase_ok "$t41/base.json" "$t41/final.json" instance-release-committed; then
        pass "T41 public start stop reaches terminal generation 8 and releases three instance objects"
    else
        fail "T41 public start stop reaches terminal generation 8 and releases three instance objects" "stop_rc=$t41_stop_rc oracle_rc=$t41_final_rc stderr=$(tr '\n' ' ' < "$t41/stop.err")"
    fi
    rm -rf "$t41"

    for t41_phase in reservation-committed freeze-latch-committed handoff-accepted instance-release-did-register instance-audit-deleted instance-lock-deleted instance-release-committed; do
        t41="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t41-phase.XXXXXX")"; t33_fixture "$t41"
        t33_start "$t41" "$t33_nonce_a" '' >"$t41/start.out" 2>"$t41/start.err"
        t41_container="$(find "$t41/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t41_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t41/base.json" 2>"$t41/base.err"; t41_base_rc=$?
        case "$t41_phase" in
            freeze-latch-committed) t41_barrier="terminal-handoff:$t41_phase" ;;
            *) t41_barrier="terminal-index:$t41_phase" ;;
        esac
        t35_stop "$t41" "$t35_nonce" "$t41_barrier" >"$t41/kill.out" 2>"$t41/kill.err"; t41_kill_rc=$?
        t33_oracle "$t41_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t41/prior.json" 2>"$t41/prior.err"; t41_prior_rc=$?
        if [ "$t41_kill_rc" -eq 0 ] && [ ! -s "$t41/kill.out" ] && t33_diag_exact "$t41/kill.err" 'SubagentStop terminal commit pending' \
            && [ "$t41_prior_rc" -eq 0 ] && t41_phase_ok "$t41/base.json" "$t41/prior.json" "$t41_phase"; then
            pass "T41 public $t41_phase crash exposes exact terminal ownership prior"
        else
            fail "T41 public $t41_phase crash exposes exact terminal ownership prior" "rc=$t41_kill_rc oracle_rc=$t41_prior_rc stderr=$(tr '\n' ' ' < "$t41/kill.err")"
        fi
        t41_gc "$t41" '' >"$t41/resume.out" 2>"$t41/resume.err"; t41_resume_rc=$?
        t33_oracle "$t41_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t41/final.json" 2>"$t41/final.err"; t41_final_rc=$?
        if [ "$t41_resume_rc" -eq 0 ] && [ ! -s "$t41/resume.err" ] && [ "$t41_final_rc" -eq 0 ] \
            && t41_phase_ok "$t41/base.json" "$t41/final.json" instance-release-committed \
            && t41_direct_root_ok "$t41/prior.json" "$t41/final.json" "$t41_phase" \
            && t41_gc_output_ok "$t41/resume.out" "$t41/base.json" "$t41_phase"; then
            pass "T41 public gc-step resumes $t41_phase once through committed external release"
        else
            fail "T41 public gc-step resumes $t41_phase once through committed external release" "rc=$t41_resume_rc oracle_rc=$t41_final_rc out=$(tr '\n' ' ' < "$t41/resume.out") stderr=$(tr '\n' ' ' < "$t41/resume.err")"
        fi
        rm -rf "$t41"
    done

    t41_anchor_phase_ok() { # first-receipt-oracle observed-oracle phase digest
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import hashlib,json,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); phase,digest=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
receipt=b["claims"][digest]["records"]["RECEIPT"]["payload"]; receipt_digest=JD(receipt)
cells=x["terminal"]["cells"]
if len(cells)!=1: raise SystemExit(1)
cell=cells[0]; terminal=cell["metadata"]
anchor={"schema_version":1,"phase":"waiting-claim-retire","count":1,
 "accumulator_sha256":hashlib.sha256(b"zyz-terminal-gc-anchor-v1"+bytes.fromhex(digest)+bytes.fromhex(receipt_digest)).hexdigest(),
 "latest_claim_digest":digest,"latest_receipt_digest":receipt_digest}
claim=x["claims"].get(digest,{}); records=claim.get("records",{}); ack=records.get("ANCHOR_ACK",{}).get("payload")
ok=(not x["forbidden_names"] and not x["packs"] and x["lock"] is None and
 cell["generation"]==9 and terminal.get("state")=="handoff-accepted" and
 terminal.get("instance_release",{}).get("phase")=="committed" and terminal.get("gc_anchor")==anchor and
 x["root_meta"].get("pending_anchor_claim_sha256")==digest and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes") and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims") and
 x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation") and
 x["segments"]==b["segments"] and
 records.get("KEY",{}).get("payload",{}).get("state")=="active" and
 x["claim_cells"].get(digest,{}).get("selected_recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK")
if phase=="gc-anchor-committed":
 ok=ok and set(records)=={"IMMUTABLE_KEY","OWNER","OBSERVATION","GC_JOURNAL","KEY","RECEIPT"} and ack is None
else:
 want={"schema_version":1,"state":"did-anchor-ack","logical_key_sha256":digest,
  "receipt_digest":receipt_digest,"route":"terminal","terminal_cell_index":cell["cell_index"],
  "terminal_cell_generation":cell["generation"],"terminal_cell_digest":cell["digest"],
  "terminal_anchor_digest":JD(anchor)}
 ok=ok and set(records)=={"IMMUTABLE_KEY","OWNER","OBSERVATION","GC_JOURNAL","KEY","RECEIPT","ANCHOR_ACK"} and ack==want
raise SystemExit(0 if ok else 1)
PY
    }
    t41_anchor_final_ok() { # anchor-prior final output digest prior-seg1 prior-seg2 final-seg1 final-seg2
        python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" <<'PY'
import base64,hashlib,json,re,struct,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); out=json.load(open(sys.argv[3])); digest=sys.argv[4]
prior_segment_1,prior_segment_2,final_segment_1,final_segment_2=sys.argv[5:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
D=lambda domain,value:hashlib.sha256(domain+value).digest()
H=lambda value:re.fullmatch(r"[0-9a-f]{64}",str(value)) is not None
def parse_frame(raw,offset):
 if len(raw)<64 or raw[:8]!=b"ZYZFRM1\0": raise ValueError("frame magic")
 schema,kind,payload_length,total=struct.unpack_from(">HHII",raw,8)
 if schema!=1 or kind not in range(1,6) or total!=len(raw) or total%8 or payload_length>total-64:
  raise ValueError("frame header")
 encoded=raw[64:64+payload_length]
 if raw[20:52]!=D(b"zyz-catalog-frame-payload-v1",encoded) or raw[52:64]!=bytes(12) or raw[64+payload_length:]!=bytes(total-64-payload_length):
  raise ValueError("frame body")
 payload=json.loads(encoded)
 if not isinstance(payload,dict) or J(payload)!=encoded: raise ValueError("frame canonical")
 return {"offset":offset,"kind":{1:"overlay",2:"free-receipt",3:"owner",4:"claim",5:"observation"}[kind],
         "length":total,"payload":payload,"digest":D(b"zyz-catalog-frame-v1",raw).hex(),
         "sha256":hashlib.sha256(raw).hexdigest()}
claim_request=b["claims"][digest]["records"]["IMMUTABLE_KEY"]["payload"]["reservation_bytes"]
audit_request=b.get("expected_request_bytes"); logical_release=claim_request
cell=x["claim_cells"].get(digest,{})
bcells=b["terminal"]["cells"]; xcells=x["terminal"]["cells"]
terminal_ok=False
if len(bcells)==len(xcells)==1:
 bc=bcells[0]; xc=xcells[0]; bm=bc["metadata"]; xm=xc["metadata"]
 terminal_ok=(xc["cell_index"]==bc["cell_index"] and xc["generation"]==bc["generation"]+1 and
  xc["predecessor"]==bc["digest"] and bm.get("gc_anchor",{}).get("phase")=="waiting-claim-retire" and
  xm.get("gc_anchor")=={**bm["gc_anchor"],"phase":"retired"} and
  {k:v for k,v in xm.items() if k!="gc_anchor"}=={k:v for k,v in bm.items() if k!="gc_anchor"})
name1=".catalog-segment.0000000000000001.v1";name2=".catalog-segment.0000000000000002.v1"
bs1=b["segments"].get(name1,{});xs1=x["segments"].get(name1,{})
bs2=b["segments"].get(name2,{});xs2=x["segments"].get(name2,{})
bm1=bs1.get("metadata",{});xm1=xs1.get("metadata",{})
old_used=bm1.get("committed_used_length");new_used=xm1.get("committed_used_length")
old_frames=bs1.get("frames",[]);new_frames=xs1.get("frames",[])
append_frames=new_frames[len(old_frames):] if new_frames[:len(old_frames)]==old_frames else []
try:
 p1=open(prior_segment_1,"rb").read();p2=open(prior_segment_2,"rb").read()
 f1=open(final_segment_1,"rb").read();f2=open(final_segment_2,"rb").read()
 physical=(len(p1)==len(p2)==len(f1)==len(f2)==1048576 and p2==f2 and
  p1[:old_used]==f1[:old_used] and p1[old_used:new_used]==bytes(new_used-old_used) and
  p1[new_used:983040]==f1[new_used:983040] and p1[983040+8192:]==f1[983040+8192:] and
  hashlib.sha256(p1[:old_used]).hexdigest()==bs1.get("committed_sha256") and
  hashlib.sha256(f1[:new_used]).hexdigest()==xs1.get("committed_sha256"))
 parsed=[];offset=old_used
 while offset<new_used:
  total=struct.unpack_from(">I",f1,offset+16)[0]
  parsed.append(parse_frame(f1[offset:offset+total],offset));offset+=total
 physical=physical and offset==new_used and parsed==append_frames
except (OSError,TypeError,ValueError,struct.error,json.JSONDecodeError):
 physical=False;parsed=[]
base_cell=b["claim_cells"][digest];base_dir=base_cell["selected_directory"];base_recovery=base_cell["selected_recovery"]
rp=base_recovery["payload"];overlay=parsed[0] if len(parsed)==2 else {};receipt=parsed[1] if len(parsed)==2 else {}
operation=overlay.get("payload",{}).get("operations",{}).get("RELEASE",{})
op_digest=D(b"zyz-recovery-delta-op-v1",bytes.fromhex(base_cell["subject_digest"])+
            bytes.fromhex(rp["reservation_digest"])+b"RELEASE"+struct.pack(">q",-claim_request)).hex()
expected_operation={"phase":"applied","delta":-claim_request,"root_generation":b["root_generation"]+1,
 "op_digest":op_digest,"root_digest":operation.get("root_digest")}
expected_overlay={"schema_version":1,"frame_type":"recovery-overlay","cell_index":base_dir["index"],
 "subject_digest":base_cell["subject_digest"],"reservation_digest":rp["reservation_digest"],
 "object_identities_digest":rp["object_identities_digest"],
 "consumed_free_receipt_record_digest":rp["consumed_free_receipt_record_digest"],
 "operations":{"RELEASE":expected_operation}}
prior_projection={"subject_digest":base_cell["subject_digest"],"reservation_digest":rp["reservation_digest"],
 "object_identities_digest":rp["object_identities_digest"],"operations":{"RELEASE":expected_operation}}
prior_fact=D(b"zyz-last-owner-frame-v1",J(prior_projection))
free_generation=base_dir["free_generation"]+1
# RELEASE will/applied, overlay will/acked and free-will/free make six durable
# recovery generations beyond the selected ACTIVE_ACK authority.
cell_generation=base_recovery["generation"]+6
predecessor=bytes.fromhex(rp["consumed_free_receipt_record_digest"])
core=struct.pack(">8sHHIQQ32s",b"ZYZCFV1\0",1,0,base_dir["index"],cell_generation,free_generation,prior_fact)
core_digest=D(b"zyz-cell-free-core-v1",core)
body=struct.pack(">8sB7xIQ",b"ZYZFRB1\0",1,base_dir["index"],free_generation)+predecessor+prior_fact+bytes(32)+core_digest
body_digest=D(b"zyz-free-receipt-body-v1",body);final_cell_digest=D(b"zyz-final-cell-image-v1",core+body_digest)
record_digest=D(b"zyz-free-receipt-record-v1",body+body_digest+final_cell_digest)
expected_receipt={"schema_version":1,"frame_type":"FREE_RECEIPT","kind":"ordinary","cell_index":base_dir["index"],
 "cell_generation":cell_generation,"free_generation":free_generation,"predecessor_record_digest":predecessor.hex(),
 "prior_owner_fact_digest":prior_fact.hex(),"body_b64":base64.b64encode(body).decode(),
 "body_digest":body_digest.hex(),"final_cell_image_digest":final_cell_digest.hex(),"record_digest":record_digest.hex()}
append_ok=(physical and set(b["segments"])==set(x["segments"])=={name1,name2} and bs2==xs2 and
 bs1.get("descriptor_generation")==4 and xs1.get("descriptor_generation")==6 and
 old_used==2360==sum(frame.get("length",-1) for frame in old_frames) and
 new_used==3968==sum(frame.get("length",-1) for frame in new_frames) and
 len(append_frames)==2 and overlay.get("kind")=="overlay" and receipt.get("kind")=="free-receipt" and
 overlay.get("offset")==old_used and receipt.get("offset")==overlay.get("offset",-1)+overlay.get("length",-1) and
 receipt.get("offset",-1)+receipt.get("length",-1)==new_used and
 {k:v for k,v in xm1.items() if k not in ("committed_used_length","committed_content_sha256")}==
  {k:v for k,v in bm1.items() if k not in ("committed_used_length","committed_content_sha256")} and
 H(operation.get("root_digest")) and operation==expected_operation and
 overlay.get("payload")==expected_overlay and receipt.get("payload")==expected_receipt and
 x["root_meta"].get("last_overlay_frame_digest")==overlay.get("digest") and
 x["root_meta"].get("last_free_receipt_record_digest")==record_digest.hex() and
 x["root_meta"].get("active_segment_generation")==1 and
 x["root_meta"].get("active_segment_used_length")==new_used and
 x["root_meta"].get("active_segment_descriptor_digest")==xs1.get("descriptor_digest"))
ok=(not x["forbidden_names"] and not x["packs"] and x["lock"] is None and terminal_ok and
 digest not in x["claims"] and append_ok and
 x["root_meta"].get("pending_anchor_claim_sha256") is None and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")-1 and
 x["root_meta"].get("active_data_claims")==b["root_meta"].get("active_data_claims")-1 and
 claim_request==134479872 and audit_request==1052672 and logical_release==134479872 and
 b["root_meta"].get("owned_bytes")==168034304 and
 x["root_meta"].get("owned_bytes")==33554432==b["root_meta"].get("owned_bytes")-logical_release and
 x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+1 and
 cell.get("selected_directory") is None and cell.get("selected_recovery") is None and
 x["root_meta"].get("last_freed_subject_digest")==cell.get("subject_digest") and
 out.get("ok") is True and out.get("state")=="compacted" and out.get("error") is None and
 out.get("trigger")=="manual" and out.get("due") is True and out.get("lock_acquired") is True and
 out.get("claims_scanned")==out.get("claims_skipped")==0 and out.get("transactions_advanced")==2 and
 out.get("receipts_anchored")==1 and out.get("entries_deleted")==1 and out.get("bytes_reclaimed")==262144 and
 out.get("owned_bytes_before")==168034304 and out.get("owned_bytes_after")==33554432==x["root_meta"].get("owned_bytes"))
raise SystemExit(0 if ok else 1)
PY
    }

    for t41_anchor_phase in gc-anchor-committed ANCHOR_ACK-header-committed; do
        t41="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t41-anchor.XXXXXX")"; t38_released_fixture "$t41"
        t41_container="$(find "$t41/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t41_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t41/base.json" 2>"$t41/base.err"; t41_base_rc=$?
        t35_stop "$t41" "$t35_nonce" 'terminal-index:instance-release-committed' >"$t41/stop.out" 2>"$t41/stop.err"; t41_stop_rc=$?
        t33_oracle "$t41_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t41/terminal.json" 2>"$t41/terminal.err"; t41_terminal_rc=$?
        if t37_unavailable_ok "$(cat "$t41/release.rc")" "$t41/release.out" "$t41/release.err" \
            && [ "$t41_base_rc" -eq 0 ] && [ "$t41_stop_rc" -eq 0 ] \
            && [ ! -s "$t41/stop.out" ] && t33_diag_exact "$t41/stop.err" 'SubagentStop terminal commit pending' \
            && [ "$t41_terminal_rc" -eq 0 ] && t41_phase_ok "$t41/base.json" "$t41/terminal.json" instance-release-committed; then
            pass "T41 released claim survives committed terminal handoff after instance objects disappear"
        else
            fail "T41 released claim survives committed terminal handoff after instance objects disappear" "release_rc=$(cat "$t41/release.rc") stop_rc=$t41_stop_rc oracle_rc=$t41_terminal_rc stderr=$(tr '\n' ' ' < "$t41/stop.err")"
        fi
        t38_gc "$t41" '' >"$t41/first.out" 2>"$t41/first.err"; t41_first_rc=$?
        t33_oracle "$t41_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t41/first.json" 2>"$t41/first-oracle.err"; t41_first_oracle_rc=$?
        if [ "$t41_first_rc" -eq 3 ] && [ ! -s "$t41/first.err" ] && [ "$t41_first_oracle_rc" -eq 0 ] \
            && t38_first_ok "$t41/terminal.json" "$t41/first.json" "$t41/first.out" "$t38_digest"; then
            pass "T41 public claim receipt waits on terminal-first route with no instance carriers"
        else
            fail "T41 public claim receipt waits on terminal-first route with no instance carriers" "rc=$t41_first_rc oracle_rc=$t41_first_oracle_rc out=$(tr '\n' ' ' < "$t41/first.out")"
        fi
        case "$t41_anchor_phase" in
            gc-anchor-committed) t41_anchor_barrier="terminal-index:$t41_anchor_phase" ;;
            *) t41_anchor_barrier="catalog-claim-gc:$t41_anchor_phase" ;;
        esac
        t38_gc "$t41" "$t41_anchor_barrier" >"$t41/kill.out" 2>"$t41/kill.err"; t41_kill_rc=$?
        t33_oracle "$t41_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t41/prior.json" 2>"$t41/prior.err"; t41_prior_rc=$?
        if [ "$t41_kill_rc" -eq 86 ] && [ ! -s "$t41/kill.out" ] && [ ! -s "$t41/kill.err" ] \
            && [ "$t41_prior_rc" -eq 0 ] && t41_anchor_phase_ok "$t41/first.json" "$t41/prior.json" "$t41_anchor_phase" "$t38_digest"; then
            pass "T41 public $t41_anchor_phase crash retains exact terminal anchor prior"
        else
            fail "T41 public $t41_anchor_phase crash retains exact terminal anchor prior" "rc=$t41_kill_rc oracle_rc=$t41_prior_rc stderr=$(tr '\n' ' ' < "$t41/kill.err")"
        fi
        t41_segment_snapshot_rc=0
        cp "$t41_container/.catalog-segment.0000000000000001.v1" "$t41/prior-segment-1.v1" \
            || t41_segment_snapshot_rc=$?
        cp "$t41_container/.catalog-segment.0000000000000002.v1" "$t41/prior-segment-2.v1" \
            || t41_segment_snapshot_rc=$?
        t38_gc "$t41" '' >"$t41/resume.out" 2>"$t41/resume.err"; t41_resume_rc=$?
        t33_oracle "$t41_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t41/final.json" 2>"$t41/final.err"; t41_final_rc=$?
        if [ "$t41_segment_snapshot_rc" -eq 0 ] && [ "$t41_resume_rc" -eq 0 ] && [ ! -s "$t41/resume.err" ] && [ "$t41_final_rc" -eq 0 ] \
            && t41_anchor_final_ok "$t41/prior.json" "$t41/final.json" "$t41/resume.out" "$t38_digest" \
                "$t41/prior-segment-1.v1" "$t41/prior-segment-2.v1" \
                "$t41_container/.catalog-segment.0000000000000001.v1" "$t41_container/.catalog-segment.0000000000000002.v1"; then
            pass "T41 public resume after $t41_anchor_phase releases claim through retained terminal authority"
        else
            fail "T41 public resume after $t41_anchor_phase releases claim through retained terminal authority" "snapshot_rc=$t41_segment_snapshot_rc rc=$t41_resume_rc oracle_rc=$t41_final_rc out=$(tr '\n' ' ' < "$t41/resume.out") stderr=$(tr '\n' ' ' < "$t41/resume.err")"
        fi
        rm -rf "$t41"
    done

    # -----------------------------------------------------------------------
    # T42  Fixed-pack probes and public FINALIZED terminal handoff.
    # These fixtures start from the same real public admission as T33. Probe
    # mutations are observed in the selected audit slot and terminal rejection
    # is required both at the F latch and after carrier deletion. Finalize uses
    # its public CLI, including raw exit-86 marker ownership and terminal-cell
    # idempotency after the instance packs no longer exist.
    # -----------------------------------------------------------------------
    t42_probe_create_ok() { # base after output probe-id
        python3 - "$1" "$2" "$3" "$4" "$t33_key" "$t33_raw" "$t33_role" <<'PY'
import hashlib,json,os,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); out=json.load(open(sys.argv[3])); probe,key,raw,role=sys.argv[4:]
before=b["packs"]["audit"]; after=x["packs"]["audit"]; record=after["records"].get("PROBE_STATE",{}).get("payload",{})
stable_top=("root_generation","root_digest","root_meta","group_generation","group_digest","group_meta",
 "subject_digest","subject_dirs","subject_recoveries","selected_cell","cell_history","lock","expected_event",
 "expected_reservation_digest","expected_request_bytes","segments","claims","claim_cells","terminal","forbidden_names")
ok=(all(x.get(name)==b.get(name) for name in stable_top) and x["packs"]["work"]==b["packs"]["work"] and
 after["header_generation"]==before["header_generation"]+1 and after["header_predecessor"]==before["header_digest"] and
 set(after["selected"])==set(before["selected"])|{"PROBE_STATE"} and
 all(after["selected"].get(name)==before["selected"].get(name) for name in before["selected"]) and
 all(after.get(name)==before.get(name) for name in ("dev","ino","size","blocks","allocated","nlink","regular")) and
 record.get("schema_version")==2 and record.get("instance_key")==key and
 record.get("instance_digest")==hashlib.sha256(os.fsencode(raw)).hexdigest() and record.get("canonical_role")==role and
 record.get("state")=="pending" and record.get("probe_id")==probe and
 record.get("probe_id_sha256")==hashlib.sha256(probe.encode()).hexdigest() and record.get("history")==[] and
 record.get("deadline_epoch")==record.get("created_epoch")+60 and record.get("inflight_state")=="unknown" and record.get("inflight_count")==0 and
 out.get("ok") is True and out.get("state")=="pending" and out.get("error") is None and
 out.get("probe_id")==probe and out.get("probe_id_sha256")==record.get("probe_id_sha256") and
 out.get("deadline_epoch")==record.get("deadline_epoch") and out.get("creation_enabled") is True)
raise SystemExit(0 if ok else 1)
PY
    }
    t42_probe_update_ok() { # pending after output operation reason
        python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import base64,hashlib,json,os,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); out=json.load(open(sys.argv[3])); operation,reason=sys.argv[4:]
before=b["packs"]["audit"]; after=x["packs"]["audit"]; old=before["records"]["PROBE_STATE"]["payload"]; new=after["records"]["PROBE_STATE"]["payload"]
expected="acked" if operation=="probe-ack" else "cancelled"; reason_bytes=os.fsencode(reason); rh=hashlib.sha256(reason_bytes).hexdigest()
history=new.get("history",[]); item=history[0] if len(history)==1 else {}
stable_top=("root_generation","root_digest","root_meta","group_generation","group_digest","group_meta",
 "subject_digest","subject_dirs","subject_recoveries","selected_cell","cell_history","lock","expected_event",
 "expected_reservation_digest","expected_request_bytes","segments","claims","claim_cells","terminal","forbidden_names")
ok=(all(x.get(name)==b.get(name) for name in stable_top) and x["packs"]["work"]==b["packs"]["work"] and
 after["header_generation"]==before["header_generation"]+1 and after["header_predecessor"]==before["header_digest"] and
 set(after["selected"])==set(before["selected"]) and
 all(after["selected"].get(name)==before["selected"].get(name) for name in before["selected"] if name!="PROBE_STATE") and
 all(after.get(name)==before.get(name) for name in ("dev","ino","size","blocks","allocated","nlink","regular")) and
 new.get("state")==expected and new.get("probe_id")==old.get("probe_id") and new.get("probe_id_sha256")==old.get("probe_id_sha256") and
 new.get("completed_epoch")==item.get("epoch") and new.get("reason_b64")==base64.b64encode(reason_bytes).decode() and new.get("reason_sha256")==rh and
 item.get("probe_id_sha256")==old.get("probe_id_sha256") and item.get("terminal_kind")==expected and item.get("reason_sha256")==rh and
 item.get("prior_record_sha256")==hashlib.sha256(json.dumps(old,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()).hexdigest() and
 out.get("ok") is True and out.get("state")==expected and out.get("error") is None and
 out.get("probe_id")==old.get("probe_id") and out.get("probe_id_sha256")==old.get("probe_id_sha256") and out.get("trusted") is True)
raise SystemExit(0 if ok else 1)
PY
    }
    t42_terminal_probe_status_ok() { # output kind handoff release
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); kind,handoff,release=sys.argv[2:]
ok=(x.get("ok") is True and x.get("state")=="terminal" and x.get("error") is None and
 x.get("trusted") is True and x.get("tracking_capability")=="armed" and x.get("terminal_kind")==kind and
 x.get("handoff_state")==handoff and x.get("instance_release_state")==release)
raise SystemExit(0 if ok else 1)
PY
    }
    t42_error_ok() { # output command code
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); command,code=sys.argv[2:]
raise SystemExit(0 if x.get("ok") is False and x.get("state")=="error" and x.get("command")==command and (x.get("error") or {}).get("code")==code else 1)
PY
    }

    for t42_operation in probe-ack probe-cancel; do
        t42="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t42-probe.XXXXXX")"; t33_fixture "$t42"
        t33_start "$t42" "$t33_nonce_a" '' >"$t42/start.out" 2>"$t42/start.err"
        t42_container="$(find "$t42/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/base.json" 2>"$t42/base.err"
        t42_probe='probe1-13579bdf2468ace013579bdf2468ace0'
        (cd "$t42" && ZYZ_RECONNECT_ACK_SEC=60 ZYZ_TEST_RANDOM_HEX_SEQUENCE=13579bdf2468ace013579bdf2468ace0 \
            bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" probe-create "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t33_role") >"$t42/create.out" 2>"$t42/create.err"; t42_create_rc=$?
        t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/pending.json" 2>"$t42/pending.err"; t42_pending_rc=$?
        if [ "$t42_create_rc" -eq 0 ] && [ ! -s "$t42/create.err" ] && [ "$t42_pending_rc" -eq 0 ] \
            && t42_probe_create_ok "$t42/base.json" "$t42/pending.json" "$t42/create.out" "$t42_probe"; then
            pass "T42 public probe-create commits one exact fixed-pack pending challenge"
        else
            fail "T42 public probe-create commits one exact fixed-pack pending challenge" "rc=$t42_create_rc oracle_rc=$t42_pending_rc out=$(tr '\n' ' ' < "$t42/create.out")"
        fi
        t42_wrong='probe1-02468ace13579bdf02468ace13579bdf'
        if [ "$t42_operation" = probe-ack ]; then
            (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" probe-ack "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t42_wrong") >"$t42/wrong.out" 2>"$t42/wrong.err"; t42_wrong_rc=$?
        else
            (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" probe-cancel "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t42_wrong" operator-cancel) >"$t42/wrong.out" 2>"$t42/wrong.err"; t42_wrong_rc=$?
        fi
        t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/wrong.json" 2>"$t42/wrong-oracle.err"
        if [ "$t42_wrong_rc" -eq 4 ] && [ ! -s "$t42/wrong.err" ] && cmp -s "$t42/pending.json" "$t42/wrong.json" \
            && t42_error_ok "$t42/wrong.out" "$t42_operation" probe-mismatch; then
            pass "T42 public $t42_operation rejects a different valid id without mutation"
        else
            fail "T42 public $t42_operation rejects a different valid id without mutation" "rc=$t42_wrong_rc out=$(tr '\n' ' ' < "$t42/wrong.out")"
        fi
        if [ "$t42_operation" = probe-ack ]; then t42_reason=acknowledged; else t42_reason=operator-cancel; fi
        if [ "$t42_operation" = probe-ack ]; then
            (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" probe-ack "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t42_probe") >"$t42/update.out" 2>"$t42/update.err"; t42_update_rc=$?
        else
            (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" probe-cancel "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t42_probe" "$t42_reason") >"$t42/update.out" 2>"$t42/update.err"; t42_update_rc=$?
        fi
        t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/final.json" 2>"$t42/final.err"; t42_final_rc=$?
        if [ "$t42_update_rc" -eq 0 ] && [ ! -s "$t42/update.err" ] && [ "$t42_final_rc" -eq 0 ] \
            && t42_probe_update_ok "$t42/pending.json" "$t42/final.json" "$t42/update.out" "$t42_operation" "$t42_reason"; then
            pass "T42 public $t42_operation advances only the exact fixed probe record"
        else
            fail "T42 public $t42_operation advances only the exact fixed probe record" "rc=$t42_update_rc oracle_rc=$t42_final_rc out=$(tr '\n' ' ' < "$t42/update.out")"
        fi
        (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" probe-status "$t42/.zyz-worker/tasks/task" "$t33_raw") >"$t42/status.out" 2>"$t42/status.err"; t42_status_rc=$?
        t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/status.json" 2>"$t42/status-oracle.err"
        if [ "$t42_operation" = probe-ack ]; then t42_expected_state=acked; else t42_expected_state=cancelled; fi
        if [ "$t42_status_rc" -eq 0 ] && [ ! -s "$t42/status.err" ] && cmp -s "$t42/final.json" "$t42/status.json" \
            && python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));raise SystemExit(0 if x.get("state")==sys.argv[2] and x.get("trusted") is True and x.get("probe_id")==sys.argv[3] else 1)' "$t42/status.out" "$t42_expected_state" "$t42_probe"; then
            pass "T42 public probe-status reads the fixed $t42_operation result without mutation"
        else
            fail "T42 public probe-status reads the fixed $t42_operation result without mutation" "rc=$t42_status_rc out=$(tr '\n' ' ' < "$t42/status.out")"
        fi
        rm -rf "$t42"
    done

    t42="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t42-terminal-probe.XXXXXX")"; t33_fixture "$t42"
    t33_start "$t42" "$t33_nonce_a" '' >/dev/null 2>"$t42/start.err"
    t42_container="$(find "$t42/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t35_stop "$t42" "$t35_nonce" 'terminal-handoff:freeze-latch-committed' >"$t42/stop.out" 2>"$t42/stop.err"
    t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/frozen.json" 2>"$t42/frozen.err"
    (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" probe-status "$t42/.zyz-worker/tasks/task" "$t33_raw") >"$t42/status.out" 2>"$t42/status.err"; t42_status_rc=$?
    (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" probe-create "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t33_role") >"$t42/probe-create.out" 2>"$t42/probe-create.err"; t42_create_rc=$?
    (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" probe-ack "$t42/.zyz-worker/tasks/task" "$t33_raw" probe1-02468ace13579bdf02468ace13579bdf) >"$t42/probe-ack.out" 2>"$t42/probe-ack.err"; t42_ack_rc=$?
    (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" probe-cancel "$t42/.zyz-worker/tasks/task" "$t33_raw" probe1-02468ace13579bdf02468ace13579bdf terminal) >"$t42/probe-cancel.out" 2>"$t42/probe-cancel.err"; t42_cancel_rc=$?
    t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/after.json" 2>"$t42/after.err"
    if [ "$t42_status_rc" -eq 0 ] && [ ! -s "$t42/status.err" ] && t42_terminal_probe_status_ok "$t42/status.out" done freeze-latched not-started \
        && [ "$t42_create_rc" -eq 4 ] && [ "$t42_ack_rc" -eq 4 ] && [ "$t42_cancel_rc" -eq 4 ] \
        && [ ! -s "$t42/probe-create.err" ] && [ ! -s "$t42/probe-ack.err" ] && [ ! -s "$t42/probe-cancel.err" ] \
        && t42_error_ok "$t42/probe-create.out" probe-create terminal && t42_error_ok "$t42/probe-ack.out" probe-ack terminal \
        && t42_error_ok "$t42/probe-cancel.out" probe-cancel terminal && cmp -s "$t42/frozen.json" "$t42/after.json"; then
        pass "T42 probe status is terminal-first at F and all probe mutations fail without carrier changes"
    else
        fail "T42 probe status is terminal-first at F and all probe mutations fail without carrier changes" "status_rc=$t42_status_rc create_rc=$t42_create_rc ack_rc=$t42_ack_rc cancel_rc=$t42_cancel_rc"
    fi
    rm -rf "$t42"

    # Observation ceiling: this executable source guard proves the two terminal
    # lookups bracket the carrier-missing branch.  It does not schedule the race;
    # a runtime fault/interleaving seam is the layer needed to prove that timing.
    if python3 - hooks/scripts/runtime_state.py <<'PY'
import sys
src=open(sys.argv[1]).read(); body=src[src.index("def status_result"):src.index("def _instance_commit_start")]
first=body.find("terminal_cell = _terminal_lookup(container, key)")
missing=body.find("except FileNotFoundError:")
retry=body.find("terminal_cell = _terminal_lookup(container, key)",missing)
reenter=body.find("return status_result(task, raw_id, env)",retry)
raise SystemExit(0 if 0<=first<missing<retry<reenter else 1)
PY
    then
        pass "T42 probe-status retries terminal authority after carrier-missing lookup race"
    else
        fail "T42 probe-status retries terminal authority after carrier-missing lookup race"
    fi

    t42_reason='confirmed API failure'
    t42_replacement='replacement/agent'
    t42_reservation_nonce='abcdef0123456789abcdef0123456789'
    t42_finalize_marker_ok() { # start-oracle marker-oracle
        python3 - "$1" "$2" "$t42_reason" "$t42_replacement" "$t33_key" "$t33_raw" "$t33_role" <<'PY'
import base64,hashlib,json,os,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); reason,replacement,key,raw,role=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
audit=x["packs"]["audit"]; work=x["packs"]["work"]; ba=b["packs"]["audit"]; bw=b["packs"]["work"]
marker=audit["records"].get("FINALIZED",{}).get("payload",{}); journal=work["records"].get("TRANSITION_JOURNAL",{}).get("payload",{})
reason_bytes=os.fsencode(reason); replacement_bytes=os.fsencode(replacement)
stable_top=("root_generation","root_digest","root_meta","group_generation","group_digest","group_meta",
 "subject_digest","subject_dirs","subject_recoveries","selected_cell","cell_history","lock","expected_event",
 "expected_reservation_digest","expected_request_bytes","segments","claims","claim_cells","terminal","forbidden_names")
ok=(all(x.get(name)==b.get(name) for name in stable_top) and
 audit["header_generation"]==ba["header_generation"]+1 and audit["header_predecessor"]==ba["header_digest"] and
 work["header_generation"]==bw["header_generation"]+1 and work["header_predecessor"]==bw["header_digest"] and
 set(audit["selected"])==set(ba["selected"])|{"FINALIZED"} and
 all(audit["selected"].get(name)==ba["selected"].get(name) for name in ba["selected"]) and
 set(work["selected"])==set(bw["selected"])|{"TRANSITION_JOURNAL"} and
 all(work["selected"].get(name)==bw["selected"].get(name) for name in bw["selected"] if name!="TRANSITION_JOURNAL") and
 all(audit.get(name)==ba.get(name) and work.get(name)==bw.get(name) for name in ("dev","ino","size","blocks","allocated","nlink","regular")) and
 marker.get("schema_version")==1 and marker.get("instance_key")==key and marker.get("agent_id_sha256")==hashlib.sha256(os.fsencode(raw)).hexdigest() and
 marker.get("canonical_role")==role and marker.get("terminal_kind")=="finalized" and
 marker.get("reason_b64")==base64.b64encode(reason_bytes).decode() and marker.get("reason_sha256")==hashlib.sha256(reason_bytes).hexdigest() and
 marker.get("replacement_agent_id_sha256")==hashlib.sha256(replacement_bytes).hexdigest() and
 marker.get("cleanup_state")=="pending" and marker.get("cleanup_pending") is True and
 journal.get("txn_type")=="finalize" and journal.get("phase")=="prepared" and journal.get("terminal_record_digest")==JD(marker) and
 "TERMINAL_HANDOFF" not in work["records"])
raise SystemExit(0 if ok else 1)
PY
    }
    t42_finalize_frozen_ok() { # start-oracle frozen-oracle
        python3 - "$1" "$2" "$t42_reason" "$t42_replacement" "$t42_reservation_nonce" "$t33_key" "$t33_raw" "$t33_role" <<'PY'
import base64,hashlib,json,os,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); reason,replacement,nonce,key,raw,role=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
cells=x["terminal"]["cells"]
if len(cells)!=1: raise SystemExit(1)
cell=cells[0]; terminal=cell["metadata"]; audit=x["packs"]["audit"]; work=x["packs"]["work"]
marker=audit["records"].get("FINALIZED",{}).get("payload",{}); journal=work["records"].get("TRANSITION_JOURNAL",{}).get("payload",{}); latch=work["records"].get("TERMINAL_HANDOFF",{}).get("payload",{})
expected_index=int.from_bytes(hashlib.sha256(key.encode("ascii")).digest()[:8],"big")%256
reason_bytes=os.fsencode(reason); replacement_bytes=os.fsencode(replacement)
frozen=latch.get("frozen_headers",{}); objects=latch.get("instance_objects",{})
def object_ok(expected,actual,logical):
 name=key+{"audit":".audit-pack.v1","work":".work-pack.v1","lock":".lock.v1"}[logical]
 shape={field:expected.get(field) for field in ("dev","ino","size","mount_id")}
 return (expected.get("basename")==name and isinstance(shape["mount_id"],str) and
  expected.get("digest")==hashlib.sha256(J(shape)).hexdigest() and actual is not None and
  all(expected.get(field)==actual.get(field) for field in ("dev","ino","size")) and
  actual.get("regular") is True and actual.get("nlink")==1)
ok=(not x["forbidden_names"] and cell["cell_index"]==expected_index and cell["generation"]==2 and
 terminal.get("state")=="reserved" and terminal.get("instance_key")==key and
 terminal.get("agent_id_sha256")==hashlib.sha256(os.fsencode(raw)).hexdigest() and terminal.get("canonical_role")==role and
 terminal.get("reservation_nonce")==nonce and terminal.get("prior_cell_generation")==1 and
 terminal.get("catalog_reservation_digest")==b["expected_reservation_digest"] and terminal.get("request_bytes")==b["expected_request_bytes"] and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes") and x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims") and
 x["selected_cell"]==b["selected_cell"] and x["cell_history"]==b["cell_history"] and x["segments"]==b["segments"] and
 marker.get("terminal_kind")=="finalized" and marker.get("instance_key")==key and marker.get("agent_id_sha256")==hashlib.sha256(os.fsencode(raw)).hexdigest() and
 marker.get("canonical_role")==role and marker.get("reason_b64")==base64.b64encode(reason_bytes).decode() and
 marker.get("reason_sha256")==hashlib.sha256(reason_bytes).hexdigest() and
 marker.get("replacement_agent_id_sha256")==hashlib.sha256(replacement_bytes).hexdigest() and
 journal.get("txn_type")=="finalize" and journal.get("phase")=="committed-terminal" and journal.get("terminal_record_digest")==JD(marker) and
 "START" not in audit["selected"] and "HEARTBEAT" not in audit["selected"] and "PROBE_STATE" not in audit["selected"] and
 "INFLIGHT" not in work["selected"] and latch.get("state")=="freeze-latch-committed" and latch.get("instance_key")==key and
 latch.get("reservation_nonce")==nonce and latch.get("terminal_record_digest")==JD(marker) and
 latch.get("catalog_reservation_digest")==b["expected_reservation_digest"] and
 frozen.get("audit")=={"generation":audit["header_generation"],"digest":audit["header_digest"]} and
 frozen.get("work_expected_generation")==work["header_generation"] and
 frozen.get("work_prior",{}).get("generation")==work["header_generation"]-1 and
 frozen.get("work_prior",{}).get("digest")==work["header_predecessor"] and set(objects)=={"audit","work","lock"} and
 object_ok(objects["audit"],audit,"audit") and object_ok(objects["work"],work,"work") and object_ok(objects["lock"],x["lock"],"lock"))
raise SystemExit(0 if ok else 1)
PY
    }
    t42_finalize_ok() { # start-oracle final-oracle output idempotent [key raw role]
        python3 - "$1" "$2" "$3" "$4" "$t42_reason" "$t42_replacement" "$t42_reservation_nonce" "${5:-$t33_key}" "${6:-$t33_raw}" "${7:-$t33_role}" <<'PY'
import base64,hashlib,json,os,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); out=json.load(open(sys.argv[3])); idem=sys.argv[4]=="true"; reason,replacement,nonce,key,raw,role=sys.argv[5:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
cells=x["terminal"]["cells"]
if len(cells)!=1: raise SystemExit(1)
cell=cells[0]; terminal=cell["metadata"]; marker=terminal.get("terminal_record",{}); release=terminal.get("instance_release",{}); request=b["expected_request_bytes"]
reason_bytes=os.fsencode(reason); replacement_bytes=os.fsencode(replacement)
expected_index=int.from_bytes(hashlib.sha256(key.encode("ascii")).digest()[:8],"big")%256
latch=terminal.get("handoff_latch",{}); frozen=terminal.get("frozen_headers",{}); objects=terminal.get("instance_objects",{})
def object_ok(expected,actual,logical):
 name=key+{"audit":".audit-pack.v1","work":".work-pack.v1","lock":".lock.v1"}[logical]
 shape={field:expected.get(field) for field in ("dev","ino","size","mount_id")}
 return (expected.get("basename")==name and isinstance(shape["mount_id"],str) and
  expected.get("digest")==hashlib.sha256(J(shape)).hexdigest() and
  all(expected.get(field)==actual.get(field) for field in ("dev","ino","size")) and
  actual.get("regular") is True and actual.get("nlink")==1)
ok=(not x["forbidden_names"] and not x["packs"] and x["lock"] is None and
 cell["cell_index"]==expected_index and cell["generation"]==8 and terminal.get("state")=="handoff-accepted" and
 terminal.get("instance_key")==key and terminal.get("agent_id_sha256")==hashlib.sha256(os.fsencode(raw)).hexdigest() and
 terminal.get("canonical_role")==role and terminal.get("reservation_nonce")==nonce and terminal.get("prior_cell_generation")==1 and
 terminal.get("catalog_reservation_digest")==b["expected_reservation_digest"] and terminal.get("request_bytes")==request and terminal.get("gc_anchor") is None and
 terminal.get("terminal_record_digest")==JD(marker) and terminal.get("handoff_latch",{}).get("terminal_record_digest")==JD(marker) and
 terminal.get("handoff_latch_digest")==JD(latch) and latch.get("state")=="freeze-latch-committed" and latch.get("instance_key")==key and
 latch.get("reservation_nonce")==nonce and latch.get("terminal_record_digest")==JD(marker) and
 latch.get("catalog_reservation_digest")==b["expected_reservation_digest"] and
 latch.get("frozen_headers")=={name:frozen[name] for name in ("audit","work_prior","work_expected_generation")} and
 latch.get("instance_objects")==objects and set(objects)=={"audit","work","lock"} and
 object_ok(objects["audit"],b["packs"]["audit"],"audit") and object_ok(objects["work"],b["packs"]["work"],"work") and object_ok(objects["lock"],b["lock"],"lock") and
 marker.get("terminal_kind")=="finalized" and marker.get("instance_key")==key and marker.get("agent_id_sha256")==hashlib.sha256(os.fsencode(raw)).hexdigest() and marker.get("canonical_role")==role and
 marker.get("reason_b64")==base64.b64encode(reason_bytes).decode() and marker.get("reason_sha256")==hashlib.sha256(reason_bytes).hexdigest() and
 marker.get("replacement_agent_id_sha256")==hashlib.sha256(replacement_bytes).hexdigest() and marker.get("cleanup_state")=="pending" and marker.get("cleanup_pending") is True and
 release.get("phase")=="committed" and release.get("free_receipt_record_digest")==x["root_meta"].get("last_free_receipt_record_digest") and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")-request and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")-1 and
 x["root_meta"].get("active_data_claims")==b["root_meta"].get("active_data_claims") and
 x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+1 and x["selected_cell"] is None and
 out.get("ok") is True and out.get("state")=="terminal" and out.get("error") is None and out.get("terminal_kind")=="finalized" and
 out.get("terminal_epoch")==marker.get("terminal_epoch") and out.get("idempotent") is idem and out.get("trusted") is True and
 out.get("cleanup_state")==marker.get("cleanup_state") and out.get("cleanup_pending")==marker.get("cleanup_pending"))
raise SystemExit(0 if ok else 1)
PY
    }

    t42="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t42-finalize.XXXXXX")"; t33_fixture "$t42"
    t33_start "$t42" "$t33_nonce_a" '' >/dev/null 2>"$t42/start.err"
    t42_container="$(find "$t42/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/base.json" 2>"$t42/base.err"
    (cd "$t42" && ZYZ_TEST_RANDOM_HEX_SEQUENCE="$t42_reservation_nonce" bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" finalize "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t33_role" "$t42_reason" "$t42_replacement") >"$t42/first.out" 2>"$t42/first.err"; t42_first_rc=$?
    t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/first.json" 2>"$t42/first-oracle.err"; t42_first_oracle_rc=$?
    if [ "$t42_first_rc" -eq 0 ] && [ ! -s "$t42/first.err" ] && [ "$t42_first_oracle_rc" -eq 0 ] \
        && t42_finalize_ok "$t42/base.json" "$t42/first.json" "$t42/first.out" false; then
        pass "T42 public finalize reaches one committed retained FINALIZED authority"
    else
        fail "T42 public finalize reaches one committed retained FINALIZED authority" "rc=$t42_first_rc oracle_rc=$t42_first_oracle_rc out=$(tr '\n' ' ' < "$t42/first.out")"
    fi
    (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" finalize "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t33_role" "$t42_reason" "$t42_replacement") >"$t42/repeat.out" 2>"$t42/repeat.err"; t42_repeat_rc=$?
    t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/repeat.json" 2>"$t42/repeat-oracle.err"
    if [ "$t42_repeat_rc" -eq 0 ] && [ ! -s "$t42/repeat.err" ] && cmp -s "$t42/first.json" "$t42/repeat.json" \
        && t42_finalize_ok "$t42/base.json" "$t42/repeat.json" "$t42/repeat.out" true; then
        pass "T42 same finalize request is byte-idempotent after carrier deletion"
    else
        fail "T42 same finalize request is byte-idempotent after carrier deletion" "rc=$t42_repeat_rc out=$(tr '\n' ' ' < "$t42/repeat.out")"
    fi
    (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" finalize "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t33_role" 'different reason' "$t42_replacement") >"$t42/reason.out" 2>"$t42/reason.err"; t42_reason_rc=$?
    (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" finalize "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t33_role" "$t42_reason" 'different/replacement') >"$t42/replacement.out" 2>"$t42/replacement.err"; t42_replacement_rc=$?
    t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/conflict.json" 2>"$t42/conflict.err"
    if [ "$t42_reason_rc" -eq 4 ] && [ "$t42_replacement_rc" -eq 4 ] && [ ! -s "$t42/reason.err" ] && [ ! -s "$t42/replacement.err" ] \
        && t42_error_ok "$t42/reason.out" finalize already-terminal && t42_error_ok "$t42/replacement.out" finalize already-terminal \
        && cmp -s "$t42/first.json" "$t42/conflict.json"; then
        pass "T42 changed finalize reason or replacement is rejected after handoff without mutation"
    else
        fail "T42 changed finalize reason or replacement is rejected after handoff without mutation" "reason_rc=$t42_reason_rc replacement_rc=$t42_replacement_rc"
    fi
    rm -rf "$t42"

    t42="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t42-finalize-replay.XXXXXX")"; t33_fixture "$t42"
    t33_start "$t42" "$t33_nonce_a" '' >/dev/null 2>"$t42/start.err"
    t42_container="$(find "$t42/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/base.json" 2>"$t42/base.err"
    (cd "$t42" && ZYZ_TEST_RANDOM_HEX_SEQUENCE="$t42_reservation_nonce" ZYZ_TEST_TRANSITION_STOP_AFTER='terminal-handoff:finalized-marker-committed' \
        bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" finalize "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t33_role" "$t42_reason" "$t42_replacement") >"$t42/marker.out" 2>"$t42/marker.err"; t42_marker_rc=$?
    t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/marker.json" 2>"$t42/marker-oracle.err"; t42_marker_oracle_rc=$?
    if [ "$t42_marker_rc" -eq 86 ] && [ ! -s "$t42/marker.out" ] && [ ! -s "$t42/marker.err" ] && [ "$t42_marker_oracle_rc" -eq 0 ] \
        && t42_finalize_marker_ok "$t42/base.json" "$t42/marker.json"; then
        pass "T42 public finalized-marker crash exposes exact fixed FINALIZED and prepared journal"
    else
        fail "T42 public finalized-marker crash exposes exact fixed FINALIZED and prepared journal" "rc=$t42_marker_rc oracle_rc=$t42_marker_oracle_rc"
    fi
    (cd "$t42" && ZYZ_TEST_RANDOM_HEX_SEQUENCE="$t42_reservation_nonce" ZYZ_TEST_TRANSITION_STOP_AFTER='terminal-handoff:freeze-latch-committed' \
        bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" finalize "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t33_role" "$t42_reason" "$t42_replacement") >"$t42/freeze.out" 2>"$t42/freeze.err"; t42_freeze_rc=$?
    t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/freeze.json" 2>"$t42/freeze-oracle.err"; t42_freeze_oracle_rc=$?
    if [ "$t42_freeze_rc" -eq 86 ] && [ ! -s "$t42/freeze.out" ] && [ ! -s "$t42/freeze.err" ] && [ "$t42_freeze_oracle_rc" -eq 0 ] \
        && t42_finalize_frozen_ok "$t42/base.json" "$t42/freeze.json"; then
        pass "T42 same finalize replay completes journal retirement before F latch"
    else
        fail "T42 same finalize replay completes journal retirement before F latch" "rc=$t42_freeze_rc oracle_rc=$t42_freeze_oracle_rc"
    fi
    (cd "$t42" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" finalize "$t42/.zyz-worker/tasks/task" "$t33_raw" "$t33_role" "$t42_reason" "$t42_replacement") >"$t42/final.out" 2>"$t42/final.err"; t42_final_rc=$?
    t33_oracle "$t42_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t42/final.json" 2>"$t42/final-oracle.err"; t42_final_oracle_rc=$?
    if [ "$t42_final_rc" -eq 0 ] && [ ! -s "$t42/final.err" ] && [ "$t42_final_oracle_rc" -eq 0 ] \
        && t42_finalize_ok "$t42/base.json" "$t42/final.json" "$t42/final.out" true; then
        pass "T42 public finalize resumes marker and F crashes through committed external release"
    else
        fail "T42 public finalize resumes marker and F crashes through committed external release" "rc=$t42_final_rc oracle_rc=$t42_final_oracle_rc out=$(tr '\n' ' ' < "$t42/final.out")"
    fi
    rm -rf "$t42"

    # -----------------------------------------------------------------------
    # T43  Durable late-clean plus bounded terminal retention/eviction.
    # Late clean starts only from a real public FINALIZED generation-8 cell;
    # public SubagentStop and manual gc-step are the only transition drivers.
    # Capacity fixtures independently encode valid ZYZTCEL1 successors into a
    # disposable genesis pack, then use public SubagentStart as the admission
    # gate.  No production parser or private transition helper is imported.
    # -----------------------------------------------------------------------
    t43_late_phase_ok() { # finalized-base observed phase
        python3 - "$1" "$2" "$3" "$t35_nonce" "$t33_raw" "$t33_role" "$t33_key" <<'PY'
import hashlib,json,os,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); phase,nonce,raw,role,key=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
bcells=b["terminal"]["cells"]; xcells=x["terminal"]["cells"]
if len(bcells)!=1 or len(xcells)!=1: raise SystemExit(1)
bc=bcells[0]; xc=xcells[0]; bm=bc["metadata"]; xm=xc["metadata"]
late=xm.get("late_clean",{}); done=late.get("done_record",{})
digest=hashlib.sha256(os.fsencode(raw)).hexdigest()
record=bytes([1,2])+len(role.encode()).to_bytes(2,"big")+role.encode()+len(digest.encode()).to_bytes(2,"big")+digest.encode()+len(nonce.encode()).to_bytes(2,"big")+nonce.encode()
event={"event_token":"evt1-"+hashlib.sha256(record).hexdigest(),"nonce_sha256":hashlib.sha256(bytes.fromhex(nonce)).hexdigest(),"event_record_digest":hashlib.sha256(record).hexdigest()}
generation={"prepared":9,"will-done":10,"did-done":11,"committed":12}[phase]
stable_top=("root_generation","root_digest","root_meta","group_generation","group_digest","group_meta",
 "subject_digest","subject_dirs","subject_recoveries","selected_cell","cell_history","packs","lock",
 "expected_event","expected_reservation_digest","expected_request_bytes","segments","claims","claim_cells","forbidden_names")
ok=(all(x.get(name)==b.get(name) for name in stable_top) and xc["cell_index"]==bc["cell_index"] and
 xc["generation"]==generation and (phase!="prepared" or xc["predecessor"]==bc["digest"]) and
 bm.get("terminal_record",{}).get("terminal_kind")=="finalized" and xm.get("terminal_record")==bm.get("terminal_record") and
 {k:v for k,v in xm.items() if k not in ("late_clean","last_event_epoch","retention_epoch")}==
 {k:v for k,v in bm.items() if k not in ("late_clean","last_event_epoch","retention_epoch")} and
 late.get("schema_version")==1 and late.get("phase")==phase and late.get("done_record_digest")==JD(done) and
 done.get("schema_version")==1 and done.get("instance_key")==key and done.get("agent_id_sha256")==digest and
 done.get("canonical_role")==role and done.get("terminal_kind")=="done" and
 all(done.get(name)==event[name] for name in event) and isinstance(done.get("terminal_epoch"),int) and
 xm.get("last_event_epoch")==max(bm.get("last_event_epoch"),done["terminal_epoch"]) and
 xm.get("retention_epoch")==max(bm.get("retention_epoch"),done["terminal_epoch"]+60))
raise SystemExit(0 if ok else 1)
PY
    }
    t43_late_gc_ok() { # output base phase
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
out=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); phase=sys.argv[3]
fresh=phase!="committed"
ok=(out.get("ok") is True and out.get("state")=="idle" and out.get("error") is None and
 out.get("trigger")=="manual" and out.get("due") is True and out.get("lock_acquired") is True and
 out.get("claims_scanned")==out.get("claims_skipped")==out.get("receipts_anchored")==0 and
 out.get("transactions_advanced")==int(fresh) and out.get("entries_deleted")==0 and out.get("bytes_reclaimed")==0 and
 out.get("owned_bytes_before")==out.get("owned_bytes_after")==b["root_meta"].get("owned_bytes"))
raise SystemExit(0 if ok else 1)
PY
    }
    t43_gc() { # sandbox barrier
        (
            cd "$1" || exit 1
            ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 ZYZ_RUNNING_NO_ACK_GRACE_SEC=60 \
            ZYZ_TEST_TRANSITION_STOP_AFTER="$2" \
                bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
                gc-step "$1/.zyz-worker/tasks/task" manual
        )
    }

    for t43_late_phase in prepared will-done did-done committed; do
        t43="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t43-late.XXXXXX")"; t33_fixture "$t43"
        t33_start "$t43" "$t33_nonce_a" '' >"$t43/start.out" 2>"$t43/start.err"
        t43_container="$(find "$t43/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        (cd "$t43" && ZYZ_TEST_RANDOM_HEX_SEQUENCE="$t42_reservation_nonce" \
            bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" finalize "$t43/.zyz-worker/tasks/task" "$t33_raw" "$t33_role" "$t42_reason" "$t42_replacement") >"$t43/finalize.out" 2>"$t43/finalize.err"; t43_finalize_rc=$?
        t33_oracle "$t43_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t43/base.json" 2>"$t43/base.err"; t43_base_rc=$?
        ZYZ_RUNNING_NO_ACK_GRACE_SEC=60 t35_stop "$t43" "$t35_nonce" "terminal-index:late-clean-$t43_late_phase" >"$t43/kill.out" 2>"$t43/kill.err"; t43_kill_rc=$?
        t33_oracle "$t43_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t43/prior.json" 2>"$t43/prior.err"; t43_prior_rc=$?
        if [ "$t43_finalize_rc" -eq 0 ] && [ ! -s "$t43/finalize.err" ] && [ "$t43_base_rc" -eq 0 ] \
            && [ "$t43_kill_rc" -eq 0 ] && [ ! -s "$t43/kill.out" ] \
            && t33_diag_exact "$t43/kill.err" 'SubagentStop terminal commit pending' \
            && [ "$t43_prior_rc" -eq 0 ] && t43_late_phase_ok "$t43/base.json" "$t43/prior.json" "$t43_late_phase"; then
            pass "T43 public late-clean $t43_late_phase crash preserves FINALIZED and exact terminal journal"
        else
            fail "T43 public late-clean $t43_late_phase crash preserves FINALIZED and exact terminal journal" "finalize_rc=$t43_finalize_rc kill_rc=$t43_kill_rc oracle_rc=$t43_prior_rc stderr=$(tr '\n' ' ' < "$t43/kill.err")"
        fi
        t43_gc "$t43" '' >"$t43/resume.out" 2>"$t43/resume.err"; t43_resume_rc=$?
        t33_oracle "$t43_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t43/final.json" 2>"$t43/final.err"; t43_final_rc=$?
        if [ "$t43_resume_rc" -eq 0 ] && [ ! -s "$t43/resume.err" ] && [ "$t43_final_rc" -eq 0 ] \
            && t43_late_phase_ok "$t43/base.json" "$t43/final.json" committed \
            && t43_late_gc_ok "$t43/resume.out" "$t43/base.json" "$t43_late_phase"; then
            pass "T43 public gc-step resumes late-clean $t43_late_phase without carrier resurrection"
        else
            fail "T43 public gc-step resumes late-clean $t43_late_phase without carrier resurrection" "rc=$t43_resume_rc oracle_rc=$t43_final_rc out=$(tr '\n' ' ' < "$t43/resume.out")"
        fi
        ZYZ_RUNNING_NO_ACK_GRACE_SEC=60 t35_stop "$t43" "$t35_nonce" '' >"$t43/repeat.out" 2>"$t43/repeat.err"; t43_repeat_rc=$?
        t33_oracle "$t43_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t43/repeat.json" 2>"$t43/repeat-oracle.err"
        if [ "$t43_repeat_rc" -eq 0 ] && [ ! -s "$t43/repeat.out" ] && [ ! -s "$t43/repeat.err" ] \
            && cmp -s "$t43/final.json" "$t43/repeat.json"; then
            pass "T43 committed late-clean replay is byte-idempotent and retains FINALIZED"
        else
            fail "T43 committed late-clean replay is byte-idempotent and retains FINALIZED" "rc=$t43_repeat_rc stderr=$(tr '\n' ' ' < "$t43/repeat.err")"
        fi
        rm -rf "$t43"
    done

    t43_seed_terminal() { # container mode target-key target-raw
        python3 - "$1" "$2" "$3" "$4" "$t33_role" <<'PY'
import hashlib,json,os,struct,sys
container,mode,target_key,target_raw,role=sys.argv[1:]
path=os.path.join(container,".terminal-audit-pack.v1")
D=lambda domain,value:hashlib.sha256(domain+value).digest()
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
def parse(raw):
 if len(raw)!=32768 or raw[:8]!=b"ZYZTCEL1": raise ValueError("terminal magic")
 schema,flags,generation,length=struct.unpack_from(">HHQI",raw,8)
 source=bytearray(raw); source[56:88]=bytes(32); payload=raw[128:128+length]
 if schema!=1 or flags or generation<1 or length>32640: raise ValueError("terminal header")
 if raw[56:88]!=D(b"zyz-pack-image-v1",bytes(source)) or raw[96:128]!=D(b"zyz-pack-payload-v1",payload): raise ValueError("terminal checksum")
 value=json.loads(payload)
 if J(value)!=payload: raise ValueError("terminal canonical")
 return generation,D(b"zyz-pack-image-id-v1",raw),value
def image(generation,predecessor,value):
 payload=J(value)
 if len(payload)>32640: raise ValueError("terminal payload")
 raw=bytearray(32768); raw[:8]=b"ZYZTCEL1"
 struct.pack_into(">HHQI",raw,8,1,0,generation,len(payload)); raw[24:56]=predecessor
 raw[96:128]=D(b"zyz-pack-payload-v1",payload); raw[128:128+len(payload)]=payload
 source=bytearray(raw); source[56:88]=bytes(32); raw[56:88]=D(b"zyz-pack-image-v1",bytes(source))
 return bytes(raw)
with open(path,"r+b",buffering=0) as f:
 for index in range(256):
  selected=[]
  for bank in (0,1):
   f.seek(index*65536+bank*32768); raw=f.read(32768)
   try: selected.append((parse(raw)[0],bank,raw,parse(raw)))
   except Exception: pass
  if not selected: raise ValueError("terminal initial cell")
  selected.sort(); generation,bank,raw,parsed=selected[-1]
  seed=("terminal-seed-%03d"%index).encode(); digest=hashlib.sha256(seed).hexdigest()
  key="terminal-%03d.%s"%(index,digest)
  if mode=="pinned" and index==2:
   key=target_key; digest=hashlib.sha256(os.fsencode(target_raw)).hexdigest()
  terminal_epoch=index+1; last_event=terminal_epoch; retention=terminal_epoch
  late=None; anchor=None
  if mode=="recent":
   retention=2147483647 if index<192 else terminal_epoch
  if mode=="pinned" and index==0:
   nonce=("%032x"%(index+1)); event_digest=hashlib.sha256(b"late-pinned-event").hexdigest()
   done={"schema_version":1,"instance_key":key,"agent_id_sha256":digest,"display_prefix":"terminal-000",
    "canonical_role":role,"terminal_kind":"done","terminal_epoch":300,
    "event_token":"evt1-"+event_digest,"nonce_sha256":hashlib.sha256(bytes.fromhex(nonce)).hexdigest(),"event_record_digest":event_digest}
   late={"schema_version":1,"phase":"prepared","done_record":done,"done_record_digest":JD(done)}
   last_event=retention=300
  if mode=="pinned" and index==1:
   anchor={"schema_version":1,"phase":"waiting-claim-retire","count":1,
    "accumulator_sha256":hashlib.sha256(b"anchor-accumulator").hexdigest(),
    "latest_claim_digest":hashlib.sha256(b"anchor-claim").hexdigest(),
    "latest_receipt_digest":hashlib.sha256(b"anchor-receipt").hexdigest()}
  latch={"schema_version":1,"state":"freeze-latch-committed"}
  marker={"schema_version":1,"instance_key":key,"agent_id_sha256":digest,"canonical_role":role,
   "terminal_kind":"finalized","terminal_epoch":terminal_epoch}
  value={"schema_version":1,"cell_index":index,"state":"handoff-accepted","instance_key":key,
   "agent_id_sha256":digest,"canonical_role":role,"reservation_nonce":"%032x"%(index+1),
   "prior_cell_generation":generation,"lease_epoch":terminal_epoch,
   "catalog_reservation_digest":hashlib.sha256(seed+b"reservation").hexdigest(),"request_bytes":1052672,
   "handoff_latch":latch,"handoff_latch_digest":JD(latch),"terminal_record":marker,
   "terminal_record_digest":JD(marker),"frozen_headers":{},"instance_objects":{},
   "instance_release":{"phase":"committed","free_receipt_record_digest":hashlib.sha256(seed+b"receipt").hexdigest()},
   "gc_anchor":anchor,"late_clean":late,"publication_staging":None,
   "event_receipts":{"schema_version":1,"resolved_start_ring_digest":None,
    "resolved_stop_ring_digest":None,"latest_start_event_token":None,"latest_stop_event_token":None},
   "created_epoch":terminal_epoch,
   "last_event_epoch":last_event,"retention_epoch":retention}
  successor=image(generation+1,parsed[1],value); target_bank=1-bank
  f.seek(index*65536+target_bank*32768); f.write(successor)
 os.fsync(f.fileno())
PY
    }
    t43_start_id() { # sandbox raw nonce
        printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"%s","agent_type":"zyz-worker:%s"}' \
            "$1" "$2" "$t33_role" |
            ZYZ_TEST_RANDOM_HEX_SEQUENCE="$3" ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 \
            bash hooks/scripts/subagent-track.sh
    }
    t43_seed_ok() { # oracle mode target-index
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); mode=sys.argv[2]; target=int(sys.argv[3]); cells=x["terminal"]["cells"]
required={"schema_version","cell_index","state","instance_key","agent_id_sha256","canonical_role",
 "reservation_nonce","prior_cell_generation","lease_epoch","catalog_reservation_digest","request_bytes",
 "handoff_latch","handoff_latch_digest","terminal_record","terminal_record_digest","frozen_headers",
 "instance_objects","instance_release","gc_anchor","late_clean","publication_staging","event_receipts",
 "created_epoch","last_event_epoch","retention_epoch"}
event_receipts={"schema_version":1,"resolved_start_ring_digest":None,"resolved_stop_ring_digest":None,
 "latest_start_event_token":None,"latest_stop_event_token":None}
accepted=[cell for cell in cells if cell["metadata"].get("state")=="handoff-accepted"]
recent={cell["cell_index"] for cell in sorted(accepted,key=lambda cell:(-cell["metadata"]["terminal_record"]["terminal_epoch"],cell["cell_index"]))[:64]}
schema_ok=all(set(cell["metadata"])==required and cell["metadata"].get("publication_staging") is None and
              cell["metadata"].get("event_receipts")==event_receipts for cell in accepted)
ok=(len(cells)==len(accepted)==256 and schema_ok and all(cell["generation"]==2 for cell in cells) and recent==set(range(192,256)))
if mode=="recent":
 ok=ok and all((cell["metadata"]["retention_epoch"]==2147483647) for cell in cells[:192])
 ok=ok and all(cell["metadata"]["retention_epoch"]==cell["metadata"]["terminal_record"]["terminal_epoch"] for cell in cells[192:])
else:
 by_index={cell["cell_index"]:cell["metadata"] for cell in cells}
 ok=ok and by_index[0].get("late_clean",{}).get("phase")=="prepared"
 ok=ok and by_index[1].get("gc_anchor",{}).get("phase")=="waiting-claim-retire"
 ok=ok and by_index[target].get("late_clean") is None and by_index[target].get("gc_anchor") is None
raise SystemExit(0 if ok else 1)
PY
    }
    t43_eviction_ok() { # before after expected-index
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); expected=int(sys.argv[3])
bc={cell["cell_index"]:cell for cell in b["terminal"]["cells"]}; xc={cell["cell_index"]:cell for cell in x["terminal"]["cells"]}
t=xc.get(expected,{}); tm=t.get("metadata",{})
changed=[index for index in range(256) if xc.get(index)!=bc.get(index)]
pinned=(bc[0]["metadata"].get("late_clean",{}).get("phase")=="prepared" and xc[0]==bc[0])
ok=(set(bc)==set(xc)==set(range(256)) and pinned and changed==[expected] and
 all(xc[i]==bc[i] for i in range(256) if i!=expected) and
 t.get("generation")==bc[expected]["generation"]+1 and t.get("predecessor")==bc[expected]["digest"] and
 tm=={"schema_version":1,"cell_index":expected,"state":"tombstone",
      "evicted_cell_generation":bc[expected]["generation"],"evicted_epoch":tm.get("evicted_epoch")} and
 isinstance(tm.get("evicted_epoch"),int) and tm["evicted_epoch"]>=0)
raise SystemExit(0 if ok else 1)
PY
    }

    t43_new_raw='terminal/new-agent'
    t43_new_key="$(python3 -c 'import hashlib,re,sys;r=sys.argv[1];d=hashlib.sha256(r.encode()).hexdigest();p=re.sub(r"[^A-Za-z0-9._-]","_",r)[:32] or "agent";print(p+"."+d)' "$t43_new_raw")"
    t43="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t43-evict.XXXXXX")"; t33_fixture "$t43"
    (cd "$t43" && ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" gc-step "$t43/.zyz-worker/tasks/task" manual) >"$t43/init.out" 2>"$t43/init.err"
    t43_container="$(find "$t43/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t43_seed_terminal "$t43_container" pinned "$t33_key" "$t33_raw"
    t33_oracle "$t43_container" "$t43_new_key" "$t43_new_raw" "$t33_role" "$t33_nonce_a" >"$t43/base.json" 2>"$t43/base.err"; t43_base_rc=$?
    if [ "$t43_base_rc" -eq 0 ] && t43_seed_ok "$t43/base.json" pinned 2; then
        t43_seed_rc=0
        t43_start_id "$t43" "$t43_new_raw" "$t33_nonce_a" >"$t43/start.out" 2>"$t43/start.err"; t43_start_rc=$?
    else
        t43_seed_rc=1; t43_start_rc=1; : >"$t43/start.out"; : >"$t43/start.err"
    fi
    t33_oracle "$t43_container" "$t43_new_key" "$t43_new_raw" "$t33_role" "$t33_nonce_a" >"$t43/after.json" 2>"$t43/after.err"; t43_after_rc=$?
    if [ "$t43_seed_rc" -eq 0 ] \
        && [ "$t43_start_rc" -eq 0 ] && [ ! -s "$t43/start.out" ] && [ ! -s "$t43/start.err" ] && [ "$t43_after_rc" -eq 0 ] \
        && t33_final_ok "$t43/after.json" && t43_eviction_ok "$t43/base.json" "$t43/after.json" 2; then
        pass "T43 public admission pins unfinished late and anchor owners then evicts oldest eligible cell"
    else
        fail "T43 public admission pins unfinished late and anchor owners then evicts oldest eligible cell" "seed_rc=$t43_seed_rc start_rc=$t43_start_rc base_rc=$t43_base_rc after_rc=$t43_after_rc stderr=$(tr '\n' ' ' < "$t43/start.err")"
    fi
    t33_oracle "$t43_container" "$t43_new_key" "$t43_new_raw" "$t33_role" "$t33_nonce_a" >"$t43/pre-late.json" 2>"$t43/pre-late.err"
    t35_stop "$t43" "$t35_nonce" '' >"$t43/late.out" 2>"$t43/late.err"; t43_late_rc=$?
    t33_oracle "$t43_container" "$t43_new_key" "$t43_new_raw" "$t33_role" "$t33_nonce_a" >"$t43/post-late.json" 2>"$t43/post-late.err"
    if [ "$t43_late_rc" -eq 0 ] && [ ! -s "$t43/late.out" ] \
        && t33_diag_exact "$t43/late.err" late-event-retention-expired \
        && cmp -s "$t43/pre-late.json" "$t43/post-late.json"; then
        pass "T43 public late stop after legal eviction reports retention expired without storage resurrection"
    else
        fail "T43 public late stop after legal eviction reports retention expired without storage resurrection" "rc=$t43_late_rc stderr=$(tr '\n' ' ' < "$t43/late.err")"
    fi
    rm -rf "$t43"

    t43="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t43-capacity.XXXXXX")"; t33_fixture "$t43"
    (cd "$t43" && ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" gc-step "$t43/.zyz-worker/tasks/task" manual) >"$t43/init.out" 2>"$t43/init.err"
    t43_container="$(find "$t43/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t43_seed_terminal "$t43_container" recent "$t33_key" "$t33_raw"
    t33_oracle "$t43_container" "$t43_new_key" "$t43_new_raw" "$t33_role" "$t33_nonce_a" >"$t43/base.json" 2>"$t43/base.err"; t43_base_rc=$?
    if [ "$t43_base_rc" -eq 0 ] && t43_seed_ok "$t43/base.json" recent 0; then
        t43_seed_rc=0
        t43_start_id "$t43" "$t43_new_raw" "$t33_nonce_a" >"$t43/start.out" 2>"$t43/start.err"; t43_start_rc=$?
    else
        t43_seed_rc=1; t43_start_rc=1; : >"$t43/start.out"; : >"$t43/start.err"
    fi
    t33_oracle "$t43_container" "$t43_new_key" "$t43_new_raw" "$t33_role" "$t33_nonce_a" >"$t43/after.json" 2>"$t43/after.err"; t43_after_rc=$?
    if [ "$t43_seed_rc" -eq 0 ] \
        && [ "$t43_start_rc" -eq 0 ] && [ ! -s "$t43/start.out" ] \
        && t33_diag_exact "$t43/start.err" terminal-audit-capacity-blocked \
        && [ "$t43_after_rc" -eq 0 ] && cmp -s "$t43/base.json" "$t43/after.json"; then
        pass "T43 recent-64 plus retention saturation blocks public admission without terminal overwrite"
    else
        fail "T43 recent-64 plus retention saturation blocks public admission without terminal overwrite" "seed_rc=$t43_seed_rc start_rc=$t43_start_rc base_rc=$t43_base_rc after_rc=$t43_after_rc stderr=$(tr '\n' ' ' < "$t43/start.err")"
    fi
    rm -rf "$t43"

    t43_anchor_retired_ok() { # ack-prior retired-prior digest ack-seg1 ack-seg2 retired-seg1 retired-seg2
        python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import base64,hashlib,json,re,struct,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); digest=sys.argv[3]
prior_segment_1,prior_segment_2,retired_segment_1,retired_segment_2=sys.argv[4:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
D=lambda domain,value:hashlib.sha256(domain+value).digest()
H=lambda value:re.fullmatch(r"[0-9a-f]{64}",str(value)) is not None
def parse_frame(raw,offset):
 if len(raw)<64 or raw[:8]!=b"ZYZFRM1\0": raise ValueError("frame magic")
 schema,kind,payload_length,total=struct.unpack_from(">HHII",raw,8)
 if schema!=1 or kind not in range(1,6) or total!=len(raw) or total%8 or payload_length>total-64:
  raise ValueError("frame header")
 encoded=raw[64:64+payload_length]
 if raw[20:52]!=D(b"zyz-catalog-frame-payload-v1",encoded) or raw[52:64]!=bytes(12) or raw[64+payload_length:]!=bytes(total-64-payload_length):
  raise ValueError("frame body")
 payload=json.loads(encoded)
 if not isinstance(payload,dict) or J(payload)!=encoded: raise ValueError("frame canonical")
 return {"offset":offset,"kind":{1:"overlay",2:"free-receipt",3:"owner",4:"claim",5:"observation"}[kind],
         "length":total,"payload":payload,"digest":D(b"zyz-catalog-frame-v1",raw).hex(),
         "sha256":hashlib.sha256(raw).hexdigest()}
bc=b["terminal"]["cells"][0]; xc=x["terminal"]["cells"][0]; bm=bc["metadata"]; xm=xc["metadata"]
request=b["claims"][digest]["records"]["IMMUTABLE_KEY"]["payload"]["reservation_bytes"]
claim=x["claim_cells"].get(digest,{})
terminal_ok=(xc["cell_index"]==bc["cell_index"] and xc["generation"]==bc["generation"]+1 and
 xc["predecessor"]==bc["digest"] and bm.get("gc_anchor",{}).get("phase")=="waiting-claim-retire" and
 xm.get("gc_anchor")=={**bm["gc_anchor"],"phase":"retired"} and
 {k:v for k,v in xm.items() if k!="gc_anchor"}=={k:v for k,v in bm.items() if k!="gc_anchor"})
name1=".catalog-segment.0000000000000001.v1";name2=".catalog-segment.0000000000000002.v1"
bs1=b["segments"].get(name1,{});xs1=x["segments"].get(name1,{})
bs2=b["segments"].get(name2,{});xs2=x["segments"].get(name2,{})
bm1=bs1.get("metadata",{});xm1=xs1.get("metadata",{})
old_used=bm1.get("committed_used_length");new_used=xm1.get("committed_used_length")
old_frames=bs1.get("frames",[]);new_frames=xs1.get("frames",[])
append_frames=new_frames[len(old_frames):] if new_frames[:len(old_frames)]==old_frames else []
try:
 p1=open(prior_segment_1,"rb").read();p2=open(prior_segment_2,"rb").read()
 f1=open(retired_segment_1,"rb").read();f2=open(retired_segment_2,"rb").read()
 physical=(len(p1)==len(p2)==len(f1)==len(f2)==1048576 and p2==f2 and
  p1[:old_used]==f1[:old_used] and p1[old_used:new_used]==bytes(new_used-old_used) and
  p1[new_used:983040]==f1[new_used:983040] and p1[983040+8192:]==f1[983040+8192:] and
  hashlib.sha256(p1[:old_used]).hexdigest()==bs1.get("committed_sha256") and
  hashlib.sha256(f1[:new_used]).hexdigest()==xs1.get("committed_sha256"))
 parsed=[];offset=old_used
 while offset<new_used:
  total=struct.unpack_from(">I",f1,offset+16)[0]
  parsed.append(parse_frame(f1[offset:offset+total],offset));offset+=total
 physical=physical and offset==new_used and parsed==append_frames
except (OSError,TypeError,ValueError,struct.error,json.JSONDecodeError):
 physical=False;parsed=[]
base_cell=b["claim_cells"][digest];base_dir=base_cell["selected_directory"];base_recovery=base_cell["selected_recovery"]
rp=base_recovery["payload"];overlay=parsed[0] if len(parsed)==2 else {};receipt=parsed[1] if len(parsed)==2 else {}
operation=overlay.get("payload",{}).get("operations",{}).get("RELEASE",{})
op_digest=D(b"zyz-recovery-delta-op-v1",bytes.fromhex(base_cell["subject_digest"])+
            bytes.fromhex(rp["reservation_digest"])+b"RELEASE"+struct.pack(">q",-request)).hex()
expected_operation={"phase":"applied","delta":-request,"root_generation":b["root_generation"]+1,
 "op_digest":op_digest,"root_digest":operation.get("root_digest")}
expected_overlay={"schema_version":1,"frame_type":"recovery-overlay","cell_index":base_dir["index"],
 "subject_digest":base_cell["subject_digest"],"reservation_digest":rp["reservation_digest"],
 "object_identities_digest":rp["object_identities_digest"],
 "consumed_free_receipt_record_digest":rp["consumed_free_receipt_record_digest"],
 "operations":{"RELEASE":expected_operation}}
prior_projection={"subject_digest":base_cell["subject_digest"],"reservation_digest":rp["reservation_digest"],
 "object_identities_digest":rp["object_identities_digest"],"operations":{"RELEASE":expected_operation}}
prior_fact=D(b"zyz-last-owner-frame-v1",J(prior_projection))
free_generation=base_dir["free_generation"]+1
cell_generation=base_recovery["generation"]+6
predecessor=bytes.fromhex(rp["consumed_free_receipt_record_digest"])
core=struct.pack(">8sHHIQQ32s",b"ZYZCFV1\0",1,0,base_dir["index"],cell_generation,free_generation,prior_fact)
core_digest=D(b"zyz-cell-free-core-v1",core)
body=struct.pack(">8sB7xIQ",b"ZYZFRB1\0",1,base_dir["index"],free_generation)+predecessor+prior_fact+bytes(32)+core_digest
body_digest=D(b"zyz-free-receipt-body-v1",body);final_cell_digest=D(b"zyz-final-cell-image-v1",core+body_digest)
record_digest=D(b"zyz-free-receipt-record-v1",body+body_digest+final_cell_digest)
expected_receipt={"schema_version":1,"frame_type":"FREE_RECEIPT","kind":"ordinary","cell_index":base_dir["index"],
 "cell_generation":cell_generation,"free_generation":free_generation,"predecessor_record_digest":predecessor.hex(),
 "prior_owner_fact_digest":prior_fact.hex(),"body_b64":base64.b64encode(body).decode(),
 "body_digest":body_digest.hex(),"final_cell_image_digest":final_cell_digest.hex(),"record_digest":record_digest.hex()}
append_ok=(physical and set(b["segments"])==set(x["segments"])=={name1,name2} and bs2==xs2 and
 bs1.get("descriptor_generation")==4 and xs1.get("descriptor_generation")==6 and
 old_used==2360==sum(frame.get("length",-1) for frame in old_frames) and
 new_used==3968==sum(frame.get("length",-1) for frame in new_frames) and
 len(old_frames)==3 and len(new_frames)==5 and len(append_frames)==2 and
 overlay.get("kind")=="overlay" and receipt.get("kind")=="free-receipt" and
 overlay.get("offset")==2360 and overlay.get("length")==752 and
 receipt.get("offset")==3112 and receipt.get("length")==856 and
 receipt.get("offset",-1)+receipt.get("length",-1)==new_used and
 {k:v for k,v in xm1.items() if k not in ("committed_used_length","committed_content_sha256")}==
  {k:v for k,v in bm1.items() if k not in ("committed_used_length","committed_content_sha256")} and
 H(operation.get("root_digest")) and operation==expected_operation and
 overlay.get("payload")==expected_overlay and receipt.get("payload")==expected_receipt and
 x["root_meta"].get("last_overlay_frame_digest")==overlay.get("digest") and
 x["root_meta"].get("last_free_receipt_record_digest")==record_digest.hex() and
 x["root_meta"].get("active_segment_generation")==1 and
 x["root_meta"].get("active_segment_used_length")==new_used and
 x["root_meta"].get("active_segment_descriptor_digest")==xs1.get("descriptor_digest"))
ok=(not x["forbidden_names"] and terminal_ok and digest not in x["claims"] and append_ok and
 x["root_meta"].get("pending_anchor_claim_sha256")==digest and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")-1 and
 x["root_meta"].get("active_data_claims")==b["root_meta"].get("active_data_claims")-1 and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")-request and
 x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+1 and
 claim.get("selected_directory") is None and claim.get("selected_recovery") is None and
 x["root_meta"].get("last_freed_subject_digest")==claim.get("subject_digest"))
raise SystemExit(0 if ok else 1)
PY
    }
    t43_anchor_pointer_final_ok() { # retired-prior final output digest
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import json,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); out=json.load(open(sys.argv[3])); digest=sys.argv[4]
stable_top=("group_generation","group_digest","group_meta","subject_digest","subject_dirs","subject_recoveries",
 "selected_cell","cell_history","packs","lock","expected_event","expected_reservation_digest","expected_request_bytes",
 "segments","claims","claim_cells","terminal","forbidden_names")
root_stable=("owned_bytes","active_claims","active_data_claims","counter_generation","last_freed_subject_digest","last_free_receipt_record_digest")
ok=(all(x.get(name)==b.get(name) for name in stable_top) and
 b["root_generation"]==27 and x["root_generation"]==29 and x["root_meta"].get("pending_anchor_claim_sha256") is None and
 all(x["root_meta"].get(name)==b["root_meta"].get(name) for name in root_stable) and
 out.get("ok") is True and out.get("state")=="compacted" and out.get("error") is None and
 out.get("trigger")=="manual" and out.get("due") is True and out.get("lock_acquired") is True and
 out.get("claims_scanned")==out.get("claims_skipped")==0 and out.get("transactions_advanced")==2 and
 out.get("receipts_anchored")==1 and out.get("entries_deleted")==0 and out.get("bytes_reclaimed")==0 and
 out.get("owned_bytes_before")==out.get("owned_bytes_after")==b["root_meta"].get("owned_bytes"))
raise SystemExit(0 if ok else 1)
PY
    }

    t43="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t43-anchor-retire.XXXXXX")"; t38_released_fixture "$t43"
    t43_container="$(find "$t43/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t43_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t43/base.json" 2>"$t43/base.err"
    t35_stop "$t43" "$t35_nonce" 'terminal-index:instance-release-committed' >"$t43/stop.out" 2>"$t43/stop.err"
    t33_oracle "$t43_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t43/terminal.json" 2>"$t43/terminal.err"; t43_terminal_oracle_rc=$?
    t43_gc "$t43" '' >"$t43/first.out" 2>"$t43/first.err"; t43_first_rc=$?
    t33_oracle "$t43_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t43/first.json" 2>"$t43/first-oracle.err"; t43_first_oracle_rc=$?
    t43_gc "$t43" 'catalog-claim-gc:ANCHOR_ACK-header-committed' >"$t43/ack.out" 2>"$t43/ack.err"; t43_ack_rc=$?
    t33_oracle "$t43_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t43/ack.json" 2>"$t43/ack-oracle.err"; t43_ack_oracle_rc=$?
    t43_segment_snapshot_rc=0
    cp "$t43_container/.catalog-segment.0000000000000001.v1" "$t43/ack-segment-1.v1" \
        || t43_segment_snapshot_rc=$?
    cp "$t43_container/.catalog-segment.0000000000000002.v1" "$t43/ack-segment-2.v1" \
        || t43_segment_snapshot_rc=$?
    t43_gc "$t43" 'terminal-index:gc-anchor-retired' >"$t43/retire.out" 2>"$t43/retire.err"; t43_retire_rc=$?
    t33_oracle "$t43_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t43/retired.json" 2>"$t43/retired-oracle.err"; t43_retired_oracle_rc=$?
    if t37_unavailable_ok "$(cat "$t43/release.rc")" "$t43/release.out" "$t43/release.err" \
        && [ "$t43_terminal_oracle_rc" -eq 0 ] \
        && t41_phase_ok "$t43/base.json" "$t43/terminal.json" instance-release-committed \
        && [ "$t43_first_rc" -eq 3 ] && [ "$t43_first_oracle_rc" -eq 0 ] \
        && t38_first_ok "$t43/terminal.json" "$t43/first.json" "$t43/first.out" "$t38_digest" \
        && [ "$t43_ack_rc" -eq 86 ] \
        && [ ! -s "$t43/ack.out" ] && [ ! -s "$t43/ack.err" ] && [ "$t43_ack_oracle_rc" -eq 0 ] \
        && t41_anchor_phase_ok "$t43/first.json" "$t43/ack.json" ANCHOR_ACK-header-committed "$t38_digest" \
        && [ "$t43_segment_snapshot_rc" -eq 0 ] \
        && [ "$t43_retire_rc" -eq 86 ] && [ ! -s "$t43/retire.out" ] && [ ! -s "$t43/retire.err" ] \
        && [ "$t43_retired_oracle_rc" -eq 0 ] \
        && t43_anchor_retired_ok "$t43/ack.json" "$t43/retired.json" "$t38_digest" \
            "$t43/ack-segment-1.v1" "$t43/ack-segment-2.v1" \
            "$t43_container/.catalog-segment.0000000000000001.v1" "$t43_container/.catalog-segment.0000000000000002.v1"; then
        pass "T43 terminal anchor retires only after claim release while ROOT pointer remains addressable"
    else
        fail "T43 terminal anchor retires only after claim release while ROOT pointer remains addressable" "first_rc=$t43_first_rc ack_rc=$t43_ack_rc snapshot_rc=$t43_segment_snapshot_rc retire_rc=$t43_retire_rc"
    fi
    t43_gc "$t43" '' >"$t43/final.out" 2>"$t43/final.err"; t43_final_rc=$?
    t33_oracle "$t43_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t43/final.json" 2>"$t43/final-oracle.err"; t43_final_oracle_rc=$?
    if [ "$t43_final_rc" -eq 0 ] && [ ! -s "$t43/final.err" ] && [ "$t43_final_oracle_rc" -eq 0 ] \
        && t43_anchor_pointer_final_ok "$t43/retired.json" "$t43/final.json" "$t43/final.out" "$t38_digest"; then
        pass "T43 retired terminal anchor precedes pointer consumption with actual zero deletion counters"
    else
        fail "T43 retired terminal anchor precedes pointer consumption with actual zero deletion counters" "rc=$t43_final_rc oracle_rc=$t43_final_oracle_rc out=$(tr '\n' ' ' < "$t43/final.out")"
    fi
    rm -rf "$t43"

    # -----------------------------------------------------------------------
    # T44  Public fixed-pack adopt-legacy.  The old pathname source is fixture
    # input only; every new authority is catalog CELL + audit/work fixed slots.
    # Exact legacy bytes and the deterministic replay event are independently
    # reconstructed.  Raw exit-86 barriers cover every new journal phase.
    # -----------------------------------------------------------------------
    t44_raw='old/id'; t44_role='implementation-agent'; t44_legacy='old_id'
    t44_key="$(python3 -c 'import hashlib,re,sys;r=sys.argv[1];d=hashlib.sha256(r.encode()).hexdigest();p=re.sub(r"[^A-Za-z0-9._-]","_",r)[:32] or "agent";print(p+"."+d)' "$t44_raw")"
    t44_nonce="$(python3 -c 'import hashlib,sys
raw=b"2000-01-01T00:00:00Z implementation-agent\n";d=hashlib.sha256(sys.argv[1].encode()).digest();ld=hashlib.sha256(raw).digest();print(hashlib.sha256(b"zyz-legacy-adoption-event-v1"+d+ld+sys.argv[2].encode()).hexdigest()[:32])' "$t44_raw" "$t44_role")"
    t44_phase_ok() { # oracle phase start-path heartbeat-path [source-mode]
        python3 - "$1" "$2" "$3" "$4" "${5:-auto}" "$t44_raw" "$t44_role" "$t44_key" "$t44_legacy" <<'PY'
import base64,hashlib,json,os,sys
x=json.load(open(sys.argv[1])); phase,start_path,heartbeat_path,source_mode,raw,role,key,legacy=sys.argv[2:]
phases=("prepared","will-identity","did-identity","will-start","did-start","will-migrated","did-migrated","will-source-retire","did-source-retire","committed")
i=phases.index(phase); source=b"2000-01-01T00:00:00Z implementation-agent\n"; source_sha=hashlib.sha256(source).hexdigest()
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
packs=x["packs"]; audit=packs.get("audit",{}); work=packs.get("work",{}); ar=audit.get("records",{}); wr=work.get("records",{})
journal=wr.get("TRANSITION_JOURNAL",{}).get("payload",{}); identity=ar.get("IDENTITY",{}).get("payload"); start=ar.get("START",{}).get("payload"); migrated=ar.get("SUCCESSOR_RECEIPTS",{}).get("payload")
expected_slots=set()
if i>=2: expected_slots.add("IDENTITY")
if i>=4: expected_slots.add("START")
if i>=6: expected_slots.add("SUCCESSOR_RECEIPTS")
want_identity={"schema_version":1,"instance_key":key,"agent_id_sha256":hashlib.sha256(os.fsencode(raw)).hexdigest(),
 "display_prefix":"old_id","canonical_role":role,"legacy_key":legacy,"legacy_start_sha256":source_sha}
want_start={"schema_version":1,"instance_key":key,"agent_id_sha256":hashlib.sha256(os.fsencode(raw)).hexdigest(),
 "canonical_role":role,"start_epoch":946684800,"start_iso":"2000-01-01T00:00:00Z","legacy_key":legacy,
 "legacy_start_sha256":source_sha,**x["expected_event"]}
created=journal.get("created_epoch")
want_migrated={"schema_version":1,"receipt_type":"legacy-migrated","legacy_key":legacy,"instance_key":key,
 "canonical_role":role,"legacy_start_sha256":source_sha,"identity_digest":JD(want_identity),
 "start_digest":JD(want_start),"migrated_epoch":created}
if source_mode=="auto":
 source_present=i<8
 source_ok=(os.path.isfile(start_path)==source_present and os.path.isfile(heartbeat_path)==source_present)
 if source_present:
  source_ok=source_ok and open(start_path,"rb").read()==source and open(heartbeat_path,"rb").read()==source
elif source_mode=="partial-start-missing":
 source_ok=(not os.path.exists(start_path) and os.path.isfile(heartbeat_path) and open(heartbeat_path,"rb").read()==source)
else:
 raise SystemExit(1)
cell=x["selected_cell"]
ok=(not x["forbidden_names"] and source_ok and
 x["root_generation"]==4 and x["root_meta"].get("owned_bytes")==33554432+x["expected_request_bytes"] and
 x["root_meta"].get("active_claims")==1 and x["root_meta"].get("active_data_claims")==0 and x["root_meta"].get("counter_generation")==1 and
 cell is not None and cell.get("state")==2 and cell.get("recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK" and
 cell.get("recovery",{}).get("payload",{}).get("reservation_digest")==x["expected_reservation_digest"] and
 cell.get("recovery",{}).get("payload",{}).get("consumed_free_receipt_record_digest")==cell.get("fields",[])[3] and
 set(packs)=={"audit","work"} and all(v.get("size")==524288 and v.get("allocated",0)>=524288 and v.get("regular") is True and v.get("nlink")==1 for v in packs.values()) and
 x["lock"] is not None and x["lock"].get("size")==x["expected_request_bytes"]-1048576 and x["lock"].get("allocated",0)>=x["lock"].get("size",1) and x["lock"].get("regular") is True and x["lock"].get("nlink")==1 and
 set(ar)==expected_slots and set(wr)=={"TRANSITION_JOURNAL"} and
 audit.get("header_generation")==1+len(expected_slots) and work.get("header_generation")==2+i and
 journal.get("schema_version")==1 and isinstance(created,int) and created>=946684800 and journal.get("txn_type")==('start' if phase=="committed" else 'adopt-legacy') and
 journal.get("phase")==phase and journal.get("instance_key")==key and journal.get("agent_id_sha256")==want_identity["agent_id_sha256"] and
 journal.get("canonical_role")==role and journal.get("legacy_key")==legacy and journal.get("legacy_start_sha256")==source_sha and
 journal.get("legacy_start_b64")==base64.b64encode(source).decode() and journal.get("identity_record")==want_identity and
 journal.get("legacy_heartbeat_sha256")==source_sha and journal.get("legacy_heartbeat_b64")==base64.b64encode(source).decode() and
 journal.get("identity_digest")==JD(want_identity) and journal.get("start_record")==want_start and journal.get("start_digest")==JD(want_start) and
 all(journal.get(name)==x["expected_event"][name] for name in x["expected_event"]))
if i>=2: ok=ok and identity==want_identity
if i>=4: ok=ok and start==want_start
if i>=6:
 ok=ok and migrated==want_migrated and journal.get("migrated_record")==want_migrated and journal.get("migrated_digest")==JD(want_migrated)
if phase=="committed":
 ok=ok and isinstance(journal.get("committed_epoch"),int) and journal.get("committed_epoch")>=created
raise SystemExit(0 if ok else 1)
PY
    }
    t44_output_ok() { # output idempotent
        python3 - "$1" "$2" "$t44_key" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); idem=sys.argv[2]=="true"; key=sys.argv[3]
ok=(x.get("ok") is True and x.get("state")=="adopted-legacy" and x.get("error") is None and
 x.get("command")=="adopt-legacy" and x.get("trusted") is True and x.get("tracking_capability")=="armed" and
 x.get("instance_key")==key and x.get("idempotent") is idem)
raise SystemExit(0 if ok else 1)
PY
    }
    t44_error_ok() { # output code
        python3 - "$1" "$2" "$t44_key" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); code=sys.argv[2]; key=sys.argv[3]; error=x.get("error") or {}
raise SystemExit(0 if x.get("ok") is False and x.get("state")=="error" and x.get("command")=="adopt-legacy" and x.get("instance_key")==key and error.get("code")==code and error.get("retryable") is False else 1)
PY
    }

    for t44_phase in prepared will-identity did-identity will-start did-start will-migrated did-migrated will-source-retire did-source-retire committed; do
        t44="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t44-adopt.XXXXXX")"; t33_fixture "$t44"
        mkdir -p "$t44/.zyz-worker/tasks/task/runtime/agents"
        printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start"
        printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"
        (cd "$t44" && ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 ZYZ_TEST_TRANSITION_STOP_AFTER="legacy-adopt:$t44_phase" \
            bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/kill.out" 2>"$t44/kill.err"; t44_kill_rc=$?
        t44_container="$(find "$t44/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/prior.json" 2>"$t44/prior.err"; t44_prior_rc=$?
        if [ "$t44_kill_rc" -eq 86 ] && [ ! -s "$t44/kill.out" ] && [ ! -s "$t44/kill.err" ] && [ "$t44_prior_rc" -eq 0 ] \
            && t44_phase_ok "$t44/prior.json" "$t44_phase" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"; then
            pass "T44 public fixed adopt-legacy $t44_phase crash exposes exact catalog/pack prior"
        else
            fail "T44 public fixed adopt-legacy $t44_phase crash exposes exact catalog/pack prior" "rc=$t44_kill_rc oracle_rc=$t44_prior_rc stderr=$(tr '\n' ' ' < "$t44/kill.err")"
        fi
        (cd "$t44" && ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/resume.out" 2>"$t44/resume.err"; t44_resume_rc=$?
        t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/final.json" 2>"$t44/final.err"; t44_final_rc=$?
        if [ "$t44_resume_rc" -eq 0 ] && [ ! -s "$t44/resume.err" ] && [ "$t44_final_rc" -eq 0 ] \
            && t44_output_ok "$t44/resume.out" "$([ "$t44_phase" = committed ] && printf true || printf false)" \
            && t44_phase_ok "$t44/final.json" committed "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"; then
            pass "T44 public fixed adopt-legacy $t44_phase resumes one committed START namespace"
        else
            fail "T44 public fixed adopt-legacy $t44_phase resumes one committed START namespace" "rc=$t44_resume_rc oracle_rc=$t44_final_rc out=$(tr '\n' ' ' < "$t44/resume.out")"
        fi
        (cd "$t44" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/repeat.out" 2>"$t44/repeat.err"; t44_repeat_rc=$?
        t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/repeat.json" 2>"$t44/repeat-oracle.err"
        if [ "$t44_repeat_rc" -eq 0 ] && [ ! -s "$t44/repeat.err" ] && t44_output_ok "$t44/repeat.out" true \
            && cmp -s "$t44/final.json" "$t44/repeat.json"; then
            pass "T44 committed fixed legacy receipt is byte-idempotent after source retirement"
        else
            fail "T44 committed fixed legacy receipt is byte-idempotent after source retirement" "rc=$t44_repeat_rc out=$(tr '\n' ' ' < "$t44/repeat.out")"
        fi
        rm -rf "$t44"
    done

    t44="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t44-partial-retire.XXXXXX")"; t33_fixture "$t44"
    mkdir -p "$t44/.zyz-worker/tasks/task/runtime/agents"
    printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start"
    printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"
    (cd "$t44" && ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 ZYZ_TEST_TRANSITION_STOP_AFTER='legacy-adopt:will-source-retire' \
        bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/kill.out" 2>"$t44/kill.err"; t44_partial_kill_rc=$?
    t44_container="$(find "$t44/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/prior.json" 2>"$t44/prior.err"; t44_partial_prior_rc=$?
    t44_partial_prior_shape_rc=1
    if [ "$t44_partial_prior_rc" -eq 0 ] && t44_phase_ok "$t44/prior.json" will-source-retire "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"; then
        t44_partial_prior_shape_rc=0
    fi
    rm -f "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start"
    t44_partial_state_ok=0
    if [ ! -e "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" ] && [ -f "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat" ]; then
        t44_partial_state_ok=1
    fi
    (cd "$t44" && ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/resume.out" 2>"$t44/resume.err"; t44_partial_resume_rc=$?
    t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/final.json" 2>"$t44/final.err"; t44_partial_final_rc=$?
    if [ "$t44_partial_kill_rc" -eq 86 ] && [ ! -s "$t44/kill.out" ] && [ ! -s "$t44/kill.err" ] \
        && [ "$t44_partial_prior_rc" -eq 0 ] && [ "$t44_partial_prior_shape_rc" -eq 0 ] && [ "$t44_partial_state_ok" -eq 1 ] \
        && [ "$t44_partial_resume_rc" -eq 0 ] && [ ! -s "$t44/resume.err" ] && t44_output_ok "$t44/resume.out" false \
        && [ "$t44_partial_final_rc" -eq 0 ] && t44_phase_ok "$t44/final.json" committed "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"; then
        pass "T44 will-source-retire partial trigger loss resumes without source resurrection"
    else
        fail "T44 will-source-retire partial trigger loss resumes without source resurrection" "kill_rc=$t44_partial_kill_rc resume_rc=$t44_partial_resume_rc oracle_rc=$t44_partial_final_rc"
    fi
    rm -rf "$t44"

    t44="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t44-real-partial-retire.XXXXXX")"; t33_fixture "$t44"
    mkdir -p "$t44/.zyz-worker/tasks/task/runtime/agents"
    printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start"
    printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"
    (cd "$t44" && ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 ZYZ_TEST_TRANSITION_STOP_AFTER='legacy-adopt:post-first-source-delete' \
        bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/kill.out" 2>"$t44/kill.err"; t44_real_partial_kill_rc=$?
    t44_container="$(find "$t44/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/prior.json" 2>"$t44/prior.err"; t44_real_partial_prior_rc=$?
    t44_real_partial_prior_shape_rc=1
    if [ "$t44_real_partial_prior_rc" -eq 0 ] \
        && t44_phase_ok "$t44/prior.json" will-source-retire "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat" partial-start-missing; then
        t44_real_partial_prior_shape_rc=0
    fi
    (cd "$t44" && ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/resume.out" 2>"$t44/resume.err"; t44_real_partial_resume_rc=$?
    t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/final.json" 2>"$t44/final.err"; t44_real_partial_final_rc=$?
    if [ "$t44_real_partial_kill_rc" -eq 86 ] && [ ! -s "$t44/kill.out" ] && [ ! -s "$t44/kill.err" ] \
        && [ "$t44_real_partial_prior_rc" -eq 0 ] && [ "$t44_real_partial_prior_shape_rc" -eq 0 ] \
        && [ "$t44_real_partial_resume_rc" -eq 0 ] && [ ! -s "$t44/resume.err" ] && t44_output_ok "$t44/resume.out" false \
        && [ "$t44_real_partial_final_rc" -eq 0 ] && t44_phase_ok "$t44/final.json" committed "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"; then
        pass "T44 real post-first-source-delete crash resumes the frozen heartbeat exactly once"
    else
        fail "T44 real post-first-source-delete crash resumes the frozen heartbeat exactly once" "kill_rc=$t44_real_partial_kill_rc resume_rc=$t44_real_partial_resume_rc oracle_rc=$t44_real_partial_final_rc"
    fi
    rm -rf "$t44"

    for t44_tamper in recreated-start changed-heartbeat; do
        t44="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t44-retire-tamper.XXXXXX")"; t33_fixture "$t44"
        mkdir -p "$t44/.zyz-worker/tasks/task/runtime/agents"
        printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start"
        printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"
        (cd "$t44" && ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 ZYZ_TEST_TRANSITION_STOP_AFTER='legacy-adopt:post-first-source-delete' \
            bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/kill.out" 2>"$t44/kill.err"; t44_tamper_kill_rc=$?
        t44_container="$(find "$t44/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/before.json" 2>"$t44/before.err"; t44_tamper_before_rc=$?
        t44_tamper_prior_ok=1
        if [ "$t44_tamper_before_rc" -eq 0 ] && t44_phase_ok "$t44/before.json" will-source-retire "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat" partial-start-missing; then
            t44_tamper_prior_ok=0
        fi
        printf 'changed legacy trigger\n' >"$t44/changed.expected"
        printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/original.expected"
        case "$t44_tamper" in
            recreated-start) t44_tamper_path="$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" ;;
            changed-heartbeat) t44_tamper_path="$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat" ;;
        esac
        printf 'changed legacy trigger\n' >"$t44_tamper_path"
        (cd "$t44" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/reject.out" 2>"$t44/reject.err"; t44_tamper_reject_rc=$?
        t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/after.json" 2>"$t44/after.err"; t44_tamper_after_rc=$?
        t44_tamper_sources_ok=0
        if cmp -s "$t44/changed.expected" "$t44_tamper_path"; then
            case "$t44_tamper" in
                recreated-start) cmp -s "$t44/original.expected" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat" && t44_tamper_sources_ok=1 ;;
                changed-heartbeat) [ ! -e "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" ] && t44_tamper_sources_ok=1 ;;
            esac
        fi
        if [ "$t44_tamper_kill_rc" -eq 86 ] && [ ! -s "$t44/kill.out" ] && [ ! -s "$t44/kill.err" ] \
            && [ "$t44_tamper_prior_ok" -eq 0 ] && [ "$t44_tamper_reject_rc" -eq 4 ] && [ ! -s "$t44/reject.err" ] \
            && t44_error_ok "$t44/reject.out" transition-corrupt && [ "$t44_tamper_after_rc" -eq 0 ] \
            && [ "$t44_tamper_sources_ok" -eq 1 ] && cmp -s "$t44/before.json" "$t44/after.json"; then
            pass "T44 post-first-source-delete $t44_tamper is rejected without fixed-pack mutation"
        else
            fail "T44 post-first-source-delete $t44_tamper is rejected without fixed-pack mutation" "kill_rc=$t44_tamper_kill_rc reject_rc=$t44_tamper_reject_rc"
        fi
        rm -rf "$t44"
    done

    t44="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t44-source-conflict.XXXXXX")"; t33_fixture "$t44"
    mkdir -p "$t44/.zyz-worker/tasks/task/runtime/agents"
    printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start"
    printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"
    (cd "$t44" && ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 ZYZ_TEST_TRANSITION_STOP_AFTER='legacy-adopt:did-migrated' \
        bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/kill.out" 2>"$t44/kill.err"; t44_conflict_kill_rc=$?
    t44_container="$(find "$t44/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/prior.json" 2>"$t44/prior.err"; t44_conflict_prior_rc=$?
    t44_conflict_prior_shape_rc=1
    if [ "$t44_conflict_prior_rc" -eq 0 ] && t44_phase_ok "$t44/prior.json" did-migrated "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"; then
        t44_conflict_prior_shape_rc=0
    fi
    printf 'changed legacy source\n' >"$t44/changed.expected"
    printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/heartbeat.expected"
    printf 'changed legacy source\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start"
    t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/mutated.json" 2>"$t44/mutated.err"; t44_mutated_rc=$?
    (cd "$t44" && bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/conflict.out" 2>"$t44/conflict.err"; t44_conflict_rc=$?
    t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/after.json" 2>"$t44/after.err"; t44_after_rc=$?
    if [ "$t44_conflict_kill_rc" -eq 86 ] && [ ! -s "$t44/kill.out" ] && [ ! -s "$t44/kill.err" ] \
        && [ "$t44_conflict_prior_rc" -eq 0 ] && [ "$t44_conflict_prior_shape_rc" -eq 0 ] \
        && [ "$t44_mutated_rc" -eq 0 ] && [ "$t44_conflict_rc" -eq 4 ] && [ ! -s "$t44/conflict.err" ] \
        && t44_error_ok "$t44/conflict.out" transition-corrupt && [ "$t44_after_rc" -eq 0 ] \
        && cmp -s "$t44/changed.expected" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start" \
        && cmp -s "$t44/heartbeat.expected" "$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat" \
        && cmp -s "$t44/mutated.json" "$t44/after.json"; then
        pass "T44 public legacy replay rejects changed retained source without fixed-pack mutation"
    else
        fail "T44 public legacy replay rejects changed retained source without fixed-pack mutation" "rc=$t44_conflict_rc out=$(tr '\n' ' ' < "$t44/conflict.out")"
    fi
    rm -rf "$t44"

    t44="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t44-finalize.XXXXXX")"; t33_fixture "$t44"
    mkdir -p "$t44/.zyz-worker/tasks/task/runtime/agents"
    printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.start"
    printf '2000-01-01T00:00:00Z implementation-agent\n' >"$t44/.zyz-worker/tasks/task/runtime/agents/$t44_legacy.heartbeat"
    (cd "$t44" && ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" adopt-legacy "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" confirmed) >"$t44/adopt.out" 2>"$t44/adopt.err"; t44_adopt_rc=$?
    t44_container="$(find "$t44/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/base.json" 2>"$t44/base.err"; t44_base_rc=$?
    (cd "$t44" && ZYZ_TEST_RANDOM_HEX_SEQUENCE="$t42_reservation_nonce" bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" finalize "$t44/.zyz-worker/tasks/task" "$t44_raw" "$t44_role" "$t42_reason" "$t42_replacement") >"$t44/finalize.out" 2>"$t44/finalize.err"; t44_finalize_rc=$?
    t33_oracle "$t44_container" "$t44_key" "$t44_raw" "$t44_role" "$t44_nonce" >"$t44/final.json" 2>"$t44/final.err"; t44_final_rc=$?
    if [ "$t44_adopt_rc" -eq 0 ] && [ ! -s "$t44/adopt.err" ] && [ "$t44_base_rc" -eq 0 ] && t44_output_ok "$t44/adopt.out" false \
        && [ "$t44_finalize_rc" -eq 0 ] && [ ! -s "$t44/finalize.err" ] && [ "$t44_final_rc" -eq 0 ] \
        && t42_finalize_ok "$t44/base.json" "$t44/final.json" "$t44/finalize.out" false "$t44_key" "$t44_raw" "$t44_role"; then
        pass "T44 adopted fixed START is consumed by public FINALIZED terminal handoff"
    else
        fail "T44 adopted fixed START is consumed by public FINALIZED terminal handoff" "adopt_rc=$t44_adopt_rc finalize_rc=$t44_finalize_rc oracle_rc=$t44_final_rc"
    fi
    rm -rf "$t44"

    # -----------------------------------------------------------------------
    # T45  Fixed PUBLICATION_JOURNAL/LIVE_INVENTORY and publication OWNER.
    # Each kill enters through public SubagentStart. The five
    # journal exits observe the durable plan and its physical visibility order;
    # the five OWNER exits use the exact purpose/parent/logical-key selector so
    # the two earlier snapshot-temp claims cannot consume the barrier.  Direct
    # release-clean/CHECKPOINT/POINTER coverage remains with the bounded public
    # claim-GC suite; these cases intentionally stop at publication handoff.
    # -----------------------------------------------------------------------
    t45_publication_digest="$(python3 -c 'import hashlib,json,sys
value={"schema_version":1,"purpose":"snapshot-publication","instance_key":sys.argv[1],"parent_txn_id":"publication-1"}
print(hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()).hexdigest())' "$t33_key")"
    t45_public_owner() { # sandbox exact-owner-phase
        (
            cd "$1" || exit 1
            printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"%s","agent_type":"zyz-worker:%s"}' \
                "$1" "$t33_raw" "$t33_role" | env \
                ZYZ_TEST_CLAIM_OWNER_STOP_AFTER="catalog-claim-owner:snapshot-publication:publication-1:$t45_publication_digest:$2" \
                bash "$REPO_ROOT/hooks/scripts/subagent-track.sh"
        )
    }
    t45_prior_ok() { # base-oracle observed-oracle journal-phase publication-owner-state agents-dir
        python3 - "$1" "$2" "$3" "$4" "$5" "$t33_key" <<'PY'
import hashlib,json,os,re,socket,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2]))
phase,pub_state,agents,key=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
H=lambda value:re.fullmatch(r"[0-9a-f]{64}",str(value)) is not None
logical={"schema_version":1,"purpose":"snapshot-publication","instance_key":key,"parent_txn_id":"publication-1"}
pub_digest=hashlib.sha256(J(logical)).hexdigest()
claims=x["claims"]; cells=x["claim_cells"]; work=x["packs"]["work"]; wr=work["records"]
journal=wr.get("PUBLICATION_JOURNAL",{}).get("payload",{})
targets=journal.get("publish_targets",[]); staged=journal.get("staged_inventory",{})
live=wr.get("LIVE_INVENTORY",{}).get("payload")
temp_digests=[]
for digest,claim in claims.items():
 immutable=claim.get("records",{}).get("IMMUTABLE_KEY",{}).get("payload",{})
 if immutable.get("purpose")=="snapshot-temp": temp_digests.append(digest)
pub_present=pub_state!="absent"
claim_count=2+int(pub_present)
publication_bytes=sum(item.get("size",-1) for item in staged.get("active",[]))
expected_owned=2*(262144+134217728)+(262144+publication_bytes if pub_present else 0)
instance_request=b["expected_request_bytes"]
work_generations={"prepared":4,"will-target-1":5,"will-target-2":7,
                  "will-live-inventory":9,"committed":12}
visible_counts={"prepared":0,"will-target-1":0,"will-target-2":1,
                "will-live-inventory":2,"committed":2}
journal_fields={"schema_version","txn_type","instance_key","phase","generation",
 "created_epoch","prior_inventory_digest","staged_inventory","publish_targets",
 "native_binding_digest","source_owner_basename","source_owner_digest",
 "source_claim_key_sha256","source_parent_identity","publication_claim_key_sha256",
 "publication_claim_parent_txn_id","publication_claim_max_data_bytes",
 "publication_claim_owner_facts","publication_claim_owner_digest","retired","recovery_temps"}
if phase=="committed": journal_fields.add("committed_epoch")
ok=(not x["forbidden_names"] and set(claims)==set(cells) and len(claims)==claim_count and
 len(temp_digests)==2 and set(journal)==journal_fields and
 journal.get("schema_version")==1 and journal.get("txn_type")=="snapshot-publish" and
 journal.get("instance_key")==key and journal.get("phase")==phase and journal.get("generation")==1 and
 journal.get("prior_inventory_digest") is None and journal.get("retired")==[] and
 journal.get("publication_claim_key_sha256")==pub_digest and
 journal.get("publication_claim_parent_txn_id")=="publication-1" and
 journal.get("publication_claim_max_data_bytes")==publication_bytes and publication_bytes>=0 and
 set(staged)=={"schema_version","instance_key","generation","active","committed_epoch","staged"} and
 staged.get("schema_version")==1 and staged.get("instance_key")==key and staged.get("generation")==1 and
 staged.get("staged") is True and len(staged.get("active",[]))==2 and len(targets)==2 and
 {item.get("purpose") for item in staged.get("active",[])}=={"baseline-records","baseline-header"} and
 work.get("header_generation")==work_generations[phase] and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")+claim_count+1 and
 x["root_meta"].get("active_data_claims")==b["root_meta"].get("active_data_claims")+claim_count and
 x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+claim_count+1 and
 instance_request==1052672 and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")+expected_owned+instance_request and
 "publication_owner_state" not in journal and "source_cleanup_state" not in journal)
source_keys={journal.get("source_claim_key_sha256")}|{
 item.get("claim_key_sha256") for item in journal.get("recovery_temps",[])}
ok=ok and len(source_keys)==2 and source_keys==set(temp_digests)
source_claim=claims.get(journal.get("source_claim_key_sha256"),{})
source_owner=source_claim.get("records",{}).get("OWNER",{}).get("payload",{})
ok=ok and journal.get("source_owner_digest")==hashlib.sha256(J(source_owner)+b"\n").hexdigest()
ok=ok and H(journal.get("native_binding_digest")) and isinstance(journal.get("source_parent_identity"),dict)
projected=[{name:item[name] for name in ("basename","type","size","sha256","dev","ino","nlink","mtime_ns","mount_id")} for item in targets]
ok=ok and journal.get("publication_claim_owner_facts",{}).get("targets")==projected
for target in targets:
 active=[item for item in staged.get("active",[]) if item.get("basename")==target.get("basename")]
 ok=ok and len(active)==1 and active[0]=={name:value for name,value in target.items() if name not in ("source_basename","source_parent_basename")}
for digest in temp_digests:
 claim=claims[digest]; owner=claim["records"].get("OWNER",{}).get("payload",{})
 obs=claim["records"].get("OBSERVATION",{}).get("payload",{}); cell=cells[digest]
 ok=ok and set(claim["records"])=={"IMMUTABLE_KEY","OWNER","OBSERVATION"}
 ok=ok and owner.get("state")=="did-create" and obs.get("state")=="claimed"
 ok=ok and cell.get("selected_directory",{}).get("state")==2
 ok=ok and cell.get("selected_recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK"
if pub_state=="absent":
 ok=ok and pub_digest not in claims
else:
 pub=claims.get(pub_digest,{}); records=pub.get("records",{}); immutable=records.get("IMMUTABLE_KEY",{}).get("payload",{})
 owner=records.get("OWNER",{}).get("payload",{}); obs=records.get("OBSERVATION",{}).get("payload")
 cell=cells.get(pub_digest,{}); expected_owner={**journal.get("publication_claim_owner_facts",{}),
  "schema_version":1,"state":"will-create","created_epoch":journal.get("created_epoch"),
  "hostname":socket.gethostname(),"logical_key_sha256":pub_digest,"instance_key":key,
  "purpose":"snapshot-publication","parent_txn_id":"publication-1"}
 expected_records={"IMMUTABLE_KEY","OWNER"} if pub_state=="will-create-partial" else {"IMMUTABLE_KEY","OWNER","OBSERVATION"}
 expected_header={"will-create-partial":3,"will-create":5,"did-create":6}[pub_state]
 expected_owner_generation=2 if pub_state=="did-create" else 1
 ok=ok and set(records)==expected_records and pub.get("header_generation")==expected_header
 ok=ok and pub.get("selected",{}).get("OWNER",{}).get("generation")==expected_owner_generation
 ok=ok and immutable.get("purpose")=="snapshot-publication" and immutable.get("parent_txn_id")=="publication-1"
 ok=ok and immutable.get("logical_key_sha256")==pub_digest and immutable.get("max_data_bytes")==publication_bytes
 ok=ok and immutable.get("reservation_bytes")==262144+publication_bytes and H(immutable.get("pack_identity_digest"))
 ok=ok and cell.get("selected_directory",{}).get("state")==2
 ok=ok and cell.get("selected_recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK"
 ok=ok and journal.get("publication_claim_owner_digest")==hashlib.sha256(J(expected_owner)+b"\n").hexdigest()
 if pub_state=="did-create":
  ok=ok and owner=={**expected_owner,"state":"did-create","target_identities":projected}
 else: ok=ok and owner==expected_owner
 if pub_state=="will-create-partial": ok=ok and obs is None
 else: ok=ok and isinstance(obs,dict) and obs.get("state")=="claimed"
frame_keys=[]
for segment in x["segments"].values():
 frame_keys.extend(item["payload"].get("logical_key_sha256") for item in segment["frames"] if item["kind"]=="claim")
expected_frames=set(temp_digests) if pub_state in ("absent","will-create-partial") else set(claims)
ok=ok and len(frame_keys)==len(expected_frames) and set(frame_keys)==expected_frames
visible=visible_counts[phase]
for index,item in enumerate(targets):
 source=os.path.join(agents,item["source_parent_basename"],item["source_basename"])
 target=os.path.join(agents,item["basename"]); path=target if index<visible else source
 ok=ok and os.path.isfile(path) and not os.path.exists(source if index<visible else target)
 if os.path.isfile(path):
  st=os.lstat(path); raw=open(path,"rb").read()
  ok=ok and (st.st_dev,st.st_ino,st.st_size,st.st_nlink,st.st_mtime_ns,hashlib.sha256(raw).hexdigest())==(item["dev"],item["ino"],item["size"],item["nlink"],item["mtime_ns"],item["sha256"])
expected_work={"TRANSITION_JOURNAL","PUBLICATION_JOURNAL"}
if phase=="committed":
 expected_work.add("LIVE_INVENTORY")
 expected_live={k:v for k,v in staged.items() if k!="staged"}
 ok=ok and live==expected_live
else: ok=ok and live is None
old_controls=[name for name in os.listdir(agents) if name.endswith((".snapshot-publish-journal",".snapshot-published.v1")) or ".snapshot-inventory." in name or name.endswith(".staged")]
ok=ok and set(wr)==expected_work and not old_controls
raise SystemExit(0 if ok else 1)
PY
    }

    for t45_phase in prepared will-target-1 will-target-2 will-live-inventory committed; do
        t45="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t45-journal.XXXXXX")"; t37_fixture "$t45"
        t45_container="$(find "$t45/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/base.json" 2>"$t45/base.err"
        t37_public "$t45" "snapshot-publish:$t45_phase" '' >"$t45/kill.out" 2>"$t45/kill.err"; t45_kill_rc=$?
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/prior.json" 2>"$t45/prior.err"; t45_prior_rc=$?
        t45_pub_state=will-create
        [ "$t45_phase" = prepared ] && t45_pub_state=absent
        if t37_unavailable_ok "$t45_kill_rc" "$t45/kill.out" "$t45/kill.err" \
            && [ "$t45_prior_rc" -eq 0 ] && t45_prior_ok "$t45/base.json" "$t45/prior.json" \
                "$t45_phase" "$t45_pub_state" "$t45/.zyz-worker/tasks/task/runtime/agents"; then
            pass "T45 public publication journal $t45_phase crash exposes exact fixed-pack visibility prior"
        else
            fail "T45 public publication journal $t45_phase crash exposes exact fixed-pack visibility prior" "rc=$t45_kill_rc oracle_rc=$t45_prior_rc stderr=$(tr '\n' ' ' < "$t45/kill.err")"
        fi
        t37_public "$t45" '' "$t33_nonce_b" >"$t45/resume.out" 2>"$t45/resume.err"; t45_resume_rc=$?
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/final.json" 2>"$t45/final.err"; t45_final_rc=$?
        if t37_fresh_conflict_ok "$t45/prior.json" "$t45/final.json" "$t45/resume.out" "$t45/resume.err" "$t45_resume_rc"; then
            pass "T45 public publication journal $t45_phase fresh retry latches AMBIGUOUS without replaying the event"
        else
            fail "T45 public publication journal $t45_phase fresh retry latches AMBIGUOUS without replaying the event" "rc=$t45_resume_rc oracle_rc=$t45_final_rc out=$(tr '\n' ' ' < "$t45/resume.out")"
        fi
        rm -rf "$t45"
    done

    for t45_owner_phase in will-create-header-committed will-did-create did-create-header-committed; do
        t45="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t45-owner.XXXXXX")"; t37_fixture "$t45"
        t45_container="$(find "$t45/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/base.json" 2>"$t45/base.err"
        t45_public_owner "$t45" "$t45_owner_phase" >"$t45/kill.out" 2>"$t45/kill.err"; t45_kill_rc=$?
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/prior.json" 2>"$t45/prior.err"; t45_prior_rc=$?
        case "$t45_owner_phase" in
            will-create-header-committed) t45_journal_phase=prepared; t45_pub_state=will-create-partial ;;
            will-did-create) t45_journal_phase=committed; t45_pub_state=will-create ;;
            did-create-header-committed) t45_journal_phase=committed; t45_pub_state=did-create ;;
        esac
        if t37_unavailable_ok "$t45_kill_rc" "$t45/kill.out" "$t45/kill.err" \
            && [ "$t45_prior_rc" -eq 0 ] && t45_prior_ok "$t45/base.json" "$t45/prior.json" \
                "$t45_journal_phase" "$t45_pub_state" "$t45/.zyz-worker/tasks/task/runtime/agents"; then
            pass "T45 exact publication OWNER $t45_owner_phase crash exposes its durable prior"
        else
            fail "T45 exact publication OWNER $t45_owner_phase crash exposes its durable prior" "rc=$t45_kill_rc oracle_rc=$t45_prior_rc stderr=$(tr '\n' ' ' < "$t45/kill.err")"
        fi
        t37_public "$t45" '' "$t33_nonce_b" >"$t45/resume.out" 2>"$t45/resume.err"; t45_resume_rc=$?
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/final.json" 2>"$t45/final.err"; t45_final_rc=$?
        if t37_fresh_conflict_ok "$t45/prior.json" "$t45/final.json" "$t45/resume.out" "$t45/resume.err" "$t45_resume_rc"; then
            pass "T45 exact publication OWNER $t45_owner_phase fresh retry latches AMBIGUOUS without replaying the event"
        else
            fail "T45 exact publication OWNER $t45_owner_phase fresh retry latches AMBIGUOUS without replaying the event" "rc=$t45_resume_rc oracle_rc=$t45_final_rc out=$(tr '\n' ' ' < "$t45/resume.out")"
        fi
        rm -rf "$t45"
    done

    # Publication OWNER release-clean is driven only after a second public
    # generation has retired generation 1 and fixed TERMINAL_STAGING owns both
    # old targets.  The kill remains an exact OWNER selector; the oracle below
    # deliberately ignores the unfinished GC_JOURNAL/CHECKPOINT/POINTER grammar
    # and observes only OWNER, fixed publication source-cleanup, data after-set
    # and ROOT accounting.
    t45_public_generation_ok() { # output expected-generation
        # Host hooks are fail-open and silent on success. Generation is proved
        # independently by the fixed PUBLICATION_JOURNAL/LIVE_INVENTORY and
        # publication claim/CELL/ROOT oracle in the caller.
        [ ! -s "$1" ] && case "$2" in 1|2) return 0 ;; *) return 1 ;; esac
    }
    t45_gc_owner() { # sandbox selector-or-empty
        (
            cd "$1" || exit 1
            ZYZ_TEST_CLAIM_OWNER_STOP_AFTER="$2" \
                bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
                gc-step "$1/.zyz-worker/tasks/task" manual
        )
    }
    t45_gc_output_ok() { # output
        python3 - "$1" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); err=x.get("error")
ok=(x.get("ok") is True and x.get("state")=="pending" and err is None and
 x.get("trigger")=="manual" and x.get("due") is True and
 x.get("lock_acquired") is True and isinstance(x.get("transactions_advanced"),int) and
 x["transactions_advanced"]>0)
raise SystemExit(0 if ok else 1)
PY
    }
    t45_release_base_ok() { # initial-oracle generation-2-base-oracle agents-dir
        python3 - "$1" "$2" "$3" "$t33_key" <<'PY'
import hashlib,json,os,re,sys
i=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); agents,key=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
logical=lambda generation:{"schema_version":1,"purpose":"snapshot-publication","instance_key":key,"parent_txn_id":f"publication-{generation}"}
pub={generation:hashlib.sha256(J(logical(generation))).hexdigest() for generation in (1,2)}
claims=b["claims"]; cells=b["claim_cells"]; work=b["packs"]["work"]; wr=work["records"]
journal=wr.get("PUBLICATION_JOURNAL",{}).get("payload",{}); live=wr.get("LIVE_INVENTORY",{}).get("payload",{})
temps=[digest for digest,claim in claims.items() if claim.get("records",{}).get("IMMUTABLE_KEY",{}).get("payload",{}).get("purpose")=="snapshot-temp"]
request=sum(claim.get("records",{}).get("IMMUTABLE_KEY",{}).get("payload",{}).get("reservation_bytes",-1) for claim in claims.values())
ok=(not b["forbidden_names"] and len(claims)==6 and len(temps)==4 and set(pub.values())<=set(claims) and
 set(claims)==set(cells) and request>=0 and
 b["root_meta"].get("active_claims")==i["root_meta"].get("active_claims")+6 and
 b["root_meta"].get("active_data_claims")==i["root_meta"].get("active_data_claims")+6 and
 b["root_meta"].get("counter_generation")==i["root_meta"].get("counter_generation")+6 and
 b["root_meta"].get("owned_bytes")==i["root_meta"].get("owned_bytes")+request and
 journal.get("txn_type")=="snapshot-publish" and journal.get("phase")=="committed" and
 journal.get("generation")==2 and journal.get("publication_owner_state")=="did-create" and
 journal.get("source_cleanup_state")=="released-clean" and
 journal.get("publication_claim_key_sha256")==pub[2] and
 live.get("schema_version")==1 and live.get("instance_key")==key and live.get("generation")==2 and
 len(live.get("active",[]))==2 and {row.get("purpose") for row in live.get("active",[])}=={"baseline-records","baseline-header"} and
 "TERMINAL_STAGING" in work.get("selected",{}))
for digest in temps:
 owner=claims[digest].get("records",{}).get("OWNER",{}).get("payload",{})
 ok=ok and owner.get("state")=="released-clean"
for digest in claims:
 cell=cells.get(digest,{})
 ok=ok and cell.get("selected_directory",{}).get("state")==2
 ok=ok and cell.get("selected_recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK"
first=claims.get(pub[1],{}); first_owner=first.get("records",{}).get("OWNER",{}).get("payload",{})
second_owner=claims.get(pub[2],{}).get("records",{}).get("OWNER",{}).get("payload",{})
ok=ok and first_owner.get("state")==second_owner.get("state")=="did-create"
ok=ok and first.get("selected",{}).get("OWNER",{}).get("generation")==2
ok=ok and cells.get(pub[1],{}).get("selected_directory",{}).get("state")==2
ok=ok and cells.get(pub[1],{}).get("selected_recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK"
for row in first_owner.get("target_identities",[])+live.get("active",[]):
 path=os.path.join(agents,row["basename"]); raw=open(path,"rb").read(); st=os.lstat(path)
 ok=ok and (st.st_dev,st.st_ino,st.st_size,st.st_nlink,st.st_mtime_ns,hashlib.sha256(raw).hexdigest())==(row["dev"],row["ino"],row["size"],row["nlink"],row["mtime_ns"],row["sha256"])
old=[name for name in os.listdir(agents) if name.endswith((".snapshot-publish-journal",".snapshot-published.v1")) or ".snapshot-inventory." in name or name.endswith(".staged")]
ok=ok and not old
raise SystemExit(0 if ok else 1)
PY
    }
    t45_release_state_ok() { # generation-2-base observed expected-owner-state agents-dir
        python3 - "$1" "$2" "$3" "$4" "$t33_key" <<'PY'
import hashlib,json,os,sys
b=json.load(open(sys.argv[1])); x=json.load(open(sys.argv[2])); expected,agents,key=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
logical={"schema_version":1,"purpose":"snapshot-publication","instance_key":key,"parent_txn_id":"publication-1"}
digest=hashlib.sha256(J(logical)).hexdigest(); claims=x["claims"]; cells=x["claim_cells"]
claim=claims.get(digest,{}); owner=claim.get("records",{}).get("OWNER",{}).get("payload",{})
work=x["packs"]["work"]; wr=work["records"]; journal=wr.get("PUBLICATION_JOURNAL",{}).get("payload",{}); live=wr.get("LIVE_INVENTORY",{}).get("payload",{})
counters=("owned_bytes","active_claims","active_data_claims","counter_generation")
ok=(not x["forbidden_names"] and set(claims)==set(b["claims"]) and
 all(x["root_meta"].get(name)==b["root_meta"].get(name) for name in counters) and
 owner.get("state")==expected and claim.get("selected",{}).get("OWNER",{}).get("generation")==({"did-create":2,"released-clean":3}[expected]) and
 cells.get(digest,{}).get("selected_directory",{}).get("state")==2 and
 cells.get(digest,{}).get("selected_recovery",{}).get("payload",{}).get("state")=="ACTIVE_ACK" and
 journal.get("txn_type")=="snapshot-publish" and journal.get("phase")=="committed" and
 journal.get("generation")==2 and journal.get("publication_owner_state")=="did-create" and
 journal.get("source_cleanup_state")=="released-clean" and live.get("generation")==2 and
 len(live.get("active",[]))==2 and "TERMINAL_STAGING" in work.get("selected",{}))
targets=owner.get("target_identities")
ok=ok and isinstance(targets,list) and len(targets)==2 and all(not os.path.exists(os.path.join(agents,row["basename"])) for row in targets)
if expected=="released-clean":
 release_digest=hashlib.sha256(b"zyz-claim-released-target-set-v1"+J(targets)).hexdigest()
 ok=ok and isinstance(owner.get("released_epoch"),int) and owner["released_epoch"]>=0
 ok=ok and owner.get("released_target_set_digest")==release_digest
else:
 ok=ok and "released_epoch" not in owner and "released_target_set_digest" not in owner
for row in live.get("active",[]):
 path=os.path.join(agents,row["basename"]); raw=open(path,"rb").read(); st=os.lstat(path)
 ok=ok and (st.st_dev,st.st_ino,st.st_size,st.st_nlink,st.st_mtime_ns,hashlib.sha256(raw).hexdigest())==(row["dev"],row["ino"],row["size"],row["nlink"],row["mtime_ns"],row["sha256"])
temps=[claim.get("records",{}).get("OWNER",{}).get("payload",{}) for claim in claims.values() if claim.get("records",{}).get("IMMUTABLE_KEY",{}).get("payload",{}).get("purpose")=="snapshot-temp"]
ok=ok and len(temps)==4 and all(row.get("state")=="released-clean" for row in temps)
old=[name for name in os.listdir(agents) if name.endswith((".snapshot-publish-journal",".snapshot-published.v1")) or ".snapshot-inventory." in name or name.endswith(".staged")]
ok=ok and not old
raise SystemExit(0 if ok else 1)
PY
    }

    for t45_release_phase in will-release-clean released-clean-header-committed; do
        t45="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t45-owner-release.XXXXXX")"; t37_fixture "$t45"
        t45_container="$(find "$t45/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/initial.json" 2>"$t45/initial.err"
        t37_public "$t45" '' '' >"$t45/generation-1.out" 2>"$t45/generation-1.err"; t45_gen1_rc=$?
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/base.json" 2>"$t45/base.err"; t45_base_rc=$?
        t37_public "$t45" '' "$t33_nonce_b" >"$t45/generation-2.out" 2>"$t45/generation-2.err"; t45_gen2_rc=$?
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/conflict-final.json" 2>"$t45/conflict-final.err"; t45_conflict_final_rc=$?
        if [ "$t45_gen1_rc" -eq 0 ] && [ ! -s "$t45/generation-1.err" ] && t45_public_generation_ok "$t45/generation-1.out" 1 \
            && [ "$t45_base_rc" -eq 0 ] && [ "$t45_conflict_final_rc" -eq 0 ] \
            && t37_fresh_conflict_ok "$t45/base.json" "$t45/conflict-final.json" "$t45/generation-2.out" "$t45/generation-2.err" "$t45_gen2_rc"; then
            pass "T45 exact publication OWNER $t45_release_phase fresh generation setup latches AMBIGUOUS and preserves the committed publication prior"
            rm -rf "$t45"
            continue
        fi
        t45_base_shape=1
        t45_selector="catalog-claim-owner:snapshot-publication:publication-1:$t45_publication_digest:$t45_release_phase"
        t45_gc_owner "$t45" "$t45_selector" >"$t45/kill.out" 2>"$t45/kill.err"; t45_kill_rc=$?
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/prior.json" 2>"$t45/prior.err"; t45_prior_rc=$?
        t45_expected_state=did-create
        [ "$t45_release_phase" = released-clean-header-committed ] && t45_expected_state=released-clean
        if [ "$t45_base_shape" -eq 0 ] && [ "$t45_kill_rc" -eq 86 ] && [ ! -s "$t45/kill.out" ] && [ ! -s "$t45/kill.err" ] \
            && [ "$t45_prior_rc" -eq 0 ] && t45_release_state_ok "$t45/base.json" "$t45/prior.json" \
                "$t45_expected_state" "$t45/.zyz-worker/tasks/task/runtime/agents"; then
            pass "T45 exact publication OWNER $t45_release_phase crash exposes deleted data and exact release prior"
        else
            fail "T45 exact publication OWNER $t45_release_phase crash exposes deleted data and exact release prior" "setup=$t45_base_shape kill_rc=$t45_kill_rc oracle_rc=$t45_prior_rc"
        fi
        t45_gc_owner "$t45" '' >"$t45/resume.out" 2>"$t45/resume.err"; t45_resume_rc=$?
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/final.json" 2>"$t45/final.err"; t45_final_rc=$?
        if [ "$t45_resume_rc" -eq 3 ] && [ ! -s "$t45/resume.err" ] && t45_gc_output_ok "$t45/resume.out" \
            && [ "$t45_final_rc" -eq 0 ] && t45_release_state_ok "$t45/base.json" "$t45/final.json" \
                released-clean "$t45/.zyz-worker/tasks/task/runtime/agents"; then
            pass "T45 exact publication OWNER $t45_release_phase public replay preserves cleanup and accounting"
        else
            fail "T45 exact publication OWNER $t45_release_phase public replay preserves cleanup and accounting" "rc=$t45_resume_rc oracle_rc=$t45_final_rc out=$(tr '\n' ' ' < "$t45/resume.out")"
        fi
        rm -rf "$t45"
    done

    t45_selector_boundary_ok() { # base final publication-digest
        python3 -c 'import json,sys;b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));d=sys.argv[3];bc=b["claims"][d];xc=x["claims"][d];br=bc["records"];xr=xc["records"];bo=br["OWNER"]["payload"];xo=xr["OWNER"]["payload"];drop={"owned_bytes","active_claims","active_data_claims","counter_generation","root_generation","root_digest","last_freed_subject_digest","active_segment_descriptor_digest","active_segment_used_length","directory_sha256","discovery_cursor","generation","generation_vector_sha256","last_free_receipt_record_digest","last_overlay_frame_digest","overlay_flush_cursor","pending_anchor_claim_sha256","recovery_overlay_digest","recovery_sha256","sweep_generation"};rb={k:v for k,v in b["root_meta"].items() if k not in drop};rx={k:v for k,v in x["root_meta"].items() if k not in drop};ob=br["OBSERVATION"]["payload"];ox=xr["OBSERVATION"]["payload"];ok=(bo==xo and br["IMMUTABLE_KEY"]==xr["IMMUTABLE_KEY"] and b["packs"]["work"]["records"].get("PUBLICATION_JOURNAL")==x["packs"]["work"]["records"].get("PUBLICATION_JOURNAL") and b["claim_cells"][d]==x["claim_cells"][d] and rb==rx and bo.get("state")==xo.get("state")=="did-create" and ob.get("state")==ox.get("state")=="claimed" and br["OBSERVATION"].get("generation")==3 and xr["OBSERVATION"].get("generation")==4 and isinstance(ob.get("sequence"),int) and isinstance(ox.get("sequence"),int) and ox["sequence"]>=ob["sequence"] and isinstance(ob.get("last_observed_epoch"),int) and isinstance(ox.get("last_observed_epoch"),int) and ox["last_observed_epoch"]>ob["last_observed_epoch"]);raise SystemExit(0 if ok else 1)' "$1" "$2" "$3"
    }
    for t45_negative in wrong-purpose wrong-parent wrong-digest wrong-phase; do
        t45="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t45-owner-selector.XXXXXX")"; t37_fixture "$t45"
        t45_container="$(find "$t45/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/initial.json" 2>"$t45/initial.err"
        t37_public "$t45" '' '' >"$t45/generation-1.out" 2>"$t45/generation-1.err"; t45_gen1_rc=$?
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/base.json" 2>"$t45/base.err"; t45_base_rc=$?
        case "$t45_negative" in
            wrong-purpose) t45_selector="catalog-claim-owner:snapshot-temp:publication-1:$t45_publication_digest:will-release-clean" ;;
            wrong-parent) t45_selector="catalog-claim-owner:snapshot-publication:publication-2:$t45_publication_digest:will-release-clean" ;;
            wrong-digest) t45_selector="catalog-claim-owner:snapshot-publication:publication-1:0000000000000000000000000000000000000000000000000000000000000000:will-release-clean" ;;
            wrong-phase) t45_selector="catalog-claim-owner:snapshot-publication:publication-1:$t45_publication_digest:will-did-create" ;;
        esac
        t45_gc_owner "$t45" "$t45_selector" >"$t45/control.out" 2>"$t45/control.err"; t45_control_rc=$?
        t33_oracle "$t45_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t45/final.json" 2>"$t45/final.err"; t45_final_rc=$?
        if [ "$t45_gen1_rc" -eq 0 ] && [ ! -s "$t45/generation-1.err" ] && t45_public_generation_ok "$t45/generation-1.out" 1 \
            && [ "$t45_base_rc" -eq 0 ] && [ "$t45_control_rc" -eq 3 ] && [ ! -s "$t45/control.err" ] \
            && t45_gc_output_ok "$t45/control.out" && [ "$t45_final_rc" -eq 0 ] \
            && t45_selector_boundary_ok "$t45/base.json" "$t45/final.json" "$t45_publication_digest"; then
            pass "T45 publication OWNER selector $t45_negative cannot consume the generation-1 did-create boundary"
        else
            fail "T45 publication OWNER selector $t45_negative cannot consume the generation-1 did-create boundary" "gen1=$t45_gen1_rc base=$t45_base_rc rc=$t45_control_rc oracle_rc=$t45_final_rc"
        fi
        rm -rf "$t45"
    done

    if python3 - hooks/scripts/runtime_state.py <<'PY'
import ast,sys
tree=ast.parse(open(sys.argv[1],encoding="utf-8").read())
fn=next((node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=="publish_snapshot"),None)
if fn is None: raise SystemExit(1)
def called(node):
 f=node.func
 return f.id if isinstance(f,ast.Name) else f.attr if isinstance(f,ast.Attribute) else ""
class Order(ast.NodeVisitor):
 def __init__(self): self.lock=0;self.stack=[];self.events=[]
 def visit_With(self,node):
  is_lock=any(isinstance(item.context_expr,ast.Call) and called(item.context_expr)=="InstanceFlock" for item in node.items)
  if is_lock:
   self.lock+=1; current=self.lock; self.stack.append(current)
   for stmt in node.body:self.visit(stmt)
   self.stack.pop()
  else:self.generic_visit(node)
 def visit_Call(self,node):
  name=called(node)
  if name in ("_publication_write_journal","_publication_read_journal","_catalog_claim_create",
              "publication_step","_catalog_claim_owner_did_create","cleanup_publication_temps"):
   self.events.append((node.lineno,name,self.stack[-1] if self.stack else None))
  self.generic_visit(node)
o=Order();o.visit(fn)
events=sorted(o.events); writes=[e for e in events if e[1]=="_publication_write_journal"]
one=lambda name:[e for e in events if e[1]==name]
create=one("_catalog_claim_create");step=one("publication_step");owner=one("_catalog_claim_owner_did_create");cleanup=one("cleanup_publication_temps")
ok=(o.lock==4 and len(writes)==3 and [e[2] for e in writes]==[1,3,4] and
 len(create)==len(step)==len(owner)==len(cleanup)==1 and
 create[0][2] is None and step[0][2]==2 and owner[0][2] is None and cleanup[0][2] is None and
 writes[0][0]<create[0][0]<step[0][0]<owner[0][0]<writes[1][0]<cleanup[0][0]<writes[2][0])
raise SystemExit(0 if ok else 1)
PY
    then
        pass "T45 publication lock order releases around catalog OWNER transitions and reacquires for handoffs"
    else
        fail "T45 publication lock order releases around catalog OWNER transitions and reacquires for handoffs"
    fi

    # -----------------------------------------------------------------------
    # T46  Dirty snapshot-temp tree checkpoints and descriptor deletion.
    # Every fixture is a real snapshot producer stopped only after its catalog
    # OWNER reached did-create.  The test then shapes descendants inside that
    # already-owned directory; the durable OWNER root dev/ino/type/mode/mount
    # remains the production authority.  Expected CHECKPOINT HMACs, POINTER
    # digests, raw-path identities, content digests, receipt HMACs and ROOT
    # accounting are rebuilt here without importing a production helper.
    #
    # Green proves these compact boundary shapes and public replay.  It does
    # not prove >128 MiB offset continuation, >10,000-entry fairness/deadline,
    # corrupt/torn checkpoint rejection, retired publication intents, nested
    # mounts, or unavailable block/char capabilities; those need their named
    # pressure/corruption/capability cases and must not be inferred from T46.
    # -----------------------------------------------------------------------
    t46_digest="$(t37_claim_digest "$t33_key" "$t37_seed")"
    t46_dirty_base_ok() { # initial-oracle dirty-oracle agents-dir digest
        python3 - "$1" "$2" "$3" "$4" "$t33_key" "$t37_nonce" <<'PY'
import hashlib,json,os,stat,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));agents,digest,key,nonce=sys.argv[3:]
audit_request=b.get("expected_request_bytes")
claim=x["claims"].get(digest,{});records=claim.get("records",{});owner=records.get("OWNER",{}).get("payload",{})
immutable=records.get("IMMUTABLE_KEY",{}).get("payload",{});obs=records.get("OBSERVATION",{}).get("payload",{})
target=owner.get("target_identities",[{}])[0];root=os.path.join(agents,f".snapshot-tmp.{nonce}")
st=os.lstat(root)
stable=("owned_bytes","active_claims","active_data_claims","counter_generation")
required_owner={"nonce","creator_pid","creator_boot_id","creator_birth_token","writer_pid",
 "writer_birth_token","task_id","task_identity_digest","root_identity_digest",
 "runtime_identity_digest","runtime_mount_id","native_binding_digest","instance_key_digest",
 "temp_basename","max_paths","max_file_bytes","max_total_bytes","max_temp_bytes","targets",
 "schema_version","state","created_epoch","hostname","logical_key_sha256","instance_key",
 "purpose","parent_txn_id","target_identities"}
ok=(isinstance(audit_request,int) and audit_request>0 and set(x["claims"])=={digest} and set(records)=={"IMMUTABLE_KEY","OWNER","OBSERVATION"} and
 set(owner)==required_owner and owner.get("state")=="did-create" and owner.get("purpose")=="snapshot-temp" and
 owner.get("instance_key")==key and owner.get("parent_txn_id")==nonce and owner.get("logical_key_sha256")==digest and
 owner.get("temp_basename")==f".snapshot-tmp.{nonce}" and
 (owner.get("max_paths"),owner.get("max_file_bytes"),owner.get("max_total_bytes"),owner.get("max_temp_bytes"))==
  (10000,16777216,67108864,134217728) and immutable.get("max_data_bytes")==134217728 and
 obs.get("state")=="claimed" and isinstance(obs.get("sequence"),int) and obs["sequence"]>0 and
 target=={"basename":f".snapshot-tmp.{nonce}","type":"directory","dev":st.st_dev,"ino":st.st_ino,
  "nlink":st.st_nlink,"mode":stat.S_IMODE(st.st_mode),"mount_id":owner.get("runtime_mount_id")} and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")+audit_request+262144+134217728 and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")+2 and
 x["root_meta"].get("active_data_claims")==b["root_meta"].get("active_data_claims")+1 and
 x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+2 and
 all(x["root_meta"].get(name)>=b["root_meta"].get(name) for name in stable))
raise SystemExit(0 if ok else 1)
PY
    }
    t46_dirty_fixture() { # sandbox shape
        t46_sandbox="$1"; t46_shape="$2"
        t37_fixture "$t46_sandbox"
        t46_container="$(find "$t46_sandbox/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t46_agents="$t46_sandbox/.zyz-worker/tasks/task/runtime/agents"
        t46_root="$t46_agents/.snapshot-tmp.$t37_nonce"
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46_sandbox/initial.json" 2>"$t46_sandbox/initial.err"
        t37_public "$t46_sandbox" 'catalog-claim-pack:owner-did-create' "$t37_seed" \
            >"$t46_sandbox/create.out" 2>"$t46_sandbox/create.err"
        printf '%s\n' "$?" > "$t46_sandbox/create.rc"
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46_sandbox/dirty.json" 2>"$t46_sandbox/dirty.err"
        t46_setup_rc=$?
        if t37_unavailable_ok "$(cat "$t46_sandbox/create.rc")" \
                "$t46_sandbox/create.out" "$t46_sandbox/create.err" \
            && [ "$t46_setup_rc" -eq 0 ] \
            && t46_dirty_base_ok "$t46_sandbox/initial.json" "$t46_sandbox/dirty.json" \
                "$t46_agents" "$t46_digest" \
            && [ -d "$t46_root" ] \
            && [ -z "$(find "$t46_root" -mindepth 1 -maxdepth 1 -print 2>/dev/null)" ]; then
            printf '0\n' > "$t46_sandbox/setup.rc"
        else
            printf '1\n' > "$t46_sandbox/setup.rc"
            return
        fi
        case "$t46_shape" in
            empty) : ;;
            regular) printf 't46-regular-payload\n' > "$t46_root/leaf" ;;
            directory) mkdir "$t46_root/leaf" ;;
            symlink) ln -s 'target-does-not-exist' "$t46_root/leaf" ;;
            fifo) mkfifo "$t46_root/leaf" ;;
            socket)
                python3 - "$t46_sandbox/dirty.json" "$t46_digest" "$t46_root" \
                    2>"$t46_sandbox/shape-capability.err" <<'PY'
import errno,json,os,socket,stat,sys
dirty=json.load(open(sys.argv[1]));digest,root=sys.argv[2:]
owner=dirty.get("claims",{}).get(digest,{}).get("records",{}).get("OWNER",{}).get("payload",{})
targets=owner.get("target_identities",[])
flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
root_fd=os.open(root,flags)
try:
 st=os.fstat(root_fd)
 target=targets[0] if len(targets)==1 else {}
 expected={"basename":os.path.basename(root),"type":"directory","dev":st.st_dev,
  "ino":st.st_ino,"nlink":st.st_nlink,"mode":stat.S_IMODE(st.st_mode),
  "mount_id":owner.get("runtime_mount_id")}
 if (not stat.S_ISDIR(st.st_mode) or st.st_nlink<=0 or owner.get("state")!="did-create" or
     owner.get("purpose")!="snapshot-temp" or owner.get("logical_key_sha256")!=digest or
     owner.get("temp_basename")!=os.path.basename(root) or target!=expected or
     not isinstance(expected["mount_id"],str) or not expected["mount_id"]):
  raise SystemExit("authenticated socket root mismatch")
 cwd_fd=os.open(".",os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC)
 try:
  os.fchdir(root_fd)
  capability={getattr(errno,name) for name in
   ("EAFNOSUPPORT","EPROTONOSUPPORT","ESOCKTNOSUPPORT","EOPNOTSUPP","ENOSYS")
   if hasattr(errno,name)}
  if not hasattr(socket,"AF_UNIX"):
   print("socket capability unavailable: AF_UNIX missing",file=sys.stderr)
   raise SystemExit(77)
  try:
   s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
   try:s.bind("leaf")
   finally:s.close()
  except OSError as exc:
   if exc.errno in capability:
    print(f"socket capability unavailable: {exc}",file=sys.stderr)
    raise SystemExit(77)
   raise
 finally:
  try:os.fchdir(cwd_fd)
  finally:os.close(cwd_fd)
 leaf=os.stat("leaf",dir_fd=root_fd,follow_symlinks=False)
 if not stat.S_ISSOCK(leaf.st_mode) or leaf.st_dev!=st.st_dev or leaf.st_nlink<=0:
  raise SystemExit("descriptor-bound socket leaf mismatch")
finally:
 os.close(root_fd)
PY
                t46_socket_rc=$?
                if [ "$t46_socket_rc" -eq 77 ]; then
                    printf 'socket capability unavailable\n' > "$t46_sandbox/shape.skip"
                    return
                fi
                if [ "$t46_socket_rc" -ne 0 ]; then
                    printf '1\n' > "$t46_sandbox/setup.rc"
                    return
                fi
                ;;
            char|block)
                python3 - "$t46_root/leaf" "$t46_shape" 2>"$t46_sandbox/shape-capability.err" <<'PY'
import os,stat,sys
mode=stat.S_IFCHR if sys.argv[2]=="char" else stat.S_IFBLK
device=os.makedev(1,3 if sys.argv[2]=="char" else 0)
os.mknod(sys.argv[1],mode|0o600,device)
PY
                if [ "$?" -ne 0 ]; then
                    printf '%s capability unavailable\n' "$t46_shape" > "$t46_sandbox/shape.skip"
                    return
                fi
                ;;
            *) printf 'unknown shape\n' > "$t46_sandbox/shape.skip"; return ;;
        esac
        python3 - "$t46_agents" "$t46_root" "$t46_shape" > "$t46_sandbox/fixture.json" <<'PY'
import base64,json,os,stat,sys
agents,root,shape=sys.argv[1:]
def fact(path):
 st=os.lstat(path)
 kind=("directory" if stat.S_ISDIR(st.st_mode) else
       "regular" if stat.S_ISREG(st.st_mode) else
       "symlink" if stat.S_ISLNK(st.st_mode) else
       "fifo" if stat.S_ISFIFO(st.st_mode) else
       "socket" if stat.S_ISSOCK(st.st_mode) else
       "block" if stat.S_ISBLK(st.st_mode) else
       "char" if stat.S_ISCHR(st.st_mode) else None)
 if kind is None:raise SystemExit(2)
 return {"type":kind,"mode":st.st_mode,"rdev":st.st_rdev,"dev":st.st_dev,
  "ino":st.st_ino,"nlink":st.st_nlink,"size":st.st_size,
  "allocated_bytes":max(st.st_size,getattr(st,"st_blocks",0)*512),
  "mtime_ns":st.st_mtime_ns,"ctime_ns":st.st_ctime_ns}
value={"shape":shape,"agents":fact(agents),"root":fact(root),"leaf":None,
       "path_b64":None,"content_b64":None}
if shape!="empty":
 path=os.path.join(root,"leaf");value["leaf"]=fact(path)
 value["path_b64"]=base64.b64encode(b"leaf").decode()
 if shape=="regular":value["content_b64"]=base64.b64encode(open(path,"rb").read()).decode()
print(json.dumps(value,sort_keys=True,separators=(",",":")))
PY
    }
    t46_gc() { # sandbox exact-barrier-or-empty
        (
            cd "$1" || exit 1
            ZYZ_NO_OUTPUT_TEMP_STALE_SEC=120 \
            ZYZ_TEST_GC_NOW_EPOCH=2147480000 \
            ZYZ_SNAPSHOT_GC_MAX_ENTRIES_PER_PASS=100 \
            ZYZ_SNAPSHOT_GC_MAX_VERIFY_BYTES_PER_PASS=2147483647 \
            ZYZ_SNAPSHOT_GC_MAX_SEC=30 \
            ZYZ_TEST_TRANSITION_STOP_AFTER="${2:+catalog-claim-gc:$2}" \
                bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
                    gc-step "$1/.zyz-worker/tasks/task" manual
        )
    }
    t46_rewrite_record() { # container-dir digest action
        python3 - "$1" "$2" "$3" <<'PY'
import hashlib,json,os,struct,sys
container,digest,action=sys.argv[1:];path=os.path.join(container,digest+".claim-pack.v1")
D=lambda domain,value:hashlib.sha256(domain+value).digest()
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
def parse(raw,magic,id_domain):
 if raw[:8]!=magic.ljust(8,b"\0"):raise ValueError("magic")
 schema,flags,generation,length=struct.unpack_from(">HHQI",raw,8)
 if schema!=1 or flags!=0 or length>len(raw)-128:raise ValueError("header")
 source=bytearray(raw);source[56:88]=bytes(32)
 if raw[56:88]!=D(b"zyz-pack-image-v1" if magic==b"ZYZCLMH1" else b"zyz-instance-record-image-v1",bytes(source)):raise ValueError("image")
 payload=raw[128:128+length]
 if raw[96:128]!=D(b"zyz-pack-payload-v1" if magic==b"ZYZCLMH1" else b"zyz-instance-record-payload-v1",payload):raise ValueError("payload")
 value=json.loads(payload)
 if J(value)!=payload:raise ValueError("canonical")
 return generation,raw[24:56],value,D(id_domain,raw)
def build(magic,size,generation,predecessor,value,image_domain,payload_domain):
 payload=J(value)
 if len(payload)>size-128:raise ValueError("payload overflow")
 raw=bytearray(size);raw[:8]=magic.ljust(8,b"\0")
 struct.pack_into(">HHQI",raw,8,1,0,generation,len(payload));raw[24:56]=predecessor
 raw[96:128]=D(payload_domain,payload);raw[128:128+len(payload)]=payload
 raw[56:88]=D(image_domain,bytes(raw));return bytes(raw)
fd=os.open(os.fsencode(path),os.O_RDWR|getattr(os,"O_NOFOLLOW",0))
try:
 headers=[]
 for bank in (0,1):
  raw=os.pread(fd,4096,bank*4096)
  try:headers.append((*parse(raw,b"ZYZCLMH1",b"zyz-pack-image-id-v1"),bank,raw))
  except Exception:pass
 if not headers:raise ValueError("no header")
 generation,predecessor,meta,header_digest,header_bank,header_raw=max(headers,key=lambda row:row[0])
 selected=dict(meta["selected"]);layouts={"CHECKPOINT":(90112,16384),"POINTER":(106496,8192)}
 def read_slot(name):
  ref=selected[name];offset,length=layouts[name];half=length//2
  raw=os.pread(fd,half,offset+ref["bank"]*half)
  observed=parse(raw,b"ZYZREC1",b"zyz-instance-record-id-v1")
  if observed[0]!=ref["generation"] or observed[3].hex()!=ref["digest"]:raise ValueError("selector")
  return ref,observed,raw
 if action in ("drop-pointer-first","drop-pointer-conflict"):
  selected.pop("POINTER",None)
 else:
  slot_name="CHECKPOINT" if action in ("current-hmac","previous-hmac") else "POINTER"
  ref,observed,raw=read_slot(slot_name);payload=dict(observed[2])
  if action=="current-hmac":
   payload["current"]={**payload["current"],"hmac_sha256":"0"*64}
  elif action=="previous-hmac":
   payload["previous"]={**payload["previous"],"hmac_sha256":"0"*64}
  elif action=="pointer-generation":
   payload["generation"]=payload["generation"]+17
  elif action=="pointer-digest":
   payload["checkpoint_digest"]="0"*64
  elif action=="pointer-previous":
   _,checkpoint,_=read_slot("CHECKPOINT");previous=checkpoint[2]["previous"]
   payload={"schema_version":1,"generation":previous["generation"],
            "checkpoint_digest":hashlib.sha256(J(previous)+b"\n").hexdigest()}
  else:raise ValueError("action")
  offset,length=layouts[slot_name];half=length//2;inactive=1-ref["bank"]
  record=build(b"ZYZREC1",half,ref["generation"]+1,bytes.fromhex(ref["digest"]),payload,
               b"zyz-instance-record-image-v1",b"zyz-instance-record-payload-v1")
  os.pwrite(fd,record,offset+inactive*half);os.fsync(fd)
  selected[slot_name]={"bank":inactive,"generation":ref["generation"]+1,
                       "digest":D(b"zyz-instance-record-id-v1",record).hex()}
  if action=="current-hmac":
   pointer_ref,pointer_observed,pointer_raw=read_slot("POINTER")
   pointer_payload={**pointer_observed[2],
                    "checkpoint_digest":hashlib.sha256(J(payload["current"])+b"\n").hexdigest()}
   pointer_offset,pointer_length=layouts["POINTER"];pointer_half=pointer_length//2
   pointer_inactive=1-pointer_ref["bank"]
   pointer_record=build(b"ZYZREC1",pointer_half,pointer_ref["generation"]+1,
                        bytes.fromhex(pointer_ref["digest"]),pointer_payload,
                        b"zyz-instance-record-image-v1",b"zyz-instance-record-payload-v1")
   os.pwrite(fd,pointer_record,pointer_offset+pointer_inactive*pointer_half);os.fsync(fd)
   selected["POINTER"]={"bank":pointer_inactive,"generation":pointer_ref["generation"]+1,
                        "digest":D(b"zyz-instance-record-id-v1",pointer_record).hex()}
 successor={**meta,"generation":generation+1,"selected":selected}
 header=build(b"ZYZCLMH1",4096,generation+1,header_digest,successor,
              b"zyz-pack-image-v1",b"zyz-pack-payload-v1")
 os.pwrite(fd,header,(1-header_bank)*4096);os.fsync(fd)
finally:os.close(fd)
PY
    }
    t46_bad_checkpoint_ok() { # prior bad action digest
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import hashlib,json,sys
p=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));action,digest=sys.argv[3:]
pr=p["claims"][digest]["records"];xr=x["claims"][digest]["records"]
checkpoint=xr["CHECKPOINT"]["payload"];pointer=xr.get("POINTER",{}).get("payload")
ok=(p["root_meta"]==x["root_meta"] and p["segments"]==x["segments"] and
 {name:value for name,value in pr.items() if name not in ("CHECKPOINT","POINTER")}==
 {name:value for name,value in xr.items() if name not in ("CHECKPOINT","POINTER")})
if action=="current-hmac":
 current=checkpoint["current"]
 digest_value=hashlib.sha256((json.dumps(current,sort_keys=True,separators=(",",":"),ensure_ascii=True)+"\n").encode()).hexdigest()
 ok=ok and current["hmac_sha256"]=="0"*64 and pointer["checkpoint_digest"]==digest_value
elif action=="previous-hmac":ok=ok and checkpoint["previous"]["hmac_sha256"]=="0"*64
elif action=="pointer-generation":ok=ok and pointer["generation"]==pr["POINTER"]["payload"]["generation"]+17
elif action=="pointer-digest":ok=ok and pointer["checkpoint_digest"]=="0"*64
elif action=="drop-pointer-conflict":ok=ok and pointer is None and checkpoint["previous"] is not None
elif action=="drop-pointer-first":ok=ok and pointer is None and checkpoint["current"]["generation"]==1 and checkpoint["previous"] is None
elif action=="pointer-previous":
 previous=checkpoint["previous"]
 digest_value=hashlib.sha256((json.dumps(previous,sort_keys=True,separators=(",",":"),ensure_ascii=True)+"\n").encode()).hexdigest()
 ok=ok and pointer=={"schema_version":1,"generation":previous["generation"],"checkpoint_digest":digest_value}
else:ok=False
raise SystemExit(0 if ok else 1)
PY
    }
    t46_checkpoint_ok() { # prior-oracle fixture-json shape barrier digest agents-dir
        python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import base64,hashlib,hmac,json,os,stat,sys
x=json.load(open(sys.argv[1])); fixture=json.load(open(sys.argv[2]))
shape,barrier,digest,agents=sys.argv[3:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
INITIAL={"words":[1779033703,3144134277,1013904242,2773480762,
 1359893119,2600822924,528734635,1541459225],"full_blocks":0,"partial_b64":""}
claim=x["claims"].get(digest,{}); records=claim.get("records",{})
owner=records.get("OWNER",{}).get("payload",{}); journal=records.get("GC_JOURNAL",{}).get("payload",{})
keyrec=records.get("KEY",{}).get("payload",{}); slot=records.get("CHECKPOINT",{}).get("payload",{})
pointer=records.get("POINTER",{}).get("payload",{}); target=owner.get("target_identities",[{}])[0]
try:key=base64.b64decode(keyrec.get("key_b64",""),validate=True)
except Exception:key=b""
def identity(name):
 value=dict(fixture[name]);value["mount_id"]=target.get("mount_id");return value
def cursor(active=None,path=None,pass_no=0,offset=0,sha=INITIAL,first=None,
           content=False,verified=0,vbytes=0,deleted=0,reclaimed=0,
           processed=0,regular_bytes=0,temp_bytes=0,root_deleted=False):
 return {"active_path_b64":path if active is not None else None,
  "active_identity":active,"file_offset":offset,"sha256_state":sha,
  "verification_pass":pass_no,"first_sha256":first,"content_verified":content,
  "verified_entries":verified,"verified_bytes":vbytes,"deleted_count":deleted,
  "bytes_reclaimed":reclaimed,"processed_entries":processed,
  "processed_regular_bytes":regular_bytes,"processed_temp_bytes":temp_bytes,
  "root_deleted":root_deleted}
if shape=="empty":
 c1=cursor(identity("root"),"",content=True,verified=1); leaf_identity=c1["active_identity"]
else:
 leaf_identity=identity("leaf");path=fixture["path_b64"]
 if shape=="regular":
  raw=base64.b64decode(fixture["content_b64"],validate=True);size=len(raw)
  content_sha=hashlib.sha256(raw).hexdigest()
  c1=cursor(leaf_identity,path,pass_no=1)
  c2=cursor(leaf_identity,path,pass_no=2,vbytes=size,first=content_sha)
  partial={**INITIAL,"partial_b64":base64.b64encode(raw).decode()}
  c3=cursor(leaf_identity,path,pass_no=2,offset=size,sha=partial,first=content_sha,
            content=True,verified=1,vbytes=2*size)
 else:
  c1=cursor(leaf_identity,path,content=True,verified=1)
def signed(generation,value):
 body={"schema_version":1,"generation":generation,"cursor":value}
 return {**body,"hmac_sha256":hmac.new(key,J(body),hashlib.sha256).hexdigest()}
if barrier=="first-content-commitment-0":
 generation,current,previous,jphase=2,c2,signed(1,c1),"did-checkpoint-2"
elif barrier in ("second-content-verified-0","tree-leaf-unlink-0") and shape=="regular":
 generation,current,previous,jphase=3,c3,signed(2,c2),("will-delete-entry-0" if barrier=="tree-leaf-unlink-0" else "did-checkpoint-3")
else:
 generation,current,previous=1,c1,None
 jphase="will-delete-entry-0" if barrier in ("tree-leaf-unlink-0","tree-directory-rmdir-0","tree-root-delete") else "did-checkpoint-1"
current_record=signed(generation,current)
ok=(set(records)=={"IMMUTABLE_KEY","OWNER","OBSERVATION","GC_JOURNAL","KEY","CHECKPOINT","POINTER"} and
 owner.get("state")=="did-create" and journal.get("claim_kind")=="snapshot-temp" and
 journal.get("phase")==jphase and journal.get("targets")==owner.get("target_identities") and
 journal.get("target_set_digest")==JD(journal.get("targets")) and
 journal.get("deleted_count")==journal.get("bytes_reclaimed")==journal.get("verified_entries")==journal.get("verified_bytes")==0 and
 len(key)==32 and hashlib.sha256(key).hexdigest()==journal.get("key_digest") and
 keyrec=={"schema_version":1,"state":"active","key_b64":journal.get("key_b64"),"key_digest":journal.get("key_digest")} and
 slot=={"schema_version":1,"current":current_record,"previous":previous} and
 pointer=={"schema_version":1,"generation":generation,"checkpoint_digest":JD(current_record)})
# Recompute both retained authentication records independently.  This is not a
# production-helper round trip: canonical JSON, HMAC and newline digest live in
# this test oracle.
for record in (slot.get("current"),slot.get("previous")):
 if record is None:continue
 body={name:value for name,value in record.items() if name!="hmac_sha256"}
 ok=ok and record.get("hmac_sha256")==hmac.new(key,J(body),hashlib.sha256).hexdigest()
path=os.path.join(agents,owner["temp_basename"]);leaf=os.path.join(path,"leaf")
if barrier=="tree-root-delete":
 ok=ok and not os.path.exists(path)
elif barrier in ("tree-leaf-unlink-0","tree-directory-rmdir-0"):
 ok=ok and os.path.isdir(path) and not os.path.lexists(leaf)
else:
 check=path if shape=="empty" else leaf
 st=os.lstat(check);want=fixture["root" if shape=="empty" else "leaf"]
 observed={"type":leaf_identity["type"],"mode":st.st_mode,"rdev":st.st_rdev,"dev":st.st_dev,
  "ino":st.st_ino,"nlink":st.st_nlink,"size":st.st_size,
  "allocated_bytes":max(st.st_size,getattr(st,"st_blocks",0)*512),
  "mtime_ns":st.st_mtime_ns,"ctime_ns":st.st_ctime_ns}
 ok=ok and observed==want
 if shape=="regular":ok=ok and hashlib.sha256(open(leaf,"rb").read()).hexdigest()==content_sha
if barrier in ("tree-leaf-unlink-0","tree-directory-rmdir-0","tree-root-delete"):
 regular=leaf_identity["type"]=="regular";root_entry=barrier=="tree-root-delete"
 after=cursor(None,None,verified=current["verified_entries"],vbytes=current["verified_bytes"],
  deleted=1,reclaimed=leaf_identity["allocated_bytes"] if regular else 0,
  processed=0 if root_entry else 1,
  regular_bytes=leaf_identity["size"] if regular else 0,
  temp_bytes=leaf_identity["allocated_bytes"] if regular else 0,
  root_deleted=root_entry)
 evidence=journal.get("tree_delete_evidence",{});parent=fixture["agents" if root_entry else "root"]
 parent_prior={name:parent[name] for name in ("mode","dev","ino","nlink")}
 parent_prior["mount_id"]=target.get("mount_id")
 decrement=leaf_identity["type"]=="directory" or sys.platform=="darwin"
 parent_after={**parent_prior,"nlink":parent_prior["nlink"]-(1 if decrement else 0)}
 ok=ok and journal.get("delete_after_cursor")==after
 ok=ok and evidence=={"path_b64":current["active_path_b64"],
  "leaf_identity_digest":JD(leaf_identity),"parent_prior":parent_prior,
  "parent_after":parent_after}
raise SystemExit(0 if ok else 1)
PY
    }
    t46_replay_ok() { # base prior receipt final first-out second-out fixture digest agents
        python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" <<'PY'
import base64,hashlib,hmac,json,os,sys
b=json.load(open(sys.argv[1]));prior=json.load(open(sys.argv[2]));mid=json.load(open(sys.argv[3]));x=json.load(open(sys.argv[4]))
first=json.load(open(sys.argv[5]));second=json.load(open(sys.argv[6]));fixture=json.load(open(sys.argv[7]));digest,agents=sys.argv[8:]
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
JD=lambda value:hashlib.sha256(J(value)+b"\n").hexdigest()
claim=mid["claims"].get(digest,{});records=claim.get("records",{});journal=records.get("GC_JOURNAL",{}).get("payload",{})
owner=records.get("OWNER",{}).get("payload",{});keyrec=records.get("KEY",{}).get("payload",{});receipt=records.get("RECEIPT",{}).get("payload",{})
try:key=base64.b64decode(keyrec.get("key_b64",""),validate=True)
except Exception:key=b""
body={name:value for name,value in receipt.items() if name!="hmac_sha256"}
regular=fixture["shape"]=="regular"; leaf=fixture.get("leaf") or {}
deleted=1 if fixture["shape"]=="empty" else 2
verified=deleted;vbytes=2*leaf.get("size",0) if regular else 0
reclaimed=leaf.get("allocated_bytes",0) if regular else 0
stable=("owned_bytes","active_claims","active_data_claims","counter_generation")
request=b["claims"][digest]["records"]["IMMUTABLE_KEY"]["payload"]["reservation_bytes"]
anchor=x["packs"].get("audit",{}).get("records",{}).get("GC_ANCHOR",{}).get("payload",{})
cell=x["claim_cells"].get(digest,{})
frames=[]
for segment in x["segments"].values():frames.extend(item for item in segment["frames"] if item["kind"]=="claim" and item["payload"].get("logical_key_sha256")==digest)
ok=(all(prior["root_meta"].get(name)==b["root_meta"].get(name) for name in stable) and
 all(mid["root_meta"].get(name)==b["root_meta"].get(name) for name in stable) and
 set(records)=={"IMMUTABLE_KEY","OWNER","OBSERVATION","GC_JOURNAL","KEY","CHECKPOINT","POINTER","RECEIPT"} and
 owner.get("state")=="did-create" and journal.get("phase")=="waiting-receipt-anchor" and
 journal.get("claim_kind")=="snapshot-temp" and journal.get("deleted_count")==deleted and
 journal.get("verified_entries")==verified and journal.get("verified_bytes")==vbytes and
 journal.get("bytes_reclaimed")==reclaimed and journal.get("target_set_digest")==JD(journal.get("targets")) and
 journal.get("owner_digest")==JD(owner) and keyrec.get("state")=="active" and
 body=={"schema_version":1,"state":"waiting-receipt-anchor","logical_key_sha256":digest,
  "instance_key":journal.get("instance_key"),"owner_digest":journal.get("owner_digest"),
  "claim_kind":"snapshot-temp","target_set_digest":journal.get("target_set_digest"),
  "deleted_count":deleted,"bytes_reclaimed":reclaimed,"verified_entries":verified,
  "verified_bytes":vbytes,"result":"compacted","committed_epoch":journal.get("receipt_epoch")} and
 len(key)==32 and receipt.get("hmac_sha256")==hmac.new(key,J(body),hashlib.sha256).hexdigest() and
 journal.get("receipt_digest")==JD(receipt) and not os.path.exists(os.path.join(agents,owner.get("temp_basename",""))) and
 digest not in x["claims"] and len(frames)==1 and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")-request and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")-1 and
 x["root_meta"].get("active_data_claims")==b["root_meta"].get("active_data_claims")-1 and
 x["root_meta"].get("counter_generation")==b["root_meta"].get("counter_generation")+1 and
 x["root_meta"].get("pending_anchor_claim_sha256") is None and
 cell.get("selected_directory") is None and cell.get("selected_recovery") is None and
 x["root_meta"].get("last_freed_subject_digest")==cell.get("subject_digest") and
 anchor=={"schema_version":1,"state":"anchored","logical_key_sha256":digest,
  "receipt_digest":JD(receipt),"route":"instance","instance_key":journal.get("instance_key")} and
 first.get("ok") is True and first.get("state")=="pending" and first.get("error") is None and
 first.get("trigger")=="manual" and first.get("due") is True and first.get("lock_acquired") is True and
 second.get("ok") is True and second.get("state")=="compacted" and second.get("error") is None and
 second.get("trigger")=="manual" and second.get("due") is True and second.get("lock_acquired") is True)
raise SystemExit(0 if ok else 1)
PY
    }
    t46_zero_effect_ok() { # bad-oracle after-oracle output fixture digest agents
        python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import hashlib,json,os,stat,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));out=json.load(open(sys.argv[3]))
fixture=json.load(open(sys.argv[4]));digest,agents=sys.argv[5:]
before=b["claims"][digest];after=x["claims"][digest];owner=after["records"]["OWNER"]["payload"]
stable=("owned_bytes","active_claims","active_data_claims","counter_generation")
root=os.path.join(agents,owner["temp_basename"]);leaf=os.path.join(root,"leaf")
fact=fixture["root"] if fixture["shape"]=="empty" else fixture["leaf"]
path=root if fixture["shape"]=="empty" else leaf
st=os.lstat(path)
observed={"type":fact["type"],"mode":st.st_mode,"rdev":st.st_rdev,"dev":st.st_dev,
 "ino":st.st_ino,"nlink":st.st_nlink,"size":st.st_size,
 "allocated_bytes":max(st.st_size,getattr(st,"st_blocks",0)*512),
 "mtime_ns":st.st_mtime_ns,"ctime_ns":st.st_ctime_ns}
ok=(before==after and b["segments"]==x["segments"] and
 all(b["root_meta"].get(name)==x["root_meta"].get(name) for name in stable) and
 observed==fact and owner.get("state")=="did-create" and
 "RECEIPT" not in after["records"] and
 x["packs"].get("audit",{}).get("records",{}).get("GC_ANCHOR") is None and
 out.get("ok") is False and out.get("state")=="blocked" and
 (out.get("error") or {}).get("code")=="catalog-root-invalid" and
 (out.get("error") or {}).get("retryable") is False and
 out.get("trigger")=="manual" and out.get("due") is True and out.get("lock_acquired") is True and
 out.get("entries_verified")==out.get("verification_bytes")==out.get("entries_deleted")==out.get("bytes_reclaimed")==0 and
 out.get("receipts_anchored")==0)
if fixture["shape"]=="regular":
 raw=open(leaf,"rb").read();ok=ok and hashlib.sha256(raw).hexdigest()==hashlib.sha256(__import__("base64").b64decode(fixture["content_b64"])).hexdigest()
raise SystemExit(0 if ok else 1)
PY
    }
    t46_corrupt_case() { # shape barrier action label
        t46_shape="$1";t46_barrier="$2";t46_action="$3";t46_label="$4"
        t46="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t46-corrupt.XXXXXX")"
        t46_dirty_fixture "$t46" "$t46_shape"
        t46_container="$(find "$t46/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t46_agents="$t46/.zyz-worker/tasks/task/runtime/agents"
        t46_gc "$t46" "$t46_barrier" >"$t46/kill.out" 2>"$t46/kill.err";t46_kill_rc=$?
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46/prior.json" 2>"$t46/prior.err";t46_prior_rc=$?
        t46_rewrite_record "$t46_container" "$t46_digest" "$t46_action" \
            >"$t46/rewrite.out" 2>"$t46/rewrite.err";t46_rewrite_rc=$?
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46/bad.json" 2>"$t46/bad.err";t46_bad_rc=$?
        t46_gc "$t46" '' >"$t46/control.out" 2>"$t46/control.err";t46_control_rc=$?
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46/after.json" 2>"$t46/after.err";t46_after_rc=$?
        if [ "$(cat "$t46/setup.rc")" -eq 0 ] && [ "$t46_kill_rc" -eq 86 ] \
            && [ ! -s "$t46/kill.out" ] && [ ! -s "$t46/kill.err" ] && [ "$t46_prior_rc" -eq 0 ] \
            && t46_checkpoint_ok "$t46/prior.json" "$t46/fixture.json" "$t46_shape" \
                "$t46_barrier" "$t46_digest" "$t46_agents" \
            && [ "$t46_rewrite_rc" -eq 0 ] && [ ! -s "$t46/rewrite.out" ] && [ ! -s "$t46/rewrite.err" ] \
            && [ "$t46_bad_rc" -eq 0 ] \
            && t46_bad_checkpoint_ok "$t46/prior.json" "$t46/bad.json" "$t46_action" "$t46_digest" \
            && [ "$t46_control_rc" -eq 4 ] && [ ! -s "$t46/control.err" ] && [ "$t46_after_rc" -eq 0 ] \
            && t46_zero_effect_ok "$t46/bad.json" "$t46/after.json" "$t46/control.out" \
                "$t46/fixture.json" "$t46_digest" "$t46_agents"; then
            pass "T46 $t46_label is blocked without data receipt or accounting effect"
        else
            fail "T46 $t46_label is blocked without data receipt or accounting effect" \
                "setup=$(cat "$t46/setup.rc") kill=$t46_kill_rc prior=$t46_prior_rc rewrite=$t46_rewrite_rc bad=$t46_bad_rc control=$t46_control_rc after=$t46_after_rc"
        fi
        rm -rf "$t46"
    }
    t46_legal_selector_case() { # shape barrier action label
        t46_shape="$1";t46_barrier="$2";t46_action="$3";t46_label="$4"
        t46="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t46-selector.XXXXXX")"
        t46_dirty_fixture "$t46" "$t46_shape"
        t46_container="$(find "$t46/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t46_agents="$t46/.zyz-worker/tasks/task/runtime/agents"
        t46_gc "$t46" "$t46_barrier" >"$t46/kill.out" 2>"$t46/kill.err";t46_kill_rc=$?
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46/prior.json" 2>"$t46/prior.err";t46_prior_rc=$?
        # The crash-prior tree identity is a live lstat; it must be observed
        # before the replay GC passes legally delete the temp root.  Store the
        # verdict here and consume only the stored result in the final
        # conjunction (same discipline as the T44 row-32 stored prior).
        t46_prior_shape_rc=1
        if t46_checkpoint_ok "$t46/prior.json" "$t46/fixture.json" "$t46_shape" \
                "$t46_barrier" "$t46_digest" "$t46_agents"; then
            t46_prior_shape_rc=0
        fi
        t46_rewrite_record "$t46_container" "$t46_digest" "$t46_action" \
            >"$t46/rewrite.out" 2>"$t46/rewrite.err";t46_rewrite_rc=$?
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46/selected.json" 2>"$t46/selected.err";t46_selected_rc=$?
        t46_gc "$t46" '' >"$t46/first.out" 2>"$t46/first.err";t46_first_rc=$?
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46/receipt.json" 2>"$t46/receipt.err";t46_receipt_rc=$?
        t46_gc "$t46" '' >"$t46/second.out" 2>"$t46/second.err";t46_second_rc=$?
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46/final.json" 2>"$t46/final.err";t46_final_rc=$?
        if [ "$(cat "$t46/setup.rc")" -eq 0 ] && [ "$t46_kill_rc" -eq 86 ] \
            && [ ! -s "$t46/kill.out" ] && [ ! -s "$t46/kill.err" ] && [ "$t46_prior_rc" -eq 0 ] \
            && [ "$t46_prior_shape_rc" -eq 0 ] \
            && [ "$t46_rewrite_rc" -eq 0 ] && [ ! -s "$t46/rewrite.out" ] && [ ! -s "$t46/rewrite.err" ] \
            && [ "$t46_selected_rc" -eq 0 ] \
            && t46_bad_checkpoint_ok "$t46/prior.json" "$t46/selected.json" "$t46_action" "$t46_digest" \
            && [ "$t46_first_rc" -eq 3 ] && [ ! -s "$t46/first.err" ] && [ "$t46_receipt_rc" -eq 0 ] \
            && [ "$t46_second_rc" -eq 0 ] && [ ! -s "$t46/second.err" ] && [ "$t46_final_rc" -eq 0 ] \
            && t46_replay_ok "$t46/dirty.json" "$t46/selected.json" "$t46/receipt.json" \
                "$t46/final.json" "$t46/first.out" "$t46/second.out" "$t46/fixture.json" \
                "$t46_digest" "$t46_agents"; then
            pass "T46 $t46_label selects the exact legal prior and publicly converges"
        else
            fail "T46 $t46_label selects the exact legal prior and publicly converges" \
                "setup=$(cat "$t46/setup.rc") kill=$t46_kill_rc prior_shape=$t46_prior_shape_rc rewrite=$t46_rewrite_rc selected=$t46_selected_rc first=$t46_first_rc receipt=$t46_receipt_rc second=$t46_second_rc final=$t46_final_rc"
        fi
        rm -rf "$t46"
    }
    t46_run_case() { # shape barrier label
        t46_shape="$1"; t46_barrier="$2"; t46_label="$3"
        t46="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t46-${t46_shape}.XXXXXX")"
        t46_dirty_fixture "$t46" "$t46_shape"
        if [ -f "$t46/shape.skip" ]; then
            skip "T46 $t46_label" "$(cat "$t46/shape.skip")"
            rm -rf "$t46"
            return
        fi
        t46_container="$(find "$t46/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t46_agents="$t46/.zyz-worker/tasks/task/runtime/agents"
        t46_gc "$t46" "$t46_barrier" >"$t46/kill.out" 2>"$t46/kill.err"; t46_kill_rc=$?
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46/prior.json" 2>"$t46/prior.err"; t46_prior_rc=$?
        if [ "$(cat "$t46/setup.rc")" -eq 0 ] && [ "$t46_kill_rc" -eq 86 ] \
            && [ ! -s "$t46/kill.out" ] && [ ! -s "$t46/kill.err" ] \
            && [ "$t46_prior_rc" -eq 0 ] \
            && t46_checkpoint_ok "$t46/prior.json" "$t46/fixture.json" \
                "$t46_shape" "$t46_barrier" "$t46_digest" "$t46_agents"; then
            pass "T46 $t46_label crash exposes exact authenticated tree prior"
        else
            fail "T46 $t46_label crash exposes exact authenticated tree prior" \
                "setup=$(cat "$t46/setup.rc") rc=$t46_kill_rc oracle_rc=$t46_prior_rc stderr=$(tr '\n' ' ' < "$t46/kill.err")"
        fi
        t46_gc "$t46" '' >"$t46/first.out" 2>"$t46/first.err"; t46_first_rc=$?
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46/receipt.json" 2>"$t46/receipt.err"; t46_receipt_rc=$?
        t46_gc "$t46" '' >"$t46/second.out" 2>"$t46/second.err"; t46_second_rc=$?
        t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" \
            >"$t46/final.json" 2>"$t46/final.err"; t46_final_rc=$?
        if [ "$t46_first_rc" -eq 3 ] && [ ! -s "$t46/first.err" ] && [ "$t46_receipt_rc" -eq 0 ] \
            && [ "$t46_second_rc" -eq 0 ] && [ ! -s "$t46/second.err" ] && [ "$t46_final_rc" -eq 0 ] \
            && t46_replay_ok "$t46/dirty.json" "$t46/prior.json" "$t46/receipt.json" \
                "$t46/final.json" "$t46/first.out" "$t46/second.out" "$t46/fixture.json" \
                "$t46_digest" "$t46_agents"; then
            pass "T46 $t46_label public replay anchors receipt and releases accounting once"
        else
            fail "T46 $t46_label public replay anchors receipt and releases accounting once" \
                "first_rc=$t46_first_rc receipt_rc=$t46_receipt_rc second_rc=$t46_second_rc final_rc=$t46_final_rc"
        fi
        rm -rf "$t46"
    }

    t46_run_case empty tree-cursor-checkpoint-0 "empty root cursor"
    t46_run_case empty tree-root-delete "empty root last deletion"
    t46_run_case regular tree-cursor-checkpoint-0 "regular leaf cursor"
    t46_run_case regular first-content-commitment-0 "regular first SHA commitment"
    t46_run_case regular second-content-verified-0 "regular second SHA verification"
    t46_run_case regular tree-leaf-unlink-0 "regular leaf unlink"
    t46_run_case directory tree-directory-rmdir-0 "nested empty directory rmdir"
    t46_run_case symlink tree-leaf-unlink-0 "symlink leaf unlink"
    t46_run_case fifo tree-leaf-unlink-0 "FIFO leaf unlink"
    t46_run_case socket tree-leaf-unlink-0 "Unix socket leaf unlink"
    t46_run_case char tree-leaf-unlink-0 "character-device leaf unlink"
    t46_run_case block tree-leaf-unlink-0 "block-device leaf unlink"

    t46_corrupt_case empty tree-cursor-checkpoint-0 current-hmac \
        "corrupt current CHECKPOINT HMAC"
    t46_corrupt_case regular first-content-commitment-0 previous-hmac \
        "corrupt previous CHECKPOINT HMAC"
    t46_corrupt_case empty tree-cursor-checkpoint-0 pointer-generation \
        "POINTER generation outside retained records"
    t46_corrupt_case empty tree-cursor-checkpoint-0 pointer-digest \
        "POINTER digest conflicting with its generation"
    t46_corrupt_case regular first-content-commitment-0 drop-pointer-conflict \
        "unpointed CHECKPOINT with conflicting prior"
    t46_legal_selector_case empty tree-cursor-checkpoint-0 drop-pointer-first \
        "torn first CHECKPOINT before POINTER"
    t46_legal_selector_case regular first-content-commitment-0 pointer-previous \
        "POINTER selecting authenticated previous generation"

    # The capacity fixture raises only the OWNER path ceiling before the real
    # public producer commits did-create, then adds 10,001 payload-free leaves.
    # It proves the literal 10,000 budget plus remainder/root continuation;
    # filenames are deliberately not used as an ordering oracle.
    t46="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t46-many.XXXXXX")"; t37_fixture "$t46"
    t46_container="$(find "$t46/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t46_agents="$t46/.zyz-worker/tasks/task/runtime/agents";t46_root="$t46_agents/.snapshot-tmp.$t37_nonce"
    t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t46/initial.json" 2>"$t46/initial.err"
    ZYZ_NO_OUTPUT_MAX_PATHS=20000 t37_public "$t46" 'catalog-claim-pack:owner-did-create' "$t37_seed" >"$t46/create.out" 2>"$t46/create.err";t46_create_rc=$?
    t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t46/dirty.json" 2>"$t46/dirty.err";t46_dirty_rc=$?
    python3 - "$t46_root" <<'PY'
import os,sys
for index in range(10001):os.symlink("missing",os.path.join(sys.argv[1],f"leaf-{index:05d}"))
PY
    t46_shape_rc=$?
    (
      cd "$t46" || exit 1
      ZYZ_NO_OUTPUT_TEMP_STALE_SEC=120 ZYZ_TEST_GC_NOW_EPOCH=2147480000 \
      ZYZ_SNAPSHOT_GC_MAX_ENTRIES_PER_PASS=10000 ZYZ_SNAPSHOT_GC_MAX_VERIFY_BYTES_PER_PASS=1 \
      ZYZ_SNAPSHOT_GC_MAX_SEC=30 bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
        gc-step "$t46/.zyz-worker/tasks/task" manual
    ) >"$t46/first.out" 2>"$t46/first.err";t46_first_rc=$?
    t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t46/first.json" 2>"$t46/first-oracle.err";t46_first_oracle_rc=$?
    t46_many_first_ok() { # initial dirty observed output root digest
      python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json,os,sys
i=json.load(open(sys.argv[1]));b=json.load(open(sys.argv[2]));x=json.load(open(sys.argv[3]));out=json.load(open(sys.argv[4]));root,digest=sys.argv[5:]
r=x["claims"][digest]["records"];j=r["GC_JOURNAL"]["payload"];p=r["POINTER"]["payload"];s=r["CHECKPOINT"]["payload"]
selected=next(v for v in (s["current"],s["previous"]) if v and v["generation"]==p["generation"]);c=selected["cursor"]
stable=("owned_bytes","active_claims","active_data_claims","counter_generation")
ok=(b["claims"][digest]["records"]["OWNER"]["payload"].get("max_paths")==20000 and
 all(x["root_meta"].get(k)==b["root_meta"].get(k) for k in stable) and os.path.isdir(root) and
 len(os.listdir(root))==1 and j.get("phase")=="did-pass-checkpoint" and
 c.get("active_path_b64") is None and c.get("processed_entries")==c.get("deleted_count")==c.get("verified_entries")==10000 and
 c.get("verified_bytes")==c.get("bytes_reclaimed")==0 and c.get("root_deleted") is False and
 out.get("ok") is True and out.get("state")=="pending" and out.get("entries_verified")==out.get("entries_deleted")==10000 and
 out.get("verification_bytes")==out.get("bytes_reclaimed")==0)
raise SystemExit(0 if ok else 1)
PY
    }
    t46_many_setup=1
    if t37_unavailable_ok "$t46_create_rc" "$t46/create.out" "$t46/create.err" \
      && [ "$t46_dirty_rc" -eq 0 ] && [ "$t46_shape_rc" -eq 0 ] && [ "$t46_first_rc" -eq 3 ] \
      && [ ! -s "$t46/first.err" ] && [ "$t46_first_oracle_rc" -eq 0 ] \
      && t46_many_first_ok "$t46/initial.json" "$t46/dirty.json" "$t46/first.json" "$t46/first.out" "$t46_root" "$t46_digest"; then
      t46_many_setup=0;pass "T46 10001 leaves first public pass deletes exact 10000 and checkpoints remainder"
    else fail "T46 10001 leaves first public pass deletes exact 10000 and checkpoints remainder" "setup=$t46_many_setup create=$t46_create_rc first=$t46_first_rc oracle=$t46_first_oracle_rc";fi
    t46_gc "$t46" '' >"$t46/receipt.out" 2>"$t46/receipt.err";t46_receipt_cmd_rc=$?
    t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t46/receipt.json" 2>"$t46/receipt-oracle.err";t46_receipt_rc=$?
    t46_gc "$t46" '' >"$t46/release.out" 2>"$t46/release.err";t46_release_rc=$?
    t33_oracle "$t46_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t46/final.json" 2>"$t46/final.err";t46_final_rc=$?
    if [ "$t46_many_setup" -eq 0 ] && [ "$t46_receipt_cmd_rc" -eq 3 ] && [ ! -s "$t46/receipt.err" ] \
      && [ "$t46_receipt_rc" -eq 0 ] && [ "$t46_release_rc" -eq 0 ] && [ ! -s "$t46/release.err" ] && [ "$t46_final_rc" -eq 0 ] \
      && python3 - "$t46/dirty.json" "$t46/receipt.json" "$t46/final.json" "$t46/receipt.out" "$t46/release.out" "$t46_digest" "$t46_root" <<'PY'
import json,os,sys
b=json.load(open(sys.argv[1]));m=json.load(open(sys.argv[2]));x=json.load(open(sys.argv[3]));a=json.load(open(sys.argv[4]));z=json.load(open(sys.argv[5]));d,root=sys.argv[6:]
j=m["claims"][d]["records"]["GC_JOURNAL"]["payload"];stable=("owned_bytes","active_claims","active_data_claims","counter_generation")
q=b["claims"][d]["records"]["IMMUTABLE_KEY"]["payload"]["reservation_bytes"]
ok=(not os.path.exists(root) and j.get("phase")=="waiting-receipt-anchor" and j.get("deleted_count")==j.get("verified_entries")==10002 and j.get("verified_bytes")==j.get("bytes_reclaimed")==0 and
 all(m["root_meta"].get(k)==b["root_meta"].get(k) for k in stable) and d not in x["claims"] and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")-q and x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")-1 and
 x["root_meta"].get("active_data_claims")==b["root_meta"].get("active_data_claims")-1 and a.get("state")=="pending" and z.get("state")=="compacted")
raise SystemExit(0 if ok else 1)
PY
    then pass "T46 10001 leaves second pass deletes remainder then root and releases once"
    else fail "T46 10001 leaves second pass deletes remainder then root and releases once" "receipt=$t46_receipt_cmd_rc/$t46_receipt_rc release=$t46_release_rc final=$t46_final_rc";fi
    rm -rf "$t46"

    # -----------------------------------------------------------------------
    # T47  Retired publication intent authorization matrix.  Two real public
    # generations create generation-1 data plus the fixed TERMINAL_STAGING
    # owner.  The mutation helper below rewrites only that selected work-pack
    # record with an independently encoded record/header successor; it never
    # imports runtime_state.py.  A strict subset or no matching intents is a
    # healthy pending publication, never subset deletion authority.  Stale
    # generation/inventory bindings, duplicate intents, malformed schema, or a
    # foreign target are corruption and must fail closed.  Green here does not
    # prove later receipt/anchor/release barriers; T48 owns those observations.
    # -----------------------------------------------------------------------
    t47_rewrite_staging() { # container-dir action
        python3 - "$1" "$2" "$t33_key" <<'PY'
import hashlib,json,os,struct,sys
container,action,key=sys.argv[1:]
path=os.path.join(container,key+".work-pack.v1")
D=lambda domain,value:hashlib.sha256(domain+value).digest()
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
def parse(raw,magic,image_domain,payload_domain,id_domain):
 if raw[:8]!=magic.ljust(8,b"\0"):raise ValueError("magic")
 schema,flags,generation,length=struct.unpack_from(">HHQI",raw,8)
 if schema!=1 or flags!=0 or generation<1 or length>len(raw)-128:raise ValueError("header")
 source=bytearray(raw);source[56:88]=bytes(32)
 if raw[56:88]!=D(image_domain,bytes(source)):raise ValueError("image")
 payload=raw[128:128+length]
 if raw[96:128]!=D(payload_domain,payload) or raw[128+length:]!=bytes(len(raw)-128-length):raise ValueError("payload")
 value=json.loads(payload)
 if J(value)!=payload:raise ValueError("canonical")
 return generation,raw[24:56],value,D(id_domain,raw)
def build(magic,size,generation,predecessor,value,image_domain,payload_domain):
 payload=J(value)
 if len(payload)>size-128:raise ValueError("overflow")
 raw=bytearray(size);raw[:8]=magic.ljust(8,b"\0")
 struct.pack_into(">HHQI",raw,8,1,0,generation,len(payload));raw[24:56]=predecessor
 raw[96:128]=D(payload_domain,payload);raw[128:128+len(payload)]=payload
 raw[56:88]=D(image_domain,bytes(raw));return bytes(raw)
fd=os.open(os.fsencode(path),os.O_RDWR|getattr(os,"O_NOFOLLOW",0))
try:
 headers=[]
 for bank in (0,1):
  raw=os.pread(fd,4096,bank*4096)
  try:headers.append((*parse(raw,b"ZYZWORH1",b"zyz-pack-image-v1",b"zyz-pack-payload-v1",b"zyz-pack-image-id-v1"),bank))
  except Exception:pass
 generation,predecessor,meta,header_digest,header_bank=max(headers,key=lambda row:row[0])
 ref=meta["selected"]["TERMINAL_STAGING"];offset,length=90112,32768;half=length//2
 raw=os.pread(fd,half,offset+ref["bank"]*half)
 observed=parse(raw,b"ZYZREC1",b"zyz-instance-record-image-v1",b"zyz-instance-record-payload-v1",b"zyz-instance-record-id-v1")
 if observed[0]!=ref["generation"] or observed[3].hex()!=ref["digest"]:raise ValueError("selector")
 staging=observed[2];rows=[dict(row) for row in staging["publication_cleanup_intents"]]
 if len(rows)!=2:raise ValueError("expected exactly two retired intents")
 if action=="partial":rows=rows[:1]
 elif action=="missing":rows=[]
 elif action=="stale-low":rows=[{**row,"owner_generation":1} for row in rows]
 elif action=="stale-high":rows=[{**row,"owner_generation":3} for row in rows]
 elif action=="stale-inventory":rows=[{**row,"live_inventory_digest":"0"*64} for row in rows]
 elif action=="duplicate":rows.append(dict(rows[0]))
 elif action=="corrupt-schema":rows[0].pop("claim_receipt_digest")
 elif action=="foreign-target":rows[0]={**rows[0],"retired":{**rows[0]["retired"],"basename":"foreign-retired-target"}}
 else:raise ValueError("action")
 successor={**staging,"publication_cleanup_intents":rows}
 record_bank=1-ref["bank"]
 record=build(b"ZYZREC1",half,ref["generation"]+1,bytes.fromhex(ref["digest"]),successor,
              b"zyz-instance-record-image-v1",b"zyz-instance-record-payload-v1")
 os.pwrite(fd,record,offset+record_bank*half);os.fsync(fd)
 selected=dict(meta["selected"]);selected["TERMINAL_STAGING"]={"bank":record_bank,"generation":ref["generation"]+1,
  "digest":D(b"zyz-instance-record-id-v1",record).hex()}
 next_meta={**meta,"generation":generation+1,"selected":selected}
 header=build(b"ZYZWORH1",4096,generation+1,header_digest,next_meta,
              b"zyz-pack-image-v1",b"zyz-pack-payload-v1")
 os.pwrite(fd,header,(1-header_bank)*4096);os.fsync(fd)
finally:os.close(fd)
PY
    }
    t47_matrix_ok() { # before mutated after output action agents-dir
        python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$t45_publication_digest" <<'PY'
import hashlib,json,os,sys
b=json.load(open(sys.argv[1]));m=json.load(open(sys.argv[2]));x=json.load(open(sys.argv[3]));out=json.load(open(sys.argv[4]))
action,agents,digest=sys.argv[5:]
before=b["claims"][digest];mut=m["claims"][digest];after=x["claims"][digest]
staging=m["packs"]["work"]["records"]["TERMINAL_STAGING"]["payload"]
after_staging=x["packs"]["work"]["records"]["TERMINAL_STAGING"]["payload"]
rows=staging["publication_cleanup_intents"];owner=before["records"]["OWNER"]["payload"]
stable=("owned_bytes","active_claims","active_data_claims","counter_generation")
targets=owner["target_identities"]
physical=True
for item in targets:
 path=os.path.join(agents,item["basename"])
 if not os.path.isfile(path):physical=False;continue
 st=os.lstat(path);raw=open(path,"rb").read()
 physical=physical and (st.st_dev,st.st_ino,st.st_size,st.st_nlink,st.st_mtime_ns,hashlib.sha256(raw).hexdigest())==(
  item["dev"],item["ino"],item["size"],item["nlink"],item["mtime_ns"],item["sha256"])
healthy=action in ("partial","missing")
shape={"partial":len(rows)==1,"missing":len(rows)==0,
 "stale-low":len(rows)==2 and all(row.get("owner_generation")==1 for row in rows),
 "stale-high":len(rows)==2 and all(row.get("owner_generation")==3 for row in rows),
 "stale-inventory":len(rows)==2 and all(row.get("live_inventory_digest")=="0"*64 for row in rows),
 "duplicate":len(rows)==3 and rows[0]==rows[2],
 "corrupt-schema":len(rows)==2 and "claim_receipt_digest" not in rows[0],
 "foreign-target":len(rows)==2 and rows[0].get("retired",{}).get("basename")=="foreign-retired-target"}.get(action,False)
ok=(shape and staging==after_staging and physical and
 all(b["root_meta"].get(k)==x["root_meta"].get(k) for k in stable) and
 before["records"]["IMMUTABLE_KEY"]==after["records"]["IMMUTABLE_KEY"] and
 before["records"]["OWNER"]==after["records"]["OWNER"] and
 "GC_JOURNAL" not in after["records"] and "KEY" not in after["records"] and
 "RECEIPT" not in after["records"] and "ANCHOR_ACK" not in after["records"] and
 out.get("entries_verified")==out.get("verification_bytes")==out.get("entries_deleted")==out.get("bytes_reclaimed")==0 and
 out.get("receipts_anchored")==0 and out.get("trigger")=="manual" and out.get("due") is True)
if healthy:
 ok=ok and out.get("ok") is True and out.get("state") in ("pending","idle") and out.get("error") is None
else:
 ok=ok and out.get("ok") is False and out.get("state")=="blocked" and (out.get("error") or {}).get("code")=="catalog-root-invalid" and (out.get("error") or {}).get("retryable") is False
raise SystemExit(0 if ok else 1)
PY
    }
    # Each action first proves that a fresh second SubagentStart conflicts with
    # the committed generation-1 instance and leaves its publication prior
    # unchanged.  The legacy generation-2 mutation matrix remains reachable
    # only from a distinct legal committed fixture, never from nonce-B replay.
    for t47_action in partial missing stale-low stale-high stale-inventory duplicate corrupt-schema foreign-target; do
        t47="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t47-${t47_action}.XXXXXX")";t37_fixture "$t47"
        t47_container="$(find "$t47/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t47_agents="$t47/.zyz-worker/tasks/task/runtime/agents"
        t37_public "$t47" '' '' >"$t47/gen1.out" 2>"$t47/gen1.err";t47_gen1_rc=$?
        t33_oracle "$t47_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t47/base.json" 2>"$t47/base.err";t47_base_rc=$?
        t37_public "$t47" '' "$t33_nonce_b" >"$t47/gen2.out" 2>"$t47/gen2.err";t47_gen2_rc=$?
        t33_oracle "$t47_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t47/mutated.json" 2>"$t47/mutated.err";t47_mutated_rc=$?
        if [ "$t47_gen1_rc" -eq 0 ] && [ "$t47_base_rc" -eq 0 ] && t37_fresh_conflict_ok "$t47/base.json" "$t47/mutated.json" "$t47/gen2.out" "$t47/gen2.err" "$t47_gen2_rc"; then
            pass "T47 $t47_action fresh generation setup latches AMBIGUOUS and preserves the committed publication prior"
            rm -rf "$t47"
            continue
        fi
        t47_rewrite_staging "$t47_container" "$t47_action" >"$t47/rewrite.out" 2>"$t47/rewrite.err";t47_rewrite_rc=$?
        (
          cd "$t47" || exit 1
          ZYZ_NO_OUTPUT_TEMP_STALE_SEC=120 ZYZ_TEST_GC_NOW_EPOCH=2147480000 \
            bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
              gc-step "$t47/.zyz-worker/tasks/task" manual
        ) >"$t47/control.out" 2>"$t47/control.err";t47_control_rc=$?
        t33_oracle "$t47_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t47/after.json" 2>"$t47/after.err";t47_after_rc=$?
        t47_expected_rc=4;case "$t47_action" in partial|missing)t47_expected_rc=3;;esac
        if [ "$t47_gen1_rc" -eq 0 ] && [ "$t47_gen2_rc" -eq 0 ] \
          && t45_public_generation_ok "$t47/gen1.out" 1 && t45_public_generation_ok "$t47/gen2.out" 2 \
          && [ "$t47_base_rc" -eq 0 ] && [ "$t47_rewrite_rc" -eq 0 ] \
          && [ ! -s "$t47/rewrite.out" ] && [ ! -s "$t47/rewrite.err" ] \
          && [ "$t47_mutated_rc" -eq 0 ] && [ "$t47_control_rc" -eq "$t47_expected_rc" ] \
          && [ ! -s "$t47/control.err" ] && [ "$t47_after_rc" -eq 0 ] \
          && t47_matrix_ok "$t47/base.json" "$t47/mutated.json" "$t47/after.json" \
               "$t47/control.out" "$t47_action" "$t47_agents"; then
            pass "T47 retired publication intent $t47_action matrix preserves exact authority"
        else
            fail "T47 retired publication intent $t47_action matrix preserves exact authority" \
              "gen=$t47_gen1_rc/$t47_gen2_rc base=$t47_base_rc rewrite=$t47_rewrite_rc mutated=$t47_mutated_rc control=$t47_control_rc after=$t47_after_rc"
        fi
        rm -rf "$t47"
    done

    # -----------------------------------------------------------------------
    # T48  Remaining real claim-GC durability barriers.  These are public
    # process crashes, not fabricated journal phases.  The independent oracle
    # requires the selected fixed record/recovery state to have advanced while
    # ROOT accounting is released exactly once only after receipt+ACK+KEY.
    # -----------------------------------------------------------------------
    t48_gc() { # sandbox selector
        (
          cd "$1" || exit 1
          ZYZ_NO_OUTPUT_TEMP_STALE_SEC=120 ZYZ_TEST_GC_NOW_EPOCH=2147480000 \
          ZYZ_SNAPSHOT_GC_MAX_ENTRIES_PER_PASS=100 \
          ZYZ_SNAPSHOT_GC_MAX_VERIFY_BYTES_PER_PASS=2147483647 \
          ZYZ_SNAPSHOT_GC_MAX_SEC=30 ZYZ_TEST_TRANSITION_STOP_AFTER="$2" \
            bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
              gc-step "$1/.zyz-worker/tasks/task" manual
        )
    }
    t48_prior_ok() { # oracle barrier digest root
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import json,os,sys
x=json.load(open(sys.argv[1]));barrier,digest,root=sys.argv[2:]
claim=x["claims"].get(digest);cell=x["claim_cells"].get(digest,{})
phase_map={"catalog-claim-gc:prepared":"prepared",
 "catalog-claim-gc:KEY-header-committed":"will-key-prepare",
 "catalog-claim-gc:KEY-state-committed":"will-key-commit",
 "catalog-claim-gc:will-receipt":"will-receipt",
 "catalog-claim-gc:RECEIPT-header-committed":"will-receipt",
 "catalog-claim-gc:did-receipt":"did-receipt",
 "catalog-claim-gc:waiting-receipt-anchor":"waiting-receipt-anchor",
 "catalog-claim-gc:GC_ANCHOR-slot-committed":"waiting-receipt-anchor",
 "catalog-claim-gc:ANCHOR_ACK-header-committed":"waiting-receipt-anchor",
 "catalog-claim-gc:KEY-retired-header-committed":"waiting-receipt-anchor",
 "catalog-claim-gc:did-key-delete":"did-key-delete",
 "catalog-claim-gc:will-parent-retire":"will-parent-retire",
 "catalog-claim-gc:did-parent-retire":"did-parent-retire",
 "catalog-claim-gc:will-claim-release":"will-claim-release"}
ok=True
if barrier in phase_map:
 records=(claim or {}).get("records",{});journal=records.get("GC_JOURNAL",{}).get("payload",{})
 ok=journal.get("phase")==phase_map[barrier]
 if "RECEIPT-header" in barrier:ok=ok and "RECEIPT" in records
 if "ANCHOR_ACK" in barrier:ok=ok and "ANCHOR_ACK" in records
 if "KEY-retired" in barrier:ok=ok and records.get("KEY",{}).get("payload",{}).get("state")=="retired"
else:
 # Release barriers may already have removed the claim pack.  The selected
 # recovery CELL/root mapping, never pathname absence alone, remains authority.
 ok=cell.get("selected_directory") is not None or cell.get("selected_recovery") is not None or claim is None
# Tree processing deletes the empty-shape temp root before will-receipt, long
# before claim release (executed T46 evidence: agents/ is empty at
# waiting-receipt-anchor).  Only the three pre-tree claim-gc barriers still
# observe a live root; every later barrier must observe its legal absence.
# This stored-prior check runs before the resume passes.
pre_tree=barrier in ("catalog-claim-gc:prepared",
 "catalog-claim-gc:KEY-header-committed","catalog-claim-gc:KEY-state-committed")
ok=ok and (os.path.isdir(root) if pre_tree else not os.path.exists(root))
raise SystemExit(0 if ok else 1)
PY
    }
    t48_final_ok() { # base final digest root
        python3 - "$1" "$2" "$3" "$4" <<'PY'
import json,os,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));d,root=sys.argv[3:]
q=b["claims"][d]["records"]["IMMUTABLE_KEY"]["payload"]["reservation_bytes"]
cell=x["claim_cells"].get(d,{})
ok=(d not in x["claims"] and not os.path.exists(root) and
 x["root_meta"].get("owned_bytes")==b["root_meta"].get("owned_bytes")-q and
 x["root_meta"].get("active_claims")==b["root_meta"].get("active_claims")-1 and
 x["root_meta"].get("active_data_claims")==b["root_meta"].get("active_data_claims")-1 and
 cell.get("selected_directory") is None and cell.get("selected_recovery") is None and
 x["root_meta"].get("last_freed_subject_digest")==cell.get("subject_digest"))
raise SystemExit(0 if ok else 1)
PY
    }
    t48_first_barriers='catalog-claim-gc:prepared catalog-claim-gc:KEY-header-committed catalog-claim-gc:KEY-state-committed catalog-claim-gc:will-receipt catalog-claim-gc:RECEIPT-header-committed catalog-claim-gc:did-receipt catalog-claim-gc:waiting-receipt-anchor'
    t48_second_barriers='catalog-claim-gc:GC_ANCHOR-slot-committed catalog-claim-gc:ANCHOR_ACK-header-committed catalog-claim-gc:KEY-retired-header-committed catalog-claim-gc:did-key-delete catalog-claim-gc:will-parent-retire catalog-claim-gc:did-parent-retire catalog-claim-gc:will-claim-release catalog-recovery:delta-will catalog-root:delta-commit catalog-recovery:delta-applied catalog-root:overlay-flush-will catalog-segment:overlay-frame-committed catalog-root:overlay-flush-commit catalog-recovery:flush-acked catalog-root:will-cell-free catalog-claim-pack:physical-release catalog-segment:free-receipt-frame-committed catalog-recovery:cell-free catalog-root:root-did-free'
    for t48_stage in first second; do
      eval "t48_barriers=\$t48_${t48_stage}_barriers"
      for t48_barrier in $t48_barriers; do
        t48="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t48-${t48_stage}.XXXXXX")";t46_dirty_fixture "$t48" empty
        t48_container="$(find "$t48/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t48_root="$t48/.zyz-worker/tasks/task/runtime/agents/.snapshot-tmp.$t37_nonce"
        if [ "$t48_stage" = second ]; then
          t48_gc "$t48" '' >"$t48/seed.out" 2>"$t48/seed.err";t48_seed_rc=$?
        else t48_seed_rc=3;fi
        t48_gc "$t48" "$t48_barrier" >"$t48/kill.out" 2>"$t48/kill.err";t48_kill_rc=$?
        t33_oracle "$t48_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t48/prior.json" 2>"$t48/prior.err";t48_prior_rc=$?
        # t48_prior_ok inspects the live temp root; evaluate and store it here,
        # before the resume passes legally delete that root, and consume only
        # the stored verdict in the final conjunction.
        t48_prior_shape_rc=1
        if t48_prior_ok "$t48/prior.json" "$t48_barrier" "$t46_digest" "$t48_root"; then
          t48_prior_shape_rc=0
        fi
        for t48_resume_index in 1 2 3 4; do
          t48_gc "$t48" '' >"$t48/resume-$t48_resume_index.out" 2>"$t48/resume-$t48_resume_index.err"
        done
        t33_oracle "$t48_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t48/final.json" 2>"$t48/final.err";t48_final_rc=$?
        if [ "$(cat "$t48/setup.rc")" -eq 0 ] && [ "$t48_seed_rc" -eq 3 ] \
          && [ "$t48_kill_rc" -eq 86 ] && [ ! -s "$t48/kill.out" ] && [ ! -s "$t48/kill.err" ] \
          && [ "$t48_prior_rc" -eq 0 ] && [ "$t48_prior_shape_rc" -eq 0 ] \
          && [ "$t48_final_rc" -eq 0 ] && t48_final_ok "$t48/dirty.json" "$t48/final.json" "$t46_digest" "$t48_root"; then
          pass "T48 real $t48_barrier crash replays through receipt anchor key owner CELL and ROOT"
        else
          fail "T48 real $t48_barrier crash replays through receipt anchor key owner CELL and ROOT" \
            "setup=$(cat "$t48/setup.rc") seed=$t48_seed_rc kill=$t48_kill_rc prior=$t48_prior_rc prior_shape=$t48_prior_shape_rc final=$t48_final_rc"
        fi
        rm -rf "$t48"
      done
    done

    # A second native SubagentStart is a fresh event, not publication-parent
    # replay.  Observe its identity-conflict/AMBIGUOUS latch and preserve the
    # committed publication prior; parent-retirement barriers require a separate
    # already-committed multi-generation fixture or persisted reconcile route.
    t48="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t48-publication-parent.XXXXXX")";t37_fixture "$t48"
    t48_container="$(find "$t48/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)";t48_agents="$t48/.zyz-worker/tasks/task/runtime/agents"
    t37_public "$t48" '' '' >"$t48/gen1.out" 2>"$t48/gen1.err";t48_gen1_rc=$?
    t33_oracle "$t48_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t48/parent.json" 2>/dev/null;t48_parent_oracle_rc=$?
    t37_public "$t48" '' "$t33_nonce_b" >"$t48/gen2.out" 2>"$t48/gen2.err";t48_gen2_rc=$?
    t33_oracle "$t48_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t48/parent-final.json" 2>/dev/null;t48_parent_final_oracle_rc=$?
    if [ "$t48_gen1_rc" -eq 0 ] && t37_fresh_conflict_ok "$t48/parent.json" "$t48/parent-final.json" "$t48/gen2.out" "$t48/gen2.err" "$t48_gen2_rc"; then
      pass "T48 publication-parent fresh setup latches AMBIGUOUS and preserves the committed publication prior"
    else
    t48_parent_rc=1
    for t48_try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
      t48_gc "$t48" 'catalog-claim-gc:publication-parent-retired' >"$t48/parent-$t48_try.out" 2>"$t48/parent-$t48_try.err";t48_parent_rc=$?
      [ "$t48_parent_rc" -eq 86 ] && break
    done
    t48_parent_ok=1
    python3 - "$t48/parent.json" "$t45_publication_digest" <<'PY' || t48_parent_ok=0
import json,re,sys
x=json.load(open(sys.argv[1]));d=sys.argv[2];r=x["claims"][d]["records"]
j=r["GC_JOURNAL"]["payload"];rows=x["packs"]["work"]["records"]["TERMINAL_STAGING"]["payload"]["publication_cleanup_intents"]
matching=[row for row in rows if row.get("retired_claim_key_sha256")==d]
ok=(j.get("phase")=="will-parent-retire" and len(matching)==2 and
 all(row.get("claim_state")=="retired" and re.fullmatch(r"[0-9a-f]{64}",str(row.get("claim_receipt_digest"))) for row in matching))
raise SystemExit(0 if ok else 1)
PY
    for t48_try in 1 2 3 4 5 6 7 8; do t48_gc "$t48" '' >"$t48/resume-parent-$t48_try.out" 2>"$t48/resume-parent-$t48_try.err";done
    if [ "$t48_gen1_rc" -eq 0 ] && [ "$t48_gen2_rc" -eq 0 ] && [ "$t48_parent_rc" -eq 86 ] \
      && [ "$t48_parent_oracle_rc" -eq 0 ] && [ "$t48_parent_ok" -eq 1 ] \
      && python3 - "$t48/parent-final.json" "$t45_publication_digest" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));raise SystemExit(0 if sys.argv[2] not in x["claims"] else 1)
PY
    then pass "T48 real publication-parent-retired barrier binds receipt before claim release"
    else fail "T48 real publication-parent-retired barrier binds receipt before claim release" "gen=$t48_gen1_rc/$t48_gen2_rc barrier=$t48_parent_rc prior=$t48_parent_oracle_rc";fi
    fi
    rm -rf "$t48"

    # -----------------------------------------------------------------------
    # T49  Public multi-invocation byte budget and deterministic deadline.
    # Sparse zero-filled files keep physical fixture cost bounded while public
    # GC must hash every logical byte.  Expected offsets/counters and SHA-256
    # values are derived here; CHECKPOINT HMAC and POINTER digest are rebuilt
    # independently.  The monotonic seam is test-only and must not alter public
    # config, lock timeouts, producer deadlines, or the real default clock.
    # -----------------------------------------------------------------------
    t49_dirty_fixture() { # sandbox max-bytes
      t37_fixture "$1";t49_max="$2"
      t49_container="$(find "$1/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
      t49_agents="$1/.zyz-worker/tasks/task/runtime/agents"
      # The producer below seeds ZYZ_TEST_RANDOM_HEX_SEQUENCE with $t33_nonce_a
      # first; nonce_hex() is invoked twice with domain-local attempt 0, so
      # that one seed owns both halves (suite convention documented at the
      # t37_seed definition).  The persisted OWNER temp_basename is therefore
      # .snapshot-tmp.$t37_phase_nonce, matching the $t38_digest claim domain.
      t49_root="$t49_agents/.snapshot-tmp.$t37_phase_nonce"
      t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$1/initial.json" 2>"$1/initial.err"
      (
        cd "$1" || exit 1
        printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"%s","agent_type":"zyz-worker:%s"}' \
          "$1" "$t33_raw" "$t33_role" | env \
          ZYZ_NO_OUTPUT_MAX_FILE_BYTES="$t49_max" ZYZ_NO_OUTPUT_MAX_TOTAL_BYTES="$t49_max" \
          ZYZ_NO_OUTPUT_MAX_TEMP_BYTES="$t49_max" ZYZ_TEST_TRANSITION_STOP_AFTER='catalog-claim-pack:owner-did-create' \
          ZYZ_TEST_RANDOM_HEX_SEQUENCE="$t33_nonce_a,$t37_seed" \
          bash "$REPO_ROOT/hooks/scripts/subagent-track.sh"
      ) >"$1/create.out" 2>"$1/create.err";printf '%s\n' "$?" >"$1/create.rc"
      t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$1/dirty.json" 2>"$1/dirty.err"
    }
    t49_gc() { # sandbox byte-budget monotonic-sequence
      (
        cd "$1" || exit 1
        ZYZ_NO_OUTPUT_TEMP_STALE_SEC=120 ZYZ_TEST_GC_NOW_EPOCH=2147480000 \
        ZYZ_SNAPSHOT_GC_MAX_ENTRIES_PER_PASS=100 \
        ZYZ_SNAPSHOT_GC_MAX_VERIFY_BYTES_PER_PASS="$2" ZYZ_SNAPSHOT_GC_MAX_SEC="${4:-30}" \
        ZYZ_TEST_GC_MONOTONIC_NS_SEQUENCE="$3" \
          bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
            gc-step "$1/.zyz-worker/tasks/task" manual
      )
    }
    t49_cursor_ok() { # oracle digest pass offset verified processed first-sha-or-null
      python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" <<'PY'
import base64,hashlib,hmac,json,sys
x=json.load(open(sys.argv[1]));d=sys.argv[2];want_pass=int(sys.argv[3]);want_offset=int(sys.argv[4]);want_verified=int(sys.argv[5]);want_processed=int(sys.argv[6]);want_sha=sys.argv[7]
r=x["claims"][d]["records"];key=base64.b64decode(r["KEY"]["payload"]["key_b64"],validate=True)
slot=r["CHECKPOINT"]["payload"];pointer=r["POINTER"]["payload"]
J=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
valid=[]
for row in (slot["current"],slot["previous"]):
 if row is None:continue
 body={k:v for k,v in row.items() if k!="hmac_sha256"}
 if hmac.compare_digest(row["hmac_sha256"],hmac.new(key,J(body),hashlib.sha256).hexdigest()):valid.append(row)
selected=next((row for row in valid if row["generation"]==pointer["generation"] and hashlib.sha256(J(row)+b"\n").hexdigest()==pointer["checkpoint_digest"]),None)
c={} if selected is None else selected["cursor"]
ok=(len(key)==32 and selected is not None and c.get("verification_pass")==want_pass and
 c.get("file_offset")==want_offset and c.get("verified_bytes")==want_verified and
 c.get("processed_entries")==want_processed and c.get("deleted_count")==want_processed and
 ((want_sha=="null" and c.get("first_sha256") is None) or c.get("first_sha256")==want_sha))
raise SystemExit(0 if ok else 1)
PY
    }
    t49_receipt_ok() { # oracle digest logical-bytes leaf-count
      python3 - "$1" "$2" "$3" "$4" <<'PY'
import base64,hashlib,hmac,json,sys
x=json.load(open(sys.argv[1]));d=sys.argv[2];logical=int(sys.argv[3]);leaf_count=int(sys.argv[4])
r=x["claims"][d]["records"];j=r["GC_JOURNAL"]["payload"];receipt=r["RECEIPT"]["payload"]
key=base64.b64decode(r["KEY"]["payload"]["key_b64"],validate=True);body={k:v for k,v in receipt.items() if k!="hmac_sha256"}
J=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
targets=j["targets"]
slot=r["CHECKPOINT"]["payload"];pointer=r["POINTER"]["payload"]
selected=next(row for row in (slot["current"],slot["previous"]) if row and row["generation"]==pointer["generation"])
c=selected["cursor"]
ok=(j.get("phase")=="waiting-receipt-anchor" and j.get("verified_bytes")==2*logical and
 j.get("verified_entries")==j.get("deleted_count")==leaf_count+1 and
 len(targets)==1 and targets[0].get("type")=="directory" and
 c.get("processed_entries")==leaf_count and c.get("processed_regular_bytes")==logical and
 c.get("verified_bytes")==2*logical and c.get("root_deleted") is True and
 receipt.get("verified_bytes")==2*logical and receipt.get("target_set_digest")==hashlib.sha256(J(targets)+b"\n").hexdigest() and
 receipt.get("hmac_sha256")==hmac.new(key,J(body),hashlib.sha256).hexdigest())
raise SystemExit(0 if ok else 1)
PY
    }

    # One byte beyond 128 MiB: pass1 stops at 128 MiB; pass2 consumes the
    # remaining first-pass byte plus all but two bytes of pass2.
    t49="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t49-single.XXXXXX")";t49_dirty_fixture "$t49" 268435456
    python3 - "$t49_root/huge" <<'PY'
import os,sys
with open(sys.argv[1],"wb") as f:f.truncate(134217729)
PY
    t49_zero_sha="$(python3 - <<'PY'
import hashlib
h=hashlib.sha256();chunk=bytes(1048576);remaining=134217729
while remaining:part=chunk[:min(len(chunk),remaining)];h.update(part);remaining-=len(part)
print(h.hexdigest())
PY
)"
    t49_single_ok=1
    for t49_pass in 1 2; do
      t49_gc "$t49" 134217728 0 >"$t49/pass$t49_pass.out" 2>"$t49/pass$t49_pass.err";eval "t49_pass${t49_pass}_rc=\$?"
      t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/pass$t49_pass.json" 2>"$t49/pass$t49_pass-oracle.err"
    done
    [ "$t49_pass1_rc" -eq 3 ] && t49_cursor_ok "$t49/pass1.json" "$t38_digest" 1 134217728 134217728 0 null || t49_single_ok=0
    [ "$t49_pass2_rc" -eq 3 ] && t49_cursor_ok "$t49/pass2.json" "$t38_digest" 2 134217727 268435456 0 "$t49_zero_sha" || t49_single_ok=0
    t49_gc "$t49" 134217728 0 >"$t49/receipt.out" 2>"$t49/receipt.err";t49_receipt_rc=$?
    t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/receipt.json" 2>/dev/null
    t49_gc "$t49" 134217728 0 >"$t49/release.out" 2>"$t49/release.err";t49_release_rc=$?
    t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/final.json" 2>/dev/null
    if t37_unavailable_ok "$(cat "$t49/create.rc")" "$t49/create.out" "$t49/create.err" \
      && [ "$t49_single_ok" -eq 1 ] && [ "$t49_receipt_rc" -eq 3 ] \
      && t49_receipt_ok "$t49/receipt.json" "$t38_digest" 134217729 1 \
      && [ "$t49_release_rc" -eq 0 ] && t48_final_ok "$t49/dirty.json" "$t49/final.json" "$t38_digest" "$t49_root"; then
      pass "T49 128MiB-plus-one single file preserves exact SHA offsets receipt anchor and release"
    else fail "T49 128MiB-plus-one single file preserves exact SHA offsets receipt anchor and release" "passes=$t49_pass1_rc/$t49_pass2_rc receipt=$t49_receipt_rc release=$t49_release_rc";fi
    rm -rf "$t49"

    # Aggregate 200 MiB across two files.  The exact cursor sequence is
    # 28 MiB into pass2 of file1, then 56 MiB into pass1 of file2, then 84 MiB
    # into pass2 of file2 before the fourth invocation reaches the receipt.
    t49="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t49-aggregate.XXXXXX")";t49_dirty_fixture "$t49" 268435456
    python3 - "$t49_root/a" "$t49_root/b" <<'PY'
import sys
for path in sys.argv[1:]:
 with open(path,"wb") as f:f.truncate(104857600)
PY
    t49_100_sha="$(python3 - <<'PY'
import hashlib
h=hashlib.sha256();chunk=bytes(1048576)
for _ in range(100):h.update(chunk)
print(h.hexdigest())
PY
)";t49_aggregate_ok=1
    for t49_pass in 1 2 3; do
      t49_gc "$t49" 134217728 0 >"$t49/pass$t49_pass.out" 2>"$t49/pass$t49_pass.err";eval "t49_pass${t49_pass}_rc=\$?"
      t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/pass$t49_pass.json" 2>/dev/null
    done
    [ "$t49_pass1_rc" -eq 3 ] && t49_cursor_ok "$t49/pass1.json" "$t38_digest" 2 29360128 134217728 0 "$t49_100_sha" || t49_aggregate_ok=0
    [ "$t49_pass2_rc" -eq 3 ] && t49_cursor_ok "$t49/pass2.json" "$t38_digest" 1 58720256 268435456 1 null || t49_aggregate_ok=0
    [ "$t49_pass3_rc" -eq 3 ] && t49_cursor_ok "$t49/pass3.json" "$t38_digest" 2 88080384 402653184 1 "$t49_100_sha" || t49_aggregate_ok=0
    t49_gc "$t49" 134217728 0 >"$t49/receipt.out" 2>"$t49/receipt.err";t49_receipt_rc=$?
    t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/receipt.json" 2>/dev/null
    t49_gc "$t49" 134217728 0 >"$t49/release.out" 2>"$t49/release.err";t49_release_rc=$?
    t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/final.json" 2>/dev/null
    if [ "$t49_aggregate_ok" -eq 1 ] && [ "$t49_receipt_rc" -eq 3 ] \
      && t49_receipt_ok "$t49/receipt.json" "$t38_digest" 209715200 2 \
      && [ "$t49_release_rc" -eq 0 ] && t48_final_ok "$t49/dirty.json" "$t49/final.json" "$t38_digest" "$t49_root"; then
      pass "T49 aggregate 200MiB fixture preserves cross-file offsets digests counters and release"
    else fail "T49 aggregate 200MiB fixture preserves cross-file offsets digests counters and release" "passes=$t49_pass1_rc/$t49_pass2_rc/$t49_pass3_rc receipt=$t49_receipt_rc release=$t49_release_rc";fi
    rm -rf "$t49"

    # Exact monotonic consumption: deadline creation/top/leaf checks consume
    # the first three zeros; one 128 KiB read consumes the fourth, and the fifth
    # value crosses the one-second deadline before byte budget exhaustion.
    t49="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t49-deadline.XXXXXX")";t49_dirty_fixture "$t49" 16777216
    python3 - "$t49_root/leaf" <<'PY'
import sys
with open(sys.argv[1],"wb") as f:f.truncate(1048576)
PY
    t49_gc "$t49" 2147483647 '0,0,0,0,2000000000' 1 >"$t49/deadline.out" 2>"$t49/deadline.err";t49_deadline_rc=$?
    t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/deadline.json" 2>/dev/null
    if [ "$t49_deadline_rc" -eq 3 ] && t49_cursor_ok "$t49/deadline.json" "$t38_digest" 1 131072 131072 0 null; then
      pass "T49 deterministic deadline wins before byte budget at exact 131072-byte cursor"
    else fail "T49 deterministic deadline wins before byte budget at exact 131072-byte cursor" "rc=$t49_deadline_rc";fi
    rm -rf "$t49"

    for t49_bad in '' '01' '9223372036854775808' '2,1'; do
      t49="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t49-clock-invalid.XXXXXX")";t49_dirty_fixture "$t49" 16777216
      python3 - "$t49_root/leaf" <<'PY'
import sys
with open(sys.argv[1],"wb") as f:f.truncate(1048576)
PY
      t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/before.json" 2>/dev/null
      t49_gc "$t49" 2147483647 "$t49_bad" 1 >"$t49/out" 2>"$t49/err";t49_bad_rc=$?
      t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/after.json" 2>/dev/null
      if [ "$t49_bad_rc" -eq 2 ] && [ ! -s "$t49/err" ] && cmp -s "$t49/before.json" "$t49/after.json" \
        && [ -f "$t49_root/leaf" ] && python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));raise SystemExit(0 if x.get("ok") is False and x.get("state")=="error" and (x.get("error") or {}).get("code")=="invalid-request" else 1)' "$t49/out"; then
        pass "T49 malformed monotonic sequence [$t49_bad] is invalid-request and byte-zero-effect"
      else fail "T49 malformed monotonic sequence [$t49_bad] is invalid-request and byte-zero-effect" "rc=$t49_bad_rc";fi
      rm -rf "$t49"
    done
    t49_bad="$(python3 -c 'print(",".join(["0"]*2049))')"
    t49="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t49-clock-overlong.XXXXXX")";t49_dirty_fixture "$t49" 16777216
    t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/before.json" 2>/dev/null
    t49_gc "$t49" 2147483647 "$t49_bad" 1 >"$t49/out" 2>"$t49/err";t49_bad_rc=$?
    t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/after.json" 2>/dev/null
    if [ "$t49_bad_rc" -eq 2 ] && cmp -s "$t49/before.json" "$t49/after.json"; then
      pass "T49 4097-byte monotonic sequence is rejected before dirty-data effect"
    else fail "T49 4097-byte monotonic sequence is rejected before dirty-data effect" "rc=$t49_bad_rc";fi
    rm -rf "$t49"
    t49_bound="$(python3 -c 'print(",".join(["0"]*2048))')"
    t49="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t49-clock-bound.XXXXXX")";t49_dirty_fixture "$t49" 16777216
    t49_gc "$t49" 2147483647 "$t49_bound" 1 >"$t49/out" 2>"$t49/err";t49_bound_rc=$?
    t33_oracle "$t49_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t49/receipt.json" 2>/dev/null
    if [ "${#t49_bound}" -eq 4095 ] && [ "$t49_bound_rc" -eq 3 ] \
      && t49_receipt_ok "$t49/receipt.json" "$t38_digest" 0 0; then
      pass "T49 exact 4095-byte canonical monotonic sequence is accepted"
    else fail "T49 exact 4095-byte canonical monotonic sequence is accepted" "length=${#t49_bound} rc=$t49_bound_rc";fi
    rm -rf "$t49"
else
    skip "T37--T49 public claim/publication coverage requires T33 GENESIS capability and SubagentStart"
fi

# ---------------------------------------------------------------------------
# T50  Migration quiesce/group-plan/scratch-copy recovery. This suite is
# intentionally isolated: public gc-step does not expose migration yet. Raw
# A/B, ROOT, source-frame and scratch bytes are decoded independently below;
# green checks must not be read as migration cutover or reader-visibility
# proof. The static case is also the degradation anchor while the physical
# fixture/oracle cases below are assembled in this continuation.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1 && [ -f hooks/scripts/runtime_state.py ]; then
    t50_surface="$(python3 -c 'import ast,json,sys
t=ast.parse(open(sys.argv[1],encoding="utf-8").read());f={n.name:n for n in t.body if isinstance(n,ast.FunctionDef)}
want={"_catalog_selected_quiesce_work","_catalog_quiesce_plan_one","_catalog_quiesce_advance_one","_catalog_quiesce_retire_active","_catalog_group_plan_step","_catalog_group_copy_step"}
barriers={n.value for n in ast.walk(t) if isinstance(n,ast.Constant) and isinstance(n.value,str) and n.value in {"scratch-frame-committed","group-copy-complete"}}
print(json.dumps({"missing":sorted(want-set(f)),"barriers":sorted(barriers)},sort_keys=True,separators=(",",":")))' hooks/scripts/runtime_state.py)"
    if printf '%s' "$t50_surface" | python3 -c 'import json,sys;x=json.load(sys.stdin);need={"scratch-frame-committed","group-copy-complete"};raise SystemExit(0 if not x["missing"] and need<=set(x["barriers"]) else 1)'; then
        pass "T50 isolated migration quiesce and scratch-copy seam remains callable"
    else
        fail "T50 isolated migration quiesce and scratch-copy seam remains callable" "$t50_surface"
    fi

    t50_drive() { # container action limit barrier
        PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT/hooks/scripts/runtime_state.py" "$1" "$2" "${3:-64}" "${4:-}" <<'PY'
import importlib.util,json,os,sys
from pathlib import Path
runtime,container,action,limit,barrier=sys.argv[1:]
spec=importlib.util.spec_from_file_location("zyz_runtime_state",runtime)
m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
c=Path(container);limit=int(limit)
if barrier: os.environ["ZYZ_TEST_TRANSITION_STOP_AFTER"]=barrier
else: os.environ.pop("ZYZ_TEST_TRANSITION_STOP_AFTER",None)
try:
 if action=="begin-group":
  first=m._catalog_migration_quiesce_begin(c)
  proof=m._catalog_validate_genesis(c);os.close(proof.pop("global_fd"))
  generation=proof["chain"]["members"][0]["generation"]
  result={"begin":first,"group":m._catalog_previs_group_begin(c,generation)}
 elif action=="quiesce-plan": result=m._catalog_quiesce_plan_one(c)
 elif action=="quiesce-advance": result=m._catalog_quiesce_advance_one(c)
 elif action=="quiesce-bounded": result=m._catalog_quiesce_retire_active(c,limit)
 elif action=="quiesce-run":
  result=None
  for _ in range(32768):
   planned=m._catalog_quiesce_plan_one(c)
   if planned["state"]=="quiesced": result=planned;break
   result=m._catalog_quiesce_advance_one(c)
  else: raise m.StateError("gc-internal","quiesce fixture did not converge",5)
 elif action=="group-plan-once": result=m._catalog_group_plan_step(c,limit)
 elif action=="group-plan-all":
  for _ in range(32768):
   result=m._catalog_group_plan_step(c,limit)
   if result["state"]=="group-planned": break
  else: raise m.StateError("gc-internal","group plan fixture did not converge",5)
 elif action=="group-copy-once": result=m._catalog_group_copy_step(c,limit)
 elif action=="group-copy-all":
  for _ in range(32768):
   result=m._catalog_group_copy_step(c,limit)
   if result["state"]=="copied": break
  else: raise m.StateError("gc-internal","group copy fixture did not converge",5)
 else: raise m.StateError("gc-internal","unknown T50 isolated action",5)
 print(json.dumps({"ok":True,"action":action,"result":result},sort_keys=True,separators=(",",":")))
except m.StateError as exc:
 print(json.dumps({"ok":False,"action":action,"error":{"code":exc.code,"message":exc.message,"retryable":exc.retryable}},sort_keys=True,separators=(",",":")))
 raise SystemExit(exc.exit_code)
PY
    }

    # Independent physical decoder: it does not import runtime_state or reuse
    # any production checksum/parser helper. ROOT selects exactly one 64 KiB
    # work image by digest; source and scratch descriptors/frames are decoded
    # from bytes and the MSB-first bitmap/rolling accumulator are rebuilt here.
    t50_oracle() { # container
        python3 - "$1" <<'PY'
import base64,hashlib,json,os,stat,struct,sys
p=sys.argv[1]
D=lambda domain,value:hashlib.sha256(domain+value).digest()
J=lambda value:json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()

def image(raw,magic,metadata_limit=3968):
 if len(raw)<128 or raw[:8]!=magic.ljust(8,b"\0"):raise ValueError("image magic")
 schema,flags,generation,length=struct.unpack_from(">HHQI",raw,8)
 if schema!=1 or flags!=0 or generation<1 or length>metadata_limit:raise ValueError("image header")
 source=bytearray(raw);source[56:88]=bytes(32)
 if raw[56:88]!=D(b"zyz-pack-image-v1",bytes(source)):raise ValueError("image checksum")
 payload=raw[128:128+length]
 if raw[96:128]!=D(b"zyz-pack-payload-v1",payload):raise ValueError("payload checksum")
 value=json.loads(payload)
 if not isinstance(value,dict) or J(value)!=payload:raise ValueError("canonical payload")
 return {"generation":generation,"predecessor":raw[24:56].hex(),"metadata":value,
         "digest":D(b"zyz-pack-image-id-v1",raw).hex(),"raw":raw}

def candidates(raw,offset,size,magic,limit=3968):
 out=[]
 for bank in (0,1):
  part=raw[offset+bank*size:offset+(bank+1)*size]
  if part==bytes(size):continue
  try:out.append({"bank":bank,**image(part,magic,limit)})
  except Exception:pass
 return out

def newest(rows):
 if not rows:raise ValueError("no valid A/B image")
 ordered=sorted(rows,key=lambda x:x["generation"])
 if len(ordered)==2 and (ordered[0]["generation"]==ordered[1]["generation"] or
                         ordered[1]["predecessor"]!=ordered[0]["digest"]):
  raise ValueError("A/B chain")
 return ordered[-1]

def hybrid(raw):
 if len(raw)!=16384:raise ValueError("hybrid size")
 header=image(raw[:4096],b"ZYZHCN1");hm=header["metadata"]
 count=hm.get("entry_count")
 if (hm.get("schema_version")!=1 or hm.get("state")!="active" or
     hm.get("chain_generation")!=header["generation"] or
     not isinstance(count,int) or not 1<=count<=16):raise ValueError("hybrid header")
 region=raw[4096:12288];images=[];entries=[];predecessor=header["predecessor"]
 prior_last=0
 for index in range(count):
  part=region[index*512:(index+1)*512];parsed=image(part,b"ZYZHCE1",384)
  if parsed["generation"]!=header["generation"] or parsed["predecessor"]!=predecessor:raise ValueError("hybrid entry chain")
  meta=parsed["metadata"]
  if meta.get("k")=="scratch-object":
   binary=part[240:512]
   if binary[:8]!=b"ZYZSCA1\0" or binary[10:16]!=bytes(6):raise ValueError("scratch anchor binary")
   n=struct.unpack_from(">H",binary,8)[0]
   if not 1<=n<=80 or binary[192+n:]!=bytes(80-n):raise ValueError("scratch anchor name")
   dg,used=struct.unpack_from(">QQ",binary,176)
   names=("identity_digest","descriptor_digest","plan_digest","source_group_digest","cancel_set_digest")
   entry={"schema_version":1,"kind":"scratch-object","first_generation":meta.get("fg"),"last_generation":meta.get("lg"),
          "basename":binary[192:192+n].decode("ascii"),"descriptor_generation":dg,"used_length":used,
          **{name:binary[16+i*32:48+i*32].hex() for i,name in enumerate(names)}}
  else:entry=meta
  if (not isinstance(entry.get("first_generation"),int) or not isinstance(entry.get("last_generation"),int) or
      entry["first_generation"]<=prior_last or entry["last_generation"]<entry["first_generation"]):raise ValueError("hybrid entry order")
  entries.append(entry);images.append(part);predecessor=parsed["digest"];prior_last=entry["last_generation"]
 if region[count*512:]!=bytes(8192-count*512):raise ValueError("hybrid unused bytes")
 entries_digest=D(b"zyz-hybrid-chain-entry-set-v1",b"".join(images)).hex()
 if hm.get("entries_sha256")!=entries_digest:raise ValueError("hybrid entry digest")
 trailer=image(raw[12288:],b"ZYZHCT1");header_digest=header["digest"]
 digest=D(b"zyz-catalog-hybrid-chain-v1",bytes.fromhex(header_digest)+bytes.fromhex(entries_digest)).hex()
 expected={"schema_version":1,"state":"committed","chain_generation":header["generation"],
           "header_sha256":header_digest,"entries_sha256":entries_digest,"hybrid_chain_digest":digest}
 if trailer["generation"]!=header["generation"] or trailer["predecessor"]!=header_digest or trailer["metadata"]!=expected:
  raise ValueError("hybrid trailer")
 return {"generation":header["generation"],"digest":digest,"entries":entries,
         "header_digest":header_digest,"entries_digest":entries_digest}

def frame(raw):
 if len(raw)<64 or raw[:8]!=b"ZYZFRM1\0":raise ValueError("frame magic")
 schema,kind,payload_length,total=struct.unpack_from(">HHII",raw,8)
 if schema!=1 or kind not in range(1,6) or total!=len(raw) or total%8 or payload_length>total-64:raise ValueError("frame header")
 if raw[52:64]!=bytes(12) or raw[64+payload_length:]!=bytes(total-64-payload_length):raise ValueError("frame padding")
 encoded=raw[64:64+payload_length]
 if raw[20:52]!=D(b"zyz-catalog-frame-payload-v1",encoded):raise ValueError("frame payload")
 value=json.loads(encoded)
 if not isinstance(value,dict) or J(value)!=encoded:raise ValueError("frame canonical")
 return {"kind":{1:"overlay",2:"free-receipt",3:"owner",4:"claim",5:"observation"}[kind],
         "length":total,"payload":value,"digest":D(b"zyz-catalog-frame-v1",raw).hex(),"raw":raw}

def segment(name):
 path=os.path.join(p,name);raw=open(path,"rb").read()
 if len(raw)!=1048576:raise ValueError("segment size")
 rows=candidates(raw,983040,4096,b"ZYZSEG1");desc=newest(rows);meta=desc["metadata"]
 used=meta.get("committed_used_length")
 if (meta.get("deterministic_basename")!=name or not isinstance(used,int) or not 0<=used<=983040 or
     meta.get("committed_content_sha256")!=hashlib.sha256(raw[:used]).hexdigest()):raise ValueError("segment descriptor")
 frames=[];offset=0
 while offset<used:
  if offset+20>used:raise ValueError("frame header extent")
  total=struct.unpack_from(">I",raw,offset+16)[0]
  if total<64 or offset+total>used:raise ValueError("frame extent")
  parsed=frame(raw[offset:offset+total]);frames.append({"offset":offset,**parsed});offset+=total
 if offset!=used:raise ValueError("segment extent")
 return {"basename":name,"descriptor_generation":desc["generation"],"descriptor_bank":desc["bank"],"descriptor_predecessor":desc["predecessor"],
         "descriptor_digest":desc["digest"],"metadata":meta,"used":used,"content_sha256":hashlib.sha256(raw[:used]).hexdigest(),
         "frames":frames,"content":raw[:used]}

g=open(os.path.join(p,".catalog-global-pack.v1"),"rb").read()
if len(g)!=4194304:raise ValueError("global size")
root_rows=candidates(g,32768,65536,b"ZYZROOT1");root=newest(root_rows);rm=root["metadata"]
chain=hybrid(root["raw"][5120:21504])
if chain["digest"]!=rm.get("hybrid_chain_digest"):raise ValueError("ROOT/hybrid selection")
work_rows=candidates(g,3440640,65536,b"ZYZMQW1",60000)
work_matches=[x for x in work_rows if x["digest"]==rm.get("migration_quiesce_work_digest")]
if len(work_matches)!=1:raise ValueError("ROOT/work selection")
work=work_matches[0]
group_rows=candidates(g,3309568,65536,b"ZYZGRP1",60000)
group_matches=[x for x in group_rows if x["digest"]==rm.get("group_control_digest")]
if len(group_matches)!=1:raise ValueError("ROOT/group selection")
group=group_matches[0];gm=group["metadata"]

sources=[]
for fact in gm.get("source_segments",[]):
 if not os.path.exists(os.path.join(p,fact["basename"])):
  sources.append({"basename":fact["basename"],"exists":False,"fact":fact,"frames":[]});continue
 s=segment(fact["basename"]);s["exists"]=True
 exact=(s["descriptor_digest"]==fact.get("descriptor_digest") and s["descriptor_generation"]==fact.get("descriptor_generation") and
        s["used"]==fact.get("used_length") and s["metadata"].get("segment_generation")==fact.get("segment_generation"))
 if not exact and gm.get("state") not in ("next-scratch-will","next-scratch-ready","retired-delete-will","old-source-retired","group-committed"):
  raise ValueError("source fact")
 s["fact_exact"]=exact
 sources.append(s)
scratch_name=gm.get("scratch_basename") or rm.get("migration_scratch_basename")
scratch=segment(scratch_name)

chain_objects=[]
for entry in chain["entries"]:
 names=([entry["basename"]] if entry.get("kind")=="scratch-object" else
        [f'.catalog-segment.{generation:016d}.v1' for generation in range(entry["first_generation"],entry["last_generation"]+1)])
 decoded=[]
 for name in names:
  if not os.path.exists(os.path.join(p,name)):raise ValueError("visible hybrid object absent")
  value=segment(name);value.pop("content",None)
  # segment() stamps the raw bytes blob on the segment and every frame; the
  # sources/scratch result branches rebuild frames without it, so mirror that
  # here (the top-level segment dict has no raw key; each frame does).  Keep
  # every load-bearing key (digest/payload/offset/length/kind/descriptor_*/
  # used/content_sha256/metadata) so downstream conjuncts still verify.
  value["frames"]=[{k:fv for k,fv in f.items() if k!="raw"} for f in value["frames"]]
  decoded.append(value)
 if entry.get("kind")=="scratch-object":
  value=decoded[0]
  exact=(value["descriptor_digest"]==entry["descriptor_digest"] and value["descriptor_generation"]==entry["descriptor_generation"] and
         value["used"]==entry["used_length"] and value["metadata"].get("segment_generation")==0)
  will=rm.get("claim_frame_will") or rm.get("previs_free_will")
  after=(isinstance(will,dict) and will.get("segment_generation")==entry["last_generation"] and will.get("frame_offset")==entry["used_length"] and
         value["descriptor_generation"]==entry["descriptor_generation"]+1 and value["descriptor_predecessor"]==entry["descriptor_digest"] and
         value["used"]==entry["used_length"]+will.get("frame_length",-1) and value["frames"] and value["frames"][-1]["offset"]==entry["used_length"] and
         value["frames"][-1]["digest"]==will.get("frame_digest") and value["metadata"].get("segment_generation")==0)
  if not exact and not after:raise ValueError("scratch anchor authority")
  value["anchor_relation"]="exact" if exact else "append-after"
 chain_objects.append({"entry":entry,"objects":decoded})

objects={}
for item in work["metadata"].get("objects",[]):
 path=os.path.join(p,item["basename"]);observed={"exists":os.path.exists(path)}
 if observed["exists"]:
  st=os.lstat(path);identity={"dev":st.st_dev,"ino":st.st_ino,"size":st.st_size,
    "mount_id":item["identity"]["mount_id"]};identity["digest"]=hashlib.sha256(J(identity)).hexdigest()
  observed.update(identity=identity,regular=stat.S_ISREG(st.st_mode),nlink=st.st_nlink,
                  exact=(identity==item["identity"] and st.st_size==item["expected_size"]))
 objects[item["basename"]]=observed

slots=gm.get("plan_total_slots",0);encoded=gm.get("plan_bitmap_b64","")
try:bitmap=base64.b64decode(encoded,validate=True)
except Exception:bitmap=b"!"
bitmap_shape=(len(bitmap)==(slots+7)//8 and (not bitmap or not slots%8 or bitmap[-1]&((1<<(8-slots%8))-1)==0))
ordered=[(s["metadata"].get("segment_generation"),f) for s in sources if s.get("exists") for f in s["frames"]]
bits=[];selected=[];acc=D(b"zyz-migration-active-frame-list-v1",b"")
if bitmap_shape and len(ordered)>=slots:
 for index,(generation,f) in enumerate(ordered[:slots]):
  bit=bool(bitmap[index//8]&(1<<(7-index%8)));bits.append(1 if bit else 0)
  if bit:
   acc=D(b"zyz-migration-active-frame-step-v1",acc+struct.pack(">QQ",generation,f["offset"])+bytes.fromhex(f["digest"]));selected.append(f)
expected_scratch=b"".join(f["raw"] for f in selected)
result={
 "root":{"generation":root["generation"],"bank":root["bank"],"digest":root["digest"],"metadata":rm,
         "valid_banks":[{"generation":x["generation"],"bank":x["bank"],"digest":x["digest"]} for x in root_rows]},
 "work":{"generation":work["generation"],"bank":work["bank"],"digest":work["digest"],"metadata":work["metadata"],
         "root_match_count":len(work_matches),"valid_banks":[{"generation":x["generation"],"bank":x["bank"],"digest":x["digest"]} for x in work_rows]},
 "group":{"generation":group["generation"],"bank":group["bank"],"digest":group["digest"],"metadata":gm,"root_match_count":len(group_matches)},
 "chain":{**chain,"objects":chain_objects},
 "objects":objects,
 "sources":[({"basename":s["basename"],"exists":False,"fact":s["fact"],"frames":[]} if not s.get("exists") else {"basename":s["basename"],"exists":True,"descriptor_generation":s["descriptor_generation"],"descriptor_bank":s["descriptor_bank"],
             "descriptor_digest":s["descriptor_digest"],"fact_exact":s.get("fact_exact"),"used":s["used"],"content_sha256":s["content_sha256"],
             "frames":[{"offset":f["offset"],"length":f["length"],"kind":f["kind"],"digest":f["digest"],"payload":f["payload"]} for f in s["frames"]]}) for s in sources],
 "scratch":{"basename":scratch["basename"],"descriptor_generation":scratch["descriptor_generation"],"descriptor_bank":scratch["descriptor_bank"],
            "descriptor_digest":scratch["descriptor_digest"],"used":scratch["used"],"content_sha256":scratch["content_sha256"],
            "frames":[{"offset":f["offset"],"length":f["length"],"kind":f["kind"],"digest":f["digest"],"payload":f["payload"]} for f in scratch["frames"]]},
 "plan":{"bitmap_shape":bitmap_shape,"bits":bits,"selected_count":len(selected),"selected_bytes":len(expected_scratch),
         "accumulator":acc.hex(),"expected_scratch_sha256":hashlib.sha256(expected_scratch).hexdigest(),
         "scratch_exact":scratch["content"]==expected_scratch},
}
print(json.dumps(result,sort_keys=True,separators=(",",":")))
PY
    }

    if [ "${t33_supported:-0}" -eq 1 ]; then
        t50_uncommitted_fixture() { # sandbox
            t33_fixture "$1"
            t33_start "$1" "$t33_nonce_a" 'catalog-recovery:owner-active' \
                >"$1/owner.out" 2>"$1/owner.err"
            t50_container="$(find "$1/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        }
        t50_quiesce_prior_ok() { # base-raw prior-raw prior-t33 barrier
            python3 - "$1" "$2" "$3" "$4" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));cell=json.load(open(sys.argv[3]))["selected_cell"];phase=sys.argv[4]
w=x["work"]["metadata"];r=x["root"]["metadata"];br=b["root"]["metadata"]
names=[item["basename"] for item in w.get("objects",[])]
expected_state={"owner-active-ack-recovered":"idle","quiesce-work-planned":"planned","quiesce-delete-will":"deleting",
 "post-object-delete-0":"deleting","quiesce-delete-cursor":"deleting","quiesce-all-objects-deleted":"deleted",
 "quiesce-release-will":"release-will","delta-will":"release-will","delta-commit":"release-will",
 "delta-applied":"release-will","quiesce-release-applied":"release-applied","quiesce-retire-committed":"committed",
 "quiesce-work-consumed":"idle"}[phase]
cursor={"quiesce-work-planned":0,"quiesce-delete-will":0,"post-object-delete-0":0,"quiesce-delete-cursor":1,
 "quiesce-all-objects-deleted":3,"quiesce-release-will":3,"delta-will":3,"delta-commit":3,"delta-applied":3,
 "quiesce-release-applied":3,"quiesce-retire-committed":3}.get(phase,0)
ok=(x["work"]["root_match_count"]==1 and x["group"]["root_match_count"]==1 and w.get("state")==expected_state and
 x["root"]["metadata"].get("migration_quiesce_work_digest")==x["work"]["digest"] and
 cell is not None and cell["recovery"]["payload"].get("state") in ("ACTIVE_ACK","DELTA_WILL","DELTA_APPLIED"))
if phase=="owner-active-ack-recovered":
 ok=ok and not names and cell["recovery"]["payload"].get("state")=="ACTIVE_ACK"
elif phase=="quiesce-work-consumed":
 ok=ok and not names and r.get("migration_scan_cursor")==cell["index"]+1
else:
 ok=ok and len(names)==3 and names[0].endswith(".lock.v1") and names[1].endswith(".work-pack.v1") and names[2].endswith(".audit-pack.v1")
 ok=ok and w.get("commit_visibility")=={"kind":"START","committed":False,"marker_digest":None}
 ok=ok and w.get("delete_cursor")==w.get("deleted_count")==cursor
 for item in w["objects"]:
  ok=ok and item.get("prior")=="present" and item.get("after")=="absent" and item.get("identity",{}).get("size")==item.get("expected_size")
 expected_exists=[True,True,True]
 if phase in ("post-object-delete-0","quiesce-delete-cursor"):expected_exists=[False,True,True]
 if phase not in ("quiesce-work-planned","quiesce-delete-will","post-object-delete-0","quiesce-delete-cursor"):expected_exists=[False,False,False]
 ok=ok and [x["objects"][name]["exists"] for name in names]==expected_exists
 ok=ok and all(not x["objects"][name]["exists"] or x["objects"][name].get("exact") is True for name in names)
before={k:br.get(k) for k in ("owned_bytes","active_claims","active_data_claims","counter_generation")}
after=dict(before,owned_bytes=before["owned_bytes"]-b["work"]["metadata"].get("request_bytes",0),active_claims=before["active_claims"]-1,counter_generation=before["counter_generation"]+1)
root_now={k:r.get(k) for k in before}
after_phases=("delta-commit","delta-applied","quiesce-release-applied","quiesce-retire-committed","quiesce-work-consumed")
ok=ok and root_now==(after if phase in after_phases else before)
ops=cell["recovery"]["payload"].get("operations",{})
# The RELEASE delta machine flips ROOT selection only after the delta-will
# barrier (production writes the DELTA_WILL image and directory successor,
# fires catalog-recovery:delta-will, then flips the selector), so the
# selected cell at delta-will is still the pre-flip ACTIVE_ACK image with no
# operation slot; delta-commit's ROOT successor carries the flipped selector,
# so only from there is the DELTA_WILL image with RELEASE=will selected.
if phase=="delta-will":ok=ok and cell["recovery"]["payload"].get("state")=="ACTIVE_ACK" and not ops
if phase=="delta-commit":ok=ok and cell["recovery"]["payload"].get("state")=="DELTA_WILL" and ops.get("RELEASE",{}).get("phase")=="will"
if phase in ("delta-applied","quiesce-release-applied","quiesce-retire-committed","quiesce-work-consumed"):
 ok=ok and cell["recovery"]["payload"].get("state")=="DELTA_APPLIED" and ops.get("RELEASE",{}).get("phase")=="applied"
raise SystemExit(0 if ok else 1)
PY
        }
        t50_quiesce_final_ok() { # base-raw final-raw final-t33
            python3 - "$1" "$2" "$3" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));o=json.load(open(sys.argv[3]));r=x["root"]["metadata"]
cell=o["selected_cell"];ops=cell["recovery"]["payload"].get("operations",{}) if cell else {}
br=b["root"]["metadata"];request=b["work"]["metadata"].get("request_bytes")
ok=(x["work"]["root_match_count"]==1 and x["work"]["metadata"].get("state")=="idle" and
 r.get("migration_scan_cursor")==8192 and request and r.get("owned_bytes")==br.get("owned_bytes")-request and
 r.get("active_claims")==br.get("active_claims")-1 and r.get("active_data_claims")==br.get("active_data_claims") and
 r.get("counter_generation")==br.get("counter_generation")+1 and cell is not None and
 ops.get("RELEASE",{}).get("phase")=="applied" and not o.get("packs") and o.get("lock") is None)
raise SystemExit(0 if ok else 1)
PY
        }

        for t50_phase in owner-active-ack-recovered quiesce-work-planned quiesce-delete-will post-object-delete-0 quiesce-delete-cursor quiesce-all-objects-deleted quiesce-release-will delta-will delta-commit delta-applied quiesce-release-applied quiesce-retire-committed quiesce-work-consumed; do
            t50="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t50-quiesce.XXXXXX")"; t50_uncommitted_fixture "$t50"
            t50_owner_rc=$?; t50_drive "$t50_container" begin-group 64 '' >"$t50/begin.out" 2>"$t50/begin.err"; t50_begin_rc=$?
            t50_drive "$t50_container" quiesce-plan 64 '' >"$t50/plan.out" 2>"$t50/plan.err"; t50_plan_rc=$?
            t50_oracle "$t50_container" >"$t50/base.json" 2>"$t50/base.err"; t50_base_rc=$?
            # Recreate the requested prior from a fresh fixture: base.json is a
            # fully planned work image so exact request/object facts remain an
            # independent anchor for every later phase.
            case "$t50_phase" in
                owner-active-ack-recovered|quiesce-work-planned)
                    rm -rf "$t50"; t50="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t50-quiesce.XXXXXX")"; t50_uncommitted_fixture "$t50"
                    t50_owner_rc=$?; t50_drive "$t50_container" begin-group 64 '' >"$t50/begin.out" 2>"$t50/begin.err"; t50_begin_rc=$?
                    t50_oracle "$t50_container" >"$t50/pre-plan-base.json" 2>"$t50/pre-plan-base.err"
                    t50_drive "$t50_container" quiesce-run 64 "catalog-migration-quiesce:$t50_phase" >"$t50/kill.out" 2>"$t50/kill.err"; t50_kill_rc=$?
                    t50_oracle "$t50_container" >"$t50/prior.json" 2>"$t50/prior.err"; t50_prior_rc=$?
                    if [ "$t50_phase" = owner-active-ack-recovered ]; then
                        # Preserve the killed ACK prior, then advance only to a
                        # planned image to obtain immutable request/object facts
                        # for the final exactly-once counter assertion.
                        t50_drive "$t50_container" quiesce-plan 64 '' >"$t50/anchor-plan.out" 2>"$t50/anchor-plan.err"
                        t50_oracle "$t50_container" >"$t50/base.json" 2>"$t50/base.err"
                    else
                        cp "$t50/prior.json" "$t50/base.json"
                    fi
                    ;;
                *)
                    case "$t50_phase" in
                        delta-will|delta-applied) t50_barrier="catalog-recovery:$t50_phase" ;;
                        delta-commit) t50_barrier="catalog-root:$t50_phase" ;;
                        *) t50_barrier="catalog-migration-quiesce:$t50_phase" ;;
                    esac
                    t50_drive "$t50_container" quiesce-run 64 "$t50_barrier" >"$t50/kill.out" 2>"$t50/kill.err"; t50_kill_rc=$?
                    t50_oracle "$t50_container" >"$t50/prior.json" 2>"$t50/prior.err"; t50_prior_rc=$?
                    ;;
            esac
            t33_oracle "$t50_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t50/prior-t33.json" 2>"$t50/prior-t33.err"; t50_t33_rc=$?
            if [ "$t50_owner_rc" -eq 0 ] && [ "$t50_begin_rc" -eq 0 ] && [ "$t50_kill_rc" -eq 86 ] && [ ! -s "$t50/kill.out" ] && [ ! -s "$t50/kill.err" ] \
                && [ "$t50_prior_rc" -eq 0 ] && [ "$t50_t33_rc" -eq 0 ] \
                && t50_quiesce_prior_ok "$t50/base.json" "$t50/prior.json" "$t50/prior-t33.json" "$t50_phase"; then
                pass "T50 quiesce $t50_phase crash exposes ROOT-selected exact physical prior"
            else
                fail "T50 quiesce $t50_phase crash exposes ROOT-selected exact physical prior" "owner=$t50_owner_rc begin=$t50_begin_rc plan=${t50_plan_rc:-n/a} kill=$t50_kill_rc oracle=$t50_prior_rc/$t50_t33_rc"
            fi
            t50_drive "$t50_container" quiesce-run 64 '' >"$t50/resume.out" 2>"$t50/resume.err"; t50_resume_rc=$?
            t50_oracle "$t50_container" >"$t50/final.json" 2>"$t50/final.err"; t50_final_rc=$?
            t33_oracle "$t50_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t50/final-t33.json" 2>"$t50/final-t33.err"; t50_final_t33_rc=$?
            if [ "$t50_resume_rc" -eq 0 ] && [ "$t50_final_rc" -eq 0 ] && [ "$t50_final_t33_rc" -eq 0 ] \
                && t50_quiesce_final_ok "$t50/base.json" "$t50/final.json" "$t50/final-t33.json"; then
                pass "T50 quiesce $t50_phase replay rolls back once and consumes work"
            else
                fail "T50 quiesce $t50_phase replay rolls back once and consumes work" "resume=$t50_resume_rc oracle=$t50_final_rc/$t50_final_t33_rc"
            fi
            rm -rf "$t50"
        done

        t50_blocked_envelope_ok() { # output
            python3 - "$1" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));e=x.get("error") or {}
raise SystemExit(0 if x.get("ok") is False and e.get("code")=="catalog-root-invalid" and e.get("retryable") is False else 1)
PY
        }
        for t50_bad in replacement unexpected-missing late-marker; do
            t50="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t50-blocked.XXXXXX")"; t50_uncommitted_fixture "$t50"
            t50_drive "$t50_container" begin-group 64 '' >"$t50/begin.out" 2>"$t50/begin.err"
            t50_drive "$t50_container" quiesce-plan 64 '' >"$t50/plan.out" 2>"$t50/plan.err"
            t50_oracle "$t50_container" >"$t50/planned.json" 2>"$t50/planned.err"
            t50_object="$(python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));print(x["work"]["metadata"]["objects"][0]["basename"])' "$t50/planned.json" 2>/dev/null)"
            case "$t50_bad" in
                replacement) cp "$t50_container/$t50_object" "$t50/replacement" && mv "$t50/replacement" "$t50_container/$t50_object" ;;
                unexpected-missing) rm -f "$t50_container/$t50_object" ;;
                late-marker) t33_start "$t50" "$t33_nonce_a" '' >"$t50/late.out" 2>"$t50/late.err" ;;
            esac
            t50_oracle "$t50_container" >"$t50/before.json" 2>"$t50/before.err"; t50_before_rc=$?
            t50_drive "$t50_container" quiesce-advance 64 '' >"$t50/blocked.out" 2>"$t50/blocked.err"; t50_blocked_rc=$?
            t50_oracle "$t50_container" >"$t50/after.json" 2>"$t50/after.err"; t50_after_rc=$?
            t50_shape_rc=1
            case "$t50_bad" in
                replacement) python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));o=x["objects"][sys.argv[2]];raise SystemExit(0 if o["exists"] and o.get("exact") is False else 1)' "$t50/before.json" "$t50_object" && t50_shape_rc=0 ;;
                unexpected-missing) python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));o=x["objects"][sys.argv[2]];raise SystemExit(0 if o["exists"] is False else 1)' "$t50/before.json" "$t50_object" && t50_shape_rc=0 ;;
                late-marker) ;;
            esac
            if [ "$t50_bad" = late-marker ]; then
                t33_oracle "$t50_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t50/before-t33.json" 2>"$t50/before-t33.err"
                python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));raise SystemExit(0 if "START" in x["packs"].get("audit",{}).get("records",{}) else 1)' "$t50/before-t33.json" 2>/dev/null && t50_shape_rc=0
            fi
            if [ "$t50_before_rc" -eq 0 ] && [ "$t50_blocked_rc" -eq 4 ] && [ "$t50_after_rc" -eq 0 ] && [ "$t50_shape_rc" -eq 0 ] \
                && t50_blocked_envelope_ok "$t50/blocked.out" && cmp -s "$t50/before.json" "$t50/after.json"; then
                pass "T50 quiesce $t50_bad is nonretryable and transaction-zero-effect"
            else
                fail "T50 quiesce $t50_bad is nonretryable and transaction-zero-effect" "before=$t50_before_rc blocked=$t50_blocked_rc after=$t50_after_rc shape=$t50_shape_rc"
            fi
            rm -rf "$t50"
        done

        t50_retained_ok() { # base-raw prior-raw prior-t33 kind
            python3 - "$1" "$2" "$3" "$4" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));o=json.load(open(sys.argv[3]));kind=sys.argv[4]
w=x["work"]["metadata"];r=x["root"]["metadata"];br=b["root"]["metadata"]
stable=("owned_bytes","active_claims","active_data_claims","counter_generation")
names=[item["basename"] for item in w.get("objects",[])]
ok=(x["work"]["root_match_count"]==1 and w.get("state")=="committed" and
 w.get("commit_visibility",{}).get("kind")==kind and w.get("commit_visibility",{}).get("committed") is True and
 len(names)==(3 if kind=="START" else 1) and all(x["objects"][name].get("exact") is True for name in names) and
 all(r.get(k)==br.get(k) for k in stable) and w.get("release_phase") is None and
 w.get("counter_prior") is None and w.get("counter_after") is None)
if kind=="START":ok=ok and "START" in o.get("packs",{}).get("audit",{}).get("records",{})
else:
 digest=w.get("creator_key","")[6:];claim=o.get("claims",{}).get(digest,{})
 ok=ok and len(digest)==64 and "OBSERVATION" in claim.get("records",{}) and claim.get("records",{}).get("OBSERVATION",{}).get("payload",{}).get("state")=="claimed"
raise SystemExit(0 if ok else 1)
PY
        }
        t50_plan_prior_ok() { # raw phase
            python3 - "$1" "$2" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));phase=sys.argv[2];g=x["group"]["metadata"];p=x["plan"]
state={"start":"planning","checkpoint":"planning","commit":"group-planned"}[phase]
slots={"start":0,"checkpoint":64,"commit":65}[phase]
selected={"start":0,"checkpoint":64,"commit":65}[phase]
ok=(x["group"]["root_match_count"]==1 and g.get("state")==state and 1<=len(g.get("source_segments",[]))<=16 and
 g.get("plan_total_slots")==slots and p.get("bitmap_shape") is True and len(p.get("bits",[]))==slots and
 p.get("selected_count")==selected and p.get("bits")==[1]*slots and x["scratch"].get("used")==0)
if phase=="start":ok=ok and g.get("plan_segment_index")==0 and g.get("plan_frame_offset")==0
elif phase=="checkpoint":
 ok=ok and g.get("candidate_frame_count")==64 and g.get("candidate_frame_bytes")==p.get("selected_bytes") and g.get("candidate_frame_digest")==p.get("accumulator")
else:
 ok=ok and len(g.get("source_segments",[]))==2 and g.get("planned_frame_count")==65 and g.get("planned_frame_bytes")==p.get("selected_bytes") and g.get("planned_frame_digest")==p.get("accumulator")
raise SystemExit(0 if ok else 1)
PY
        }
        t50_copy_prior_ok() { # raw phase
            python3 - "$1" "$2" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));phase=sys.argv[2];g=x["group"]["metadata"];s=x["scratch"];p=x["plan"]
source=[f for source in x["sources"] for f in source["frames"]]
if phase=="will":
 will=g.get("copy_will") or {};ok=(g.get("state")=="copy-will" and g.get("copy_cursor")==0 and g.get("copy_bytes")==0 and
  s.get("used")==0 and will.get("scratch_offset")==0 and will.get("scratch_after")==will.get("frame_length") and
  will.get("source_frame_digest")==source[0]["digest"])
elif phase=="physical":
 will=g.get("copy_will") or {};ok=(g.get("state")=="copy-will" and g.get("copy_cursor")==0 and g.get("copy_bytes")==0 and
  s.get("used")==will.get("scratch_after")==will.get("frame_length") and len(s.get("frames",[]))==1 and
  s["frames"][0]["digest"]==source[0]["digest"] and p.get("scratch_exact") is False)
elif phase=="did":
 ok=(g.get("state")=="copying" and g.get("copy_will") is None and g.get("copy_cursor")==2 and
  g.get("copy_slot_cursor")==2 and g.get("copy_bytes")==s.get("used") and len(s.get("frames",[]))==2 and
  [f["digest"] for f in s["frames"]]==[f["digest"] for f in source[:2]])
else:
 ok=(g.get("state")=="copied" and g.get("copy_will") is None and g.get("copy_cursor")==g.get("planned_frame_count")==65 and
  g.get("copy_slot_cursor")==g.get("plan_total_slots")==65 and g.get("copy_bytes")==g.get("planned_frame_bytes")==s.get("used") and
  g.get("copy_accumulator")==g.get("planned_frame_digest")==p.get("accumulator") and p.get("scratch_exact") is True and
  p.get("expected_scratch_sha256")==s.get("content_sha256") and g.get("scratch_descriptor_digest")==s.get("descriptor_digest") and
  g.get("copied_scratch_descriptor_digest")==s.get("descriptor_digest"))
raise SystemExit(0 if ok else 1)
PY
        }

        if command -v t40_public >/dev/null 2>&1; then
            t50="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t50-group.XXXXXX")"; t37_fixture "$t50"
            t50_container="$(find "$t50/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
            t40_public "$t50" 65 "$t40_seed_a" 'catalog-claim-pack:public-batch-committed' >"$t50/batch.out" 2>"$t50/batch.err"; t50_batch_rc=$?
            t50_oracle "$t50_container" >"$t50/batch-base.json" 2>"$t50/batch-base.err"; t50_batch_oracle_rc=$?
            t50_drive "$t50_container" begin-group 64 '' >"$t50/begin.out" 2>"$t50/begin.err"; t50_begin_rc=$?

            t50_drive "$t50_container" quiesce-run 64 'catalog-migration-quiesce:quiesce-committed-creator-retained' >"$t50/start-kill.out" 2>"$t50/start-kill.err"; t50_start_kill_rc=$?
            t50_oracle "$t50_container" >"$t50/start-prior.json" 2>"$t50/start-prior.err"; t50_start_prior_rc=$?
            t33_oracle "$t50_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t50/start-prior-t33.json" 2>"$t50/start-prior-t33.err"; t50_start_t33_rc=$?
            if t37_unavailable_ok "$t50_batch_rc" "$t50/batch.out" "$t50/batch.err" \
                && [ "$t50_batch_oracle_rc" -eq 0 ] && [ "$t50_begin_rc" -eq 0 ] \
                && [ "$t50_start_kill_rc" -eq 86 ] && [ "$t50_start_prior_rc" -eq 0 ] && [ "$t50_start_t33_rc" -eq 0 ] \
                && t50_retained_ok "$t50/batch-base.json" "$t50/start-prior.json" "$t50/start-prior-t33.json" START; then
                pass "T50 committed START creator is retained with counters and objects exact"
            else
                fail "T50 committed START creator is retained with counters and objects exact" "batch=$t50_batch_rc/$t50_batch_oracle_rc begin=$t50_begin_rc retained=$t50_start_kill_rc/$t50_start_prior_rc/$t50_start_t33_rc"
            fi

            t50_drive "$t50_container" quiesce-run 64 'catalog-migration-quiesce:quiesce-committed-creator-retained' >"$t50/claim-kill.out" 2>"$t50/claim-kill.err"; t50_claim_kill_rc=$?
            t50_oracle "$t50_container" >"$t50/claim-prior.json" 2>"$t50/claim-prior.err"; t50_claim_prior_rc=$?
            t33_oracle "$t50_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t50/claim-prior-t33.json" 2>"$t50/claim-prior-t33.err"; t50_claim_t33_rc=$?
            if [ "$t50_claim_kill_rc" -eq 86 ] && [ "$t50_claim_prior_rc" -eq 0 ] && [ "$t50_claim_t33_rc" -eq 0 ] \
                && t50_retained_ok "$t50/batch-base.json" "$t50/claim-prior.json" "$t50/claim-prior-t33.json" did-claim; then
                pass "T50 committed did-claim creator is retained with counters and object exact"
            else
                fail "T50 committed did-claim creator is retained with counters and object exact" "retained=$t50_claim_kill_rc/$t50_claim_prior_rc/$t50_claim_t33_rc"
            fi

            t50_drive "$t50_container" quiesce-bounded 64 '' >"$t50/bound1.out" 2>"$t50/bound1.err"; t50_bound1_rc=$?
            t50_drive "$t50_container" quiesce-bounded 64 '' >"$t50/bound2.out" 2>"$t50/bound2.err"; t50_bound2_rc=$?
            t50_oracle "$t50_container" >"$t50/quiesced.json" 2>"$t50/quiesced.err"; t50_quiesced_rc=$?
            t33_oracle "$t50_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t50/quiesced-t33.json" 2>"$t50/quiesced-t33.err"; t50_quiesced_t33_rc=$?
            if [ "$t50_bound1_rc" -eq 0 ] && [ "$t50_bound2_rc" -eq 0 ] && [ "$t50_quiesced_rc" -eq 0 ] && [ "$t50_quiesced_t33_rc" -eq 0 ] \
                && python3 - "$t50/batch-base.json" "$t50/quiesced.json" "$t50/quiesced-t33.json" "$t50/bound1.out" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));o=json.load(open(sys.argv[3]));first=json.load(open(sys.argv[4]))["result"]
stable=("owned_bytes","active_claims","active_data_claims","counter_generation")
ok=(first.get("completed")==64 and first.get("more") is True and x["root"]["metadata"].get("migration_scan_cursor")==8192 and
 x["work"]["metadata"].get("state")=="idle" and all(x["root"]["metadata"].get(k)==b["root"]["metadata"].get(k) for k in stable) and
 len(o.get("claims",{}))==65 and all("OBSERVATION" in c.get("records",{}) for c in o["claims"].values()))
raise SystemExit(0 if ok else 1)
PY
            then
                pass "T50 creator retirement invocation completes at most 64 and retains every committed creator"
            else
                fail "T50 creator retirement invocation completes at most 64 and retains every committed creator" "bounded=$t50_bound1_rc/$t50_bound2_rc oracle=$t50_quiesced_rc/$t50_quiesced_t33_rc"
            fi

            for t50_plan_phase in start checkpoint commit; do
                case "$t50_plan_phase" in
                    start) t50_plan_barrier=group-plan-started ;;
                    checkpoint) t50_plan_barrier=group-plan-checkpoint ;;
                    commit) t50_plan_barrier=group-plan-committed ;;
                esac
                t50_drive "$t50_container" group-plan-once 64 "catalog-migration-group:$t50_plan_barrier" >"$t50/plan-$t50_plan_phase.out" 2>"$t50/plan-$t50_plan_phase.err"; t50_plan_kill_rc=$?
                t50_oracle "$t50_container" >"$t50/plan-$t50_plan_phase.json" 2>"$t50/plan-$t50_plan_phase-oracle.err"; t50_plan_oracle_rc=$?
                if [ "$t50_plan_kill_rc" -eq 86 ] && [ "$t50_plan_oracle_rc" -eq 0 ] \
                    && t50_plan_prior_ok "$t50/plan-$t50_plan_phase.json" "$t50_plan_phase"; then
                    pass "T50 group plan $t50_plan_phase crash preserves source/frame cursor bitmap and accumulator"
                else
                    fail "T50 group plan $t50_plan_phase crash preserves source/frame cursor bitmap and accumulator" "kill=$t50_plan_kill_rc oracle=$t50_plan_oracle_rc"
                fi
            done

            t50_drive "$t50_container" group-copy-once 64 'catalog-migration-group:group-copy-will' >"$t50/copy-will.out" 2>"$t50/copy-will.err"; t50_copy_will_rc=$?
            t50_oracle "$t50_container" >"$t50/copy-will.json" 2>"$t50/copy-will-oracle.err"; t50_copy_will_oracle_rc=$?
            if [ "$t50_copy_will_rc" -eq 86 ] && [ "$t50_copy_will_oracle_rc" -eq 0 ] && t50_copy_prior_ok "$t50/copy-will.json" will; then
                pass "T50 scratch copy will freezes exact source digest and scratch prior"
            else fail "T50 scratch copy will freezes exact source digest and scratch prior" "kill=$t50_copy_will_rc oracle=$t50_copy_will_oracle_rc"; fi

            t50_drive "$t50_container" group-copy-once 64 'catalog-migration-group:scratch-frame-committed' >"$t50/copy-physical.out" 2>"$t50/copy-physical.err"; t50_copy_physical_rc=$?
            t50_oracle "$t50_container" >"$t50/copy-physical.json" 2>"$t50/copy-physical-oracle.err"; t50_copy_physical_oracle_rc=$?
            if [ "$t50_copy_physical_rc" -eq 86 ] && [ "$t50_copy_physical_oracle_rc" -eq 0 ] && t50_copy_prior_ok "$t50/copy-physical.json" physical; then
                pass "T50 physical scratch append and descriptor are durable before did"
            else fail "T50 physical scratch append and descriptor are durable before did" "kill=$t50_copy_physical_rc oracle=$t50_copy_physical_oracle_rc"; fi

            t50_drive "$t50_container" group-copy-once 64 '' >"$t50/did1.out" 2>"$t50/did1.err"; t50_did1_rc=$?
            t50_oracle "$t50_container" >"$t50/did1.json" 2>"$t50/did1-oracle.err"; t50_did1_oracle_rc=$?
            t50_drive "$t50_container" group-copy-once 64 '' >"$t50/will2.out" 2>"$t50/will2.err"; t50_will2_rc=$?
            t50_drive "$t50_container" group-copy-once 64 'catalog-migration-group:group-copy-did' >"$t50/did2.out" 2>"$t50/did2.err"; t50_did2_rc=$?
            t50_oracle "$t50_container" >"$t50/did2.json" 2>"$t50/did2-oracle.err"; t50_did2_oracle_rc=$?
            if [ "$t50_did1_rc" -eq 0 ] && [ "$t50_did1_oracle_rc" -eq 0 ] && [ "$t50_will2_rc" -eq 0 ] && [ "$t50_did2_rc" -eq 86 ] && [ "$t50_did2_oracle_rc" -eq 0 ] \
                && python3 -c 'import json,sys;a=json.load(open(sys.argv[1]));b=json.load(open(sys.argv[2]));raise SystemExit(0 if a["scratch"]["used"]==b["scratch"]["used"]==b["sources"][0]["frames"][0]["length"] and a["scratch"]["descriptor_digest"]==b["scratch"]["descriptor_digest"] else 1)' "$t50/copy-physical.json" "$t50/did1.json" \
                && t50_copy_prior_ok "$t50/did2.json" did; then
                pass "T50 scratch copy did replay does not double-append and advances exact cursor"
            else fail "T50 scratch copy did replay does not double-append and advances exact cursor" "did1=$t50_did1_rc/$t50_did1_oracle_rc will2=$t50_will2_rc did2=$t50_did2_rc/$t50_did2_oracle_rc"; fi

            t50_drive "$t50_container" group-copy-all 64 'catalog-migration-group:group-copy-complete' >"$t50/complete.out" 2>"$t50/complete.err"; t50_complete_rc=$?
            t50_oracle "$t50_container" >"$t50/complete.json" 2>"$t50/complete-oracle.err"; t50_complete_oracle_rc=$?
            if [ "$t50_complete_rc" -eq 86 ] && [ "$t50_complete_oracle_rc" -eq 0 ] && t50_copy_prior_ok "$t50/complete.json" complete; then
                pass "T50 copy-complete ROOT selection requires exact slots bytes accumulator and scratch descriptor"
            else fail "T50 copy-complete ROOT selection requires exact slots bytes accumulator and scratch descriptor" "kill=$t50_complete_rc oracle=$t50_complete_oracle_rc"; fi
            t50_drive "$t50_container" group-copy-all 64 '' >"$t50/repeat.out" 2>"$t50/repeat.err"; t50_repeat_rc=$?
            t50_oracle "$t50_container" >"$t50/repeat.json" 2>"$t50/repeat-oracle.err"; t50_repeat_oracle_rc=$?
            if [ "$t50_repeat_rc" -eq 0 ] && [ "$t50_repeat_oracle_rc" -eq 0 ] && cmp -s "$t50/complete.json" "$t50/repeat.json" \
                && python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));r=x["result"];raise SystemExit(0 if r.get("state")=="copied" and r.get("idempotent") is True else 1)' "$t50/repeat.out"; then
                pass "T50 completed scratch copy replay is byte-idempotent"
            else fail "T50 completed scratch copy replay is byte-idempotent" "repeat=$t50_repeat_rc/$t50_repeat_oracle_rc"; fi
            rm -rf "$t50"
        else
            skip "T50 65-frame bounded plan/copy requires public batch fixture seam"
        fi

        t50_isolated_plan_bounds() {
            PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT/hooks/scripts/runtime_state.py" <<'PY'
import base64,hashlib,importlib.util,os,struct,sys,tempfile
from pathlib import Path
spec=importlib.util.spec_from_file_location("zyz_runtime_state",sys.argv[1]);m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
D=lambda domain,value:hashlib.sha256(domain+value).digest()
class Lock:
 def __init__(self,*args,**kwargs):pass
 def __enter__(self):return self
 def __exit__(self,*args):return False
with tempfile.TemporaryDirectory() as td:
 c=Path(td);(c/".catalog-global-pack.v1").write_bytes(b"\0"*64);(c/".catalog-recovery-pack.v1").write_bytes(b"\0"*64)
 for index in range(1,18):(c/f"source-{index}").write_bytes(b"")
 (c/"scratch").write_bytes(b"")
 members=[{"generation":i,"basename":f"source-{i}","identity_digest":f"{i:064x}","descriptor_digest":f"{i+100:064x}","descriptor_generation":1,"used_length":0} for i in range(1,18)]
 empty=D(b"zyz-migration-active-frame-list-v1",b"").hex()
 proof={"root_meta":{"state":"migration-quiescing","admission_state":"closed","migration_scan_cursor":8192,"migration_scratch_basename":"scratch"},
  "group_meta":{"state":"new-source-initialized","group_generation":1,"source_segment_generation":1},"chain":{"members":members},
  "root":(1,0,b"\0"*65536,(1,b"\0"*32,{},b"\0"*32)),"group":(1,0,b"",(1,b"\0"*32,{},b"\0"*32))}
 def validate(_):
  value=dict(proof);value["global_fd"]=os.open(c/".catalog-global-pack.v1",os.O_RDONLY);return value
 committed=[]
 def commit(_g,_r,_p,metadata,barrier,root_updates=None):
  proof["group_meta"]=metadata;committed.append((barrier,metadata));return {"metadata":metadata,"group_digest":"11"*32,"root_digest":"22"*32}
 m.CatalogFlock=Lock;m._catalog_validate_genesis=validate;m._catalog_group_commit=commit
 m._catalog_segment_chain_projection=lambda *_:{"generation":0,"basename":"scratch","identity_digest":"33"*32,"descriptor_digest":"44"*32,"descriptor_generation":1,"used_length":0}
 first=m._catalog_group_plan_step(c,64);start=proof["group_meta"]
 if first.get("state")!="planning" or len(start.get("source_segments",[]))!=16:raise SystemExit(1)

 raw_frames=[]
 for index in range(65):
  raw=bytearray(64);raw[:8]=b"ZYZFRM1\0";struct.pack_into(">HHII",raw,8,1,4,0,64);raw_frames.append(bytes(raw))
 (c/"source-1").write_bytes(b"".join(raw_frames))
 source={"segment_generation":1,"basename":"source-1","identity_digest":"01"*32,"descriptor_digest":"02"*32,"descriptor_generation":1,"used_length":65*64}
 proof["group_meta"]={"state":"planning","group_generation":1,"source_segments":[source],"plan_segment_index":0,"plan_frame_offset":0,
  "plan_segment_start_slots":0,"plan_total_slots":0,"plan_bitmap_b64":"","plan_selected_source_count":0,"planned_frame_count":0,
  "planned_frame_bytes":0,"planned_frame_digest":empty,"candidate_frame_count":0,"candidate_frame_bytes":0,"candidate_frame_digest":empty}
 counter={"value":0}
 def parsed(raw):
  index=counter["value"];counter["value"]+=1;return {"kind":"claim","payload":{"fixture":index},"digest":hashlib.sha256(b"t50-frame"+bytes([index])).digest()}
 m._catalog_parse_frame=parsed;m._catalog_group_claim_active=lambda *_:True
 checkpoint=m._catalog_group_plan_step(c,64);middle=proof["group_meta"]
 expected=bytes(32)
 acc=D(b"zyz-migration-active-frame-list-v1",b"")
 for index in range(64):
  digest=hashlib.sha256(b"t50-frame"+bytes([index])).digest();acc=D(b"zyz-migration-active-frame-step-v1",acc+struct.pack(">QQ",1,index*64)+digest)
 if (checkpoint.get("frames_scanned")!=64 or middle.get("state")!="planning" or middle.get("plan_total_slots")!=64 or
     base64.b64decode(middle.get("plan_bitmap_b64"))!=b"\xff"*8 or middle.get("candidate_frame_digest")!=acc.hex()):raise SystemExit(1)
 final=m._catalog_group_plan_step(c,64);planned=proof["group_meta"]
 digest=hashlib.sha256(b"t50-frame"+bytes([64])).digest();acc=D(b"zyz-migration-active-frame-step-v1",acc+struct.pack(">QQ",1,64*64)+digest)
 if (final.get("state")!="group-planned" or final.get("frames_scanned")!=1 or planned.get("plan_total_slots")!=65 or
     base64.b64decode(planned.get("plan_bitmap_b64"))!=b"\xff"*8+b"\x80" or planned.get("planned_frame_count")!=65 or
     planned.get("planned_frame_bytes")!=65*64 or planned.get("planned_frame_digest")!=acc.hex()):raise SystemExit(1)

 proof["group_meta"]={"state":"planning","group_generation":1,"source_segments":[dict(source,used_length=0)],"plan_segment_index":0,
  "plan_frame_offset":0,"plan_segment_start_slots":0,"plan_total_slots":0,"plan_bitmap_b64":"","plan_selected_source_count":0,
  "planned_frame_count":0,"planned_frame_bytes":0,"planned_frame_digest":empty,"candidate_frame_count":1,
  "candidate_frame_bytes":983041,"candidate_frame_digest":"55"*32}
 try:m._catalog_group_plan_step(c,64)
 except m.StateError as exc:
  if exc.code!="catalog-root-invalid" or exc.message!="first migration source exceeds scratch":raise
 else:raise SystemExit(1)
PY
        }
        if t50_isolated_plan_bounds; then
            pass "T50 isolated planner caps 17 sources at 16 and 65 frames at 64 and rejects incomplete first source"
        else
            fail "T50 isolated planner caps 17 sources at 16 and 65 frames at 64 and rejects incomplete first source"
        fi
    else
        skip "T50 physical quiesce recovery requires T33 durable GENESIS capability"
    fi
else
    skip "T50 isolated migration quiesce/group-copy coverage requires python runtime backend"
fi

# ---------------------------------------------------------------------------
# T51  Migration cutover, hybrid reader authority, PREVIS free, source
# retirement, repeated groups, dense pressure and public accounting.  T50 is
# the immutable-copy prefix only.  The raw oracle above now also decodes the
# fixed hybrid-chain header/anchors/trailer and every ROOT-visible object; do
# not read T50 green checks as proof of any T51 claim.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1 && [ -f hooks/scripts/runtime_state.py ]; then
    t51_surface="$(python3 -c 'import ast,json,sys
t=ast.parse(open(sys.argv[1],encoding="utf-8").read());f={n.name:n for n in t.body if isinstance(n,ast.FunctionDef)}
want={"_catalog_previs_group_visible","_catalog_previs_free","_catalog_previs_free_step","_catalog_group_retire_step","_catalog_group_continue_or_finish","_catalog_chain_member","_gc_schedule_due","gc_step_command"}
barriers={n.value for n in ast.walk(t) if isinstance(n,ast.Constant) and isinstance(n.value,str)}
need={"group-cutover-will","group-visible","will-previs-cell-free","previs-cell-free","did-previs-cell-free","previs-empty-consumed","next-scratch-will","next-scratch-physical-initialized","next-scratch-ready","retired-delete-will","retired-source-physical-deleted","retired-delete-counter-committed","group-committed","group-next-ready","will-migration-finish","migration-committed"}
print(json.dumps({"missing":sorted(want-set(f)),"barriers":sorted(need-barriers)},sort_keys=True,separators=(",",":")))' hooks/scripts/runtime_state.py)"
    if printf '%s' "$t51_surface" | python3 -c 'import json,sys;x=json.load(sys.stdin);raise SystemExit(0 if not x["missing"] and not x["barriers"] else 1)'; then
        pass "T51 cutover free retirement continuation and public scheduler seams remain callable"
    else
        fail "T51 cutover free retirement continuation and public scheduler seams remain callable" "$t51_surface"
    fi

    t51_drive() { # container action barrier [limit]
        PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT/hooks/scripts/runtime_state.py" "$1" "$2" "${3:-}" "${4:-64}" <<'PY'
import importlib.util,json,os,sys
from pathlib import Path
runtime,container,action,barrier,limit=sys.argv[1:];limit=int(limit)
spec=importlib.util.spec_from_file_location("zyz_runtime_state",runtime)
m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m);c=Path(container)
if barrier:os.environ["ZYZ_TEST_TRANSITION_STOP_AFTER"]=barrier
else:os.environ.pop("ZYZ_TEST_TRANSITION_STOP_AFTER",None)
def proof():
 value=m._catalog_validate_genesis(c);os.close(value.pop("global_fd"));return value
try:
 p=proof();g=p["group_meta"]
 if action=="cutover":
  result=m._catalog_previs_group_visible(c,g["group_generation"],g["source_segment_generation"])
 elif action=="free-step":result=m._catalog_previs_free_step(c,limit)
 elif action=="retire-step":result=m._catalog_group_retire_step(c)
 elif action=="continue":result=m._catalog_group_continue_or_finish(c)
 elif action=="validate":result={"state":p["root_meta"]["state"],"group":g["state"]}
 elif action=="reader":
  with m.CatalogFlock(c):
   p=m._catalog_validate_genesis(c);os.close(p.pop("global_fd"))
   # _catalog_validate_genesis opens global_fd O_RDONLY, but _gc_claim_sweep
   # always writes a ROOT successor to advance the cursor.  Mirror the
   # production caller (runtime_state.py:13724-13736): close the RO fd,
   # reopen global O_RDWR|O_NOFOLLOW, keep recovery O_RDONLY|O_NOFOLLOW.
   fd=os.open(os.fsencode(c/".catalog-global-pack.v1"),os.O_RDWR|getattr(os,"O_NOFOLLOW",0))
   rfd=os.open(os.fsencode(c/".catalog-recovery-pack.v1"),os.O_RDONLY|getattr(os,"O_NOFOLLOW",0))
   try:result=m._gc_claim_sweep(c,p,fd,rfd,limit)
   finally:os.close(fd);os.close(rfd)
 elif action=="tamper-counter":
  result=m._catalog_commit_root_updates(c,p,{"owned_bytes":p["root_meta"]["owned_bytes"]+1},"t51-counter-tamper")["root_meta"]
 elif action=="claim-create":
  import hashlib,re
  raw="resume/agent";key=(re.sub(r"[^A-Za-z0-9._-]","_",raw)[:32]+"."+hashlib.sha256(raw.encode()).hexdigest())
  os.environ["ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES"]="67108864";os.environ["ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES"]="134217728"
  result=m._catalog_claim_create(c,"snapshot-temp",key,"t51-post-migration",0,2000000000,m._gc_config())
 elif action=="outcome":
  os.environ["ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES"]="67108864";os.environ["ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES"]="134217728"
  result=m._catalog_migration_commit_outcome(c,m._gc_config())
 elif action=="finish-group":
  result=None
  for _ in range(32768):
   p=proof();state=p["group_meta"]["state"]
   if state in ("group-visible","freeing"):result=m._catalog_previs_free_step(c,limit)
   elif state in ("previs-cells-consumed","next-scratch-will","next-scratch-ready","retired-delete-will"):
    result=m._catalog_group_retire_step(c)
   elif state=="group-committed":break
   else:raise m.StateError("gc-internal","T51 group driver phase is invalid",5)
  else:raise m.StateError("gc-internal","T51 group driver did not converge",5)
 elif action=="finish-migration":
  result=None
  for _ in range(65536):
   p=proof();root=p["root_meta"];state=p["group_meta"]["state"]
   if root["state"]=="migration-committed":result={"state":"migration-committed","idempotent":True};break
   if state=="group-committed":result=m._catalog_group_continue_or_finish(c);continue
   if state=="idle":
    generation=root.get("migration_source_segment_generation")
    result=m._catalog_previs_group_begin(c,generation);continue
   if state in ("new-source-initialized","planning"):
    result=m._catalog_group_plan_step(c,limit);continue
   if state in ("group-planned","copy-will","copying"):
    result=m._catalog_group_copy_step(c,limit);continue
   if state in ("copied","cutover-will"):
    result=m._catalog_previs_group_visible(c,p["group_meta"]["group_generation"],p["group_meta"]["source_segment_generation"]);continue
   if state in ("group-visible","freeing"):
    result=m._catalog_previs_free_step(c,limit);continue
   if state in ("previs-cells-consumed","next-scratch-will","next-scratch-ready","retired-delete-will"):
    result=m._catalog_group_retire_step(c);continue
   raise m.StateError("gc-internal","T51 migration driver phase is invalid",5)
  else:raise m.StateError("gc-internal","T51 migration driver did not converge",5)
 else:raise m.StateError("gc-internal","unknown T51 action",5)
 print(json.dumps({"ok":True,"action":action,"result":result},sort_keys=True,separators=(",",":")))
except m.StateError as exc:
 print(json.dumps({"ok":False,"action":action,"error":{"code":exc.code,"message":exc.message,"retryable":exc.retryable}},sort_keys=True,separators=(",",":")))
 raise SystemExit(exc.exit_code)
PY
    }

    t51_prepare_copied() { # container
        t50_drive "$1" begin-group 64 '' >/dev/null 2>&1 || return
        PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT/hooks/scripts/runtime_state.py" "$1" <<'PY'
import importlib.util,os,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("zyz_runtime_state",sys.argv[1]);m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m);c=Path(sys.argv[2])
for _ in range(32768):
 r=m._catalog_quiesce_cancel_previsible(c,64)
 if r["state"]=="quiesced":break
else:raise SystemExit(1)
for _ in range(32768):
 r=m._catalog_group_plan_step(c,64)
 if r["state"]=="group-planned":break
else:raise SystemExit(1)
for _ in range(32768):
 r=m._catalog_group_copy_step(c,64)
 if r["state"]=="copied":break
else:raise SystemExit(1)
PY
    }

    t51_fixture() { # sandbox claim-count
        t37_fixture "$1"
        t51_container="$(find "$1/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
        t40_public "$1" "$2" "$t40_seed_a" 'catalog-claim-pack:public-batch-committed' >"$1/batch.out" 2>"$1/batch.err"
        t51_batch_rc=$?
        t51_prepare_copied "$t51_container"
    }

    t51_files_digest() { # container
        python3 - "$1" <<'PY'
import hashlib,json,os,sys
p=sys.argv[1];rows=[]
for name in sorted(os.listdir(p)):
 path=os.path.join(p,name)
 if not os.path.isfile(path):continue
 h=hashlib.sha256()
 with open(path,"rb") as f:
  while True:
   block=f.read(1048576)
   if not block:break
   h.update(block)
 rows.append([name,os.path.getsize(path),h.hexdigest()])
print(json.dumps(rows,separators=(",",":")))
PY
    }

    t51_cutover_ok() { # before after phase
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));phase=sys.argv[3]
g=x["group"]["metadata"];r=x["root"]["metadata"];old=b["chain"]["digest"]
scratch=[row for row in x["chain"]["entries"] if row.get("kind")=="scratch-object"]
if phase=="will":
 w=g.get("cutover_will") or {};ok=(g.get("state")=="cutover-will" and x["chain"]["digest"]==old and not scratch and
  w.get("prior_chain_digest")==old and w.get("scratch_descriptor_digest")==b["scratch"]["descriptor_digest"] and
  w.get("plan_digest")==g.get("planned_frame_digest") and w.get("source_group_digest")==g.get("source_group_digest"))
else:
 a=scratch[0] if len(scratch)==1 else {};obj=x["chain"]["objects"][0]["objects"][0] if len(scratch)==1 else {}
 ok=(g.get("state")=="group-visible" and r.get("state")=="migration-active" and r.get("admission_state")=="closed" and
  x["chain"]["digest"]==g.get("visible_chain_digest") and
  a.get("basename")==b["scratch"]["basename"] and a.get("descriptor_digest")==b["scratch"]["descriptor_digest"] and
  a.get("used_length")==b["scratch"]["used"] and obj.get("content_sha256")==b["scratch"]["content_sha256"] and
  g.get("group_visible_digest")==r.get("previs_group_visible_digest") and all(row.get("exists") for row in x["sources"]))
raise SystemExit(0 if ok else 1)
PY
    }

    if [ "${t33_supported:-0}" -eq 1 ] && command -v t40_public >/dev/null 2>&1; then
        for t51_phase in will visible; do
            t51="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t51-cutover.XXXXXX")";t51_fixture "$t51" 2;t51_fixture_rc=$?
            t50_oracle "$t51_container" >"$t51/before.json" 2>"$t51/before.err";t51_before_rc=$?
            # cutover is a two-transaction machine: the first call from copied
            # commits group-cutover-will (and fires that barrier), the second
            # (from cutover-will) commits group-visible.  The will phase kills
            # on the first drive; the visible phase must first advance
            # copied->cutover-will unbarriered, then kill on the second drive so
            # the group-visible barrier is genuinely reached.  before.json stays
            # captured at copied state: cutover does not touch the scratch
            # object, so the visible branch's b["scratch"] prior is unchanged
            # (the replay row below relies on the same copied-state before).
            if [ "$t51_phase" = will ]; then t51_barrier='catalog-migration-group:group-cutover-will'; else t51_barrier='catalog-migration-group:group-visible'; t51_drive "$t51_container" cutover '' >"$t51/advance.out" 2>"$t51/advance.err";fi
            t51_drive "$t51_container" cutover "$t51_barrier" >"$t51/kill.out" 2>"$t51/kill.err";t51_kill_rc=$?
            t50_oracle "$t51_container" >"$t51/prior.json" 2>"$t51/prior.err";t51_prior_rc=$?
            if [ "$t51_fixture_rc" -eq 0 ] && [ "$t51_before_rc" -eq 0 ] && [ "$t51_kill_rc" -eq 86 ] && [ "$t51_prior_rc" -eq 0 ] \
                && t51_cutover_ok "$t51/before.json" "$t51/prior.json" "$t51_phase"; then
                pass "T51 ROOT group cutover $t51_phase barrier has exact physical hybrid prior"
            else
                fail "T51 ROOT group cutover $t51_phase barrier has exact physical hybrid prior" "fixture=$t51_fixture_rc before=$t51_before_rc kill=$t51_kill_rc oracle=$t51_prior_rc"
            fi
            t51_drive "$t51_container" cutover '' >"$t51/replay.out" 2>"$t51/replay.err";t51_replay_rc=$?
            t50_oracle "$t51_container" >"$t51/replay.json" 2>"$t51/replay-oracle.err";t51_replay_oracle_rc=$?
            if [ "$t51_replay_rc" -eq 0 ] && [ "$t51_replay_oracle_rc" -eq 0 ] && t51_cutover_ok "$t51/before.json" "$t51/replay.json" visible; then
                pass "T51 ROOT group cutover $t51_phase replay selects one scratch authority"
            else
                fail "T51 ROOT group cutover $t51_phase replay selects one scratch authority" "replay=$t51_replay_rc/$t51_replay_oracle_rc"
            fi
            rm -rf "$t51"
        done

        t51="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t51-reader.XXXXXX")";t51_fixture "$t51" 2;t51_fixture_rc=$?
        t50_oracle "$t51_container" >"$t51/copied.json" 2>"$t51/copied.err";t51_copied_rc=$?
        t51_drive "$t51_container" cutover '' >/dev/null 2>&1;t51_drive "$t51_container" cutover '' >/dev/null 2>&1
        t50_oracle "$t51_container" >"$t51/visible.json" 2>"$t51/visible.err";t51_visible_rc=$?
        t51_old="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sources"][0]["basename"])' "$t51/copied.json" 2>/dev/null)"
        python3 - "$t51_container/$t51_old" <<'PY'
import os,sys
fd=os.open(sys.argv[1],os.O_RDWR)
try:
 b=os.pread(fd,1,0);os.pwrite(fd,bytes([b[0]^1]),0);os.fsync(fd)
finally:os.close(fd)
PY
        t51_drive "$t51_container" reader ''  >"$t51/reader.out" 2>"$t51/reader.err";t51_reader_rc=$?
        if [ "$t51_fixture_rc" -eq 0 ] && [ "$t51_copied_rc" -eq 0 ] && [ "$t51_visible_rc" -eq 0 ] && [ "$t51_reader_rc" -eq 0 ] \
            && python3 - "$t51/copied.json" "$t51/visible.json" "$t51/reader.out" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));r=json.load(open(sys.argv[3]))["result"]
source=[f["digest"] for s in b["sources"] for f in s["frames"] if f["kind"]=="claim"]
scratch=[f["digest"] for row in x["chain"]["objects"] for o in row["objects"] for f in o["frames"] if f["kind"]=="claim"]
candidates=[v.get("logical_key_sha256") for v in r.get("candidates",[])]
expected=[f["payload"].get("logical_key_sha256") for s in b["sources"] for f in s["frames"] if f["kind"]=="claim"]
ok=(source==scratch and len(source)==2 and r.get("claims_scanned")==2 and candidates==expected)
raise SystemExit(0 if ok else 1)
PY
        then
            pass "T51 reader follows visible scratch anchor and ignores mutated retired source bytes"
        else
            fail "T51 reader follows visible scratch anchor and ignores mutated retired source bytes" "fixture=$t51_fixture_rc raw=$t51_copied_rc/$t51_visible_rc reader=$t51_reader_rc"
        fi
        rm -rf "$t51"

        for t51_bad in replacement missing hybrid-corruption; do
            t51="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t51-anchor-bad.XXXXXX")";t51_fixture "$t51" 2
            t51_drive "$t51_container" cutover '' >/dev/null 2>&1;t51_drive "$t51_container" cutover '' >/dev/null 2>&1
            t50_oracle "$t51_container" >"$t51/visible.json" 2>/dev/null
            t51_anchor="$(python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));print(next(e["basename"] for e in x["chain"]["entries"] if e.get("kind")=="scratch-object"))' "$t51/visible.json")"
            case "$t51_bad" in
                replacement) mv "$t51_container/$t51_anchor" "$t51_container/$t51_anchor.saved";cp "$t51_container/$t51_anchor.saved" "$t51_container/$t51_anchor" ;;
                missing) mv "$t51_container/$t51_anchor" "$t51_container/$t51_anchor.missing" ;;
                hybrid-corruption)
                    python3 - "$t51_container/.catalog-global-pack.v1" "$t51/visible.json" <<'PY'
import hashlib,json,os,sys
path=sys.argv[1];bank=json.load(open(sys.argv[2]))["root"]["bank"];offset=32768+bank*65536
fd=os.open(path,os.O_RDWR)
try:
 raw=bytearray(os.pread(fd,65536,offset));raw[5120+240]^=1;raw[56:88]=bytes(32)
 raw[56:88]=hashlib.sha256(b"zyz-pack-image-v1"+raw).digest();os.pwrite(fd,raw,offset);os.fsync(fd)
finally:os.close(fd)
PY
                    ;;
            esac
            t51_files_digest "$t51_container" >"$t51/tampered.sha"
            t51_drive "$t51_container" validate '' >"$t51/blocked.out" 2>"$t51/blocked.err";t51_blocked_rc=$?
            t51_files_digest "$t51_container" >"$t51/after.sha"
            if [ "$t51_blocked_rc" -eq 4 ] && cmp -s "$t51/tampered.sha" "$t51/after.sha" \
                && python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));raise SystemExit(0 if x.get("ok") is False and x.get("error",{}).get("code")=="catalog-root-invalid" and x["error"].get("retryable") is False else 1)' "$t51/blocked.out"; then
                pass "T51 visible hybrid $t51_bad is fail-closed and transaction-zero-effect"
            else
                fail "T51 visible hybrid $t51_bad is fail-closed and transaction-zero-effect" "rc=$t51_blocked_rc"
            fi
            rm -rf "$t51"
        done

        t51_previs_fixture() { # sandbox
            t33_fixture "$1"
            # A PREVISible cell is a creator reserved BEFORE the migration
            # begins (admission is still open): once admission closes,
            # _catalog_capacity_gate (runtime_state.py:4434-4437) rejects every
            # new reservation with catalog-migration-pressure, so a reserved
            # cell can never be created inside the quiescing window.  Seed the
            # reserved creator first (root-successor-durable leaves one RESERVED
            # cell, owned_bytes at the 33554432 GENESIS floor), exactly as the
            # executed-green T36 PREVIS suite (suite 3419) does.
            t33_start "$1" "$t33_nonce_a" 'catalog-root:root-successor-durable' >"$1/reserve.out" 2>"$1/reserve.err"
            t51_reserve_rc=$?
            t51_container="$(find "$1/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
            # Drive the WHOLE migration through the production dispatcher
            # _catalog_migration_step (exactly what public gc-step orchestrates
            # and what green T36 exercises): with owned_bytes >= high-water it
            # runs quiesce-begin -> previs-group-begin -> cancel-previsible (the
            # reserved cell becomes the PREVIS_CANCELLED cell, cancel_count=1,
            # cursor advances to CELL_COUNT) -> group-plan -> group-copy ->
            # previs-group-visible, one bounded phase per call, until the group
            # reaches group-visible.  This replaces the earlier hand-rolled
            # begin-group/cancel/plan/copy sequence, which called low-level
            # helpers out of order (and a nonexistent t51_drive begin-group
            # action), leaving root active so quiesce never started.
            PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT/hooks/scripts/runtime_state.py" "$t51_container" <<'PY'
import importlib.util,os,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("zyz_runtime_state",sys.argv[1]);m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m);c=Path(sys.argv[2])
# High water below the seeded owned_bytes so the dispatcher opens a migration.
os.environ["ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES"]="33554432";os.environ["ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES"]="67108864"
config=m._gc_config()
def group_state():
 p=m._catalog_validate_genesis(c);os.close(p.pop("global_fd"));return p["group_meta"].get("state")
for _ in range(32768):
 if group_state()=="group-visible":break
 m._catalog_migration_step(c,config)
else:raise SystemExit(1)
PY
        }
        t51_previs_ok() { # base-t33 raw t33 phase
            python3 - "$1" "$2" "$3" "$4" <<'PY'
import hashlib,json,struct,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));o=json.load(open(sys.argv[3]));phase=sys.argv[4]
r=x["root"]["metadata"];g=x["group"]["metadata"];h=o["cell_history"][0]
cancelled=max((v for v in h["recoveries"] if v["payload"].get("state")=="PREVIS_CANCELLED"),key=lambda v:v["generation"])
pv=cancelled["payload"].get("previs") or {};free=max((v for v in h["recoveries"] if v["payload"].get("state")=="FREE"),key=lambda v:v["generation"],default=None)
stable=("owned_bytes","active_claims","active_data_claims","counter_generation")
ok=(g.get("cancel_count")==1 and r.get("previs_cancel_count")==1 and all(r.get(k)==b["root_meta"].get(k) for k in stable) and
 pv.get("phase")=="cancelled" and pv.get("group_generation")==g.get("group_generation") and
 pv.get("source_segment_generation")==g.get("source_segment_generation") and not cancelled["payload"].get("operations"))
if phase=="will":
 w=r.get("previs_free_will") or {};ok=ok and g.get("state")=="group-visible" and o.get("selected_cell") is not None and free is None
 ok=ok and w.get("cell_index")==h["index"] and w.get("cancel_digest")==pv.get("cancel_digest") and w.get("group_visible_digest")==g.get("group_visible_digest")
elif phase=="physical":
 # At the catalog-recovery:previs-cell-free barrier the recovery FREE image is
 # durable but the FREE directory image has NOT been written yet (production
 # writes it only AFTER this barrier, runtime_state.py:7037-7050), and ROOT has
 # not yet cleared previs_free_will.  Assert the exact at-barrier state: recovery
 # FREE present at the advanced generation, previs_free_will still bound, and NO
 # FREE directory yet.  The directory-image assertions belong to the did phase.
 w=r.get("previs_free_will") or {};ok=ok and g.get("state")=="group-visible" and o.get("selected_cell") is not None and free is not None
 free_dirs=[d for d in h["directories"] if d.get("state")==0 and d.get("cell_generation")==free.get("generation") and d.get("free_generation")==free.get("free_generation")]
 ok=ok and free.get("free_generation")==o["selected_cell"].get("free_generation",0)+1 and len(free_dirs)==0 and w.get("cell_index")==h["index"] and isinstance(w.get("free_receipt_record_digest"),str) and r.get("last_previs_free_receipt_record_digest") is None
else:
 prior=hashlib.sha256(b"zyz-previs-consumed-v1").digest()
 record=bytes.fromhex(r.get("last_previs_free_receipt_record_digest"))
 consumed=hashlib.sha256(b"zyz-previs-consumed-successor-v1"+prior+struct.pack(">I",h["index"])+record).hexdigest()
 ok=ok and g.get("state")=="previs-cells-consumed" and g.get("free_count")==1 and g.get("consumed_digest")==consumed
 ok=ok and r.get("previs_free_will") is None and o.get("selected_cell") is None and free is not None
 # The FREE directory image is written after the physical barrier, so the did
 # phase is where the freed directory must exist exactly once with field-2
 # bearing the ROOT-published free receipt record digest.
 free_dirs=[d for d in h["directories"] if d.get("state")==0 and d.get("cell_generation")==free.get("generation") and d.get("free_generation")==free.get("free_generation")]
 ok=ok and len(free_dirs)==1 and record.hex()==free_dirs[0]["fields"][2]
raise SystemExit(0 if ok else 1)
PY
        }

        for t51_phase in will physical did; do
            t51="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t51-previs.XXXXXX")";t51_previs_fixture "$t51";t51_fixture_rc=$?
            t33_oracle "$t51_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t51/base-t33.json" 2>"$t51/base-t33.err";t51_base_t33_rc=$?
            t50_oracle "$t51_container" >"$t51/base.json" 2>"$t51/base.err";t51_base_rc=$?
            case "$t51_phase" in
                will) t51_barrier='catalog-root:will-previs-cell-free' ;;
                physical) t51_barrier='catalog-recovery:previs-cell-free' ;;
                did) t51_barrier='catalog-root:did-previs-cell-free' ;;
            esac
            t51_drive "$t51_container" free-step "$t51_barrier" >"$t51/kill.out" 2>"$t51/kill.err";t51_kill_rc=$?
            t50_oracle "$t51_container" >"$t51/prior.json" 2>"$t51/prior.err";t51_prior_rc=$?
            t33_oracle "$t51_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t51/prior-t33.json" 2>"$t51/prior-t33.err";t51_prior_t33_rc=$?
            if [ "$t51_fixture_rc" -eq 0 ] && [ "$t51_base_rc" -eq 0 ] && [ "$t51_base_t33_rc" -eq 0 ] \
                && [ "$t51_kill_rc" -eq 86 ] && [ "$t51_prior_rc" -eq 0 ] && [ "$t51_prior_t33_rc" -eq 0 ] \
                && t51_previs_ok "$t51/base-t33.json" "$t51/prior.json" "$t51/prior-t33.json" "$t51_phase"; then
                pass "T51 PREVIS free $t51_phase barrier preserves exact CELL ROOT GROUP prior"
            else
                fail "T51 PREVIS free $t51_phase barrier preserves exact CELL ROOT GROUP prior" "fixture=$t51_fixture_rc base=$t51_base_rc/$t51_base_t33_rc kill=$t51_kill_rc prior=$t51_prior_rc/$t51_prior_t33_rc"
            fi
            t51_drive "$t51_container" free-step '' >"$t51/replay.out" 2>"$t51/replay.err";t51_replay_rc=$?
            t50_oracle "$t51_container" >"$t51/final.json" 2>/dev/null
            t33_oracle "$t51_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t51/final-t33.json" 2>/dev/null
            t51_files_digest "$t51_container" >"$t51/once.sha";t51_drive "$t51_container" free-step '' >/dev/null 2>&1;t51_files_digest "$t51_container" >"$t51/twice.sha"
            if [ "$t51_replay_rc" -eq 0 ] && t51_previs_ok "$t51/base-t33.json" "$t51/final.json" "$t51/final-t33.json" did \
                && cmp -s "$t51/once.sha" "$t51/twice.sha"; then
                pass "T51 PREVIS free $t51_phase replay consumes one cell exactly once"
            else
                fail "T51 PREVIS free $t51_phase replay consumes one cell exactly once" "replay=$t51_replay_rc"
            fi
            rm -rf "$t51"
        done

        t51="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t51-previs-empty.XXXXXX")";t51_fixture "$t51" 2
        t51_drive "$t51_container" cutover '' >/dev/null 2>&1;t51_drive "$t51_container" cutover '' >/dev/null 2>&1
        t51_drive "$t51_container" free-step 'catalog-migration-group:previs-empty-consumed' >"$t51/kill.out" 2>"$t51/kill.err";t51_empty_rc=$?
        t50_oracle "$t51_container" >"$t51/prior.json" 2>"$t51/prior.err";t51_empty_oracle_rc=$?
        t51_drive "$t51_container" free-step '' >"$t51/replay.out" 2>"$t51/replay.err";t51_empty_replay_rc=$?
        t50_oracle "$t51_container" >"$t51/final.json" 2>/dev/null
        if [ "$t51_empty_rc" -eq 86 ] && [ "$t51_empty_oracle_rc" -eq 0 ] && [ "$t51_empty_replay_rc" -eq 0 ] \
            && python3 - "$t51/prior.json" "$t51/final.json" <<'PY'
import json,sys
a=json.load(open(sys.argv[1]));b=json.load(open(sys.argv[2]));ga=a["group"]["metadata"];gb=b["group"]["metadata"]
ok=(ga.get("state")==gb.get("state")=="previs-cells-consumed" and ga.get("cancel_count")==ga.get("free_count")==0 and
 ga.get("consumed_digest")==gb.get("consumed_digest") and a["chain"]["digest"]==b["chain"]["digest"])
raise SystemExit(0 if ok else 1)
PY
        then
            pass "T51 empty PREVIS set commits consumption without fabricating a cell or receipt"
        else
            fail "T51 empty PREVIS set commits consumption without fabricating a cell or receipt" "kill=$t51_empty_rc oracle=$t51_empty_oracle_rc replay=$t51_empty_replay_rc"
        fi
        rm -rf "$t51"

        t51_retire_ok() { # base prior phase
            python3 - "$1" "$2" "$3" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));phase=sys.argv[3];g=x["group"]["metadata"];r=x["root"]["metadata"]
sources=x["sources"];br=b["root"]["metadata"];bg=b["group"]["metadata"]
state={"next-will":"next-scratch-will","physical-init":"next-scratch-will","next-ready":"next-scratch-ready",
 "delete-will":"retired-delete-will","physical-delete":"retired-delete-will","counter":"next-scratch-ready","commit":"group-committed"}[phase]
ok=(len(sources)==2 and g.get("state")==state and x["chain"]["digest"]==b["chain"]["digest"] and
 g.get("consumed_digest")==bg.get("consumed_digest") and r.get("previs_group_visible_digest")==br.get("previs_group_visible_digest"))
if phase=="next-will":ok=ok and sources[0].get("fact_exact") is True and sources[1].get("fact_exact") is True
else:ok=ok and sources[0].get("exists") is True and sources[0].get("fact_exact") is False and sources[0].get("used")==0
if phase in ("next-will","physical-init","next-ready","delete-will"):
 ok=ok and sources[1].get("exists") is True and r.get("owned_bytes")==br.get("owned_bytes")
else:
 ok=ok and sources[1].get("exists") is False
 if phase=="physical-delete":ok=ok and r.get("owned_bytes")==br.get("owned_bytes")
 else:ok=ok and r.get("owned_bytes")==br.get("owned_bytes")-1048576 and r.get("counter_generation")==br.get("counter_generation")+1
if phase in ("next-ready","delete-will","physical-delete","counter","commit"):
 ok=ok and r.get("migration_scratch_basename")==sources[0]["basename"]
if phase=="commit":
 ok=ok and g.get("retired_bytes")==1048576 and r.get("previs_cancel_count")==0 and g.get("consumed_digest")==bg.get("consumed_digest")
raise SystemExit(0 if ok else 1)
PY
        }

        for t51_phase in next-will physical-init next-ready delete-will physical-delete counter commit; do
            t51="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t51-retire.XXXXXX")";t51_fixture "$t51" 65;t51_fixture_rc=$?
            t51_drive "$t51_container" cutover '' >/dev/null 2>&1;t51_drive "$t51_container" cutover '' >/dev/null 2>&1
            t51_drive "$t51_container" free-step '' >/dev/null 2>&1
            t50_oracle "$t51_container" >"$t51/base.json" 2>"$t51/base.err";t51_base_rc=$?
            case "$t51_phase" in
                next-will) t51_barrier='catalog-migration-group:next-scratch-will' ;;
                physical-init) t51_barrier='catalog-migration-group:next-scratch-physical-initialized' ;;
                next-ready) t51_barrier='catalog-migration-group:next-scratch-ready' ;;
                delete-will) t51_barrier='catalog-migration-group:retired-delete-will' ;;
                physical-delete) t51_barrier='catalog-migration-group:retired-source-physical-deleted' ;;
                counter) t51_barrier='catalog-migration-group:retired-delete-counter-committed' ;;
                commit) t51_barrier='catalog-migration-group:group-committed' ;;
            esac
            t51_drive "$t51_container" finish-group "$t51_barrier" >"$t51/kill.out" 2>"$t51/kill.err";t51_kill_rc=$?
            t50_oracle "$t51_container" >"$t51/prior.json" 2>"$t51/prior.err";t51_prior_rc=$?
            if [ "$t51_fixture_rc" -eq 0 ] && [ "$t51_base_rc" -eq 0 ] && [ "$t51_kill_rc" -eq 86 ] && [ "$t51_prior_rc" -eq 0 ] \
                && t51_retire_ok "$t51/base.json" "$t51/prior.json" "$t51_phase"; then
                pass "T51 old-source retirement $t51_phase barrier has exact physical and counter prior"
            else
                fail "T51 old-source retirement $t51_phase barrier has exact physical and counter prior" "fixture=$t51_fixture_rc base=$t51_base_rc kill=$t51_kill_rc oracle=$t51_prior_rc"
            fi
            t51_drive "$t51_container" finish-group '' >"$t51/replay.out" 2>"$t51/replay.err";t51_replay_rc=$?
            t50_oracle "$t51_container" >"$t51/final.json" 2>/dev/null
            t51_files_digest "$t51_container" >"$t51/once.sha";t51_drive "$t51_container" finish-group '' >/dev/null 2>&1;t51_files_digest "$t51_container" >"$t51/twice.sha"
            if [ "$t51_replay_rc" -eq 0 ] && t51_retire_ok "$t51/base.json" "$t51/final.json" commit && cmp -s "$t51/once.sha" "$t51/twice.sha"; then
                pass "T51 old-source retirement $t51_phase replay reaches one durable group commit"
            else
                fail "T51 old-source retirement $t51_phase replay reaches one durable group commit" "replay=$t51_replay_rc"
            fi
            rm -rf "$t51"
        done

        for t51_bad in missing-before-will replacement-after-will counter-conflict; do
            t51="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t51-retire-bad.XXXXXX")";t51_fixture "$t51" 65
            t51_drive "$t51_container" cutover '' >/dev/null 2>&1;t51_drive "$t51_container" cutover '' >/dev/null 2>&1;t51_drive "$t51_container" free-step '' >/dev/null 2>&1
            t51_drive "$t51_container" retire-step '' >/dev/null 2>&1;t51_drive "$t51_container" retire-step '' >/dev/null 2>&1
            t50_oracle "$t51_container" >"$t51/ready.json" 2>/dev/null
            t51_old2="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sources"][1]["basename"])' "$t51/ready.json")"
            case "$t51_bad" in
                missing-before-will) mv "$t51_container/$t51_old2" "$t51_container/$t51_old2.early" ;;
                replacement-after-will)
                    t51_drive "$t51_container" retire-step '' >/dev/null 2>&1
                    mv "$t51_container/$t51_old2" "$t51_container/$t51_old2.saved";cp "$t51_container/$t51_old2.saved" "$t51_container/$t51_old2" ;;
                counter-conflict)
                    t51_drive "$t51_container" retire-step '' >/dev/null 2>&1
                    t51_drive "$t51_container" retire-step 'catalog-migration-group:retired-source-physical-deleted' >/dev/null 2>&1
                    t51_drive "$t51_container" tamper-counter '' >/dev/null 2>&1 ;;
            esac
            t51_files_digest "$t51_container" >"$t51/tampered.sha"
            t51_drive "$t51_container" retire-step '' >"$t51/blocked.out" 2>"$t51/blocked.err";t51_blocked_rc=$?
            t51_files_digest "$t51_container" >"$t51/after.sha"
            if [ "$t51_blocked_rc" -eq 4 ] && cmp -s "$t51/tampered.sha" "$t51/after.sha" \
                && python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));raise SystemExit(0 if x.get("error",{}).get("code")=="catalog-root-invalid" else 1)' "$t51/blocked.out"; then
                pass "T51 old-source retirement $t51_bad is fail-closed and zero-effect"
            else
                fail "T51 old-source retirement $t51_bad is fail-closed and zero-effect" "rc=$t51_blocked_rc"
            fi
            rm -rf "$t51"
        done

        t51="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t51-writer.XXXXXX")";t51_fixture "$t51" 2
        t51_drive "$t51_container" cutover '' >/dev/null 2>&1;t51_drive "$t51_container" cutover '' >/dev/null 2>&1
        t51_drive "$t51_container" free-step '' >/dev/null 2>&1;t51_drive "$t51_container" finish-group '' >/dev/null 2>&1
        t51_drive "$t51_container" finish-migration '' >/dev/null 2>&1;t51_drive "$t51_container" outcome '' >/dev/null 2>&1
        t50_oracle "$t51_container" >"$t51/base.json" 2>"$t51/base.err";t51_base_rc=$?
        t51_drive "$t51_container" claim-create 'catalog-segment:claim-frame-committed' >"$t51/kill.out" 2>"$t51/kill.err";t51_writer_kill_rc=$?
        t50_oracle "$t51_container" >"$t51/prior.json" 2>"$t51/prior.err";t51_writer_prior_rc=$?
        t51_drive "$t51_container" claim-create '' >"$t51/replay.out" 2>"$t51/replay.err";t51_writer_replay_rc=$?
        t50_oracle "$t51_container" >"$t51/final.json" 2>"$t51/final.err";t51_writer_final_rc=$?
        if [ "$t51_base_rc" -eq 0 ] && [ "$t51_writer_kill_rc" -eq 86 ] && [ "$t51_writer_prior_rc" -eq 0 ] \
            && [ "$t51_writer_replay_rc" -eq 0 ] && [ "$t51_writer_final_rc" -eq 0 ] \
            && python3 - "$t51/base.json" "$t51/prior.json" "$t51/final.json" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]));p=json.load(open(sys.argv[2]));x=json.load(open(sys.argv[3]))
def scratch(v):return next((o for row in v["chain"]["objects"] if row["entry"].get("kind")=="scratch-object" for o in row["objects"] if o["basename"]==row["entry"]["basename"]),None)
bs=scratch(b);ps=scratch(p);xs=scratch(x);will=p["root"]["metadata"].get("claim_frame_will") or p["root"]["metadata"].get("previs_free_will") or {}
ok=(bs and ps and xs and p["chain"]["digest"]==b["chain"]["digest"] and ps.get("anchor_relation")=="append-after" and
 ps["basename"]==bs["basename"] and ps["descriptor_generation"]==bs["descriptor_generation"]+1 and ps["descriptor_predecessor"]==bs["descriptor_digest"] and
 ps["used"]==bs["used"]+will.get("frame_length") and ps["frames"][-1]["digest"]==will.get("frame_digest") and
 x["root"]["metadata"].get("claim_frame_will") is None and xs.get("anchor_relation")=="exact" and
 xs["descriptor_digest"]==ps["descriptor_digest"] and xs["used"]==ps["used"] and x["chain"]["digest"]!=b["chain"]["digest"])
raise SystemExit(0 if ok else 1)
PY
        then
            pass "T51 post-migration claim append updates physical scratch then ROOT hybrid anchor exactly"
        else
            fail "T51 post-migration claim append updates physical scratch then ROOT hybrid anchor exactly" "base=$t51_base_rc kill=$t51_writer_kill_rc prior=$t51_writer_prior_rc replay=$t51_writer_replay_rc/$t51_writer_final_rc"
        fi
        rm -rf "$t51"

        t51_build17() { # sandbox; prints container
            PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT/hooks/scripts/runtime_state.py" "$1/.zyz-worker/tasks/task" <<'PY'
import hashlib,importlib.util,os,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("zyz_runtime_state",sys.argv[1]);m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
task=Path(sys.argv[2]);container,initial=m.ensure_catalog_genesis(str(task));c=Path(container)
with m.CatalogFlock(c):
 p=m._catalog_validate_genesis(c);os.close(p.pop("global_fd"));prior=m._catalog_segment_chain_projection(c,".catalog-segment.0000000000000001.v1",1)
 for generation in range(2,18):
  name=f".catalog-segment.{generation:016d}.v1";path=c/name
  if generation>2:
   fd=os.open(os.fsencode(path),os.O_RDWR|os.O_CREAT|os.O_EXCL,0o600);m._catalog_preallocate(fd,m.CATALOG_SEGMENT_SIZE,name)
   for offset in range(0,m.CATALOG_SEGMENT_SIZE,1048576):m._catalog_pwrite_all(fd,bytes(min(1048576,m.CATALOG_SEGMENT_SIZE-offset)),offset,name)
   base=m._catalog_segment_image(generation,name);m._catalog_pwrite_all(fd,base,m.CATALOG_SEGMENT_SIZE-m.CATALOG_SEGMENT_CONTROL,"T51 pristine descriptor")
  else:
   fd=os.open(os.fsencode(path),os.O_RDWR|getattr(os,"O_NOFOLLOW",0));base=os.pread(fd,4096,m.CATALOG_SEGMENT_SIZE-m.CATALOG_SEGMENT_CONTROL)
  base_parsed=m._catalog_parse_image(base,b"ZYZSEG1");acc=m._catalog_digest(b"zyz-segment-chain-successor-v1",bytes.fromhex(prior["predecessor_chain_accumulator"])+bytes.fromhex(prior["descriptor_digest"]))
  meta=dict(base_parsed[2],predecessor_generation=prior["generation"],predecessor_descriptor_sha256=prior["descriptor_digest"],predecessor_chain_accumulator=acc.hex())
  linked=m._catalog_image(b"ZYZSEG1",4096,base_parsed[0]+1,base_parsed[3],meta)
  m._catalog_pwrite_all(fd,linked,m.CATALOG_SEGMENT_SIZE-m.CATALOG_SEGMENT_CONTROL+4096,"T51 linked descriptor");m._data_sync(fd);os.close(fd)
  prior=m._catalog_segment_chain_projection(c,name,generation)
 gfd=os.open(os.fsencode(c/".catalog-global-pack.v1"),os.O_RDWR|getattr(os,"O_NOFOLLOW",0));rfd=os.open(os.fsencode(c/".catalog-recovery-pack.v1"),os.O_RDONLY|getattr(os,"O_NOFOLLOW",0))
 try:
  entry=m._catalog_chain_range_anchor(c,1,17);region,_=m._catalog_chain_region([entry],p["chain"]["generation"]+1,bytes.fromhex(p["chain"]["digest"]))
  m._catalog_root_successor(gfd,rfd,p,p["root"][2][4096:5120],{"owned_bytes":p["root_meta"]["owned_bytes"]+15*m.CATALOG_SEGMENT_SIZE,
   "counter_generation":p["root_meta"]["counter_generation"]+15,
   "active_segment_generation":17,"active_segment_used_length":0,"active_segment_descriptor_digest":prior["descriptor_digest"],
   "active_segment_claim_count":0},"t51-seventeen-source-fixture",region)
 finally:os.close(gfd);os.close(rfd)
print(c)
PY
        }
        t51_17_fixture() { # sandbox copied-0|1
            t33_fixture "$1"
            t51_container="$(t51_build17 "$1")" || return
            if [ "${2:-1}" -eq 1 ]; then t51_prepare_copied "$t51_container";fi
        }
        t51_17_final_ok() { # initial final
            python3 - "$1" "$2" <<'PY'
import json,os,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));r=x["root"]["metadata"];g=x["group"]["metadata"]
entries=x["chain"]["entries"];ranges=[(e.get("first_generation"),e.get("last_generation")) for e in entries]
names=[e.get("basename") for e in entries];container=os.path.dirname(sys.argv[2]);mi=r.get("migration_quiesce_intent")
ok=(r.get("state")=="migration-committed" and r.get("admission_state")=="closed" and g.get("state")=="group-committed" and
 len(entries)==2 and all(e.get("kind")=="scratch-object" for e in entries) and ranges==[(1,16),(17,17)] and
 names==[".catalog-compaction-scratch.v1",".catalog-segment.0000000000000001.v1"] and
 r.get("owned_bytes")==b["root"]["metadata"].get("owned_bytes")-15*1048576 and
 r.get("counter_generation")==b["root"]["metadata"].get("counter_generation")+15 and
 g.get("retired_bytes")==0 and isinstance(mi,dict) and mi==b["root"]["metadata"].get("migration_quiesce_intent") and
 r.get("migration_source_chain_digest")==mi.get("source_chain_digest") and isinstance(mi.get("source_chain_digest"),str) and
 r.get("migration_creator_cutoff")==mi.get("creator_cutoff_sequence") and isinstance(mi.get("creator_cutoff_sequence"),int))
raise SystemExit(0 if ok else 1)
PY
        }

        for t51_phase in next finish-will finish-commit; do
            t51="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t51-suffix.XXXXXX")";t51_17_fixture "$t51" 1;t51_fixture_rc=$?
            t50_oracle "$t51_container" >"$t51/initial.json" 2>"$t51/initial.err";t51_initial_rc=$?
            t51_drive "$t51_container" cutover '' >/dev/null 2>&1;t51_drive "$t51_container" cutover '' >/dev/null 2>&1
            t51_drive "$t51_container" free-step '' >/dev/null 2>&1;t51_drive "$t51_container" finish-group '' >/dev/null 2>&1
            case "$t51_phase" in
                next) t51_action=continue;t51_barrier='catalog-migration-group:group-next-ready' ;;
                finish-will) t51_action=finish-migration;t51_barrier='catalog-root:will-migration-finish' ;;
                finish-commit) t51_action=finish-migration;t51_barrier='catalog-root:migration-committed' ;;
            esac
            t51_drive "$t51_container" "$t51_action" "$t51_barrier" >"$t51/kill.out" 2>"$t51/kill.err";t51_kill_rc=$?
            t50_oracle "$t51_container" >"$t51/prior.json" 2>"$t51/prior.err";t51_prior_rc=$?
            if [ "$t51_fixture_rc" -eq 0 ] && [ "$t51_initial_rc" -eq 0 ] && [ "$t51_kill_rc" -eq 86 ] && [ "$t51_prior_rc" -eq 0 ] \
                && python3 - "$t51/prior.json" "$t51_phase" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));phase=sys.argv[2];r=x["root"]["metadata"];g=x["group"]["metadata"]
if phase=="next":ok=(r.get("state")=="migration-active" and r.get("admission_state")=="closed" and g.get("state")=="idle" and r.get("migration_source_segment_generation")==17 and [(e["first_generation"],e["last_generation"]) for e in x["chain"]["entries"]]==[(1,16),(17,17)])
elif phase=="finish-will":ok=(r.get("state")=="will-migration-finish" and r.get("admission_state")=="closed" and g.get("state")=="group-committed")
else:ok=(r.get("state")=="migration-committed" and r.get("admission_state")=="closed" and g.get("state")=="group-committed")
raise SystemExit(0 if ok else 1)
PY
            then
                pass "T51 repeated-group $t51_phase barrier retains exact suffix and admission state"
            else
                fail "T51 repeated-group $t51_phase barrier retains exact suffix and admission state" "fixture=$t51_fixture_rc initial=$t51_initial_rc kill=$t51_kill_rc oracle=$t51_prior_rc"
            fi
            t51_drive "$t51_container" finish-migration '' >"$t51/replay.out" 2>"$t51/replay.err";t51_replay_rc=$?
            t50_oracle "$t51_container" >"$t51/final.json" 2>"$t51/final.err";t51_final_rc=$?
            t51_files_digest "$t51_container" >"$t51/once.sha";t51_drive "$t51_container" finish-migration '' >/dev/null 2>&1;t51_files_digest "$t51_container" >"$t51/twice.sha"
            if [ "$t51_replay_rc" -eq 0 ] && [ "$t51_final_rc" -eq 0 ] && t51_17_final_ok "$t51/initial.json" "$t51/final.json" && cmp -s "$t51/once.sha" "$t51/twice.sha" \
                && [ ! -e "$t51_container/.catalog-segment.0000000000000002.v1" ] && [ ! -e "$t51_container/.catalog-segment.0000000000000016.v1" ]; then
                pass "T51 repeated-group $t51_phase replay completes finite suffix exactly once"
            else
                fail "T51 repeated-group $t51_phase replay completes finite suffix exactly once" "replay=$t51_replay_rc final=$t51_final_rc"
            fi
            rm -rf "$t51"
        done

        t51_chain_bounds() {
            PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT/hooks/scripts/runtime_state.py" <<'PY'
import hashlib,importlib.util,json,struct,sys
spec=importlib.util.spec_from_file_location("zyz_runtime_state",sys.argv[1]);m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
D=lambda d,v:hashlib.sha256(d+v).digest();J=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
entries=[];first=1
for i in range(16):
 count=128 if i<15 else 127;last=first+count-1
 entries.append({"schema_version":1,"kind":"segment-range","first_generation":first,"last_generation":last,"member_count":count,"identity_set_digest":hashlib.sha256(f"range-{i}".encode()).hexdigest()});first=last+1
raw,digest=m._catalog_chain_region(entries,7,bytes.fromhex("11"*32))
if len(raw)!=16384 or raw[4096+16*512:12288]!=b"" or first-1!=2047:raise SystemExit(1)
header=raw[:4096];meta=json.loads(header[128:128+struct.unpack_from(">I",header,20)[0]])
images=raw[4096:12288];entry_digest=D(b"zyz-hybrid-chain-entry-set-v1",images).hex()
if meta.get("entry_count")!=16 or meta.get("entries_sha256")!=entry_digest:raise SystemExit(1)
try:m._catalog_chain_region(entries+[dict(entries[-1],first_generation=2048,last_generation=2048,member_count=1)],8)
except m.StateError:pass
else:raise SystemExit(1)
overflow=[dict(v) for v in entries];overflow[-1]["last_generation"]+=1;overflow[-1]["member_count"]+=1
try:m._catalog_chain_region(overflow,8)
except m.StateError:pass
else:raise SystemExit(1)
scratch={"schema_version":1,"kind":"scratch-object","first_generation":1,"last_generation":1,"basename":"scratch.v1",
 "identity_digest":"22"*32,"descriptor_digest":"33"*32,"descriptor_generation":9,"used_length":17,
 "plan_digest":"44"*32,"source_group_digest":"55"*32,"cancel_set_digest":"66"*32}
mixed,_=m._catalog_chain_region([scratch,dict(entries[0],first_generation=2,last_generation=129,member_count=128)],9)
binary=mixed[4096+240:4096+512]
if binary[:8]!=b"ZYZSCA1\0" or struct.unpack_from(">QQ",binary,176)!=(9,17) or binary[192:202]!=b"scratch.v1":raise SystemExit(1)
PY
        }
        if t51_chain_bounds; then
            pass "T51 hybrid serializer enforces exact 16-anchor and 2047-member capacity"
        else
            fail "T51 hybrid serializer enforces exact 16-anchor and 2047-member capacity"
        fi

        t51_static="$(python3 - hooks/scripts/runtime_state.py <<'PY'
import ast,json,sys
t=ast.parse(open(sys.argv[1],encoding="utf-8").read());f={n.name:n for n in t.body if isinstance(n,ast.FunctionDef)}
graph={name:{n.func.id for n in ast.walk(node) if isinstance(n,ast.Call) and isinstance(n.func,ast.Name)} for name,node in f.items()}
seen=set();todo=["gc_step_command"]
while todo:
 name=todo.pop()
 if name in seen:continue
 seen.add(name);todo.extend(graph.get(name,set())-seen)
need={"_catalog_migration_quiesce_begin","_catalog_quiesce_cancel_previsible","_catalog_group_plan_step","_catalog_group_copy_step","_catalog_previs_group_visible","_catalog_previs_free_step","_catalog_group_retire_step","_catalog_group_continue_or_finish"}
writers={"_catalog_claim_frame_committed","_catalog_claim_create","_catalog_flush_cell","_catalog_ordinary_free","_gc_claim_sweep","_catalog_rotate_claim_segment"}
bad=[]
for name in writers:
 node=f.get(name)
 text=ast.get_source_segment(open(sys.argv[1],encoding="utf-8").read(),node) if node else ""
 if name not in ("_catalog_rotate_claim_segment",) and ".catalog-segment." in text:bad.append(name)
print(json.dumps({"public_missing":sorted(need-seen),"deterministic_active_paths":sorted(bad),
 "has_dense_signature":any("dense_capacity_signature" in ast.get_source_segment(open(sys.argv[1],encoding="utf-8").read(),n) for n in f.values()),
 "capacity_gate_dense":"dense_capacity_signature" in ast.get_source_segment(open(sys.argv[1],encoding="utf-8").read(),f["_catalog_capacity_gate"])},sort_keys=True,separators=(",",":")))
PY
)"
        if printf '%s' "$t51_static" | python3 -c 'import json,sys;x=json.load(sys.stdin);raise SystemExit(0 if not x["public_missing"] and not x["deterministic_active_paths"] and x["has_dense_signature"] and x["capacity_gate_dense"] else 1)'; then
            pass "T51 public migration graph dense gate and hybrid reader-writer static closure"
        else
            fail "T51 public migration graph dense gate and hybrid reader-writer static closure" "$t51_static"
        fi

        t51_due_table() {
            PYTHONDONTWRITEBYTECODE=1 python3 - "$REPO_ROOT/hooks/scripts/runtime_state.py" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location("zyz_runtime_state",sys.argv[1]);m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)
config={"ZYZ_SNAPSHOT_GC_INTERVAL_SEC":60,"ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES":100}
schedule={"state":"SCHEDULED","next_gc_epoch":1};base={"state":"active","claim_scan_due":False,"blocked_claims_known":0,"pending_anchor_claim_sha256":None,
 "dense_capacity_signature":None,"hybrid_chain_digest":"11"*32,"recovery_overlay_digest":"22"*32,"counter_generation":3,"owned_bytes":200,"active_data_claims":4}
base["dense_capacity_signature"]=m._catalog_dense_signature_value(base)
cases=[("watchdog",base,False),("lifecycle",base,False),("manual",base,True),("system-timer",base,True),
 ("watchdog",dict(base,claim_scan_due=True),True),("lifecycle",dict(base,pending_anchor_claim_sha256="11"*32),True)]
if any(m._gc_schedule_due(trigger,schedule,root,config,10) is not want for trigger,root,want in cases):raise SystemExit(1)
if m._gc_schedule_due("watchdog",schedule,dict(base,dense_capacity_signature=None),config,10) is not True:raise SystemExit(1)
PY
        }
        if t51_due_table; then
            pass "T51 dense signature due table preserves manual intent and ordinary automatic work"
        else
            fail "T51 dense signature due table preserves manual intent and ordinary automatic work"
        fi

        t51_gc() { # sandbox trigger
            (cd "$1" && ZYZ_SNAPSHOT_GC_HIGH_WATER_BYTES=33554432 ZYZ_SNAPSHOT_GC_HARD_WATER_BYTES=67108864 \
                ZYZ_NO_OUTPUT_TEMP_STALE_SEC=2147483647 ZYZ_TEST_GC_NOW_EPOCH=2000000000 \
                bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" gc-step "$1/.zyz-worker/tasks/task" "$2")
        }
        t51_public_output_ok() { # json expected-due
            python3 - "$1" "$2" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));due=sys.argv[2]=="true"
keys=("ok","state","error","trigger","due","lock_acquired","claims_scanned","claims_skipped","blocked_claims_known","transactions_advanced","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","owned_bytes_before","owned_bytes_after","high_water","hard_water","receipts_anchored","next_gc_epoch")
counts=("claims_scanned","claims_skipped","transactions_advanced","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","receipts_anchored")
ok=(tuple(x)==keys and x.get("due") is due and x.get("lock_acquired") is True and all(isinstance(x.get(k),int) and x[k]>=0 for k in counts) and
 isinstance(x.get("owned_bytes_before"),int) and isinstance(x.get("owned_bytes_after"),int) and x.get("high_water")==33554432 and x.get("hard_water")==67108864)
raise SystemExit(0 if ok else 1)
PY
        }

        t51="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t51-public-sparse.XXXXXX")";t51_17_fixture "$t51" 0;t51_fixture_rc=$?
        t50_oracle "$t51_container" >"$t51/initial.json" 2>"$t51/initial.err";t51_initial_rc=$?
        : >"$t51/passes.jsonl";t51_public_sparse_done=0
        for t51_pass in $(seq 1 512); do
            t51_gc "$t51" manual >"$t51/pass.out" 2>"$t51/pass.err";t51_pass_rc=$?
            [ -s "$t51/pass.out" ] && cat "$t51/pass.out" >>"$t51/passes.jsonl"
            t50_oracle "$t51_container" >"$t51/current.json" 2>/dev/null || break
            if python3 -c 'import json,sys;r=json.load(open(sys.argv[1]));m=r["root"]["metadata"];raise SystemExit(0 if m.get("state")=="active" and m.get("admission_state")=="open" and m.get("migration_quiesce_intent") is None and r["group"]["metadata"].get("state")=="idle" else 1)' "$t51/current.json"; then t51_public_sparse_done=1;break;fi
            [ "$t51_pass_rc" -eq 0 ] || [ "$t51_pass_rc" -eq 3 ] || break
        done
        if [ "$t51_fixture_rc" -eq 0 ] && [ "$t51_initial_rc" -eq 0 ] && [ "$t51_public_sparse_done" -eq 1 ] \
            && python3 - "$t51/initial.json" "$t51/current.json" "$t51/passes.jsonl" <<'PY'
import json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));rows=[json.loads(v) for v in open(sys.argv[3]) if v.strip()];r=x["root"]["metadata"]
keys=("ok","state","error","trigger","due","lock_acquired","claims_scanned","claims_skipped","blocked_claims_known","transactions_advanced","entries_verified","verification_bytes","entries_deleted","bytes_reclaimed","owned_bytes_before","owned_bytes_after","high_water","hard_water","receipts_anchored","next_gc_epoch")
ok=(rows and all(tuple(r)==keys and r["trigger"]=="manual" and r["due"] is True for r in rows) and
 sum(r["entries_deleted"] for r in rows)==15 and sum(r["bytes_reclaimed"] for r in rows)==15*1048576 and
 sum(r["entries_verified"] for r in rows)==sum(r["verification_bytes"] for r in rows)==sum(r["receipts_anchored"] for r in rows)==0 and
 rows[-1]["state"]=="compacted" and rows[-1]["owned_bytes_after"]==33554432 and r.get("state")=="active" and
 r.get("admission_state")=="open" and r.get("dense_capacity_signature") is None and x["group"]["metadata"].get("state")=="idle" and
 [(e["first_generation"],e["last_generation"]) for e in x["chain"]["entries"]]==[(1,16),(17,17)] and
 r.get("counter_generation")==b["root"]["metadata"].get("counter_generation")+15)
raise SystemExit(0 if ok else 1)
PY
        then
            pass "T51 public sparse migration preserves entry due and exact pass effects through completion"
        else
            fail "T51 public sparse migration preserves entry due and exact pass effects through completion" "fixture=$t51_fixture_rc initial=$t51_initial_rc done=$t51_public_sparse_done pass=${t51_pass_rc:-none}"
        fi
        rm -rf "$t51"

        t51="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t51-public-dense.XXXXXX")";t37_fixture "$t51"
        t51_container="$(find "$t51/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)";t40_public "$t51" 65 "$t40_seed_a" 'catalog-claim-pack:public-batch-committed' >/dev/null 2>&1
        : >"$t51/passes.jsonl";t51_dense_done=0
        for t51_pass in $(seq 1 512); do
            t51_gc "$t51" manual >"$t51/pass.out" 2>"$t51/pass.err";t51_pass_rc=$?;[ -s "$t51/pass.out" ] && cat "$t51/pass.out" >>"$t51/passes.jsonl"
            t50_oracle "$t51_container" >"$t51/current.json" 2>/dev/null || break
            if python3 -c 'import json,sys;r=json.load(open(sys.argv[1]))["root"]["metadata"];raise SystemExit(0 if r.get("state")=="active" and r.get("admission_state")=="closed" and r.get("dense_capacity_signature") is not None else 1)' "$t51/current.json"; then t51_dense_done=1;break;fi
            [ "$t51_pass_rc" -eq 0 ] || [ "$t51_pass_rc" -eq 3 ] || break
        done
        t51_gc "$t51" watchdog >"$t51/watchdog.out" 2>"$t51/watchdog.err";t51_watchdog_rc=$?
        t51_gc "$t51" lifecycle >"$t51/lifecycle.out" 2>"$t51/lifecycle.err";t51_lifecycle_rc=$?
        t51_gc "$t51" manual >"$t51/manual.out" 2>"$t51/manual.err";t51_manual_rc=$?
        t51_gc "$t51" system-timer >"$t51/timer.out" 2>"$t51/timer.err";t51_timer_rc=$?
        if [ "$t51_dense_done" -eq 1 ] && [ "$t51_watchdog_rc" -eq 3 ] && [ "$t51_lifecycle_rc" -eq 3 ] && [ "$t51_manual_rc" -eq 3 ] && [ "$t51_timer_rc" -eq 3 ] \
            && t51_public_output_ok "$t51/watchdog.out" false && t51_public_output_ok "$t51/lifecycle.out" false \
            && t51_public_output_ok "$t51/manual.out" true && t51_public_output_ok "$t51/timer.out" true \
            && python3 - "$t51/current.json" "$t51/passes.jsonl" "$t51/watchdog.out" "$t51/lifecycle.out" "$t51/manual.out" "$t51/timer.out" <<'PY'
import hashlib,json,struct,sys
x=json.load(open(sys.argv[1]));rows=[json.loads(v) for v in open(sys.argv[2]) if v.strip()];outs=[json.load(open(v)) for v in sys.argv[3:]]
r=x["root"]["metadata"];s=r.get("dense_capacity_signature") or {}
want=hashlib.sha256(b"zyz-dense-capacity-signature-v1"+bytes.fromhex(r["hybrid_chain_digest"])+bytes.fromhex(r["recovery_overlay_digest"])+struct.pack(">QQQ",r["counter_generation"],r["owned_bytes"],r["active_data_claims"])).hexdigest()
def _pressure(v):
    return v.get("state")=="pressure" and v.get("error",{}).get("code")=="catalog-capacity-pressure" and v.get("error",{}).get("retryable") is True
def _pass_ok(v):
    # no-compaction-rerun invariant holds for ALL four suppression passes (design.md:403):
    # a matching dense signature never re-runs the unchanged 1->1 compaction.
    if not (v.get("ok") is True and v.get("entries_deleted")==v.get("bytes_reclaimed")==0): return False
    if v.get("due") is False:
        # automatic triggers (watchdog, lifecycle): matching signature MUST suppress to pressure with no work.
        return _pressure(v)
    # due=true (manual, system-timer): ordinary GC may be mid-sweep on the 65>64 fixture
    # (state=pending, priority blocked>pending>pressure at design.md:124) or reach pressure;
    # either is legitimate, but no compaction rerun (guarded above).
    return _pressure(v) if v.get("state")=="pressure" else v.get("state")=="pending"
ok=(s==want and r.get("state")=="active" and r.get("admission_state")=="closed" and
 sum(v["entries_deleted"] for v in rows)==1 and sum(v["bytes_reclaimed"] for v in rows)==1048576 and
 all(_pass_ok(v) for v in outs))
raise SystemExit(0 if ok else 1)
PY
        then
            pass "T51 dense 2-to-1 completion emits bound pressure signature and suppresses unchanged reruns"
        else
            fail "T51 dense 2-to-1 completion emits bound pressure signature and suppresses unchanged reruns" "done=$t51_dense_done auto=$t51_watchdog_rc/$t51_lifecycle_rc explicit=$t51_manual_rc/$t51_timer_rc"
        fi
        t51_files_digest "$t51_container" >"$t51/dense-before.sha"
        # Drive new-owner admission through the fresh-claim real-rc actor (design.md:378 item 2,
        # manifest "Dense admission priority and zero effect"): t51_drive claim-create derives a
        # genuinely fresh cell key (claim.<sha> not in t40_public's 65-claim batch, so duplicate is
        # None), reaching the dense capacity gate on the fresh-owner/claim-create path
        # (runtime_state.py:4609->4465) which preempts high/hard before any recovery/directory/pack
        # write and returns the rc4 catalog-capacity-pressure envelope on stdout.  The SubagentStart
        # host hook (t37_public -> subagent-track.sh) is intentionally fail-open exit 0 (design.md:567)
        # and cannot emit rc4/an stdout envelope; a bare t37_public also reuses the committed batch
        # owner id, so the reused-identity conflict (10000) would preempt the gate entirely.
        t51_drive "$t51_container" claim-create '' >"$t51/admission.out" 2>"$t51/admission.err";t51_admission_rc=$?
        t51_files_digest "$t51_container" >"$t51/dense-after.sha"
        if [ "$t51_admission_rc" -eq 4 ] && cmp -s "$t51/dense-before.sha" "$t51/dense-after.sha" \
            && python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));raise SystemExit(0 if x.get("error",{}).get("code")=="catalog-capacity-pressure" and x["error"].get("retryable") is True else 1)' "$t51/admission.out"; then
            pass "T51 matching dense signature rejects a new claim owner before any physical effect"
        else
            fail "T51 matching dense signature rejects a new claim owner before any physical effect" "rc=$t51_admission_rc"
        fi
        t51_drive "$t51_container" tamper-counter '' >/dev/null 2>&1
        t51_gc "$t51" watchdog >"$t51/changed.out" 2>"$t51/changed.err";t51_changed_rc=$?
        if [ "$t51_changed_rc" -eq 3 ] && t51_public_output_ok "$t51/changed.out" true \
            && python3 -c 'import json,sys;x=json.load(open(sys.argv[1]));raise SystemExit(0 if x.get("state")=="pending" and x.get("error") is None and x.get("transactions_advanced",0)>0 else 1)' "$t51/changed.out"; then
            pass "T51 dense signature owned-input change makes automatic entry due and re-evaluates pressure"
        else
            fail "T51 dense signature owned-input change makes automatic entry due and re-evaluates pressure" "rc=$t51_changed_rc"
        fi
        rm -rf "$t51"
    else
        skip "T51 physical cutover and reader authority require T33 GENESIS plus public batch fixture"
    fi
else
    skip "T51 migration completion coverage requires python runtime backend"
fi

# ---------------------------------------------------------------------------
# T52  Fixed-pack event diagnostics and public reconciliation.
#
# The retired T24 pathname matrix is not an oracle for the fixed design.  These
# cases enter only through SubagentStart/SubagentStop and reconcile-start/stop,
# while t33_oracle decodes DIAGNOSTICS, RESOLVED_START, RESOLVED_STOP and the
# TRANSITION_JOURNAL directly from their selected A/B images.  The boundary
# fixtures below encode a valid disposable audit-pack successor independently;
# they never create a logical record as a pathname.
# Observation ceiling: exit-86 plus raw selected-image inspection proves the
# process-visible fsync/barrier order, not persistence across real power loss.
# Do not read these green checks as proof of unmodelled simultaneous callers;
# the public foreign-owner controls and mutation run are the available guards.
# ---------------------------------------------------------------------------
if [ "${t33_supported:-0}" -eq 1 ] && [ -x hooks/scripts/agent-runtime-state.sh ]; then
    t52_raw='reconcile/agent'; t52_role='review-agent'
    t52_start_nonce='11223344556677889900aabbccddeeff'
    t52_stop_nonce='ffeeddccbbaa00998877665544332211'
    t52_key="$(python3 -c 'import hashlib,re,sys
r=sys.argv[1];print((re.sub(r"[^A-Za-z0-9._-]","_",r)[:32] or "agent")+"."+hashlib.sha256(r.encode()).hexdigest())' "$t52_raw")"
    t52_fixture() { t33_fixture "$1"; }
    t52_start() { # sandbox nonce primary-failure-0|1 [barrier]
        printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"%s","agent_type":"zyz-worker:%s"}' \
            "$1" "$t52_raw" "$t52_role" |
            env ZYZ_TEST_RANDOM_HEX_SEQUENCE="$2" \
                ZYZ_TEST_PRIMARY_FAIL_BEFORE_JOURNAL="$([ "$3" -eq 1 ] && printf start)" \
                ZYZ_TEST_TRANSITION_STOP_AFTER="${4:-}" \
                bash hooks/scripts/subagent-track.sh
    }
    t52_stop() { # sandbox nonce primary-failure-0|1
        printf '{"cwd":"%s","hook_event_name":"SubagentStop","agent_id":"%s","agent_type":"zyz-worker:%s","stop_hook_active":false,"last_assistant_message":"Completed review with exact evidence, decisions, risks, remaining scope, and a reproducible handoff for the main agent."}' \
            "$1" "$t52_raw" "$t52_role" |
            env ZYZ_TEST_RANDOM_HEX_SEQUENCE="$2" \
                ZYZ_TEST_PRIMARY_FAIL_BEFORE_JOURNAL="$([ "$3" -eq 1 ] && printf stop)" \
                ZYZ_SNAPSHOT_GC_INTERVAL_SEC=0 \
                bash hooks/scripts/stop-gate-subagent.sh
    }
    t52_reconcile() { # sandbox kind token barrier [role]
        (
            cd "$1" || exit 1
            ZYZ_TEST_TRANSITION_STOP_AFTER="$4" \
                bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
                "reconcile-$2" "$1/.zyz-worker/tasks/task" "$t52_raw" "${5:-$t52_role}" "$3" confirmed
        )
    }
    t52_error_ok() { # output code
        python3 - "$1" "$2" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));raise SystemExit(0 if x.get("ok") is False and x.get("state")=="error" and (x.get("error") or {}).get("code")==sys.argv[2] else 1)
PY
    }
    t52_token() { sed -n 's/^zyz-worker: \(start-unarmed\|stop-uncommitted\) \(evt1-[0-9a-f]*\)$/\2/p' "$1"; }
    t52_diag_ok() { # oracle kind nonce
        python3 - "$1" "$2" "$3" "$t52_key" "$t52_raw" "$t52_role" <<'PY'
import hashlib,json,os,sys
x=json.load(open(sys.argv[1]));kind,nonce,key,raw,role=sys.argv[2:]
digest=hashlib.sha256(os.fsencode(raw)).hexdigest();code=1 if kind=="start" else 2
rb=role.encode();db=digest.encode();nb=nonce.encode()
record=bytes([1,code])+len(rb).to_bytes(2,"big")+rb+len(db).to_bytes(2,"big")+db+len(nb).to_bytes(2,"big")+nb
event={"event_token":"evt1-"+hashlib.sha256(record).hexdigest(),"nonce_sha256":hashlib.sha256(bytes.fromhex(nonce)).hexdigest(),"event_record_digest":hashlib.sha256(record).hexdigest()}
audit=x["packs"].get("audit",{});work=x["packs"].get("work",{});entries=audit.get("records",{}).get("DIAGNOSTICS",{}).get("payload",{}).get("entries",[])
ok=(len(entries)==1 and entries[0].get("schema_version")==1 and entries[0].get("kind")==kind and
 entries[0].get("instance_key")==key and entries[0].get("raw_id_sha256")==digest and entries[0].get("canonical_role")==role and
 all(entries[0].get(name)==value for name,value in event.items()) and isinstance(entries[0].get("event_epoch"),int) and
 entries[0].get("reason_sha256")==hashlib.sha256(("primary-"+kind+"-before-journal").encode()).hexdigest() and
 entries[0].get("needs_reconcile") is True and entries[0].get("resolved_receipt_digest") is None and
 (kind!="start" or ("IDENTITY" not in audit.get("selected",{}) and "START" not in audit.get("selected",{}) and not work.get("selected"))) and
 (kind!="stop" or ("IDENTITY" in audit.get("selected",{}) and "START" in audit.get("selected",{}))))
raise SystemExit(0 if ok else 1)
PY
    }
    t52_start_final_ok() { # diagnostic-oracle final-oracle output idempotent token
        python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import base64,hashlib,json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));out=json.load(open(sys.argv[3]));idem=sys.argv[4]=="true";token=sys.argv[5]
J=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()+b"\n"
br=b["packs"]["audit"]["records"]["DIAGNOSTICS"]["payload"]["entries"][0]
audit=x["packs"]["audit"];work=x["packs"]["work"];records=audit["records"]
diag=records["DIAGNOSTICS"]["payload"]["entries"];receipts=records["RESOLVED_START"]["payload"]["entries"];journal=work["records"]["TRANSITION_JOURNAL"]["payload"]
if len(diag)!=1 or len(receipts)!=1:raise SystemExit(1)
d=diag[0];r=receipts[0];slots={name:(records[name]["generation"],records[name]["digest"]) for name in ("IDENTITY","START")}
base_keys={"schema_version","command","ok","state","error","instance_key","trusted","tracking_capability",
 "terminal_kind","terminal_epoch","cleanup_state","cleanup_pending","cleanup_error","cleanup_intent_digest",
 "cleanup_receipt_digest","probe_id","probe_id_sha256","deadline_epoch","creation_enabled","idempotent",
 "late_clean","preserved_terminal_kind","argv","argv_b64","human_message","shell_command","inflight_capability",
 "inflight_count","no_output_state","no_output_changed","baseline_epoch","baseline_digest","current_digest"}
argv=out.get("argv");argv_b64=out.get("argv_b64")
envelope=(set(out)==base_keys|{"event_token","reconciled_epoch","no_output_capability"} and
 isinstance(argv,list) and len(argv)==6 and argv[0]=="reconcile-start" and argv[2:]==["reconcile/agent",br["canonical_role"],token,"confirmed"] and
 argv_b64==[base64.b64encode(v.encode()).decode() for v in argv] and out.get("schema_version")==1 and
 out.get("command")=="reconcile-start" and out.get("error") is None and out.get("instance_key")==records["IDENTITY"]["payload"]["instance_key"] and
 out.get("terminal_kind") is None and out.get("terminal_epoch") is None and out.get("cleanup_state")=="not-applicable" and
 out.get("cleanup_pending") is False and all(out.get(name) is None for name in ("cleanup_error","cleanup_intent_digest","cleanup_receipt_digest","probe_id","probe_id_sha256","deadline_epoch","creation_enabled","human_message","shell_command","no_output_state","no_output_changed","baseline_epoch","baseline_digest","current_digest")) and
 out.get("late_clean") is False and out.get("preserved_terminal_kind") is None and out.get("inflight_capability")=="unknown" and
 out.get("inflight_count")==0 and out.get("no_output_capability")=="unavailable" and out.get("reconciled_epoch")==r.get("resolved_epoch"))
ok=(d.get("needs_reconcile") is False and d.get("resolved_receipt_digest")==hashlib.sha256(J(r)).hexdigest() and
 r.get("receipt_type")=="start" and r.get("event_token")==token and r.get("owner_diagnostic_digest")==hashlib.sha256(J(br)).hexdigest() and
 r.get("committed_journal_digest")==hashlib.sha256(J(journal)).hexdigest() and journal.get("txn_type")=="reconcile-start" and journal.get("phase")=="committed" and
 r.get("target_slot_generation")=={n:v[0] for n,v in slots.items()} and r.get("target_slot_digest")=={n:v[1] for n,v in slots.items()} and
 envelope and out.get("ok") is True and out.get("state")=="reconciled-start" and out.get("trusted") is True and
 out.get("tracking_capability")=="armed" and out.get("idempotent") is idem and out.get("event_token")==token)
raise SystemExit(0 if ok else 1)
PY
    }
    t52_stop_final_ok() { # diagnostic-oracle terminal-oracle output idempotent token
        python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import base64,json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));out=json.load(open(sys.argv[3]));idem=sys.argv[4]=="true";token=sys.argv[5]
cells=x["terminal"]["cells"]
if len(cells)!=1:raise SystemExit(1)
meta=cells[0]["metadata"];marker=meta.get("terminal_record",{});receipts=meta.get("event_receipts",{})
base_keys={"schema_version","command","ok","state","error","instance_key","trusted","tracking_capability",
 "terminal_kind","terminal_epoch","cleanup_state","cleanup_pending","cleanup_error","cleanup_intent_digest",
 "cleanup_receipt_digest","probe_id","probe_id_sha256","deadline_epoch","creation_enabled","idempotent",
 "late_clean","preserved_terminal_kind","argv","argv_b64","human_message","shell_command","inflight_capability",
 "inflight_count","no_output_state","no_output_changed","baseline_epoch","baseline_digest","current_digest"}
argv=out.get("argv");argv_b64=out.get("argv_b64")
envelope=(set(out)==base_keys|{"event_token","reconciled_epoch"} and isinstance(argv,list) and len(argv)==6 and
 argv[0]=="reconcile-stop" and argv[2:]==["reconcile/agent",marker.get("canonical_role"),token,"confirmed"] and
 argv_b64==[base64.b64encode(v.encode()).decode() for v in argv] and out.get("schema_version")==1 and
 out.get("command")=="reconcile-stop" and out.get("error") is None and out.get("instance_key")==marker.get("instance_key") and
 out.get("terminal_kind")=="done" and out.get("terminal_epoch")==marker.get("terminal_epoch") and
 out.get("cleanup_state")==marker.get("cleanup_state","compacted") and out.get("cleanup_pending")==marker.get("cleanup_pending",False) and
 all(out.get(name) is None for name in ("cleanup_error","cleanup_intent_digest","cleanup_receipt_digest","probe_id","probe_id_sha256","deadline_epoch","creation_enabled","human_message","shell_command","no_output_state","no_output_changed","baseline_epoch","baseline_digest","current_digest")) and
 out.get("late_clean") is False and out.get("preserved_terminal_kind") is None and out.get("inflight_capability")=="unknown" and
 out.get("inflight_count")==0 and isinstance(out.get("reconciled_epoch"),int))
ok=(not x["packs"] and x["lock"] is None and marker.get("terminal_kind")=="done" and marker.get("event_token")==token and
 receipts.get("latest_stop_event_token")==token and isinstance(receipts.get("resolved_stop_ring_digest"),str) and
 envelope and out.get("ok") is True and out.get("state")=="reconciled-stop" and out.get("trusted") is True and
 out.get("tracking_capability")=="armed" and out.get("idempotent") is idem and out.get("event_token")==token)
raise SystemExit(0 if ok else 1)
PY
    }
    t52_reconcile_prior_ok() { # diagnostic-oracle prior-oracle kind coordinate token
        python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import hashlib,json,sys
b=json.load(open(sys.argv[1]));x=json.load(open(sys.argv[2]));kind,coordinate,token=sys.argv[3:]
J=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()+b"\n"
JD=lambda v:hashlib.sha256(J(v)).hexdigest()
audit=x["packs"].get("audit",{});work=x["packs"].get("work",{});records=audit.get("records",{})
base_entries=b["packs"]["audit"]["records"]["DIAGNOSTICS"]["payload"]["entries"]
entries=records.get("DIAGNOSTICS",{}).get("payload",{}).get("entries",[])
slot="RESOLVED_START" if kind=="start" else "RESOLVED_STOP"
receipts=records.get(slot,{}).get("payload",{}).get("entries",[])
journal=work.get("records",{}).get("TRANSITION_JOURNAL",{}).get("payload",{})
if len(base_entries)!=1 or len(entries)!=1 or not isinstance(journal,dict):raise SystemExit(1)
owner=base_entries[0];diagnostic=entries[0]
target_names=("IDENTITY","START") if kind=="start" else ("DONE",)
if any(name not in records for name in target_names):raise SystemExit(1)
generations={name:records[name]["generation"] for name in target_names}
digests={name:records[name]["digest"] for name in target_names}
committed={name:value for name,value in journal.items()
           if name not in ("phase","committed_epoch","target_slot_generation","target_slot_digest")}
committed.update(phase="committed",committed_epoch=journal.get("resolved_epoch"),
                 target_slot_generation=generations,target_slot_digest=digests)
cleanup_state="not-applicable";cleanup_digest=None
if kind=="stop":
 marker=records["DONE"]["payload"]
 cleanup_state=marker.get("cleanup_state","pending");cleanup_digest=marker.get("cleanup_intent_digest")
expected_receipt={"schema_version":1,"receipt_type":kind,"txn_id":journal.get("txn_id"),
 "event_token":owner.get("event_token"),"nonce_sha256":owner.get("nonce_sha256"),
 "event_record_digest":owner.get("event_record_digest"),"raw_id_sha256":owner.get("raw_id_sha256"),
 "canonical_role":owner.get("canonical_role"),"owner_diagnostic_digest":JD(owner),
 "committed_journal_digest":JD(committed),"target_slot_generation":generations,
 "target_slot_digest":digests,"resolved_epoch":journal.get("resolved_epoch"),
 "outcome":"reconciled-"+kind,"cleanup_state":cleanup_state,"cleanup_txn_digest":cleanup_digest}
common=(journal.get("schema_version")==1 and journal.get("txn_type")=="reconcile-"+kind and
 set(journal)==({"schema_version","txn_type","phase","txn_id","instance_key","agent_id_sha256",
  "canonical_role","owner_diagnostic_digest","event_token","nonce_sha256","event_record_digest",
  "event_epoch","resolved_epoch"}|({"identity_record","start_record"} if kind=="start" else {"done_record"})) and
 journal.get("txn_id")==hashlib.sha256(("zyz-reconcile-"+kind+"-v1").encode()+bytes.fromhex(token[5:])).hexdigest() and
 journal.get("instance_key")==owner.get("instance_key") and
 journal.get("agent_id_sha256")==owner.get("raw_id_sha256") and
 journal.get("canonical_role")==owner.get("canonical_role") and
 journal.get("owner_diagnostic_digest")==JD(owner) and journal.get("event_token")==token and
 journal.get("nonce_sha256")==owner.get("nonce_sha256") and
 journal.get("event_record_digest")==owner.get("event_record_digest") and journal.get("event_epoch")==owner.get("event_epoch") and
 isinstance(journal.get("resolved_epoch"),int) and
 (kind!="start" or (journal.get("identity_record")==records["IDENTITY"]["payload"] and
                     journal.get("start_record")==records["START"]["payload"] and "DONE" not in records)) and
 (kind!="stop" or (journal.get("done_record")==records["DONE"]["payload"] and "START" not in audit.get("selected",{}))))
if coordinate=="will":
 ok=(common and journal.get("phase")=="will-diagnostic-resolved" and not receipts and
     slot not in audit.get("selected",{}) and diagnostic==owner)
elif coordinate=="receipt-header":
 ok=(common and journal.get("phase")=="will-diagnostic-resolved" and receipts==[expected_receipt] and
     records[slot]["payload"]=={"schema_version":1,"receipt_type":kind,"entries":[expected_receipt]} and
     slot in audit.get("selected",{}) and diagnostic==owner)
elif coordinate=="did":
 expected_diagnostic=dict(owner,needs_reconcile=False,resolved_receipt_digest=JD(expected_receipt))
 ok=(common and journal.get("phase")=="did-diagnostic-resolved" and receipts==[expected_receipt] and
     records[slot]["payload"]=={"schema_version":1,"receipt_type":kind,"entries":[expected_receipt]} and
     slot in audit.get("selected",{}) and diagnostic==expected_diagnostic)
else:ok=False
raise SystemExit(0 if ok else 1)
PY
    }

    t52="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t52-start.XXXXXX")";t52_fixture "$t52"
    t52_start "$t52" "$t52_start_nonce" 1 >"$t52/diag.out" 2>"$t52/diag.err";t52_diag_rc=$?
    t52_token_value="$(t52_token "$t52/diag.err")";t52_container="$(find "$t52/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/diag.json" 2>"$t52/diag-oracle.err";t52_oracle_rc=$?
    if [ "$t52_diag_rc" -eq 0 ] && [ ! -s "$t52/diag.out" ] && [ -n "$t52_token_value" ] && [ "$t52_oracle_rc" -eq 0 ] \
        && t52_diag_ok "$t52/diag.json" start "$t52_start_nonce"; then
        pass "T52 public held-lock start failure writes one fixed DIAGNOSTICS event triple"
    else
        fail "T52 public held-lock start failure writes one fixed DIAGNOSTICS event triple" "rc=$t52_diag_rc oracle=$t52_oracle_rc token=[$t52_token_value]"
    fi
    t52_reconcile "$t52" start "$t52_token_value" '' implementation-agent >"$t52/wrong-role.out" 2>"$t52/wrong-role.err";t52_wrong_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/wrong-role.json" 2>/dev/null
    if [ "$t52_wrong_rc" -eq 4 ] && [ ! -s "$t52/wrong-role.err" ] && t52_error_ok "$t52/wrong-role.out" event-conflict \
        && cmp -s "$t52/diag.json" "$t52/wrong-role.json"; then
        pass "T52 reconcile-start wrong role leaves every fixed authority byte-identical"
    else
        fail "T52 reconcile-start wrong role leaves every fixed authority byte-identical" "rc=$t52_wrong_rc"
    fi
    t52_reconcile "$t52" start "$t52_token_value" '' >"$t52/first.out" 2>"$t52/first.err";t52_first_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/first.json" 2>"$t52/first-oracle.err";t52_first_oracle_rc=$?
    if [ "$t52_first_rc" -eq 0 ] && [ ! -s "$t52/first.err" ] && [ "$t52_first_oracle_rc" -eq 0 ] \
        && t52_start_final_ok "$t52/diag.json" "$t52/first.json" "$t52/first.out" false "$t52_token_value"; then
        pass "T52 public reconcile-start commits one digest-bound RESOLVED_START receipt"
    else
        fail "T52 public reconcile-start commits one digest-bound RESOLVED_START receipt" "rc=$t52_first_rc oracle=$t52_first_oracle_rc"
    fi
    t52_reconcile "$t52" start "$t52_token_value" '' >"$t52/repeat.out" 2>"$t52/repeat.err";t52_repeat_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/repeat.json" 2>/dev/null
    if [ "$t52_repeat_rc" -eq 0 ] && [ ! -s "$t52/repeat.err" ] && cmp -s "$t52/first.json" "$t52/repeat.json" \
        && t52_start_final_ok "$t52/diag.json" "$t52/repeat.json" "$t52/repeat.out" true "$t52_token_value"; then
        pass "T52 committed reconcile-start is byte-idempotent through the public CLI"
    else
        fail "T52 committed reconcile-start is byte-idempotent through the public CLI" "rc=$t52_repeat_rc"
    fi
    rm -rf "$t52"

    t52="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t52-stop.XXXXXX")";t52_fixture "$t52"
    t52_start "$t52" "$t52_start_nonce" 0 >"$t52/start.out" 2>"$t52/start.err"
    t52_stop "$t52" "$t52_stop_nonce" 1 >"$t52/diag.out" 2>"$t52/diag.err";t52_diag_rc=$?
    t52_token_value="$(t52_token "$t52/diag.err")";t52_container="$(find "$t52/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/diag.json" 2>"$t52/diag-oracle.err";t52_oracle_rc=$?
    if [ "$t52_diag_rc" -eq 0 ] && [ ! -s "$t52/diag.out" ] && [ -n "$t52_token_value" ] && [ "$t52_oracle_rc" -eq 0 ] \
        && t52_diag_ok "$t52/diag.json" stop "$t52_stop_nonce"; then
        pass "T52 public held-lock stop failure writes one fixed DIAGNOSTICS event triple"
    else
        fail "T52 public held-lock stop failure writes one fixed DIAGNOSTICS event triple" "rc=$t52_diag_rc oracle=$t52_oracle_rc token=[$t52_token_value]"
    fi
    t52_reconcile "$t52" stop "$t52_token_value" '' implementation-agent >"$t52/wrong-role.out" 2>"$t52/wrong-role.err";t52_wrong_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/wrong-role.json" 2>/dev/null
    if [ "$t52_wrong_rc" -eq 4 ] && [ ! -s "$t52/wrong-role.err" ] && t52_error_ok "$t52/wrong-role.out" identity-conflict \
        && cmp -s "$t52/diag.json" "$t52/wrong-role.json"; then
        pass "T52 reconcile-stop wrong role leaves every fixed authority byte-identical"
    else
        fail "T52 reconcile-stop wrong role leaves every fixed authority byte-identical" "rc=$t52_wrong_rc"
    fi
    t52_reconcile "$t52" stop "$t52_token_value" '' >"$t52/first.out" 2>"$t52/first.err";t52_first_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/first.json" 2>"$t52/first-oracle.err";t52_first_oracle_rc=$?
    if [ "$t52_first_rc" -eq 0 ] && [ ! -s "$t52/first.err" ] && [ "$t52_first_oracle_rc" -eq 0 ] \
        && t52_stop_final_ok "$t52/diag.json" "$t52/first.json" "$t52/first.out" false "$t52_token_value"; then
        pass "T52 public reconcile-stop compacts its RESOLVED_STOP authority into terminal receipts"
    else
        fail "T52 public reconcile-stop compacts its RESOLVED_STOP authority into terminal receipts" "rc=$t52_first_rc oracle=$t52_first_oracle_rc"
    fi
    t52_reconcile "$t52" stop "$t52_token_value" '' >"$t52/repeat.out" 2>"$t52/repeat.err";t52_repeat_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/repeat.json" 2>/dev/null
    if [ "$t52_repeat_rc" -eq 0 ] && [ ! -s "$t52/repeat.err" ] && cmp -s "$t52/first.json" "$t52/repeat.json" \
        && t52_stop_final_ok "$t52/diag.json" "$t52/repeat.json" "$t52/repeat.out" true "$t52_token_value"; then
        pass "T52 committed reconcile-stop is byte-idempotent through terminal authority"
    else
        fail "T52 committed reconcile-stop is byte-idempotent through terminal authority" "rc=$t52_repeat_rc"
    fi
    rm -rf "$t52"

    # The T168 receipt WAL has three physically distinct selected states for
    # each reconciliation kind.  The semantic will/did barriers stop only after
    # the corresponding journal header commit; the generic receipt barrier
    # stops after the RESOLVED_* header selects the receipt but before the
    # diagnostic is resolved.  Every prior is decoded from raw fixed packs.
    t52_foreign_token='evt1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    for t52_kind in start stop; do
        for t52_coordinate in will receipt-header did; do
            case "$t52_coordinate" in
                will) t52_barrier="reconcile-$t52_kind:will-diagnostic-resolved";t52_coordinate_label='will-diagnostic-resolved' ;;
                receipt-header)
                    if [ "$t52_kind" = start ]; then t52_slot=RESOLVED_START;else t52_slot=RESOLVED_STOP;fi
                    t52_barrier="reconcile-event:$t52_slot-header-committed";t52_coordinate_label="$t52_slot header-selected" ;;
                did) t52_barrier="reconcile-$t52_kind:did-diagnostic-resolved";t52_coordinate_label='did-diagnostic-resolved' ;;
            esac
            t52="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t52-wal.XXXXXX")";t52_fixture "$t52"
            if [ "$t52_kind" = stop ]; then
                t52_start "$t52" "$t52_start_nonce" 0 >"$t52/start.out" 2>"$t52/start.err"
                t52_stop "$t52" "$t52_stop_nonce" 1 >"$t52/diag.out" 2>"$t52/diag.err";t52_diag_rc=$?
            else
                t52_start "$t52" "$t52_start_nonce" 1 >"$t52/diag.out" 2>"$t52/diag.err";t52_diag_rc=$?
            fi
            t52_token_value="$(t52_token "$t52/diag.err")"
            t52_container="$(find "$t52/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
            t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/diag.json" 2>"$t52/diag-oracle.err";t52_diag_oracle_rc=$?
            t52_reconcile "$t52" "$t52_kind" "$t52_token_value" "$t52_barrier" >"$t52/crash.out" 2>"$t52/crash.err";t52_crash_rc=$?
            t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/prior.json" 2>"$t52/prior.err";t52_prior_rc=$?
            if [ "$t52_diag_rc" -eq 0 ] && [ -n "$t52_token_value" ] && [ "$t52_diag_oracle_rc" -eq 0 ] \
                && [ "$t52_crash_rc" -eq 86 ] && [ ! -s "$t52/crash.out" ] && [ ! -s "$t52/crash.err" ] \
                && [ "$t52_prior_rc" -eq 0 ] && t52_reconcile_prior_ok "$t52/diag.json" "$t52/prior.json" \
                    "$t52_kind" "$t52_coordinate" "$t52_token_value"; then
                pass "T52 public reconcile-$t52_kind $t52_coordinate_label crash exposes exact fixed receipt-WAL prior"
            else
                fail "T52 public reconcile-$t52_kind $t52_coordinate_label crash exposes exact fixed receipt-WAL prior" "diagnostic=$t52_diag_rc diagnostic_oracle=$t52_diag_oracle_rc crash=$t52_crash_rc prior=$t52_prior_rc token=[$t52_token_value]"
            fi

            t52_reconcile "$t52" "$t52_kind" "$t52_foreign_token" '' >"$t52/foreign.out" 2>"$t52/foreign.err";t52_foreign_rc=$?
            t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/foreign.json" 2>"$t52/foreign-oracle.err";t52_foreign_oracle_rc=$?
            if [ "$t52_foreign_rc" -eq 4 ] && [ ! -s "$t52/foreign.err" ] \
                && t52_error_ok "$t52/foreign.out" reconcile-unavailable && [ "$t52_foreign_oracle_rc" -eq 0 ] \
                && cmp -s "$t52/prior.json" "$t52/foreign.json"; then
                pass "T52 public reconcile-$t52_kind $t52_coordinate_label rejects a foreign token without mutation"
            else
                fail "T52 public reconcile-$t52_kind $t52_coordinate_label rejects a foreign token without mutation" "rc=$t52_foreign_rc oracle=$t52_foreign_oracle_rc"
            fi

            if [ "$t52_kind" = start ]; then t52_wrong_code=event-conflict;else t52_wrong_code=identity-conflict;fi
            t52_reconcile "$t52" "$t52_kind" "$t52_token_value" '' implementation-agent >"$t52/wrong.out" 2>"$t52/wrong.err";t52_wrong_rc=$?
            t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/wrong.json" 2>"$t52/wrong-oracle.err";t52_wrong_oracle_rc=$?
            if [ "$t52_wrong_rc" -eq 4 ] && [ ! -s "$t52/wrong.err" ] \
                && t52_error_ok "$t52/wrong.out" "$t52_wrong_code" && [ "$t52_wrong_oracle_rc" -eq 0 ] \
                && cmp -s "$t52/prior.json" "$t52/wrong.json"; then
                pass "T52 public reconcile-$t52_kind $t52_coordinate_label rejects a foreign role without mutation"
            else
                fail "T52 public reconcile-$t52_kind $t52_coordinate_label rejects a foreign role without mutation" "rc=$t52_wrong_rc oracle=$t52_wrong_oracle_rc code=$t52_wrong_code"
            fi

            t52_reconcile "$t52" "$t52_kind" "$t52_token_value" '' >"$t52/recover.out" 2>"$t52/recover.err";t52_recover_rc=$?
            t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/final.json" 2>"$t52/final.err";t52_final_rc=$?
            t52_reconcile "$t52" "$t52_kind" "$t52_token_value" '' >"$t52/repeat.out" 2>"$t52/repeat.err";t52_repeat_rc=$?
            t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/repeat.json" 2>"$t52/repeat-oracle.err";t52_repeat_oracle_rc=$?
            if [ "$t52_kind" = start ]; then
                t52_start_final_ok "$t52/diag.json" "$t52/final.json" "$t52/recover.out" false "$t52_token_value";t52_recover_ok=$?
                t52_start_final_ok "$t52/diag.json" "$t52/repeat.json" "$t52/repeat.out" true "$t52_token_value";t52_repeat_ok=$?
            else
                t52_stop_final_ok "$t52/diag.json" "$t52/final.json" "$t52/recover.out" false "$t52_token_value";t52_recover_ok=$?
                t52_stop_final_ok "$t52/diag.json" "$t52/repeat.json" "$t52/repeat.out" true "$t52_token_value";t52_repeat_ok=$?
            fi
            if [ "$t52_recover_rc" -eq 0 ] && [ ! -s "$t52/recover.err" ] && [ "$t52_final_rc" -eq 0 ] \
                && [ "$t52_recover_ok" -eq 0 ] && [ "$t52_repeat_rc" -eq 0 ] && [ ! -s "$t52/repeat.err" ] \
                && [ "$t52_repeat_oracle_rc" -eq 0 ] && [ "$t52_repeat_ok" -eq 0 ] \
                && cmp -s "$t52/final.json" "$t52/repeat.json"; then
                pass "T52 public reconcile-$t52_kind $t52_coordinate_label recovers once then replays byte-idempotently"
            else
                fail "T52 public reconcile-$t52_kind $t52_coordinate_label recovers once then replays byte-idempotently" "recover=$t52_recover_rc recover_oracle=$t52_final_rc recover_check=$t52_recover_ok repeat=$t52_repeat_rc repeat_oracle=$t52_repeat_oracle_rc repeat_check=$t52_repeat_ok"
            fi
            rm -rf "$t52"
        done
    done

    # The owned incomplete stop-journal exception is deliberately narrower than
    # an arbitrary DONE.  A normal public stop has already handed off terminal
    # authority and has no matching diagnostic/receipt owner for this token.
    t52="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t52-natural-done.XXXXXX")";t52_fixture "$t52"
    t52_start "$t52" "$t52_start_nonce" 0 >"$t52/start.out" 2>"$t52/start.err";t52_natural_start_rc=$?
    t52_stop "$t52" "$t52_stop_nonce" 0 >"$t52/stop.out" 2>"$t52/stop.err";t52_natural_stop_rc=$?
    t52_container="$(find "$t52/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/before.json" 2>"$t52/before.err";t52_before_rc=$?
    t52_reconcile "$t52" stop "$t52_foreign_token" '' >"$t52/reconcile.out" 2>"$t52/reconcile.err";t52_natural_reconcile_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/after.json" 2>"$t52/after.err";t52_after_rc=$?
    if [ "$t52_natural_start_rc" -eq 0 ] && [ ! -s "$t52/start.out" ] && [ ! -s "$t52/start.err" ] \
        && [ "$t52_natural_stop_rc" -eq 0 ] && [ ! -s "$t52/stop.out" ] && [ ! -s "$t52/stop.err" ] \
        && [ "$t52_before_rc" -eq 0 ] && [ "$t52_natural_reconcile_rc" -eq 4 ] && [ ! -s "$t52/reconcile.err" ] \
        && t52_error_ok "$t52/reconcile.out" already-terminal && [ "$t52_after_rc" -eq 0 ] \
        && cmp -s "$t52/before.json" "$t52/after.json"; then
        pass "T52 public reconcile-stop cannot claim a foreign natural DONE"
    else
        fail "T52 public reconcile-stop cannot claim a foreign natural DONE" "start=$t52_natural_start_rc stop=$t52_natural_stop_rc before=$t52_before_rc reconcile=$t52_natural_reconcile_rc after=$t52_after_rc"
    fi
    rm -rf "$t52"

    # A primary failure whose diagnostic write also fails is tokenless.  The
    # start fixture first reaches public ACTIVE_ACK with no logical records;
    # replaying the exact event may then fail without changing catalog or pack
    # bytes.  Stop uses a normally active public instance and the same oracle.
    t52="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t52-double-start.XXXXXX")";t52_fixture "$t52"
    t52_start "$t52" "$t52_start_nonce" 0 'catalog-recovery:cell-active-ack' >"$t52/ack.out" 2>"$t52/ack.err";t52_ack_rc=$?
    t52_container="$(find "$t52/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/before.json" 2>"$t52/before.err";t52_before_rc=$?
    ZYZ_TEST_DIAGNOSTIC_WRITE_FAIL=1 t52_start "$t52" "$t52_start_nonce" 1 >"$t52/fail.out" 2>"$t52/fail.err";t52_fail_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/after.json" 2>"$t52/after.err";t52_after_rc=$?
    if t37_unavailable_ok "$t52_ack_rc" "$t52/ack.out" "$t52/ack.err" && [ "$t52_before_rc" -eq 0 ] \
        && [ "$t52_fail_rc" -eq 0 ] && [ ! -s "$t52/fail.out" ] && t33_diag_exact "$t52/fail.err" primary-diagnostic-write-failed \
        && [ "$t52_after_rc" -eq 0 ] && cmp -s "$t52/before.json" "$t52/after.json"; then
        pass "T52 start primary plus diagnostic double failure remains tokenless and byte-zero-effect"
    else
        fail "T52 start primary plus diagnostic double failure remains tokenless and byte-zero-effect" "ack=$t52_ack_rc before=$t52_before_rc fail=$t52_fail_rc after=$t52_after_rc"
    fi
    rm -rf "$t52"

    t52="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t52-double-stop.XXXXXX")";t52_fixture "$t52"
    t52_start "$t52" "$t52_start_nonce" 0 >/dev/null 2>"$t52/start.err"
    t52_container="$(find "$t52/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/before.json" 2>"$t52/before.err";t52_before_rc=$?
    ZYZ_TEST_DIAGNOSTIC_WRITE_FAIL=1 t52_stop "$t52" "$t52_stop_nonce" 1 >"$t52/fail.out" 2>"$t52/fail.err";t52_fail_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/after.json" 2>"$t52/after.err";t52_after_rc=$?
    if [ "$t52_before_rc" -eq 0 ] && [ "$t52_fail_rc" -eq 0 ] && [ ! -s "$t52/fail.out" ] \
        && t33_diag_exact "$t52/fail.err" primary-diagnostic-write-failed && [ "$t52_after_rc" -eq 0 ] \
        && cmp -s "$t52/before.json" "$t52/after.json"; then
        pass "T52 stop primary plus diagnostic double failure remains tokenless and byte-zero-effect"
    else
        fail "T52 stop primary plus diagnostic double failure remains tokenless and byte-zero-effect" "before=$t52_before_rc fail=$t52_fail_rc after=$t52_after_rc"
    fi
    rm -rf "$t52"

    # Instance-lock timeout is observed before event selection. A separate live
    # process owns the real preallocated lock carrier; the hook must not scan,
    # generate a token, write DIAGNOSTICS, or alter any selected pack image.
    t52="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t52-lock.XXXXXX")";t52_fixture "$t52"
    t52_start "$t52" "$t52_start_nonce" 0 >/dev/null 2>"$t52/start.err"
    t52_container="$(find "$t52/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/before.json" 2>"$t52/before.err";t52_before_rc=$?
    python3 - "$t52_container/$t52_key.lock.v1" "$t52/ready" "$t52/go" <<'PY' &
import fcntl,os,sys,time
fd=os.open(sys.argv[1],os.O_RDWR);fcntl.flock(fd,fcntl.LOCK_EX);open(sys.argv[2],"wb").close()
while not os.path.exists(sys.argv[3]):time.sleep(.02)
fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)
PY
    t52_lock_pid=$!
    t52_wait=0;while [ ! -e "$t52/ready" ] && [ "$t52_wait" -lt 200 ];do sleep .02;t52_wait=$((t52_wait+1));done
    ZYZ_AGENT_LOCK_ACQUIRE_SEC=1 t52_stop "$t52" "$t52_stop_nonce" 0 >"$t52/lock.out" 2>"$t52/lock.err";t52_lock_rc=$?
    : >"$t52/go";wait "$t52_lock_pid";t52_holder_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/after.json" 2>"$t52/after.err";t52_after_rc=$?
    if [ "$t52_before_rc" -eq 0 ] && [ "$t52_holder_rc" -eq 0 ] && [ "$t52_lock_rc" -eq 0 ] && [ ! -s "$t52/lock.out" ] \
        && t33_diag_exact "$t52/lock.err" event-lock-unavailable && [ "$t52_after_rc" -eq 0 ] \
        && cmp -s "$t52/before.json" "$t52/after.json"; then
        pass "T52 live instance lock makes public stop tokenless and byte-zero-effect"
    else
        fail "T52 live instance lock makes public stop tokenless and byte-zero-effect" "before=$t52_before_rc holder=$t52_holder_rc hook=$t52_lock_rc after=$t52_after_rc"
    fi
    rm -rf "$t52"

    t52_seed_ring() { # audit-pack key slot kind count
        python3 - "$1" "$2" "$3" "$4" "$5" "${6:-}" "$t52_raw" "$t52_role" <<'PY'
import hashlib,json,os,struct,sys
path,key,slot,kind,count,collision_nonces,raw_id,role=sys.argv[1:];count=int(count)
D=lambda d,v:hashlib.sha256(d+v).digest();J=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=True).encode()
layout={"DIAGNOSTICS":(352256,40960),"RESOLVED_START":(106496,65536),"RESOLVED_STOP":(172032,65536),"LATE_EVENT":(303104,16384)}
def parse(raw,magic):
 if raw[:8]!=magic:raise ValueError("magic")
 schema,flags,generation,length=struct.unpack_from(">HHQI",raw,8);source=bytearray(raw);source[56:88]=bytes(32);payload=raw[128:128+length]
 if schema!=1 or flags or generation<1 or length>len(raw)-128 or raw[56:88]!=D(b"zyz-pack-image-v1",bytes(source)) or raw[96:128]!=D(b"zyz-pack-payload-v1",payload):raise ValueError("image")
 return generation,raw[24:56],json.loads(payload),D(b"zyz-pack-image-id-v1",raw)
def image(magic,size,generation,predecessor,payload,image_domain,payload_domain):
 encoded=J(payload);raw=bytearray(size);raw[:8]=magic;struct.pack_into(">HHQI",raw,8,1,0,generation,len(encoded));raw[24:56]=predecessor;raw[96:128]=D(payload_domain,encoded);raw[128:128+len(encoded)]=encoded;source=bytearray(raw);source[56:88]=bytes(32);raw[56:88]=D(image_domain,bytes(source));return bytes(raw)
data=bytearray(open(path,"rb").read());headers=[]
for bank in (0,1):
 raw=bytes(data[bank*4096:(bank+1)*4096])
 if raw==bytes(4096):continue
 try:headers.append((parse(raw,b"ZYZAUDH1")[0],bank,raw,parse(raw,b"ZYZAUDH1")))
 except Exception:pass
headers.sort();generation,bank,header_raw,parsed=headers[-1];meta=parsed[2]
def event(i):
 if collision_nonces:
  nonce=collision_nonces.split(",")[i];digest=hashlib.sha256(os.fsencode(raw_id)).hexdigest();rb=role.encode();db=digest.encode();nb=nonce.encode();record=bytes([1,2])+len(rb).to_bytes(2,"big")+rb+len(db).to_bytes(2,"big")+db+len(nb).to_bytes(2,"big")+nb
  return {"schema_version":1,"event_token":"evt1-"+hashlib.sha256(record).hexdigest(),"nonce_sha256":hashlib.sha256(bytes.fromhex(nonce)).hexdigest(),"event_record_digest":hashlib.sha256(record).hexdigest()}
 token=hashlib.sha256((slot+"-token-"+str(i)).encode()).hexdigest();nonce=hashlib.sha256((slot+"-nonce-"+str(i)).encode()).hexdigest();record=hashlib.sha256((slot+"-record-"+str(i)).encode()).hexdigest()
 return {"schema_version":1,"event_token":"evt1-"+token,"nonce_sha256":nonce,"event_record_digest":record}
entries=[]
for i in range(count):
 e=event(i)
 if slot=="DIAGNOSTICS":
  e.update(schema_version=1,kind=kind,instance_key=key,raw_id_sha256="11"*32,canonical_role="review-agent",event_epoch=i,reason_sha256="22"*32,needs_reconcile=True,resolved_receipt_digest=None)
 elif slot.startswith("RESOLVED_"):
  e.update(schema_version=1,receipt_type=kind,txn_id="33"*32,raw_id_sha256="11"*32,canonical_role="review-agent",owner_diagnostic_digest="44"*32,committed_journal_digest="55"*32,target_slot_generation={},target_slot_digest={},resolved_epoch=i,outcome="seeded-boundary",cleanup_state="not-applicable",cleanup_txn_digest=None)
 entries.append(e)
payload={"schema_version":1,("events" if slot=="LATE_EVENT" else "entries"):entries}
if slot.startswith("RESOLVED_"):payload["receipt_type"]=kind
offset,length=layout[slot];half=length//2;prior=meta["selected"].get(slot);record_bank=0 if prior is None else 1-prior["bank"];record_generation=1 if prior is None else prior["generation"]+1;record_predecessor=bytes(32) if prior is None else bytes.fromhex(prior["digest"])
record=image(b"ZYZREC1\0",half,record_generation,record_predecessor,payload,b"zyz-instance-record-image-v1",b"zyz-instance-record-payload-v1");record_digest=D(b"zyz-instance-record-id-v1",record).hex();data[offset+record_bank*half:offset+(record_bank+1)*half]=record
selected=dict(meta["selected"]);selected[slot]={"bank":record_bank,"generation":record_generation,"digest":record_digest};next_meta={"schema_version":1,"pack_kind":"audit","instance_key":key,"generation":generation+1,"selected":selected};next_bank=1-bank;next_header=image(b"ZYZAUDH1",4096,generation+1,parsed[3],next_meta,b"zyz-pack-image-v1",b"zyz-pack-payload-v1");data[next_bank*4096:(next_bank+1)*4096]=next_header
with open(path,"r+b") as f:f.write(data);f.flush();os.fsync(f.fileno())
PY
    }
    for t52_spec in 'DIAGNOSTICS start' 'DIAGNOSTICS stop' 'RESOLVED_START start' 'RESOLVED_STOP stop' 'LATE_EVENT stop'; do
        t52_slot="${t52_spec% *}";t52_kind="${t52_spec#* }"
        for t52_count in 16 17; do
            t52="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t52-ring.XXXXXX")";t52_fixture "$t52"
            t52_start "$t52" "$t52_start_nonce" 0 >/dev/null 2>"$t52/start.err"
            t52_container="$(find "$t52/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
            t52_seed_ring "$t52_container/$t52_key.audit-pack.v1" "$t52_key" "$t52_slot" "$t52_kind" "$t52_count" >"$t52/seed.out" 2>"$t52/seed.err";t52_seed_rc=$?
            t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/before.json" 2>"$t52/before.err";t52_before_rc=$?
            ZYZ_TEST_DISABLE_SECRETS=1 ZYZ_TEST_DISABLE_URANDOM=1 \
                t52_stop "$t52" invalid 0 >"$t52/hook.out" 2>"$t52/hook.err";t52_hook_rc=$?
            t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/after.json" 2>"$t52/after.err";t52_after_rc=$?
            if [ "$t52_count" -eq 16 ]; then t52_code=event-randomness-unavailable;t52_label='accepts exact maximum before randomness ceiling';else t52_code=event-inventory-invalid;t52_label='rejects maximum+1 before randomness';fi
            if [ "$t52_seed_rc" -eq 0 ] && [ "$t52_before_rc" -eq 0 ] && [ "$t52_hook_rc" -eq 0 ] && [ ! -s "$t52/hook.out" ] \
                && t33_diag_exact "$t52/hook.err" "$t52_code" && [ "$t52_after_rc" -eq 0 ] && cmp -s "$t52/before.json" "$t52/after.json"; then
                pass "T52 fixed $t52_slot ring $t52_label"
            else
                fail "T52 fixed $t52_slot ring $t52_label" "seed=$t52_seed_rc before=$t52_before_rc hook=$t52_hook_rc after=$t52_after_rc"
            fi
            rm -rf "$t52"
        done
    done

    t52_collision_nonces='00000000000000000000000000000001,00000000000000000000000000000002,00000000000000000000000000000003,00000000000000000000000000000004,00000000000000000000000000000005,00000000000000000000000000000006,00000000000000000000000000000007,00000000000000000000000000000008'
    t52="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t52-collision.XXXXXX")";t52_fixture "$t52"
    t52_start "$t52" "$t52_start_nonce" 0 >/dev/null 2>"$t52/start.err"
    t52_container="$(find "$t52/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t52_seed_ring "$t52_container/$t52_key.audit-pack.v1" "$t52_key" LATE_EVENT stop 8 "$t52_collision_nonces" >"$t52/seed.out" 2>"$t52/seed.err";t52_seed_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/before.json" 2>"$t52/before.err";t52_before_rc=$?
    t52_stop "$t52" "$t52_collision_nonces" 0 >"$t52/hook.out" 2>"$t52/hook.err";t52_hook_rc=$?
    t33_oracle "$t52_container" "$t52_key" "$t52_raw" "$t52_role" "$t52_start_nonce" >"$t52/after.json" 2>"$t52/after.err";t52_after_rc=$?
    if [ "$t52_seed_rc" -eq 0 ] && [ "$t52_before_rc" -eq 0 ] && [ "$t52_hook_rc" -eq 0 ] && [ ! -s "$t52/hook.out" ] \
        && t33_diag_exact "$t52/hook.err" event-token-collision && [ "$t52_after_rc" -eq 0 ] \
        && cmp -s "$t52/before.json" "$t52/after.json"; then
        pass "T52 eight retained late-event collisions exhaust public stop without a token or mutation"
    else
        fail "T52 eight retained late-event collisions exhaust public stop without a token or mutation" "seed=$t52_seed_rc before=$t52_before_rc hook=$t52_hook_rc after=$t52_after_rc"
    fi
    rm -rf "$t52"
else
    skip "T52 fixed-pack diagnostics/reconciliation require T33 GENESIS and public runtime CLI"
fi

# ---------------------------------------------------------------------------
# T53  Public fixed-baseline physical no-output comparison.
#
# A real SubagentStart publishes the baseline through the fixed claim/catalog
# path.  Every observation then enters through public probe-status; no pathname
# is used as a logical baseline or liveness record.  The directory/FIFO pair is
# deliberately same-path, permissions, size and payload so only canonical type
# distinguishes it.  Restored neighbors prove the comparator remains live.
# Observation ceiling: this userspace fixture discriminates the approved local
# physical record fields, exclusions and frozen policy; it does not recreate a
# hostile mount namespace or kernel power-loss event.  Do not read T53 green as
# proof of those native boundaries, which remain owned by T37/T46/T49.
# ---------------------------------------------------------------------------
if [ "${t33_supported:-0}" -eq 1 ] && command -v t37_public >/dev/null 2>&1; then
    t53_probe() { # sandbox output
        (
            cd "$1" || exit 1
            ZYZ_WATCHDOG_NO_OUTPUT_SEC=1 \
                bash "$REPO_ROOT/hooks/scripts/agent-runtime-state.sh" \
                probe-status "$1/.zyz-worker/tasks/task" "$t33_raw"
        ) >"$2" 2>"$2.err"
    }
    t53_expect() { # output state true|false
        python3 - "$1" "$2" "$3" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]));state=sys.argv[2];changed=sys.argv[3]=="true"
raise SystemExit(0 if x.get("ok") is True and x.get("trusted") is True and x.get("tracking_capability")=="armed" and x.get("no_output_state")==state and x.get("no_output_changed") is changed and isinstance(x.get("baseline_digest"),str) and isinstance(x.get("current_digest"),str) else 1)
PY
    }
    t53_publication_class() { # probe-output elapsed-ns start-rc start-out start-err probe-rc probe-err
        python3 - "$@" <<'PY'
import json,re,sys
elapsed=sys.argv[2]  # retained for caller diagnostics only; it is not a publication predicate
try:
 x=json.load(open(sys.argv[1]));start_rc=int(sys.argv[3]);probe_rc=int(sys.argv[6])
except (OSError,ValueError,TypeError,json.JSONDecodeError):
 print("invalid");raise SystemExit(0)
if not isinstance(x,dict):
 print("invalid");raise SystemExit(0)
empty=lambda path:open(path,"rb").read()==b""
envelope=(start_rc==0 and probe_rc==0 and empty(sys.argv[4]) and empty(sys.argv[5]) and empty(sys.argv[7]))
hex64=lambda value:isinstance(value,str) and re.fullmatch(r"[0-9a-f]{64}",value) is not None
common=(envelope and x.get("ok") is True and x.get("state")=="disabled" and x.get("error") is None and
        x.get("trusted") is True and x.get("tracking_capability")=="armed")
ready=(common and type(x.get("baseline_epoch")) is int and x.get("baseline_epoch")>=0 and
       hex64(x.get("baseline_digest")) and hex64(x.get("current_digest")) and
       x.get("baseline_digest")==x.get("current_digest") and
       x.get("no_output_state")=="unchanged" and x.get("no_output_changed") is False)
unavailable=(common and all(x.get(name) is None for name in ("baseline_epoch","baseline_digest","current_digest")) and
             x.get("no_output_state")=="unavailable" and x.get("no_output_changed") is None)
print("ready" if ready else "trusted-unavailable" if unavailable else "invalid")
PY
    }
    t53_predicate="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t53-predicate.XXXXXX")"
    : >"$t53_predicate/empty"; printf 'diagnostic\n' >"$t53_predicate/nonempty"
    printf '{"ok":true,"state":"disabled","error":null,"trusted":true,"tracking_capability":"armed","baseline_epoch":0,"baseline_digest":"%064d","current_digest":"%064d","no_output_state":"unchanged","no_output_changed":false}\n' 0 0 >"$t53_predicate/ready"
    printf '%s\n' '{"ok":true,"state":"disabled","error":null,"trusted":true,"tracking_capability":"armed","baseline_epoch":null,"baseline_digest":null,"current_digest":null,"no_output_state":"unavailable","no_output_changed":null}' >"$t53_predicate/unavailable"
    printf '%s\n' '{}' >"$t53_predicate/silent"
    printf '%s\n' '{"ok":true,"state":"disabled","error":null,"trusted":false,"tracking_capability":"armed","baseline_epoch":null,"baseline_digest":null,"current_digest":null,"no_output_state":"unavailable","no_output_changed":null}' >"$t53_predicate/untrusted"
    printf '%s\n' '{"ok":true,"state":"disabled","error":{"code":"tracking-unavailable"},"trusted":true,"tracking_capability":"armed","baseline_epoch":null,"baseline_digest":null,"current_digest":null,"no_output_state":"unavailable","no_output_changed":null}' >"$t53_predicate/error"
    printf '%s\n' '{"ok":true,"state":"running","error":null,"trusted":true,"tracking_capability":"armed","baseline_epoch":null,"baseline_digest":null,"current_digest":null,"no_output_state":"unavailable","no_output_changed":null}' >"$t53_predicate/wrong-state"
    printf '%s\n' '{"ok":true,"state":"disabled","error":null,"trusted":true,"tracking_capability":"armed","baseline_epoch":0,"baseline_digest":null,"current_digest":null,"no_output_state":"unavailable","no_output_changed":null}' >"$t53_predicate/wrong-null"
    printf '%s\n' '{not-json' >"$t53_predicate/malformed"
    printf '%s\n' '[]' >"$t53_predicate/nonobject"
    t53_classify_fixture() { # output elapsed start-rc probe-rc start-stderr probe-stderr
        t53_publication_class "$1" "$2" "$3" "$t53_predicate/empty" "$5" "$4" "$6"
    }
    if [ "$(t53_classify_fixture "$t53_predicate/ready" 1 0 0 "$t53_predicate/empty" "$t53_predicate/empty")" = ready ] \
        && [ "$(t53_classify_fixture "$t53_predicate/unavailable" 1 0 0 "$t53_predicate/empty" "$t53_predicate/empty")" = trusted-unavailable ] \
        && [ "$(t53_classify_fixture "$t53_predicate/unavailable" 5000000000 0 0 "$t53_predicate/empty" "$t53_predicate/empty")" = trusted-unavailable ] \
        && [ "$(t53_classify_fixture "$t53_predicate/silent" 1 0 0 "$t53_predicate/empty" "$t53_predicate/empty")" = invalid ] \
        && [ "$(t53_classify_fixture "$t53_predicate/untrusted" 1 0 0 "$t53_predicate/empty" "$t53_predicate/empty")" = invalid ] \
        && [ "$(t53_classify_fixture "$t53_predicate/error" 1 0 0 "$t53_predicate/empty" "$t53_predicate/empty")" = invalid ] \
        && [ "$(t53_classify_fixture "$t53_predicate/wrong-state" 1 0 0 "$t53_predicate/empty" "$t53_predicate/empty")" = invalid ] \
        && [ "$(t53_classify_fixture "$t53_predicate/wrong-null" 1 0 0 "$t53_predicate/empty" "$t53_predicate/empty")" = invalid ] \
        && [ "$(t53_classify_fixture "$t53_predicate/malformed" 1 0 0 "$t53_predicate/empty" "$t53_predicate/empty")" = invalid ] \
        && [ "$(t53_classify_fixture "$t53_predicate/nonobject" 1 0 0 "$t53_predicate/empty" "$t53_predicate/empty")" = invalid ] \
        && [ "$(t53_classify_fixture "$t53_predicate/ready" 1 1 0 "$t53_predicate/empty" "$t53_predicate/empty")" = invalid ] \
        && [ "$(t53_classify_fixture "$t53_predicate/ready" 1 0 1 "$t53_predicate/empty" "$t53_predicate/empty")" = invalid ] \
        && [ "$(t53_classify_fixture "$t53_predicate/ready" 1 0 0 "$t53_predicate/nonempty" "$t53_predicate/empty")" = invalid ] \
        && [ "$(t53_classify_fixture "$t53_predicate/ready" 1 0 0 "$t53_predicate/empty" "$t53_predicate/nonempty")" = invalid ] \
        && [ "$(t53_publication_class "$t53_predicate/ready" 1 0 "$t53_predicate/nonempty" "$t53_predicate/empty" 0 "$t53_predicate/empty")" = invalid ]; then
        pass "T53 publication predicate distinguishes ready, trusted unavailable, and invalid envelopes"
    else
        fail "T53 publication predicate distinguishes ready, trusted unavailable, and invalid envelopes"
    fi
    rm -rf "$t53_predicate"
    t53_policy_ok() { # oracle agents-dir
        python3 - "$1" "$2" <<'PY'
import hashlib,json,os,re,stat,sys
x=json.load(open(sys.argv[1]));agents=sys.argv[2];live=x["packs"]["work"]["records"]["LIVE_INVENTORY"]["payload"]
headers=[v for v in live.get("active",[]) if v.get("purpose")=="baseline-header"]
if len(headers)!=1:raise SystemExit(1)
descriptor=headers[0];path=os.path.join(agents,descriptor.get("basename",""));st=os.lstat(path);raw=open(path,"rb").read();header=json.loads(raw)
want={"ZYZ_NO_OUTPUT_MAX_PATHS":10000,"ZYZ_NO_OUTPUT_MAX_FILE_BYTES":16777216,
 "ZYZ_NO_OUTPUT_MAX_TOTAL_BYTES":67108864,"ZYZ_NO_OUTPUT_MAX_INVENTORY_BYTES":33554432,
 "ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES":33554432,"ZYZ_NO_OUTPUT_MAX_RSS_BYTES":134217728,
 "ZYZ_NO_OUTPUT_MAX_TEMP_BYTES":134217728,"ZYZ_NO_OUTPUT_SNAPSHOT_TIMEOUT_SEC":8}
descriptor_ok=(set(descriptor)=={"purpose","generation","basename","type","size","sha256","dev","ino","nlink","mtime_ns","mount_id"} and
 descriptor.get("type")=="regular" and re.fullmatch(r"[A-Za-z0-9._-]{1,255}",descriptor.get("basename","")) is not None and
 stat.S_ISREG(st.st_mode) and (st.st_size,st.st_dev,st.st_ino,st.st_nlink,st.st_mtime_ns,hashlib.sha256(raw).hexdigest())==
 (descriptor.get("size"),descriptor.get("dev"),descriptor.get("ino"),descriptor.get("nlink"),descriptor.get("mtime_ns"),descriptor.get("sha256")))
header_ok=(set(header)=={"schema_version","instance_key","baseline_epoch","manifest_digest","observation","comparison_policy","cross_invocation_invariants"} and
 header.get("schema_version")==1 and header.get("instance_key")==live.get("instance_key") and isinstance(header.get("baseline_epoch"),int) and
 re.fullmatch(r"[0-9a-f]{64}",str(header.get("manifest_digest"))) is not None and isinstance(header.get("observation"),dict) and
 header["observation"].get("manifest_digest")==header.get("manifest_digest") and
 set(header.get("cross_invocation_invariants",{}))=={"root_dev","root_ino","root_mount_id","git_binding","runtime_binding","raw_path_capability","mount_capability","rlimit_as_capability"} and
 header.get("comparison_policy")==want)
raise SystemExit(0 if descriptor_ok and header_ok else 1)
PY
    }
    t53_check() { # sandbox label state bool
        t53_output="$1/.zyz-worker/tasks/task/runtime/t53-check.out"
        t53_probe "$1" "$t53_output";t53_rc=$?
        if [ "$t53_rc" -eq 0 ] && [ ! -s "$t53_output.err" ] && t53_expect "$t53_output" "$3" "$4"; then
            pass "T53 $2"
        else
            fail "T53 $2" "rc=$t53_rc out=$(tr '\n' ' ' < "$t53_output") stderr=$(tr '\n' ' ' < "$t53_output.err")"
        fi
    }

    t53="$(mktemp -d "${TMPDIR:-/tmp}/zyz-t53.XXXXXX")";t37_fixture "$t53"
    chmod 0644 "$t53/deliverable.txt"
    mkdir "$t53/type-field" && chmod 0700 "$t53/type-field"
    t53_start_begin="$(python3 -c 'import time;print(time.monotonic_ns())')"
    t37_public "$t53" '' '' >"$t53/.zyz-worker/tasks/task/runtime/t53-start.out" 2>"$t53/.zyz-worker/tasks/task/runtime/t53-start.err";t53_start_rc=$?
    t53_start_end="$(python3 -c 'import time;print(time.monotonic_ns())')"
    t53_start_elapsed=$((t53_start_end-t53_start_begin))
    # The public threshold has a legal minimum of one second. Waiting here is
    # an observation precondition, not a timing-boundary assertion.
    sleep 2
    t53_probe "$t53" "$t53/.zyz-worker/tasks/task/runtime/t53-publication.out";t53_publication_rc=$?
    t53_publication="$(t53_publication_class \
        "$t53/.zyz-worker/tasks/task/runtime/t53-publication.out" "$t53_start_elapsed" \
        "$t53_start_rc" "$t53/.zyz-worker/tasks/task/runtime/t53-start.out" \
        "$t53/.zyz-worker/tasks/task/runtime/t53-start.err" "$t53_publication_rc" \
        "$t53/.zyz-worker/tasks/task/runtime/t53-publication.out.err")"
    if [ "$t53_publication" = ready ]; then
        pass "T53 public SubagentStart publication is confirmed by terminal-first public probe-status"
    t53_container="$(find "$t53/.zyz-worker/tasks/task/runtime" -type d -name .snapshot-gc-owned.v1 -print 2>/dev/null)"
    t33_oracle "$t53_container" "$t33_key" "$t33_raw" "$t33_role" "$t33_nonce_a" >"$t53/.zyz-worker/tasks/task/runtime/t53-policy.json" 2>"$t53/.zyz-worker/tasks/task/runtime/t53-policy.err";t53_policy_rc=$?
    if [ "$t53_policy_rc" -eq 0 ] && t53_policy_ok "$t53/.zyz-worker/tasks/task/runtime/t53-policy.json" "$t53/.zyz-worker/tasks/task/runtime/agents"; then
        pass "T53 fixed baseline freezes exactly eight snapshot ceilings at independent defaults"
    else
        fail "T53 fixed baseline freezes exactly eight snapshot ceilings at independent defaults" "oracle=$t53_policy_rc"
    fi
    t53_check "$t53" "unchanged complete physical tree is positive no-output" unchanged false
    ZYZ_NO_OUTPUT_MAX_PATHS=1 ZYZ_NO_OUTPUT_MAX_FILE_BYTES=1 ZYZ_NO_OUTPUT_MAX_TOTAL_BYTES=1 \
        ZYZ_NO_OUTPUT_MAX_INVENTORY_BYTES=1 ZYZ_NO_OUTPUT_MAX_MANIFEST_BYTES=1 \
        ZYZ_NO_OUTPUT_MAX_RSS_BYTES=16777216 ZYZ_NO_OUTPUT_MAX_TEMP_BYTES=1 \
        ZYZ_NO_OUTPUT_SNAPSHOT_TIMEOUT_SEC=1 \
        t53_check "$t53" "post-baseline snapshot ceiling changes cannot replace the frozen policy" unchanged false

    printf 'claim-producer-physical-onput\n' > "$t53/deliverable.txt"
    t53_check "$t53" "equal-length content replacement with stable type mode and size is changed" changed true
    printf 'claim-producer-physical-input\n' > "$t53/deliverable.txt";chmod 0644 "$t53/deliverable.txt"
    t53_check "$t53" "restored equal content returns to unchanged" unchanged false

    chmod 0600 "$t53/deliverable.txt"
    t53_check "$t53" "permission-only physical change is observed" changed true
    chmod 0644 "$t53/deliverable.txt"
    t53_check "$t53" "restored permissions return to unchanged" unchanged false

    rmdir "$t53/type-field";mkfifo "$t53/type-field";chmod 0700 "$t53/type-field"
    t53_check "$t53" "same-path permission size payload directory-to-FIFO type is observed" changed true
    rm -f "$t53/type-field";mkdir "$t53/type-field";chmod 0700 "$t53/type-field"
    t53_check "$t53" "restored directory type returns to unchanged" unchanged false

    rm -f "$t53/deliverable.txt"
    t53_check "$t53" "baseline-present to current-absent is observed" changed true
    printf 'claim-producer-physical-input\n' > "$t53/deliverable.txt";chmod 0644 "$t53/deliverable.txt"
    t53_check "$t53" "restored absent member returns to unchanged" unchanged false

    printf 'transient\n' > "$t53/net-reverted";rm -f "$t53/net-reverted"
    t53_check "$t53" "create-delete net reversion remains unchanged" unchanged false

    printf 'runtime-only\n' > "$t53/.zyz-worker/tasks/task/runtime/no-output-excluded"
    t53_check "$t53" "this task runtime is exactly excluded" unchanged false
    rm -f "$t53/.zyz-worker/tasks/task/runtime/no-output-excluded"

    printf -- '## Metadata\n\n- Current Phase: review\n' > "$t53/.zyz-worker/tasks/task/status.md"
    t53_check "$t53" "this task status is not excluded" changed true
    printf -- '## Metadata\n\n- Current Phase: implementation\n' > "$t53/.zyz-worker/tasks/task/status.md"
    t53_check "$t53" "restored task status returns to unchanged" unchanged false

    mkdir -p "$t53/.zyz-worker/tasks/other/runtime";printf 'other-runtime\n' > "$t53/.zyz-worker/tasks/other/runtime/member"
    t53_check "$t53" "another task runtime is not excluded" changed true
    rm -f "$t53/.zyz-worker/tasks/other/runtime/member";rmdir "$t53/.zyz-worker/tasks/other/runtime" "$t53/.zyz-worker/tasks/other" 2>/dev/null || true
    t53_check "$t53" "removing another task runtime returns to unchanged" unchanged false

    printf 'index-only\n' > "$t53/.git/index"
    t53_check "$t53" "Git index-only bytes do not count as physical output" unchanged false
    elif [ "$t53_publication" = trusted-unavailable ]; then
        skip "T53 public baseline publication is structurally unavailable" "elapsed_ns=$t53_start_elapsed probe=$(tr '\n' ' ' < "$t53/.zyz-worker/tasks/task/runtime/t53-publication.out")"
    else
        fail "T53 public SubagentStart publication precondition is explicit and cannot accept false rc0" "start_rc=$t53_start_rc probe_rc=$t53_publication_rc elapsed_ns=$t53_start_elapsed start_stdout=$(tr '\n' ' ' < "$t53/.zyz-worker/tasks/task/runtime/t53-start.out") start_stderr=$(tr '\n' ' ' < "$t53/.zyz-worker/tasks/task/runtime/t53-start.err") probe=$(tr '\n' ' ' < "$t53/.zyz-worker/tasks/task/runtime/t53-publication.out" 2>/dev/null) probe_stderr=$(tr '\n' ' ' < "$t53/.zyz-worker/tasks/task/runtime/t53-publication.out.err" 2>/dev/null)"
    fi
    rm -rf "$t53"
else
    skip "T53 public physical no-output comparison requires T37 fixed publication path"
fi

# ---------------------------------------------------------------------------
echo
if [ "$SKIPPED" -gt 0 ]; then
    echo "RESULT: $PASSED/$TOTAL checks passed ($SKIPPED skipped)"
else
    echo "RESULT: $PASSED/$TOTAL checks passed"
fi
[ "$FAILED" -eq 0 ]
