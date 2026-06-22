#!/usr/bin/env bash
#
# Test suite for the orchestration-scheduling-task skill.
#
# Implements T1-T7 from
#   .zyz-worker/tasks/orchestration-scheduling-task/design-helpers-tests.md
#   ## §测试计划
#
# Usage:
#   bash scripts/test-orchestration-helpers.sh
#
# Behavior:
#   - Runs all seven test groups to completion (does NOT bail on first failure).
#   - Prints PASS / FAIL / SKIP per check with offending paths on FAIL.
#   - Prints a final summary line:
#       RESULT: <passed>/<total> checks passed  [(<skipped> skipped)]
#   - Exits 0 on success, 1 if any check failed.  SKIP does not count as fail.
#
# Compatibility:
#   - macOS bash 3.2 and Linux bash 4+; no bash 4 features used.
#   - Uses `set -u` and `set -o pipefail` only — never `set -e` so the
#     operator sees the full picture across all checks.
#   - Reference scans use `git ls-files -z` so untracked directories such as
#     docs/superpowers/ and node_modules/ are ignored automatically.

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Locate repo root.  Prefer git, fall back to the script's parent.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
cd "$REPO_ROOT" || {
    echo "FATAL: cannot cd into repo root '$REPO_ROOT'" >&2
    exit 2
}

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
say_header() {
    echo
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
}

pass() {
    TOTAL=$((TOTAL + 1))
    PASSED=$((PASSED + 1))
    echo "  PASS  $1"
}

fail() {
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
    echo "  FAIL  $1"
}

skip() {
    TOTAL=$((TOTAL + 1))
    SKIPPED=$((SKIPPED + 1))
    echo "  SKIP  $1"
}

# check_file_exists <relpath>
check_file_exists() {
    local p="$1"
    if [ -e "$REPO_ROOT/$p" ]; then
        pass "exists: $p"
    else
        fail "missing: $p"
    fi
}

# check_file_executable <relpath>
check_file_executable() {
    local p="$1"
    if [ -x "$REPO_ROOT/$p" ]; then
        pass "executable: $p"
    else
        fail "not executable (chmod +x missing?): $p"
    fi
}

# check_grep <file> <pattern-description> <ERE-pattern>
check_grep() {
    local file="$1"
    local desc="$2"
    local pattern="$3"
    if [ ! -f "$REPO_ROOT/$file" ]; then
        fail "$file missing (cannot grep $desc)"
        return
    fi
    if grep -qE -- "$pattern" "$REPO_ROOT/$file"; then
        pass "$file contains $desc"
    else
        fail "$file is missing $desc (pattern: $pattern)"
    fi
}

# check_grep_fixed <file> <description> <fixed-string>
check_grep_fixed() {
    local file="$1"
    local desc="$2"
    local needle="$3"
    if [ ! -f "$REPO_ROOT/$file" ]; then
        fail "$file missing (cannot grep $desc)"
        return
    fi
    if grep -qF -- "$needle" "$REPO_ROOT/$file"; then
        pass "$file contains $desc"
    else
        fail "$file is missing $desc (needle: '$needle')"
    fi
}

# check_grep_absent <file> <description> <fixed-string>
check_grep_absent() {
    local file="$1"
    local desc="$2"
    local needle="$3"
    if [ ! -f "$REPO_ROOT/$file" ]; then
        fail "$file missing (cannot grep $desc)"
        return
    fi
    if grep -qF -- "$needle" "$REPO_ROOT/$file"; then
        fail "$file unexpectedly contains $desc ('$needle')"
    else
        pass "$file does not contain $desc"
    fi
}

# check_no_affirmative_direct_write <file> <description>
# S-1 correction guard: assert <file> makes NO AFFIRMATIVE, present-tense claim
# that the `confirmed` token (or the orchestrator on it) writes `state:
# completed` DIRECTLY — that is the RETIRED 0.6.5 semantics (the direct write
# is gone; `completed` only ever mirrors a worker `phase=done`).
#
# The subtlety this guard exists for (and why a plain check_grep_absent is
# WRONG here): the CORRECT, landed wording deliberately RESTATES the retired
# phrase in NEGATED / past-tense-retirement form, e.g.
#   - orch-merge.sh:    "The `confirmed` token no longer writes `state: completed` directly — it now relays ..."
#   - CHANGELOG:        "L1 never writes `completed` directly from the `confirmed` token ..."
#   - CHANGELOG Removed:"It directly wrote `state: completed` on the `confirmed` token, which violated ..."
# A fixed-string absence check on "writes state: completed directly" would
# FALSE-POSITIVE on all of these correct lines.  So we detect the direct-write
# CLAIM line (a write verb applied to `state: completed`, with the `directly`
# modifier, on a line that also mentions the `confirmed` token), then EXEMPT any
# such line that carries a negation / retirement marker (no longer | never |
# not | wrote [past-tense retirement narration] | retired | violated |
# instead).  Only an UN-negated, present-tense affirmative direct-write claim
# fails.
#
# This is line-oriented (the claim is always written on one line in these
# files).  ERE, case-insensitive.
check_no_affirmative_direct_write() {
    local file="$1"
    local desc="$2"
    if [ ! -f "$REPO_ROOT/$file" ]; then
        fail "$file missing (cannot scan $desc)"
        return
    fi
    # Direct-write CLAIM signature: a line mentioning the `confirmed` token AND a
    # write verb applied to `state: completed` (backticks optional) AND the
    # `directly` modifier.  Either order of write-verb vs. `directly`.
    local claim_re='confirmed'
    local writes_re='writes?[[:space:]]+`?state: completed`?[[:space:]]+directly|directly[[:space:]]+writes?[[:space:]]+`?state: completed'
    # Negation / retirement exemption markers.
    local exempt_re='no longer|never|[^a-z]not |wrote|retired|violated|instead'
    local claim_lines
    claim_lines="$(grep -inE -- "$writes_re" "$REPO_ROOT/$file" 2>/dev/null \
        | grep -iE -- "$claim_re" || true)"
    if [ -z "$claim_lines" ]; then
        pass "$file has no affirmative confirmed-token direct-write wording ($desc)"
        return
    fi
    # Some line matched the direct-write phrase.  Fail only if at least one such
    # line is NOT negated / retirement-marked.
    local offenders
    offenders="$(printf '%s\n' "$claim_lines" | grep -ivE -- "$exempt_re" || true)"
    if [ -z "$offenders" ]; then
        pass "$file direct-write phrase present only in negated/retirement form ($desc)"
    else
        fail "$file contains an AFFIRMATIVE confirmed-token direct-write claim ($desc) — RETIRED in 0.6.5 (completed must mirror worker phase=done, never be direct-written from the confirmed token).  Offending line(s):
$(printf '%s\n' "$offenders" | sed 's/^/      | /')"
    fi
}

# ---------------------------------------------------------------------------
# Static lists shared across tests
# ---------------------------------------------------------------------------
HELPER_SCRIPTS=(
    "scripts/orch-spawn-worker.sh"
    "scripts/orch-check-worker.sh"
    "scripts/orch-scan-tasks.sh"
    "scripts/orch-heartbeat-daemon.sh"
    "scripts/orch-cleanup-worker.sh"
    "scripts/orch-merge-and-cleanup.sh"
    "scripts/orch-merge.sh"
)

AGENT_FILES=(
    "agents/implementation-agent.md"
    "agents/test-agent.md"
    "agents/review-agent.md"
    "subagents/implementation-agent.md"
    "subagents/test-agent.md"
    "subagents/review-agent.md"
)

# ---------------------------------------------------------------------------
# T1. File / script existence + chmod
# ---------------------------------------------------------------------------
run_T1() {
    say_header "T1  File / script existence + chmod"

    # Skill prompt + main-agent prompt
    check_file_exists "skills/orchestration-scheduling-task/SKILL.md"
    check_file_exists "skills/orchestration-scheduling-task/prompts/main-agent.md"

    # 3 templates
    check_file_exists "skills/orchestration-scheduling-task/templates/master-list-task-entry.md"
    check_file_exists "skills/orchestration-scheduling-task/templates/worker-status.md"
    check_file_exists "skills/orchestration-scheduling-task/templates/question-answer.md"

    # slash command
    check_file_exists "commands/orchestrate-tasks.md"

    # Helper scripts (incl. orch-merge.sh, done/merge decouple): exist +
    # executable.  NOTE: orch-confirm.sh is RETIRED (0.6.5 confirmation/done
    # state-model fix) — the `confirmed` token now relays through L2
    # (intent=relay-confirmation) so the worker writes phase=done, instead of
    # orch-confirm.sh directly writing `state: completed`.  Its retirement is
    # locked by the positive non-existence assertion below.
    local s
    for s in "${HELPER_SCRIPTS[@]}"; do
        check_file_exists "$s"
        if [ -e "$REPO_ROOT/$s" ]; then
            check_file_executable "$s"
        fi
    done

    # orch-confirm.sh must NOT exist (retired in 0.6.5).  Asserting its absence
    # positively means a future re-introduction of the direct-write path turns
    # this check red.
    if [ ! -e "$REPO_ROOT/scripts/orch-confirm.sh" ]; then
        pass "orch-confirm.sh is retired (file absent; confirmed now relays via L2 relay-confirmation)"
    else
        fail "orch-confirm.sh still exists but was retired in 0.6.5 (confirmed must relay via L2 relay-confirmation, not direct-write state: completed): scripts/orch-confirm.sh"
    fi

    # The test script itself
    check_file_exists "scripts/test-orchestration-helpers.sh"
    check_file_executable "scripts/test-orchestration-helpers.sh"

    # ---- T1' (stage C orchestration-source-repo) ------------------------
    # master-list-task-entry.md must declare a `source-repo:` frontmatter
    # field, and have an accompanying comment that mentions both "required"
    # and one of "absolute" / "~/" (the absolute-path constraint per design
    # §A "绝对路径强制" and §D 模板更新).
    local mlte="skills/orchestration-scheduling-task/templates/master-list-task-entry.md"
    check_grep "$mlte" "T1' template declares 'source-repo:' field" \
        '^[[:space:]]*source-repo[[:space:]]*:'
    if [ -f "$REPO_ROOT/$mlte" ]; then
        # Require the word "required" somewhere in the file (comment block
        # or inline annotation), AND either "absolute" or a literal "~/"
        # token nearby — both signal the absolute-path contract.
        if grep -qF "required" "$REPO_ROOT/$mlte" \
            && { grep -qF "absolute" "$REPO_ROOT/$mlte" \
                || grep -qF "~/" "$REPO_ROOT/$mlte"; }; then
            pass "T1' $mlte mentions source-repo 'required' + 'absolute' (or '~/')"
        else
            fail "T1' $mlte does NOT document source-repo as required+absolute (need both 'required' and one of 'absolute'/'~/')"
        fi
    fi

    # ---- T1'' (orchestration-layered-architecture ST-B / ST-A) ----------
    # The layered (L1/L2/L3) orchestration redesign adds:
    #   - a new driver-state template templates/monitor.md (ST-B) with 9
    #     frontmatter keys + 3 body anchors, and
    #   - a new L2 driver subagent definition agents/orch-driver-agent.md
    #     mirrored frontmatter-free in subagents/orch-driver-agent.md (ST-A).
    # Per design §Testing Plan ("脚本层能测的": monitor.md 模板存在+字段齐全;
    # driver agent + 模板路径真实存在).

    # (1) monitor.md template exists.
    local monitor="skills/orchestration-scheduling-task/templates/monitor.md"
    check_file_exists "$monitor"

    # (1a) monitor.md frontmatter declares all 9 driver-state keys.  Each is a
    #      `^<key>:` line inside the file.  We assert them individually so a
    #      missing one names itself on FAIL.
    if [ -f "$REPO_ROOT/$monitor" ]; then
        local mkey
        for mkey in \
            task-id \
            last-driver-iso \
            driver-intent \
            claude-started \
            needs-user \
            needs-user-window \
            needs-attention \
            attention-reason \
            last-summary
        do
            check_grep "$monitor" "T1'' monitor.md frontmatter key '$mkey:'" \
                "^${mkey}:"
        done

        # (1b) monitor.md body anchors: the three section headings the L2
        #      driver writes under.
        check_grep "$monitor" "T1'' monitor.md body anchor '# Driver State'" \
            '^# Driver State([[:space:]]|$)'
        check_grep "$monitor" "T1'' monitor.md body anchor '## Last Action'" \
            '^## Last Action([[:space:]]|$)'
        check_grep "$monitor" "T1'' monitor.md body anchor '## Notes'" \
            '^## Notes([[:space:]]|$)'
    fi

    # (2) L2 driver subagent definition exists in BOTH the agents/ canonical
    #     copy and the subagents/ legacy mirror (same dual layout as the
    #     execute-task subagents).
    local drv_agent="agents/orch-driver-agent.md"
    local drv_sub="subagents/orch-driver-agent.md"
    check_file_exists "$drv_agent"
    check_file_exists "$drv_sub"

    # (2a) The agents/ copy carries Claude Code subagent frontmatter:
    #      `name: orch-driver-agent` and a `tools:` line that includes Bash
    #      (the driver runs `tmux send-keys` / `tmux capture-pane`, so Bash is
    #      load-bearing per design Constraint 3 + the ST-A contract).
    if [ -f "$REPO_ROOT/$drv_agent" ]; then
        check_grep "$drv_agent" "T1'' agents/ frontmatter 'name: orch-driver-agent'" \
            '^name:[[:space:]]*orch-driver-agent[[:space:]]*$'
        check_grep "$drv_agent" "T1'' agents/ frontmatter 'tools:' line includes Bash" \
            '^tools:.*\bBash\b'
    fi

    # (2b) The subagents/ mirror is FRONTMATTER-FREE per the legacy convention
    #      (subagents/implementation-agent.md et al start with a '# ' heading,
    #      NOT a leading '---' YAML fence).  Assert the driver mirror matches:
    #      its first non-empty line is a '# ' heading and it does NOT open with
    #      '---'.  Cross-check against subagents/implementation-agent.md so the
    #      convention itself is pinned, not just the new file.
    local sub_first_drv sub_first_impl
    if [ -f "$REPO_ROOT/$drv_sub" ]; then
        sub_first_drv="$(grep -m1 -vE '^[[:space:]]*$' "$REPO_ROOT/$drv_sub" 2>/dev/null || true)"
        case "$sub_first_drv" in
            '---'|'---'[[:space:]]*)
                fail "T1'' $drv_sub opens with a '---' YAML fence (legacy subagents/ mirror must be frontmatter-free, first line a '# ' heading)" ;;
            '# '*)
                pass "T1'' $drv_sub is frontmatter-free (starts with '# ' heading, no leading '---')" ;;
            *)
                fail "T1'' $drv_sub first non-empty line is not a '# ' heading (got: '$sub_first_drv')" ;;
        esac
    fi
    # Pin the convention against the canonical legacy mirror.
    if [ -f "$REPO_ROOT/subagents/implementation-agent.md" ]; then
        sub_first_impl="$(grep -m1 -vE '^[[:space:]]*$' "$REPO_ROOT/subagents/implementation-agent.md" 2>/dev/null || true)"
        case "$sub_first_impl" in
            '# '*)
                pass "T1'' subagents/implementation-agent.md is frontmatter-free (mirror convention reference)" ;;
            *)
                fail "T1'' subagents/implementation-agent.md unexpectedly not frontmatter-free (got: '$sub_first_impl'); mirror convention reference broken" ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# T2. Reference consistency (uses `git ls-files`)
# ---------------------------------------------------------------------------
run_T2() {
    say_header "T2  Reference consistency"

    # (a) commands/orchestrate-tasks.md @${CLAUDE_PLUGIN_ROOT}/... refs must
    #     resolve to real files in the repo.
    local cmd_file="commands/orchestrate-tasks.md"
    if [ ! -f "$REPO_ROOT/$cmd_file" ]; then
        fail "T2(a) $cmd_file missing (cannot verify @CLAUDE_PLUGIN_ROOT refs)"
    else
        # Extract every '@${CLAUDE_PLUGIN_ROOT}/<relative-path>' token.
        # The path token ends at first whitespace or end of line; markdown
        # backticks, parens etc. are tolerated by stripping trailing
        # punctuation in the trim step.
        local refs ref relpath bad
        # shellcheck disable=SC2016
        refs="$(grep -oE '@\$\{CLAUDE_PLUGIN_ROOT\}/[^[:space:]`)<>]+' "$REPO_ROOT/$cmd_file" || true)"

        if [ -z "$refs" ]; then
            fail "T2(a) $cmd_file has no @\${CLAUDE_PLUGIN_ROOT}/... references at all (expected several)"
        else
            bad=0
            while IFS= read -r ref; do
                [ -z "$ref" ] && continue
                # Strip leading '@${CLAUDE_PLUGIN_ROOT}/'
                relpath="${ref#@\$\{CLAUDE_PLUGIN_ROOT\}/}"
                # Strip trailing punctuation that markdown commonly attaches
                relpath="${relpath%%[\`),.;:]}"
                if [ -e "$REPO_ROOT/$relpath" ]; then
                    pass "T2(a) $cmd_file ref resolves: $relpath"
                else
                    fail "T2(a) $cmd_file ref does NOT resolve: $relpath"
                    bad=$((bad + 1))
                fi
            done <<EOF
$refs
EOF
            if [ "$bad" -eq 0 ]; then
                : # individual PASS lines already emitted
            fi
        fi
    fi

    # (b) None of the 6 agent files contains a markdown link whose target
    #     points at .zyz-worker/tasks/orchestration-scheduling-task/ (per
    #     design F13: avoid brittle outlinks that break after task-folder
    #     cleanup).  We only forbid the URL fragment inside a markdown
    #     link form  (...)(...)  — bare-string mentions in prose are
    #     tolerated, since they cannot "break" a reader's navigation.
    #
    #     Pattern: ](...zyz-worker/tasks/orchestration-scheduling-task/...)
    #     Use ERE; escape parens.
    local af violators
    for af in "${AGENT_FILES[@]}"; do
        if [ ! -f "$REPO_ROOT/$af" ]; then
            fail "T2(b) $af missing (cannot scan for forbidden outlink)"
            continue
        fi
        violators="$(grep -nE '\]\([^)]*\.zyz-worker/tasks/orchestration-scheduling-task/' \
            "$REPO_ROOT/$af" 2>/dev/null || true)"
        if [ -z "$violators" ]; then
            pass "T2(b) $af has no markdown link to .zyz-worker/tasks/orchestration-scheduling-task/ (F13)"
        else
            fail "T2(b) $af contains forbidden markdown outlink (F13):
$(printf '%s\n' "$violators" | sed 's/^/      | /')"
        fi
    done

    # (c) layered-architecture reference consistency: main-agent.md and SKILL.md
    #     reference the new L2 driver agent (`orch-driver-agent`) and the new
    #     driver-state template path (`templates/monitor.md`).  Assert that
    #     EVERY referenced path actually exists on disk (the same posture as
    #     T2(a)'s @CLAUDE_PLUGIN_ROOT resolution — a referenced artefact that
    #     does not exist would break the L1 dispatch contract).  Per design
    #     §Testing Plan ("T2 引用一致性: main-agent.md / SKILL.md 引用的新 driver
    #     agent + 模板路径真实存在").
    local main_md="skills/orchestration-scheduling-task/prompts/main-agent.md"
    local skill_md="skills/orchestration-scheduling-task/SKILL.md"
    # The driver agent is referenced by the bare name `orch-driver-agent`; it
    # resolves to the canonical agents/ copy (mirrored in subagents/).
    local driver_agent_path="agents/orch-driver-agent.md"
    local driver_sub_path="subagents/orch-driver-agent.md"
    local monitor_tpl_path="skills/orchestration-scheduling-task/templates/monitor.md"

    local rc_file
    for rc_file in "$main_md" "$skill_md"; do
        if [ ! -f "$REPO_ROOT/$rc_file" ]; then
            fail "T2(c) $rc_file missing (cannot verify driver-agent / monitor.md refs)"
            continue
        fi
        # Must reference the driver agent by name.
        if grep -qF "orch-driver-agent" "$REPO_ROOT/$rc_file"; then
            pass "T2(c) $rc_file references 'orch-driver-agent'"
        else
            fail "T2(c) $rc_file does NOT reference 'orch-driver-agent'"
        fi
        # Must reference the monitor.md driver-state file.
        if grep -qF "monitor.md" "$REPO_ROOT/$rc_file"; then
            pass "T2(c) $rc_file references 'monitor.md'"
        else
            fail "T2(c) $rc_file does NOT reference 'monitor.md'"
        fi
    done

    # And the referenced artefacts must actually exist on disk.
    local rc_path
    for rc_path in "$driver_agent_path" "$driver_sub_path" "$monitor_tpl_path"; do
        if [ -e "$REPO_ROOT/$rc_path" ]; then
            pass "T2(c) referenced path resolves: $rc_path"
        else
            fail "T2(c) referenced path does NOT resolve: $rc_path (driver-agent / monitor.md ref broken)"
        fi
    done
}

