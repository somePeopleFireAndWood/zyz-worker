#!/usr/bin/env bash
#
# Static-check suite for the rename-and-conventions task.
#
# Implements T1-T6 from
#   .zyz-worker/tasks/rename-and-conventions/design.md  ##  Testing Plan
#
# Usage:
#   bash scripts/test-rename-and-conventions.sh
#
# Behavior:
#   - Runs all six test groups to completion (does NOT bail on first failure).
#   - Prints PASS / FAIL: <reason> per check.
#   - Prints a final summary line:  RESULT: <passed>/<total> checks passed
#   - Exits 0 on success, 1 if any check failed.
#
# Notes:
#   - Designed for macOS bash 3.2 and Linux bash 4+.  No bash 4 features used.
#   - Reference scans use `git ls-files -z` so untracked dirs such as
#     docs/superpowers/ and node_modules/ are ignored automatically.

# Intentionally NOT using `set -e`: every check must run regardless of any
# single failure so the operator sees the full picture.
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

# ---------------------------------------------------------------------------
# Helpers
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

# check_file_exists <relpath>
check_file_exists() {
    local p="$1"
    if [ -e "$REPO_ROOT/$p" ]; then
        pass "exists: $p"
    else
        fail "missing: $p"
    fi
}

# check_file_absent <relpath>
check_file_absent() {
    local p="$1"
    if [ ! -e "$REPO_ROOT/$p" ]; then
        pass "absent: $p"
    else
        fail "must not exist but does: $p"
    fi
}

# ---------------------------------------------------------------------------
# T1.  File existence / non-existence
# ---------------------------------------------------------------------------
run_T1() {
    say_header "T1  File existence / non-existence"

    check_file_exists "skills/execute-task/SKILL.md"
    check_file_absent "skills/code-development"
    check_file_absent "skills/zyz-worker"
    check_file_exists "commands/execute-task.md"
    check_file_exists "commands/code-development.md"
    check_file_exists "docs/conventions/long-running-state.md"
}

# ---------------------------------------------------------------------------
# T2.  Reference consistency (git ls-files only)
#
#  Three sub-scans:
#    (a) "code-development"           — every hit must be in the whitelist
#    (b) "skills/code-development"    — only allowed under
#                                       .zyz-worker/tasks/rename-and-conventions/
#                                       or docs/design/execute-task-skill-design.md
#    (c) "skills/zyz-worker"          — zero hits anywhere
# ---------------------------------------------------------------------------

# is_in_whitelist <path> <whitelist-array-name>
# Whitelist entries match in two ways:
#   * exact path equality   (e.g. "README.md")
#   * prefix as directory   (entry ends in '/' and path begins with it)
# Returns 0 if match.
is_whitelisted() {
    local path="$1"
    shift
    local entry
    for entry in "$@"; do
        case "$entry" in
            */)
                case "$path" in
                    "$entry"*) return 0 ;;
                esac
                ;;
            *)
                if [ "$path" = "$entry" ]; then
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

