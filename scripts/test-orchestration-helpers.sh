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
    "scripts/orch-reuse-worker.sh"
    "scripts/orch-check-worker.sh"
    "scripts/orch-scan-tasks.sh"
    "scripts/orch-heartbeat-daemon.sh"
    "scripts/orch-cleanup-worker.sh"
    "scripts/orch-merge-and-cleanup.sh"
    "scripts/orch-merge.sh"
    "scripts/orch-build-env.sh"
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
# TR-neg. orch-reuse-worker.sh negative / exit-code-precedence cases
#         (orch-reuse-worker design §Testing Plan "reuse 脚本负路径", §Important
#         Details exit-code table).
#
# This group is modeled EXACTLY on T4' (orch-spawn-worker.sh source-repo
# negative cases): a temp <list-dir>, fixture master entries written by a small
# helper, and run_and_check_exit / run_and_check_exit_stderr_regex assertions
# pinning each exit code (and, for the precedence case, the precise stderr).
#
# Per design the reuse exit codes are:
#   2  argv shape / invalid task-id charset
#   4  NEW master entry missing/unreadable
#   5  reuse precondition failed, split into:
#        5-tmux-FREE (validated BEFORE the dep check, fires on a tmux-less host):
#          reuse-from missing / illegal reuse-from charset (path-like) /
#          old master entry missing / illegal reuse-scope / old task not completed
#          / old worktree gone / new runtime dir already exists
#        5-tmux-DEP (validated AFTER the dep check): old session not alive
#   3  missing dependency (tmux/git)  — sits BETWEEN the two 5 classes
#
# CRITICAL precedence assertion (mirrors T4'): with tmux + git REMOVED from
# PATH, a 5-tmux-FREE precondition (old task not completed) STILL exits 5 — NOT
# 3 — proving the tmux-free checks run before the dependency gate.  And we
# assert that the tmux-DEPENDENT old-session-alive check is only reachable after
# the dep gate (a well-formed reuse task on a tmux-less host exits 3, never 5,
# for the session-alive reason).
#
# This whole group needs NO real tmux (it never reaches the container-creation
# branch), so it runs UNCONDITIONALLY, placed beside T4' so a tmux-less host
# exercises the full reuse negative matrix.
# ---------------------------------------------------------------------------

# trneg_write_master_entry <list-dir> <task-id> <state> [reuse-from] [reuse-scope] [reuse-claude] [worktree-override]
# Writes a minimal master entry under <list-dir>/tasks/<task-id>.md.  Any of the
# reuse-* args may be empty to OMIT that frontmatter line (so we can exercise
# "reuse-from missing", "reuse-scope omitted -> defaults to both", etc.).  When
# <worktree-override> is non-empty it is used as the `worktree:` value (used to
# point an old entry at a non-existent worktree path for the "old worktree gone"
# case); otherwise a stable per-task path is emitted.
trneg_write_master_entry() {
    local list_dir="$1"
    local task_id="$2"
    local state="$3"
    local reuse_from="${4:-}"
    local reuse_scope="${5:-}"
    local reuse_claude="${6:-}"
    local worktree_override="${7:-}"
    local wt="$worktree_override"
    [ -z "$wt" ] && wt="/tmp/zyz-orch-trneg-worktree/$task_id"
    mkdir -p "$list_dir/tasks"
    {
        echo "---"
        echo "task-id: $task_id"
        echo "project: trneg-mock"
        echo "source-repo: /tmp/zyz-orch-trneg-srcrepo"
        echo "state: $state"
        echo "priority: normal"
        echo "branch: task/$task_id"
        echo "base: main"
        echo "worktree: $wt"
        echo "tmux-session: zyz-task-$task_id"
        [ -n "$reuse_from" ]   && echo "reuse-from: $reuse_from"
        [ -n "$reuse_scope" ]  && echo "reuse-scope: $reuse_scope"
        [ -n "$reuse_claude" ] && echo "reuse-claude: $reuse_claude"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-24"
        echo "updated-at: 2026-06-24"
        echo "---"
        echo ""
        echo "# $task_id"
        echo ""
        echo "## Description"
        echo ""
        echo "TR-neg reuse negative-case fixture."
    } >"$list_dir/tasks/$task_id.md"
}

# trneg_path_without_tmux_git — echo a PATH with tmux + git stripped so the
# dependency gate (exit 3) actually fires.  Same idiom as t4_missing_dep but we
# strip BOTH tmux and git (reuse checks `for dep in tmux git`).  Returns empty
# if it cannot strip tmux from this host's PATH (caller then SKIPs).
trneg_path_without_tmux_git() {
    local stripped
    stripped="$(echo "$PATH" | tr ':' '\n' \
        | grep -vE '/(tmux|git|gh|homebrew|brew)' \
        | tr '\n' ':')"
    stripped="${stripped%:}"
    case ":$stripped:" in *:/usr/bin:*) : ;; *) stripped="/usr/bin:$stripped" ;; esac
    case ":$stripped:" in *:/bin:*) : ;; *) stripped="/bin:$stripped" ;; esac
    if PATH="$stripped" command -v tmux >/dev/null 2>&1; then
        printf ''
        return
    fi
    printf '%s' "$stripped"
}