# ---------------------------------------------------------------------------
# T3. Prompt key-fields presence
# ---------------------------------------------------------------------------
run_T3() {
    say_header "T3  Prompt key-fields presence"

    # SKILL.md
    local skill="skills/orchestration-scheduling-task/SKILL.md"
    check_grep_fixed "$skill" "'Orchestrated Mode'"       "Orchestrated Mode"
    check_grep_fixed "$skill" "'ZYZ_WORKER_STATUS_FILE'"  "ZYZ_WORKER_STATUS_FILE"
    check_grep_fixed "$skill" "'flock'"                   "flock"
    check_grep_fixed "$skill" "'task/<task-id>'"          "task/<task-id>"

    # main-agent.md
    local main="skills/orchestration-scheduling-task/prompts/main-agent.md"
    check_grep_fixed "$main" "'Cadence Policy'" "Cadence Policy"
    check_grep_fixed "$main" "'/loop'"          "/loop"
    check_grep_fixed "$main" "'ScheduleWakeup'" "ScheduleWakeup"

    # ---- T3'' (orch-auto-timer: default auto-timer + ZYZ_ORCH_ONCE opt-out) -
    # Per design §Testing Plan (orch-auto-timer): main-agent.md must carry the
    # new "default auto-timer self-scheduling + single-shot opt-out" semantics
    # as positive literal anchors.  These sit beside the existing /loop +
    # ScheduleWakeup anchors above; all of those are kept unchanged.
    check_grep_fixed "$main" "ZYZ_ORCH_ONCE opt-out env var" "ZYZ_ORCH_ONCE"
    check_grep_fixed "$main" "auto-timer mode anchor"        "auto-timer"

    # 7 cadence anchor strings
    local anchor
    for anchor in \
        "imminent-completion" \
        "stale" \
        "waiting-user" \
        "in-progress-fresh" \
        "not-analyzed" \
        "all-ready-idle" \
        "unknown-investigate"
    do
        check_grep_fixed "$main" "cadence anchor '$anchor'" "$anchor"
    done

    # execute-task SKILL.md
    local etsk="skills/execute-task/SKILL.md"
    check_grep "$etsk" "'## Orchestrated Mode' heading" '^## Orchestrated Mode([[:space:]]|$)'

    # ---- absorbing-state contract: done is absorbing, awaiting-confirmation
    #      is reversible (0.6.5 confirmation/done state-model fix, design F5) ---
    # PRIOR STATE OF THIS BLOCK (now retired): it asserted that execute-task
    # SKILL.md merely *contained* the two independent fixed-strings
    # `awaiting-confirmation` AND `absorbing`.  Both words still appear after the
    # 0.6.5 fix (awaiting-confirmation is still a phase; done is now the
    # absorbing one), so that pair PASSED VACUOUSLY and its description lied —
    # it claimed awaiting-confirmation was the absorbing terminal.
    #
    # The 0.6.5 contract INVERTS the rule: `awaiting-confirmation` is reversible
    # (a review of an awaiting-confirmation worker that asks for changes rolls it
    # back to implementation); the SOLE non-reversible / absorbing terminal is
    # `done`, written only after explicit user confirmation.  These three
    # discriminating anchors are present in the NEW prose and ABSENT from the OLD
    # (which said the non-reversible phase was `awaiting-confirmation`), so each
    # would FAIL if the old awaiting-confirmation-absorbing wording were still in
    # place — i.e. they are non-vacuous.
    #
    # (1) The non-reversible phase is `done` (NOT awaiting-confirmation).
    check_grep "$etsk" "absorbing rule: the non-reversible phase is \`done\`" \
        'non-reversible phase is `done`'
    # (2) `done` is tied to the word "absorbing" (the new roll-back-rule heading
    #     reads "phase may roll back, except \`done\` which is absorbing").
    check_grep_fixed "$etsk" "absorbing rule: \`done\` is the absorbing terminal" \
        'except `done` which is absorbing'
    # (3) `awaiting-confirmation` is explicitly REVERSIBLE.  ERE: from the
    #     awaiting-confirmation token to "remains reversible" within one
    #     sentence (no intervening period), so a future edit that re-froze
    #     awaiting-confirmation as absorbing would no longer match.
    check_grep "$etsk" "absorbing rule: \`awaiting-confirmation\` remains reversible" \
        'awaiting-confirmation[^.]*remains reversible'

    # ---- delivery test-gate (registration-style hard gate) --------------
    # Per .zyz-worker/tasks/zyz-phase-awaiting-confirmation/design-test-gate.md
    # §4: the Deliver step gains a pre-delivery gate that requires EVERY
    # required test category (unit / e2e / regression; plus pressure when
    # `## Risks` demands it) to be registered ran/skipped before delivery.
    # The literal string `every required category` is the contract anchor
    # (RC3) — it is unique to the §4 gate sentence, so deleting the gate
    # turns this check red.
    check_grep_fixed "$etsk" "§4 delivery test-gate anchor 'every required category'" \
        "every required category"

    # ---- task-status template per-category Final Aggregate Testing -------
    # Per design-test-gate.md §模板结构化: `## Final Aggregate Testing` in the
    # task-status template becomes a per-category checklist with one line per
    # category using the `(ran: <result> | skipped: <reason>)` grammar.  E2E
    # and Regression are the two categories the user specifically worried get
    # silently skipped, so we anchor on those two labels at minimum.
    local etsk_tpl="skills/execute-task/templates/task-status.md"
    check_grep_fixed "$etsk_tpl" "Final Aggregate Testing has per-category E2E line" \
        "- E2E:"
    check_grep_fixed "$etsk_tpl" "Final Aggregate Testing has per-category Regression line" \
        "- Regression:"

    # Each of the 6 agent files: heading + 'wait-state'
    local af
    for af in "${AGENT_FILES[@]}"; do
        check_grep "$af" "'## Orchestrated Mode Hook' heading" \
            '^## Orchestrated Mode Hook([[:space:]]|$)'
        check_grep_fixed "$af" "'wait-state' field mention" "wait-state"
    done

    # ---- T3' (stage C orchestration-source-repo) ------------------------
    # Per design §C / §E:
    #   - SKILL.md mentions `source-repo`
    #   - main-agent.md mentions `source-repo` AND mentions cwd independence
    #     (one of "cwd" / "any cwd" / "any directory" — i.e. the Hard Limits
    #     prose at §C.2)
    #   - commands/orchestrate-tasks.md mentions `source-repo`
    check_grep_fixed "$skill" "T3' SKILL.md mentions 'source-repo'" "source-repo"
    check_grep_fixed "$main"  "T3' main-agent.md mentions 'source-repo'" "source-repo"
    if [ -f "$REPO_ROOT/$main" ]; then
        # cwd independence prose — accept any of the three common phrasings.
        if grep -qF "any cwd" "$REPO_ROOT/$main" \
            || grep -qF "any directory" "$REPO_ROOT/$main" \
            || grep -qE "\\bcwd\\b" "$REPO_ROOT/$main"; then
            pass "T3' $main mentions cwd independence (any cwd / any directory / cwd)"
        else
            fail "T3' $main does NOT mention cwd independence (need one of 'any cwd', 'any directory', or 'cwd')"
        fi
    fi
    local cmd_orch="commands/orchestrate-tasks.md"
    check_grep_fixed "$cmd_orch" "T3' $cmd_orch mentions 'source-repo'" "source-repo"

    # ---- T3'' cross-file anchor (orch-auto-timer) -----------------------
    # Per design §Testing Plan (orch-auto-timer, F5): `ZYZ_ORCH_ONCE` must
    # also surface in commands/orchestrate-tasks.md as the cross-file anchor
    # for the unified "default auto-timer polling + single-shot opt-out"
    # semantics (main-agent.md already carries it via the T3'' check above).
    check_grep_fixed "$cmd_orch" "T3'' $cmd_orch mentions 'ZYZ_ORCH_ONCE'" "ZYZ_ORCH_ONCE"
    check_grep_fixed "CLAUDE.md" "T3'' CLAUDE.md mentions 'ZYZ_ORCH_ONCE'" "ZYZ_ORCH_ONCE"

    # ---- T3''' (done/merge decouple) static anchors ---------------------
    # Per .zyz-worker/tasks/zyz-phase-awaiting-confirmation/
    # design-done-merge-decouple.md: `state: completed` is decoupled from
    # merge, and three master-entry tokens (`confirmed`, `merge`/`merge: <base>`,
    # legacy `approved`) route deterministically.  These doc-greps pin the new
    # wording the implementation must land; they are the PRIMARY multi-token
    # routing-precedence assertion (the design chose the doc-grep form so it
    # does not depend on a full git fixture — §测试 "主用文档 grep 形").
    #
    # (4) main-agent.md gate-step documents the `approved` short-circuit: when
    #     `approved` is present, any coexisting `confirmed`/`merge`/
    #     `cleanup-approved` tokens are IGNORED that tick (RC3: "ignored", not
    #     "absorbed as a subset").  `short-circuit` is the stable anchor phrase.
    #     ($main = orch prompts/main-agent.md, defined above in this function.)
    check_grep_fixed "$main" "T3''' gate approved short-circuit documented" \
        "short-circuit"

    # (5a) RC7 backtick-quoted token anchors in the master-entry template.  The
    #      backticks are part of the matched needle/pattern, so the match can
    #      NEVER land on the bare substring `confirmed` inside
    #      `awaiting-confirmation` (which has no surrounding backticks).  The
    #      template comment documents the `confirmed` and `merge` tokens with
    #      these literal backtick spans.
    local mlte_decouple="skills/orchestration-scheduling-task/templates/master-list-task-entry.md"
    check_grep_fixed "$mlte_decouple" "T3''' template documents \`confirmed\` token (backtick-quoted)" \
        '`confirmed`'
    # The design's §令牌词表 allows the merge token to be documented as the bare
    # shorthand `merge` OR the parameterized `merge:` (i.e. `merge: <base>`) —
    # RC7 explicitly accepts either backtick-quoted spelling.  Match either so
    # the anchor is robust to whichever form the template comment lands on,
    # while the backtick prefix still rules out the awaiting-confirmation
    # substring trap.  (ERE: backtick is a literal; alternation via `|`.)
    check_grep "$mlte_decouple" "T3''' template documents \`merge\` or \`merge:\` token (backtick-quoted)" \
        '`merge`|`merge:`'

    # (5b) orch SKILL.md `completed` row/sentence carries the unique anchor word
    #      `decoupled` (done is now decoupled from merge).  This word does not
    #      exist anywhere in the tree before this change, so this check
    #      specifically asserts the new completed-state wording landed.
    #      ($skill = orch SKILL.md, defined above in this function.)
    check_grep_fixed "$skill" "T3''' SKILL.md completed-state 'decoupled' anchor" \
        "decoupled"

    # ---- T3'''' (0.6.5 confirmation/done state-model fix) ----------------
    # The 0.6.5 fix re-introduces worker phase `done` as the sole absorbing
    # terminal, makes `awaiting-confirmation` reversible, adds a new L1 state
    # `awaiting-user-confirmation`, and routes the `confirmed` token through an
    # L2 driver intent `relay-confirmation` (retiring orch-confirm.sh's
    # direct-write).  These doc-grep anchors pin the new contract wording the
    # implementation must land; the absorbing-rule anchors themselves live in
    # the execute-task SKILL.md block above (design F5).

    # (B1) Worker phase enum gains `done`.  Two mirror sites carry the 7-value
    #      enum string: the orchestration SKILL.md "Worker status frontmatter"
    #      excerpt and the worker-status.md template comment.  The execute-task
    #      SKILL.md carries the canonical phase line too.  We anchor on the
    #      `awaiting-confirmation | done | error` tail (fixed string) so the
    #      check FAILS on the OLD `awaiting-confirmation | error` enum (no
    #      `done`) and PASSES only once `done` is spliced back in.
    local worker_status_tpl="skills/orchestration-scheduling-task/templates/worker-status.md"
    check_grep_fixed "$etsk" "B1 execute-task SKILL.md phase enum has '| done | error'" \
        "awaiting-confirmation | done | error"
    check_grep_fixed "$skill" "B1 orch SKILL.md worker-status excerpt phase enum has '| done | error'" \
        "awaiting-confirmation | done | error"
    check_grep_fixed "$worker_status_tpl" "B1 worker-status.md template phase enum has '| done | error'" \
        "awaiting-confirmation | done | error"

    # (B3) L1 state enum gains `awaiting-user-confirmation`.  The orchestration
    #      SKILL.md state enum (and its state-machine prose) must list it.
    #      `awaiting-user-confirmation` does not exist anywhere in the tree
    #      before this change, so a bare presence check is already
    #      discriminating.
    check_grep_fixed "$skill" "B3 orch SKILL.md state enum has 'awaiting-user-confirmation'" \
        "awaiting-user-confirmation"

    # (B4) Projection asserts (doc-grep on main-agent.md; design S2: T5 can only
    #      verify the helper PASSES the phase value through, not the L1
    #      projection — the projection rule itself is doc-only).  The main-agent
    #      project/poll step must map:
    #        phase=awaiting-confirmation -> state: awaiting-user-confirmation
    #        phase=done                  -> state: completed
    #      ($main = orch prompts/main-agent.md, defined above in this function.)
    #
    #      (a) awaiting-user-confirmation appears in the projection bullet
    #          (fixed string; absent from the OLD "keep state: in-progress"
    #          projection).
    check_grep_fixed "$main" "B4 main-agent.md projects awaiting-confirmation -> awaiting-user-confirmation" \
        "awaiting-user-confirmation"
    #      (b) phase=done is tied to completed in the projection.  ERE from the
    #          `phase=done` token to `completed` within one bullet (no
    #          intervening period), so it FAILS if the done->completed row is
    #          missing.
    check_grep "$main" "B4 main-agent.md projects phase=done -> completed" \
        'phase=done[^.]*completed'

    # (B5) scan accepts awaiting-user-confirmation as a legal state (not coerced
    #      to not-analyzed).  orch-scan-tasks.sh's legal-state case branch must
    #      include the new value.  doc-grep on the script source (the legal
    #      values are an inline `case` alternation), fixed string.
    check_grep_fixed "scripts/orch-scan-tasks.sh" \
        "B5 orch-scan-tasks.sh legal-state case accepts 'awaiting-user-confirmation'" \
        "awaiting-user-confirmation"

    # (B6) gate routes `confirmed` to L2 relay-confirmation (NOT orch-confirm.sh).
    #      The 0.6.5 gate step replaces the direct `state: completed` write with
    #      an L2 dispatch (intent=relay-confirmation) that send-keys a human-
    #      readable confirmation into the worker pane; the worker then writes
    #      phase=done and L1 mirrors completed on the next poll.
    #      (a) the gate must mention relay-confirmation (fixed string; absent
    #          from the OLD gate that called orch-confirm.sh).
    check_grep_fixed "$main" "B6 main-agent.md gate routes confirmed via 'relay-confirmation'" \
        "relay-confirmation"
    #      (b) the gate must NOT call orch-confirm.sh anymore (retired path).
    check_grep_absent "$main" "B6 main-agent.md gate no longer calls 'orch-confirm.sh'" \
        "orch-confirm.sh"
    #      (c) F1 idempotency: relay is dispatched at most once per
    #          confirmation, de-duped by reading the worker's monitor.md
    #          `driver-intent` record (an existing relay-confirmation record
    #          means do-not-resend).  We anchor the F1 re-dispatch guard on TWO
    #          discriminating facts a non-idempotent (every-tick re-send) gate
    #          would lack:
    #            - the "at most once" idempotency phrase (ERE, case-insensitive
    #              via char classes so it matches either "AT MOST ONCE" or
    #              "at most once" — the design does not pin the casing); and
    #            - the gate reads `driver-intent` from monitor.md for the relay
    #              de-dup (the concrete de-dup mechanism the design F1 names; the
    #              old poll step read only claude-started/needs-* fields, never
    #              driver-intent, so this is non-vacuous).
    check_grep "$main" "B6 main-agent.md gate relay idempotency 'at most once' (any case)" \
        '[Aa][Tt] [Mm][Oo][Ss][Tt] [Oo][Nn][Cc][Ee]'
    check_grep_fixed "$main" "B6 main-agent.md gate reads monitor.md 'driver-intent' for relay de-dup" \
        "driver-intent"

    # (B9) monitor.md template driver-intent enum gains relay-confirmation.
    #      The persisted-schema enum comment in the template must list all three
    #      intents.  We anchor on the bare value (fixed string; absent from the
    #      OLD `first-dispatch | intervene` enum).
    local monitor_tpl="skills/orchestration-scheduling-task/templates/monitor.md"
    check_grep_fixed "$monitor_tpl" "B9 monitor.md template driver-intent enum has 'relay-confirmation'" \
        "relay-confirmation"

    # ---- S-1 (0.6.5): confirmed-token retired-wording absent ------------
    # The 0.6.5 fix RETIRES scripts/orch-confirm.sh entirely.  B7 / T1 / T11a
    # already lock the SCRIPT FILE's absence and B6 locks that main-agent.md's
    # gate no longer calls it.  But the design F3 / acceptance-criteria
    # (design.md L196: "orch-confirm.sh 已 retire（含 README/orch-merge.sh 注释/
    # exit 处理 bullet 全部清除）") require the retirement to be COMPLETE: the
    # satellite files that USED to reference orch-confirm.sh's direct
    # `state: completed` write must have that wording purged too, or the
    # retirement is half-done and a reader is left a stale pointer to a deleted
    # script.  This guard pins the F3 purge so it cannot silently regress —
    # mirroring the design's closing whole-repo grep on `orch-confirm`
    # (design.md L203).
    #
    # Each file must NOT contain the literal `orch-confirm` anywhere:
    #   - README.md           — the scripts/ directory tree (design L211) must
    #                           no longer list orch-confirm.sh.
    #   - scripts/orch-merge.sh — its header comment (design L10) used to point
    #                           at orch-confirm.sh; it now describes the relay
    #                           path instead and must not name the retired
    #                           script.
    #   - scripts/orch-merge-and-cleanup.sh — defensive third site (design L168
    #                           flags its header as a candidate); the legacy
    #                           `approved` path is unchanged, but it must not
    #                           reference the retired orch-confirm.sh either.
    # `check_grep_absent` is fixed-string (`grep -qF`), so the `orch-confirm`
    # substring also catches `orch-confirm.sh` / `scripts/orch-confirm.sh`.
    local s1_file
    for s1_file in \
        "README.md" \
        "scripts/orch-merge.sh" \
        "scripts/orch-merge-and-cleanup.sh"
    do
        check_grep_absent "$s1_file" \
            "S-1 $s1_file has no retired 'orch-confirm' wording (F3 purge)" \
            "orch-confirm"
    done

    # ---- S-1 correction: confirmed-token DIRECT-WRITE wording absent ----
    # Purging the orch-confirm.sh NAME (above) is not enough: a file could drop
    # the script name yet still carry stale prose asserting that the `confirmed`
    # token writes `state: completed` DIRECTLY — the retired semantics.  The
    # 0.6.5 invariant is that `completed` ALWAYS mirrors a worker `phase=done`
    # (for the confirmed/relay channel); no doc may make an affirmative,
    # present-tense direct-write claim.  check_no_affirmative_direct_write
    # detects that claim while EXEMPTING the deliberately-restated negated /
    # past-tense-retirement forms the correct wording uses ("no longer writes
    # ... directly", "never writes ... directly", "directly wrote ... violated")
    # — see the helper's header for why a plain check_grep_absent would
    # false-positive on the correct landed wording.
    #
    # Cover the gate doc (the primary site that USED to direct-write), the
    # master-entry template `confirmed` token comment, and the three satellite
    # files already guarded above for the script name.
    local s1_dw_file
    for s1_dw_file in \
        "skills/orchestration-scheduling-task/prompts/main-agent.md" \
        "skills/orchestration-scheduling-task/templates/master-list-task-entry.md" \
        "README.md" \
        "scripts/orch-merge.sh" \
        "scripts/orch-merge-and-cleanup.sh"
    do
        check_no_affirmative_direct_write "$s1_dw_file" \
            "S-1 confirmed-token direct-write claim retired in $s1_dw_file"
    done
}

# ---------------------------------------------------------------------------
# T4. Helper bash unit tests
#
# For each of the 6 scripts:
#   (a) no args / invalid task-id  -> exit 2
#   (b) missing dependency on PATH -> exit 3
#
# Per design §E: heartbeat-daemon takes <heartbeat-file> <interval-sec>;
# scan-tasks takes <list-dir>; the rest take <task-id> [<list-dir> ...].
# An "invalid task-id like 'bad space'" is the canonical T4(a) input for
# the five scripts that accept a task-id; for orch-scan-tasks.sh we use
# zero args (it does not take a task-id).
# ---------------------------------------------------------------------------

# run_and_get_exit <expected-exit-or-empty> <description> -- <cmd...>
# Always increments TOTAL+PASS/FAIL.  If the script under test does not
# exist, we record a FAIL (not skip) — T1 already covered existence, but
# T4 must not silently pass when scripts are missing.
run_and_check_exit() {
    local expected="$1"
    local desc="$2"
    shift 2
    # Discard stdin to avoid blocking on any read-from-stdin in the script.
    local rc
    "$@" </dev/null >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq "$expected" ]; then
        pass "$desc (exit=$rc as expected)"
    else
        fail "$desc (got exit=$rc, expected $expected; cmd: $*)"
    fi
}

# run_and_check_exit_stderr_regex <expected-exit> <expected-stderr-regex> <desc> -- <cmd...>
# Asserts BOTH exit code AND that stderr matches the given ERE pattern.
# Used by T4' negative spawn cases (design §F.3, §"exit 5 复用" table) to
# pin down the precise diagnostic prefix in stderr.
#
# - stdout is discarded; stderr is captured to a tmpfile and grep -qE'd.
# - On mismatch, prints both observed exit code and (truncated) stderr to
#   aid debugging.
# - One TOTAL increment per call (either pass or fail), not two — the
#   exit + stderr assertions form a single logical check per the design.
run_and_check_exit_stderr_regex() {
    local expected_exit="$1"
    local expected_re="$2"
    local desc="$3"
    shift 3
    local err_tmp rc
    err_tmp="$(mktemp "${TMPDIR:-/tmp}/zyz-orch-stderr.XXXXXX")"
    # Discard stdin and stdout; capture stderr to err_tmp.
    "$@" </dev/null >/dev/null 2>"$err_tmp"
    rc=$?
    local err_content
    err_content="$(cat "$err_tmp" 2>/dev/null || true)"
    rm -f "$err_tmp"
    if [ "$rc" -ne "$expected_exit" ]; then
        fail "$desc (got exit=$rc, expected $expected_exit; cmd: $*; stderr: $(printf '%s' "$err_content" | head -c 400))"
        return
    fi
    if printf '%s\n' "$err_content" | grep -qE -- "$expected_re"; then
        pass "$desc (exit=$rc and stderr matches /$expected_re/)"
    else
        fail "$desc (exit=$rc OK but stderr did NOT match /$expected_re/; stderr was:
$(printf '%s\n' "$err_content" | sed 's/^/      | /'))"
    fi
}

# t4_invalid_taskid <script-path>
# Invokes with an invalid task-id 'bad space' (positional 1) and a dummy
# list-dir.  Expects exit 2.  Skips when the script is missing.
t4_invalid_taskid() {
    local script="$1"
    if [ ! -x "$REPO_ROOT/$script" ]; then
        skip "T4 $script invalid-taskid (script missing or not executable)"
        return
    fi
    # bash <script> 'bad space' <dummy-list-dir>
    run_and_check_exit 2 "T4 $script with invalid task-id 'bad space' -> exit 2" \
        bash "$REPO_ROOT/$script" "bad space" "/tmp/zyz-orch-t4-dummy-list"
}

# t4_no_args <script-path>
# Invokes with no args.  Expects exit 2.
t4_no_args() {
    local script="$1"
    if [ ! -x "$REPO_ROOT/$script" ]; then
        skip "T4 $script no-args (script missing or not executable)"
        return
    fi
    run_and_check_exit 2 "T4 $script with no args -> exit 2" \
        bash "$REPO_ROOT/$script"
}

# t4_missing_dep <script-path> <valid-args...>
# Strips tmux/git/gh from PATH using `env -i PATH=/usr/bin:/bin` and
# expects exit 3.  Scripts that only take <list-dir> have valid args
# different from scripts that take <task-id>.
#
# We use `env -i PATH=/usr/bin:/bin` to provide a minimal PATH that
# (on macOS and Linux) does not contain tmux, gh, or git in most setups.
# To be safe we also explicitly strip any tmux-providing dir.
#
# NOTE: heartbeat-daemon does not require tmux/git, only bash + date +
# sleep — its missing-dep check is meaningless, so we mark it SKIP.
t4_missing_dep() {
    local script="$1"
    shift
    if [ ! -x "$REPO_ROOT/$script" ]; then
        skip "T4 $script missing-dep (script missing or not executable)"
        return
    fi
    # Build a PATH stripped of common tmux/git locations.  We intentionally
    # use a minimal PATH so the script's dependency check fires.  We DO
    # include /usr/bin and /bin so basic utilities (env, bash, date, mkdir,
    # sleep, basename, dirname) still work — the design says scripts must
    # explicitly check for tmux/git/gh, not for coreutils.
    local stripped_path
    stripped_path="$(echo "$PATH" | tr ':' '\n' \
        | grep -vE '/(tmux|git|gh|homebrew|brew)' \
        | tr '\n' ':')"
    # Strip trailing colon
    stripped_path="${stripped_path%:}"
    # Ensure at least /usr/bin and /bin are present
    case ":$stripped_path:" in
        *:/usr/bin:*) : ;;
        *) stripped_path="/usr/bin:$stripped_path" ;;
    esac
    case ":$stripped_path:" in
        *:/bin:*) : ;;
        *) stripped_path="/bin:$stripped_path" ;;
    esac

    # If after stripping, `tmux` is still found (unusual location), we
    # cannot reliably test missing-dep; mark SKIP.
    if PATH="$stripped_path" command -v tmux >/dev/null 2>&1; then
        skip "T4 $script missing-dep (cannot strip tmux from PATH on this host)"
        return
    fi

    local rc
    PATH="$stripped_path" bash "$REPO_ROOT/$script" "$@" </dev/null >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 3 ]; then
        pass "T4 $script with stripped PATH (no tmux) -> exit 3"
    else
        fail "T4 $script with stripped PATH (no tmux) got exit=$rc, expected 3"
    fi
}