run_T2() {
    say_header "T2  Reference consistency"

    # Whitelist for bare-string "code-development".
    #
    # NOTE: scripts/test-rename-and-conventions.sh is whitelisted because this
    # script itself must reason about the string "code-development" by name
    # (whitelist entries, comments, grep patterns).  Without this entry, the
    # first time the script is `git add`-ed it would flag its own contents.
    local wl_full=(
        "commands/code-development.md"
        "docs/design/execute-task-skill-design.md"
        "docs/design/initial-design.md"
        "docs/conventions/project-structure.md"
        "docs/automation-todo.md"
        ".zyz-worker/tasks/rename-and-conventions/"
        ".claude-plugin/plugin.json"
        ".claude-plugin/marketplace.json"
        "README.md"
        "CLAUDE.md"
        "CHANGELOG.md"
        "scripts/test-rename-and-conventions.sh"
        "scripts/test-release-0-5-0.sh"
    )

    # Whitelist for "skills/code-development".
    # NOTE: scripts/test-rename-and-conventions.sh is self-whitelisted for the
    # same reason as in wl_full above — the script must reason about
    # "skills/code-development" by name (comments, grep patterns, messages).
    local wl_skills_cd=(
        ".zyz-worker/tasks/rename-and-conventions/"
        "scripts/test-rename-and-conventions.sh"
    )

    # --- (a) bare "code-development" -------------------------------------
    local out_a
    # `-d skip` is essential: `git ls-files` lists the symlinks
    # `.claude/agents` -> ../agents and `.claude/commands` -> ../commands,
    # which grep sees as directories. Without `-d skip`, grep errors
    # ("Is a directory"), exits non-zero, poisons the pipeline exit code,
    # the `if !` below fires, out_a is blanked, and the whole T2(a) check
    # silently passes — a latent bug present since stage A. `-d skip`
    # makes grep skip symlink-to-dir entries cleanly so the real hits are
    # captured and checked. (grep also returns 1 when there are genuinely
    # no matches, which the blank-out_a fallback still handles correctly.)
    if ! out_a="$(git ls-files -z | xargs -0 grep -nIH -d skip "code-development" 2>/dev/null)"; then
        out_a=""
    fi

    local violations_a=0
    if [ -n "$out_a" ]; then
        local line file
        # Use here-string to feed lines into a loop without subshell scoping
        # surprises.  Bash 3.2 compatible.
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            # Format: <file>:<lineno>:<content>
            file="${line%%:*}"
            if ! is_whitelisted "$file" "${wl_full[@]}"; then
                fail "T2(a) unexpected 'code-development' hit  -->  $line"
                violations_a=$((violations_a + 1))
            fi
        done <<EOF
$out_a
EOF
    fi
    if [ "$violations_a" -eq 0 ]; then
        pass "T2(a) all 'code-development' references are in the whitelist"
    fi

    # --- (b) "skills/code-development" -----------------------------------
    local out_b
    if ! out_b="$(git ls-files -z | xargs -0 grep -nIH -d skip "skills/code-development" 2>/dev/null)"; then
        out_b=""
    fi

    local violations_b=0
    if [ -n "$out_b" ]; then
        local line file
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            file="${line%%:*}"
            if ! is_whitelisted "$file" "${wl_skills_cd[@]}"; then
                fail "T2(b) unexpected 'skills/code-development' hit  -->  $line"
                violations_b=$((violations_b + 1))
            fi
        done <<EOF
$out_b
EOF
    fi
    if [ "$violations_b" -eq 0 ]; then
        pass "T2(b) no stray 'skills/code-development' references outside whitelist"
    fi

    # --- (c) "skills/zyz-worker"  -- must be zero except legit keepers --
    # The placeholder skill skills/zyz-worker/ was removed in stage A. No
    # live file should reference it, EXCEPT: (1) CHANGELOG.md history entry
    # documenting the removal, and (2) this test script, which must name
    # the string to check for its absence (self-reference). Both are
    # legitimate keepers, not regressions.
    local wl_zyz=(
        "CHANGELOG.md"
        "scripts/test-rename-and-conventions.sh"
    )
    local out_c
    if ! out_c="$(git ls-files -z | xargs -0 grep -nIH -d skip "skills/zyz-worker" 2>/dev/null)"; then
        out_c=""
    fi

    local violations_c=0
    if [ -n "$out_c" ]; then
        local line file
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            file="${line%%:*}"
            if ! is_whitelisted "$file" "${wl_zyz[@]}"; then
                fail "T2(c) forbidden 'skills/zyz-worker' hit  -->  $line"
                violations_c=$((violations_c + 1))
            fi
        done <<EOF
$out_c
EOF
    fi
    if [ "$violations_c" -eq 0 ]; then
        pass "T2(c) no stray 'skills/zyz-worker' references outside whitelist"
    fi
}

# ---------------------------------------------------------------------------
# T3.  Frontmatter consistency
# ---------------------------------------------------------------------------
run_T3() {
    say_header "T3  Frontmatter consistency"

    local skill="skills/execute-task/SKILL.md"
    if [ ! -f "$skill" ]; then
        fail "T3 cannot check name field — $skill does not exist"
    else
        if head -n 10 "$skill" | grep -q "^name: execute-task[[:space:]]*$"; then
            pass "T3 $skill frontmatter has 'name: execute-task'"
        else
            fail "T3 $skill frontmatter is missing 'name: execute-task' (first 10 lines):"
            head -n 10 "$skill" | sed 's/^/      | /'
        fi
    fi

    # No skill under skills/ should declare 'name: code-development'.
    # Use a tmp file list to avoid xargs-with-no-input hanging on grep stdin.
    local file_list stray
    file_list="$(find skills -type f -name '*.md' 2>/dev/null || true)"
    if [ -z "$file_list" ]; then
        pass "T3 no markdown files under skills/ (nothing to scan)"
    else
        stray="$(printf '%s\n' "$file_list" \
                | xargs grep -nIH "^name: code-development[[:space:]]*$" 2>/dev/null || true)"
        if [ -z "$stray" ]; then
            pass "T3 no 'name: code-development' frontmatter anywhere under skills/"
        else
            local line
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                fail "T3 stray 'name: code-development' frontmatter  -->  $line"
            done <<EOF
$stray
EOF
        fi
    fi
}