run_TR_reuse_neg() {
    say_header "TR-neg orch-reuse-worker.sh negative / exit-precedence cases"

    local reuse="$REPO_ROOT/scripts/orch-reuse-worker.sh"
    if [ ! -x "$reuse" ]; then
        skip "TR-neg invalid new task-id 'bad space' -> exit 2 (orch-reuse-worker.sh missing or not executable)"
        skip "TR-neg new master entry missing -> exit 4 (orch-reuse-worker.sh missing or not executable)"
        skip "TR-neg reuse-from missing -> exit 5 (orch-reuse-worker.sh missing or not executable)"
        skip "TR-neg reuse-from path-like charset -> exit 5 (orch-reuse-worker.sh missing or not executable)"
        skip "TR-neg old master entry missing -> exit 5 (orch-reuse-worker.sh missing or not executable)"
        skip "TR-neg illegal reuse-scope -> exit 5 (orch-reuse-worker.sh missing or not executable)"
        skip "TR-neg old task not completed -> exit 5 (orch-reuse-worker.sh missing or not executable)"
        skip "TR-neg (CC-impl-1) scope=tmux but OLD dispatch.md missing -> exit 5 (orch-reuse-worker.sh missing or not executable)"
        skip "TR-neg PRECEDENCE: 5-tmux-free fires with tmux/git stripped (not 3) (orch-reuse-worker.sh missing or not executable)"
        skip "TR-neg PRECEDENCE: session-alive (5-tmux-dep) is gated behind dep check -> exit 3 (orch-reuse-worker.sh missing or not executable)"
        return
    fi

    local TRNEG_ROOT
    TRNEG_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-trneg.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$TRNEG_ROOT'" EXIT

    # ---- (1) invalid NEW task-id -> exit 2 (argv/charset, first guard) ----
    # `bad space` fails the [A-Za-z0-9_-]+ charset before any file is read.
    run_and_check_exit 2 \
        "TR-neg invalid new task-id 'bad space' -> exit 2" \
        bash "$reuse" "bad space" "$TRNEG_ROOT/list-anything"

    # ---- (2) NEW master entry missing -> exit 4 --------------------------
    # Valid task-id charset, but no <list-dir>/tasks/<new-id>.md on disk.
    local list2="$TRNEG_ROOT/list2"
    mkdir -p "$list2/tasks"
    run_and_check_exit 4 \
        "TR-neg new master entry missing -> exit 4" \
        bash "$reuse" newtask "$list2"

    # ---- (3) reuse-from missing -> exit 5 (5-tmux-free) ------------------
    # New entry exists but declares no reuse-from (not a reuse task).
    local list3="$TRNEG_ROOT/list3"
    trneg_write_master_entry "$list3" newtask ready "" "" ""
    run_and_check_exit 5 \
        "TR-neg reuse-from missing -> exit 5" \
        bash "$reuse" newtask "$list3"

    # ---- (4) reuse-from with illegal (path-like) charset -> exit 5 -------
    # A `reuse-from` that looks like a path is rejected up front (S3: cross-list
    # / absolute-path reuse-from is structurally forbidden).
    local list4="$TRNEG_ROOT/list4"
    trneg_write_master_entry "$list4" newtask ready "../other/old" both true
    run_and_check_exit 5 \
        "TR-neg reuse-from path-like charset '../other/old' -> exit 5" \
        bash "$reuse" newtask "$list4"

    # ---- (5) old master entry missing -> exit 5 --------------------------
    # Legal reuse-from charset, but no <list-dir>/tasks/<old-id>.md exists.
    local list5="$TRNEG_ROOT/list5"
    trneg_write_master_entry "$list5" newtask ready oldtask both true
    # (intentionally do NOT create tasks/oldtask.md)
    run_and_check_exit 5 \
        "TR-neg old master entry missing -> exit 5" \
        bash "$reuse" newtask "$list5"

    # ---- (6) illegal reuse-scope -> exit 5 -------------------------------
    # Old entry exists + completed, but reuse-scope is not in {worktree,tmux,both}.
    # scope legality is checked BEFORE the old-entry read, so the old entry's
    # presence/state does not matter here — but we make it valid anyway so the
    # ONLY reason to fail is the bad scope.
    local list6="$TRNEG_ROOT/list6"
    trneg_write_master_entry "$list6" newtask ready oldtask bogusscope true
    trneg_write_master_entry "$list6" oldtask completed "" "" ""
    run_and_check_exit 5 \
        "TR-neg illegal reuse-scope 'bogusscope' -> exit 5" \
        bash "$reuse" newtask "$list6"

    # ---- (7) old task state != completed -> exit 5 -----------------------
    # The old entry exists but is `ready`, not `completed` (G4 violation).
    local list7="$TRNEG_ROOT/list7"
    trneg_write_master_entry "$list7" newtask ready oldtask both true
    trneg_write_master_entry "$list7" oldtask ready "" "" ""
    run_and_check_exit 5 \
        "TR-neg old task not completed (state: ready) -> exit 5" \
        bash "$reuse" newtask "$list7"

    # ---- (7b) CC-impl-1: same-claude reuse (scope tmux/both) but the OLD
    #          task's runtime/<old-id>/dispatch.md is missing (or present with
    #          empty shell-pid / tmux-pane-id) -> exit 5 ----------------------
    # The old pane coordinates (shell-pid / tmux-pane-id) have NO master-entry
    # fallback, and an empty shell-pid in the NEW same-claude dispatch.md would
    # make orch-check-worker.sh's `pgrep -P "$DISPATCH_SHELL_PID"` never bind ->
    # the worker is silently un-pollable.  orch-reuse-worker.sh therefore rejects
    # this up front as a NEW tmux-free precondition (pure file read, runs BEFORE
    # the tmux/git dep gate), exit 5.
    #
    # Fixture (simplest robust shape per the review note): NEW task reuse-scope
    # = tmux (so the worktree-exists 5-tmux-free check is skipped and we don't
    # need a real old worktree), OLD task `completed` (passes the old-completed
    # check), and the OLD task's runtime/<old-id>/dispatch.md ABSENT (no pane
    # coordinates available at all -> the guard's strictest trigger).  We assert
    # on the EXIT CODE only (5); the guard's stderr string is intentionally NOT
    # asserted (strings drift).
    local list7b="$TRNEG_ROOT/list7b"
    trneg_write_master_entry "$list7b" newtask ready oldtask tmux true
    trneg_write_master_entry "$list7b" oldtask completed "" "" ""
    # (intentionally do NOT create list7b/runtime/oldtask/dispatch.md)
    run_and_check_exit 5 \
        "TR-neg (CC-impl-1) scope=tmux but OLD dispatch.md missing (no shell-pid/pane-id to bind) -> exit 5" \
        bash "$reuse" newtask "$list7b"

    # ---- (8) PRECEDENCE: 5-tmux-free fires even with tmux/git stripped ---
    # THE CRITICAL ASSERTION (mirrors T4'): the "old task not completed" check
    # is a 5-tmux-FREE precondition; it MUST be evaluated BEFORE the `for dep in
    # tmux git` dependency gate.  So on a host with tmux+git stripped from PATH,
    # this case still exits 5 (the reuse precondition) and NOT 3 (missing dep).
    # If the dep gate ran first, we would see 3 here — that regression is what
    # this guard catches.
    local stripped_path
    stripped_path="$(trneg_path_without_tmux_git)"
    if [ -z "$stripped_path" ]; then
        skip "TR-neg PRECEDENCE: 5-tmux-free fires with tmux/git stripped (not 3) (cannot strip tmux from PATH on this host)"
        skip "TR-neg PRECEDENCE: session-alive (5-tmux-dep) is gated behind dep check -> exit 3 (cannot strip tmux from PATH on this host)"
    else
        local list8="$TRNEG_ROOT/list8"
        trneg_write_master_entry "$list8" newtask ready oldtask both true
        trneg_write_master_entry "$list8" oldtask ready "" "" ""
        local rc8
        PATH="$stripped_path" bash "$reuse" newtask "$list8" </dev/null >/dev/null 2>&1
        rc8=$?
        if [ "$rc8" -eq 5 ]; then
            pass "TR-neg PRECEDENCE: 5-tmux-free (old task not completed) fires with tmux/git stripped -> exit 5 (NOT 3)"
        else
            fail "TR-neg PRECEDENCE: old-task-not-completed with tmux/git stripped got exit=$rc8, expected 5 (a 3 would prove the dep gate ran before the tmux-free precondition — ordering regression)"
        fi

        # ---- (9) PRECEDENCE: session-alive (5-tmux-dep) is gated behind the
        #         dep check.  Construct a WELL-FORMED reuse task: old task IS
        #         completed, scope=tmux (needs a live session).  With tmux/git
        #         stripped, ALL the 5-tmux-free preconditions pass, so control
        #         reaches the dependency gate and exits 3 — it must NOT reach the
        #         tmux-dependent `tmux has-session` check (which would be a 5).
        #         This proves the session-alive check lives AFTER the dep gate.
        local list9="$TRNEG_ROOT/list9"
        # Old worktree must EXIST so the worktree-existence 5-tmux-free check
        # (only run for worktree/both scope) does not pre-empt; scope=tmux skips
        # it anyway, but make the old worktree real to be unambiguous.
        local old_wt9="$TRNEG_ROOT/old-wt9"
        mkdir -p "$old_wt9"
        trneg_write_master_entry "$list9" newtask ready oldtask tmux true
        trneg_write_master_entry "$list9" oldtask completed "" "" "" "$old_wt9"
        # The OLD task's dispatch.md must carry the pane coordinates
        # (shell-pid / tmux-pane-id): the CC-impl-1 guard asserted in case (7b)
        # above is ALSO a 5-tmux-free precondition and runs BEFORE the dep gate,
        # so without it this fixture would exit 5 on THAT guard and never reach
        # the dep gate this case is about.  A well-formed fixture must therefore
        # satisfy every tmux-free precondition, not just old-task-completed.
        mkdir -p "$list9/runtime/oldtask"
        {
            echo "---"
            echo "task-id: oldtask"
            echo "tmux-session: zyz-task-oldtask"
            echo "tmux-pane-id: %0"
            echo "shell-pid: 1"
            echo "worktree: $old_wt9"
            echo "---"
        } >"$list9/runtime/oldtask/dispatch.md"
        local rc9
        PATH="$stripped_path" bash "$reuse" newtask "$list9" </dev/null >/dev/null 2>&1
        rc9=$?
        if [ "$rc9" -eq 3 ]; then
            pass "TR-neg PRECEDENCE: well-formed scope=tmux reuse with tmux/git stripped -> exit 3 (dep gate), proving session-alive (5-tmux-dep) is only reachable AFTER deps"
        else
            fail "TR-neg PRECEDENCE: well-formed scope=tmux reuse with tmux/git stripped got exit=$rc9, expected 3 (a 5 would mean the session-alive check ran before the dep gate — ordering regression; a 0/6/7 would mean it proceeded to container creation without tmux)"
        fi
    fi

    trap - EXIT
    rm -rf "$TRNEG_ROOT"
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
        "dispatch.md reuse field 'reuse-from:' present on normal spawn (a-reuse)" \
        "dispatch.md reuse field 'reuse-from:' is present-but-EMPTY on normal spawn (a-reuse)" \
        "dispatch.md reuse field 'reuse-scope:' present on normal spawn (a-reuse)" \
        "dispatch.md reuse field 'reuse-scope:' is present-but-EMPTY on normal spawn (a-reuse)" \
        "dispatch.md reuse field 'reuse-claude-effective:' present on normal spawn (a-reuse)" \
        "dispatch.md reuse field 'reuse-claude-effective:' is present-but-EMPTY on normal spawn (a-reuse)" \
        "dispatch.md reuse field 'heartbeat-window-id:' present on normal spawn (a-reuse)" \
        "dispatch.md reuse field 'heartbeat-window-id:' is present-but-EMPTY on normal spawn (a-reuse)" \
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
            "dispatch.md 4 reuse fields present-but-empty on normal spawn (a-reuse)" \
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
        local rk
        for rk in reuse-from reuse-scope reuse-claude-effective heartbeat-window-id; do
            skip "T8 dispatch.md reuse field '$rk:' present on normal spawn (a-reuse) (skipped: dispatch.md absent)"
            skip "T8 dispatch.md reuse field '$rk:' is present-but-EMPTY on normal spawn (a-reuse) (skipped: dispatch.md absent)"
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

    # ---- T8(a-reuse): the 4 reuse fields are PRESENT-BUT-EMPTY on a NORMAL
    #      spawn (orch-reuse-worker design step 1b + Testing Plan CC2).
    # orch-spawn-worker.sh writes `reuse-from:` / `reuse-scope:` /
    # `reuse-claude-effective:` / `heartbeat-window-id:` as empty lines so the
    # dispatch.md schema is UNIFIED with reuse-produced files (and survives
    # orch-check-worker.sh's fixed-field-list rewrite).  These are a NEW,
    # independent assertion group — they do NOT touch the closed-set "12
    # Phase-1 non-empty / 4 Phase-2 empty" loops above (which iterate an
    # explicit key list, not "all keys").
    #
    # CC2 ANCHOR DISCIPLINE: we assert via the full-key `^<key>:` anchor (grep
    # -E, line-anchored) so the match can never land on a colon-prefix sibling.
    # The four reuse keys are mutually NON-prefixing (`reuse-from`/`reuse-scope`/
    # `reuse-claude-effective`/`heartbeat-window-id`), so each anchor is exact.
    # We assert BOTH (i) the line is present AND (ii) its VALUE is empty (the
    # line is exactly `^<key>:[[:space:]]*$`), because present-but-empty is the
    # whole point — a present line with a stray value would be a schema bug.
    local rkey
    for rkey in reuse-from reuse-scope reuse-claude-effective heartbeat-window-id; do
        if grep -qE "^${rkey}:" "$DISPATCH"; then
            T8_PASS "dispatch.md reuse field '$rkey:' present on normal spawn (a-reuse)"
        else
            T8_FAIL "dispatch.md reuse field '$rkey:' MISSING on normal spawn (schema not unified with reuse) (a-reuse)"
        fi
        # Value must be EMPTY (present-but-empty).  Match a line that is the key,
        # a colon, then only optional whitespace to EOL.
        if grep -qE "^${rkey}:[[:space:]]*$" "$DISPATCH"; then
            T8_PASS "dispatch.md reuse field '$rkey:' is present-but-EMPTY on normal spawn (a-reuse)"
        else
            T8_FAIL "dispatch.md reuse field '$rkey:' is present but NON-empty on a normal spawn (expected empty value) (a-reuse).  Line:
$(grep -E "^${rkey}:" "$DISPATCH" 2>/dev/null | sed 's/^/      | /')"
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

# tr_fm <file> <key> — top-level (file-scope) frontmatter value extractor with
# the SAME semantics as run_T8's inline t8_fm (anchor `^<key>:`, trim, print the
# value).  Defined at file scope — NOT inside a run_* function — so the reuse
# groups (run_T8_reuse_rewrite / run_TR_reuse_pos) never depend on t8_fm having
# been DEFINED by a particular run_T8 code path (t8_fm is local to run_T8 and is
# only created after T8's spawn succeeds; if T8 skipped or its spawn failed,
# t8_fm would be undefined).  Same ASSUMPTION as t8_fm: correct ONLY for
# script-written dispatch.md (plain `key: value`, no inline comments, no quoted
# values, no colon-prefix-colliding keys) — which is exactly what reuse/spawn
# write and what these groups construct.
tr_fm() {
    local file="$1" key="$2"
    [ -f "$file" ] || { printf ''; return 0; }
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

# ---------------------------------------------------------------------------
# T8-reuse-rewrite. orch-check-worker.sh preserves the 4 reuse fields across a
#         Phase-2 rewrite AND emits an attach-only reuse-aware ## Recovery body
#         for a same-claude reuse worker (orch-reuse-worker design step 1c, CC1,
#         CC2; Testing Plan "check 的 Phase-2 重写保留 4 字段 + 复用感知 Recovery
#         body").
#
# This is a UNIT test of orch-check-worker.sh's rewrite_dispatch_atomic — it
# needs NO real tmux session, only `tmux` on PATH (the helper hard-checks tmux
# at entry and exits 3 otherwise, exactly like T5).  We construct a dispatch.md
# by hand with:
#   - reuse-from NON-empty + reuse-scope=both + reuse-claude-effective=true
#     (a same-claude reuse worker),
#   - a POPULATED Phase-2 trio (claude-pid / claude-session-id / transcript-path
#     all set) but first-seen-iso EMPTY.
# With the trio complete and first-seen-iso empty, check's Step D stamps
# first-seen-iso (NEWLY_BOUND), sets NEEDS_REWRITE=true, and calls
# rewrite_dispatch_atomic — which (a) re-reads + re-emits the 4 reuse fields
# (they would be DROPPED if the fixed-field-list rewriter forgot them), and
# (b) regenerates the ## Recovery body using the reuse-aware THREE-WAY branch.
# For a same-claude reuse (reuse-from set AND reuse-claude-effective=true) the
# body is ATTACH-ONLY: it must NOT print an independent `claude --resume <sid>`
# COMMAND LINE.
#
# CC2 ATTACH-ONLY ASSERTION (the load-bearing subtlety): the attach-only body
# DELIBERATELY contains the literal warning phrase
#   "Do NOT run an independent `claude --resume` for this task"
# so a naive `grep -c "claude --resume"` returns 1 and a naive absence check on
# the bare substring `claude --resume` would FALSE-FAIL on the correct body.
# We therefore assert the absence of a `claude --resume <session-id>` COMMAND
# LINE specifically — `claude --resume` followed by whitespace and a session-id
# token — via the ERE  `claude --resume +[A-Za-z0-9-]` .  The warning phrase has
# a backtick (`claude --resume\``) immediately after "resume", NOT a space +
# id, so it does NOT match.  The plain-spawn / independent-session body, by
# contrast, DOES emit `claude --resume <uuid> --plugin-dir ...`, which this ERE
# matches — so the assertion is non-vacuous (it would fire if the reuse-aware
# branch regressed to the plain body).
# ---------------------------------------------------------------------------

t8rr_write_master_entry() {
    local list_dir="$1" task_id="$2" session="$3"
    mkdir -p "$list_dir/tasks"
    {
        echo "---"
        echo "task-id: $task_id"
        echo "project: t8rr-mock"
        echo "source-repo: /tmp/zyz-orch-t8rr-srcrepo"
        echo "state: in-progress"
        echo "priority: normal"
        echo "branch: task/$task_id"
        echo "base: main"
        echo "worktree: /tmp/zyz-orch-t8rr-worktree/$task_id"
        echo "tmux-session: $session"
        echo "reuse-from: t8rrold"
        echo "reuse-scope: both"
        echo "reuse-claude: true"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-24"
        echo "updated-at: 2026-06-24"
        echo "---"
        echo ""
        echo "# $task_id"
        echo ""
        echo "## Description"
        echo ""
        echo "T8-reuse-rewrite fixture."
    } >"$list_dir/tasks/$task_id.md"
}

run_T8_reuse_rewrite() {
    say_header "T8-reuse-rewrite orch-check-worker.sh reuse-field preservation + attach-only Recovery body"

    local check="$REPO_ROOT/scripts/orch-check-worker.sh"

    # Gated on tmux like T5 (check hard-requires tmux at entry; no real session
    # is needed — session-alive simply reports false).
    if ! command -v tmux >/dev/null 2>&1; then
        skip "T8-reuse-rewrite check exits 0 on a reuse dispatch.md (tmux not available)"
        skip "T8-reuse-rewrite reuse field 'reuse-from' survives rewrite (tmux not available)"
        skip "T8-reuse-rewrite reuse field 'reuse-scope' survives rewrite (tmux not available)"
        skip "T8-reuse-rewrite reuse field 'reuse-claude-effective' survives rewrite (tmux not available)"
        skip "T8-reuse-rewrite reuse field 'heartbeat-window-id' survives rewrite (tmux not available)"
        skip "T8-reuse-rewrite same-claude Recovery body is attach-only (no 'claude --resume <sid>' command line) (tmux not available)"
        skip "T8-reuse-rewrite same-claude Recovery body keeps the attach 'tmux attach -t <session>' line (tmux not available)"
        skip "T8-reuse-rewrite same-claude Recovery body keeps the literal --resume WARNING phrase (allowed) (tmux not available)"
        return
    fi
    if [ ! -x "$check" ]; then
        skip "T8-reuse-rewrite check exits 0 on a reuse dispatch.md (orch-check-worker.sh missing or not executable)"
        skip "T8-reuse-rewrite reuse field 'reuse-from' survives rewrite (orch-check-worker.sh missing or not executable)"
        skip "T8-reuse-rewrite reuse field 'reuse-scope' survives rewrite (orch-check-worker.sh missing or not executable)"
        skip "T8-reuse-rewrite reuse field 'reuse-claude-effective' survives rewrite (orch-check-worker.sh missing or not executable)"
        skip "T8-reuse-rewrite reuse field 'heartbeat-window-id' survives rewrite (orch-check-worker.sh missing or not executable)"
        skip "T8-reuse-rewrite same-claude Recovery body is attach-only (no 'claude --resume <sid>' command line) (orch-check-worker.sh missing or not executable)"
        skip "T8-reuse-rewrite same-claude Recovery body keeps the attach 'tmux attach -t <session>' line (orch-check-worker.sh missing or not executable)"
        skip "T8-reuse-rewrite same-claude Recovery body keeps the literal --resume WARNING phrase (allowed) (orch-check-worker.sh missing or not executable)"
        return
    fi

    local T8RR_ROOT
    T8RR_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t8rr.XXXXXX")"
    # NOTE: deliberately NO `trap ... EXIT` (same rationale as T11b/TR-pos) —
    # installing one here would clobber T8's chained `trap "t8_teardown" EXIT`.
    # We rm -rf the tmproot on every exit path explicitly.

    local LIST_DIR="$T8RR_ROOT/list"
    local TASK_ID="t8rrnew"
    local SESSION="zyz-task-t8rrold"   # the (reused) old session name
    local RUNTIME="$LIST_DIR/runtime/$TASK_ID"
    local DISPATCH="$RUNTIME/dispatch.md"
    mkdir -p "$RUNTIME"
    t8rr_write_master_entry "$LIST_DIR" "$TASK_ID" "$SESSION"

    # Fixed fake Phase-2 trio.  claude-pid does NOT need to be a live process:
    # check only re-discovers it via pgrep when claude-pid is EMPTY; since we
    # pre-populate it, Step A is skipped.  Likewise sid + transcript are
    # pre-set, so Steps B/C are skipped.  first-seen-iso is left EMPTY so Step D
    # stamps it and forces NEEDS_REWRITE=true -> rewrite_dispatch_atomic fires.
    local FAKE_PID="424242"
    local FAKE_SID="dddddddd-eeee-ffff-0000-111111111111"
    # transcript-path must point at an existing file (Step C's `-f` guard would
    # clear it otherwise — but Step C is skipped here since transcript is preset;
    # still, make it real so nothing downstream rejects it).
    local FAKE_TRANSCRIPT="$T8RR_ROOT/$FAKE_SID.jsonl"
    printf '%s\n' '{"type":"user"}' >"$FAKE_TRANSCRIPT"

    {
        echo "---"
        echo "task-id: $TASK_ID"
        echo "spawn-iso: 2026-06-24T00:00:00+0000"
        echo "tmux-session: $SESSION"
        echo "tmux-window-id: @7"
        echo "tmux-pane-id: %7"
        echo "shell-pid: 777777"
        echo "worktree: /tmp/zyz-orch-t8rr-worktree/$TASK_ID"
        echo "source-repo: /tmp/zyz-orch-t8rr-srcrepo"
        echo "branch: task/$TASK_ID"
        echo "base: main"
        echo "plugin-root: $REPO_ROOT"
        echo "encoded-cwd: -tmp-zyz-orch-t8rr-worktree-$TASK_ID"
        echo "reuse-from: t8rrold"
        echo "reuse-scope: both"
        echo "reuse-claude-effective: true"
        echo "heartbeat-window-id: @9"
        echo "claude-pid: $FAKE_PID"
        echo "claude-session-id: $FAKE_SID"
        echo "transcript-path: $FAKE_TRANSCRIPT"
        echo "first-seen-iso:"
        echo "---"
        echo ""
        echo "# Dispatch Info"
        echo ""
        echo "## Recovery"
        echo ""
        echo "(awaiting claude startup ...)"
    } >"$DISPATCH"

    local rr_out rr_rc
    rr_out="$(
        cd "$T8RR_ROOT" && bash "$check" "$TASK_ID" "$LIST_DIR" </dev/null 2>&1
    )"
    rr_rc=$?

    if [ "$rr_rc" -eq 0 ]; then
        pass "T8-reuse-rewrite check exits 0 on a reuse dispatch.md"
    else
        fail "T8-reuse-rewrite check exited $rr_rc (expected 0).  Output:
$(printf '%s\n' "$rr_out" | sed 's/^/      | /')"
    fi

    # ---- (1) the 4 reuse fields SURVIVE the rewrite (full-key anchors) ----
    # Re-read with the file-scope tr_fm extractor.
    local got_rf got_rs got_rce got_hbw
    got_rf="$(tr_fm "$DISPATCH" reuse-from)"
    got_rs="$(tr_fm "$DISPATCH" reuse-scope)"
    got_rce="$(tr_fm "$DISPATCH" reuse-claude-effective)"
    got_hbw="$(tr_fm "$DISPATCH" heartbeat-window-id)"

    if [ "$got_rf" = "t8rrold" ]; then
        pass "T8-reuse-rewrite reuse field 'reuse-from' survives rewrite"
    else
        fail "T8-reuse-rewrite reuse field 'reuse-from'='$got_rf' (expected 't8rrold') — DROPPED by the fixed-field-list rewrite"
    fi
    if [ "$got_rs" = "both" ]; then
        pass "T8-reuse-rewrite reuse field 'reuse-scope' survives rewrite"
    else
        fail "T8-reuse-rewrite reuse field 'reuse-scope'='$got_rs' (expected 'both') — DROPPED by the rewrite"
    fi
    if [ "$got_rce" = "true" ]; then
        pass "T8-reuse-rewrite reuse field 'reuse-claude-effective' survives rewrite"
    else
        fail "T8-reuse-rewrite reuse field 'reuse-claude-effective'='$got_rce' (expected 'true') — DROPPED by the rewrite"
    fi
    if [ "$got_hbw" = "@9" ]; then
        pass "T8-reuse-rewrite reuse field 'heartbeat-window-id' survives rewrite"
    else
        fail "T8-reuse-rewrite reuse field 'heartbeat-window-id'='$got_hbw' (expected '@9') — DROPPED by the rewrite"
    fi

    # ---- (2) the regenerated ## Recovery body is reuse-aware ATTACH-ONLY ----
    local rr_body
    rr_body="$(awk '/^## Recovery$/{f=1; next} f' "$DISPATCH" 2>/dev/null || true)"

    # CC2: NO `claude --resume <session-id>` COMMAND LINE.  Match the command
    # form `claude --resume` + whitespace + a session-id token.  The literal
    # warning phrase has a backtick right after "resume" (no space+id), so it
    # does NOT match this ERE.
    if printf '%s\n' "$rr_body" | grep -qE 'claude --resume +[A-Za-z0-9-]'; then
        fail "T8-reuse-rewrite same-claude Recovery body is attach-only (no 'claude --resume <sid>' command line) — but found a resume COMMAND LINE.  Body:
$(printf '%s\n' "$rr_body" | sed 's/^/      | /')"
    else
        pass "T8-reuse-rewrite same-claude Recovery body is attach-only (no 'claude --resume <sid>' command line)"
    fi

    # The attach line MUST be present (recovery is via attach for a same-claude
    # reuse worker).
    if printf '%s\n' "$rr_body" | grep -qF "tmux attach -t $SESSION"; then
        pass "T8-reuse-rewrite same-claude Recovery body keeps the attach 'tmux attach -t <session>' line"
    else
        fail "T8-reuse-rewrite same-claude Recovery body MISSING 'tmux attach -t $SESSION'.  Body:
$(printf '%s\n' "$rr_body" | sed 's/^/      | /')"
    fi

    # The literal --resume WARNING phrase is ALLOWED (it is the footgun warning,
    # not a command line).  Asserting it is present documents WHY the naive
    # grep -c approach is wrong, and pins the reuse-aware branch fired (the plain
    # body never carries this warning).
    if printf '%s\n' "$rr_body" | grep -qF 'Do NOT run an independent `claude --resume`'; then
        pass "T8-reuse-rewrite same-claude Recovery body keeps the literal --resume WARNING phrase (allowed)"
    else
        fail "T8-reuse-rewrite same-claude Recovery body MISSING the footgun warning 'Do NOT run an independent \`claude --resume\`' (reuse-aware branch did not fire?).  Body:
$(printf '%s\n' "$rr_body" | sed 's/^/      | /')"
    fi

    rm -rf "$T8RR_ROOT"
}

# ---------------------------------------------------------------------------
# TR-pos. orch-reuse-worker.sh positive container-reuse cases
#         (orch-reuse-worker design §Testing Plan "reuse 脚本正路径",
#         registered as the real-tmux "container-layer e2e" — full claude
#         end-to-end is SKIPPED-with-reason per the design's E2E decision).
#
# Gated on real tmux + git exactly like T6/T8.  Builds a throwaway git repo and
# an OLD task that is `completed` and whose container is LIVE (a real tmux
# session + a real linked worktree + an old dispatch.md recording the old pane
# coordinates), then drives orch-reuse-worker.sh for three NEW tasks:
#   - scope=worktree                 : NEW session zyz-task-<new>, OLD worktree,
#                                       reuse-claude-effective=n/a, in-pane daemon
#                                       touches the new heartbeat.
#   - scope=both  + reuse-claude=true: OLD session reused, reuse-claude-effective
#                                       =true, non-empty heartbeat-window-id,
#                                       shell-pid == old pane's, a NEW window in
#                                       the reused session, new heartbeat touched,
#                                       OLD entry+runtime unchanged.
#   - scope=tmux  + reuse-claude=true: worktree recorded == old worktree.
#
# Cleanup: NO `trap ... EXIT` (same rationale as T11b — installing one here would
# clobber T8's chained `trap "t8_teardown" EXIT`).  Instead a local trpos_teardown
# kills every tmux session this group created and removes the tmproot; it is
# invoked on every early-return path AND at the natural end, so nothing leaks.
# ---------------------------------------------------------------------------

TR_POS_FAIL() { fail "TR-pos $1"; }
TR_POS_PASS() { pass "TR-pos $1"; }

TR_POS_SKIP_ALL() {
    local reason="$1"
    local i
    for i in \
        "scope=worktree: dispatch.md tmux-session=zyz-task-<new> (new session)" \
        "scope=worktree: dispatch.md worktree=<old worktree>" \
        "scope=worktree: dispatch.md reuse-claude-effective=n/a" \
        "scope=worktree: dispatch.md reuse-from=<old-id>" \
        "scope=worktree: dispatch.md reuse-scope=worktree" \
        "scope=worktree: new session zyz-task-<new> is alive" \
        "scope=worktree: new heartbeat file touched (in-pane daemon)" \
        "scope=worktree: heartbeat-window-id empty (new session, in-pane daemon)" \
        "scope=both: dispatch.md tmux-session=<old session>" \
        "scope=both: dispatch.md reuse-claude-effective=true" \
        "scope=both: dispatch.md heartbeat-window-id non-empty" \
        "scope=both: dispatch.md shell-pid == old pane's shell-pid" \
        "scope=both: dispatch.md worktree=<old worktree>" \
        "scope=both: a NEW window opened in the reused session" \
        "scope=both: new heartbeat file touched (new-window daemon)" \
        "scope=both: OLD master entry unchanged after reuse" \
        "scope=both: OLD runtime dispatch.md unchanged after reuse" \
        "scope=tmux: dispatch.md worktree == old worktree" \
        "scope=tmux: dispatch.md reuse-claude-effective=true" \
        "TR-pos fixture teardown clean"
    do
        skip "TR-pos $i (skipped: $reason)"
    done
}

run_TR_reuse_pos() {
    say_header "TR-pos orch-reuse-worker.sh positive container-reuse (real tmux+git)"

    if ! command -v tmux >/dev/null 2>&1; then
        TR_POS_SKIP_ALL "tmux not available on PATH"
        return
    fi
    if ! command -v git >/dev/null 2>&1; then
        TR_POS_SKIP_ALL "git not available on PATH"
        return
    fi

    local reuse="$REPO_ROOT/scripts/orch-reuse-worker.sh"
    if [ ! -x "$reuse" ]; then
        TR_POS_SKIP_ALL "orch-reuse-worker.sh missing or not executable"
        return
    fi

    # ---- Fixture setup --------------------------------------------------
    local TRPOS_ROOT TRPOS_OLD_SESSION
    TRPOS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-trpos.XXXXXX")"
    local LIST_DIR="$TRPOS_ROOT/list"
    local WORK_DIR="$TRPOS_ROOT/work"
    local OLD_ID="trposold"
    local OLD_WORKTREE="$TRPOS_ROOT/worktrees/$OLD_ID"
    TRPOS_OLD_SESSION="zyz-task-$OLD_ID"
    local NEW_WT_ID="trposwt"        # scope=worktree new task
    local NEW_BOTH_ID="trposboth"    # scope=both new task
    local NEW_TMUX_ID="trpostmux"    # scope=tmux new task
    local NEW_WT_SESSION="zyz-task-$NEW_WT_ID"

    # Teardown: kill every session this group may have created + remove tmproot.
    # Defined as a closure over the locals (invoked synchronously, not from a
    # trap, so the locals are in scope — unlike T6/T8's deferred-trap teardown).
    trpos_teardown() {
        tmux kill-session -t "$TRPOS_OLD_SESSION" 2>/dev/null || true
        tmux kill-session -t "$NEW_WT_SESSION"    2>/dev/null || true
        # Give SIGHUP a moment to reap the in-pane + new-window heartbeat
        # daemons before we yank the tmproot out from under them.
        sleep 1
        rm -rf "$TRPOS_ROOT"
    }

    # --- Init the throwaway git repo (the source-repo for the old task) ---
    mkdir -p "$WORK_DIR"
    (
        cd "$WORK_DIR" || exit 1
        git init -q . >/dev/null 2>&1
        git config user.email "trpos@example.com"
        git config user.name "TRpos Test"
        git checkout -q -b main 2>/dev/null || git checkout -q main
        echo "TR-pos initial (work)" >README.md
        git add README.md
        git commit -q -m "initial"
        # Linked worktree on a task branch — this is the OLD task's worktree,
        # the thing the new tasks will reuse.
        git worktree add -q -b "task/$OLD_ID" "$OLD_WORKTREE" main >/dev/null 2>&1
    ) || { TR_POS_FAIL "git fixture init failed"; trpos_teardown; TR_POS_SKIP_ALL "git fixture init failed"; return; }

    # --- The OLD master entry: completed, no reuse-* (it was a plain task) ---
    mkdir -p "$LIST_DIR/tasks"
    {
        echo "---"
        echo "task-id: $OLD_ID"
        echo "project: trpos-mock"
        echo "source-repo: $WORK_DIR"
        echo "state: completed"
        echo "priority: normal"
        echo "branch: task/$OLD_ID"
        echo "base: main"
        echo "worktree: $OLD_WORKTREE"
        echo "tmux-session: $TRPOS_OLD_SESSION"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-24"
        echo "updated-at: 2026-06-24"
        echo "---"
        echo ""
        echo "# $OLD_ID (TR-pos old completed task)"
        echo ""
        echo "## Description"
        echo ""
        echo "TR-pos old completed task whose container is reused."
    } >"$LIST_DIR/tasks/$OLD_ID.md"

    # --- Bring up the OLD task's LIVE tmux session (a real session whose pane
    #     shell is the old "claude pane"), and capture its real pane coordinates
    #     so the old dispatch.md records a real, alive shell-pid / pane-id /
    #     window-id (same-claude reuse reads these). ---
    if ! tmux new-session -d -s "$TRPOS_OLD_SESSION" -c "$OLD_WORKTREE" 2>/dev/null; then
        TR_POS_FAIL "could not create old tmux session $TRPOS_OLD_SESSION"
        trpos_teardown
        TR_POS_SKIP_ALL "could not create old tmux session"
        return
    fi
    sleep 1
    local old_pane_info old_win old_pane old_shell
    old_pane_info="$(tmux list-panes -t "$TRPOS_OLD_SESSION" -F '#{window_id} #{pane_id} #{pane_pid}' 2>/dev/null | head -1)"
    old_win="$(echo "$old_pane_info" | awk '{print $1}')"
    old_pane="$(echo "$old_pane_info" | awk '{print $2}')"
    old_shell="$(echo "$old_pane_info" | awk '{print $3}')"

    # --- The OLD runtime dispatch.md: a plain-spawn-shaped Phase-1 file with
    #     the real old pane coordinates + the 4 reuse fields empty (spawn's
    #     schema).  orch-reuse-worker.sh reads tmux-session / worktree /
    #     shell-pid / tmux-pane-id / tmux-window-id / source-repo / branch /
    #     base / plugin-root from here. ---
    mkdir -p "$LIST_DIR/runtime/$OLD_ID"
    local OLD_DISPATCH="$LIST_DIR/runtime/$OLD_ID/dispatch.md"
    {
        echo "---"
        echo "task-id: $OLD_ID"
        echo "spawn-iso: 2026-06-24T00:00:00+0000"
        echo "tmux-session: $TRPOS_OLD_SESSION"
        echo "tmux-window-id: $old_win"
        echo "tmux-pane-id: $old_pane"
        echo "shell-pid: $old_shell"
        echo "worktree: $OLD_WORKTREE"
        echo "source-repo: $WORK_DIR"
        echo "branch: task/$OLD_ID"
        echo "base: main"
        echo "plugin-root: $REPO_ROOT"
        echo "encoded-cwd: $(cd "$OLD_WORKTREE" && pwd -P | tr '/.' '--' | tr -s '-')"
        echo "reuse-from:"
        echo "reuse-scope:"
        echo "reuse-claude-effective:"
        echo "heartbeat-window-id:"
        echo "claude-pid:"
        echo "claude-session-id:"
        echo "transcript-path:"
        echo "first-seen-iso:"
        echo "---"
        echo ""
        echo "# Dispatch Info"
        echo ""
        echo "## Recovery"
        echo ""
        echo "(old task recovery body)"
    } >"$OLD_DISPATCH"

    # Snapshot the OLD entry + OLD dispatch.md so we can prove reuse NEVER
    # rewrites them (G4 / acceptance criterion 3).
    local old_entry_hash_pre old_dispatch_hash_pre
    old_entry_hash_pre="$(t8_content_hash "$LIST_DIR/tasks/$OLD_ID.md")"
    old_dispatch_hash_pre="$(t8_content_hash "$OLD_DISPATCH")"

    # Frontmatter reads use the file-scope tr_fm helper (same `^<key>:` anchor
    # semantics as run_T8's t8_fm, but defined at file scope so it is always in
    # the function table regardless of which T8 code path ran).  Safe only
    # against script-written dispatch.md — which is exactly what reuse writes.

    # =====================================================================
    # (A) scope=worktree — new session, reuse old worktree, new claude.
    # =====================================================================
    {
        echo "---"
        echo "task-id: $NEW_WT_ID"
        echo "project: trpos-mock"
        echo "source-repo: $WORK_DIR"
        echo "state: ready"
        echo "priority: normal"
        echo "branch: task/$NEW_WT_ID"
        echo "base: main"
        echo "worktree: $TRPOS_ROOT/worktrees/$NEW_WT_ID"
        echo "tmux-session: $NEW_WT_SESSION"
        echo "reuse-from: $OLD_ID"
        echo "reuse-scope: worktree"
        echo "reuse-claude: false"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-24"
        echo "updated-at: 2026-06-24"
        echo "---"
        echo ""
        echo "# $NEW_WT_ID"
        echo ""
        echo "## Description"
        echo ""
        echo "TR-pos scope=worktree reuse."
    } >"$LIST_DIR/tasks/$NEW_WT_ID.md"

    local wt_rc wt_out
    wt_out="$(
        cd "$TRPOS_ROOT" && bash "$reuse" "$NEW_WT_ID" "$LIST_DIR" </dev/null 2>&1
    )"
    wt_rc=$?
    local WT_DISPATCH="$LIST_DIR/runtime/$NEW_WT_ID/dispatch.md"
    if [ "$wt_rc" -ne 0 ] || [ ! -f "$WT_DISPATCH" ]; then
        TR_POS_FAIL "scope=worktree reuse exited $wt_rc or wrote no dispatch.md.  Output:
$(printf '%s\n' "$wt_out" | sed 's/^/      | /')"
        local i
        for i in \
            "scope=worktree: dispatch.md tmux-session=zyz-task-<new> (new session)" \
            "scope=worktree: dispatch.md worktree=<old worktree>" \
            "scope=worktree: dispatch.md reuse-claude-effective=n/a" \
            "scope=worktree: dispatch.md reuse-from=<old-id>" \
            "scope=worktree: dispatch.md reuse-scope=worktree" \
            "scope=worktree: new session zyz-task-<new> is alive" \
            "scope=worktree: new heartbeat file touched (in-pane daemon)" \
            "scope=worktree: heartbeat-window-id empty (new session, in-pane daemon)"
        do
            skip "TR-pos $i (skipped: scope=worktree reuse failed)"
        done
    else
        local wt_sess wt_wt wt_rce wt_rf wt_rs wt_hbwin
        wt_sess="$(tr_fm "$WT_DISPATCH" tmux-session)"
        wt_wt="$(tr_fm "$WT_DISPATCH" worktree)"
        wt_rce="$(tr_fm "$WT_DISPATCH" reuse-claude-effective)"
        wt_rf="$(tr_fm "$WT_DISPATCH" reuse-from)"
        wt_rs="$(tr_fm "$WT_DISPATCH" reuse-scope)"
        wt_hbwin="$(tr_fm "$WT_DISPATCH" heartbeat-window-id)"

        if [ "$wt_sess" = "$NEW_WT_SESSION" ]; then
            TR_POS_PASS "scope=worktree: dispatch.md tmux-session=zyz-task-<new> (new session)"
        else
            TR_POS_FAIL "scope=worktree: dispatch.md tmux-session='$wt_sess' != '$NEW_WT_SESSION' (expected a NEW session)"
        fi
        if [ "$wt_wt" = "$OLD_WORKTREE" ]; then
            TR_POS_PASS "scope=worktree: dispatch.md worktree=<old worktree>"
        else
            TR_POS_FAIL "scope=worktree: dispatch.md worktree='$wt_wt' != old worktree '$OLD_WORKTREE'"
        fi
        if [ "$wt_rce" = "n/a" ]; then
            TR_POS_PASS "scope=worktree: dispatch.md reuse-claude-effective=n/a"
        else
            TR_POS_FAIL "scope=worktree: dispatch.md reuse-claude-effective='$wt_rce' != 'n/a' (reuse-claude is IGNORED for worktree scope)"
        fi
        if [ "$wt_rf" = "$OLD_ID" ]; then
            TR_POS_PASS "scope=worktree: dispatch.md reuse-from=<old-id>"
        else
            TR_POS_FAIL "scope=worktree: dispatch.md reuse-from='$wt_rf' != '$OLD_ID'"
        fi
        if [ "$wt_rs" = "worktree" ]; then
            TR_POS_PASS "scope=worktree: dispatch.md reuse-scope=worktree"
        else
            TR_POS_FAIL "scope=worktree: dispatch.md reuse-scope='$wt_rs' != 'worktree'"
        fi
        if tmux has-session -t "$NEW_WT_SESSION" 2>/dev/null; then
            TR_POS_PASS "scope=worktree: new session zyz-task-<new> is alive"
        else
            TR_POS_FAIL "scope=worktree: new session '$NEW_WT_SESSION' is NOT alive after reuse"
        fi
        # heartbeat file is touched by the in-pane daemon within ~1-2s.
        local wt_hb="$LIST_DIR/runtime/$NEW_WT_ID/heartbeat" wt_hb_present=0 _t
        for _t in 1 2 3 4 5; do
            if [ -e "$wt_hb" ]; then wt_hb_present=1; break; fi
            sleep 1
        done
        if [ "$wt_hb_present" -eq 1 ]; then
            TR_POS_PASS "scope=worktree: new heartbeat file touched (in-pane daemon)"
        else
            TR_POS_FAIL "scope=worktree: new heartbeat file '$wt_hb' NOT touched (in-pane daemon did not run)"
        fi
        # worktree scope uses an in-pane daemon (no new window), so
        # heartbeat-window-id is empty.
        if [ -z "$wt_hbwin" ]; then
            TR_POS_PASS "scope=worktree: heartbeat-window-id empty (new session, in-pane daemon)"
        else
            TR_POS_FAIL "scope=worktree: heartbeat-window-id='$wt_hbwin' should be empty for worktree scope (in-pane daemon, no new window)"
        fi
    fi

    # =====================================================================
    # (B) scope=both + reuse-claude=true — reuse old session + old worktree,
    #     same claude, new-window heartbeat daemon.
    # =====================================================================
    # Count windows in the reused session BEFORE so we can prove a NEW one
    # was opened.
    local both_win_before both_win_after
    both_win_before="$(tmux list-windows -t "$TRPOS_OLD_SESSION" 2>/dev/null | wc -l | tr -d ' ')"

    {
        echo "---"
        echo "task-id: $NEW_BOTH_ID"
        echo "project: trpos-mock"
        echo "source-repo: $WORK_DIR"
        echo "state: ready"
        echo "priority: normal"
        echo "branch: task/$NEW_BOTH_ID"
        echo "base: main"
        echo "worktree: $TRPOS_ROOT/worktrees/$NEW_BOTH_ID-ignored"
        echo "tmux-session: zyz-task-$NEW_BOTH_ID"
        echo "reuse-from: $OLD_ID"
        echo "reuse-scope: both"
        echo "reuse-claude: true"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-24"
        echo "updated-at: 2026-06-24"
        echo "---"
        echo ""
        echo "# $NEW_BOTH_ID"
        echo ""
        echo "## Description"
        echo ""
        echo "TR-pos scope=both same-claude reuse."
    } >"$LIST_DIR/tasks/$NEW_BOTH_ID.md"

    local both_rc both_out
    both_out="$(
        cd "$TRPOS_ROOT" && bash "$reuse" "$NEW_BOTH_ID" "$LIST_DIR" </dev/null 2>&1
    )"
    both_rc=$?
    local BOTH_DISPATCH="$LIST_DIR/runtime/$NEW_BOTH_ID/dispatch.md"
    if [ "$both_rc" -ne 0 ] || [ ! -f "$BOTH_DISPATCH" ]; then
        TR_POS_FAIL "scope=both reuse exited $both_rc or wrote no dispatch.md.  Output:
$(printf '%s\n' "$both_out" | sed 's/^/      | /')"
        local i
        for i in \
            "scope=both: dispatch.md tmux-session=<old session>" \
            "scope=both: dispatch.md reuse-claude-effective=true" \
            "scope=both: dispatch.md heartbeat-window-id non-empty" \
            "scope=both: dispatch.md shell-pid == old pane's shell-pid" \
            "scope=both: dispatch.md worktree=<old worktree>" \
            "scope=both: a NEW window opened in the reused session" \
            "scope=both: new heartbeat file touched (new-window daemon)" \
            "scope=both: OLD master entry unchanged after reuse" \
            "scope=both: OLD runtime dispatch.md unchanged after reuse"
        do
            skip "TR-pos $i (skipped: scope=both reuse failed)"
        done
    else
        local both_sess both_rce both_hbwin both_shell both_wt
        both_sess="$(tr_fm "$BOTH_DISPATCH" tmux-session)"
        both_rce="$(tr_fm "$BOTH_DISPATCH" reuse-claude-effective)"
        both_hbwin="$(tr_fm "$BOTH_DISPATCH" heartbeat-window-id)"
        both_shell="$(tr_fm "$BOTH_DISPATCH" shell-pid)"
        both_wt="$(tr_fm "$BOTH_DISPATCH" worktree)"

        if [ "$both_sess" = "$TRPOS_OLD_SESSION" ]; then
            TR_POS_PASS "scope=both: dispatch.md tmux-session=<old session>"
        else
            TR_POS_FAIL "scope=both: dispatch.md tmux-session='$both_sess' != old session '$TRPOS_OLD_SESSION'"
        fi
        if [ "$both_rce" = "true" ]; then
            TR_POS_PASS "scope=both: dispatch.md reuse-claude-effective=true"
        else
            TR_POS_FAIL "scope=both: dispatch.md reuse-claude-effective='$both_rce' != 'true'"
        fi
        if [ -n "$both_hbwin" ]; then
            TR_POS_PASS "scope=both: dispatch.md heartbeat-window-id non-empty"
        else
            TR_POS_FAIL "scope=both: dispatch.md heartbeat-window-id is EMPTY (new-window daemon id should be recorded)"
        fi
        if [ -n "$old_shell" ] && [ "$both_shell" = "$old_shell" ]; then
            TR_POS_PASS "scope=both: dispatch.md shell-pid == old pane's shell-pid"
        else
            TR_POS_FAIL "scope=both: dispatch.md shell-pid='$both_shell' != old pane's shell-pid '$old_shell'"
        fi
        if [ "$both_wt" = "$OLD_WORKTREE" ]; then
            TR_POS_PASS "scope=both: dispatch.md worktree=<old worktree>"
        else
            TR_POS_FAIL "scope=both: dispatch.md worktree='$both_wt' != old worktree '$OLD_WORKTREE'"
        fi

        both_win_after="$(tmux list-windows -t "$TRPOS_OLD_SESSION" 2>/dev/null | wc -l | tr -d ' ')"
        if [ -n "$both_win_before" ] && [ -n "$both_win_after" ] && [ "$both_win_after" -gt "$both_win_before" ]; then
            TR_POS_PASS "scope=both: a NEW window opened in the reused session"
        else
            TR_POS_FAIL "scope=both: reused session window count did not grow ($both_win_before -> $both_win_after); expected a new heartbeat window"
        fi

        # new heartbeat file touched by the new-window daemon within ~1-2s.
        local both_hb="$LIST_DIR/runtime/$NEW_BOTH_ID/heartbeat" both_hb_present=0 _t2
        for _t2 in 1 2 3 4 5; do
            if [ -e "$both_hb" ]; then both_hb_present=1; break; fi
            sleep 1
        done
        if [ "$both_hb_present" -eq 1 ]; then
            TR_POS_PASS "scope=both: new heartbeat file touched (new-window daemon)"
        else
            TR_POS_FAIL "scope=both: new heartbeat file '$both_hb' NOT touched (new-window daemon did not run)"
        fi

        # OLD entry + OLD dispatch.md must be byte-unchanged (reuse only
        # associates; G4 / acceptance criterion 3).
        local old_entry_hash_post old_dispatch_hash_post
        old_entry_hash_post="$(t8_content_hash "$LIST_DIR/tasks/$OLD_ID.md")"
        old_dispatch_hash_post="$(t8_content_hash "$OLD_DISPATCH")"
        if [ -z "$old_entry_hash_pre" ] || [ -z "$old_entry_hash_post" ]; then
            skip "TR-pos scope=both: OLD master entry unchanged after reuse (skipped: no shasum/sha256sum on host)"
        elif [ "$old_entry_hash_pre" = "$old_entry_hash_post" ]; then
            TR_POS_PASS "scope=both: OLD master entry unchanged after reuse"
        else
            TR_POS_FAIL "scope=both: OLD master entry CHANGED after reuse (reuse must never rewrite the old task)"
        fi
        if [ -z "$old_dispatch_hash_pre" ] || [ -z "$old_dispatch_hash_post" ]; then
            skip "TR-pos scope=both: OLD runtime dispatch.md unchanged after reuse (skipped: no shasum/sha256sum on host)"
        elif [ "$old_dispatch_hash_pre" = "$old_dispatch_hash_post" ]; then
            TR_POS_PASS "scope=both: OLD runtime dispatch.md unchanged after reuse"
        else
            TR_POS_FAIL "scope=both: OLD runtime dispatch.md CHANGED after reuse (reuse must never rewrite the old container's dispatch.md)"
        fi
    fi

    # =====================================================================
    # (C) scope=tmux + reuse-claude=true — worktree recorded == old worktree
    #     (the `worktree:` frontmatter field is intentionally ignored; cwd
    #     follows the reused pane).
    # =====================================================================
    {
        echo "---"
        echo "task-id: $NEW_TMUX_ID"
        echo "project: trpos-mock"
        echo "source-repo: $WORK_DIR"
        echo "state: ready"
        echo "priority: normal"
        echo "branch: task/$NEW_TMUX_ID"
        echo "base: main"
        # A bogus worktree override to prove it is IGNORED for tmux scope.
        echo "worktree: $TRPOS_ROOT/worktrees/$NEW_TMUX_ID-should-be-ignored"
        echo "tmux-session: zyz-task-$NEW_TMUX_ID"
        echo "reuse-from: $OLD_ID"
        echo "reuse-scope: tmux"
        echo "reuse-claude: true"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-06-24"
        echo "updated-at: 2026-06-24"
        echo "---"
        echo ""
        echo "# $NEW_TMUX_ID"
        echo ""
        echo "## Description"
        echo ""
        echo "TR-pos scope=tmux same-claude reuse."
    } >"$LIST_DIR/tasks/$NEW_TMUX_ID.md"

    local tmux_rc tmux_out
    tmux_out="$(
        cd "$TRPOS_ROOT" && bash "$reuse" "$NEW_TMUX_ID" "$LIST_DIR" </dev/null 2>&1
    )"
    tmux_rc=$?
    local TMUX_DISPATCH="$LIST_DIR/runtime/$NEW_TMUX_ID/dispatch.md"
    if [ "$tmux_rc" -ne 0 ] || [ ! -f "$TMUX_DISPATCH" ]; then
        TR_POS_FAIL "scope=tmux reuse exited $tmux_rc or wrote no dispatch.md.  Output:
$(printf '%s\n' "$tmux_out" | sed 's/^/      | /')"
        skip "TR-pos scope=tmux: dispatch.md worktree == old worktree (skipped: scope=tmux reuse failed)"
        skip "TR-pos scope=tmux: dispatch.md reuse-claude-effective=true (skipped: scope=tmux reuse failed)"
    else
        local tmux_wt tmux_rce
        tmux_wt="$(tr_fm "$TMUX_DISPATCH" worktree)"
        tmux_rce="$(tr_fm "$TMUX_DISPATCH" reuse-claude-effective)"
        if [ "$tmux_wt" = "$OLD_WORKTREE" ]; then
            TR_POS_PASS "scope=tmux: dispatch.md worktree == old worktree"
        else
            TR_POS_FAIL "scope=tmux: dispatch.md worktree='$tmux_wt' != old worktree '$OLD_WORKTREE' (the new task's worktree: field must be ignored; cwd follows the reused pane)"
        fi
        if [ "$tmux_rce" = "true" ]; then
            TR_POS_PASS "scope=tmux: dispatch.md reuse-claude-effective=true"
        else
            TR_POS_FAIL "scope=tmux: dispatch.md reuse-claude-effective='$tmux_rce' != 'true'"
        fi
    fi

    trpos_teardown
    TR_POS_PASS "fixture teardown clean"
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

    # ---- T7''' (go-build-io-optimization) -------------------------------
    # The Go build I/O optimization injection feature adds load-bearing doc
    # strings.  Per design §Testing Plan T7 ("README/CLAUDE/project-structure
    # 含新关键串，如 orch-build-env.sh、ZYZ_GO_BUILD_OPT") and §Acceptance
    # Criteria ("文档讲清 worker × p 模型、三个开关、降级、tmpfs 撑爆风险 + 观察
    # 命令").  These are positive literal anchors so a future doc edit cannot
    # silently drop the new helper / its three tunable env switches.

    # (A) README.md documents the helper + all three tunable env switches.
    check_grep_fixed "README.md" \
        "T7''' README.md references the new helper 'orch-build-env.sh'" \
        "orch-build-env.sh"
    check_grep_fixed "README.md" \
        "T7''' README.md documents 'ZYZ_GO_BUILD_OPT' master switch" \
        "ZYZ_GO_BUILD_OPT"
    check_grep_fixed "README.md" \
        "T7''' README.md documents 'ZYZ_GO_BUILD_P' (-p cap)" \
        "ZYZ_GO_BUILD_P"
    check_grep_fixed "README.md" \
        "T7''' README.md documents 'ZYZ_GO_TMPFS_DIR' (tmpfs base)" \
        "ZYZ_GO_TMPFS_DIR"
    # The README must surface the tmpfs blow-up observation command (df/free)
    # so an operator can watch RAM-disk usage — design Risk + Acceptance.
    if [ -f "$readme" ]; then
        if grep -qF "/dev/shm" "$readme" && grep -qF "free -h" "$readme"; then
            pass "T7''' README.md gives a tmpfs observation command (df /dev/shm + free -h)"
        else
            fail "T7''' README.md does not surface the tmpfs blow-up observation command (need '/dev/shm' and 'free -h')"
        fi
    fi

    # (B) CLAUDE.md mentions the new helper (the orch-*.sh helper list line
    #     names each script; orch-build-env.sh must be included).
    check_grep_fixed "CLAUDE.md" \
        "T7''' CLAUDE.md references 'orch-build-env.sh'" \
        "orch-build-env.sh"

    # (C) docs/conventions/project-structure.md lists the new helper.
    check_grep_fixed "docs/conventions/project-structure.md" \
        "T7''' project-structure.md lists 'orch-build-env.sh' in the helper list" \
        "orch-build-env.sh"
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

    # ---- TR-driver (orch-reuse-worker design §Testing Plan T9): presence-only
    #      guards for the reuse-dispatch driver contract in BOTH mirror copies.
    #      T9 does presence ONLY; the mirror byte-equality of the new
    #      `## intent=reuse-dispatch` section (incl. the in-band runtime-config
    #      block) is covered by T10's whole-body diff on the driver pair — we do
    #      NOT add a byte-equality anchor here (design RC7 / Testing Plan: "T9
    #      只做存在性，不做镜像逐字 diff").
    local rdrvf
    for rdrvf in "$drv_agent" "$drv_sub"; do
        # (a) the new L2 driver intent value.
        check_grep_fixed "$rdrvf" \
            "TR-driver intent 'reuse-dispatch' present in $rdrvf" \
            "reuse-dispatch"
        # (b) the in-band runtime-config block fence keyword.
        check_grep_fixed "$rdrvf" \
            "TR-driver in-band block 'reuse-runtime-config' present in $rdrvf" \
            "reuse-runtime-config"
        # (c) the in-band block's worker-status-file override key (lower-case,
        #     hyphenated; must match orch-reuse-worker.sh + execute-task contract).
        check_grep_fixed "$rdrvf" \
            "TR-driver in-band key 'worker-status-file' present in $rdrvf" \
            "worker-status-file"
        # (d) the in-band block's task-id override key.
        check_grep_fixed "$rdrvf" \
            "TR-driver in-band key 'task-id' present in $rdrvf" \
            "task-id"
        # (e) the `## Inputs` intent enum line must list ALL FOUR values.  We
        #     anchor on the single line that carries every value in order
        #     (ERE: the four backtick-quoted tokens on one line) so a future
        #     edit that drops `reuse-dispatch` from the enum (but mentions it in
        #     a section heading) still turns this red.
        check_grep "$rdrvf" \
            "TR-driver '## Inputs' intent enum line lists all four values in $rdrvf" \
            '`first-dispatch`.*`intervene`.*`relay-confirmation`.*`reuse-dispatch`'
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

