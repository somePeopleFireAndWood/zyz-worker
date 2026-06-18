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
)

AGENT_FILES=(
    "agents/coding-agent.md"
    "agents/test-agent.md"
    "agents/review-agent.md"
    "subagents/coding-agent.md"
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

    # 6 helper scripts: exist + executable
    local s
    for s in "${HELPER_SCRIPTS[@]}"; do
        check_file_exists "$s"
        if [ -e "$REPO_ROOT/$s" ]; then
            check_file_executable "$s"
        fi
    done

    # The test script itself
    check_file_exists "scripts/test-orchestration-helpers.sh"
    check_file_executable "scripts/test-orchestration-helpers.sh"
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
    check_grep_fixed "$etsk" "phase monotonicity contract 'monotonically furthest'" \
        "monotonically furthest"

    # Each of the 6 agent files: heading + 'wait-state'
    local af
    for af in "${AGENT_FILES[@]}"; do
        check_grep "$af" "'## Orchestrated Mode Hook' heading" \
            '^## Orchestrated Mode Hook([[:space:]]|$)'
        check_grep_fixed "$af" "'wait-state' field mention" "wait-state"
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

    # ---- orch-spawn-worker.sh : <task-id> <list-dir> [--auto-start] ----
    t4_no_args        "scripts/orch-spawn-worker.sh"
    t4_invalid_taskid "scripts/orch-spawn-worker.sh"
    t4_missing_dep    "scripts/orch-spawn-worker.sh" "foo" "/tmp/zyz-orch-t4-dummy-list"

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

    # Phase walkthrough: design -> coding -> coding+waiting-subagent ->
    # coding+none -> testing -> review -> delivery -> done.
    write_worker_status "$runtime" design none
    t5_assert_check "$list_dir" "foo" "phase" "design"
    t5_assert_check "$list_dir" "foo" "wait-state" "none"

    write_worker_status "$runtime" coding none
    t5_assert_check "$list_dir" "foo" "phase" "coding"
    t5_assert_check "$list_dir" "foo" "wait-state" "none"

    write_worker_status "$runtime" coding waiting-subagent "dispatched test-agent"
    t5_assert_check "$list_dir" "foo" "phase" "coding"
    t5_assert_check "$list_dir" "foo" "wait-state" "waiting-subagent"

    write_worker_status "$runtime" coding none
    t5_assert_check "$list_dir" "foo" "wait-state" "none"

    write_worker_status "$runtime" testing none
    t5_assert_check "$list_dir" "foo" "phase" "testing"

    write_worker_status "$runtime" review none
    t5_assert_check "$list_dir" "foo" "phase" "review"

    write_worker_status "$runtime" delivery none
    t5_assert_check "$list_dir" "foo" "phase" "delivery"

    write_worker_status "$runtime" done none
    t5_assert_check "$list_dir" "foo" "phase" "done"

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
    # sees the count matches expectations.  10 planned checks in T6.
    local i
    for i in \
        "tmux session zyz-task-foo created" \
        "runtime dir <list-dir>/runtime/foo exists" \
        "heartbeat file present after spawn" \
        "orch-check-worker.sh reports phase=done after mock worker" \
        "orch-merge-and-cleanup.sh exits 0" \
        "master entry state: completed after merge" \
        "tmux session zyz-task-foo absent after cleanup" \
        "worktree removed after cleanup" \
        "no orch-heartbeat-daemon.sh residue after teardown (F8)" \
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
    T6_TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/zyz-orch-t6.XXXXXX")"
    T6_TMUX_SESSION="zyz-task-foo"
    T6_LIST_DIR="$T6_TMPROOT/list"
    T6_ORIGIN_DIR="$T6_TMPROOT/origin.git"
    T6_WORK_DIR="$T6_TMPROOT/work"
    T6_WORKTREE_DIR="$T6_TMPROOT/worktrees/foo"

    # Convenience local aliases used throughout this function body.  The
    # T6_* globals carry the same values and are what the teardown reads.
    local TMPROOT="$T6_TMPROOT"
    local TMUX_SESSION="$T6_TMUX_SESSION"
    local LIST_DIR="$T6_LIST_DIR"
    local ORIGIN_DIR="$T6_ORIGIN_DIR"
    local WORK_DIR="$T6_WORK_DIR"
    local WORKTREE_DIR="$T6_WORKTREE_DIR"

    # Teardown function reads T6_* globals (not the local copies).
    # Defined inline so it is in the function table when the trap fires.
    t6_teardown() {
        # Best-effort kill of tmux session in case the test left it alive
        # due to an early failure.  This is allowed by F8 — F8 only
        # forbids manual pkill of orch-heartbeat-daemon.sh; killing the
        # tmux session is the *natural* path that should also kill the
        # daemon via SIGHUP.
        tmux kill-session -t "$T6_TMUX_SESSION" 2>/dev/null || true

        # Per F8: after teardown, there must be NO orch-heartbeat-daemon.sh
        # processes left running.  Wait up to 3 seconds for the SIGHUP
        # propagation, then check.
        sleep 2
        local residue
        residue="$(pgrep -f 'orch-heartbeat-daemon\.sh' 2>/dev/null || true)"
        if [ -n "$residue" ]; then
            T6_FAIL "no orch-heartbeat-daemon.sh residue after teardown (F8) -- pids: $residue"
            # Don't pkill ourselves; F8 forbids it.  Leave for operator.
        else
            T6_PASS "no orch-heartbeat-daemon.sh residue after teardown (F8)"
        fi

        rm -rf "$T6_TMPROOT"
        T6_PASS "T6 fixture teardown clean"
    }
    # shellcheck disable=SC2064
    trap "t6_teardown" EXIT

    # --- Init the two git repos ---
    if ! git init --bare "$ORIGIN_DIR" >/dev/null 2>&1; then
        T6_FAIL "git init --bare $ORIGIN_DIR failed"
        return
    fi
    mkdir -p "$WORK_DIR"
    (
        cd "$WORK_DIR" || exit 1
        git init -q . >/dev/null 2>&1
        git config user.email "t6@example.com"
        git config user.name "T6 Test"
        git checkout -q -b main 2>/dev/null || git checkout -q main
        echo "T6 initial" >README.md
        git add README.md
        git commit -q -m "initial"
        git remote add origin "$ORIGIN_DIR" 2>/dev/null || true
        git push -q origin main 2>/dev/null || true
    ) || { T6_FAIL "git init in $WORK_DIR failed"; return; }

    # --- Build master entry pointing at the work repo as worktree base ---
    mkdir -p "$LIST_DIR/tasks"
    {
        echo "---"
        echo "task-id: foo"
        echo "project: t6-mock"
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
        echo "source-repo: $WORK_DIR"
        echo "---"
        echo ""
        echo "# foo (T6 mock)"
        echo ""
        echo "## Description"
        echo ""
        echo "T6 real-tmux integration test."
    } >"$LIST_DIR/tasks/foo.md"

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
        # warn — coding-agent's real gh may execute and the test may
        # misclassify the merge as a real conflict.
        echo "  WARN  T6 fake gh shadow not active: command -v gh -> $resolved_gh"
    fi

    # --- Invoke spawn-worker --------------------------------------------
    # We pass the WORK_DIR as the source repo via env var ZYZ_SOURCE_REPO
    # AND via the master entry frontmatter `source-repo:` field, AND we cd
    # into WORK_DIR before invoking spawn.  The design (§E.2) does not pin
    # down exactly how spawn finds the project repo (the worktree-path
    # default is `~/.zyz-worker/worktrees/<project>/<branch>`); offering
    # multiple discovery paths is belt-and-braces compatibility.
    local spawn_rc spawn_out
    spawn_out="$(
        cd "$WORK_DIR" \
        && PATH="$GH_STRIPPED_PATH" \
           ZYZ_SOURCE_REPO="$WORK_DIR" \
           bash "$spawn" foo "$LIST_DIR" </dev/null 2>&1
    )"
    spawn_rc=$?

    if [ "$spawn_rc" -ne 0 ]; then
        T6_FAIL "orch-spawn-worker.sh exited $spawn_rc.  Output:
$(printf '%s\n' "$spawn_out" | sed 's/^/      | /')"
        # Continue to teardown; remaining checks SKIP.
        local i
        for i in \
            "tmux session $TMUX_SESSION created" \
            "runtime dir $LIST_DIR/runtime/foo exists" \
            "heartbeat file present after spawn" \
            "orch-check-worker.sh reports phase=done after mock worker" \
            "orch-merge-and-cleanup.sh exits 0" \
            "master entry state: completed after merge" \
            "tmux session $TMUX_SESSION absent after cleanup" \
            "worktree removed after cleanup"
        do
            skip "T6 $i (skipped: spawn failed)"
        done
        return
    fi

    # Allow tmux session + in-pane daemon a moment to come up.
    sleep 1

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        T6_PASS "tmux session $TMUX_SESSION created"
    else
        T6_FAIL "tmux session $TMUX_SESSION NOT created"
    fi

    if [ -d "$LIST_DIR/runtime/foo" ]; then
        T6_PASS "runtime dir $LIST_DIR/runtime/foo exists"
    else
        T6_FAIL "runtime dir $LIST_DIR/runtime/foo missing"
    fi

    # Heartbeat: may take a moment.  Poll up to 5 seconds.
    local hb_present=0 try
    for try in 1 2 3 4 5; do
        if [ -e "$LIST_DIR/runtime/foo/heartbeat" ]; then
            hb_present=1
            break
        fi
        sleep 1
    done
    if [ "$hb_present" -eq 1 ]; then
        T6_PASS "heartbeat file present after spawn"
    else
        T6_FAIL "heartbeat file NOT present after spawn"
    fi

    # --- Send keys: a tiny bash mock worker writes phase=done ---
    # We send a small inline bash command that overwrites worker-status.md
    # with phase=done.  We do NOT start `claude` (per design).
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local mock_cmd="cat > '$LIST_DIR/runtime/foo/worker-status.md' <<MOCKEOF
---
task-id: foo
phase: done
phase-since: $now
wait-state: none
waiting-reason:
expected-resume-by:
last-flush: $now
---