# ---------------------------------------------------------------------------
# T4.  Long-Running State hard-constraint insertion
# ---------------------------------------------------------------------------

# Extract a relative link to docs/conventions/long-running-state.md from $1.
# Echoes the first such relative path found, or empty.
extract_lrs_link() {
    local file="$1"
    # Match (...docs/conventions/long-running-state.md) inside any markdown link.
    grep -oE '\(([^)]*docs/conventions/long-running-state\.md)\)' "$file" 2>/dev/null \
        | head -n 1 \
        | sed -E 's/^\(//; s/\)$//'
}

# --- Shared link sub-checks used by both Pattern A and Pattern B -----------
#
# check_lrs_link_presence_and_resolution <file>
#   (a) Asserts the file contains a markdown link whose target ends in
#       docs/conventions/long-running-state.md.
#   (b) Asserts the link is '../'-prefixed (i.e. relative, not absolute or
#       site-root).
#   (c) Asserts the link resolves to an existing file when interpreted
#       relative to the containing directory.
#
# Each call adds up to three PASS/FAIL records.
check_lrs_link_presence_and_resolution() {
    local file="$1"

    local link
    link="$(extract_lrs_link "$file")"
    if [ -z "$link" ]; then
        fail "T4 $file has no link to docs/conventions/long-running-state.md"
        return
    fi

    case "$link" in
        ../*)
            pass "T4 $file links to long-running-state.md (relative: $link)"
            ;;
        *)
            fail "T4 $file long-running-state.md link is not '../'-prefixed  -->  $link"
            ;;
    esac

    local dir target
    dir="$(dirname "$file")"
    if ( cd "$dir" && [ -f "$link" ] ); then
        target="$(cd "$dir" && cd "$(dirname "$link")" && pwd)/$(basename "$link")"
        pass "T4 $file link resolves  -->  $target"
    else
        fail "T4 $file link '$link' does not resolve from $dir/"
    fi
}

# --- Pattern A: dedicated heading insertion --------------------------------
#
# Design §E2 Pattern A: 6 agent files plus skills/git-worktree/SKILL.md
# gain a NEW heading.  Six files get "## Long-Running State", git-worktree
# gets "## Long-Running Considerations".
#
# check_lrs_pattern_a <file> <heading_pattern>
#   heading_pattern is an ERE alternation, e.g.
#     "Long-Running State"
#     "Long-Running State|Long-Running Considerations"
#
# Each call adds 1 heading check plus the shared link sub-checks
# (3 records total when the file exists).
check_lrs_pattern_a() {
    local file="$1"
    local heading_pattern="$2"

    if [ ! -f "$file" ]; then
        fail "T4 $file does not exist"
        return
    fi

    if grep -qE "$heading_pattern" "$file"; then
        pass "T4 $file [Pattern A] contains heading matching /$heading_pattern/"
    else
        fail "T4 $file [Pattern A] is missing heading matching /$heading_pattern/"
    fi

    check_lrs_link_presence_and_resolution "$file"
}

# --- Pattern B: bullet appended to an existing list ------------------------
#
# Design §E2 Pattern B: skills/execute-task/SKILL.md and
# skills/execute-task/prompts/main-agent.md append a bullet to an
# existing list and do NOT introduce a new "## Long-Running State" heading.
# Design §E4 fixes the exact bullet wording:
#   * SKILL.md:        "Long-running tasks must persist progress, ..."
#   * main-agent.md:   "Persist long-running task progress, ..."
#
# check_lrs_pattern_b <file> <bullet_marker_substring>
#   The bullet_marker_substring is matched case-insensitively as a plain
#   substring (no regex), and only on lines beginning with the markdown
#   bullet "- " — this guarantees the wording really lives inside the
#   existing bullet list rather than appearing in prose elsewhere.
#
# Each call adds 1 bullet check plus the shared link sub-checks
# (3 records total when the file exists).
check_lrs_pattern_b() {
    local file="$1"
    local bullet_marker="$2"

    if [ ! -f "$file" ]; then
        fail "T4 $file does not exist"
        return
    fi

    # Bullet lines beginning with "- " that contain the marker substring,
    # case-insensitively.  -F keeps the marker literal.
    # NOTE: no -q on the downstream grep — under `set -o pipefail`, -q exits
    # on the first match and closes the pipe's read end, so the upstream grep
    # can die of SIGPIPE (141) mid-write and the whole pipeline flakes to
    # FAIL despite the match. >/dev/null keeps the exit semantics while the
    # downstream reads all input.
    if grep -i -n '^- ' "$file" | grep -i -F -- "$bullet_marker" >/dev/null; then
        pass "T4 $file [Pattern B] has bullet matching '$bullet_marker'"
    else
        fail "T4 $file [Pattern B] is missing bullet matching '$bullet_marker'"
    fi

    check_lrs_link_presence_and_resolution "$file"
}

run_T4() {
    say_header "T4  Long-Running State hard-constraint insertion"

    # ---- Pattern A: 6 agent files, dedicated "## Long-Running State" -----
    local pattern_a_files=(
        "subagents/implementation-agent.md"
        "subagents/test-agent.md"
        "subagents/review-agent.md"
        "agents/implementation-agent.md"
        "agents/test-agent.md"
        "agents/review-agent.md"
    )
    local f
    for f in "${pattern_a_files[@]}"; do
        check_lrs_pattern_a "$f" "Long-Running State"
    done

    # Pattern A: git-worktree uses "## Long-Running Considerations"
    # (accept either label so a future rename to "State" still passes).
    check_lrs_pattern_a "skills/git-worktree/SKILL.md" \
        "Long-Running State|Long-Running Considerations"

    # ---- Pattern B: bullet appended to existing list, no new heading ----
    # skills/execute-task/SKILL.md   — bullet under "## Core Rules"
    # Design §E4 wording starts with "Long-running tasks must persist".
    check_lrs_pattern_b "skills/execute-task/SKILL.md" \
        "Long-running tasks must persist"

    # skills/execute-task/prompts/main-agent.md — bullet under "## Responsibilities"
    # Design §E4 wording starts with "Persist long-running task progress".
    check_lrs_pattern_b "skills/execute-task/prompts/main-agent.md" \
        "Persist long-running task progress"
}

# ---------------------------------------------------------------------------
# T5.  Slash command alias equivalence
#
#  Bodies must be identical after stripping the 'description:' frontmatter
#  line from each.
# ---------------------------------------------------------------------------
run_T5() {
    say_header "T5  Slash command alias equivalence"

    local a="commands/execute-task.md"
    local b="commands/code-development.md"

    if [ ! -f "$a" ] || [ ! -f "$b" ]; then
        fail "T5 cannot diff — one or both command files missing ($a, $b)"
        return
    fi

    local diff_out
    diff_out="$(diff <(grep -v '^description:' "$a") \
                    <(grep -v '^description:' "$b"))"
    if [ -z "$diff_out" ]; then
        pass "T5 $a and $b are identical after stripping 'description:'"
    else
        fail "T5 $a and $b differ outside the 'description:' line:"
        printf '%s\n' "$diff_out" | sed 's/^/      | /'
    fi
}

# ---------------------------------------------------------------------------
# T6.  README opening + skills/zyz-worker/ absence
# ---------------------------------------------------------------------------
run_T6() {
    say_header "T6  README content"

    local readme="README.md"
    if [ ! -f "$readme" ]; then
        fail "T6 $readme does not exist"
        return
    fi

    local marker
    for marker in "周钰喆" "工人阶级" "解放全人类" "实际工作时"; do
        if grep -q "$marker" "$readme"; then
            pass "T6 $readme contains '$marker'"
        else
            fail "T6 $readme is missing required marker '$marker'"
        fi
    done

    if grep -qn "skills/zyz-worker/" "$readme"; then
        local hits
        hits="$(grep -n "skills/zyz-worker/" "$readme")"
        fail "T6 $readme still mentions 'skills/zyz-worker/':"
        printf '%s\n' "$hits" | sed 's/^/      | /'
    else
        pass "T6 $readme does not mention 'skills/zyz-worker/'"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "Running rename-and-conventions static-check suite"
echo "Repo root: $REPO_ROOT"

run_T1
run_T2
run_T3
run_T4
run_T5
run_T6

echo
echo "============================================================"
if [ "$FAILED" -eq 0 ]; then
    echo "RESULT: $PASSED/$TOTAL checks passed"
    echo "============================================================"
    exit 0
else
    echo "RESULT: $PASSED/$TOTAL checks passed  ($FAILED failed)"
    echo "============================================================"
    exit 1
fi