run_T4() {
    say_header "T4  Helper bash unit tests"

    # ---- orch-scan-tasks.sh : takes <list-dir> only ----
    t4_no_args "scripts/orch-scan-tasks.sh"
    # No task-id to be invalid against; instead test invalid (missing) list-dir
    # which §E.1 says should exit 4.  We still cover the no-args case above.
    # missing-dep: scan-tasks does not strictly require tmux per §E.1 — it
    # only walks files.  But the design §E top-of-section rule says every
    # script must `command -v tmux git` at entry.  So we still expect 3.
    t4_missing_dep "scripts/orch-scan-tasks.sh" "/tmp/zyz-orch-t4-dummy-list"

    # ---- orch-spawn-worker.sh : <task-id> <list-dir> (2 args; spawn no
    #      longer has --auto-start — it only builds the container, and starting
    #      claude is the exclusive job of the L2 orch-driver-agent) ----
    t4_no_args        "scripts/orch-spawn-worker.sh"
    t4_invalid_taskid "scripts/orch-spawn-worker.sh"

    # ---- T4'' spawn no longer accepts --auto-start (layered-architecture
    #      ST-C) -------------------------------------------------------------
    # The layered redesign REMOVED spawn's --auto-start flag entirely: spawn
    # now takes EXACTLY 2 args and starting claude is the exclusive job of the
    # L2 orch-driver-agent.  A 3rd positional arg (the old `--auto-start`) must
    # be rejected as an argument error (exit 2).  This fires BEFORE any heavy
    # work (the `[ "$#" -ne 2 ]` guard is the first thing spawn checks), so it
    # exits 2 regardless of fixture validity — no fixture needed.  We use a
    # valid task-id charset for the first arg so the rejection is the arg-COUNT
    # guard, not the task-id charset guard.
    if [ -x "$REPO_ROOT/scripts/orch-spawn-worker.sh" ]; then
        run_and_check_exit 2 \
            "T4'' spawn with a 3rd arg '--auto-start' -> exit 2 (arg error; flag removed)" \
            bash "$REPO_ROOT/scripts/orch-spawn-worker.sh" foo "/tmp/zyz-orch-t4-dummy-list" --auto-start
        # The spawn usage/help string + its stdout contract must NOT mention
        # auto-start anywhere (no stale `--auto-start` flag, no `auto-start=`
        # stdout line).  Scan the whole script source for the substring.
        check_grep_absent "scripts/orch-spawn-worker.sh" \
            "T4'' spawn source has no 'auto-start' mention (flag fully removed)" \
            "auto-start"
        # The slash-command prose must ALSO not advertise the removed flag.
        # An aggregate review found commands/orchestrate-tasks.md had been
        # documenting a stale `--auto-start` flag long after spawn dropped it;
        # the spawn-source absence check above never guarded the command file,
        # so the stale reference survived a green suite.  Guard it here with the
        # same helper + message style so it cannot regress.
        check_grep_absent "commands/orchestrate-tasks.md" \
            "T4'' command file has no 'auto-start' mention (flag fully removed)" \
            "auto-start"
    else
        skip "T4'' spawn with a 3rd arg '--auto-start' -> exit 2 (spawn script missing or not executable)"
        skip "T4'' spawn source has no 'auto-start' mention (spawn script missing)"
        skip "T4'' command file has no 'auto-start' mention (spawn script missing)"
    fi

    # Missing-dep for spawn-worker requires a valid list-dir + master entry +
    # valid source-repo, because stage C orchestration-source-repo §B
    # reordered the exit-code precedence:
    #     argv(2) -> master-entry-missing(4) -> source-repo-invalid(5)
    #               -> tmux/git-missing(3) -> rest
    # So the legacy `t4_missing_dep` with a non-existent list-dir now exits 4
    # instead of 3.  We build a minimal valid fixture so the tmux-strip path
    # actually reaches the dep check.
    t4_spawn_missing_dep() {
        local script="scripts/orch-spawn-worker.sh"
        if [ ! -x "$REPO_ROOT/$script" ]; then
            skip "T4 $script missing-dep (script missing or not executable)"
            return
        fi
        if ! command -v git >/dev/null 2>&1; then
            skip "T4 $script missing-dep (git not available; cannot build source-repo fixture)"
            return
        fi
        local fixture_root
        fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t4-spawn-dep.XXXXXX")"
        local fixture_list="$fixture_root/list"
        local fixture_repo="$fixture_root/repo"
        mkdir -p "$fixture_list/tasks" "$fixture_repo"
        (
            cd "$fixture_repo" || exit 1
            git init -q . >/dev/null 2>&1
            git config user.email "t4@example.com"
            git config user.name "T4 Test"
            git checkout -q -b main 2>/dev/null || git checkout -q main
            echo "T4 spawn-dep fixture" >README.md
            git add README.md
            git commit -q -m "initial"
        ) || {
            skip "T4 $script missing-dep (git init in fixture failed)"
            rm -rf "$fixture_root"
            return
        }
        {
            echo "---"
            echo "task-id: foo"
            echo "project: t4-mock"
            echo "source-repo: $fixture_repo"
            echo "state: ready"
            echo "priority: normal"
            echo "branch: task/foo"
            echo "base: main"
            echo "worktree: $fixture_root/worktrees/foo"
            echo "tmux-session: zyz-task-foo"
            echo "blocked-by: []"
            echo "merged-with: []"
            echo "deps-tentative: false"
            echo "last-seen:"
            echo "heartbeat-stale-sec: 300"
            echo "created-at: 2026-06-18"
            echo "updated-at: 2026-06-18"
            echo "---"
            echo ""
            echo "# foo"
            echo ""
            echo "## Description"
            echo ""
            echo "T4 missing-dep fixture."
        } >"$fixture_list/tasks/foo.md"

        # Build a PATH stripped of tmux/git/gh — same logic as t4_missing_dep,
        # but we keep git in the lookup so source-repo validation can pass.
        # Wait: stripping git would also break source-repo's `git -C` check
        # (source-repo runs BEFORE tmux dep check; if git is absent, source-repo
        # validation falls into 'not a git work tree' exit 5).  So we keep
        # git on PATH and strip ONLY tmux.  Result: source-repo passes,
        # tmux dep check fires -> exit 3.
        local stripped_path
        stripped_path="$(echo "$PATH" | tr ':' '\n' \
            | grep -vE '/(tmux|homebrew|brew)' \
            | tr '\n' ':')"
        stripped_path="${stripped_path%:}"
        case ":$stripped_path:" in
            *:/usr/bin:*) : ;;
            *) stripped_path="/usr/bin:$stripped_path" ;;
        esac
        case ":$stripped_path:" in
            *:/bin:*) : ;;
            *) stripped_path="/bin:$stripped_path" ;;
        esac

        if PATH="$stripped_path" command -v tmux >/dev/null 2>&1; then
            skip "T4 $script missing-dep (cannot strip tmux from PATH on this host)"
            rm -rf "$fixture_root"
            return
        fi

        local rc
        PATH="$stripped_path" bash "$REPO_ROOT/$script" foo "$fixture_list" </dev/null >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 3 ]; then
            pass "T4 $script with stripped PATH (no tmux), valid source-repo -> exit 3"
        else
            fail "T4 $script with stripped PATH (no tmux), valid source-repo got exit=$rc, expected 3"
        fi
        rm -rf "$fixture_root"
    }
    t4_spawn_missing_dep

    # ---- orch-check-worker.sh : <task-id> <list-dir> ----
    t4_no_args        "scripts/orch-check-worker.sh"
    t4_invalid_taskid "scripts/orch-check-worker.sh"
    t4_missing_dep    "scripts/orch-check-worker.sh" "foo" "/tmp/zyz-orch-t4-dummy-list"

    # ---- orch-heartbeat-daemon.sh : <heartbeat-file> <interval-sec> ----
    # heartbeat takes two args; no task-id semantics.  Only no-args is
    # meaningful for it.  Missing-dep is SKIP because §E.4 says the daemon
    # only needs `date` and `sleep`; it does NOT require tmux/git.
    t4_no_args "scripts/orch-heartbeat-daemon.sh"
    skip "T4 scripts/orch-heartbeat-daemon.sh missing-dep (daemon does not require tmux/git per §E.4)"

    # ---- orch-cleanup-worker.sh : <task-id> <list-dir> [--force] ----
    t4_no_args        "scripts/orch-cleanup-worker.sh"
    t4_invalid_taskid "scripts/orch-cleanup-worker.sh"
    t4_missing_dep    "scripts/orch-cleanup-worker.sh" "foo" "/tmp/zyz-orch-t4-dummy-list"

    # ---- orch-merge-and-cleanup.sh : <task-id> <list-dir> <base-branch> ----
    t4_no_args        "scripts/orch-merge-and-cleanup.sh"
    t4_invalid_taskid "scripts/orch-merge-and-cleanup.sh"
    t4_missing_dep    "scripts/orch-merge-and-cleanup.sh" "foo" "/tmp/zyz-orch-t4-dummy-list" "main"
}

# ---------------------------------------------------------------------------
# T4'. orch-spawn-worker.sh source-repo negative spawn cases (stage C
#      orchestration-source-repo, design §F.3 + §"exit 5 复用" table).
#
# Four sub-cases, each exits 5 with a precise stderr diagnostic prefix:
#   (a) master entry missing `source-repo:`
#         → "error: master entry has no source-repo field"
#   (b) master entry `source-repo: ./relative`
#         → "error: source-repo must be an absolute path or start with ~/"
#   (c) master entry `source-repo: /nonexistent/...` (unlikely path)
#         → "error: source-repo path does not exist"
#   (d) master entry `source-repo: /tmp` (exists but not a git work tree)
#         → "error: source-repo is not a git work tree"
#
# Per design §B the spawn-worker script is reordered so source-repo
# validation runs BEFORE the tmux/git dependency check, so these cases
# MUST fire even on hosts without tmux installed.  We therefore run them
# unconditionally (no tmux gate), placed before T5/T6 so a tmux-less host
# still exercises the full negative matrix.
# ---------------------------------------------------------------------------

# t4p_write_master_entry <list-dir> <task-id> <source-repo-value-or-empty>
# Writes a minimal master entry under <list-dir>/tasks/<task-id>.md.
# If <source-repo-value> is empty, the source-repo line is omitted entirely
# (case (a) — missing field).  Otherwise the literal value is emitted as-is.
t4p_write_master_entry() {
    local list_dir="$1"
    local task_id="$2"
    local sr_val="$3"
    mkdir -p "$list_dir/tasks"
    {
        echo "---"
        echo "task-id: $task_id"
        echo "project: t4p-mock"
        if [ -n "$sr_val" ]; then
            echo "source-repo: $sr_val"
        fi
        echo "state: ready"
        echo "priority: normal"
        echo "branch: task/$task_id"
        echo "base: main"
        echo "worktree: /tmp/zyz-orch-t4p-worktree/$task_id"
        echo "tmux-session: zyz-task-$task_id"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-18"
        echo "updated-at: 2026-06-18"
        echo "---"
        echo ""
        echo "# $task_id"
        echo ""
        echo "## Description"
        echo ""
        echo "T4' negative spawn case fixture."
    } >"$list_dir/tasks/$task_id.md"
}

run_T4_prime() {
    say_header "T4' orch-spawn-worker.sh source-repo negative cases"

    local spawn="$REPO_ROOT/scripts/orch-spawn-worker.sh"
    if [ ! -x "$spawn" ]; then
        skip "T4' (a) source-repo field missing -> exit 5 (spawn script missing or not executable)"
        skip "T4' (b) source-repo relative path -> exit 5 (spawn script missing or not executable)"
        skip "T4' (c) source-repo nonexistent path -> exit 5 (spawn script missing or not executable)"
        skip "T4' (d) source-repo not a git work tree -> exit 5 (spawn script missing or not executable)"
        return
    fi
    if ! command -v git >/dev/null 2>&1; then
        # spawn validates source-repo via `git -C ... rev-parse`; without git
        # the (d) case cannot be distinguished from a missing-dep exit 3.
        # Per design §B, source-repo validation is supposed to run BEFORE
        # the tmux/git dep check; but git is still needed to verify case (d).
        # On a no-git host, mark the whole group SKIP rather than guess.
        skip "T4' (a) source-repo field missing -> exit 5 (git not available)"
        skip "T4' (b) source-repo relative path -> exit 5 (git not available)"
        skip "T4' (c) source-repo nonexistent path -> exit 5 (git not available)"
        skip "T4' (d) source-repo not a git work tree -> exit 5 (git not available)"
        return
    fi

    local T4P_ROOT
    T4P_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t4p.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$T4P_ROOT'" EXIT

    # Case (a): no source-repo field.
    local list_a="$T4P_ROOT/list-a"
    t4p_write_master_entry "$list_a" "foo" ""
    run_and_check_exit_stderr_regex 5 \
        'error: master entry has no source-repo field' \
        "T4' (a) source-repo field missing -> exit 5 + 'master entry has no source-repo field'" \
        bash "$spawn" foo "$list_a"

    # Case (b): relative path.
    local list_b="$T4P_ROOT/list-b"
    t4p_write_master_entry "$list_b" "foo" "./relative"
    run_and_check_exit_stderr_regex 5 \
        'error: source-repo must be an absolute path or start with ~/' \
        "T4' (b) source-repo relative './relative' -> exit 5 + 'must be an absolute path or start with ~/'" \
        bash "$spawn" foo "$list_b"

    # Case (c): nonexistent absolute path.  Use a path that is extremely
    # unlikely to exist on any host.
    local list_c="$T4P_ROOT/list-c"
    local nonexistent_path="/nonexistent/zyz-orch-t4p-$$-does-not-exist"
    t4p_write_master_entry "$list_c" "foo" "$nonexistent_path"
    run_and_check_exit_stderr_regex 5 \
        'error: source-repo path does not exist' \
        "T4' (c) source-repo nonexistent path -> exit 5 + 'path does not exist'" \
        bash "$spawn" foo "$list_c"

    # Case (d): /tmp exists but is not a git work tree.  Per design §F.3.d
    # we use /tmp (macOS may symlink /tmp to /private/tmp; `git -C /tmp
    # rev-parse --is-inside-work-tree` will still return non-zero unless
    # somebody perversely turned /tmp itself into a git work tree — accept
    # that edge case as the design's documented gotcha).
    local list_d="$T4P_ROOT/list-d"
    t4p_write_master_entry "$list_d" "foo" "/tmp"
    # Pre-flight: if /tmp happens to be a git work tree on this host, fall
    # back to a sibling tmpdir that we KNOW is not a git repo.
    local not_a_repo_path="/tmp"
    if git -C /tmp rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        not_a_repo_path="$T4P_ROOT/not-a-repo"
        mkdir -p "$not_a_repo_path"
        # Rewrite case (d)'s master entry to the sibling path.
        t4p_write_master_entry "$list_d" "foo" "$not_a_repo_path"
    fi
    run_and_check_exit_stderr_regex 5 \
        'error: source-repo is not a git work tree' \
        "T4' (d) source-repo not a git work tree ($not_a_repo_path) -> exit 5 + 'not a git work tree'" \
        bash "$spawn" foo "$list_d"

    trap - EXIT
    rm -rf "$T4P_ROOT"
}

# ---------------------------------------------------------------------------
# T5. Mock-worker behavior test
#
# Builds a temp <list-dir> with one master entry tasks/foo.md, then
# manually writes worker-status.md transitions and asserts that
# `orch-check-worker.sh foo <list-dir>` reports the matching phase /
# wait-state.  We do NOT spawn a real tmux session here — this is a unit
# test of the read path of orch-check-worker.sh.
# ---------------------------------------------------------------------------

# Write a worker-status.md with phase + wait-state to <runtime-dir>.
# Args: <runtime-dir> <phase> <wait-state> [waiting-reason]
write_worker_status() {
    local runtime="$1"
    local phase="$2"
    local wstate="$3"
    local reason="${4:-}"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$runtime"
    # Use tmpfile+rename to mimic atomic write contract.
    local tmp="$runtime/worker-status.md.tmp.$$"
    {
        echo "---"
        echo "task-id: foo"
        echo "phase: $phase"
        echo "phase-since: $now"
        echo "wait-state: $wstate"
        echo "waiting-reason: $reason"
        echo "expected-resume-by:"
        echo "last-flush: $now"
        echo "---"
        echo ""
        echo "## Current Activity"
        echo ""
        echo "mock worker in phase=$phase wait-state=$wstate"
    } >"$tmp"
    mv "$tmp" "$runtime/worker-status.md"
}

# Write a master entry frontmatter file.  Args: <list-dir> <task-id>
write_master_entry() {
    local list_dir="$1"
    local task_id="$2"
    mkdir -p "$list_dir/tasks"
    {
        echo "---"
        echo "task-id: $task_id"
        echo "project: t5-mock"
        echo "state: in-progress"
        echo "priority: normal"
        echo "branch: task/$task_id"
        echo "base: main"
        echo "worktree: /tmp/zyz-orch-t5-worktree/$task_id"
        echo "tmux-session: zyz-task-$task_id"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: true"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-18"
        echo "updated-at: 2026-06-18"
        echo "---"
        echo ""
        echo "# $task_id"
        echo ""
        echo "## Description"
        echo ""
        echo "Mock task for T5."
    } >"$list_dir/tasks/$task_id.md"
}

# Touch a heartbeat with mtime = now (fresh) or with backdated mtime.
# Args: <heartbeat-file> <fresh|stale>
write_heartbeat() {
    local hb="$1"
    local kind="$2"
    mkdir -p "$(dirname "$hb")"
    date -u +%Y-%m-%dT%H:%M:%SZ >"$hb"
    if [ "$kind" = "stale" ]; then
        # Backdate to 1 hour ago.  Use POSIX `touch -t` with portable format.
        # bash 3.2 + macOS friendly: use `touch -t YYYYMMDDhhmm.SS`.
        local ts
        # Compute a timestamp 1 hour in the past.  macOS date does not
        # accept GNU `date -d`; we use `date -v-1H` on macOS or
        # `date -u -d '1 hour ago'` on GNU.  Test which is available.
        if date -v-1H -u +%Y%m%d%H%M.%S >/dev/null 2>&1; then
            ts="$(date -v-1H -u +%Y%m%d%H%M.%S)"
        else
            ts="$(date -u -d '1 hour ago' +%Y%m%d%H%M.%S 2>/dev/null || true)"
        fi
        if [ -n "$ts" ]; then
            touch -t "$ts" "$hb"
        fi
    fi
}

# t5_assert_check <list-dir> <task-id> <expected-field> <expected-value>
# Runs orch-check-worker.sh and asserts a specific key=value line appears.
t5_assert_check() {
    local list_dir="$1"
    local task_id="$2"
    local key="$3"
    local val="$4"
    local script="$REPO_ROOT/scripts/orch-check-worker.sh"
    if [ ! -x "$script" ]; then
        skip "T5 assert $key=$val (orch-check-worker.sh missing or not executable)"
        return
    fi
    local out rc
    out="$(bash "$script" "$task_id" "$list_dir" </dev/null 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "T5 orch-check-worker.sh $task_id $list_dir exited $rc (expected 0).  Output: $out"
        return
    fi
    if printf '%s\n' "$out" | grep -qE "^${key}=${val}([[:space:]]|$)"; then
        pass "T5 check reports $key=$val"
    else
        fail "T5 check did NOT report $key=$val.  Output was:
$(printf '%s\n' "$out" | sed 's/^/      | /')"
    fi
}