## Current Activity

T6 mock worker finished.
MOCKEOF"

    # tmux send-keys requires the literal command then Enter.
    tmux send-keys -t "$TMUX_SESSION" "$mock_cmd" Enter 2>/dev/null || true
    sleep 2

    # Verify phase=done via the helper.
    local check_out check_rc
    check_out="$(bash "$check" foo "$LIST_DIR" </dev/null 2>&1)"
    check_rc=$?
    if [ "$check_rc" -eq 0 ] && printf '%s\n' "$check_out" | grep -qE '^phase=done([[:space:]]|$)'; then
        T6_PASS "orch-check-worker.sh reports phase=done after mock worker"
    else
        T6_FAIL "orch-check-worker.sh did NOT report phase=done (rc=$check_rc).  Output:
$(printf '%s\n' "$check_out" | sed 's/^/      | /')"
    fi

    # --- Write 'approved' to master entry's ## Pending Merge Approval ---
    {
        echo ""
        echo "## Pending Merge Approval"
        echo ""
        echo "approved by T6-test at $now"
    } >>"$LIST_DIR/tasks/foo.md"

    # --- Invoke merge-and-cleanup ---
    local merge_rc merge_out
    merge_out="$(
        PATH="$GH_STRIPPED_PATH" \
        bash "$merge" foo "$LIST_DIR" main </dev/null 2>&1
    )"
    merge_rc=$?

    if [ "$merge_rc" -eq 0 ]; then
        T6_PASS "orch-merge-and-cleanup.sh exits 0"
    else
        T6_FAIL "orch-merge-and-cleanup.sh exited $merge_rc.  Output:
$(printf '%s\n' "$merge_out" | sed 's/^/      | /')"
    fi

    # Master entry frontmatter should now show state: completed.
    if grep -qE '^state:[[:space:]]*completed' "$LIST_DIR/tasks/foo.md"; then
        T6_PASS "master entry state: completed after merge"
    else
        T6_FAIL "master entry state is NOT 'completed' after merge"
    fi

    # tmux session should be gone.
    sleep 1
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        T6_FAIL "tmux session $TMUX_SESSION still alive after cleanup"
    else
        T6_PASS "tmux session $TMUX_SESSION absent after cleanup"
    fi

    # worktree should be gone.
    if [ -d "$WORKTREE_DIR" ]; then
        T6_FAIL "worktree $WORKTREE_DIR still present after cleanup"
    else
        T6_PASS "worktree removed after cleanup"
    fi

    # Teardown trap will run the F8 daemon-residue check + cleanup.
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
run_T5
run_T6
run_T7

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