# ---------------------------------------------------------------------------
# CONSOL. Consolidation-pass regression guards. Each pins a bug that was found
# by audit and verified by execution; all are pure file reads (no tmux, no git),
# so this group runs unconditionally.
#
#  (a) approved-token boundary. orch-merge-and-cleanup.sh bounded its `approved`
#      token with a class omitting `-`, so `cleanup-approved` (and
#      `not-approved`) cleared the gate — the narrow cleanup token alone could
#      trigger merge + push + the terminal `state: completed`. Only a real
#      `approved` may pass; the near-miss tokens must exit 10.
#  (b) heartbeat-threshold env validation. A non-numeric ZYZ_HEARTBEAT_* value
#      reached an arithmetic context and aborted the helper with exit 1 (bash
#      `set -u` reads the string as a variable name) — an undocumented code
#      that silently blinded L1's per-tick poll of every worker.
#  (c) worktree-numbering-gap detection in the READERS. Spawn rejects a hole
#      with exit 5, but the readers broke at the first empty worktree-N and
#      silently truncated the repo set (merge reported success having merged
#      only the repos before the hole). A reader must not be more permissive
#      than the writer.
# ---------------------------------------------------------------------------
run_CONSOL() {
    say_header "CONSOL consolidation-pass regression guards"

    local root
    root="$(mktemp -d "${TMPDIR:-/tmp}/zyz-consol.XXXXXX")"
    trap 'rm -rf "$root"' EXIT

    # --- (a) approved-token boundary ------------------------------------
    local mac="$REPO_ROOT/scripts/orch-merge-and-cleanup.sh"
    local tok
    for tok in cleanup-approved not-approved; do
        local ld="$root/gate-$tok"
        mkdir -p "$ld/tasks"
        {
            echo "---"; echo "task-id: foo"; echo "source-repo: $root/norepo"
            echo "state: in-progress"; echo "branch: task/foo"; echo "base: main"
            echo "worktree: $root/nowt"; echo "tmux-session: zyz-task-foo"; echo "---"
            echo ""; echo "# foo"; echo ""; echo "## Pending Merge Approval"; echo ""; echo "$tok"
        } >"$ld/tasks/foo.md"
        if [ -x "$mac" ]; then
            run_and_check_exit 10 \
                "CONSOL(a) '$tok' alone must NOT satisfy the 'approved' gate" \
                bash "$mac" foo "$ld" main
        else
            skip "CONSOL(a) '$tok' alone must NOT satisfy the 'approved' gate (script missing)"
        fi
    done

    # --- (b) malformed threshold env must not exit 1 ---------------------
    local chk="$REPO_ROOT/scripts/orch-check-worker.sh"
    local ld2="$root/thresh"
    mkdir -p "$ld2/tasks" "$ld2/runtime/foo"
    {
        echo "---"; echo "task-id: foo"; echo "source-repo: $root/norepo"
        echo "state: in-progress"; echo "worktree: $root/nowt"
        echo "tmux-session: zyz-task-foo"; echo "---"; echo ""; echo "# foo"
    } >"$ld2/tasks/foo.md"
    date -u +%Y-%m-%dT%H:%M:%SZ >"$ld2/runtime/foo/heartbeat"
    if [ -x "$chk" ] && command -v tmux >/dev/null 2>&1; then
        local rc_b
        ZYZ_HEARTBEAT_STALE_SEC=abc bash "$chk" foo "$ld2" </dev/null >/dev/null 2>&1
        rc_b=$?
        if [ "$rc_b" -eq 0 ]; then
            pass "CONSOL(b) malformed ZYZ_HEARTBEAT_STALE_SEC falls back to default (exit 0, not 1)"
        else
            fail "CONSOL(b) malformed ZYZ_HEARTBEAT_STALE_SEC gave exit=$rc_b, expected 0 (an unvalidated value reaching arithmetic aborts under set -u)"
        fi
        ZYZ_HEARTBEAT_WAITING_USER_SEC=xyz bash "$chk" foo "$ld2" </dev/null >/dev/null 2>&1
        rc_b=$?
        if [ "$rc_b" -eq 0 ]; then
            pass "CONSOL(b) malformed ZYZ_HEARTBEAT_WAITING_USER_SEC falls back to default (exit 0, not 1)"
        else
            fail "CONSOL(b) malformed ZYZ_HEARTBEAT_WAITING_USER_SEC gave exit=$rc_b, expected 0"
        fi
    else
        skip "CONSOL(b) malformed ZYZ_HEARTBEAT_STALE_SEC falls back to default (orch-check-worker.sh or tmux unavailable)"
        skip "CONSOL(b) malformed ZYZ_HEARTBEAT_WAITING_USER_SEC falls back to default (orch-check-worker.sh or tmux unavailable)"
    fi

    # --- (c) numbering-gap detection in the readers ----------------------
    # dispatch.md declares worktree + worktree-3 but NO worktree-2. Readers must
    # refuse rather than silently merging/cleaning only repo 1.
    local ld3="$root/gap"
    mkdir -p "$ld3/tasks" "$ld3/runtime/foo"
    {
        echo "---"; echo "task-id: foo"; echo "tmux-session: zyz-task-foo"
        echo "worktree: $root/wt1"; echo "source-repo: $root/r1"
        echo "branch: task/foo"; echo "base: main"
        echo "worktree-3: $root/wt3"; echo "source-repo-3: $root/r3"
        echo "branch-3: task/foo"; echo "base-3: main"; echo "---"
    } >"$ld3/runtime/foo/dispatch.md"
    {
        echo "---"; echo "task-id: foo"; echo "source-repo: $root/r1"
        echo "state: in-progress"; echo "branch: task/foo"; echo "base: main"
        echo "worktree: $root/wt1"; echo "tmux-session: zyz-task-foo"; echo "---"
        echo ""; echo "# foo"; echo ""; echo "## Pending Merge Approval"; echo ""
        echo "merge"; echo "approved"
    } >"$ld3/tasks/foo.md"
    mkdir -p "$root/wt1" "$root/wt3"

    local gapscript gapname gapexit
    for gapname in orch-merge:11 orch-merge-and-cleanup:11 orch-cleanup-worker:8; do
        gapscript="$REPO_ROOT/scripts/${gapname%%:*}.sh"
        gapexit="${gapname##*:}"
        if [ ! -x "$gapscript" ]; then
            skip "CONSOL(c) ${gapname%%:*}.sh refuses a worktree-numbering gap (script missing)"
            continue
        fi
        local rc_c out_c
        if [ "${gapname%%:*}" = "orch-cleanup-worker" ]; then
            out_c="$(bash "$gapscript" foo "$ld3" --force </dev/null 2>&1 >/dev/null || true)"
            bash "$gapscript" foo "$ld3" --force </dev/null >/dev/null 2>&1
            rc_c=$?
        else
            out_c="$(bash "$gapscript" foo "$ld3" main </dev/null 2>&1 >/dev/null || true)"
            bash "$gapscript" foo "$ld3" main </dev/null >/dev/null 2>&1
            rc_c=$?
        fi
        if [ "$rc_c" -eq "$gapexit" ] && printf '%s' "$out_c" | grep -qi 'numbering gap'; then
            pass "CONSOL(c) ${gapname%%:*}.sh refuses a worktree-numbering gap (exit $gapexit + diagnostic)"
        else
            fail "CONSOL(c) ${gapname%%:*}.sh did NOT refuse a worktree-numbering gap: got exit=$rc_c (expected $gapexit), stderr: $out_c"
        fi
    done

    trap - EXIT
    rm -rf "$root"
}

run_T10() {
    say_header "T10  agents/ <-> subagents/ mirror body-equality (test-gate S1)"

    t10_mirror_diff "agents/implementation-agent.md" \
                    "subagents/implementation-agent.md" \
                    "implementation-agent"
    t10_mirror_diff "agents/review-agent.md" \
                    "subagents/review-agent.md" \
                    "review-agent"
    # test-agent was the one role pair left unguarded (the other three are
    # covered here), so a bullet added on one side could silently drift on the
    # other.  Same baseline shape as the implementation/review pairs, so the
    # existing normalizer applies unchanged.
    t10_mirror_diff "agents/test-agent.md" \
                    "subagents/test-agent.md" \
                    "test-agent"

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
# T12. orch-build-env.sh — Go build I/O optimization injection helper.
#
# Deterministic, API-free, tmux-free unit tests for the standalone helper
# scripts/orch-build-env.sh (design task go-build-io-optimization §Testing Plan
# / §Acceptance Criteria).  The helper reads three host env vars and prints ONE
# shell snippet line to stdout (empty when disabled); spawn / reuse send-keys
# that line into a fresh worker pane so each `go build` writes intermediates to
# tmpfs (GOTMPDIR) and lowers per-build concurrency (GOFLAGS=-p=N).
#
# We test on three axes:
#   (1) STDOUT shape — what literals the baked snippet does / does not contain
#       under controlled env (default, OPT off, -p clamp boundaries, tmpfs dir
#       override + single-quote rejection).
#   (2) RUNTIME contract — `eval` the emitted snippet in a CLEAN subshell and
#       observe the resulting GOTMPDIR / GOFLAGS.  This is the load-bearing part:
#       it proves auto-degrade (no tmpfs => GOTMPDIR stays unset, GOFLAGS still
#       set) and no-clobber (a pane-inherited GOTMPDIR/GOFLAGS always wins).
#   (3) WIRING consistency — both orch-spawn-worker.sh AND orch-reuse-worker.sh
#       source-call orch-build-env.sh, in lockstep, so the two injection points
#       cannot drift.
#
# The helper runs with `set -euo pipefail`; we always invoke it via a fresh
# `bash <script>` with `env -i`-style controlled env so host GOTMPDIR/GOFLAGS or
# stray ZYZ_GO_* vars in the operator's shell cannot leak into the assertions.
# ---------------------------------------------------------------------------

# t12_emit <description> [VAR=val ...] :: result captured into T12_OUT / T12_RC
# Runs `bash scripts/orch-build-env.sh` with EXACTLY the given env (nothing
# inherited that could perturb output), captures stdout into the global
# T12_OUT, and the exit code into T12_RC.  Always returns 0 so callers keep
# going even when the helper is missing (the existence FAIL is recorded by the
# caller).  Uses `env -i` plus a minimal PATH so the helper can still find its
# coreutils (printf/grep/tr) but inherits none of the operator's ZYZ_GO_* /
# GOTMPDIR / GOFLAGS.  The first arg (description) is shifted off; everything
# after it is the KEY=VALUE env list handed to `env -i`.
T12_OUT=""
T12_RC=0
t12_emit() {
    local script="$REPO_ROOT/scripts/orch-build-env.sh"
    shift   # drop the description; remaining args are KEY=VALUE pairs
    local minpath="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
    T12_OUT="$(env -i PATH="$minpath" "$@" bash "$script" 2>/dev/null)"
    T12_RC=$?
    return 0
}

# t12_contains <description> <fixed-needle>
# PASS iff T12_OUT contains <fixed-needle> (literal).  Prints the actual output
# on FAIL so a mismatch is debuggable.
t12_contains() {
    local desc="$1"
    local needle="$2"
    case "$T12_OUT" in
        *"$needle"*) pass "T12 $desc (output contains '$needle')" ;;
        *) fail "T12 $desc — output did NOT contain '$needle'.  Actual stdout:
      | $T12_OUT" ;;
    esac
}

# t12_absent <description> <fixed-needle>
# PASS iff T12_OUT does NOT contain <fixed-needle>.
t12_absent() {
    local desc="$1"
    local needle="$2"
    case "$T12_OUT" in
        *"$needle"*) fail "T12 $desc — output UNEXPECTEDLY contained '$needle'.  Actual stdout:
      | $T12_OUT" ;;
        *) pass "T12 $desc (output does not contain '$needle')" ;;
    esac
}

# t12_empty <description>
# PASS iff T12_OUT is the empty string (injection disabled).
t12_empty() {
    local desc="$1"
    if [ -z "$T12_OUT" ]; then
        pass "T12 $desc (stdout empty as expected)"
    else
        fail "T12 $desc — expected EMPTY stdout but got:
      | $T12_OUT"
    fi
}

run_T12() {
    say_header "T12  orch-build-env.sh Go build I/O optimization helper"

    local script="scripts/orch-build-env.sh"
    if [ ! -x "$REPO_ROOT/$script" ]; then
        skip "T12 $script missing or not executable — all T12 stdout/runtime checks skipped"
        # Still run the wiring-consistency guard below: it greps source files,
        # independent of the helper being runnable.
        t12_wiring_guard
        return
    fi

    # =====================================================================
    # (A) DEFAULT (no ZYZ_GO_* env) — the canonical baked snippet.
    # =====================================================================
    t12_emit "default (no env)"
    if [ "$T12_RC" -ne 0 ]; then
        fail "T12 default invocation exited non-zero (rc=$T12_RC) — helper must always exit 0"
    else
        pass "T12 default invocation exits 0"
    fi
    # Sets GOTMPDIR (the tmpfs steer) and GOFLAGS=-p=4 (the default cap).
    t12_contains "default sets GOTMPDIR" "GOTMPDIR"
    t12_contains "default GOFLAGS uses -p=4 (default cap)" "-p=4"
    t12_contains "default exports GOFLAGS" "GOFLAGS"
    # The two no-clobber guards (literal, byte-exact from the design snippet).
    t12_contains 'default has GOTMPDIR no-clobber guard' '[ -z "${GOTMPDIR:-}" ]'
    t12_contains 'default has GOFLAGS no-clobber guard' '[ -z "${GOFLAGS:-}" ]'
    # The runtime existence+writable probe on the base dir, and the per-base
    # subdir literal.
    t12_contains "default references /dev/shm tmpfs base" "/dev/shm"
    t12_contains "default mkdir-creates the zyz-gobuild subdir" "zyz-gobuild"
    # Constraint 3: NEVER GOMAXPROCS, NEVER GOCACHE.
    t12_absent "default never sets GOMAXPROCS" "GOMAXPROCS"
    t12_absent "default never sets GOCACHE" "GOCACHE"
    # Trailing `; true` keeps the pane exit status clean.
    t12_contains "default ends with '; true' (clean pane exit status)" "; true"

    # =====================================================================
    # (B) MASTER SWITCH off — empty stdout for every falsey spelling.
    # =====================================================================
    t12_emit "ZYZ_GO_BUILD_OPT=0" ZYZ_GO_BUILD_OPT=0
    t12_empty "ZYZ_GO_BUILD_OPT=0 disables injection"
    t12_emit "ZYZ_GO_BUILD_OPT=false" ZYZ_GO_BUILD_OPT=false
    t12_empty "ZYZ_GO_BUILD_OPT=false disables injection"
    t12_emit "ZYZ_GO_BUILD_OPT=off" ZYZ_GO_BUILD_OPT=off
    t12_empty "ZYZ_GO_BUILD_OPT=off disables injection"
    t12_emit "ZYZ_GO_BUILD_OPT=no" ZYZ_GO_BUILD_OPT=no
    t12_empty "ZYZ_GO_BUILD_OPT=no disables injection"
    # Case-insensitive: an uppercase falsey value must also disable.
    t12_emit "ZYZ_GO_BUILD_OPT=OFF (uppercase)" ZYZ_GO_BUILD_OPT=OFF
    t12_empty "ZYZ_GO_BUILD_OPT=OFF (case-insensitive) disables injection"
    # A truthy / unrecognized value leaves injection ON (snippet emitted).
    t12_emit "ZYZ_GO_BUILD_OPT=1 (explicit on)" ZYZ_GO_BUILD_OPT=1
    t12_contains "ZYZ_GO_BUILD_OPT=1 keeps injection ON" "GOFLAGS"

    # =====================================================================
    # (C) -p value clamp — valid passes through, out-of-range/garbage -> 4,
    #     boundary 64 inclusive.
    # =====================================================================
    t12_emit "ZYZ_GO_BUILD_P=2" ZYZ_GO_BUILD_P=2
    t12_contains "ZYZ_GO_BUILD_P=2 emits -p=2" "-p=2"
    t12_emit "ZYZ_GO_BUILD_P=64 (upper boundary, inclusive)" ZYZ_GO_BUILD_P=64
    t12_contains "ZYZ_GO_BUILD_P=64 emits -p=64 (boundary in range)" "-p=64"
    t12_emit "ZYZ_GO_BUILD_P=999 (over the 64 clamp)" ZYZ_GO_BUILD_P=999
    t12_contains "ZYZ_GO_BUILD_P=999 falls back to -p=4 (clamped)" "-p=4"
    t12_absent "ZYZ_GO_BUILD_P=999 does NOT pass 999 through" "-p=999"
    t12_emit "ZYZ_GO_BUILD_P=65 (just over boundary)" ZYZ_GO_BUILD_P=65
    t12_contains "ZYZ_GO_BUILD_P=65 falls back to -p=4 (just over 64)" "-p=4"
    t12_emit "ZYZ_GO_BUILD_P=abc (non-numeric)" ZYZ_GO_BUILD_P=abc
    t12_contains "ZYZ_GO_BUILD_P=abc falls back to -p=4" "-p=4"
    t12_emit "ZYZ_GO_BUILD_P=0 (not a positive integer)" ZYZ_GO_BUILD_P=0
    t12_contains "ZYZ_GO_BUILD_P=0 falls back to -p=4" "-p=4"

    # =====================================================================
    # (D) tmpfs base dir override + single-quote rejection.
    # =====================================================================
    t12_emit "ZYZ_GO_TMPFS_DIR=/custom" ZYZ_GO_TMPFS_DIR=/custom
    t12_contains "ZYZ_GO_TMPFS_DIR=/custom references /custom base" "/custom"
    t12_contains "ZYZ_GO_TMPFS_DIR=/custom builds /custom/zyz-gobuild" "/custom/zyz-gobuild"
    # A value containing a single quote would break the single-quote wrapping in
    # the emitted snippet, so the helper must REJECT it and fall back to
    # /dev/shm.  We pass a literal `/ev'il` candidate and assert the output uses
    # /dev/shm and never echoes the quoted candidate.
    t12_emit "ZYZ_GO_TMPFS_DIR=/ev'il (single quote)" "ZYZ_GO_TMPFS_DIR=/ev'il"
    t12_contains "ZYZ_GO_TMPFS_DIR with single quote falls back to /dev/shm" "/dev/shm"
    t12_absent "ZYZ_GO_TMPFS_DIR with single quote does NOT use the quoted value" "/ev'il"

    # =====================================================================
    # (E) RUNTIME contract — `eval` the snippet in a CLEAN subshell and observe
    #     the resulting GOTMPDIR / GOFLAGS.  THE most important assertions.
    # =====================================================================
    t12_runtime_degrade
    t12_runtime_tmpfs_present
    t12_runtime_no_clobber

    # =====================================================================
    # (F) WIRING consistency — both injection points call the helper.
    # =====================================================================
    t12_wiring_guard
}

# t12_eval_capture <snippet> <preset-GOTMPDIR-or-empty> <preset-GOFLAGS-or-empty>
#   :: sets T12_EVAL_GOTMPDIR and T12_EVAL_GOFLAGS to the post-eval values.
# Runs the snippet in a CLEAN child bash with `env -i` so NOTHING from the
# operator's environment leaks in.  When a preset value is non-empty it is
# pre-exported BEFORE the eval, to simulate a pane that already inherited that
# var (the no-clobber scenario).  After eval, the child prints the two vars on
# two delimited lines which we parse out.  The sentinel `__UNSET__` distinguishes
# "variable not set at all" from "set to empty string".
T12_EVAL_GOTMPDIR=""
T12_EVAL_GOFLAGS=""
t12_eval_capture() {
    local snippet="$1"
    local preset_tmpdir="$2"
    local preset_goflags="$3"
    # Build the child program.  We pre-export presets (only when non-empty),
    # eval the snippet, then emit the two vars with an unambiguous sentinel.
    local preset_block=""
    if [ -n "$preset_tmpdir" ]; then
        preset_block="export GOTMPDIR='$preset_tmpdir'; "
    fi
    if [ -n "$preset_goflags" ]; then
        preset_block="${preset_block}export GOFLAGS='$preset_goflags'; "
    fi
    local prog
    prog="${preset_block}eval \"\$SNIPPET\"; printf 'GOTMPDIR=%s\n' \"\${GOTMPDIR-__UNSET__}\"; printf 'GOFLAGS=%s\n' \"\${GOFLAGS-__UNSET__}\""
    local out
    # SNIPPET is passed via env so quoting inside it survives intact; PATH gives
    # the eval'd snippet access to mkdir/[ etc.
    out="$(env -i PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
        SNIPPET="$snippet" bash -c "$prog" 2>/dev/null)"
    T12_EVAL_GOTMPDIR="$(printf '%s\n' "$out" | sed -n 's/^GOTMPDIR=//p')"
    T12_EVAL_GOFLAGS="$(printf '%s\n' "$out" | sed -n 's/^GOFLAGS=//p')"
}

# Runtime case 1: base dir absent/non-writable => auto-degrade.
#   Point ZYZ_GO_TMPFS_DIR at a guaranteed-nonexistent path.  In a clean pane
#   (GOTMPDIR/GOFLAGS unset) the snippet's `[ -d ] && [ -w ]` probe is FALSE, so
#   GOTMPDIR must stay UNSET while GOFLAGS is still set.  This is the
#   macOS-no-/dev/shm degrade path and MUST pass on the macOS test host.
t12_runtime_degrade() {
    if [ ! -x "$REPO_ROOT/scripts/orch-build-env.sh" ]; then
        skip "T12 runtime-degrade (helper missing)"
        return
    fi
    local nonexistent="/nonexistent-zyz-xyz-$$-degrade"
    t12_emit "degrade base" "ZYZ_GO_TMPFS_DIR=$nonexistent"
    if [ -z "$T12_OUT" ]; then
        fail "T12 runtime-degrade — helper produced empty snippet (cannot eval)"
        return
    fi
    t12_eval_capture "$T12_OUT" "" ""
    if [ "$T12_EVAL_GOTMPDIR" = "__UNSET__" ]; then
        pass "T12 runtime-degrade: GOTMPDIR stays UNSET when base dir is absent (auto-degrade)"
    else
        fail "T12 runtime-degrade: expected GOTMPDIR UNSET (degrade) but it was set to '$T12_EVAL_GOTMPDIR' (base '$nonexistent' must not exist)"
    fi
    if [ "$T12_EVAL_GOFLAGS" = "-p=4" ]; then
        pass "T12 runtime-degrade: GOFLAGS still set to -p=4 even when GOTMPDIR degraded"
    else
        fail "T12 runtime-degrade: expected GOFLAGS='-p=4' (set regardless of tmpfs) but got '$T12_EVAL_GOFLAGS'"
    fi
}

# Runtime case 2: real writable temp base => GOTMPDIR set + dir created.
#   Use mktemp -d as ZYZ_GO_TMPFS_DIR.  In a clean pane the probe passes, the
#   snippet mkdir -p's <base>/zyz-gobuild and exports GOTMPDIR to it.  Assert the
#   value AND that the directory now exists.  Clean up after.
t12_runtime_tmpfs_present() {
    if [ ! -x "$REPO_ROOT/scripts/orch-build-env.sh" ]; then
        skip "T12 runtime-tmpfs-present (helper missing)"
        return
    fi
    local tmpbase
    tmpbase="$(mktemp -d "${TMPDIR:-/tmp}/zyz-gobuild-t12.XXXXXX")" || {
        skip "T12 runtime-tmpfs-present (mktemp -d failed)"
        return
    }
    t12_emit "real tmpfs base" "ZYZ_GO_TMPFS_DIR=$tmpbase"
    if [ -z "$T12_OUT" ]; then
        fail "T12 runtime-tmpfs-present — helper produced empty snippet (cannot eval)"
        rm -rf "$tmpbase"
        return
    fi
    t12_eval_capture "$T12_OUT" "" ""
    local expected="$tmpbase/zyz-gobuild"
    if [ "$T12_EVAL_GOTMPDIR" = "$expected" ]; then
        pass "T12 runtime-tmpfs-present: GOTMPDIR set to '$expected'"
    else
        fail "T12 runtime-tmpfs-present: expected GOTMPDIR='$expected' but got '$T12_EVAL_GOTMPDIR'"
    fi
    if [ -d "$expected" ]; then
        pass "T12 runtime-tmpfs-present: GOTMPDIR directory '$expected' was created by mkdir -p"
    else
        fail "T12 runtime-tmpfs-present: GOTMPDIR directory '$expected' was NOT created"
    fi
    rm -rf "$tmpbase"
}