run_T5() {
    say_header "T5  Mock-worker behavior test"

    # T5 exercises the read path of orch-check-worker.sh.  Per design §E
    # top-of-section, every helper (including check-worker) hard-checks
    # for tmux + git at entry and exits 3 if either is missing.  T4 is
    # the contract-level validation of that rule; T5 is the data-plane
    # validation built on top.  On a host without tmux, check-worker
    # always exits 3 before reading any worker-status.md — T5 cannot
    # run.  SKIP the whole group (same shape as T6's tmux gate).
    if ! command -v tmux >/dev/null 2>&1; then
        skip "T5 entire group SKIPPED (tmux not available; orch-check-worker.sh requires tmux per design §E top-of-section)"
        return
    fi

    local script="$REPO_ROOT/scripts/orch-check-worker.sh"
    if [ ! -x "$script" ]; then
        skip "T5 entire group SKIPPED (orch-check-worker.sh missing or not executable)"
        return
    fi

    # Build isolated temp <list-dir>.
    local TMPROOT
    TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t5.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$TMPROOT'" EXIT

    local list_dir="$TMPROOT/list"
    local runtime="$list_dir/runtime/foo"
    local hb="$runtime/heartbeat"

    write_master_entry "$list_dir" "foo"
    mkdir -p "$runtime"
    write_heartbeat "$hb" fresh

    # Phase walkthrough: design -> implementation -> implementation+waiting-subagent ->
    # implementation+none -> testing -> review -> delivery -> awaiting-confirmation.
    write_worker_status "$runtime" design none
    t5_assert_check "$list_dir" "foo" "phase" "design"
    t5_assert_check "$list_dir" "foo" "wait-state" "none"

    write_worker_status "$runtime" implementation none
    t5_assert_check "$list_dir" "foo" "phase" "implementation"
    t5_assert_check "$list_dir" "foo" "wait-state" "none"

    write_worker_status "$runtime" implementation waiting-subagent "dispatched test-agent"
    t5_assert_check "$list_dir" "foo" "phase" "implementation"
    t5_assert_check "$list_dir" "foo" "wait-state" "waiting-subagent"

    write_worker_status "$runtime" implementation none
    t5_assert_check "$list_dir" "foo" "wait-state" "none"

    write_worker_status "$runtime" testing none
    t5_assert_check "$list_dir" "foo" "phase" "testing"

    write_worker_status "$runtime" review none
    t5_assert_check "$list_dir" "foo" "phase" "review"

    write_worker_status "$runtime" delivery none
    t5_assert_check "$list_dir" "foo" "phase" "delivery"

    # Rollback is now allowed among working phases (the helper is a pure
    # pass-through reader; the absorbing-state rule is a worker-side contract
    # verified at the doc level in T3, not enforced by orch-check-worker.sh).
    write_worker_status "$runtime" review none
    t5_assert_check "$list_dir" "foo" "phase" "review"
    write_worker_status "$runtime" implementation none
    t5_assert_check "$list_dir" "foo" "phase" "implementation"
    write_worker_status "$runtime" review none
    t5_assert_check "$list_dir" "foo" "phase" "review"

    # `awaiting-confirmation` is the worker's furthest SELF-reachable phase
    # (self-declared finished, awaiting user confirmation).  It is NOT terminal:
    # the 0.6.5 state-model fix makes it reversible, and re-introduces `done` as
    # the sole absorbing terminal — written by the worker ONLY after explicit
    # user confirmation.  The helper just echoes whatever phase the file holds;
    # the absorbing rule (done is non-reversible; awaiting-confirmation is
    # reversible) is a worker-side CONTRACT verified by doc-grep in T3 (design
    # B2/F5), NOT enforced by orch-check-worker.sh — so this data-plane test only
    # proves the helper carries each value through, including `done`.
    write_worker_status "$runtime" delivery none
    t5_assert_check "$list_dir" "foo" "phase" "delivery"
    write_worker_status "$runtime" awaiting-confirmation none
    t5_assert_check "$list_dir" "foo" "phase" "awaiting-confirmation"

    # F6: prove the helper passes the re-introduced `done` terminal through
    # verbatim (write_worker_status interpolates `phase: $phase` with NO enum
    # validation — verified by reading the helper — so an unknown/new phase
    # string is carried as-is; this is exactly the pass-through the new contract
    # relies on for L1 to mirror `done` -> `state: completed`).
    write_worker_status "$runtime" done none
    t5_assert_check "$list_dir" "foo" "phase" "done"

    # Rollback pass-through (the new contract allows awaiting-confirmation to
    # roll back): write awaiting-confirmation, then roll back to implementation,
    # and prove the data plane carries the rollback the helper does NOT forbid.
    # (The absorbing-rule guarantee that `done` itself never rolls back is a
    # doc-level worker contract, asserted by T3 B2 — not by this helper.)
    write_worker_status "$runtime" awaiting-confirmation none
    t5_assert_check "$list_dir" "foo" "phase" "awaiting-confirmation"
    write_worker_status "$runtime" implementation none
    t5_assert_check "$list_dir" "foo" "phase" "implementation"

    # Heartbeat staleness: backdate heartbeat and expect heartbeat-status=stale.
    write_heartbeat "$hb" stale
    t5_assert_check "$list_dir" "foo" "heartbeat-status" "stale"

    # Restore freshness and confirm transition back to fresh.
    write_heartbeat "$hb" fresh
    t5_assert_check "$list_dir" "foo" "heartbeat-status" "fresh"

    # Phase-since stagnation note (per design): the helper does NOT detect
    # 5-tick stagnation; that is orchestrator-level logic and is therefore
    # outside the scope of this unit test.  Documenting via SKIP.
    skip "T5 phase-since 5-tick stagnation (orchestrator-level; not testable in helper unit test per §A.6/§F.2)"

    # ---- BUG-2: malformed-frontmatter guard ---------------------------------
    # Per design §BUG-2: a worker-status.md written as a bare field dump (NO
    # `---` fence, file starts directly with `phase: ...`) is a contract defect
    # — fm_field never enters frontmatter, so every field reads empty and L1
    # sees no progress.  As a backstop, orch-check-worker.sh now emits the
    # literal line `worker-status-malformed=true` for such fence-less files so
    # L1 can diagnose it.  This case is gated by the same tmux requirement as
    # the rest of T5 (orch-check-worker.sh hard-requires tmux at entry).
    #
    # We overwrite worker-status.md with a fence-less dump AFTER the well-formed
    # walkthrough above so earlier asserts are unaffected.
    {
        echo "phase: review"
        echo "phase-since: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "wait-state: none"
        echo "waiting-reason:"
        echo "expected-resume-by:"
        echo "last-flush: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$runtime/worker-status.md"
    local malformed_out malformed_rc
    malformed_out="$(bash "$script" "foo" "$list_dir" </dev/null 2>&1)"
    malformed_rc=$?
    if [ "$malformed_rc" -ne 0 ]; then
        fail "T5 BUG-2 orch-check-worker.sh exited $malformed_rc on fence-less worker-status (expected 0).  Output:
$(printf '%s\n' "$malformed_out" | sed 's/^/      | /')"
    elif printf '%s\n' "$malformed_out" | grep -qE '^worker-status-malformed=true([[:space:]]|$)'; then
        pass "T5 BUG-2 fence-less worker-status.md yields 'worker-status-malformed=true'"
    else
        fail "T5 BUG-2 fence-less worker-status.md did NOT yield 'worker-status-malformed=true'.  Output:
$(printf '%s\n' "$malformed_out" | sed 's/^/      | /')"
    fi

    # ---- BUG-1: tilde-expansion regression ----------------------------------
    # Per design §BUG-1: cleanup/merge expanded a `~/`-form worktree with an
    # UNQUOTED ${WORKTREE#~/}, where bash treats the leading `~` of the pattern
    # as a tilde metacharacter (expanding it to $HOME/ before matching), so the
    # literal `~/` prefix is never stripped → a no-op → path becomes
    # $HOME/~/... (nonexistent) → removal silently skipped.  The fix uses the
    # QUOTED ${WORKTREE#"~/"} form (matching orch-spawn-worker.sh).
    #
    # (1) Pure unit assertion: prove the quoted form strips `~/` while the
    #     unquoted form is a no-op on this shell.
    local wt='~/x/y'
    local bad="$HOME/${wt#~/}"      # buggy (unquoted) form
    local good="$HOME/${wt#"~/"}"   # fixed (quoted) form
    if [ "$good" = "$HOME/x/y" ]; then
        pass "T5 BUG-1 quoted \${WORKTREE#\"~/\"} strip yields \$HOME/x/y"
    else
        fail "T5 BUG-1 quoted strip wrong: got '$good', expected '$HOME/x/y'"
    fi
    if [ "$bad" != "$good" ]; then
        pass "T5 BUG-1 unquoted \${WORKTREE#~/} strip is a no-op (demonstrates the bug)"
    else
        skip "T5 BUG-1 unquoted form coincidentally equal on this shell"
    fi
    # (2) Behavioral grep guard: the two fixed scripts must use the QUOTED form.
    check_grep_fixed "scripts/orch-cleanup-worker.sh" \
        "BUG-1 cleanup uses quoted \${WORKTREE#\"~/\"}" '${WORKTREE#"~/"}'
    check_grep_fixed "scripts/orch-merge-and-cleanup.sh" \
        "BUG-1 merge uses quoted \${WORKTREE#\"~/\"}" '${WORKTREE#"~/"}'

    # Clean trap; T6 sets its own.
    trap - EXIT
    rm -rf "$TMPROOT"
}

# ---------------------------------------------------------------------------
# T6. Real tmux integration test (CONDITIONAL on tmux availability)
# ---------------------------------------------------------------------------

# T6_FAIL <reason>
T6_FAIL() {
    fail "T6 $1"
}

T6_PASS() {
    pass "T6 $1"
}

T6_SKIP_ALL() {
    local reason="$1"
    # Emit one consolidated SKIP record per planned check so the operator
    # sees the count matches expectations.  Stage C orchestration-source-repo
    # extends T6 with a second task `bar` (design §F.2 2-task cross-repo);
    # the planned-check list grows accordingly.
    local i
    for i in \
        "fixture cwd is not equal to source-repo (F.1.d defensive)" \
        "tmux session zyz-task-foo created" \
        "tmux session zyz-task-bar created (F.2)" \
        "runtime dir <list-dir>/runtime/foo exists" \
        "runtime dir <list-dir>/runtime/bar exists (F.2)" \
        "heartbeat file present after spawn (foo)" \
        "heartbeat file present after spawn (bar) (F.2)" \
        "worktree foo resolves to source-repo work (F.2)" \
        "worktree bar resolves to source-repo work2 (F.2)" \
        "worktree foo and bar resolve to DIFFERENT .git dirs (F.2)" \
        "orch-check-worker.sh reports phase=awaiting-confirmation after mock worker (foo)" \
        "orch-check-worker.sh reports phase=awaiting-confirmation after mock worker (bar) (F.2)" \
        "orch-merge-and-cleanup.sh exits 0 (foo)" \
        "orch-merge-and-cleanup.sh exits 0 (bar) (F.2)" \
        "master entry foo state: completed after merge" \
        "master entry bar state: completed after merge (F.2)" \
        "tmux session zyz-task-foo absent after cleanup" \
        "tmux session zyz-task-bar absent after cleanup (F.2)" \
        "worktree foo removed after cleanup" \
        "worktree bar removed after cleanup (F.2)" \
        "no orch-heartbeat-daemon.sh residue after teardown (F8, foo+bar)" \
        "T6 fixture teardown clean"
    do
        skip "T6 $i (skipped: $reason)"
    done
}

run_T6() {
    say_header "T6  Real tmux integration test"

    if ! command -v tmux >/dev/null 2>&1; then
        T6_SKIP_ALL "tmux not available on PATH"
        return
    fi
    if ! command -v git >/dev/null 2>&1; then
        T6_SKIP_ALL "git not available on PATH"
        return
    fi

    local spawn="$REPO_ROOT/scripts/orch-spawn-worker.sh"
    local check="$REPO_ROOT/scripts/orch-check-worker.sh"
    local merge="$REPO_ROOT/scripts/orch-merge-and-cleanup.sh"
    if [ ! -x "$spawn" ] || [ ! -x "$check" ] || [ ! -x "$merge" ]; then
        T6_SKIP_ALL "one or more helper scripts missing/not executable"
        return
    fi

    # ---- Fixture setup --------------------------------------------------
    # NOTE: we intentionally use GLOBAL (non-`local`) variables for state
    # that the EXIT trap below needs to see.  Bash `local` variables are
    # invisible to functions invoked from the trap once run_T6 returns.
    #
    # Stage C orchestration-source-repo extends T6 to a 2-task cross-repo
    # fixture (design §F.2): two independent work repos `work` and `work2`,
    # two master entries `foo` (source-repo=work) and `bar` (source-repo=
    # work2), spawn invoked from $TMPROOT (which is intentionally NOT a
    # git repo, per §F.1.b).
    T6_TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t6.XXXXXX")"
    T6_TMUX_SESSION="zyz-task-foo"
    T6_TMUX_SESSION2="zyz-task-bar"
    T6_LIST_DIR="$T6_TMPROOT/list"
    T6_ORIGIN_DIR="$T6_TMPROOT/origin.git"
    T6_ORIGIN_DIR2="$T6_TMPROOT/origin2.git"
    T6_WORK_DIR="$T6_TMPROOT/work"
    T6_WORK_DIR2="$T6_TMPROOT/work2"
    T6_WORKTREE_DIR="$T6_TMPROOT/worktrees/foo"
    T6_WORKTREE_DIR2="$T6_TMPROOT/worktrees/bar"

    # Convenience local aliases used throughout this function body.  The
    # T6_* globals carry the same values and are what the teardown reads.
    local TMPROOT="$T6_TMPROOT"
    local TMUX_SESSION="$T6_TMUX_SESSION"
    local TMUX_SESSION2="$T6_TMUX_SESSION2"
    local LIST_DIR="$T6_LIST_DIR"
    local ORIGIN_DIR="$T6_ORIGIN_DIR"
    local ORIGIN_DIR2="$T6_ORIGIN_DIR2"
    local WORK_DIR="$T6_WORK_DIR"
    local WORK_DIR2="$T6_WORK_DIR2"
    local WORKTREE_DIR="$T6_WORKTREE_DIR"
    local WORKTREE_DIR2="$T6_WORKTREE_DIR2"

    # Teardown function reads T6_* globals (not the local copies).
    # Defined inline so it is in the function table when the trap fires.
    t6_teardown() {
        # Best-effort kill of both tmux sessions in case the test left
        # them alive due to an early failure.  This is allowed by F8 —
        # F8 only forbids manual pkill of orch-heartbeat-daemon.sh;
        # killing the tmux sessions is the *natural* path that should
        # also kill the daemons via SIGHUP.
        tmux kill-session -t "$T6_TMUX_SESSION"  2>/dev/null || true
        tmux kill-session -t "$T6_TMUX_SESSION2" 2>/dev/null || true

        # Per F8: after teardown, there must be NO orch-heartbeat-daemon.sh
        # processes left running for EITHER task-id.  Wait up to ~3 seconds
        # for SIGHUP propagation, then check both.  We grep per task-id so
        # any unrelated heartbeat daemons on the host (other tests, other
        # users) do not pollute this assertion.
        sleep 2
        local residue_foo residue_bar
        residue_foo="$(pgrep -f "orch-heartbeat-daemon.*runtime/foo" 2>/dev/null || true)"
        residue_bar="$(pgrep -f "orch-heartbeat-daemon.*runtime/bar" 2>/dev/null || true)"
        if [ -n "$residue_foo" ] || [ -n "$residue_bar" ]; then
            T6_FAIL "no orch-heartbeat-daemon.sh residue after teardown (F8, foo+bar) -- foo pids: '$residue_foo', bar pids: '$residue_bar'"
            # Don't pkill ourselves; F8 forbids it.  Leave for operator.
        else
            T6_PASS "no orch-heartbeat-daemon.sh residue after teardown (F8, foo+bar)"
        fi

        rm -rf "$T6_TMPROOT"
        T6_PASS "T6 fixture teardown clean"
    }
    # shellcheck disable=SC2064
    trap "t6_teardown" EXIT

    # --- Init the two pairs of git repos (work + work2) ---
    # Stage C orchestration-source-repo §F.2: 2-task cross-repo fixture
    # requires two independent source-repos so we can prove worktrees
    # resolve to DIFFERENT .git common dirs.
    if ! git init --bare "$ORIGIN_DIR" >/dev/null 2>&1; then
        T6_FAIL "git init --bare $ORIGIN_DIR failed"
        return
    fi
    if ! git init --bare "$ORIGIN_DIR2" >/dev/null 2>&1; then
        T6_FAIL "git init --bare $ORIGIN_DIR2 failed"
        return
    fi
    mkdir -p "$WORK_DIR"
    (
        cd "$WORK_DIR" || exit 1
        git init -q . >/dev/null 2>&1
        git config user.email "t6@example.com"
        git config user.name "T6 Test"
        git checkout -q -b main 2>/dev/null || git checkout -q main
        echo "T6 initial (work)" >README.md
        git add README.md
        git commit -q -m "initial"
        git remote add origin "$ORIGIN_DIR" 2>/dev/null || true
        git push -q origin main 2>/dev/null || true
    ) || { T6_FAIL "git init in $WORK_DIR failed"; return; }
    mkdir -p "$WORK_DIR2"
    (
        cd "$WORK_DIR2" || exit 1
        git init -q . >/dev/null 2>&1
        git config user.email "t6@example.com"
        git config user.name "T6 Test"
        git checkout -q -b main 2>/dev/null || git checkout -q main
        echo "T6 initial (work2)" >README.md
        git add README.md
        git commit -q -m "initial"
        git remote add origin "$ORIGIN_DIR2" 2>/dev/null || true
        git push -q origin main 2>/dev/null || true
    ) || { T6_FAIL "git init in $WORK_DIR2 failed"; return; }

    # --- Build master entries pointing at the work repos as worktree base ---
    # foo -> source-repo=$WORK_DIR ; bar -> source-repo=$WORK_DIR2 (§F.2).
    mkdir -p "$LIST_DIR/tasks"
    {
        echo "---"
        echo "task-id: foo"
        echo "project: t6-mock"
        echo "source-repo: $WORK_DIR"
        echo "state: ready"
        echo "priority: normal"
        echo "branch: task/foo"
        echo "base: main"
        echo "worktree: $WORKTREE_DIR"
        echo "tmux-session: $TMUX_SESSION"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-18"
        echo "updated-at: 2026-06-18"
        echo "---"
        echo ""
        echo "# foo (T6 mock)"
        echo ""
        echo "## Description"
        echo ""
        echo "T6 real-tmux integration test."
    } >"$LIST_DIR/tasks/foo.md"

    # Second master entry: bar -> work2.  Frontmatter ordering follows the
    # canonical sequence from design §"Frontmatter Ordering".
    {
        echo "---"
        echo "task-id: bar"
        echo "project: bar"
        echo "source-repo: $WORK_DIR2"
        echo "state: ready"
        echo "priority: normal"
        echo "branch: task/bar"
        echo "base: main"
        echo "worktree: $WORKTREE_DIR2"
        echo "tmux-session: $TMUX_SESSION2"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-18"
        echo "updated-at: 2026-06-18"
        echo "---"
        echo ""
        echo "# bar (T6 mock)"
        echo ""
        echo "## Description"
        echo ""
        echo "T6 real-tmux integration test (second source-repo, §F.2)."
    } >"$LIST_DIR/tasks/bar.md"

    # Shadow `gh` with a fake script that always exits 1 with a "not
    # logged in" stderr message.  This triggers the gh-auth-fail fallback
    # path in orch-merge-and-cleanup.sh (design §E.6 step 5: gh exit !=0
    # AND stderr contains 'auth' / 'unauthenticated' / 'not logged in'
    # → fall back to local `git merge --no-ff`).
    #
    # Why shadow instead of PATH-strip: real `gh` typically lives in
    # /opt/homebrew/bin or /usr/local/bin, paths whose names do NOT
    # contain the substring 'gh' — naive PATH-strip via `grep -v gh`
    # fails to remove them, leaving the real gh in PATH.  Prepending a
    # shadow dir with our own `gh` executable is the robust portable
    # approach: it works regardless of where real gh is installed
    # because PATH lookup is left-to-right.
    local SHADOW_DIR="$TMPROOT/shadow-bin"
    mkdir -p "$SHADOW_DIR"
    cat >"$SHADOW_DIR/gh" <<'FAKEGHEOF'
#!/bin/sh
echo "gh: not logged in" >&2
exit 1
FAKEGHEOF
    chmod +x "$SHADOW_DIR/gh"

    # Prepend the shadow dir.  Real gh remains on PATH later in the
    # search order but `command -v gh` / direct `gh` invocations will
    # resolve to the fake one because PATH is left-to-right.
    local GH_STRIPPED_PATH="$SHADOW_DIR:$PATH"

    # Sanity: tmux is still available, and `gh` now resolves to the fake.
    if ! PATH="$GH_STRIPPED_PATH" command -v tmux >/dev/null 2>&1; then
        # Should never happen (we only prepended a dir) but guard anyway.
        GH_STRIPPED_PATH="$PATH"
    fi
    local resolved_gh
    resolved_gh="$(PATH="$GH_STRIPPED_PATH" command -v gh 2>/dev/null || true)"
    if [ "$resolved_gh" != "$SHADOW_DIR/gh" ]; then
        # Shadowing failed (e.g. fake gh not executable).  Continue but
        # warn — implementation-agent's real gh may execute and the test may
        # misclassify the merge as a real conflict.
        echo "  WARN  T6 fake gh shadow not active: command -v gh -> $resolved_gh"
    fi

    # --- Invoke spawn-worker --------------------------------------------
    # Stage C orchestration-source-repo §F.1: source-repo discovery now
    # flows EXCLUSIVELY through the master entry's `source-repo:` field;
    # the legacy `cd "$WORK_DIR"` cwd-shim and the `ZYZ_SOURCE_REPO` env
    # belt-and-braces have both been removed.  We invoke from $TMPROOT,
    # which is explicitly NOT a git repo, to prove cwd independence.
    #
    # §F.1.d defensive assertion: spawn must be invoked from a cwd that
    # is NOT equal to the source-repo, so any accidental cwd-fallback
    # in spawn-worker would mis-resolve `git rev-parse --show-toplevel`
    # and fail loudly rather than silently doing the right thing.
    if [ "$TMPROOT" != "$WORK_DIR" ] && [ "$TMPROOT" != "$WORK_DIR2" ]; then
        T6_PASS "fixture cwd is not equal to source-repo (F.1.d defensive)"
    else
        T6_FAIL "fixture cwd ($TMPROOT) equals a source-repo path (WORK_DIR=$WORK_DIR, WORK_DIR2=$WORK_DIR2) -- T6 §F.1.d invariant broken"
    fi

    local spawn_rc spawn_out
    spawn_out="$(
        cd "$TMPROOT" \
        && PATH="$GH_STRIPPED_PATH" \
           bash "$spawn" foo "$LIST_DIR" </dev/null 2>&1
    )"
    spawn_rc=$?

    if [ "$spawn_rc" -ne 0 ]; then
        T6_FAIL "orch-spawn-worker.sh (foo) exited $spawn_rc.  Output:
$(printf '%s\n' "$spawn_out" | sed 's/^/      | /')"
        # Continue to teardown; remaining checks SKIP.
        local i
        for i in \
            "tmux session $TMUX_SESSION created" \
            "tmux session $TMUX_SESSION2 created (F.2)" \
            "runtime dir $LIST_DIR/runtime/foo exists" \
            "runtime dir $LIST_DIR/runtime/bar exists (F.2)" \
            "heartbeat file present after spawn (foo)" \
            "heartbeat file present after spawn (bar) (F.2)" \
            "worktree foo resolves to source-repo work (F.2)" \
            "worktree bar resolves to source-repo work2 (F.2)" \
            "worktree foo and bar resolve to DIFFERENT .git dirs (F.2)" \
            "orch-check-worker.sh reports phase=awaiting-confirmation after mock worker (foo)" \
            "orch-check-worker.sh reports phase=awaiting-confirmation after mock worker (bar) (F.2)" \
            "orch-merge-and-cleanup.sh exits 0 (foo)" \
            "orch-merge-and-cleanup.sh exits 0 (bar) (F.2)" \
            "master entry foo state: completed after merge" \
            "master entry bar state: completed after merge (F.2)" \
            "tmux session $TMUX_SESSION absent after cleanup" \
            "tmux session $TMUX_SESSION2 absent after cleanup (F.2)" \
            "worktree foo removed after cleanup" \
            "worktree bar removed after cleanup (F.2)"
        do
            skip "T6 $i (skipped: spawn foo failed)"
        done
        return
    fi

    # Spawn the second worker `bar` from the same non-git cwd $TMPROOT.
    local spawn2_rc spawn2_out
    spawn2_out="$(
        cd "$TMPROOT" \
        && PATH="$GH_STRIPPED_PATH" \
           bash "$spawn" bar "$LIST_DIR" </dev/null 2>&1
    )"
    spawn2_rc=$?

    if [ "$spawn2_rc" -ne 0 ]; then
        T6_FAIL "orch-spawn-worker.sh (bar) exited $spawn2_rc.  Output:
$(printf '%s\n' "$spawn2_out" | sed 's/^/      | /')"
        # We still continue the foo branch checks below; mark bar-specific
        # ones SKIP individually as we encounter them.
    fi

    # Allow tmux sessions + in-pane daemons a moment to come up.
    sleep 1

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        T6_PASS "tmux session $TMUX_SESSION created"
    else
        T6_FAIL "tmux session $TMUX_SESSION NOT created"
    fi
    if [ "$spawn2_rc" -eq 0 ]; then
        if tmux has-session -t "$TMUX_SESSION2" 2>/dev/null; then
            T6_PASS "tmux session $TMUX_SESSION2 created (F.2)"
        else
            T6_FAIL "tmux session $TMUX_SESSION2 NOT created (F.2)"
        fi
    else
        skip "T6 tmux session $TMUX_SESSION2 created (F.2) (skipped: spawn bar failed)"
    fi

    if [ -d "$LIST_DIR/runtime/foo" ]; then
        T6_PASS "runtime dir $LIST_DIR/runtime/foo exists"
    else
        T6_FAIL "runtime dir $LIST_DIR/runtime/foo missing"
    fi
    if [ "$spawn2_rc" -eq 0 ]; then
        if [ -d "$LIST_DIR/runtime/bar" ]; then
            T6_PASS "runtime dir $LIST_DIR/runtime/bar exists (F.2)"
        else
            T6_FAIL "runtime dir $LIST_DIR/runtime/bar missing (F.2)"
        fi
    else
        skip "T6 runtime dir $LIST_DIR/runtime/bar exists (F.2) (skipped: spawn bar failed)"
    fi

    # Heartbeat: may take a moment.  Poll up to 5 seconds — covers both
    # foo and bar in one poll loop (bar polled only if spawn2 succeeded).
    local hb_foo_present=0 hb_bar_present=0 try
    for try in 1 2 3 4 5; do
        if [ "$hb_foo_present" -eq 0 ] && [ -e "$LIST_DIR/runtime/foo/heartbeat" ]; then
            hb_foo_present=1
        fi
        if [ "$spawn2_rc" -eq 0 ] && [ "$hb_bar_present" -eq 0 ] && [ -e "$LIST_DIR/runtime/bar/heartbeat" ]; then
            hb_bar_present=1
        fi
        if [ "$hb_foo_present" -eq 1 ] && { [ "$spawn2_rc" -ne 0 ] || [ "$hb_bar_present" -eq 1 ]; }; then
            break
        fi
        sleep 1
    done
    if [ "$hb_foo_present" -eq 1 ]; then
        T6_PASS "heartbeat file present after spawn (foo)"
    else
        T6_FAIL "heartbeat file NOT present after spawn (foo)"
    fi
    if [ "$spawn2_rc" -eq 0 ]; then
        if [ "$hb_bar_present" -eq 1 ]; then
            T6_PASS "heartbeat file present after spawn (bar) (F.2)"
        else
            T6_FAIL "heartbeat file NOT present after spawn (bar) (F.2)"
        fi
    else
        skip "T6 heartbeat file present after spawn (bar) (F.2) (skipped: spawn bar failed)"
    fi

    # F.2.d: worktrees must resolve via `git -C ... rev-parse --git-common-dir`
    # to two DIFFERENT .git common dirs — one rooted at $WORK_DIR/.git, the
    # other at $WORK_DIR2/.git.  This proves the per-task source-repo
    # routing actually held end-to-end (no accidental shared-repo coupling).
    #
    # macOS gotcha: `/var/folders/...` (where `mktemp -d` returns) is a
    # symlink to `/private/var/folders/...`.  `git rev-parse --git-common-dir`
    # internally realpaths the path, returning the `/private/...` form, while
    # $WORK_DIR / $WORKTREE_DIR retain the raw `/var/...` form from mktemp.
    # We MUST realpath both sides before string comparison or every macOS
    # CI run will FAIL with a path-mismatch that is purely cosmetic.
    #
    # `(cd "$dir" && pwd -P)` is the portable bash idiom: -P forces the
    # physical (resolved) path.  We resolve the parent and re-attach the
    # basename so this also works when the leaf does not exist yet (it
    # does in this fixture, but be robust).
    t6_realpath() {
        local p="$1"
        [ -z "$p" ] && { echo ""; return; }
        local d b
        d="$(dirname "$p")"
        b="$(basename "$p")"
        local resolved_d
        resolved_d="$(cd "$d" 2>/dev/null && pwd -P || true)"
        if [ -z "$resolved_d" ]; then
            # Fall back to the unresolved path so the error message is still
            # informative on the rare host where the parent dir is unreadable.
            echo "$p"
            return
        fi
        echo "$resolved_d/$b"
    }

    local foo_gitdir bar_gitdir foo_gitdir_real bar_gitdir_real
    local expected_foo_real expected_bar_real
    if [ -d "$WORKTREE_DIR" ]; then
        foo_gitdir="$(git -C "$WORKTREE_DIR" rev-parse --git-common-dir 2>/dev/null || true)"
        # Make absolute in case git returned a relative path.
        case "$foo_gitdir" in
            /*) : ;;
            *) foo_gitdir="$(cd "$WORKTREE_DIR/$foo_gitdir" 2>/dev/null && pwd || echo "$foo_gitdir")" ;;
        esac
        foo_gitdir_real="$(t6_realpath "$foo_gitdir")"
        expected_foo_real="$(t6_realpath "$WORK_DIR/.git")"
        if [ -n "$foo_gitdir_real" ] && [ "$foo_gitdir_real" = "$expected_foo_real" ]; then
            T6_PASS "worktree foo resolves to source-repo work (F.2)"
        else
            T6_FAIL "worktree foo --git-common-dir (realpath) ='$foo_gitdir_real' != expected '$expected_foo_real' (raw observed='$foo_gitdir', raw expected='$WORK_DIR/.git') (F.2)"
        fi
    else
        T6_FAIL "worktree foo dir $WORKTREE_DIR missing; cannot resolve --git-common-dir (F.2)"
    fi
    if [ "$spawn2_rc" -eq 0 ] && [ -d "$WORKTREE_DIR2" ]; then
        bar_gitdir="$(git -C "$WORKTREE_DIR2" rev-parse --git-common-dir 2>/dev/null || true)"
        case "$bar_gitdir" in
            /*) : ;;
            *) bar_gitdir="$(cd "$WORKTREE_DIR2/$bar_gitdir" 2>/dev/null && pwd || echo "$bar_gitdir")" ;;
        esac
        bar_gitdir_real="$(t6_realpath "$bar_gitdir")"
        expected_bar_real="$(t6_realpath "$WORK_DIR2/.git")"
        if [ -n "$bar_gitdir_real" ] && [ "$bar_gitdir_real" = "$expected_bar_real" ]; then
            T6_PASS "worktree bar resolves to source-repo work2 (F.2)"
        else
            T6_FAIL "worktree bar --git-common-dir (realpath) ='$bar_gitdir_real' != expected '$expected_bar_real' (raw observed='$bar_gitdir', raw expected='$WORK_DIR2/.git') (F.2)"
        fi
    else
        if [ "$spawn2_rc" -ne 0 ]; then
            skip "T6 worktree bar resolves to source-repo work2 (F.2) (skipped: spawn bar failed)"
        else
            T6_FAIL "worktree bar dir $WORKTREE_DIR2 missing; cannot resolve --git-common-dir (F.2)"
        fi
    fi
    # Final cross-check: the two realpath'd .git common dirs must be different.
    # Compare realpath'd forms so a host where /var -> /private/var doesn't
    # accidentally collapse them, AND a host without that symlink still passes.
    if [ "$spawn2_rc" -eq 0 ] && [ -n "${foo_gitdir_real:-}" ] && [ -n "${bar_gitdir_real:-}" ]; then
        if [ "$foo_gitdir_real" != "$bar_gitdir_real" ]; then
            T6_PASS "worktree foo and bar resolve to DIFFERENT .git dirs (F.2)"
        else
            T6_FAIL "worktree foo and bar resolve to the SAME .git dir '$foo_gitdir_real' (F.2 cross-repo isolation broken)"
        fi
    else
        skip "T6 worktree foo and bar resolve to DIFFERENT .git dirs (F.2) (skipped: spawn bar failed or git-common-dir unresolved)"
    fi

    # --- Send keys: a tiny bash mock worker writes phase=awaiting-confirmation in each pane ---
    # We send a small inline bash command that overwrites worker-status.md
    # with phase=awaiting-confirmation.  We do NOT start `claude` (per design).
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Helper to build the mock-worker tmux send-keys command for a task-id.
    # Emitted as a single argv so caller can `tmux send-keys -t SESSION "<cmd>" Enter`.
    t6_mock_cmd() {
        local tid="$1"
        echo "cat > '$LIST_DIR/runtime/$tid/worker-status.md' <<MOCKEOF
---
task-id: $tid
phase: awaiting-confirmation
phase-since: $now
wait-state: none
waiting-reason:
expected-resume-by:
last-flush: $now
---

## Current Activity

T6 mock worker ($tid) finished.
MOCKEOF"
    }

    local mock_cmd_foo mock_cmd_bar
    mock_cmd_foo="$(t6_mock_cmd foo)"
    # tmux send-keys requires the literal command then Enter.
    tmux send-keys -t "$TMUX_SESSION" "$mock_cmd_foo" Enter 2>/dev/null || true
    if [ "$spawn2_rc" -eq 0 ]; then
        mock_cmd_bar="$(t6_mock_cmd bar)"
        tmux send-keys -t "$TMUX_SESSION2" "$mock_cmd_bar" Enter 2>/dev/null || true
    fi
    sleep 2

    # Verify phase=awaiting-confirmation via the helper, for each task.
    local check_out check_rc
    check_out="$(bash "$check" foo "$LIST_DIR" </dev/null 2>&1)"
    check_rc=$?
    if [ "$check_rc" -eq 0 ] && printf '%s\n' "$check_out" | grep -qE '^phase=awaiting-confirmation([[:space:]]|$)'; then
        T6_PASS "orch-check-worker.sh reports phase=awaiting-confirmation after mock worker (foo)"
    else
        T6_FAIL "orch-check-worker.sh did NOT report phase=awaiting-confirmation for foo (rc=$check_rc).  Output:
$(printf '%s\n' "$check_out" | sed 's/^/      | /')"
    fi
    if [ "$spawn2_rc" -eq 0 ]; then
        local check_out_bar check_rc_bar
        check_out_bar="$(bash "$check" bar "$LIST_DIR" </dev/null 2>&1)"
        check_rc_bar=$?
        if [ "$check_rc_bar" -eq 0 ] && printf '%s\n' "$check_out_bar" | grep -qE '^phase=awaiting-confirmation([[:space:]]|$)'; then
            T6_PASS "orch-check-worker.sh reports phase=awaiting-confirmation after mock worker (bar) (F.2)"
        else
            T6_FAIL "orch-check-worker.sh did NOT report phase=awaiting-confirmation for bar (rc=$check_rc_bar).  Output:
$(printf '%s\n' "$check_out_bar" | sed 's/^/      | /')"
        fi
    else
        skip "T6 orch-check-worker.sh reports phase=awaiting-confirmation after mock worker (bar) (F.2) (skipped: spawn bar failed)"
    fi

    # --- Write 'approved' to each master entry's ## Pending Merge Approval ---
    {
        echo ""
        echo "## Pending Merge Approval"
        echo ""
        echo "approved by T6-test at $now"
    } >>"$LIST_DIR/tasks/foo.md"
    if [ "$spawn2_rc" -eq 0 ]; then
        {
            echo ""
            echo "## Pending Merge Approval"
            echo ""
            echo "approved by T6-test at $now"
        } >>"$LIST_DIR/tasks/bar.md"
    fi

    # --- Invoke merge-and-cleanup for each task ---
    local merge_rc merge_out
    merge_out="$(
        PATH="$GH_STRIPPED_PATH" \
        bash "$merge" foo "$LIST_DIR" main </dev/null 2>&1
    )"
    merge_rc=$?

    if [ "$merge_rc" -eq 0 ]; then
        T6_PASS "orch-merge-and-cleanup.sh exits 0 (foo)"
    else
        T6_FAIL "orch-merge-and-cleanup.sh (foo) exited $merge_rc.  Output:
$(printf '%s\n' "$merge_out" | sed 's/^/      | /')"
    fi
    if [ "$spawn2_rc" -eq 0 ]; then
        local merge_rc_bar merge_out_bar
        merge_out_bar="$(
            PATH="$GH_STRIPPED_PATH" \
            bash "$merge" bar "$LIST_DIR" main </dev/null 2>&1
        )"
        merge_rc_bar=$?
        if [ "$merge_rc_bar" -eq 0 ]; then
            T6_PASS "orch-merge-and-cleanup.sh exits 0 (bar) (F.2)"
        else
            T6_FAIL "orch-merge-and-cleanup.sh (bar) exited $merge_rc_bar.  Output:
$(printf '%s\n' "$merge_out_bar" | sed 's/^/      | /')"
        fi
    else
        skip "T6 orch-merge-and-cleanup.sh exits 0 (bar) (F.2) (skipped: spawn bar failed)"
    fi

    # Master entry frontmatter should now show state: completed.
    if grep -qE '^state:[[:space:]]*completed' "$LIST_DIR/tasks/foo.md"; then
        T6_PASS "master entry foo state: completed after merge"
    else
        T6_FAIL "master entry foo state is NOT 'completed' after merge"
    fi
    if [ "$spawn2_rc" -eq 0 ]; then
        if grep -qE '^state:[[:space:]]*completed' "$LIST_DIR/tasks/bar.md"; then
            T6_PASS "master entry bar state: completed after merge (F.2)"
        else
            T6_FAIL "master entry bar state is NOT 'completed' after merge (F.2)"
        fi
    else
        skip "T6 master entry bar state: completed after merge (F.2) (skipped: spawn bar failed)"
    fi

    # tmux sessions should be gone.
    sleep 1
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        T6_FAIL "tmux session $TMUX_SESSION still alive after cleanup"
    else
        T6_PASS "tmux session $TMUX_SESSION absent after cleanup"
    fi
    if [ "$spawn2_rc" -eq 0 ]; then
        if tmux has-session -t "$TMUX_SESSION2" 2>/dev/null; then
            T6_FAIL "tmux session $TMUX_SESSION2 still alive after cleanup (F.2)"
        else
            T6_PASS "tmux session $TMUX_SESSION2 absent after cleanup (F.2)"
        fi
    else
        skip "T6 tmux session $TMUX_SESSION2 absent after cleanup (F.2) (skipped: spawn bar failed)"
    fi

    # worktrees should be gone.
    if [ -d "$WORKTREE_DIR" ]; then
        T6_FAIL "worktree foo $WORKTREE_DIR still present after cleanup"
    else
        T6_PASS "worktree foo removed after cleanup"
    fi
    if [ "$spawn2_rc" -eq 0 ]; then
        if [ -d "$WORKTREE_DIR2" ]; then
            T6_FAIL "worktree bar $WORKTREE_DIR2 still present after cleanup (F.2)"
        else
            T6_PASS "worktree bar removed after cleanup (F.2)"
        fi
    else
        skip "T6 worktree bar removed after cleanup (F.2) (skipped: spawn bar failed)"
    fi

    # Teardown trap will run the F8 daemon-residue check + cleanup.
}

# ---------------------------------------------------------------------------
# T8. dispatch.md — Phase-1 spawn write + archive lifecycle
# ---------------------------------------------------------------------------
#
# This group covers the per-task dispatch.md state file introduced by the
# "dispatch-md-and-recovery" design (see
#   .zyz-worker/tasks/dispatch-md-and-recovery/design.md ## Testing Plan).
#
# ST1 owns T8(a) (spawn writes Phase-1 fields) and T8(d) (archive, not delete,
# through cleanup).  T8(b)/(c)/(c2) (Phase-2 lazy-fill in orch-check-worker.sh)
# are implemented by ST2's test-agent in t8_run_phase2_section() (a top-level
# helper invoked from run_T8 after the T8(a) happy path, BEFORE the T8(d)
# cleanup section since cleanup archives dispatch.md away).
#
# Fixture shape mirrors T6: real `git init`, a real master entry whose
# `source-repo:` points at the fixture repo (NOT the plugin repo), a real
# `mktemp -d` tmproot, real tmux, a `trap ... EXIT` teardown that kills the
# T8 tmux session, asserts no leftover heartbeat-daemon for the T8 task-id
# (F8 hygiene, same as T6), and removes the tmproot.

# T8_FAIL <reason>
T8_FAIL() {
    fail "T8 $1"
}

T8_PASS() {
    pass "T8 $1"
}

T8_SKIP_ALL() {
    local reason="$1"
    # One consolidated SKIP record per planned T8(a)/(d) check so the
    # operator's count matches expectations.  Keep this list in sync with the
    # assertions emitted below.
    local i
    for i in \
        "dispatch.md exists and is readable (a)" \
        "dispatch.md Phase-1 key task-id non-empty (a)" \
        "dispatch.md Phase-1 key spawn-iso non-empty (a)" \
        "dispatch.md Phase-1 key tmux-session non-empty (a)" \
        "dispatch.md Phase-1 key tmux-window-id non-empty (a)" \
        "dispatch.md Phase-1 key tmux-pane-id non-empty (a)" \
        "dispatch.md Phase-1 key shell-pid non-empty (a)" \
        "dispatch.md Phase-1 key worktree non-empty (a)" \
        "dispatch.md Phase-1 key source-repo non-empty (a)" \
        "dispatch.md Phase-1 key branch non-empty (a)" \
        "dispatch.md Phase-1 key base non-empty (a)" \
        "dispatch.md Phase-1 key plugin-root non-empty (a)" \
        "dispatch.md Phase-1 key encoded-cwd non-empty (a)" \
        "dispatch.md tmux-window-id matches ^@[0-9]+\$ (a)" \
        "dispatch.md tmux-pane-id matches ^%[0-9]+\$ (a)" \
        "dispatch.md shell-pid is a positive integer (a)" \
        "dispatch.md shell-pid process is alive (kill -0) (a)" \
        "dispatch.md worktree is an absolute path that exists (a)" \
        "dispatch.md source-repo is an absolute path that exists (a)" \
        "dispatch.md encoded-cwd equals pwd -P of worktree, / and . -> -, squeezed (a)" \
        "dispatch.md plugin-root equals repo root (CLAUDE_PLUGIN_ROOT unset) (a)" \
        "dispatch.md Phase-2 key claude-pid empty (a)" \
        "dispatch.md Phase-2 key claude-session-id empty (a)" \
        "dispatch.md Phase-2 key transcript-path empty (a)" \
        "dispatch.md Phase-2 key first-seen-iso empty (a)" \
        "check exits 0 with Phase-2 fixture (b)" \
        "check stdout preserves legacy phase=/wait-state= lines in order (b)" \
        "check stdout has dispatch-bound=true (b)" \
        "dispatch.md claude-pid == forked child pid (b)" \
        "dispatch.md claude-session-id == fake uuid (b)" \
        "dispatch.md transcript-path == fixture jsonl path (b)" \
        "dispatch.md first-seen-iso non-empty (b)" \
        "## Recovery body has substituted 'claude --resume <uuid>' (b)" \
        "## Recovery body has substituted 'tmux attach -t <session>' (b)" \
        "## Recovery body has substituted transcript path (b)" \
        "## Recovery body has NO literal angle-bracket placeholders (b)" \
        "no-op poll leaves all 4 Phase-2 values unchanged (c)" \
        "no-op poll leaves dispatch.md byte-identical (content hash) (c)" \
        "external sessions json mutation ignored: claude-session-id unchanged (c)" \
        "field-clear re-bind: claude-session-id == new uuid (c2)" \
        "field-clear re-bind: transcript-path updated to new jsonl (c2)" \
        "field-clear re-bind: first-seen-iso repopulated (c2)" \
        "find-by-sid: transcript discovered under non-matching projects dir (c3)" \
        "find-by-sid: dispatch-bound=true with mismatched encoded-cwd dir (c3)" \
        "runtime/<task-id>/ gone after cleanup --force (d)" \
        "runtime/.archive/<task-id>-*/dispatch.md exists after cleanup (d)" \
        "archived dispatch.md has same task-id: line as original (d)" \
        "no orch-heartbeat-daemon.sh residue after teardown (F8)" \
        "T8 fixture teardown clean"
    do
        skip "T8 $i (skipped: $reason)"
    done
}

run_T8() {
    say_header "T8  dispatch.md Phase-1 spawn write + archive lifecycle"

    if ! command -v tmux >/dev/null 2>&1; then
        T8_SKIP_ALL "tmux not available on PATH"
        return
    fi
    if ! command -v git >/dev/null 2>&1; then
        T8_SKIP_ALL "git not available on PATH"
        return
    fi

    local spawn="$REPO_ROOT/scripts/orch-spawn-worker.sh"
    local cleanup="$REPO_ROOT/scripts/orch-cleanup-worker.sh"
    if [ ! -x "$spawn" ] || [ ! -x "$cleanup" ]; then
        T8_SKIP_ALL "one or more helper scripts missing/not executable"
        return
    fi

    # ---- Fixture setup --------------------------------------------------
    # GLOBAL (non-`local`) state that the EXIT trap must see; bash `local`
    # vars are invisible to the trap once run_T8 returns (same rationale as
    # T6).  Use a unique T8_* tmux session name + a mktemp -d tmproot so the
    # test is isolated and re-runnable.
    T8_TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t8.XXXXXX")"
    T8_TASK_ID="t8disp"
    T8_TMUX_SESSION="zyz-task-$T8_TASK_ID"
    T8_LIST_DIR="$T8_TMPROOT/list"
    T8_WORK_DIR="$T8_TMPROOT/work"
    T8_WORKTREE_DIR="$T8_TMPROOT/worktrees/$T8_TASK_ID"
    # Forked fake-claude child PID (set by t8_run_phase2_section when the T8(b)
    # fixture forks `exec -a claude sleep 600 &`).  Initialized empty here so
    # t8_teardown can reference it under `set -u` even on SKIP paths where the
    # fork never happened.
    T8_FAKE_CLAUDE_PID=""

    # Convenience local aliases (the T8_* globals carry the same values and
    # are what the teardown reads).
    local TMPROOT="$T8_TMPROOT"
    local TASK_ID="$T8_TASK_ID"
    local TMUX_SESSION="$T8_TMUX_SESSION"
    local LIST_DIR="$T8_LIST_DIR"
    local WORK_DIR="$T8_WORK_DIR"
    local WORKTREE_DIR="$T8_WORKTREE_DIR"

    # Capture any EXIT trap a prior group left installed.  T6 sets
    # `trap "t6_teardown" EXIT` and (unlike T4'/T5) does NOT clear it on its
    # early-return paths — it historically relied on being the last group with
    # an EXIT trap.  Now that T8 follows T6 and installs its own EXIT trap, we
    # must CHAIN the prior trap rather than clobber it, or T6's teardown (its
    # F8 residue check + tmproot removal) would silently never run.  `trap -p`
    # prints the current trap as a re-executable `trap '<cmd>' EXIT` string; we
    # extract just <cmd> and invoke it first inside t8_teardown.  This handles
    # ALL of T6's exit paths (natural end AND early returns) without touching
    # T6.  T8_PRIOR_EXIT_TRAP is a GLOBAL so t8_teardown (invoked from the
    # trap) can see it.
    T8_PRIOR_EXIT_TRAP=""
    local _prior_trap_line
    _prior_trap_line="$(trap -p EXIT 2>/dev/null || true)"
    if [ -n "$_prior_trap_line" ]; then
        # Strip the leading `trap -- '` (or `trap '`) and trailing `' EXIT`.
        # Use sed to peel the wrapper; what remains is the raw command string.
        T8_PRIOR_EXIT_TRAP="$(printf '%s\n' "$_prior_trap_line" \
            | sed -e "s/^trap -- '//" -e "s/^trap '//" -e "s/' EXIT\$//" \
            | sed "s/'\\\\''/'/g")"
    fi

    # Robustness diagnostic (review note #2a): by the time control reaches
    # here, T8 has already passed the same tmux/git/script gates that T6 must
    # pass, so — on any host where T6 actually ran — T6 will have installed
    # (and never cleared) its `trap "t6_teardown" EXIT`.  We therefore EXPECT
    # T8_PRIOR_EXIT_TRAP to be non-empty.  If the peel produced an empty
    # string (e.g. a future edit changed T6's trap format and the sed wrapper
    # no longer matches), the chain would silently no-op and T6's teardown
    # would never run again — exactly the latent bug this chaining exists to
    # prevent.  Surface it loudly rather than letting it regress invisibly.
    if [ -z "$T8_PRIOR_EXIT_TRAP" ]; then
        T8_FAIL "expected a prior EXIT trap (T6's t6_teardown) to chain, but captured none -- trap -p EXIT='$_prior_trap_line' (T6 teardown may not run; trap-format regression?)"
    fi

    # Teardown reads T8_* globals (not the local copies).  Defined inline so
    # it is in the function table when the trap fires.
    t8_teardown() {
        # First, run any prior group's EXIT trap (T6's t6_teardown) that we
        # chained above, so its assertions + tmproot removal still fire.  If
        # the chained eval returns non-zero, emit a VISIBLE warning (review
        # note #2b) before swallowing it — a silent `|| true` would hide a
        # future trap-format regression.  We keep going (the warning does not
        # abort teardown) so T8's own cleanup still completes.
        if [ -n "${T8_PRIOR_EXIT_TRAP:-}" ]; then
            if ! eval "$T8_PRIOR_EXIT_TRAP"; then
                echo "  WARN  T8 chained prior EXIT trap returned non-zero: '$T8_PRIOR_EXIT_TRAP' (T6 teardown may be incomplete; trap-format regression?)"
            fi
        fi

        # Best-effort kill of the T8 tmux session in case an early failure
        # left it alive.  Killing the session SIGHUPs the in-pane heartbeat
        # daemon (F8-allowed natural path; F8 only forbids manual pkill of
        # the daemon itself).
        tmux kill-session -t "$T8_TMUX_SESSION" 2>/dev/null || true

        # Belt-and-suspenders: explicitly reap the T8(b) fake-claude child
        # (`exec -a claude sleep 600 &`) in case the session-kill SIGHUP did
        # not propagate to it.  This is OUR fixture process, not the heartbeat
        # daemon, so killing it does not violate F8.  Guard the pid is numeric
        # before kill so an empty/garbage value can't error under set -u.
        if printf '%s' "${T8_FAKE_CLAUDE_PID:-}" | grep -qE '^[1-9][0-9]*$'; then
            kill "$T8_FAKE_CLAUDE_PID" 2>/dev/null || true
        fi

        # F8 hygiene (same as T6): after teardown there must be NO
        # orch-heartbeat-daemon.sh process left for the T8 task-id.  Wait up
        # to ~3s for SIGHUP propagation, then check.  Grep per task-id so
        # unrelated daemons on the host do not pollute the assertion.
        sleep 2
        local residue
        residue="$(pgrep -f "orch-heartbeat-daemon.*runtime/$T8_TASK_ID" 2>/dev/null || true)"
        if [ -n "$residue" ]; then
            T8_FAIL "no orch-heartbeat-daemon.sh residue after teardown (F8) -- pids: '$residue'"
            # Don't pkill ourselves; F8 forbids it.  Leave for operator.
        else
            T8_PASS "no orch-heartbeat-daemon.sh residue after teardown (F8)"
        fi

        rm -rf "$T8_TMPROOT"
        T8_PASS "T8 fixture teardown clean"
    }
    # shellcheck disable=SC2064
    trap "t8_teardown" EXIT

    # --- Init the fixture git repo (the source-repo for this task) -------
    # NOTE: source-repo points at the fixture repo, NOT the plugin repo.
    # PLUGIN_ROOT derivation runs on EVERY spawn (spawn no longer has an
    # --auto-start block — it only builds the container; starting claude is the
    # L2 orch-driver-agent's job).  A spawn whose source-repo is not the plugin
    # repo therefore emits
    #   warn: PLUGIN_ROOT=... does not contain skills/execute-task
    # to STDERR.  That warn is EXPECTED and BENIGN here.  We capture stdout
    # and stderr SEPARATELY below so the warn never false-fails the test.
    mkdir -p "$WORK_DIR"
    (
        cd "$WORK_DIR" || exit 1
        git init -q . >/dev/null 2>&1
        git config user.email "t8@example.com"
        git config user.name "T8 Test"
        git checkout -q -b main 2>/dev/null || git checkout -q main
        echo "T8 initial (work)" >README.md
        git add README.md
        git commit -q -m "initial"
    ) || { T8_FAIL "git init in $WORK_DIR failed"; return; }

    # --- Build the master entry pointing at the fixture repo ------------
    mkdir -p "$LIST_DIR/tasks"
    {
        echo "---"
        echo "task-id: $TASK_ID"
        echo "project: t8-mock"
        echo "source-repo: $WORK_DIR"
        echo "state: ready"
        echo "priority: normal"
        echo "branch: task/$TASK_ID"
        echo "base: main"
        echo "worktree: $WORKTREE_DIR"
        echo "tmux-session: $TMUX_SESSION"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-21"
        echo "updated-at: 2026-06-21"
        echo "---"
        echo ""
        echo "# $TASK_ID (T8 mock)"
        echo ""
        echo "## Description"
        echo ""
        echo "T8 dispatch.md Phase-1 + archive lifecycle test."
    } >"$LIST_DIR/tasks/$TASK_ID.md"

    # --- Invoke spawn (2 args; spawn no longer has --auto-start) ---------
    # We unset CLAUDE_PLUGIN_ROOT in the spawn subshell so plugin-root is
    # derived deterministically from $SCRIPT_DIR/.. == repo root, regardless
    # of the caller's environment.  Invoke from $TMPROOT (not a git repo) to
    # mirror T6's cwd-independence posture.
    #
    # Capture stdout and stderr into SEPARATE files: the PLUGIN_ROOT warn
    # (expected/benign — see above) goes to stderr and must NOT be treated as
    # a failure.  We only gate on the EXIT CODE, never on stderr content.
    local spawn_out_file spawn_err_file spawn_rc
    spawn_out_file="$TMPROOT/spawn.out"
    spawn_err_file="$TMPROOT/spawn.err"
    (
        cd "$TMPROOT" || exit 99
        unset CLAUDE_PLUGIN_ROOT
        bash "$spawn" "$TASK_ID" "$LIST_DIR" </dev/null
    ) >"$spawn_out_file" 2>"$spawn_err_file"
    spawn_rc=$?

    if [ "$spawn_rc" -ne 0 ]; then
        T8_FAIL "orch-spawn-worker.sh ($TASK_ID) exited $spawn_rc (expected 0).  stdout:
$(sed 's/^/      | /' "$spawn_out_file" 2>/dev/null)
      stderr:
$(sed 's/^/      | /' "$spawn_err_file" 2>/dev/null)"
        # Continue to teardown; remaining a/d checks SKIP.
        local i
        for i in \
            "dispatch.md exists and is readable (a)" \
            "dispatch.md Phase-1 keys present and non-empty (a)" \
            "dispatch.md tmux-window-id / tmux-pane-id format (a)" \
            "dispatch.md shell-pid positive + alive (a)" \
            "dispatch.md worktree / source-repo absolute + exist (a)" \
            "dispatch.md encoded-cwd equals pwd -P of worktree (a)" \
            "dispatch.md plugin-root equals repo root (a)" \
            "dispatch.md Phase-2 fields empty (a)" \
            "Phase-2 lazy-fill bind / idempotency / re-bind (b/c/c2)" \
            "runtime/<task-id>/ gone after cleanup (d)" \
            "runtime/.archive/<task-id>-*/dispatch.md exists (d)" \
            "archived dispatch.md has same task-id: line (d)"
        do
            skip "T8 $i (skipped: spawn failed)"
        done
        return
    fi

    # =====================================================================
    # T8(a) — spawn writes Phase-1 fields
    # =====================================================================
    local DISPATCH="$LIST_DIR/runtime/$TASK_ID/dispatch.md"

    if [ -f "$DISPATCH" ] && [ -r "$DISPATCH" ]; then
        T8_PASS "dispatch.md exists and is readable (a)"
    else
        T8_FAIL "dispatch.md missing or unreadable: $DISPATCH (a)"
        # Without the file the rest of T8(a) cannot run; SKIP them, then go
        # straight to the T8(d) cleanup section (which has its own guards).
        local k
        for k in task-id spawn-iso tmux-session tmux-window-id tmux-pane-id \
                 shell-pid worktree source-repo branch base plugin-root encoded-cwd; do
            skip "T8 dispatch.md Phase-1 key $k non-empty (a) (skipped: dispatch.md absent)"
        done
        skip "T8 dispatch.md tmux-window-id matches ^@[0-9]+\$ (a) (skipped: dispatch.md absent)"
        skip "T8 dispatch.md tmux-pane-id matches ^%[0-9]+\$ (a) (skipped: dispatch.md absent)"
        skip "T8 dispatch.md shell-pid is a positive integer (a) (skipped: dispatch.md absent)"
        skip "T8 dispatch.md shell-pid process is alive (kill -0) (a) (skipped: dispatch.md absent)"
        skip "T8 dispatch.md worktree is an absolute path that exists (a) (skipped: dispatch.md absent)"
        skip "T8 dispatch.md source-repo is an absolute path that exists (a) (skipped: dispatch.md absent)"
        skip "T8 dispatch.md encoded-cwd equals pwd -P of worktree, / and . -> -, squeezed (a) (skipped: dispatch.md absent)"
        skip "T8 dispatch.md plugin-root equals repo root (CLAUDE_PLUGIN_ROOT unset) (a) (skipped: dispatch.md absent)"
        for k in claude-pid claude-session-id transcript-path first-seen-iso; do
            skip "T8 dispatch.md Phase-2 key $k empty (a) (skipped: dispatch.md absent)"
        done
        # Emit the b/c/c2 SKIP set (the phase2 section self-SKIPs all its
        # labels via its own dispatch.md-absent guard, keeping the count
        # stable with the happy path).
        t8_run_phase2_section
        # Fall through to T8(d): cleanup section guards on dir presence.
        t8_run_cleanup_section
        return
    fi

    # Small inline frontmatter extractor matching the scripts' fm_field
    # semantics: anchor on `^<key>:`, strip the leading whitespace from the
    # value, print only the value (empty string when the key has no value).
    # We keep it inline (not relying on a sourced helper) to match the
    # self-contained style of the existing test groups.
    #
    # ASSUMPTION (important for ST2 reuse): this extractor is correct ONLY for
    # the spawn/check-WRITTEN dispatch.md format — i.e. plain `key: value`
    # lines with NO `# inline comments`, NO quoted values, and NO key that is
    # a colon-prefix of another key.  The `^<key>:` anchor would mis-match if a
    # future schema added a prefix-colliding field (e.g. `claude` next to
    # `claude-pid`), and the value-trim does NOT unquote or strip comments the
    # way the scripts' richer fm_field() does.  All 16 current dispatch.md
    # fields satisfy these constraints, and spawn/check write the format
    # verbatim, so it is safe here.  ST2 should reuse THIS helper only against
    # spawn/check-written dispatch.md files — never against the
    # template/dispatch.md (which has comments + quoted placeholders) or any
    # hand-edited file.  Use the scripts' own fm_field() for the general case.
    t8_fm() {
        local file="$1" key="$2"
        awk -F': ' -v k="$key" '
            $0 ~ ("^" k ":") {
                v = substr($0, length(k) + 2)
                sub(/^[[:space:]]+/, "", v)
                sub(/[[:space:]]+$/, "", v)
                print v
                exit
            }
        ' "$file"
    }

    # ---- the 12 Phase-1 keys present and non-empty ----
    local key val
    for key in task-id spawn-iso tmux-session tmux-window-id tmux-pane-id \
               shell-pid worktree source-repo branch base plugin-root encoded-cwd; do
        val="$(t8_fm "$DISPATCH" "$key" 2>/dev/null || true)"
        if [ -n "$val" ]; then
            T8_PASS "dispatch.md Phase-1 key $key non-empty (a)"
        else
            T8_FAIL "dispatch.md Phase-1 key $key is EMPTY (a)"
        fi
    done

    # ---- tmux-window-id / tmux-pane-id format ----
    local win_id pane_id
    win_id="$(t8_fm "$DISPATCH" tmux-window-id 2>/dev/null || true)"
    pane_id="$(t8_fm "$DISPATCH" tmux-pane-id 2>/dev/null || true)"
    if printf '%s' "$win_id" | grep -qE '^@[0-9]+$'; then
        T8_PASS "dispatch.md tmux-window-id matches ^@[0-9]+\$ (a)"
    else
        T8_FAIL "dispatch.md tmux-window-id='$win_id' does not match ^@[0-9]+\$ (a)"
    fi
    if printf '%s' "$pane_id" | grep -qE '^%[0-9]+$'; then
        T8_PASS "dispatch.md tmux-pane-id matches ^%[0-9]+\$ (a)"
    else
        T8_FAIL "dispatch.md tmux-pane-id='$pane_id' does not match ^%[0-9]+\$ (a)"
    fi

    # ---- shell-pid is a positive integer and the process is alive ----
    local shell_pid
    shell_pid="$(t8_fm "$DISPATCH" shell-pid 2>/dev/null || true)"
    if printf '%s' "$shell_pid" | grep -qE '^[1-9][0-9]*$'; then
        T8_PASS "dispatch.md shell-pid is a positive integer (a)"
    else
        T8_FAIL "dispatch.md shell-pid='$shell_pid' is not a positive integer (a)"
    fi
    # kill -0 only meaningful for a syntactically valid pid; guard so an
    # invalid value above does not throw a bash syntax error under set -u.
    if printf '%s' "$shell_pid" | grep -qE '^[1-9][0-9]*$' && kill -0 "$shell_pid" 2>/dev/null; then
        T8_PASS "dispatch.md shell-pid process is alive (kill -0) (a)"
    else
        T8_FAIL "dispatch.md shell-pid='$shell_pid' process is NOT alive (kill -0 failed) (a)"
    fi

    # ---- worktree / source-repo are absolute paths that exist ----
    local wt sr
    wt="$(t8_fm "$DISPATCH" worktree 2>/dev/null || true)"
    sr="$(t8_fm "$DISPATCH" source-repo 2>/dev/null || true)"
    case "$wt" in
        /*) if [ -d "$wt" ]; then
                T8_PASS "dispatch.md worktree is an absolute path that exists (a)"
            else
                T8_FAIL "dispatch.md worktree='$wt' is absolute but does not exist (a)"
            fi ;;
        *)  T8_FAIL "dispatch.md worktree='$wt' is not an absolute path (a)" ;;
    esac
    case "$sr" in
        /*) if [ -d "$sr" ]; then
                T8_PASS "dispatch.md source-repo is an absolute path that exists (a)"
            else
                T8_FAIL "dispatch.md source-repo='$sr' is absolute but does not exist (a)"
            fi ;;
        *)  T8_FAIL "dispatch.md source-repo='$sr' is not an absolute path (a)" ;;
    esac

    # ---- encoded-cwd EXACTLY equals pwd -P of worktree, / and . -> -, squeezed
    # THIS IS THE KEY ASSERTION: it catches the macOS /var -> /private/var
    # symlink issue.  We recompute the expected value INDEPENDENTLY from the
    # recorded worktree value, using the same `cd && pwd -P | tr '/.' '--' |
    # tr -s '-'` idiom the spawn script uses to mirror Claude Code's
    # ~/.claude/projects/<dir> naming (both `/` and `.` -> `-`, then squeeze
    # consecutive `-`).  If spawn had used raw $WORKTREE instead of `pwd -P`,
    # the physical-path resolution diverges and this FAILS.
    #
    # REGRESSION GUARD (fix-encoded-cwd-transcript): the T8 temp worktree path
    # is an mktemp dir whose basename contains a `.` (e.g. zyz-orch-t8.Ur0RKX),
    # so this recomputation exercises the `.`-in-path case directly.  The old
    # rule (`tr / -`) preserved the `.` and produced a value the corrected
    # spawn no longer writes; this assertion passing IS the regression guard.
    local enc enc_expected
    enc="$(t8_fm "$DISPATCH" encoded-cwd 2>/dev/null || true)"
    enc_expected=""
    if [ -n "$wt" ] && [ -d "$wt" ]; then
        enc_expected="$(cd "$wt" && pwd -P | tr '/.' '--' | tr -s '-')"
    fi
    if [ -n "$enc" ] && [ -n "$enc_expected" ] && [ "$enc" = "$enc_expected" ]; then
        T8_PASS "dispatch.md encoded-cwd equals pwd -P of worktree, / and . -> -, squeezed (a)"
    else
        T8_FAIL "dispatch.md encoded-cwd='$enc' != expected '$enc_expected' (recomputed from worktree '$wt' via cd+pwd -P | tr '/.' '--' | tr -s '-') (a)"
    fi

    # ---- plugin-root equals repo root (CLAUDE_PLUGIN_ROOT was unset) ----
    # Spawn derives PLUGIN_ROOT from $SCRIPT_DIR/.. when CLAUDE_PLUGIN_ROOT
    # is unset; $SCRIPT_DIR is scripts/, so $SCRIPT_DIR/.. == repo root.
    # Compare physical forms on both sides to dodge any symlink delta.
    local pr pr_phys repo_phys
    pr="$(t8_fm "$DISPATCH" plugin-root 2>/dev/null || true)"
    pr_phys=""
    if [ -n "$pr" ] && [ -d "$pr" ]; then
        pr_phys="$(cd "$pr" && pwd -P)"
    fi
    repo_phys="$(cd "$REPO_ROOT" && pwd -P)"
    if [ -n "$pr_phys" ] && [ "$pr_phys" = "$repo_phys" ]; then
        T8_PASS "dispatch.md plugin-root equals repo root (CLAUDE_PLUGIN_ROOT unset) (a)"
    else
        T8_FAIL "dispatch.md plugin-root='$pr' (phys '$pr_phys') != repo root '$repo_phys' (a)"
    fi

    # ---- the 4 Phase-2 keys are all EMPTY at spawn time ----
    local p2
    for key in claude-pid claude-session-id transcript-path first-seen-iso; do
        p2="$(t8_fm "$DISPATCH" "$key" 2>/dev/null || true)"
        if [ -z "$p2" ]; then
            T8_PASS "dispatch.md Phase-2 key $key empty (a)"
        else
            T8_FAIL "dispatch.md Phase-2 key $key is NON-empty at spawn time ('$p2') (a)"
        fi
    done

    # =====================================================================
    # T8(b)/(c)/(c2) — Phase-2 lazy-fill in orch-check-worker.sh  (added ST2)
    # =====================================================================
    # IMPORTANT ORDERING: these run BEFORE the T8(d) cleanup section, because
    # cleanup ARCHIVES (mv's away) runtime/<task-id>/dispatch.md — after that
    # the check helper has nothing to bind against.  The design's Lifecycle
    # ordering is "spawn → check binds → cleanup archives", so we mirror it:
    # bind here, then run the cleanup section as the genuinely-last step.
    #
    # All three sub-cases share the same controlled $HOME, fake-claude child
    # process, and fixture session/project dirs, and they MUTATE shared state
    # in sequence (b binds → c proves idempotency on b's state → c2 clears the
    # fields and re-binds).  They are therefore implemented as one linear block
    # in dependency order, matching the design's "Continuation of …" phrasing.
    t8_run_phase2_section

    # =====================================================================
    # T8(d) — lifecycle through cleanup (archive, not delete)
    # =====================================================================
    t8_run_cleanup_section

    # Teardown trap runs the F8 daemon-residue check + tmproot cleanup.  Note:
    # the `exec -a claude sleep 600` child forked in T8(b) is a child of the
    # pane shell, so `tmux kill-session` in t8_teardown SIGHUPs and reaps it —
    # no separate kill needed (verified against the existing teardown).
}

# t8_run_phase2_section — T8(b)/(c)/(c2): drive orch-check-worker.sh's Phase-2
# lazy-fill against a controlled $HOME.  Reads the T8_* globals (so it can be
# called from run_T8 after the T8(a) happy path).  Requires that T8(a) produced
# a readable dispatch.md with populated Phase-1 fields — guarded below.
#
# SKIP semantics: if python3 is unavailable the check helper's Step B can never
# discover claude-session-id, so the whole trio never binds.  Per design we SKIP
# (not FAIL) every b/c/c2 assertion with the canonical message.
t8_run_phase2_section() {
    local check="$REPO_ROOT/scripts/orch-check-worker.sh"
    local LIST_DIR="$T8_LIST_DIR"
    local TASK_ID="$T8_TASK_ID"
    local TMUX_SESSION="$T8_TMUX_SESSION"
    local TMPROOT="$T8_TMPROOT"
    local DISPATCH="$LIST_DIR/runtime/$TASK_ID/dispatch.md"

    # Reuse the T8(a) inline frontmatter extractor.  t8_fm is defined inside
    # run_T8 (the happy path), which has already run by the time we get here.
    # It trims surrounding whitespace, so comparisons are byte-trailing-space
    # safe (the check helper writes empty fields as `key: ` with a trailing
    # space, spawn writes `key:` with none — t8_fm normalizes both).

    # ---- The full b/c/c2 assertion label list (for batch SKIP) ----------
    # Kept in one place so every early-return SKIP path emits the same set and
    # the operator's PASS/SKIP count stays stable regardless of which guard
    # fired.
    local b_c_c2_labels=(
        "check exits 0 with Phase-2 fixture (b)"
        "check stdout preserves legacy phase=/wait-state= lines in order (b)"
        "check stdout has dispatch-bound=true (b)"
        "dispatch.md claude-pid == forked child pid (b)"
        "dispatch.md claude-session-id == fake uuid (b)"
        "dispatch.md transcript-path == fixture jsonl path (b)"
        "dispatch.md first-seen-iso non-empty (b)"
        "## Recovery body has substituted 'claude --resume <uuid>' (b)"
        "## Recovery body has substituted 'tmux attach -t <session>' (b)"
        "## Recovery body has substituted transcript path (b)"
        "## Recovery body has NO literal angle-bracket placeholders (b)"
        "no-op poll leaves all 4 Phase-2 values unchanged (c)"
        "no-op poll leaves dispatch.md byte-identical (content hash) (c)"
        "external sessions json mutation ignored: claude-session-id unchanged (c)"
        "field-clear re-bind: claude-session-id == new uuid (c2)"
        "field-clear re-bind: transcript-path updated to new jsonl (c2)"
        "field-clear re-bind: first-seen-iso repopulated (c2)"
        "find-by-sid: transcript discovered under non-matching projects dir (c3)"
        "find-by-sid: dispatch-bound=true with mismatched encoded-cwd dir (c3)"
    )
    t8_skip_phase2() {
        # $1 = reason suffix appended to each label.
        local reason="$1" lbl
        for lbl in "${b_c_c2_labels[@]}"; do
            skip "T8 $lbl (skipped: $reason)"
        done
    }

    # ---- Guard: python3 required (design SKIP, not FAIL) ----------------
    if ! command -v python3 >/dev/null 2>&1; then
        t8_skip_phase2 "python3 unavailable; Phase-2 bind not testable"
        return
    fi

    # ---- Guard: T8(a) must have produced a usable dispatch.md ----------
    if [ ! -f "$DISPATCH" ] || [ ! -r "$DISPATCH" ]; then
        t8_skip_phase2 "dispatch.md absent/unreadable (T8(a) did not produce it)"
        return
    fi

    # ---- Pull the Phase-1 anchors we need from dispatch.md -------------
    local SHELL_PID ENCODED_CWD WORKTREE PLUGIN_ROOT
    SHELL_PID="$(t8_fm "$DISPATCH" shell-pid 2>/dev/null || true)"
    ENCODED_CWD="$(t8_fm "$DISPATCH" encoded-cwd 2>/dev/null || true)"
    WORKTREE="$(t8_fm "$DISPATCH" worktree 2>/dev/null || true)"
    PLUGIN_ROOT="$(t8_fm "$DISPATCH" plugin-root 2>/dev/null || true)"

    if ! printf '%s' "$SHELL_PID" | grep -qE '^[1-9][0-9]*$'; then
        t8_skip_phase2 "shell-pid='$SHELL_PID' not a valid pid (cannot fork fake claude)"
        return
    fi
    if [ -z "$ENCODED_CWD" ]; then
        t8_skip_phase2 "encoded-cwd empty (cannot place fixture transcript)"
        return
    fi

    # ---- Controlled HOME: stage fake ~/.claude trees inside the tmproot --
    # The check helper reads $HOME/.claude/sessions/<pid>.json and
    # $HOME/.claude/projects/<encoded-cwd>/<sid>.jsonl.  Point HOME at a temp
    # dir so we never touch the real ~/.claude.  pgrep is unaffected by HOME
    # (it queries the live process table), so the fake-claude child is still
    # discoverable.
    local FAKE_HOME="$TMPROOT/home"
    local SESS_DIR="$FAKE_HOME/.claude/sessions"
    local PROJ_DIR="$FAKE_HOME/.claude/projects/$ENCODED_CWD"
    mkdir -p "$SESS_DIR" "$PROJ_DIR"

    # ---- Fork a fake `claude` as a direct child of the pane shell -------
    # VERIFIED-CORRECT on Darwin 25.5.0 (design Fixture note): `exec -a claude
    # sleep 600 &` yields a process whose comm is `claude`, so
    # `pgrep -P <shell> -n -x claude` matches it.  A shebang shim or
    # `cp /bin/sleep claude` do NOT work (comm becomes /bin/sh or empty) — do
    # not substitute them.  The `&` backgrounds it so the pane shell stays
    # interactive; it is a direct child of $SHELL_PID.
    tmux send-keys -t "$TMUX_SESSION" "exec -a claude sleep 600 &" Enter 2>/dev/null || true

    # Give the shell a moment to fork the child and let pgrep's accounting
    # name settle.  Poll up to ~5s for robustness on a busy host.
    local FAKE_PID="" _try
    for _try in 1 2 3 4 5 6 7 8 9 10; do
        FAKE_PID="$(pgrep -P "$SHELL_PID" -n -x claude 2>/dev/null || true)"
        if [ -n "$FAKE_PID" ]; then
            break
        fi
        sleep 0.5
    done

    if ! printf '%s' "$FAKE_PID" | grep -qE '^[1-9][0-9]*$'; then
        # Could not produce a comm=claude child on this host.  This is the one
        # fixture-mechanic that the design flags as host-sensitive; treat as a
        # SKIP (the bind is genuinely not testable here), not a FAIL.
        t8_skip_phase2 "could not fork a comm=claude child of shell-pid=$SHELL_PID (exec -a claude unsupported on this host)"
        return
    fi

    # Record the forked child PID in a GLOBAL so t8_teardown can belt-and-
    # suspenders kill it.  Killing the tmux session already SIGHUPs and reaps
    # this child (it is a backgrounded direct child of the pane shell, same as
    # the heartbeat daemon), but an explicit `kill` in teardown guarantees no
    # stray 600s `sleep` survives even if SIGHUP propagation is flaky on the
    # host.
    T8_FAKE_CLAUDE_PID="$FAKE_PID"

    # ---- Fixed fake identifiers ----------------------------------------
    local FAKE_UUID="11111111-2222-3333-4444-555555555555"
    local WORKTREE_PHYS=""
    if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
        WORKTREE_PHYS="$(cd "$WORKTREE" && pwd -P)"
    else
        WORKTREE_PHYS="$WORKTREE"
    fi

    # Step 3: write the sessions pointer json keyed by the forked child pid.
    local POINTER="$SESS_DIR/$FAKE_PID.json"
    cat >"$POINTER" <<EOF
{"pid": $FAKE_PID, "sessionId": "$FAKE_UUID", "cwd": "$WORKTREE_PHYS"}
EOF

    # Step 4: write the transcript jsonl with one non-empty JSONL row.
    local TRANSCRIPT_FIXTURE="$PROJ_DIR/$FAKE_UUID.jsonl"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"t8 fixture row"}}' >"$TRANSCRIPT_FIXTURE"

    # =====================================================================
    # T8(b) — invoke check with the controlled HOME; assert the bind.
    # =====================================================================
    local b_out_file b_err_file b_out b_rc
    b_out_file="$TMPROOT/check-b.out"
    b_err_file="$TMPROOT/check-b.err"
    (
        cd "$TMPROOT" || exit 99
        HOME="$FAKE_HOME" bash "$check" "$TASK_ID" "$LIST_DIR" </dev/null
    ) >"$b_out_file" 2>"$b_err_file"
    b_rc=$?
    b_out="$(cat "$b_out_file" 2>/dev/null || true)"

    if [ "$b_rc" -eq 0 ]; then
        T8_PASS "check exits 0 with Phase-2 fixture (b)"
    else
        T8_FAIL "check exited $b_rc (expected 0) with Phase-2 fixture (b).  stdout:
$(sed 's/^/      | /' "$b_out_file" 2>/dev/null)
      stderr:
$(sed 's/^/      | /' "$b_err_file" 2>/dev/null)"
    fi

    # Legacy stdout lines still present, in their original relative order.  We
    # extract the keys-of-interest in emission order and compare to the
    # expected sequence (the new dispatch-bound line is additive AFTER
    # expected-resume-by and is checked separately).
    local legacy_order
    legacy_order="$(printf '%s\n' "$b_out" | grep -E '^(session-alive|heartbeat-status|heartbeat-mtime|phase|phase-since|wait-state|waiting-reason|expected-resume-by)=' | sed 's/=.*//' | tr '\n' ' ' | sed 's/ *$//')"
    local legacy_expected="session-alive heartbeat-status heartbeat-mtime phase phase-since wait-state waiting-reason expected-resume-by"
    if [ "$legacy_order" = "$legacy_expected" ]; then
        T8_PASS "check stdout preserves legacy phase=/wait-state= lines in order (b)"
    else
        T8_FAIL "check stdout legacy key order='$legacy_order' != expected='$legacy_expected' (b)"
    fi

    # New dispatch-bound=true line.
    if printf '%s\n' "$b_out" | grep -qx 'dispatch-bound=true'; then
        T8_PASS "check stdout has dispatch-bound=true (b)"
    else
        T8_FAIL "check stdout missing 'dispatch-bound=true'.  Full stdout:
$(printf '%s\n' "$b_out" | sed 's/^/      | /')  (b)"
    fi

    # dispatch.md Phase-2 fields are now populated.  Re-extract via t8_fm.
    local got_pid got_sid got_transcript got_first
    got_pid="$(t8_fm "$DISPATCH" claude-pid 2>/dev/null || true)"
    got_sid="$(t8_fm "$DISPATCH" claude-session-id 2>/dev/null || true)"
    got_transcript="$(t8_fm "$DISPATCH" transcript-path 2>/dev/null || true)"
    got_first="$(t8_fm "$DISPATCH" first-seen-iso 2>/dev/null || true)"

    if [ "$got_pid" = "$FAKE_PID" ]; then
        T8_PASS "dispatch.md claude-pid == forked child pid (b)"
    else
        T8_FAIL "dispatch.md claude-pid='$got_pid' != forked child pid '$FAKE_PID' (b)"
    fi
    if [ "$got_sid" = "$FAKE_UUID" ]; then
        T8_PASS "dispatch.md claude-session-id == fake uuid (b)"
    else
        T8_FAIL "dispatch.md claude-session-id='$got_sid' != fake uuid '$FAKE_UUID' (b)"
    fi
    if [ "$got_transcript" = "$TRANSCRIPT_FIXTURE" ]; then
        T8_PASS "dispatch.md transcript-path == fixture jsonl path (b)"
    else
        T8_FAIL "dispatch.md transcript-path='$got_transcript' != fixture '$TRANSCRIPT_FIXTURE' (b)"
    fi
    if [ -n "$got_first" ]; then
        T8_PASS "dispatch.md first-seen-iso non-empty (b)"
    else
        T8_FAIL "dispatch.md first-seen-iso is EMPTY after bind (b)"
    fi

    # ---- ## Recovery body: substituted (no angle brackets) -------------
    # Read everything after the `## Recovery` heading.  The body must contain
    # the CONCRETE substituted commands, not the `<…>` template tokens.
    local recovery_body
    recovery_body="$(awk '/^## Recovery$/{f=1; next} f' "$DISPATCH" 2>/dev/null || true)"

    if printf '%s\n' "$recovery_body" | grep -qF "claude --resume $FAKE_UUID --plugin-dir $PLUGIN_ROOT"; then
        T8_PASS "## Recovery body has substituted 'claude --resume <uuid>' (b)"
    else
        T8_FAIL "## Recovery body missing 'claude --resume $FAKE_UUID --plugin-dir $PLUGIN_ROOT'.  Body:
$(printf '%s\n' "$recovery_body" | sed 's/^/      | /')  (b)"
    fi
    if printf '%s\n' "$recovery_body" | grep -qF "tmux attach -t $TMUX_SESSION"; then
        T8_PASS "## Recovery body has substituted 'tmux attach -t <session>' (b)"
    else
        T8_FAIL "## Recovery body missing 'tmux attach -t $TMUX_SESSION'.  Body:
$(printf '%s\n' "$recovery_body" | sed 's/^/      | /')  (b)"
    fi
    if printf '%s\n' "$recovery_body" | grep -qF "$TRANSCRIPT_FIXTURE"; then
        T8_PASS "## Recovery body has substituted transcript path (b)"
    else
        T8_FAIL "## Recovery body missing transcript path '$TRANSCRIPT_FIXTURE'.  Body:
$(printf '%s\n' "$recovery_body" | sed 's/^/      | /')  (b)"
    fi
    # No leftover template angle-bracket tokens (e.g. <claude-session-id>,
    # <tmux-session>).  We look for the specific placeholder names the body
    # template would contain if substitution had not happened.
    if printf '%s\n' "$recovery_body" | grep -qE '<(claude-session-id|tmux-session|worktree|plugin-root|transcript-path|first-seen-iso)>'; then
        T8_FAIL "## Recovery body still contains literal <…> placeholder tokens (substitution did not fire).  Body:
$(printf '%s\n' "$recovery_body" | sed 's/^/      | /')  (b)"
    else
        T8_PASS "## Recovery body has NO literal angle-bracket placeholders (b)"
    fi

    # =====================================================================
    # T8(c) — idempotency under stable input (continues T8(b) state).
    # =====================================================================
    # Snapshot the 4 Phase-2 values and a content hash of dispatch.md BEFORE
    # the no-op poll.
    local pre_pid pre_sid pre_transcript pre_first pre_hash
    pre_pid="$got_pid"
    pre_sid="$got_sid"
    pre_transcript="$got_transcript"
    pre_first="$got_first"
    pre_hash="$(t8_content_hash "$DISPATCH")"

    sleep 1

    # The pure no-op poll: same fixture, no mutation.  The trio is already
    # populated, so NEEDS_REWRITE must stay false and dispatch.md must NOT be
    # rewritten.
    (
        cd "$TMPROOT" || exit 99
        HOME="$FAKE_HOME" bash "$check" "$TASK_ID" "$LIST_DIR" </dev/null
    ) >"$TMPROOT/check-c.out" 2>"$TMPROOT/check-c.err" || true

    local post_pid post_sid post_transcript post_first post_hash
    post_pid="$(t8_fm "$DISPATCH" claude-pid 2>/dev/null || true)"
    post_sid="$(t8_fm "$DISPATCH" claude-session-id 2>/dev/null || true)"
    post_transcript="$(t8_fm "$DISPATCH" transcript-path 2>/dev/null || true)"
    post_first="$(t8_fm "$DISPATCH" first-seen-iso 2>/dev/null || true)"
    post_hash="$(t8_content_hash "$DISPATCH")"

    if [ "$post_pid" = "$pre_pid" ] && [ "$post_sid" = "$pre_sid" ] \
        && [ "$post_transcript" = "$pre_transcript" ] && [ "$post_first" = "$pre_first" ]; then
        T8_PASS "no-op poll leaves all 4 Phase-2 values unchanged (c)"
    else
        T8_FAIL "no-op poll changed a Phase-2 value: pid '$pre_pid'->'$post_pid', sid '$pre_sid'->'$post_sid', transcript '$pre_transcript'->'$post_transcript', first '$pre_first'->'$post_first' (c)"
    fi

    if [ -z "$pre_hash" ] || [ -z "$post_hash" ]; then
        # No digest tool on this host (neither shasum nor sha256sum).  The
        # byte-identity check is not performable; SKIP rather than FAIL.
        skip "T8 no-op poll leaves dispatch.md byte-identical (content hash) (c) (skipped: no shasum/sha256sum on host)"
    elif [ "$post_hash" = "$pre_hash" ]; then
        T8_PASS "no-op poll leaves dispatch.md byte-identical (content hash) (c)"
    else
        T8_FAIL "no-op poll rewrote dispatch.md: pre-hash='$pre_hash' post-hash='$post_hash' (rewrite fired when nothing was new) (c)"
    fi

    # ---- External mutation of the sessions json is ignored (idempotency) -
    # Change the stored sessionId in the pointer json to a DIFFERENT value.
    # Because dispatch.md already has a non-empty claude-session-id, Step B is
    # short-circuited and the external mutation must be ignored.
    local OTHER_UUID="99999999-8888-7777-6666-555555555555"
    cat >"$POINTER" <<EOF
{"pid": $FAKE_PID, "sessionId": "$OTHER_UUID", "cwd": "$WORKTREE_PHYS"}
EOF
    (
        cd "$TMPROOT" || exit 99
        HOME="$FAKE_HOME" bash "$check" "$TASK_ID" "$LIST_DIR" </dev/null
    ) >"$TMPROOT/check-c2mut.out" 2>"$TMPROOT/check-c2mut.err" || true

    local after_mut_sid
    after_mut_sid="$(t8_fm "$DISPATCH" claude-session-id 2>/dev/null || true)"
    if [ "$after_mut_sid" = "$FAKE_UUID" ]; then
        T8_PASS "external sessions json mutation ignored: claude-session-id unchanged (c)"
    else
        T8_FAIL "external sessions json mutation NOT ignored: claude-session-id='$after_mut_sid' (expected unchanged '$FAKE_UUID'; idempotency short-circuit failed) (c)"
    fi

    # =====================================================================
    # T8(c2) — manual re-bind via field-clear (continues).
    # =====================================================================
    # Clear the 4 Phase-2 fields in dispatch.md while preserving Phase-1.  We
    # rewrite only the four `claude-pid:` / `claude-session-id:` /
    # `transcript-path:` / `first-seen-iso:` lines to empty (value removed),
    # leaving every other line — including the whole Phase-1 block and body —
    # untouched.  Use a temp file + mv to avoid a partial in-place edit.
    local cleared_tmp="$DISPATCH.t8clear.$$"
    awk '
        /^claude-pid:/        { print "claude-pid:";        next }
        /^claude-session-id:/ { print "claude-session-id:"; next }
        /^transcript-path:/   { print "transcript-path:";   next }
        /^first-seen-iso:/    { print "first-seen-iso:";    next }
        { print }
    ' "$DISPATCH" >"$cleared_tmp" 2>/dev/null && mv -f "$cleared_tmp" "$DISPATCH"

    # Point the pointer json at a NEW sessionId and create its transcript.  The
    # forked child pid is unchanged (still alive), so Step A re-discovers the
    # same claude-pid, Step B reads the NEW sessionId, Step C finds the new
    # transcript.
    local NEW_UUID="abababab-cdcd-efef-0101-232323232323"
    cat >"$POINTER" <<EOF
{"pid": $FAKE_PID, "sessionId": "$NEW_UUID", "cwd": "$WORKTREE_PHYS"}
EOF
    local NEW_TRANSCRIPT="$PROJ_DIR/$NEW_UUID.jsonl"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"t8 c2 rebind row"}}' >"$NEW_TRANSCRIPT"

    (
        cd "$TMPROOT" || exit 99
        HOME="$FAKE_HOME" bash "$check" "$TASK_ID" "$LIST_DIR" </dev/null
    ) >"$TMPROOT/check-c2.out" 2>"$TMPROOT/check-c2.err" || true

    local rb_sid rb_transcript rb_first
    rb_sid="$(t8_fm "$DISPATCH" claude-session-id 2>/dev/null || true)"
    rb_transcript="$(t8_fm "$DISPATCH" transcript-path 2>/dev/null || true)"
    rb_first="$(t8_fm "$DISPATCH" first-seen-iso 2>/dev/null || true)"

    if [ "$rb_sid" = "$NEW_UUID" ]; then
        T8_PASS "field-clear re-bind: claude-session-id == new uuid (c2)"
    else
        T8_FAIL "field-clear re-bind: claude-session-id='$rb_sid' != new uuid '$NEW_UUID' (re-bind did not fire) (c2)"
    fi
    if [ "$rb_transcript" = "$NEW_TRANSCRIPT" ]; then
        T8_PASS "field-clear re-bind: transcript-path updated to new jsonl (c2)"
    else
        T8_FAIL "field-clear re-bind: transcript-path='$rb_transcript' != new '$NEW_TRANSCRIPT' (c2)"
    fi
    if [ -n "$rb_first" ]; then
        T8_PASS "field-clear re-bind: first-seen-iso repopulated (c2)"
    else
        T8_FAIL "field-clear re-bind: first-seen-iso is EMPTY after re-bind (c2)"
    fi

    # =====================================================================
    # T8(c3) — find-by-session-id regression guard (fix-encoded-cwd-transcript).
    # =====================================================================
    # THE BUG: orch-check-worker.sh Step C used to RECONSTRUCT the transcript
    # path from the dispatch.md encoded-cwd field
    # ($HOME/.claude/projects/<encoded-cwd>/<sid>.jsonl).  For any worktree path
    # containing a `.` the recorded encoded-cwd diverged from claude's actual
    # project-dir name (claude squeezes `.`/`/` to a single `-`), so the lookup
    # landed in the wrong directory, never found the JSONL, and dispatch-bound
    # stayed false forever.
    #
    # THE FIX: Step C now discovers the transcript BY SESSION-ID
    # (`find "$HOME/.claude/projects" -name "<sid>.jsonl"`), which is robust no
    # matter how claude encodes the directory name.
    #
    # THIS CASE proves the fix: we clear the Phase-2 fields, point the pointer
    # json at a fresh sid, and place that sid's transcript under a projects
    # subdir whose name is DELIBERATELY DIFFERENT from the dispatch.md
    # encoded-cwd field.  If discovery still depended on encoded-cwd the helper
    # would miss it and never bind.  With find-by-sid it MUST still discover the
    # file and bind.  The sid is a fresh unique UUID, so there is exactly one
    # `<sid>.jsonl` anywhere under the temp $FAKE_HOME/.claude/projects tree and
    # the helper's `find ... | head -1` is unambiguous.
    #
    # Clear the 4 Phase-2 fields again (same idiom as c2) so the check helper
    # re-runs Step C from scratch.
    local cleared_tmp3="$DISPATCH.t8clear3.$$"
    awk '
        /^claude-pid:/        { print "claude-pid:";        next }
        /^claude-session-id:/ { print "claude-session-id:"; next }
        /^transcript-path:/   { print "transcript-path:";   next }
        /^first-seen-iso:/    { print "first-seen-iso:";    next }
        { print }
    ' "$DISPATCH" >"$cleared_tmp3" 2>/dev/null && mv -f "$cleared_tmp3" "$DISPATCH"

    # A projects subdir whose name does NOT match $ENCODED_CWD.  Using a literal
    # sentinel name makes the mismatch obvious and guarantees it differs from any
    # real encoded-cwd (which is always an absolute-path-derived dash string).
    local MISMATCH_DIRNAME="deliberately-not-the-encoded-cwd-dir"
    local MISMATCH_PROJ_DIR="$FAKE_HOME/.claude/projects/$MISMATCH_DIRNAME"
    mkdir -p "$MISMATCH_PROJ_DIR"

    # Fresh, unique UUID so its basename is globally unique under the temp
    # projects tree — the helper's `find -name "<sid>.jsonl" | head -1` lands on
    # exactly this file regardless of traversal order.
    local SID_C3="c3c3c3c3-dddd-eeee-ffff-010101010101"
    cat >"$POINTER" <<EOF
{"pid": $FAKE_PID, "sessionId": "$SID_C3", "cwd": "$WORKTREE_PHYS"}
EOF
    local TRANSCRIPT_C3="$MISMATCH_PROJ_DIR/$SID_C3.jsonl"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"t8 c3 find-by-sid row"}}' >"$TRANSCRIPT_C3"

    local c3_out_file c3_err_file c3_out c3_rc
    c3_out_file="$TMPROOT/check-c3.out"
    c3_err_file="$TMPROOT/check-c3.err"
    (
        cd "$TMPROOT" || exit 99
        HOME="$FAKE_HOME" bash "$check" "$TASK_ID" "$LIST_DIR" </dev/null
    ) >"$c3_out_file" 2>"$c3_err_file"
    c3_rc=$?
    c3_out="$(cat "$c3_out_file" 2>/dev/null || true)"

    local c3_transcript
    c3_transcript="$(t8_fm "$DISPATCH" transcript-path 2>/dev/null || true)"

    # (1) The transcript was discovered under the NON-matching projects dir,
    #     proving discovery is by session-id, not by encoded-cwd reconstruction.
    if [ "$c3_transcript" = "$TRANSCRIPT_C3" ]; then
        T8_PASS "find-by-sid: transcript discovered under non-matching projects dir (c3)"
    else
        T8_FAIL "find-by-sid: transcript-path='$c3_transcript' != expected '$TRANSCRIPT_C3' (check exit=$c3_rc; helper did not find the JSONL by session-id under a dir whose name != encoded-cwd).  stderr:
$(sed 's/^/      | /' "$c3_err_file" 2>/dev/null)  (c3)"
    fi

    # (2) The trio completed and the helper reports dispatch-bound=true even
    #     though the projects subdir name does not match dispatch.md encoded-cwd.
    if printf '%s\n' "$c3_out" | grep -qx 'dispatch-bound=true'; then
        T8_PASS "find-by-sid: dispatch-bound=true with mismatched encoded-cwd dir (c3)"
    else
        T8_FAIL "find-by-sid: missing 'dispatch-bound=true' after placing transcript under a non-matching projects dir (check exit=$c3_rc).  Full stdout:
$(printf '%s\n' "$c3_out" | sed 's/^/      | /')  (c3)"
    fi
}

# t8_content_hash <file> — emit a content hash of the file using whichever
# digest tool the host has (shasum on macOS, sha256sum on most Linux).  Prints
# just the hex digest (first field) or empty if no tool is available.  Used by
# T8(c) to prove the no-op poll did not rewrite dispatch.md (content equality is
# more robust than mtime, which has 1s granularity on some macOS volumes).
t8_content_hash() {
    local f="$1"
    [ -f "$f" ] || { printf ''; return 0; }
    if command -v shasum >/dev/null 2>&1; then
        shasum "$f" 2>/dev/null | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" 2>/dev/null | awk '{print $1}'
    else
        printf ''
    fi
}

# t8_run_cleanup_section — T8(d): invoke cleanup --force and assert the
# runtime dir is archived (moved, not deleted).  Reads the T8_* globals so it
# can be called from either the happy path or the dispatch.md-absent fallback
# above.  Captures stdout/stderr separately (cleanup is quiet, but be
# consistent with the spawn invocation).
t8_run_cleanup_section() {
    local cleanup="$REPO_ROOT/scripts/orch-cleanup-worker.sh"
    local LIST_DIR="$T8_LIST_DIR"
    local TASK_ID="$T8_TASK_ID"
    local TMPROOT="$T8_TMPROOT"

    local DISPATCH="$LIST_DIR/runtime/$TASK_ID/dispatch.md"
    local RUNTIME_DIR="$LIST_DIR/runtime/$TASK_ID"

    # Capture the original task-id: frontmatter line (if dispatch.md is
    # present) so we can compare it against the archived copy after the move.
    local orig_taskid_line=""
    if [ -f "$DISPATCH" ]; then
        orig_taskid_line="$(grep -m1 '^task-id:' "$DISPATCH" 2>/dev/null || true)"
    fi

    # Cleanup REQUIRES --force to actually archive; without it the script is a
    # dry-run that leaves runtime/<task-id>/ in place (see
    # orch-cleanup-worker.sh).  Capture stdout/stderr separately and gate on
    # the exit code only.
    local cleanup_out_file cleanup_err_file cleanup_rc
    cleanup_out_file="$TMPROOT/cleanup.out"
    cleanup_err_file="$TMPROOT/cleanup.err"
    (
        cd "$TMPROOT" || exit 99
        bash "$cleanup" "$TASK_ID" "$LIST_DIR" --force </dev/null
    ) >"$cleanup_out_file" 2>"$cleanup_err_file"
    cleanup_rc=$?

    if [ "$cleanup_rc" -ne 0 ]; then
        T8_FAIL "orch-cleanup-worker.sh --force ($TASK_ID) exited $cleanup_rc (expected 0).  stdout:
$(sed 's/^/      | /' "$cleanup_out_file" 2>/dev/null)
      stderr:
$(sed 's/^/      | /' "$cleanup_err_file" 2>/dev/null)"
        skip "T8 runtime/<task-id>/ gone after cleanup --force (d) (skipped: cleanup failed)"
        skip "T8 runtime/.archive/<task-id>-*/dispatch.md exists after cleanup (d) (skipped: cleanup failed)"
        skip "T8 archived dispatch.md has same task-id: line as original (d) (skipped: cleanup failed)"
        return
    fi

    # runtime/<task-id>/ must be GONE (moved, not copied).
    if [ ! -e "$RUNTIME_DIR" ]; then
        T8_PASS "runtime/<task-id>/ gone after cleanup --force (d)"
    else
        T8_FAIL "runtime/<task-id>/ still present after cleanup --force: $RUNTIME_DIR (d)"
    fi

    # runtime/.archive/<task-id>-*/dispatch.md must EXIST (archived, not
    # deleted).  The cleanup script names the archive dir
    # <task-id>-<YYYYmmdd-HHMMSS>; glob for it.  Under set -u with a
    # non-matching glob the literal pattern survives, so guard with -f.
    local archived_dispatch="" candidate
    for candidate in "$LIST_DIR"/runtime/.archive/"$TASK_ID"-*/dispatch.md; do
        if [ -f "$candidate" ]; then
            archived_dispatch="$candidate"
            break
        fi
    done
    if [ -n "$archived_dispatch" ]; then
        T8_PASS "runtime/.archive/<task-id>-*/dispatch.md exists after cleanup (d)"
    else
        T8_FAIL "no runtime/.archive/$TASK_ID-*/dispatch.md found after cleanup (archive missing — cleanup deleted instead of archived?) (d)"
    fi

    # The archived dispatch.md must carry the same task-id: line as the
    # original (proves it is the same file, moved intact).
    if [ -n "$archived_dispatch" ] && [ -f "$archived_dispatch" ]; then
        local archived_taskid_line
        archived_taskid_line="$(grep -m1 '^task-id:' "$archived_dispatch" 2>/dev/null || true)"
        if [ -n "$orig_taskid_line" ] && [ "$archived_taskid_line" = "$orig_taskid_line" ]; then
            T8_PASS "archived dispatch.md has same task-id: line as original (d)"
        else
            T8_FAIL "archived dispatch.md task-id line='$archived_taskid_line' != original='$orig_taskid_line' (d)"
        fi
    else
        skip "T8 archived dispatch.md has same task-id: line as original (d) (skipped: archive copy absent)"
    fi
}

# ---------------------------------------------------------------------------
# T7. README / CLAUDE.md / project-structure.md key strings
# ---------------------------------------------------------------------------
run_T7() {
    say_header "T7  README / CLAUDE.md / project-structure.md key strings"

    # README.md must mention orchestration-scheduling-task somewhere.
    check_grep_fixed "README.md" "'orchestration-scheduling-task'" "orchestration-scheduling-task"

    # README.md「当前状态」段 must mention commands/orchestrate-tasks.md or
    # the bare 'orchestrate-tasks' command name.  We accept either.
    local readme="$REPO_ROOT/README.md"
    if [ ! -f "$readme" ]; then
        fail "T7 README.md missing"
    else
        if grep -qF "commands/orchestrate-tasks.md" "$readme" \
            || grep -qF "orchestrate-tasks" "$readme"; then
            pass "T7 README.md references orchestrate-tasks"
        else
            fail "T7 README.md does not mention commands/orchestrate-tasks.md nor 'orchestrate-tasks'"
        fi
    fi

    # CLAUDE.md must contain the workflow heading (or equivalent).  Design
    # §测试计划 T7: "CLAUDE.md 含 ## Orchestration Scheduling Task Workflow
    # 或等价标题".
    if grep -F "Orchestration Scheduling Task Workflow" "$REPO_ROOT/CLAUDE.md" >/dev/null 2>&1; then
        pass "T7 CLAUDE.md contains '## Orchestration Scheduling Task Workflow'"
    else
        fail "T7 CLAUDE.md missing 'Orchestration Scheduling Task Workflow' heading"
    fi

    # docs/conventions/project-structure.md must mention scripts/orch-*.sh
    # (or at minimum the 'scripts/orch-' prefix).
    local ps="$REPO_ROOT/docs/conventions/project-structure.md"
    if [ ! -f "$ps" ]; then
        fail "T7 docs/conventions/project-structure.md missing"
    else
        if grep -qF "scripts/orch-*.sh" "$ps" \
            || grep -qF "scripts/orch-" "$ps"; then
            pass "T7 project-structure.md references scripts/orch-*.sh"
        else
            fail "T7 project-structure.md does not mention 'scripts/orch-*.sh' or 'scripts/orch-'"
        fi

        # ... and <list-dir>/runtime/ (or just 'runtime/').
        if grep -qF "<list-dir>/runtime/" "$ps" \
            || grep -qF "runtime/" "$ps"; then
            pass "T7 project-structure.md references <list-dir>/runtime/"
        else
            fail "T7 project-structure.md does not mention '<list-dir>/runtime/' or 'runtime/'"
        fi
    fi

    # ---- T7' (stage C orchestration-source-repo) ------------------------
    # README.md must mention `source-repo` AND mention the multi-project
    # use case (either "多项目" or "multi-project") — per design §E and
    # Testing Plan §T7'.  We do not require the two strings on the same
    # line; documenting in the same file is sufficient.
    if [ -f "$readme" ]; then
        if grep -qF "source-repo" "$readme"; then
            pass "T7' README.md mentions 'source-repo'"
        else
            fail "T7' README.md does not mention 'source-repo'"
        fi
        if grep -qF "多项目" "$readme" || grep -qF "multi-project" "$readme"; then
            pass "T7' README.md mentions '多项目' or 'multi-project'"
        else
            fail "T7' README.md mentions neither '多项目' nor 'multi-project'"
        fi
    fi

    # ---- T7'' (orchestration-layered-architecture ST-F / ST-E) ----------
    # The layered (L1/L2/L3) redesign adds load-bearing strings to SKILL.md
    # (ST-F) and main-agent.md (ST-E).  Per design §Testing Plan ("T7 字符串:
    # SKILL.md 含层级图关键串、三层职责、driver/monitor 字样、notify 签名扩展点、
    # max-parallel -1 资源提醒").  These are positive literal anchors the
    # grep-based suite pins so future edits cannot silently drop them.

    # (A) SKILL.md load-bearing strings.
    local skill_md="skills/orchestration-scheduling-task/SKILL.md"
    check_grep "$skill_md" "T7'' SKILL.md '## Architecture' 3-layer section heading" \
        '^## Architecture'
    check_grep_fixed "$skill_md" "T7'' SKILL.md references 'orch-driver-agent' (L2 driver)" \
        "orch-driver-agent"
    check_grep_fixed "$skill_md" "T7'' SKILL.md mentions 'monitor' (driver-state / File Protocols row)" \
        "monitor"
    # max-parallel -1 unlimited + resource caveat wording.
    check_grep_fixed "$skill_md" "T7'' SKILL.md 'ZYZ_MAX_PARALLEL_WORKERS' parallel cap" \
        "ZYZ_MAX_PARALLEL_WORKERS"
    check_grep_fixed "$skill_md" "T7'' SKILL.md default '-1' unlimited semantics" \
        "-1"
    check_grep_fixed "$skill_md" "T7'' SKILL.md 'unlimited' wording for the -1 default" \
        "unlimited"
    check_grep_fixed "$skill_md" "T7'' SKILL.md resource caveat (per-worker = full claude process)" \
        "Resource caveat"
    # notify structured signature (future-webhook extension point).
    check_grep_fixed "$skill_md" "T7'' SKILL.md notify signature '(task-id, window, reason'" \
        "(task-id, window, reason"

    # (B) main-agent.md load-bearing strings.
    local main_md="skills/orchestration-scheduling-task/prompts/main-agent.md"
    check_grep_fixed "$main_md" "T7'' main-agent.md 'intent=first-dispatch'" \
        "intent=first-dispatch"
    check_grep_fixed "$main_md" "T7'' main-agent.md 'intent=intervene'" \
        "intent=intervene"
    check_grep "$main_md" "T7'' main-agent.md '### intervene' step heading" \
        '^### intervene([[:space:]]|$)'
    check_grep "$main_md" "T7'' main-agent.md '### throttle' step heading" \
        '^### throttle([[:space:]]|$)'
    check_grep "$main_md" "T7'' main-agent.md '### notify' step heading" \
        '^### notify([[:space:]]|$)'
    check_grep_fixed "$main_md" "T7'' main-agent.md 'default -1' parallel-cap default" \
        "default -1"
    # main-agent.md must NOT carry the removed auto-start env var, nor the stale
    # "let the user attach to manually start claude" dispatch instruction
    # (Finding 8: L2 starts claude now; ST-E deleted both).  We forbid the
    # removed env var outright, and forbid the specific stale phrasing.
    check_grep_absent "$main_md" "T7'' main-agent.md 'ZYZ_AUTO_START_WORKER' (removed env var)" \
        "ZYZ_AUTO_START_WORKER"
    check_grep_absent "$main_md" "T7'' main-agent.md stale 'manually start' claude instruction" \
        "manually start"
}

