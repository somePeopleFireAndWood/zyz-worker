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

    # ---- orch-spawn-worker.sh : <task-id> <list-dir> [--auto-start] ----
    t4_no_args        "scripts/orch-spawn-worker.sh"
    t4_invalid_taskid "scripts/orch-spawn-worker.sh"
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
        "orch-check-worker.sh reports phase=done after mock worker (foo)" \
        "orch-check-worker.sh reports phase=done after mock worker (bar) (F.2)" \
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
        # warn — coding-agent's real gh may execute and the test may
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
            "orch-check-worker.sh reports phase=done after mock worker (foo)" \
            "orch-check-worker.sh reports phase=done after mock worker (bar) (F.2)" \
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

    # --- Send keys: a tiny bash mock worker writes phase=done in each pane ---
    # We send a small inline bash command that overwrites worker-status.md
    # with phase=done.  We do NOT start `claude` (per design).
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Helper to build the mock-worker tmux send-keys command for a task-id.
    # Emitted as a single argv so caller can `tmux send-keys -t SESSION "<cmd>" Enter`.
    t6_mock_cmd() {
        local tid="$1"
        echo "cat > '$LIST_DIR/runtime/$tid/worker-status.md' <<MOCKEOF
---
task-id: $tid
phase: done
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

    # Verify phase=done via the helper, for each task.
    local check_out check_rc
    check_out="$(bash "$check" foo "$LIST_DIR" </dev/null 2>&1)"
    check_rc=$?
    if [ "$check_rc" -eq 0 ] && printf '%s\n' "$check_out" | grep -qE '^phase=done([[:space:]]|$)'; then
        T6_PASS "orch-check-worker.sh reports phase=done after mock worker (foo)"
    else
        T6_FAIL "orch-check-worker.sh did NOT report phase=done for foo (rc=$check_rc).  Output:
$(printf '%s\n' "$check_out" | sed 's/^/      | /')"
    fi
    if [ "$spawn2_rc" -eq 0 ]; then
        local check_out_bar check_rc_bar
        check_out_bar="$(bash "$check" bar "$LIST_DIR" </dev/null 2>&1)"
        check_rc_bar=$?
        if [ "$check_rc_bar" -eq 0 ] && printf '%s\n' "$check_out_bar" | grep -qE '^phase=done([[:space:]]|$)'; then
            T6_PASS "orch-check-worker.sh reports phase=done after mock worker (bar) (F.2)"
        else
            T6_FAIL "orch-check-worker.sh did NOT report phase=done for bar (rc=$check_rc_bar).  Output:
$(printf '%s\n' "$check_out_bar" | sed 's/^/      | /')"
        fi
    else
        skip "T6 orch-check-worker.sh reports phase=done after mock worker (bar) (F.2) (skipped: spawn bar failed)"
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