# Runtime case 3: no-clobber — a pane that already has GOTMPDIR/GOFLAGS keeps
#   them, even with a real writable base that WOULD otherwise set GOTMPDIR.
#   Preset GOTMPDIR=/preset/keep and GOFLAGS=-p=9 in the (clean) child, then eval
#   the snippet built from a real writable base; assert BOTH stayed unchanged.
t12_runtime_no_clobber() {
    if [ ! -x "$REPO_ROOT/scripts/orch-build-env.sh" ]; then
        skip "T12 runtime-no-clobber (helper missing)"
        return
    fi
    local tmpbase
    tmpbase="$(mktemp -d "${TMPDIR:-/tmp}/zyz-gobuild-t12nc.XXXXXX")" || {
        skip "T12 runtime-no-clobber (mktemp -d failed)"
        return
    }
    # Emit a snippet whose baked base IS writable, so the ONLY thing stopping the
    # export is the `-z` no-clobber guard reacting to the preset.
    t12_emit "no-clobber base" "ZYZ_GO_TMPFS_DIR=$tmpbase"
    if [ -z "$T12_OUT" ]; then
        fail "T12 runtime-no-clobber — helper produced empty snippet (cannot eval)"
        rm -rf "$tmpbase"
        return
    fi
    t12_eval_capture "$T12_OUT" "/preset/keep" "-p=9"
    if [ "$T12_EVAL_GOTMPDIR" = "/preset/keep" ]; then
        pass "T12 runtime-no-clobber: preset GOTMPDIR='/preset/keep' preserved (not overwritten)"
    else
        fail "T12 runtime-no-clobber: preset GOTMPDIR='/preset/keep' was CLOBBERED to '$T12_EVAL_GOTMPDIR' (no-clobber guard failed)"
    fi
    if [ "$T12_EVAL_GOFLAGS" = "-p=9" ]; then
        pass "T12 runtime-no-clobber: preset GOFLAGS='-p=9' preserved (not overwritten)"
    else
        fail "T12 runtime-no-clobber: preset GOFLAGS='-p=9' was CLOBBERED to '$T12_EVAL_GOFLAGS' (no-clobber guard failed)"
    fi
    # Defensive: the writable base proves the export WOULD have fired absent the
    # preset (the directory gets created by the eval regardless, since mkdir runs
    # before the export in the && chain ONLY when -z passes; here -z fails first,
    # so the subdir must NOT exist — confirming the guard short-circuited early).
    if [ ! -d "$tmpbase/zyz-gobuild" ]; then
        pass "T12 runtime-no-clobber: subdir NOT created (no-clobber short-circuits before mkdir)"
    else
        fail "T12 runtime-no-clobber: '$tmpbase/zyz-gobuild' was created — mkdir ran despite preset GOTMPDIR (guard ordering wrong)"
    fi
    rm -rf "$tmpbase"
}

# Wiring-consistency guard: BOTH spawn and reuse source-call orch-build-env.sh,
# in lockstep, so the two injection points cannot drift.  Fixed-string grep
# against each file (design §Testing Plan "一致性守护").
t12_wiring_guard() {
    check_grep_fixed "scripts/orch-spawn-worker.sh" \
        "T12 wiring: spawn calls orch-build-env.sh (injection point 1)" \
        "orch-build-env.sh"
    check_grep_fixed "scripts/orch-reuse-worker.sh" \
        "T12 wiring: reuse calls orch-build-env.sh (injection point 2, worktree scope)" \
        "orch-build-env.sh"

    # NEGATIVE lockstep half (design Testing Plan): the reuse injection is
    # scoped to the `worktree)` branch ONLY — it must NOT also fire in the
    # `tmux|both)` scope, where the pane runs an ALREADY-STARTED claude whose env
    # is frozen and into which send-keys'ing shell is harmful.  Proof: the call
    # appears EXACTLY ONCE in reuse, and that one occurrence is positioned BEFORE
    # the `tmux|both)` dispatch branch label that handles the send-keys path
    # (line ~449).  Both together pin the call to the worktree branch so a future
    # edit cannot leak it into the live-claude path.
    local reuse="$REPO_ROOT/scripts/orch-reuse-worker.sh"
    if [ ! -f "$reuse" ]; then
        fail "T12 wiring(neg): scripts/orch-reuse-worker.sh missing (cannot scope-check injection)"
    else
        local n_calls
        n_calls="$(grep -cF "orch-build-env.sh" "$reuse" 2>/dev/null || echo 0)"
        if [ "$n_calls" -eq 1 ]; then
            pass "T12 wiring(neg): reuse calls orch-build-env.sh EXACTLY once (not in tmux|both scope)"
        else
            fail "T12 wiring(neg): reuse has $n_calls orch-build-env.sh occurrences (expected exactly 1 — an extra occurrence risks injecting into a live-claude tmux|both pane)"
        fi
        # The single injection line must precede the LAST `tmux|both)` dispatch
        # scope label (the branch that send-keys into the reused live pane).
        local inj_line tmuxboth_line
        inj_line="$(grep -nF "orch-build-env.sh" "$reuse" 2>/dev/null | tail -1 | cut -d: -f1)"
        tmuxboth_line="$(grep -nE '^[[:space:]]*tmux\|both\)' "$reuse" 2>/dev/null | tail -1 | cut -d: -f1)"
        if [ -n "$inj_line" ] && [ -n "$tmuxboth_line" ] && [ "$inj_line" -lt "$tmuxboth_line" ]; then
            pass "T12 wiring(neg): reuse injection (line $inj_line) precedes the tmux|both dispatch branch (line $tmuxboth_line) — scoped to worktree)"
        else
            fail "T12 wiring(neg): reuse injection line ($inj_line) is NOT before the tmux|both branch label ($tmuxboth_line) — injection may have leaked into the live-claude scope"
        fi
    fi
}

# ===========================================================================
# MULTI-REPO GROUPS (task zyz-multi-repo-single-session, design 01/02/04).
#
# These groups cover the single-session / N-worktree feature: spawn builds N
# worktrees + 1 tmux session; dispatch.md carries the RESOLVED numbered field
# group (worktree-N / source-repo-N / branch-N / base-N); merge / cleanup /
# reuse read that group from dispatch.md (the authoritative repo set, design
# 02-D0), never re-discovering it from the master entry.
#
# CONVENTION NOTE — no EXIT trap.  Like T11b / T8-reuse-rewrite / TR-pos (all of
# which run AFTER T8), these groups deliberately do NOT install a `trap … EXIT`.
# T8 chained T6's EXIT trap; a fresh EXIT trap here would CLOBBER that chain and
# T6/T8 teardown (their F8 residue checks + tmproot removal) would silently never
# run.  Instead every group defines a synchronous teardown (kill any tmux
# sessions it created + rm -rf its mktemp -d root) and calls it on EVERY return
# path, so no scratch dir is ever leaked.
# ===========================================================================

# zyzm_init_git_repo <dir> — init a git repo at <dir> with a `main` branch and
# one initial commit.  Returns non-zero on any git failure so callers can SKIP.
zyzm_init_git_repo() {
    local dir="$1"
    mkdir -p "$dir" || return 1
    (
        cd "$dir" || exit 1
        git init -q . >/dev/null 2>&1 || exit 1
        git config user.email "multirepo@example.com"
        git config user.name "MultiRepo Test"
        git checkout -q -b main 2>/dev/null || git checkout -q main || exit 1
        echo "multi-repo fixture ($dir)" >README.md
        git add README.md
        git commit -q -m "initial" || exit 1
    ) || return 1
    return 0
}

# zyzm_write_master_entry <list-dir> <task-id> <primary-source-repo> [extra-fm-line ...]
# Writes a master entry whose ONLY repo-set frontmatter is the unnumbered
# `source-repo:` PLUS whatever literal extra frontmatter lines the caller passes
# (e.g. "source-repo-2: /path", "base-2: nope", "worktree-2: /has:colon").  The
# primary `worktree:`/`branch:`/`base:` numbered fields are deliberately NOT
# emitted here so the positive multi-repo cases exercise spawn's default
# sibling-layout + default-inheritance (finding-1 guard: the numbered group must
# be MATERIALIZED by spawn into dispatch.md, never copied from the entry).
zyzm_write_master_entry() {
    local list_dir="$1" task_id="$2" primary_repo="$3"
    shift 3
    mkdir -p "$list_dir/tasks"
    {
        echo "---"
        echo "task-id: $task_id"
        echo "project: $(basename "$primary_repo")"
        echo "source-repo: $primary_repo"
        local extra
        for extra in "$@"; do
            echo "$extra"
        done
        echo "state: ready"
        echo "priority: normal"
        echo "branch: task/$task_id"
        echo "base: main"
        echo "tmux-session: zyz-task-$task_id"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-07-22"
        echo "updated-at: 2026-07-22"
        echo "---"
        echo ""
        echo "# $task_id"
        echo ""
        echo "## Description"
        echo ""
        echo "Multi-repo spawn fixture (design 01/04). Finding-1 guard: numbered"
        echo "fields intentionally omitted so spawn must materialize them."
    } >"$list_dir/tasks/$task_id.md"
}

# ---------------------------------------------------------------------------
# T4-multi.  orch-spawn-worker.sh multi-repo spawn (design 01-D1..D4, 04 §T4-multi).
#
# Positive: a 2-repo entry (source-repo + source-repo-2, numbered worktree/branch/
# base OMITTED — finding-1 guard) spawns 2 sibling worktrees + 1 tmux session,
# materializes the RESOLVED numbered field group into dispatch.md, and prints
# worktree-2= / repo-count=2.  We run spawn with HOME pointed at a per-test dir so
# the DEFAULT sibling layout ($HOME/.zyz-worker/worktrees/<proj>/task/<id>/<repo>)
# lands under our mktemp -d root and is torn down with it.
#
# Negatives (exit 5, NOT 7): numbering gap (source-repo-3 w/o -2), a repo-2 that
# does not exist, two repos with the SAME basename + default layout (pairwise-
# distinct check must fire as exit 5 BEFORE any worktree is created — never let
# the 2nd `git worktree add` fail as exit 7), and a worktree-N override with ':'.
# Rollback (exit 7): repo 2's `git worktree add` fails (bad base-2) => repo 1's
# already-created worktree is rolled back.
#
# tmux-free vs gated: the numbering-gap + repo-2-nonexistent checks run BEFORE
# spawn's tmux/git dependency gate (like T4'), so they fire on a tmux-less host
# (git still required to build the primary fixture repo).  The positive spawn,
# same-basename, colon, and rollback cases all reach logic AFTER the dep gate (or
# need a real session/worktree), so they are gated on tmux+git.
# ---------------------------------------------------------------------------
run_T4_multi() {
    say_header "T4-multi orch-spawn-worker.sh multi-repo spawn"

    local spawn="$REPO_ROOT/scripts/orch-spawn-worker.sh"
    if [ ! -x "$spawn" ]; then
        skip "T4-multi (all) orch-spawn-worker.sh missing or not executable"
        return
    fi
    if ! command -v git >/dev/null 2>&1; then
        skip "T4-multi (all) git not available (cannot build fixture repos)"
        return
    fi

    local T4M_ROOT
    T4M_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t4m.XXXXXX")"
    local FAKE_HOME="$T4M_ROOT/home"
    mkdir -p "$FAKE_HOME"
    # Session created by the positive spawn (torn down synchronously — NO EXIT
    # trap; see the group-header note).
    local T4M_POS_SESSION=""
    zyzm_t4_teardown() {
        [ -n "$T4M_POS_SESSION" ] && tmux kill-session -t "$T4M_POS_SESSION" 2>/dev/null
        sleep 1
        rm -rf "$T4M_ROOT"
    }

    # Two independent primary/secondary repos with DISTINCT basenames.
    local REPO1="$T4M_ROOT/repo-alpha"
    local REPO2="$T4M_ROOT/repo-beta"
    if ! zyzm_init_git_repo "$REPO1" || ! zyzm_init_git_repo "$REPO2"; then
        skip "T4-multi (all) git fixture init failed"
        zyzm_t4_teardown
        return
    fi

    # ===================================================================
    # NEGATIVE (tmux-free): numbering gap — source-repo-3 present, -2 absent.
    # ===================================================================
    local list_gap="$T4M_ROOT/list-gap"
    zyzm_write_master_entry "$list_gap" "zyzm4gap" "$REPO1" "source-repo-3: $REPO2"
    run_and_check_exit_stderr_regex 5 \
        'error: source-repo numbering gap: source-repo-2 is missing but source-repo-3 is present' \
        "T4-multi (neg) numbering gap (source-repo-3 w/o -2) -> exit 5 + gap diagnostic" \
        env HOME="$FAKE_HOME" bash "$spawn" zyzm4gap "$list_gap"

    # ===================================================================
    # NEGATIVE (tmux-free): source-repo-2 points at a non-existent path.
    #   Per-repo validation runs BEFORE the dep gate, so this fires tmux-free
    #   and carries the multi-repo `repo 2 (<path>)` diagnostic prefix.
    # ===================================================================
    local list_r2ne="$T4M_ROOT/list-r2ne"
    local nonexistent="/nonexistent/zyz-orch-t4m-$$-repo2"
    zyzm_write_master_entry "$list_r2ne" "zyzm4r2ne" "$REPO1" "source-repo-2: $nonexistent"
    run_and_check_exit_stderr_regex 5 \
        "error: repo 2 \\($nonexistent\\): source-repo path does not exist" \
        "T4-multi (neg) source-repo-2 nonexistent -> exit 5 + 'repo 2' prefix" \
        env HOME="$FAKE_HOME" bash "$spawn" zyzm4r2ne "$list_r2ne"

    # ===================================================================
    # The remaining cases need tmux (positive spawn creates a real session;
    # same-basename / colon / rollback all reach post-dep-gate logic).  Gate
    # them; SKIP with a reason on a tmux-less host.
    # ===================================================================
    if ! command -v tmux >/dev/null 2>&1; then
        skip "T4-multi (pos) 2-repo spawn creates 2 sibling worktrees + 1 session (tmux not available)"
        skip "T4-multi (pos) stdout has worktree-2= and repo-count=2 (tmux not available)"
        skip "T4-multi (pos) dispatch.md carries resolved numbered field group (tmux not available)"
        skip "T4-multi (neg) same-basename default collision -> exit 5 pairwise-distinct (NOT exit 7) (tmux not available)"
        skip "T4-multi (neg) worktree-2 override containing ':' -> exit 5 (tmux not available)"
        skip "T4-multi (rollback) repo 2 worktree add fails -> exit 7 + repo 1 rolled back (tmux not available)"
        zyzm_t4_teardown
        return
    fi

    # ---- POSITIVE: 2-repo spawn, numbered fields OMITTED (finding-1 guard) ----
    local list_pos="$T4M_ROOT/list-pos"
    local POS_ID="zyzm4pos"
    T4M_POS_SESSION="zyz-task-$POS_ID"
    zyzm_write_master_entry "$list_pos" "$POS_ID" "$REPO1" "source-repo-2: $REPO2"
    local pos_out pos_rc
    pos_out="$(
        cd "$T4M_ROOT" \
        && env HOME="$FAKE_HOME" bash "$spawn" "$POS_ID" "$list_pos" </dev/null 2>&1
    )"
    pos_rc=$?

    if [ "$pos_rc" -ne 0 ]; then
        fail "T4-multi (pos) 2-repo spawn exited $pos_rc (expected 0).  Output:
$(printf '%s\n' "$pos_out" | sed 's/^/      | /')"
        skip "T4-multi (pos) stdout has worktree-2= and repo-count=2 (spawn failed)"
        skip "T4-multi (pos) dispatch.md carries resolved numbered field group (spawn failed)"
    else
        # Resolve the two DEFAULT sibling worktree paths under FAKE_HOME.
        local proj="$(basename "$REPO1")"
        local wt1="$FAKE_HOME/.zyz-worker/worktrees/$proj/task/$POS_ID/$(basename "$REPO1")"
        local wt2="$FAKE_HOME/.zyz-worker/worktrees/$proj/task/$POS_ID/$(basename "$REPO2")"
        local ok_sib="true"
        [ -d "$wt1" ] || ok_sib="false"
        [ -d "$wt2" ] || ok_sib="false"
        # Sibling layout: both under the SAME parent dir, dir name = repo basename.
        if [ "$ok_sib" = "true" ] \
            && [ "$(dirname "$wt1")" = "$(dirname "$wt2")" ] \
            && tmux has-session -t "$T4M_POS_SESSION" 2>/dev/null; then
            pass "T4-multi (pos) 2-repo spawn creates 2 sibling worktrees + 1 session"
        else
            fail "T4-multi (pos) sibling-layout/session check failed (wt1='$wt1' exists=$([ -d "$wt1" ] && echo y || echo n), wt2='$wt2' exists=$([ -d "$wt2" ] && echo y || echo n), same-parent=$([ "$(dirname "$wt1")" = "$(dirname "$wt2")" ] && echo y || echo n)).  Output:
$(printf '%s\n' "$pos_out" | sed 's/^/      | /')"
        fi

        # stdout: worktree-2=<non-empty> and repo-count=2.
        if printf '%s\n' "$pos_out" | grep -qE '^worktree-2=.+' \
            && printf '%s\n' "$pos_out" | grep -qxF 'repo-count=2'; then
            pass "T4-multi (pos) stdout has worktree-2= and repo-count=2"
        else
            fail "T4-multi (pos) stdout missing 'worktree-2=<val>' or 'repo-count=2'.  Output:
$(printf '%s\n' "$pos_out" | sed 's/^/      | /')"
        fi

        # dispatch.md carries the RESOLVED numbered group with NON-EMPTY values.
        local disp="$list_pos/runtime/$POS_ID/dispatch.md"
        local d_wt2 d_sr2 d_br2 d_ba2
        d_wt2="$(tr_fm "$disp" worktree-2)"
        d_sr2="$(tr_fm "$disp" source-repo-2)"
        d_br2="$(tr_fm "$disp" branch-2)"
        d_ba2="$(tr_fm "$disp" base-2)"
        if [ -n "$d_wt2" ] && [ -n "$d_sr2" ] && [ -n "$d_br2" ] && [ -n "$d_ba2" ]; then
            pass "T4-multi (pos) dispatch.md carries resolved numbered field group (worktree-2/source-repo-2/branch-2/base-2 all non-empty)"
        else
            fail "T4-multi (pos) dispatch.md numbered group incomplete: worktree-2='$d_wt2' source-repo-2='$d_sr2' branch-2='$d_br2' base-2='$d_ba2' (finding-1: spawn must materialize resolved values)"
        fi
        # Clean the positive session before the destructive negatives reuse HOME.
        tmux kill-session -t "$T4M_POS_SESSION" 2>/dev/null || true
        T4M_POS_SESSION=""
    fi

    # ---- NEGATIVE: two repos with the SAME basename + default layout ----
    # Both default worktree paths resolve identically; the pairwise-distinct
    # check (design D4-3b, finding 6) MUST fire as exit 5 BEFORE any worktree is
    # created — NOT let the 2nd `git worktree add` fail as exit 7.
    local dup_parent="$T4M_ROOT/dupdir"
    local dupA="$dup_parent/a/samebase"
    local dupB="$dup_parent/b/samebase"
    if zyzm_init_git_repo "$dupA" && zyzm_init_git_repo "$dupB"; then
        local list_dup="$T4M_ROOT/list-dup"
        zyzm_write_master_entry "$list_dup" "zyzm4dup" "$dupA" "source-repo-2: $dupB"
        run_and_check_exit_stderr_regex 5 \
            'error: worktree path collision between repo 1 and repo 2' \
            "T4-multi (neg) same-basename default collision -> exit 5 pairwise-distinct (NOT exit 7)" \
            env HOME="$FAKE_HOME" bash "$spawn" zyzm4dup "$list_dup"
    else
        skip "T4-multi (neg) same-basename default collision -> exit 5 pairwise-distinct (NOT exit 7) (fixture init failed)"
    fi

    # ---- NEGATIVE: worktree-2 override containing ':' (separator constraint) --
    local list_colon="$T4M_ROOT/list-colon"
    zyzm_write_master_entry "$list_colon" "zyzm4colon" "$REPO1" \
        "source-repo-2: $REPO2" "worktree-2: $T4M_ROOT/has:colon"
    run_and_check_exit_stderr_regex 5 \
        "error: repo 2 worktree path must not contain ':'" \
        "T4-multi (neg) worktree-2 override containing ':' -> exit 5" \
        env HOME="$FAKE_HOME" bash "$spawn" zyzm4colon "$list_colon"

    # ---- ROLLBACK: repo 2 worktree add fails -> repo 1 rolled back (exit 7) ---
    # Force repo 2's `git worktree add` to fail by giving it a base-2 that does
    # not exist as a ref (and no such local branch, so the `-b`/fallback both
    # fail).  Repo 1 succeeds first, so the failure must reverse-roll it back.
    # We give explicit worktree-N overrides inside T4M_ROOT so the created paths
    # are torn down with the root regardless of HOME.
    local list_rb="$T4M_ROOT/list-rb"
    local rb_wt1="$T4M_ROOT/rb-wt/repo1"
    local rb_wt2="$T4M_ROOT/rb-wt/repo2"
    zyzm_write_master_entry "$list_rb" "zyzm4rb" "$REPO1" \
        "worktree: $rb_wt1" \
        "source-repo-2: $REPO2" "worktree-2: $rb_wt2" "base-2: no-such-base-ref"
    local rb_out rb_rc
    rb_out="$(
        cd "$T4M_ROOT" \
        && env HOME="$FAKE_HOME" bash "$spawn" zyzm4rb "$list_rb" </dev/null 2>&1
    )"
    rb_rc=$?
    if [ "$rb_rc" -eq 7 ] && [ ! -e "$rb_wt1" ]; then
        pass "T4-multi (rollback) repo 2 worktree add fails -> exit 7 + repo 1 rolled back"
    else
        fail "T4-multi (rollback) expected exit 7 + repo 1 worktree '$rb_wt1' removed, got exit=$rb_rc, repo1-present=$([ -e "$rb_wt1" ] && echo y || echo n).  Output:
$(printf '%s\n' "$rb_out" | sed 's/^/      | /')"
    fi
    # Clean any tmux session the rollback attempt might have created (spawn
    # creates the session only AFTER worktrees; rollback exits at worktree step
    # so none should exist, but be defensive).
    tmux kill-session -t "zyz-task-zyzm4rb" 2>/dev/null || true

    zyzm_t4_teardown
}

# ---------------------------------------------------------------------------
# T5-multi.  orch-check-worker.sh rewrite_dispatch_atomic preserves the multi-repo
#            numbered field group across a Phase-2 rewrite (design 01-D5, 02-D0,
#            04 §T5-multi).  This is the finding-1 companion at the check layer:
#            the fixed-field-list rewriter must read back + re-emit worktree-N /
#            source-repo-N / branch-N / base-N, or a later poll would SILENTLY
#            DROP them and merge/cleanup would then only see repo 1.
#
# UNIT test — needs `tmux` on PATH (check hard-exits 3 otherwise) but NO real
# session/worktree/git.  We hand-build a dispatch.md carrying a resolved numbered
# group (repo 2) with the Phase-2 trio populated (claude-pid/sid/transcript) but
# first-seen-iso EMPTY, so Step D stamps first-seen -> NEEDS_REWRITE=true ->
# rewrite_dispatch_atomic fires.  Mirrors T8-reuse-rewrite exactly.
# ---------------------------------------------------------------------------
run_T5_multi() {
    say_header "T5-multi orch-check-worker.sh preserves numbered field group across rewrite"

    local check="$REPO_ROOT/scripts/orch-check-worker.sh"

    if ! command -v tmux >/dev/null 2>&1; then
        skip "T5-multi check exits 0 on a multi-repo dispatch.md (tmux not available)"
        skip "T5-multi numbered field 'worktree-2' survives rewrite (tmux not available)"
        skip "T5-multi numbered field 'source-repo-2' survives rewrite (tmux not available)"
        skip "T5-multi numbered field 'branch-2' survives rewrite (tmux not available)"
        skip "T5-multi numbered field 'base-2' survives rewrite (tmux not available)"
        return
    fi
    if [ ! -x "$check" ]; then
        skip "T5-multi check exits 0 on a multi-repo dispatch.md (orch-check-worker.sh missing or not executable)"
        skip "T5-multi numbered field 'worktree-2' survives rewrite (orch-check-worker.sh missing or not executable)"
        skip "T5-multi numbered field 'source-repo-2' survives rewrite (orch-check-worker.sh missing or not executable)"
        skip "T5-multi numbered field 'branch-2' survives rewrite (orch-check-worker.sh missing or not executable)"
        skip "T5-multi numbered field 'base-2' survives rewrite (orch-check-worker.sh missing or not executable)"
        return
    fi

    local T5M_ROOT
    T5M_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t5m.XXXXXX")"
    # No EXIT trap (see group-header note) — explicit rm on every path.

    local LIST_DIR="$T5M_ROOT/list"
    local TASK_ID="zyzm5"
    local SESSION="zyz-task-$TASK_ID"
    local RUNTIME="$LIST_DIR/runtime/$TASK_ID"
    local DISPATCH="$RUNTIME/dispatch.md"
    mkdir -p "$RUNTIME"

    # Minimal master entry (check reads heartbeat-stale-sec / tmux-session).
    zyzm_write_master_entry "$LIST_DIR" "$TASK_ID" "/tmp/zyz-orch-t5m-srcrepo" \
        "source-repo-2: /tmp/zyz-orch-t5m-srcrepo2"

    # Phase-2 trio pre-populated; first-seen EMPTY (forces Step D rewrite).
    local FAKE_PID="525252"
    local FAKE_SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local FAKE_TRANSCRIPT="$T5M_ROOT/$FAKE_SID.jsonl"
    printf '%s\n' '{"type":"user"}' >"$FAKE_TRANSCRIPT"

    # Hand-built multi-repo dispatch.md: the RESOLVED numbered group (repo 2)
    # sits right after the unnumbered `base:` line, exactly as spawn writes it.
    {
        echo "---"
        echo "task-id: $TASK_ID"
        echo "spawn-iso: 2026-07-22T00:00:00+0000"
        echo "tmux-session: $SESSION"
        echo "tmux-window-id: @3"
        echo "tmux-pane-id: %3"
        echo "shell-pid: 333333"
        echo "worktree: /tmp/zyz-orch-t5m-worktrees/$TASK_ID/repo1"
        echo "source-repo: /tmp/zyz-orch-t5m-srcrepo"
        echo "branch: task/$TASK_ID"
        echo "base: main"
        echo "worktree-2: /tmp/zyz-orch-t5m-worktrees/$TASK_ID/repo2"
        echo "source-repo-2: /tmp/zyz-orch-t5m-srcrepo2"
        echo "branch-2: task/$TASK_ID"
        echo "base-2: main"
        echo "plugin-root: $REPO_ROOT"
        echo "encoded-cwd: -tmp-zyz-orch-t5m-worktrees-$TASK_ID-repo1"
        echo "reuse-from:"
        echo "reuse-scope:"
        echo "reuse-claude-effective:"
        echo "heartbeat-window-id:"
        echo "claude-pid: $FAKE_PID"
        echo "claude-session-id: $FAKE_SID"
        echo "transcript-path: $FAKE_TRANSCRIPT"
        echo "first-seen-iso:"
        echo "---"
        echo ""
        echo "# Dispatch Info"
        echo ""
        echo "## Recovery"
        echo ""
        echo "(awaiting claude startup ...)"
    } >"$DISPATCH"

    local m_out m_rc
    m_out="$(
        cd "$T5M_ROOT" && bash "$check" "$TASK_ID" "$LIST_DIR" </dev/null 2>&1
    )"
    m_rc=$?

    if [ "$m_rc" -eq 0 ]; then
        pass "T5-multi check exits 0 on a multi-repo dispatch.md"
    else
        fail "T5-multi check exited $m_rc (expected 0).  Output:
$(printf '%s\n' "$m_out" | sed 's/^/      | /')"
    fi

    # Re-read the numbered group; each must SURVIVE the fixed-field rewrite.
    local g_wt2 g_sr2 g_br2 g_ba2
    g_wt2="$(tr_fm "$DISPATCH" worktree-2)"
    g_sr2="$(tr_fm "$DISPATCH" source-repo-2)"
    g_br2="$(tr_fm "$DISPATCH" branch-2)"
    g_ba2="$(tr_fm "$DISPATCH" base-2)"

    if [ "$g_wt2" = "/tmp/zyz-orch-t5m-worktrees/$TASK_ID/repo2" ]; then
        pass "T5-multi numbered field 'worktree-2' survives rewrite"
    else
        fail "T5-multi 'worktree-2'='$g_wt2' (expected '/tmp/zyz-orch-t5m-worktrees/$TASK_ID/repo2') — DROPPED by the fixed-field-list rewrite"
    fi
    if [ "$g_sr2" = "/tmp/zyz-orch-t5m-srcrepo2" ]; then
        pass "T5-multi numbered field 'source-repo-2' survives rewrite"
    else
        fail "T5-multi 'source-repo-2'='$g_sr2' (expected '/tmp/zyz-orch-t5m-srcrepo2') — DROPPED by the rewrite"
    fi
    if [ "$g_br2" = "task/$TASK_ID" ]; then
        pass "T5-multi numbered field 'branch-2' survives rewrite"
    else
        fail "T5-multi 'branch-2'='$g_br2' (expected 'task/$TASK_ID') — DROPPED by the rewrite"
    fi
    if [ "$g_ba2" = "main" ]; then
        pass "T5-multi numbered field 'base-2' survives rewrite"
    else
        fail "T5-multi 'base-2'='$g_ba2' (expected 'main') — DROPPED by the rewrite"
    fi

    rm -rf "$T5M_ROOT"
}

# ---------------------------------------------------------------------------
# T6-multi.  End-to-end 1-task-2-repos (design 04 §T6-multi, the T6 mirror
#            reversed: T6 = 2 tasks × 1 repo; this = 1 task × 2 repos).
#
# finding-1 guard fixture: the master entry declares ONLY source-repo +
# source-repo-2 (numbered worktree/branch/base OMITTED).  spawn -> 2 sibling
# worktrees + 1 session -> a unique commit in EACH worktree -> `approved` token ->
# merge-and-cleanup -> assert BOTH repos' base contain their own commit, BOTH
# worktrees removed, state=completed.  If the impl regressed to discovering the
# repo set from the master entry (finding 1), repo 2 would be silently skipped and
# the "repo 2 base contains its commit" / "repo 2 worktree removed" assertions
# would FAIL, surfacing the defect.
#
# Idempotency scoping (design 04-R2): the NAIVE second full merge-and-cleanup run
# returns exit 11 (dispatch.md was archived by cleanup -> single-repo fallback ->
# the fixture master entry has NO `worktree:` field -> worktree missing) — NOT a
# no-op exit 0.  The "already-merged no-op" idempotency belongs to the pre-cleanup
# partial-failure case, tested in T11b-multi.
#
# No origin remote is configured, so the gh path is skipped (HAS_ORIGIN=false) and
# the merge runs via local `git merge --no-ff` — deterministic, no network/gh.
# ---------------------------------------------------------------------------
T6M_FAIL() { fail "T6-multi $1"; }
T6M_PASS() { pass "T6-multi $1"; }

T6M_SKIP_ALL() {
    local reason="$1" i
    for i in \
        "spawn 1-task-2-repos exits 0" \
        "2 sibling worktrees + 1 tmux session created" \
        "dispatch.md carries resolved numbered group (finding-1 guard)" \
        "merge-and-cleanup exits 0" \
        "repo 1 base contains repo 1's task commit" \
        "repo 2 base contains repo 2's task commit (finding-1 guard)" \
        "master entry state: completed after merge-and-cleanup" \
        "repo 1 worktree removed after cleanup" \
        "repo 2 worktree removed after cleanup (finding-1 guard)" \
        "tmux session absent after cleanup" \
        "naive second merge-and-cleanup run -> exit 11 (dispatch.md archived, not no-op 0)"
    do
        skip "T6-multi $i (skipped: $reason)"
    done
}

run_T6_multi() {
    say_header "T6-multi end-to-end 1-task-2-repos (spawn -> merge-and-cleanup)"

    if ! command -v tmux >/dev/null 2>&1; then T6M_SKIP_ALL "tmux not available"; return; fi
    if ! command -v git  >/dev/null 2>&1; then T6M_SKIP_ALL "git not available";  return; fi

    local spawn="$REPO_ROOT/scripts/orch-spawn-worker.sh"
    local merge="$REPO_ROOT/scripts/orch-merge-and-cleanup.sh"
    if [ ! -x "$spawn" ] || [ ! -x "$merge" ]; then
        T6M_SKIP_ALL "spawn/merge-and-cleanup helper missing or not executable"
        return
    fi

    local T6M_ROOT
    T6M_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t6m.XXXXXX")"
    local FAKE_HOME="$T6M_ROOT/home"
    mkdir -p "$FAKE_HOME"
    local TASK_ID="zyzm6"
    local SESSION="zyz-task-$TASK_ID"
    local LIST_DIR="$T6M_ROOT/list"
    local REPO1="$T6M_ROOT/work-main"
    local REPO2="$T6M_ROOT/work-lib"

    # Synchronous teardown (NO EXIT trap — see group-header note).
    t6m_teardown() {
        tmux kill-session -t "$SESSION" 2>/dev/null || true
        sleep 1
        rm -rf "$T6M_ROOT"
    }

    if ! zyzm_init_git_repo "$REPO1" || ! zyzm_init_git_repo "$REPO2"; then
        T6M_SKIP_ALL "git fixture init failed"
        t6m_teardown
        return
    fi

    # finding-1 guard master entry: source-repo + source-repo-2 ONLY.
    zyzm_write_master_entry "$LIST_DIR" "$TASK_ID" "$REPO1" "source-repo-2: $REPO2"

    # ---- Shadow gh with a fake that always fails "not logged in" so the merge
    #      takes the local `git merge --no-ff` path deterministically (mirrors
    #      T6's approach: a real gh in PATH could otherwise try the network). ----
    local SHADOW_DIR="$T6M_ROOT/shadow-bin"
    mkdir -p "$SHADOW_DIR"
    cat >"$SHADOW_DIR/gh" <<'FAKEGHEOF'
#!/bin/sh
echo "gh: not logged in" >&2
exit 1
FAKEGHEOF
    chmod +x "$SHADOW_DIR/gh"
    local RUN_PATH="$SHADOW_DIR:$PATH"

    # ---- spawn (invoked from a non-git cwd; HOME steered so default sibling
    #      layout lands under our root) ----
    local spawn_out spawn_rc
    spawn_out="$(
        cd "$T6M_ROOT" \
        && env HOME="$FAKE_HOME" PATH="$RUN_PATH" bash "$spawn" "$TASK_ID" "$LIST_DIR" </dev/null 2>&1
    )"
    spawn_rc=$?
    if [ "$spawn_rc" -ne 0 ]; then
        T6M_FAIL "spawn 1-task-2-repos exited $spawn_rc (expected 0).  Output:
$(printf '%s\n' "$spawn_out" | sed 's/^/      | /')"
        local i
        for i in \
            "2 sibling worktrees + 1 tmux session created" \
            "dispatch.md carries resolved numbered group (finding-1 guard)" \
            "merge-and-cleanup exits 0" \
            "repo 1 base contains repo 1's task commit" \
            "repo 2 base contains repo 2's task commit (finding-1 guard)" \
            "master entry state: completed after merge-and-cleanup" \
            "repo 1 worktree removed after cleanup" \
            "repo 2 worktree removed after cleanup (finding-1 guard)" \
            "tmux session absent after cleanup" \
            "naive second merge-and-cleanup run -> exit 11 (dispatch.md archived, not no-op 0)"
        do
            skip "T6-multi $i (skipped: spawn failed)"
        done
        t6m_teardown
        return
    fi
    T6M_PASS "spawn 1-task-2-repos exits 0"

    # Resolve the two worktree paths from dispatch.md (authoritative).
    local disp="$LIST_DIR/runtime/$TASK_ID/dispatch.md"
    local wt1 wt2 br1 br2
    wt1="$(tr_fm "$disp" worktree)"
    wt2="$(tr_fm "$disp" worktree-2)"
    br1="$(tr_fm "$disp" branch)"
    br2="$(tr_fm "$disp" branch-2)"

    sleep 1
    if [ -d "$wt1" ] && [ -d "$wt2" ] \
        && [ "$(dirname "$wt1")" = "$(dirname "$wt2")" ] \
        && tmux has-session -t "$SESSION" 2>/dev/null; then
        T6M_PASS "2 sibling worktrees + 1 tmux session created"
    else
        T6M_FAIL "expected 2 sibling worktrees + 1 session (wt1='$wt1' d=$([ -d "$wt1" ] && echo y||echo n), wt2='$wt2' d=$([ -d "$wt2" ] && echo y||echo n), same-parent=$([ "$(dirname "$wt1")" = "$(dirname "$wt2")" ] && echo y||echo n), session=$(tmux has-session -t "$SESSION" 2>/dev/null && echo y||echo n))"
    fi

    if [ -n "$wt2" ] && [ -n "$(tr_fm "$disp" source-repo-2)" ] \
        && [ -n "$br2" ] && [ -n "$(tr_fm "$disp" base-2)" ]; then
        T6M_PASS "dispatch.md carries resolved numbered group (finding-1 guard)"
    else
        T6M_FAIL "dispatch.md numbered group not fully materialized (finding-1): worktree-2='$wt2' source-repo-2='$(tr_fm "$disp" source-repo-2)' branch-2='$br2' base-2='$(tr_fm "$disp" base-2)'"
    fi

    # ---- Mock worker: a UNIQUE commit in EACH worktree (repo 1 + repo 2). ----
    local uniq1="repo1-only-$TASK_ID.txt"
    local uniq2="repo2-only-$TASK_ID.txt"
    local sha1="" sha2=""
    if [ -d "$wt1" ]; then
        (
            cd "$wt1" || exit 1
            echo "repo 1 task work" >"$uniq1"
            git add "$uniq1"
            git commit -q -m "T6-multi repo1 task commit"
        ) && sha1="$(git -C "$wt1" rev-parse HEAD 2>/dev/null || true)"
    fi
    if [ -d "$wt2" ]; then
        (
            cd "$wt2" || exit 1
            echo "repo 2 task work" >"$uniq2"
            git add "$uniq2"
            git commit -q -m "T6-multi repo2 task commit"
        ) && sha2="$(git -C "$wt2" rev-parse HEAD 2>/dev/null || true)"
    fi

    # ---- approve + merge-and-cleanup ----
    {
        echo ""
        echo "## Pending Merge Approval"
        echo ""
        echo "approved by T6-multi-test"
    } >>"$LIST_DIR/tasks/$TASK_ID.md"

    local mc_out mc_rc
    mc_out="$(
        cd "$T6M_ROOT" \
        && env HOME="$FAKE_HOME" PATH="$RUN_PATH" bash "$merge" "$TASK_ID" "$LIST_DIR" main </dev/null 2>&1
    )"
    mc_rc=$?
    if [ "$mc_rc" -eq 0 ]; then
        T6M_PASS "merge-and-cleanup exits 0"
    else
        T6M_FAIL "merge-and-cleanup exited $mc_rc (expected 0).  Output:
$(printf '%s\n' "$mc_out" | sed 's/^/      | /')"
    fi

    # ---- Both repos' base (main) must now contain their own task commit. ----
    if [ -n "$sha1" ] && git -C "$REPO1" merge-base --is-ancestor "$sha1" main >/dev/null 2>&1; then
        T6M_PASS "repo 1 base contains repo 1's task commit"
    else
        T6M_FAIL "repo 1 task commit '$sha1' NOT reachable from main in $REPO1.  merge output:
$(printf '%s\n' "$mc_out" | sed 's/^/      | /')"
    fi
    if [ -n "$sha2" ] && git -C "$REPO2" merge-base --is-ancestor "$sha2" main >/dev/null 2>&1; then
        T6M_PASS "repo 2 base contains repo 2's task commit (finding-1 guard)"
    else
        T6M_FAIL "repo 2 task commit '$sha2' NOT reachable from main in $REPO2 — repo 2 was silently skipped (finding 1: repo set must come from dispatch.md, not the master entry).  merge output:
$(printf '%s\n' "$mc_out" | sed 's/^/      | /')"
    fi

    # ---- state=completed ----
    if grep -qE '^state:[[:space:]]*completed' "$LIST_DIR/tasks/$TASK_ID.md"; then
        T6M_PASS "master entry state: completed after merge-and-cleanup"
    else
        T6M_FAIL "master entry state is NOT 'completed' after merge-and-cleanup"
    fi

    # ---- both worktrees removed ----
    if [ ! -d "$wt1" ]; then
        T6M_PASS "repo 1 worktree removed after cleanup"
    else
        T6M_FAIL "repo 1 worktree '$wt1' still present after cleanup"
    fi
    if [ ! -d "$wt2" ]; then
        T6M_PASS "repo 2 worktree removed after cleanup (finding-1 guard)"
    else
        T6M_FAIL "repo 2 worktree '$wt2' still present after cleanup — repo 2 skipped (finding 1)"
    fi

    # ---- tmux session gone ----
    sleep 1
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        T6M_FAIL "tmux session $SESSION still alive after cleanup"
    else
        T6M_PASS "tmux session absent after cleanup"
    fi

    # ---- Idempotency scoping (04-R2): naive SECOND full run -> exit 11. ----
    # cleanup archived dispatch.md, so merge-and-cleanup falls back to the
    # single-repo master-entry path; the finding-1 fixture entry has NO
    # `worktree:` field, so the worktree resolves empty -> exit 11.  This is the
    # CORRECT behavior (matches today's single-repo), NOT a no-op exit 0.
    local mc2_out mc2_rc
    mc2_out="$(
        cd "$T6M_ROOT" \
        && env HOME="$FAKE_HOME" PATH="$RUN_PATH" bash "$merge" "$TASK_ID" "$LIST_DIR" main </dev/null 2>&1
    )"
    mc2_rc=$?
    if [ "$mc2_rc" -eq 11 ]; then
        T6M_PASS "naive second merge-and-cleanup run -> exit 11 (dispatch.md archived, not no-op 0)"
    else
        T6M_FAIL "naive second merge-and-cleanup run expected exit 11 (dispatch.md archived -> single-repo fallback -> worktree missing), got exit=$mc2_rc.  Output:
$(printf '%s\n' "$mc2_out" | sed 's/^/      | /')"
    fi

    t6m_teardown
}

# zyzm_build_repo_worktree <repo-dir> <worktree-dir> <branch> <unique-file> <conflict>
# Init a git repo with main, add a linked worktree on <branch> carrying a UNIQUE
# commit.  When <conflict>=true, also make main and the task branch edit the SAME
# line so a later `git merge --no-ff` conflicts.  Prints nothing; caller reads the
# task-branch HEAD via `git -C <worktree-dir> rev-parse HEAD`.  Returns non-zero
# on any git failure.
zyzm_build_repo_worktree() {
    local repo="$1" wt="$2" branch="$3" uniq="$4" conflict="$5"
    mkdir -p "$repo" || return 1
    (
        cd "$repo" || exit 1
        git init -q . >/dev/null 2>&1 || exit 1
        git config user.email "multirepo@example.com"
        git config user.name "MultiRepo Test"
        git checkout -q -b main 2>/dev/null || git checkout -q main || exit 1
        echo "initial" >README.md
        git add README.md
        if [ "$conflict" = "true" ]; then
            echo "base line" >conflict.txt
            git add conflict.txt
        fi
        git commit -q -m "initial" || exit 1
        git worktree add -q -b "$branch" "$wt" main >/dev/null 2>&1 || exit 1
    ) || return 1
    (
        cd "$wt" || exit 1
        echo "task work" >"$uniq"
        git add "$uniq"
        if [ "$conflict" = "true" ]; then
            echo "task line" >conflict.txt
            git add conflict.txt
        fi
        git commit -q -m "task-branch commit ($branch)" || exit 1
    ) || return 1
    if [ "$conflict" = "true" ]; then
        (
            cd "$repo" || exit 1
            git checkout -q main || exit 1
            echo "main line" >conflict.txt
            git add conflict.txt
            git commit -q -m "diverging main commit" || exit 1
        ) || return 1
    fi
    return 0
}