# ---------------------------------------------------------------------------
# T9. orch-driver-agent send-spelling guard (fix-worker-slashcmd, Change 3).
#
# Deterministic (no API / no tmux / no claude) regression guard that locks the
# slash-command spelling the L2 driver sends into the worker pane.  Background:
# in current Claude Code, plugin commands register namespaced-only
# (`/zyz-worker:execute-task`); the bare `/execute-task` does NOT resolve
# because `execute-task` also exists as a skill (name collision).  So both
# driver mirror copies MUST send the namespaced spelling.
#
# For BOTH agents/orch-driver-agent.md and subagents/orch-driver-agent.md:
#   (a) PRESENT: the backtick-wrapped namespaced send token
#         `/zyz-worker:execute-task <task-id>`
#   (b) ABSENT:  the backtick-wrapped BARE send token
#         `/execute-task <task-id>`
#       The `<task-id>`-adjacent anchor is what distinguishes a *send
#       instruction* from retained bare diagnostic prose (e.g.
#       "the `/execute-task` slash command was rejected", "an already-running
#       `/zyz-worker:execute-task`").  Those keep the bare `/execute-task`
#       WITHOUT an adjacent ` <task-id>`, so this anchor does not flag them.
#       (Decision: design review finding F1.)
#   (c) MIRROR byte-equality: the "Send the command" step line must be
#       byte-identical between the two files, so one mirror cannot be fixed
#       while the other is missed (design review Suggestion).
#
# All matching is fixed-string (`grep -F`) to avoid brittle whitespace/regex
# assumptions.  NOTE (design Risk F7): the namespaced literal below is coupled
# to plugin.json `name: zyz-worker`; a future plugin rename must update this
# guard in lockstep with both driver files.
# ---------------------------------------------------------------------------
run_T9() {
    say_header "T9  orch-driver-agent send-spelling guard (fix-worker-slashcmd)"

    local drv_agent="agents/orch-driver-agent.md"
    local drv_sub="subagents/orch-driver-agent.md"

    # Exact backtick-wrapped anchors (fixed strings — NOT regex).
    local present_token='`/zyz-worker:execute-task <task-id>`'
    local absent_token='`/execute-task <task-id>`'

    # (a) + (b): per-file present / absent assertions.
    local f
    for f in "$drv_agent" "$drv_sub"; do
        check_grep_fixed "$f" \
            "T9 namespaced send token '$present_token'" \
            "$present_token"
        check_grep_absent "$f" \
            "T9 bare send token '$absent_token' (must not regress to bare /execute-task)" \
            "$absent_token"
    done

    # (c) MIRROR byte-equality of the "Send the command" step line.
    #
    # The send-step line is the ONE line in each file that carries the literal
    # "**Send the command.**" anchor; it also carries the namespaced send token.
    # We pull that single line from each file with `grep -F` on the anchor and
    # assert the two are byte-identical.  Anchoring on "**Send the command.**"
    # (rather than the namespaced token, which also appears on the intervene
    # re-send line) guarantees exactly one line is extracted per file.
    local send_anchor='**Send the command.**'
    if [ ! -f "$REPO_ROOT/$drv_agent" ] || [ ! -f "$REPO_ROOT/$drv_sub" ]; then
        fail "T9 mirror send-line byte-equality (one or both driver files missing: $drv_agent / $drv_sub)"
    else
        local line_agent line_sub
        line_agent="$(grep -F -- "$send_anchor" "$REPO_ROOT/$drv_agent" 2>/dev/null || true)"
        line_sub="$(grep -F -- "$send_anchor" "$REPO_ROOT/$drv_sub" 2>/dev/null || true)"
        if [ -z "$line_agent" ] || [ -z "$line_sub" ]; then
            fail "T9 mirror send-line byte-equality: '$send_anchor' line not found in $drv_agent (got '$line_agent') and/or $drv_sub (got '$line_sub')"
        elif [ "$line_agent" = "$line_sub" ]; then
            pass "T9 mirror send-line byte-equality (agents/ and subagents/ 'Send the command' lines identical)"
        else
            fail "T9 mirror send-line DRIFT between $drv_agent and $drv_sub:
      | agents/    : $line_agent
      | subagents/ : $line_sub"
        fi
    fi

    # ---- B8 (0.6.5 confirmation/done state-model fix, design F7): the new L2
    #      driver intent `relay-confirmation` must be present in BOTH driver
    #      mirror copies.  This is the presence half of the F7 double-safety
    #      (the body-diff half is in T10, which extends the mirror guard to the
    #      driver pair).  `relay-confirmation` does not exist in the tree before
    #      this change, so a bare presence check per file is already
    #      discriminating; pinning BOTH copies ensures one mirror cannot gain
    #      the intent while the other is missed.
    local drvf
    for drvf in "$drv_agent" "$drv_sub"; do
        check_grep_fixed "$drvf" \
            "B8 driver intent 'relay-confirmation' present in $drvf" \
            "relay-confirmation"
    done
}

# ---------------------------------------------------------------------------
# T10. agents/ <-> subagents/ mirror body-equality guard (test-gate ST, S1).
#
# The execute-task subagent role prompts live in TWO places that must stay in
# sync: the canonical Claude Code subagent copies under agents/ (which carry a
# leading `---\nname: ...\n---` YAML frontmatter block) and the legacy mirrors
# under subagents/ (which are frontmatter-free, starting directly with a `# `
# heading).  Per design-test-gate.md §guard 测试 (S1): there was NO test
# asserting these two pairs stay body-identical, so a mirror bullet added on
# one side (e.g. the new aggregate-testing registration responsibility on
# implementation-agent, or the new four-category review standard on
# review-agent) could silently drift on the other.  This guard closes that gap.
#
# Method (mirrors the test-rename-and-conventions.sh T5 `diff <(grep -v ...)`
# precedent, which we may not edit there — so it is implemented here):
#   1. strip_frontmatter() removes the agents/ file's leading `---`...`---`
#      YAML block, leaving the body.
#   2. The subagents/ mirror is frontmatter-free (verified by reading both
#      files), so its body starts immediately — no stripping needed there.
#   3. TWO intentional, known body divergences exist between the stripped
#      agents/ body and the subagents/ body, BOTH predating the test-gate
#      change and NEITHER part of the mirrored responsibility/standard bullets:
#        (i)  a LEADING BLANK LINE: after the agents/ frontmatter fence there is
#             a blank line before the `# ...Agent Prompt` heading, whereas the
#             subagents/ files start directly with that heading.  strip_frontmatter
#             removes only the `---`...`---` block, so that blank survives.
#        (ii) the intro sentence:
#               agents/    : "You are <role> for the zyz-worker execute-task workflow."
#               subagents/ : "You are <role> for the execute-task skill."
#      Like T5's `grep -v '^description:'` filter, t10_normalize_body() collapses
#      BOTH of these away IDENTICALLY on each side (drop leading blank lines, then
#      canonicalize the role-intro line) before diffing — so the guard is green on
#      a correct baseline while still failing loudly if ANY OTHER line — including
#      the newly added mirror bullets — drifts.
# ---------------------------------------------------------------------------

# strip_frontmatter <file>
# Prints <file> with a leading YAML frontmatter block removed (if present).
# A frontmatter block is the first `---`...`---` fence starting at line 1; the
# fence lines themselves and everything between them are dropped, the body that
# follows is printed verbatim.  A file with no leading `---` is printed as-is.
strip_frontmatter() {
    awk '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---"  { infm=0; next }
        !infm              { print }
    ' "$1"
}

# t10_normalize_body  (stdin -> stdout)
# Canonicalizes the TWO known-divergent aspects so the agents/ (frontmatter-
# stripped) and subagents/ bodies compare equal where they are intentionally
# allowed to differ, while every OTHER line must still match byte for byte:
#   (i)  drop LEADING blank lines.  `sed '/./,$!d'` deletes lines from the start
#        of input up to (but not including) the first line containing any
#        non-blank character — i.e. it trims a leading run of blank lines and
#        leaves the rest untouched.  This erases the blank line that survives
#        after the agents/ frontmatter fence (subagents/ has none).
#   (ii) canonicalize the role-intro line.  Both phrasings start with
#        "You are <Role> for the " and end differently ("zyz-worker execute-task
#        workflow." vs "execute-task skill."); collapse the whole line to a fixed
#        sentinel.
# Applied IDENTICALLY to both sides; this is the only normalization.
t10_normalize_body() {
    sed '/./,$!d' \
        | sed -E 's/^You are .* for the (zyz-worker execute-task workflow|execute-task skill)\.$/You are <ROLE> for the execute-task workflow./'
}

# t10_mirror_diff <agents-relpath> <subagents-relpath> <label>
# Strips the agents/ frontmatter, normalizes both known baseline divergences on
# both sides, and diffs the result.  PASS if identical, FAIL (printing the diff)
# otherwise.
t10_mirror_diff() {
    local agent_rel="$1"
    local sub_rel="$2"
    local label="$3"
    local agent_abs="$REPO_ROOT/$agent_rel"
    local sub_abs="$REPO_ROOT/$sub_rel"

    if [ ! -f "$agent_abs" ] || [ ! -f "$sub_abs" ]; then
        fail "T10 $label mirror body-equality (one or both files missing: $agent_rel / $sub_rel)"
        return
    fi

    local diff_out
    diff_out="$(
        diff \
            <(strip_frontmatter "$agent_abs" | t10_normalize_body) \
            <(t10_normalize_body <"$sub_abs")
    )"
    if [ -z "$diff_out" ]; then
        pass "T10 $agent_rel and $sub_rel bodies are byte-identical (mirror drift guard)"
    else
        fail "T10 $agent_rel and $sub_rel mirror bodies DIVERGED (outside the role-intro / leading-blank normalization):
$(printf '%s\n' "$diff_out" | sed 's/^/      | /')"
    fi
}

run_T10() {
    say_header "T10  agents/ <-> subagents/ mirror body-equality (test-gate S1)"

    t10_mirror_diff "agents/implementation-agent.md" \
                    "subagents/implementation-agent.md" \
                    "implementation-agent"
    t10_mirror_diff "agents/review-agent.md" \
                    "subagents/review-agent.md" \
                    "review-agent"

    # ---- B8 (0.6.5, design F7): extend the mirror body-diff to the L2 driver
    #      pair so the new `relay-confirmation` section cannot drift between the
    #      two copies (T9 already pins its PRESENCE in both; this pins their
    #      BODIES identical).
    #
    #      BASELINE DIVERGENCE (verified by reading both driver files): the
    #      agents/ copy carries a leading `---`...`---` YAML frontmatter block
    #      (name/description/tools) followed by a blank line before the
    #      `# orchDriverAgent Prompt` heading; the subagents/ copy is
    #      frontmatter-free and starts directly with that heading.  This is the
    #      SAME shape as the implementation/review pairs, so the SAME normalizer
    #      handles it: strip_frontmatter drops the agents/ YAML block, and
    #      t10_normalize_body's `sed '/./,$!d'` trims the surviving leading
    #      blank line.  UNLIKE the execute-task pairs, the driver pair's
    #      role-intro line is BYTE-IDENTICAL on both sides ("You are
    #      orchDriverAgent (the L2 driver) for the zyz-worker
    #      orchestration-scheduling-task skill."), so t10_normalize_body's
    #      role-intro substitution simply does not fire on it — and it does not
    #      need to, because identical lines diff clean.  No new normalization is
    #      required; the existing one is a strict superset that leaves the driver
    #      bodies green on a correct baseline while still catching ANY drift in
    #      the new relay-confirmation section (or anywhere else).
    t10_mirror_diff "agents/orch-driver-agent.md" \
                    "subagents/orch-driver-agent.md" \
                    "orch-driver-agent"
}

# ---------------------------------------------------------------------------
# T11. Confirmation/merge path unit tests.
#
# T11(a) — orch-confirm.sh RETIREMENT guard (0.6.5 confirmation/done
#   state-model fix).  Background: the 0.6.4 done/merge-decouple shipped an
#   orch-confirm.sh that, on the `confirmed` token, DIRECTLY wrote
#   `state: completed` (no git, no worktree).  The 0.6.5 fix RETIRES that
#   script: `state: completed` must only ever be a MIRROR of a worker writing
#   `phase=done`, so the `confirmed` token now relays through an L2 driver
#   (intent=relay-confirmation) that send-keys a confirmation into the worker
#   pane; the worker writes `phase=done` and L1 projects `completed` on the
#   next poll (single source of truth = worker phase=done).  The legacy
#   `approved` path (orch-merge-and-cleanup.sh: atomic merge + completed +
#   cleanup) is a deliberate exception and is unchanged (design RC2).
#
#   The OLD T11a tested the now-deleted direct-write path (confirmed -> exit 0
#   + confirm-status=success + state: completed).  That path no longer exists,
#   so T11a is REWRITTEN to LOCK the retirement: the script must be absent, and
#   the confirmed->relay contract is asserted by the gate doc-greps in T3 (B6).
#   This guard is static (no git/tmux needed) and runs UNCONDITIONALLY.
#
# T11(b) — orch-merge.sh <task-id> <list-dir> <base>: checks the `merge` token,
#   merges the task branch into base + pushes, leaves `state:` UNCHANGED and
#   does NOT clean up the worktree.  It mirrors orch-merge-and-cleanup.sh's
#   conventions (hard-requires tmux + git at entry), so T11(b) is gated on
#   tmux+git exactly like T6.  T11(b) is UNCHANGED by the 0.6.5 fix.
# ---------------------------------------------------------------------------

# T11(a) — orch-confirm.sh retirement guard (static; no git/tmux needed).
run_T11_confirm() {
    say_header "T11a orch-confirm.sh retirement guard (confirmed now relays via L2)"

    # The direct-write path is RETIRED: scripts/orch-confirm.sh must NOT exist.
    # Its absence is the contract — `confirmed` now routes through the gate to
    # an L2 relay-confirmation dispatch (asserted by T3 B6), and `completed` is
    # never written except as a mirror of worker phase=done.
    if [ ! -e "$REPO_ROOT/scripts/orch-confirm.sh" ]; then
        pass "T11a orch-confirm.sh is retired (file absent; confirmed relays via L2 relay-confirmation, not a direct state: completed write)"
    else
        fail "T11a orch-confirm.sh still exists but was retired in 0.6.5 — the confirmed token must relay through L2 (intent=relay-confirmation) so the worker writes phase=done; a direct-write to state: completed violates the single-source-of-truth invariant: scripts/orch-confirm.sh"
    fi
}

# T11(b) — orch-merge.sh `merge`-only path (real git fixture, gated tmux+git).
#
# Mirrors T6's git-fixture construction (real `git init`, a base branch + a task
# branch + a linked worktree) but drives orch-merge.sh instead of
# orch-merge-and-cleanup.sh.  Asserts the merge happened (task commit reachable
# from base) while state stays in-progress and the worktree survives.
run_T11_merge() {
    say_header "T11b orch-merge.sh merge-only path (real tmux+git)"

    local merge="$REPO_ROOT/scripts/orch-merge.sh"

    # Gate exactly like T6: orch-merge.sh hard-requires tmux + git at entry
    # (it mirrors orch-merge-and-cleanup.sh's dependency check).
    if ! command -v tmux >/dev/null 2>&1; then
        skip "T11b orch-merge.sh exits 0 + merge-status=success (tmux not available)"
        skip "T11b orch-merge.sh: task commit reachable from base after merge (tmux not available)"
        skip "T11b orch-merge.sh: master entry state still in-progress (NOT completed) (tmux not available)"
        skip "T11b orch-merge.sh: worktree still present (no cleanup) (tmux not available)"
        return
    fi
    if ! command -v git >/dev/null 2>&1; then
        skip "T11b orch-merge.sh exits 0 + merge-status=success (git not available)"
        skip "T11b orch-merge.sh: task commit reachable from base after merge (git not available)"
        skip "T11b orch-merge.sh: master entry state still in-progress (NOT completed) (git not available)"
        skip "T11b orch-merge.sh: worktree still present (no cleanup) (git not available)"
        return
    fi
    if [ ! -x "$merge" ]; then
        skip "T11b orch-merge.sh exits 0 + merge-status=success (script missing or not executable)"
        skip "T11b orch-merge.sh: task commit reachable from base after merge (script missing or not executable)"
        skip "T11b orch-merge.sh: master entry state still in-progress (NOT completed) (script missing or not executable)"
        skip "T11b orch-merge.sh: worktree still present (no cleanup) (script missing or not executable)"
        return
    fi

    # ---- Fixture: one work repo with main + a task branch in a worktree. -
    local T11B_ROOT
    T11B_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t11b.XXXXXX")"
    # NOTE: deliberately NO `trap ... EXIT` (same rationale as T11a) — installing
    # one here would clobber T8's chained `trap "t8_teardown" EXIT`.  Every
    # early-return path below does its own explicit `rm -rf "$T11B_ROOT"`, and
    # the happy path removes it at the end, so the fixture never leaks.

    local LIST_DIR="$T11B_ROOT/list"
    local WORK_DIR="$T11B_ROOT/work"
    local WORKTREE_DIR="$T11B_ROOT/worktrees/foo"
    local UNIQUE_FILE="task-only-file.txt"

    mkdir -p "$WORK_DIR"
    (
        cd "$WORK_DIR" || exit 1
        git init -q . >/dev/null 2>&1
        git config user.email "t11@example.com"
        git config user.name "T11 Test"
        git checkout -q -b main 2>/dev/null || git checkout -q main
        echo "T11 initial (work)" >README.md
        git add README.md
        git commit -q -m "initial"
        # Create the task branch + a linked worktree carrying a UNIQUE commit
        # that does NOT exist on main yet.  After orch-merge.sh runs, that
        # commit must become reachable from main.
        git worktree add -q -b task/foo "$WORKTREE_DIR" main >/dev/null 2>&1
    ) || { fail "T11b git fixture init failed"; rm -rf "$T11B_ROOT"; return; }
    (
        cd "$WORKTREE_DIR" || exit 1
        echo "added on the task branch only" >"$UNIQUE_FILE"
        git add "$UNIQUE_FILE"
        git commit -q -m "T11 task-branch-only commit"
    ) || { fail "T11b task-branch commit failed"; rm -rf "$T11B_ROOT"; return; }

    # The SHA of the task-branch-only commit (must become reachable from main).
    local task_sha
    task_sha="$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || true)"

    # ---- Master entry: source-repo=work, worktree=worktree, `merge` token. -
    # No origin remote is configured, so orch-merge.sh's push step is a no-op
    # for `merge`-only (mirrors orch-merge-and-cleanup.sh's HAS_ORIGIN guard);
    # the local `git merge --no-ff` still runs and must succeed.
    mkdir -p "$LIST_DIR/tasks"
    {
        echo "---"
        echo "task-id: foo"
        echo "project: t11b-mock"
        echo "source-repo: $WORK_DIR"
        echo "state: in-progress"
        echo "priority: normal"
        echo "branch: task/foo"
        echo "base: main"
        echo "worktree: $WORKTREE_DIR"
        echo "tmux-session: zyz-task-foo"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-22"
        echo "updated-at: 2026-06-22"
        echo "---"
        echo ""
        echo "# foo (T11b mock)"
        echo ""
        echo "## Description"
        echo ""
        echo "T11b merge-only path test."
        echo ""
        echo "## Pending Merge Approval"
        echo ""
        echo "merge by T11-test"
    } >"$LIST_DIR/tasks/foo.md"
    local entry="$LIST_DIR/tasks/foo.md"

    # ---- Invoke orch-merge.sh foo <list-dir> main ----------------------
    local merge_rc merge_out
    merge_out="$(bash "$merge" foo "$LIST_DIR" main </dev/null 2>&1)"
    merge_rc=$?

    # (1) exit 0 + stdout merge-status=success.
    if [ "$merge_rc" -eq 0 ] && printf '%s\n' "$merge_out" | grep -qF 'merge-status=success'; then
        pass "T11b orch-merge.sh exits 0 + merge-status=success"
    else
        fail "T11b orch-merge.sh: got exit=$merge_rc, stdout did not contain 'merge-status=success'.  Output:
$(printf '%s\n' "$merge_out" | sed 's/^/      | /')"
    fi

    # (2) The task-branch-only commit is now reachable from main (merge fired).
    #     `git merge-base --is-ancestor <task-sha> main` exits 0 iff reachable.
    if [ -n "$task_sha" ] \
        && git -C "$WORK_DIR" merge-base --is-ancestor "$task_sha" main >/dev/null 2>&1; then
        pass "T11b orch-merge.sh: task commit $task_sha reachable from base 'main' after merge"
    else
        fail "T11b orch-merge.sh: task commit '$task_sha' is NOT reachable from base 'main' (merge did not happen).  merge stdout:
$(printf '%s\n' "$merge_out" | sed 's/^/      | /')"
    fi

    # (3) NEGATIVE: master entry state must STILL be in-progress, NOT completed
    #     — that is the whole point of decoupling merge from done.
    if grep -qE '^state:[[:space:]]*in-progress' "$entry" \
        && ! grep -qE '^state:[[:space:]]*completed' "$entry"; then
        pass "T11b orch-merge.sh: master entry state still in-progress (NOT completed)"
    else
        fail "T11b orch-merge.sh: master entry state changed (merge must NOT touch state).  Frontmatter:
$(sed -n '1,20p' "$entry" 2>/dev/null | sed 's/^/      | /')"
    fi

    # (4) NEGATIVE: the worktree still exists (merge does NOT clean up).
    if [ -d "$WORKTREE_DIR" ]; then
        pass "T11b orch-merge.sh: worktree still present (no cleanup)"
    else
        fail "T11b orch-merge.sh: worktree $WORKTREE_DIR was removed (merge must NOT clean up)"
    fi

    rm -rf "$T11B_ROOT"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "Running orchestration-scheduling-task test suite"
echo "Repo root: $REPO_ROOT"

run_T1
run_T2
run_T3
run_T4
run_T4_prime
run_T5
run_T6
run_T7
run_T8
run_T9
run_T10
run_T11_confirm
run_T11_merge

echo
echo "============================================================"
if [ "$SKIPPED" -gt 0 ]; then
    SKIP_SUFFIX="  ($SKIPPED skipped)"
else
    SKIP_SUFFIX=""
fi
if [ "$FAILED" -eq 0 ]; then
    echo "RESULT: $PASSED/$TOTAL checks passed$SKIP_SUFFIX"
    echo "============================================================"
    exit 0
else
    echo "RESULT: $PASSED/$TOTAL checks passed  ($FAILED failed)$SKIP_SUFFIX"
    echo "============================================================"
    exit 1
fi