# zyzm_write_dispatch_2repo <dispatch-file> <task-id> <wt1> <br1> <wt2> <br2>
# Write a spawn-shaped multi-repo dispatch.md (repo 2 numbered group after the
# unnumbered `base:` line).  base/base-2 are both `main`.  Phase-2 fields empty.
zyzm_write_dispatch_2repo() {
    local dfile="$1" tid="$2" wt1="$3" br1="$4" wt2="$5" br2="$6"
    mkdir -p "$(dirname "$dfile")"
    {
        echo "---"
        echo "task-id: $tid"
        echo "spawn-iso: 2026-07-22T00:00:00+0000"
        echo "tmux-session: zyz-task-$tid"
        echo "tmux-window-id: @1"
        echo "tmux-pane-id: %1"
        echo "shell-pid: 111111"
        echo "worktree: $wt1"
        echo "source-repo: $wt1"
        echo "branch: $br1"
        echo "base: main"
        echo "worktree-2: $wt2"
        echo "source-repo-2: $wt2"
        echo "branch-2: $br2"
        echo "base-2: main"
        echo "plugin-root: $REPO_ROOT"
        echo "encoded-cwd: -x"
        echo "reuse-from:"
        echo "reuse-scope:"
        echo "reuse-claude-effective:"
        echo "heartbeat-window-id:"
        echo "claude-pid:"
        echo "claude-session-id:"
        echo "transcript-path:"
        echo "first-seen-iso:"
        echo "---"
        echo ""
        echo "# Dispatch Info"
        echo ""
        echo "## Recovery"
        echo ""
        echo "(x)"
    } >"$dfile"
}

# zyzm_write_merge_entry <list-dir> <task-id> <primary-repo> <token>
# Master entry for the merge family with a `## Pending Merge Approval` <token>
# line (e.g. `merge` or `approved`).  state stays in-progress.
zyzm_write_merge_entry() {
    local list_dir="$1" tid="$2" primary="$3" token="$4"
    mkdir -p "$list_dir/tasks"
    {
        echo "---"
        echo "task-id: $tid"
        echo "project: $(basename "$primary")"
        echo "source-repo: $primary"
        echo "state: in-progress"
        echo "priority: normal"
        echo "branch: task/$tid"
        echo "base: main"
        echo "worktree: $primary"
        echo "tmux-session: zyz-task-$tid"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-07-22"
        echo "updated-at: 2026-07-22"
        echo "---"
        echo ""
        echo "# $tid"
        echo ""
        echo "## Description"
        echo ""
        echo "Multi-repo merge-only fixture."
        echo ""
        echo "## Pending Merge Approval"
        echo ""
        echo "$token by test"
    } >"$list_dir/tasks/$tid.md"
}

# ---------------------------------------------------------------------------
# T11b-multi.  orch-merge.sh `merge`-only path, multi-repo (design 02-D2, 04
#              §T11b-multi).  Three sub-scenarios:
#
#  (A) happy path: 2 repos, both merged + (no origin -> no push), worktrees KEPT,
#      master entry state UNCHANGED (merge never writes state), per-repo stdout
#      (merge-status= + merge-status-2=).
#  (B) partial failure: repo 2 conflicts -> exit 12, repo 1 already merged (its
#      commit reachable from main), per-repo stdout carries merge-status=success.
#  (C) local-path idempotent re-run (single-repo, gh shadowed to fail): a repo
#      whose branch is ALREADY an ancestor of base re-runs as already-merged +
#      exit 0, NOT a false exit 12.
#
# Gated on tmux+git (orch-merge.sh hard-requires both at entry, like T11b).  gh is
# shadowed with a failing fake so the deterministic LOCAL merge path is taken (no
# network); the design's real-gh PR-state probe is a manual/skipped point noted in
# the delivery report.
# ---------------------------------------------------------------------------
run_T11b_multi() {
    say_header "T11b-multi orch-merge.sh merge-only path multi-repo"

    local merge="$REPO_ROOT/scripts/orch-merge.sh"

    if ! command -v tmux >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 || [ ! -x "$merge" ]; then
        local why="tmux/git not available"
        [ ! -x "$merge" ] && why="orch-merge.sh missing or not executable"
        skip "T11b-multi (A) 2 repos merged, worktrees kept, state unchanged, per-repo stdout ($why)"
        skip "T11b-multi (B) repo 2 conflict -> exit 12, repo 1 merged, per-repo stdout ($why)"
        skip "T11b-multi (C) local-path idempotent re-run -> repo 1 already-merged, no false exit 12 ($why)"
        return
    fi

    local T11M_ROOT
    T11M_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t11m.XXXXXX")"
    # gh shadow (fail "not logged in" -> local merge path).
    local SHADOW_DIR="$T11M_ROOT/shadow-bin"
    mkdir -p "$SHADOW_DIR"
    cat >"$SHADOW_DIR/gh" <<'FAKEGHEOF'
#!/bin/sh
echo "gh: not logged in" >&2
exit 1
FAKEGHEOF
    chmod +x "$SHADOW_DIR/gh"
    local RUN_PATH="$SHADOW_DIR:$PATH"

    # =====================================================================
    # (A) HAPPY PATH — 2 clean repos, both merge, worktrees kept, state same.
    # =====================================================================
    local A_ROOT="$T11M_ROOT/A"
    local A_LIST="$A_ROOT/list"
    local A_TID="zyzm11a"
    local A_R1="$A_ROOT/repo1" A_R2="$A_ROOT/repo2"
    local A_WT1="$A_ROOT/wt1"  A_WT2="$A_ROOT/wt2"
    local A_BR="task/$A_TID"
    local a_ok="true"
    zyzm_build_repo_worktree "$A_R1" "$A_WT1" "$A_BR" "r1.txt" false || a_ok="false"
    zyzm_build_repo_worktree "$A_R2" "$A_WT2" "$A_BR" "r2.txt" false || a_ok="false"
    if [ "$a_ok" != "true" ]; then
        skip "T11b-multi (A) 2 repos merged, worktrees kept, state unchanged, per-repo stdout (git fixture init failed)"
    else
        local a_sha1 a_sha2
        a_sha1="$(git -C "$A_WT1" rev-parse HEAD 2>/dev/null || true)"
        a_sha2="$(git -C "$A_WT2" rev-parse HEAD 2>/dev/null || true)"
        zyzm_write_merge_entry "$A_LIST" "$A_TID" "$A_R1" "merge"
        zyzm_write_dispatch_2repo "$A_LIST/runtime/$A_TID/dispatch.md" "$A_TID" \
            "$A_WT1" "$A_BR" "$A_WT2" "$A_BR"
        local a_out a_rc
        a_out="$(env PATH="$RUN_PATH" bash "$merge" "$A_TID" "$A_LIST" main </dev/null 2>&1)"
        a_rc=$?
        local a_entry="$A_LIST/tasks/$A_TID.md"
        local a_pass="true" a_why=""
        [ "$a_rc" -eq 0 ] || { a_pass="false"; a_why="$a_why exit=$a_rc(≠0);"; }
        git -C "$A_R1" merge-base --is-ancestor "$a_sha1" main >/dev/null 2>&1 \
            || { a_pass="false"; a_why="$a_why repo1-not-merged;"; }
        git -C "$A_R2" merge-base --is-ancestor "$a_sha2" main >/dev/null 2>&1 \
            || { a_pass="false"; a_why="$a_why repo2-not-merged;"; }
        [ -d "$A_WT1" ] || { a_pass="false"; a_why="$a_why wt1-removed;"; }
        [ -d "$A_WT2" ] || { a_pass="false"; a_why="$a_why wt2-removed;"; }
        grep -qE '^state:[[:space:]]*in-progress' "$a_entry" \
            || { a_pass="false"; a_why="$a_why state-changed;"; }
        printf '%s\n' "$a_out" | grep -qE '^merge-status=(success|already-merged)$' \
            || { a_pass="false"; a_why="$a_why no-repo1-status;"; }
        printf '%s\n' "$a_out" | grep -qE '^merge-status-2=(success|already-merged)$' \
            || { a_pass="false"; a_why="$a_why no-repo2-status;"; }
        if [ "$a_pass" = "true" ]; then
            pass "T11b-multi (A) 2 repos merged, worktrees kept, state unchanged, per-repo stdout"
        else
            fail "T11b-multi (A) failed:$a_why  Output:
$(printf '%s\n' "$a_out" | sed 's/^/      | /')"
        fi
    fi

    # =====================================================================
    # (B) PARTIAL FAILURE — repo 1 clean (merges), repo 2 conflicts -> exit 12.
    #     Merged repo 1 is NOT rolled back (design 02-D2-3); stdout reports
    #     merge-status=success for repo 1 before the exit-12 abort on repo 2.
    # =====================================================================
    local B_ROOT="$T11M_ROOT/B"
    local B_LIST="$B_ROOT/list"
    local B_TID="zyzm11b"
    local B_R1="$B_ROOT/repo1" B_R2="$B_ROOT/repo2"
    local B_WT1="$B_ROOT/wt1"  B_WT2="$B_ROOT/wt2"
    local B_BR="task/$B_TID"
    local b_ok="true"
    zyzm_build_repo_worktree "$B_R1" "$B_WT1" "$B_BR" "r1.txt" false || b_ok="false"
    zyzm_build_repo_worktree "$B_R2" "$B_WT2" "$B_BR" "r2.txt" true  || b_ok="false"
    if [ "$b_ok" != "true" ]; then
        skip "T11b-multi (B) repo 2 conflict -> exit 12, repo 1 merged, per-repo stdout (git fixture init failed)"
    else
        local b_sha1
        b_sha1="$(git -C "$B_WT1" rev-parse HEAD 2>/dev/null || true)"
        zyzm_write_merge_entry "$B_LIST" "$B_TID" "$B_R1" "merge"
        zyzm_write_dispatch_2repo "$B_LIST/runtime/$B_TID/dispatch.md" "$B_TID" \
            "$B_WT1" "$B_BR" "$B_WT2" "$B_BR"
        local b_out b_rc
        b_out="$(env PATH="$RUN_PATH" bash "$merge" "$B_TID" "$B_LIST" main </dev/null 2>&1)"
        b_rc=$?
        local b_pass="true" b_why=""
        [ "$b_rc" -eq 12 ] || { b_pass="false"; b_why="$b_why exit=$b_rc(≠12);"; }
        git -C "$B_R1" merge-base --is-ancestor "$b_sha1" main >/dev/null 2>&1 \
            || { b_pass="false"; b_why="$b_why repo1-not-merged;"; }
        printf '%s\n' "$b_out" | grep -qE '^merge-status=(success|already-merged)$' \
            || { b_pass="false"; b_why="$b_why no-repo1-status-on-stdout;"; }
        if [ "$b_pass" = "true" ]; then
            pass "T11b-multi (B) repo 2 conflict -> exit 12, repo 1 merged, per-repo stdout"
        else
            fail "T11b-multi (B) failed:$b_why  Output:
$(printf '%s\n' "$b_out" | sed 's/^/      | /')"
        fi
    fi

    # =====================================================================
    # (C) LOCAL-PATH IDEMPOTENT RE-RUN — single-repo, gh shadowed to fail.
    #     Run merge once (branch merges into main), then re-run: the second run
    #     must detect the branch is already an ancestor of base and report
    #     already-merged + exit 0, NOT falsely treat it as a conflict (exit 12).
    # =====================================================================
    local C_ROOT="$T11M_ROOT/C"
    local C_LIST="$C_ROOT/list"
    local C_TID="zyzm11c"
    local C_R1="$C_ROOT/repo1"
    local C_WT1="$C_ROOT/wt1"
    local C_BR="task/$C_TID"
    if ! zyzm_build_repo_worktree "$C_R1" "$C_WT1" "$C_BR" "c1.txt" false; then
        skip "T11b-multi (C) local-path idempotent re-run -> repo 1 already-merged, no false exit 12 (git fixture init failed)"
    else
        zyzm_write_merge_entry "$C_LIST" "$C_TID" "$C_R1" "merge"
        # Single-repo dispatch.md (no numbered group) so the merge uses repo 1's
        # worktree from dispatch.md; base=main.
        mkdir -p "$C_LIST/runtime/$C_TID"
        {
            echo "---"
            echo "task-id: $C_TID"
            echo "spawn-iso: 2026-07-22T00:00:00+0000"
            echo "tmux-session: zyz-task-$C_TID"
            echo "tmux-window-id: @1"
            echo "tmux-pane-id: %1"
            echo "shell-pid: 111111"
            echo "worktree: $C_WT1"
            echo "source-repo: $C_R1"
            echo "branch: $C_BR"
            echo "base: main"
            echo "plugin-root: $REPO_ROOT"
            echo "encoded-cwd: -x"
            echo "reuse-from:"
            echo "reuse-scope:"
            echo "reuse-claude-effective:"
            echo "heartbeat-window-id:"
            echo "claude-pid:"
            echo "claude-session-id:"
            echo "transcript-path:"
            echo "first-seen-iso:"
            echo "---"
            echo ""
            echo "# Dispatch Info"
            echo ""
            echo "## Recovery"
            echo ""
            echo "(x)"
        } >"$C_LIST/runtime/$C_TID/dispatch.md"

        local c_out1 c_rc1
        c_out1="$(env PATH="$RUN_PATH" bash "$merge" "$C_TID" "$C_LIST" main </dev/null 2>&1)"
        c_rc1=$?
        # Re-run: expect already-merged + exit 0, NO false exit 12.
        local c_out2 c_rc2
        c_out2="$(env PATH="$RUN_PATH" bash "$merge" "$C_TID" "$C_LIST" main </dev/null 2>&1)"
        c_rc2=$?
        if [ "$c_rc1" -eq 0 ] && [ "$c_rc2" -eq 0 ] \
            && printf '%s\n' "$c_out2" | grep -qxF 'merge-status=already-merged'; then
            pass "T11b-multi (C) local-path idempotent re-run -> repo 1 already-merged, no false exit 12"
        else
            fail "T11b-multi (C) idempotent re-run failed: run1 exit=$c_rc1, run2 exit=$c_rc2 (expected 0/0 + 'merge-status=already-merged' on re-run).  Re-run output:
$(printf '%s\n' "$c_out2" | sed 's/^/      | /')"
        fi
    fi

    rm -rf "$T11M_ROOT"
}

# ---------------------------------------------------------------------------
# cleanup-multi.  orch-cleanup-worker.sh multi-repo (design 02-D3, 04 §cleanup).
#
#  (A) dry-run: per-repo would-remove lines — worktree-removed=false (repo 1) AND
#      worktree-removed-2=false (repo 2); nothing is actually removed.
#  (B) --force: both worktrees removed (worktree-removed=true + worktree-removed-2=
#      true), runtime archived; no read-after-archive (the repo set is resolved
#      from dispatch.md BEFORE the archive move).
#  (C) removal failure -> exit 8 + per-repo stdout: repo 2's worktree is LOCKED
#      (single `--force` refuses a locked worktree), so repo 1 removes cleanly
#      (worktree-removed=true) while repo 2 fails (worktree-removed-2=false) and
#      the script exits 8 (design D3-2). See the in-body NOTE for why the raw
#      "dirty removes nothing" phrasing is not black-box reproducible.
#
# Gated on tmux+git.  No tmux session is actually created (cleanup's kill step is a
# no-op when the session is absent), so this needs only `tmux` on PATH + git.
# ---------------------------------------------------------------------------
run_cleanup_multi() {
    say_header "cleanup-multi orch-cleanup-worker.sh multi-repo"

    local cleanup="$REPO_ROOT/scripts/orch-cleanup-worker.sh"
    if ! command -v tmux >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 || [ ! -x "$cleanup" ]; then
        local why="tmux/git not available"
        [ ! -x "$cleanup" ] && why="orch-cleanup-worker.sh missing or not executable"
        skip "cleanup-multi (A) dry-run per-repo would-remove lines ($why)"
        skip "cleanup-multi (B) --force removes both worktrees + archives runtime ($why)"
        skip "cleanup-multi (C) removal failure -> exit 8 + per-repo stdout ($why)"
        return
    fi

    local CLM_ROOT
    CLM_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-clm.XXXXXX")"

    # =====================================================================
    # (A) DRY-RUN — per-repo would-remove lines.
    # =====================================================================
    local A_ROOT="$CLM_ROOT/A"
    local A_LIST="$A_ROOT/list"
    local A_TID="zyzmcl_a"
    local A_R1="$A_ROOT/repo1" A_R2="$A_ROOT/repo2"
    local A_WT1="$A_ROOT/wt1"  A_WT2="$A_ROOT/wt2"
    local a_ok="true"
    zyzm_build_repo_worktree "$A_R1" "$A_WT1" "task/$A_TID" "r1.txt" false || a_ok="false"
    zyzm_build_repo_worktree "$A_R2" "$A_WT2" "task/$A_TID" "r2.txt" false || a_ok="false"
    if [ "$a_ok" != "true" ]; then
        skip "cleanup-multi (A) dry-run per-repo would-remove lines (git fixture init failed)"
    else
        zyzm_write_merge_entry "$A_LIST" "$A_TID" "$A_R1" "n/a"
        zyzm_write_dispatch_2repo "$A_LIST/runtime/$A_TID/dispatch.md" "$A_TID" \
            "$A_WT1" "task/$A_TID" "$A_WT2" "task/$A_TID"
        local a_out a_rc
        a_out="$(bash "$cleanup" "$A_TID" "$A_LIST" </dev/null 2>&1)"
        a_rc=$?
        if [ "$a_rc" -eq 0 ] \
            && printf '%s\n' "$a_out" | grep -qxF 'worktree-removed=false' \
            && printf '%s\n' "$a_out" | grep -qxF 'worktree-removed-2=false' \
            && [ -d "$A_WT1" ] && [ -d "$A_WT2" ]; then
            pass "cleanup-multi (A) dry-run per-repo would-remove lines"
        else
            fail "cleanup-multi (A) dry-run: expected exit 0 + 'worktree-removed=false' + 'worktree-removed-2=false' + both worktrees still present (exit=$a_rc).  Output:
$(printf '%s\n' "$a_out" | sed 's/^/      | /')"
        fi
    fi

    # =====================================================================
    # (B) --force — both worktrees removed + runtime archived.
    # =====================================================================
    local B_ROOT="$CLM_ROOT/B"
    local B_LIST="$B_ROOT/list"
    local B_TID="zyzmcl_b"
    local B_R1="$B_ROOT/repo1" B_R2="$B_ROOT/repo2"
    local B_WT1="$B_ROOT/wt1"  B_WT2="$B_ROOT/wt2"
    local b_ok="true"
    zyzm_build_repo_worktree "$B_R1" "$B_WT1" "task/$B_TID" "r1.txt" false || b_ok="false"
    zyzm_build_repo_worktree "$B_R2" "$B_WT2" "task/$B_TID" "r2.txt" false || b_ok="false"
    if [ "$b_ok" != "true" ]; then
        skip "cleanup-multi (B) --force removes both worktrees + archives runtime (git fixture init failed)"
    else
        zyzm_write_merge_entry "$B_LIST" "$B_TID" "$B_R1" "n/a"
        zyzm_write_dispatch_2repo "$B_LIST/runtime/$B_TID/dispatch.md" "$B_TID" \
            "$B_WT1" "task/$B_TID" "$B_WT2" "task/$B_TID"
        local b_out b_rc
        b_out="$(bash "$cleanup" "$B_TID" "$B_LIST" --force </dev/null 2>&1)"
        b_rc=$?
        if [ "$b_rc" -eq 0 ] \
            && printf '%s\n' "$b_out" | grep -qxF 'worktree-removed=true' \
            && printf '%s\n' "$b_out" | grep -qxF 'worktree-removed-2=true' \
            && [ ! -d "$B_WT1" ] && [ ! -d "$B_WT2" ] \
            && printf '%s\n' "$b_out" | grep -qxF 'runtime-archived=true' \
            && [ ! -d "$B_LIST/runtime/$B_TID" ] && [ -d "$B_LIST/runtime/.archive" ]; then
            pass "cleanup-multi (B) --force removes both worktrees + archives runtime"
        else
            fail "cleanup-multi (B) --force: expected exit 0 + worktree-removed=true + worktree-removed-2=true + both worktrees gone + runtime archived (exit=$b_rc, wt1-present=$([ -d "$B_WT1" ] && echo y||echo n), wt2-present=$([ -d "$B_WT2" ] && echo y||echo n)).  Output:
$(printf '%s\n' "$b_out" | sed 's/^/      | /')"
        fi
    fi

    # =====================================================================
    # (C) REMOVAL FAILURE -> exit 8 + per-repo stdout (design D3-2: a mid-set
    #     removal failure does NOT abort the remaining repos; exit 8 at the end
    #     with per-repo worktree-removed[-N]= lines).
    #
    # We LOCK repo 2's worktree: `git worktree remove --force` (SINGLE --force,
    # which is what cleanup runs) refuses to remove a LOCKED worktree — that
    # needs --force twice.  So repo 1 removes cleanly (worktree-removed=true)
    # while repo 2 fails (worktree-removed-2=false), the script exits 8, and
    # repo 2's worktree survives.  This is deterministic and cross-version-safe
    # (worktree lock + double-force semantics predate all supported git).
    #
    # NOTE (reported to main agent): the discovered-test-point phrasing "一仓脏
    # -> exit 8 全不删 (dirty precheck removes nothing)" is NOT black-box
    # reproducible against the landed impl: in --force mode a DIRTY worktree is
    # force-REMOVED (orch-cleanup-worker.sh:298-305), never an exit-8 trigger; the
    # only "removes nothing" exit-8 is the precheck's unlocatable-main-repo abort,
    # which `dirname` masks for a merely-deleted checkout.  This test asserts the
    # deterministic removal-failure exit-8 path instead.
    # =====================================================================
    local C_ROOT="$CLM_ROOT/C"
    local C_LIST="$C_ROOT/list"
    local C_TID="zyzmcl_c"
    local C_R1="$C_ROOT/repo1" C_R2="$C_ROOT/repo2"
    local C_WT1="$C_ROOT/wt1"  C_WT2="$C_ROOT/wt2"
    local c_ok="true"
    zyzm_build_repo_worktree "$C_R1" "$C_WT1" "task/$C_TID" "r1.txt" false || c_ok="false"
    zyzm_build_repo_worktree "$C_R2" "$C_WT2" "task/$C_TID" "r2.txt" false || c_ok="false"
    if [ "$c_ok" != "true" ]; then
        skip "cleanup-multi (C) removal failure -> exit 8 + per-repo stdout (git fixture init failed)"
    elif ! git -C "$C_R2" worktree lock "$C_WT2" >/dev/null 2>&1; then
        skip "cleanup-multi (C) removal failure -> exit 8 + per-repo stdout (git worktree lock unsupported on this host)"
    else
        zyzm_write_merge_entry "$C_LIST" "$C_TID" "$C_R1" "n/a"
        zyzm_write_dispatch_2repo "$C_LIST/runtime/$C_TID/dispatch.md" "$C_TID" \
            "$C_WT1" "task/$C_TID" "$C_WT2" "task/$C_TID"
        local c_out c_rc
        c_out="$(bash "$cleanup" "$C_TID" "$C_LIST" --force </dev/null 2>&1)"
        c_rc=$?
        if [ "$c_rc" -eq 8 ] \
            && printf '%s\n' "$c_out" | grep -qxF 'worktree-removed=true' \
            && printf '%s\n' "$c_out" | grep -qxF 'worktree-removed-2=false' \
            && [ -d "$C_WT2" ]; then
            pass "cleanup-multi (C) removal failure -> exit 8 + per-repo stdout (repo 1 removed, repo 2 failed+present)"
        else
            fail "cleanup-multi (C) expected exit 8 + 'worktree-removed=true' + 'worktree-removed-2=false' + repo 2 worktree present (exit=$c_rc, wt2-present=$([ -d "$C_WT2" ] && echo y||echo n)).  Output:
$(printf '%s\n' "$c_out" | sed 's/^/      | /')"
        fi
        # Unlock so teardown's rm -rf is unobstructed.
        git -C "$C_R2" worktree unlock "$C_WT2" >/dev/null 2>&1 || true
    fi

    rm -rf "$CLM_ROOT"
}

# zyzm_write_old_completed_entry <list-dir> <old-id> <primary-repo> <primary-wt>
# Write a COMPLETED old master entry (the reuse source).  Its resolved multi-repo
# worktree set lives in the old dispatch.md (written separately), not here.
zyzm_write_old_completed_entry() {
    local list_dir="$1" oid="$2" primary="$3" pwt="$4"
    mkdir -p "$list_dir/tasks"
    {
        echo "---"
        echo "task-id: $oid"
        echo "project: $(basename "$primary")"
        echo "source-repo: $primary"
        echo "state: completed"
        echo "priority: normal"
        echo "branch: task/$oid"
        echo "base: main"
        echo "worktree: $pwt"
        echo "tmux-session: zyz-task-$oid"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-07-22"
        echo "updated-at: 2026-07-22"
        echo "---"
        echo ""
        echo "# $oid"
        echo ""
        echo "## Description"
        echo ""
        echo "Old completed multi-repo task (reuse source)."
    } >"$list_dir/tasks/$oid.md"
}

# zyzm_write_reuse_entry <list-dir> <new-id> <old-id> <scope> <primary-repo>
# Write a NEW task master entry declaring reuse-from/reuse-scope.
zyzm_write_reuse_entry() {
    local list_dir="$1" nid="$2" oid="$3" scope="$4" primary="$5"
    mkdir -p "$list_dir/tasks"
    {
        echo "---"
        echo "task-id: $nid"
        echo "project: $(basename "$primary")"
        echo "source-repo: $primary"
        echo "state: ready"
        echo "priority: normal"
        echo "branch: task/$nid"
        echo "base: main"
        echo "worktree: /tmp/zyz-orch-rum-ignored/$nid"
        echo "tmux-session: zyz-task-$nid"
        echo "reuse-from: $oid"
        echo "reuse-scope: $scope"
        echo "reuse-claude: false"
        echo "blocked-by: []"
        echo "merged-with: []"
        echo "deps-tentative: false"
        echo "last-seen:"
        echo "heartbeat-stale-sec: 300"
        echo "created-at: 2026-07-22"
        echo "updated-at: 2026-07-22"
        echo "---"
        echo ""
        echo "# $nid"
        echo ""
        echo "## Description"
        echo ""
        echo "New task reusing a multi-repo container."
    } >"$list_dir/tasks/$nid.md"
}

# ---------------------------------------------------------------------------
# reuse-multi.  orch-reuse-worker.sh multi-repo (design 02-D4/D5, 04 §reuse).
#
#  (A) NEGATIVE (tmux-free): an old completed task whose old dispatch.md numbered
#      group points at a repo-2 worktree that no longer exists -> a worktree-scope
#      reuse aborts with exit 5 naming repo 2.  The worktree-existence precheck
#      runs BEFORE the tmux/git dependency gate, so this fires on a tmux-less host.
#  (B) POSITIVE (tmux-gated): worktree-scope reuse of a 2-worktree old set ->
#      (b1) the NEW dispatch.md inherits the resolved numbered group (worktree-2 /
#           source-repo-2 / branch-2 / base-2 == old values), and
#      (b2) ZYZ_WORKTREES ("<wt1>:<wt2>") is exported into the new session's pane.
# ---------------------------------------------------------------------------
run_reuse_multi() {
    say_header "reuse-multi orch-reuse-worker.sh multi-repo"

    local reuse="$REPO_ROOT/scripts/orch-reuse-worker.sh"
    if [ ! -x "$reuse" ]; then
        skip "reuse-multi (A) missing repo in old set -> exit 5 (orch-reuse-worker.sh missing or not executable)"
        skip "reuse-multi (B1) new dispatch.md inherits numbered group (orch-reuse-worker.sh missing or not executable)"
        skip "reuse-multi (B2) ZYZ_WORKTREES exported into new pane for worktree scope >=2 (orch-reuse-worker.sh missing or not executable)"
        return
    fi

    local RUM_ROOT
    RUM_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-rum.XXXXXX")"
    local RUM_NEW_SESSION=""
    rum_teardown() {
        [ -n "$RUM_NEW_SESSION" ] && tmux kill-session -t "$RUM_NEW_SESSION" 2>/dev/null
        sleep 1
        rm -rf "$RUM_ROOT"
    }

    # =====================================================================
    # (A) NEGATIVE (tmux-free): old set's repo-2 worktree gone -> exit 5.
    # =====================================================================
    local A_LIST="$RUM_ROOT/list-a"
    local A_OLD="rumolda" A_NEW="rumnewa"
    local A_PWT="$RUM_ROOT/a-owt1"
    mkdir -p "$A_PWT"   # primary worktree EXISTS (index 0 passes)
    zyzm_write_old_completed_entry "$A_LIST" "$A_OLD" "$RUM_ROOT/a-repo1" "$A_PWT"
    # Old dispatch.md numbered group points repo-2 worktree at a NONEXISTENT path.
    zyzm_write_dispatch_2repo "$A_LIST/runtime/$A_OLD/dispatch.md" "$A_OLD" \
        "$A_PWT" "task/$A_OLD" "/nonexistent/zyz-rum-$$-repo2" "task/$A_OLD"
    zyzm_write_reuse_entry "$A_LIST" "$A_NEW" "$A_OLD" "worktree" "$RUM_ROOT/a-repo1"
    run_and_check_exit_stderr_regex 5 \
        'reuse-from old worktree path \(repo 2\) no longer exists' \
        "reuse-multi (A) missing repo 2 in old set -> exit 5 naming repo 2" \
        bash "$reuse" "$A_NEW" "$A_LIST"

    # =====================================================================
    # (B) POSITIVE (tmux+git gated): worktree-scope reuse of a 2-worktree old
    #     set inherits the numbered group + exports ZYZ_WORKTREES.
    # =====================================================================
    if ! command -v tmux >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        skip "reuse-multi (B1) new dispatch.md inherits numbered group (tmux/git not available)"
        skip "reuse-multi (B2) ZYZ_WORKTREES exported into new pane for worktree scope >=2 (tmux/git not available)"
        rum_teardown
        return
    fi

    local B_LIST="$RUM_ROOT/list-b"
    local B_OLD="rumoldb" B_NEW="rumnewb"
    local B_R1="$RUM_ROOT/b-repo1" B_R2="$RUM_ROOT/b-repo2"
    local B_WT1="$RUM_ROOT/b-owt1"  B_WT2="$RUM_ROOT/b-owt2"
    RUM_NEW_SESSION="zyz-task-$B_NEW"
    local b_ok="true"
    zyzm_build_repo_worktree "$B_R1" "$B_WT1" "task/$B_OLD" "r1.txt" false || b_ok="false"
    zyzm_build_repo_worktree "$B_R2" "$B_WT2" "task/$B_OLD" "r2.txt" false || b_ok="false"
    if [ "$b_ok" != "true" ]; then
        skip "reuse-multi (B1) new dispatch.md inherits numbered group (git fixture init failed)"
        skip "reuse-multi (B2) ZYZ_WORKTREES exported into new pane for worktree scope >=2 (git fixture init failed)"
        rum_teardown
        return
    fi

    zyzm_write_old_completed_entry "$B_LIST" "$B_OLD" "$B_R1" "$B_WT1"
    # Old dispatch.md numbered group: repo 1 = wt1 (source-repo=B_R1), repo 2 =
    # wt2 (source-repo=B_R2).  zyzm_write_dispatch_2repo sets source-repo=<wt> for
    # each, but reuse re-reads source-repo-N from here for the NEW group; the wt
    # values are the load-bearing ones for the inherit + ZYZ_WORKTREES checks.
    mkdir -p "$B_LIST/runtime/$B_OLD"
    {
        echo "---"
        echo "task-id: $B_OLD"
        echo "spawn-iso: 2026-07-22T00:00:00+0000"
        echo "tmux-session: zyz-task-$B_OLD"
        echo "tmux-window-id: @1"
        echo "tmux-pane-id: %1"
        echo "shell-pid: 111111"
        echo "worktree: $B_WT1"
        echo "source-repo: $B_R1"
        echo "branch: task/$B_OLD"
        echo "base: main"
        echo "worktree-2: $B_WT2"
        echo "source-repo-2: $B_R2"
        echo "branch-2: task/$B_OLD"
        echo "base-2: main"
        echo "plugin-root: $REPO_ROOT"
        echo "encoded-cwd: -x"
        echo "reuse-from:"
        echo "reuse-scope:"
        echo "reuse-claude-effective:"
        echo "heartbeat-window-id:"
        echo "claude-pid:"
        echo "claude-session-id:"
        echo "transcript-path:"
        echo "first-seen-iso:"
        echo "---"
        echo ""
        echo "# Dispatch Info"
        echo ""
        echo "## Recovery"
        echo ""
        echo "(old)"
    } >"$B_LIST/runtime/$B_OLD/dispatch.md"

    zyzm_write_reuse_entry "$B_LIST" "$B_NEW" "$B_OLD" "worktree" "$B_R1"

    local b_out b_rc
    b_out="$(
        cd "$RUM_ROOT" && bash "$reuse" "$B_NEW" "$B_LIST" </dev/null 2>&1
    )"
    b_rc=$?
    local B_DISPATCH="$B_LIST/runtime/$B_NEW/dispatch.md"
    if [ "$b_rc" -ne 0 ] || [ ! -f "$B_DISPATCH" ]; then
        fail "reuse-multi (B) worktree-scope reuse exited $b_rc or wrote no dispatch.md.  Output:
$(printf '%s\n' "$b_out" | sed 's/^/      | /')"
        skip "reuse-multi (B1) new dispatch.md inherits numbered group (reuse failed)"
        skip "reuse-multi (B2) ZYZ_WORKTREES exported into new pane for worktree scope >=2 (reuse failed)"
        rum_teardown
        return
    fi

    # (B1) new dispatch.md inherits the resolved numbered group from the old set.
    local n_wt2 n_sr2 n_br2 n_ba2
    n_wt2="$(tr_fm "$B_DISPATCH" worktree-2)"
    n_sr2="$(tr_fm "$B_DISPATCH" source-repo-2)"
    n_br2="$(tr_fm "$B_DISPATCH" branch-2)"
    n_ba2="$(tr_fm "$B_DISPATCH" base-2)"
    if [ "$n_wt2" = "$B_WT2" ] && [ "$n_sr2" = "$B_R2" ] \
        && [ "$n_br2" = "task/$B_OLD" ] && [ "$n_ba2" = "main" ]; then
        pass "reuse-multi (B1) new dispatch.md inherits numbered group (worktree-2/source-repo-2/branch-2/base-2 from old set)"
    else
        fail "reuse-multi (B1) numbered group not inherited: worktree-2='$n_wt2' (want '$B_WT2') source-repo-2='$n_sr2' (want '$B_R2') branch-2='$n_br2' base-2='$n_ba2'"
    fi

    # (B2) ZYZ_WORKTREES exported into the new session's pane.  reuse's
    # worktree-scope branch send-keys `export ZYZ_WORKTREES='wt1:wt2'` into the
    # new pane's shell; we send a follow-up command in the SAME shell that writes
    # $ZYZ_WORKTREES to a probe file, then read it back.
    if tmux has-session -t "$RUM_NEW_SESSION" 2>/dev/null; then
        local probe="$RUM_ROOT/zyz_worktrees_probe.txt"
        tmux send-keys -t "$RUM_NEW_SESSION" \
            "printf '%s' \"\$ZYZ_WORKTREES\" > '$probe'" Enter 2>/dev/null || true
        local _t got_wtenv=""
        for _t in 1 2 3 4 5; do
            [ -s "$probe" ] && { got_wtenv="$(cat "$probe" 2>/dev/null || true)"; break; }
            sleep 1
        done
        if [ "$got_wtenv" = "$B_WT1:$B_WT2" ]; then
            pass "reuse-multi (B2) ZYZ_WORKTREES exported into new pane for worktree scope >=2"
        else
            fail "reuse-multi (B2) ZYZ_WORKTREES in new pane='$got_wtenv' (expected '$B_WT1:$B_WT2')"
        fi
    else
        fail "reuse-multi (B2) new session '$RUM_NEW_SESSION' not alive; cannot probe ZYZ_WORKTREES"
    fi

    rum_teardown
}

# ---------------------------------------------------------------------------
# gh-scope-multi.  orch-merge.sh gh repo-scoping regression guard (review
# finding 1: every gh call must run inside `(cd "$MAIN_REPO" && gh …)` so a
# multi-repo merge hits each repo's OWN main checkout, never the orchestrator's
# arbitrary cwd).  Black-box; creates NO tmux session (orch-merge.sh only needs
# the tmux/git BINARIES on PATH for the merge path).
#
# A stub `gh` placed FIRST on PATH appends its own $PWD (the dir gh was invoked
# from) to $GH_PWD_LOG on every pr list|create|merge, prints empty on list + a
# fake URL on create, exits 0 — so the script believes gh succeeded, no network.
# We drive orch-merge.sh from a neutral cwd that is NEITHER repo (the mktemp
# root) to mimic the orchestrator; if the scoping is removed every gh call runs
# from that launch cwd instead, which the assertion below catches.
#
# Gated on tmux+git binaries (orch-merge.sh hard-requires both at entry:
# `for dep in tmux git`).  No tmux session is created.
# ---------------------------------------------------------------------------
run_gh_scope_multi() {
    say_header "gh-scope-multi orch-merge.sh gh repo-scoping (review finding 1)"

    local merge="$REPO_ROOT/scripts/orch-merge.sh"
    if ! command -v tmux >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 || [ ! -x "$merge" ]; then
        local why="tmux/git not available"
        [ ! -x "$merge" ] && why="orch-merge.sh missing or not executable"
        skip "gh-scope-multi gh invoked from each repo's MAIN_REPO, never the orchestrator cwd ($why)"
        return
    fi

    local GS_ROOT
    GS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-ghscope.XXXXXX")"
    local GS_LIST="$GS_ROOT/list"
    local GS_TID="zyzghsc"
    local GS_R1="$GS_ROOT/repo1" GS_R2="$GS_ROOT/repo2"
    local GS_WT1="$GS_ROOT/wt1"  GS_WT2="$GS_ROOT/wt2"
    local GS_REMOTE1="$GS_ROOT/remote1.git" GS_REMOTE2="$GS_ROOT/remote2.git"
    local GS_BR="task/$GS_TID"
    local GS_LOG="$GS_ROOT/gh-pwd.log"
    local GS_RUNCWD="$GS_ROOT"

    # Build 2 real git repos + linked worktrees on the task branch.
    local gs_ok="true"
    zyzm_build_repo_worktree "$GS_R1" "$GS_WT1" "$GS_BR" "r1.txt" false || gs_ok="false"
    zyzm_build_repo_worktree "$GS_R2" "$GS_WT2" "$GS_BR" "r2.txt" false || gs_ok="false"
    # Give each MAIN_REPO an `origin` so orch-merge.sh sets HAS_ORIGIN=true and
    # takes the gh path (bare remotes so the script's real `git push` succeeds).
    git init -q --bare "$GS_REMOTE1" >/dev/null 2>&1 || gs_ok="false"
    git init -q --bare "$GS_REMOTE2" >/dev/null 2>&1 || gs_ok="false"
    git -C "$GS_R1" remote add origin "$GS_REMOTE1" >/dev/null 2>&1 || gs_ok="false"
    git -C "$GS_R2" remote add origin "$GS_REMOTE2" >/dev/null 2>&1 || gs_ok="false"

    if [ "$gs_ok" != "true" ]; then
        skip "gh-scope-multi gh invoked from each repo's MAIN_REPO, never the orchestrator cwd (git fixture init failed)"
        rm -rf "$GS_ROOT"
        return
    fi

    # Stub gh FIRST on PATH: log the cwd gh was invoked from (repo-scoped =>
    # each repo's MAIN_REPO; un-scoped => the orchestrator launch cwd), print
    # empty on `pr list` (no existing PR), a fake URL on `pr create`, and exit 0
    # everywhere so orch-merge.sh believes gh succeeded (no network, no auth).
    local GS_SHADOW="$GS_ROOT/shadow-bin"
    mkdir -p "$GS_SHADOW"
    cat >"$GS_SHADOW/gh" <<'STUBGHEOF'
#!/bin/sh
# stub gh — record invocation cwd for the repo-scoping regression guard.
pwd -P >> "$GH_PWD_LOG"
case "$1 $2" in
    "pr create") echo "https://example.invalid/pr/1" ;;
    *) : ;;   # `pr list` -> empty stdout (no PR); `pr merge` -> nothing
esac
exit 0
STUBGHEOF
    chmod +x "$GS_SHADOW/gh"
    local GS_RUN_PATH="$GS_SHADOW:$PATH"

    # Master entry (`merge` token) + spawn-shaped 2-repo dispatch.md.
    zyzm_write_merge_entry "$GS_LIST" "$GS_TID" "$GS_R1" "merge"
    zyzm_write_dispatch_2repo "$GS_LIST/runtime/$GS_TID/dispatch.md" "$GS_TID" \
        "$GS_WT1" "$GS_BR" "$GS_WT2" "$GS_BR"

    # Drive orch-merge.sh from a cwd that is NEITHER repo (the mktemp root) to
    # mimic the orchestrator's arbitrary cwd.  Stub gh first on PATH + a fresh
    # log; GH_PWD_LOG steers the stub's per-call cwd record.
    : >"$GS_LOG"
    local gs_out gs_rc
    gs_out="$( cd "$GS_RUNCWD" && env PATH="$GS_RUN_PATH" GH_PWD_LOG="$GS_LOG" \
        bash "$merge" "$GS_TID" "$GS_LIST" main </dev/null 2>&1 )"
    gs_rc=$?

    # Canonicalize both sides to physical paths so a symlinked TMPDIR (macOS
    # /tmp -> /private/tmp) can't cause a spurious mismatch; the stub logs
    # `pwd -P` too.
    local gs_exp1 gs_exp2 gs_cwd_canon
    gs_exp1="$(cd "$GS_R1" && pwd -P)"
    gs_exp2="$(cd "$GS_R2" && pwd -P)"
    gs_cwd_canon="$(cd "$GS_RUNCWD" && pwd -P)"

    local gs_pass="true" gs_why=""
    # gh must have actually been invoked (log non-empty) or the gh path wasn't
    # taken and the guard would silently pass.
    [ -s "$GS_LOG" ] || { gs_pass="false"; gs_why="$gs_why gh-never-invoked(log-empty);"; }
    # gh ran from repo 1's MAIN_REPO …
    grep -qxF "$gs_exp1" "$GS_LOG" \
        || { gs_pass="false"; gs_why="$gs_why gh-not-scoped-to-repo1;"; }
    # … and from repo 2's MAIN_REPO (both distinct repo paths present).
    grep -qxF "$gs_exp2" "$GS_LOG" \
        || { gs_pass="false"; gs_why="$gs_why gh-not-scoped-to-repo2;"; }
    # gh must NEVER have run from the orchestrator's launch cwd (exact-line
    # match so repo1/repo2 subdir lines don't count).
    if grep -qxF "$gs_cwd_canon" "$GS_LOG"; then
        gs_pass="false"; gs_why="$gs_why gh-ran-from-orchestrator-cwd;"
    fi

    if [ "$gs_pass" = "true" ]; then
        pass "gh-scope-multi gh invoked from each repo's MAIN_REPO, never the orchestrator cwd"
    else
        fail "gh-scope-multi failed:$gs_why  merge exit=$gs_rc; gh-pwd-log:
$(sed 's/^/      | /' "$GS_LOG" 2>/dev/null)
      merge output:
$(printf '%s\n' "$gs_out" | sed 's/^/      | /')"
    fi

    rm -rf "$GS_ROOT"
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
run_TR_reuse_neg
run_T5
run_T6
run_T7
run_T8
run_T8_reuse_rewrite
run_TR_reuse_pos
run_T9
run_T10
run_T11_confirm
run_T11_merge
run_T12
run_T4_multi
run_T5_multi
run_T6_multi
run_T11b_multi
run_cleanup_multi
run_reuse_multi
run_gh_scope_multi
run_CONSOL

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
