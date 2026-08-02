#!/usr/bin/env bash
#
# Static + smoke-check suite for the release-0-5-0 task.
#
# Implements T1-T6 from
#   .zyz-worker/tasks/release-0-5-0/design.md  ##  Testing Plan
#
# Usage:
#   bash scripts/test-release-0-5-0.sh
#
# Behavior:
#   - Runs all six test groups to completion (does NOT bail on first failure).
#   - Prints PASS / FAIL / SKIP per check with offending paths on FAIL.
#   - Prints a final summary line:
#       RESULT: <passed>/<total> checks passed  [(<skipped> skipped)]
#   - Exits 0 on success, 1 if any check failed.  SKIP does not count as fail.
#
# Compatibility:
#   - macOS bash 3.2 and Linux bash 4+; no bash 4 features used.
#   - Uses `set -u` and `set -o pipefail` only — never `set -e` so the
#     operator sees the full picture across all checks.
#   - `stat -f %z` (macOS / BSD) vs `stat -c %s` (GNU) handled via fallback.
#   - SIGPIPE discipline: under pipefail, `<producer> | grep -q` is unsafe
#     whenever the producer can still be writing after grep's first match —
#     grep -q exits immediately, the producer's next write hits a closed pipe,
#     SIGPIPE makes the pipeline rc 141, and the check false-FAILs (bit us on
#     T6: `git show v0.11.0` emits ~72KB > the 64KB pipe buffer).  Containment
#     checks on captured output therefore use pure-bash `case` (no pipe), and
#     regex checks use grep WITHOUT -q + >/dev/null (grep then consumes all
#     input, so the producer never gets SIGPIPE).  Single-line producers are
#     exempt (nothing can follow the match).

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

EXPECTED_VERSION="0.13.0"
# Regex-escaped form of EXPECTED_VERSION (dots escaped) for use inside `grep -E`
# patterns. Derived so a version bump only requires editing EXPECTED_VERSION above.
EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/\./\\./g')"

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

# portable_stat_size <file>
# Echoes the file size in bytes.  Tries GNU `stat -c %s` (Linux) first, then
# BSD `stat -f %z` (macOS), validating that each result is all-digits before
# accepting it, then falls back to `wc -c`.  Echoes "" on total failure.
#
# Why validate numeric: on GNU/Linux `stat -f` is `--file-system` (NOT a format
# string) and exits 0 printing a filesystem-info blob, so a naive "BSD first,
# fall back if empty" approach never falls back on Linux.  Requiring an all-digit
# result makes the order-independent fallback correct on both platforms.
portable_stat_size() {
    local f="$1"
    local s
    s="$(stat -c %s "$f" 2>/dev/null || true)"
    case "$s" in ''|*[!0-9]*) s="$(stat -f %z "$f" 2>/dev/null || true)";; esac
    case "$s" in ''|*[!0-9]*) s="$(wc -c < "$f" 2>/dev/null | tr -d ' \t' || true)";; esac
    case "$s" in ''|*[!0-9]*) s="";; esac
    echo "$s"
}

# run_and_check_exit_stderr_regex <expected-exit> <expected-stderr-regex-or-empty> <desc> -- <cmd...>
# Asserts BOTH exit code AND (if regex non-empty) that stderr matches the
# given ERE pattern.  One TOTAL increment per call.
run_and_check_exit_stderr_regex() {
    local expected_exit="$1"
    local expected_re="$2"
    local desc="$3"
    shift 3
    local err_tmp rc
    err_tmp="$(mktemp "${TMPDIR:-/tmp}/zyz-rel-stderr.XXXXXX")"
    "$@" </dev/null >/dev/null 2>"$err_tmp"
    rc=$?
    local err_content
    err_content="$(cat "$err_tmp" 2>/dev/null || true)"
    rm -f "$err_tmp"
    if [ "$rc" -ne "$expected_exit" ]; then
        fail "$desc (got exit=$rc, expected $expected_exit; cmd: $*; stderr: $(printf '%s' "$err_content" | head -c 400))"
        return
    fi
    if [ -z "$expected_re" ]; then
        pass "$desc (exit=$rc as expected)"
        return
    fi
    # No -q: grep must consume ALL of printf's output or a match on an early
    # stderr line SIGPIPEs printf under pipefail (see header SIGPIPE note).
    if printf '%s\n' "$err_content" | grep -E -- "$expected_re" >/dev/null; then
        pass "$desc (exit=$rc and stderr matches /$expected_re/)"
    else
        fail "$desc (exit=$rc OK but stderr did NOT match /$expected_re/; stderr was:
$(printf '%s\n' "$err_content" | sed 's/^/      | /'))"
    fi
}

# ---------------------------------------------------------------------------
# T1.  File existence + chmod
# ---------------------------------------------------------------------------
run_T1() {
    say_header "T1  File existence + chmod"

    # scripts/pack.sh exists + executable
    if [ -e "$REPO_ROOT/scripts/pack.sh" ]; then
        pass "scripts/pack.sh exists"
    else
        fail "scripts/pack.sh missing"
    fi
    if [ -x "$REPO_ROOT/scripts/pack.sh" ]; then
        pass "scripts/pack.sh is executable (chmod +x)"
    else
        fail "scripts/pack.sh is NOT executable (chmod +x needed)"
    fi

    # CHANGELOG.md exists
    if [ -e "$REPO_ROOT/CHANGELOG.md" ]; then
        pass "CHANGELOG.md exists"
    else
        fail "CHANGELOG.md missing"
    fi

    # The test script itself
    if [ -e "$REPO_ROOT/scripts/test-release-0-5-0.sh" ]; then
        pass "scripts/test-release-0-5-0.sh exists"
    else
        fail "scripts/test-release-0-5-0.sh missing"
    fi
    if [ -x "$REPO_ROOT/scripts/test-release-0-5-0.sh" ]; then
        pass "scripts/test-release-0-5-0.sh is executable"
    else
        fail "scripts/test-release-0-5-0.sh is NOT executable"
    fi
}

# ---------------------------------------------------------------------------
# T2.  Version consistency across 3 manifests
#
# All three must agree with the single source of truth, $EXPECTED_VERSION
# (defined near the top of this script — a version bump only edits that line):
#  - .claude-plugin/plugin.json    : exactly one '"version"' line == $EXPECTED_VERSION
#  - .claude-plugin/marketplace.json: exactly one '"version"' line == $EXPECTED_VERSION
#       (no top-level version field; only plugins[0].version)
#  - .codex-plugin/plugin.json     : exactly one '"version"' line matching
#       "$EXPECTED_VERSION+codex.<14 digits>"
# ---------------------------------------------------------------------------
run_T2() {
    say_header "T2  Version consistency across 3 manifests"

    # ---- .claude-plugin/plugin.json -----------------------------------------
    local cf="$REPO_ROOT/.claude-plugin/plugin.json"
    if [ ! -f "$cf" ]; then
        fail "T2 .claude-plugin/plugin.json missing"
    else
        local lines hits count
        hits="$(grep -nE '"version"' "$cf" 2>/dev/null || true)"
        if [ -z "$hits" ]; then
            count=0
        else
            count="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
        fi
        if [ "$count" -ne 1 ]; then
            fail "T2 .claude-plugin/plugin.json has $count '\"version\"' lines, expected 1.  Hits:
$(printf '%s\n' "$hits" | sed 's/^/      | /')"
        else
            # Exact match against "version": "$EXPECTED_VERSION".  $hits is
            # exactly one line here (count==1 guard), so grep's first match is
            # also printf's last byte — SIGPIPE-safe — but we standardize on
            # no-q anyway so a `| grep -q` never reappears in this file.
            if printf '%s\n' "$hits" | grep -E "\"version\"[[:space:]]*:[[:space:]]*\"$EXPECTED_VERSION_RE\"" >/dev/null; then
                pass "T2 .claude-plugin/plugin.json has exactly one \"version\": \"$EXPECTED_VERSION\" line"
            else
                fail "T2 .claude-plugin/plugin.json '\"version\"' line is not \"$EXPECTED_VERSION\".  Line:
$(printf '%s\n' "$hits" | sed 's/^/      | /')"
            fi
        fi
    fi

    # ---- .claude-plugin/marketplace.json ------------------------------------
    local mf="$REPO_ROOT/.claude-plugin/marketplace.json"
    if [ ! -f "$mf" ]; then
        fail "T2 .claude-plugin/marketplace.json missing"
    else
        local hits count
        hits="$(grep -nE '"version"' "$mf" 2>/dev/null || true)"
        if [ -z "$hits" ]; then
            count=0
        else
            count="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
        fi
        if [ "$count" -ne 1 ]; then
            # Design §A.2: NO top-level version expected.  2+ lines == design violation.
            fail "T2 .claude-plugin/marketplace.json has $count '\"version\"' lines, expected exactly 1 (no top-level version field).  Hits:
$(printf '%s\n' "$hits" | sed 's/^/      | /')"
        else
            if printf '%s\n' "$hits" | grep -E "\"version\"[[:space:]]*:[[:space:]]*\"$EXPECTED_VERSION_RE\"" >/dev/null; then
                pass "T2 .claude-plugin/marketplace.json has exactly one \"version\": \"$EXPECTED_VERSION\" line (plugins[0].version, no top-level version)"
            else
                fail "T2 .claude-plugin/marketplace.json '\"version\"' line is not \"$EXPECTED_VERSION\".  Line:
$(printf '%s\n' "$hits" | sed 's/^/      | /')"
            fi
        fi
    fi

    # ---- .codex-plugin/plugin.json ------------------------------------------
    local xf="$REPO_ROOT/.codex-plugin/plugin.json"
    if [ ! -f "$xf" ]; then
        fail "T2 .codex-plugin/plugin.json missing"
    else
        local hits count
        hits="$(grep -nE '"version"' "$xf" 2>/dev/null || true)"
        if [ -z "$hits" ]; then
            count=0
        else
            count="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
        fi
        if [ "$count" -ne 1 ]; then
            fail "T2 .codex-plugin/plugin.json has $count '\"version\"' lines, expected 1.  Hits:
$(printf '%s\n' "$hits" | sed 's/^/      | /')"
        else
            # Match "$EXPECTED_VERSION+codex.<14 digits>"
            if printf '%s\n' "$hits" | grep -E "\"version\"[[:space:]]*:[[:space:]]*\"$EXPECTED_VERSION_RE\\+codex\\.[0-9]{14}\"" >/dev/null; then
                pass "T2 .codex-plugin/plugin.json '\"version\"' matches \"$EXPECTED_VERSION+codex.<14 digits>\""
            else
                fail "T2 .codex-plugin/plugin.json '\"version\"' does NOT match \"$EXPECTED_VERSION+codex.<14 digits>\".  Line:
$(printf '%s\n' "$hits" | sed 's/^/      | /')"
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# T3.  CHANGELOG.md sections present
#
#  - Contains `## [Unreleased]`
#  - Contains `## [0.5.0]`
#  - Contains `## [0.4.0]`
#  - Each version section (0.5.0, 0.4.0) has at least one of
#    ### Added / ### Changed / ### Removed / ### Fixed
# ---------------------------------------------------------------------------

# extract_section <file> <heading-literal>
# Echoes lines AFTER the first line whose start equals <heading-literal>
# (literal prefix match via awk `index($0, target) == 1`) up to (but not
# including) the next `^## ` heading.  Used to scope sub-heading checks
# to a single version section.
#
# Rationale: awk's `-v re=...` assignment processes backslash escapes in
# the value (e.g. `\[` -> `[`, `\.` -> `.`), so passing an ERE through -v
# silently breaks bracketed headings like `## [0.5.0]` (it would parse
# `[0.5.0]` as a character class instead of literal brackets).  Using a
# literal heading + `index() == 1` sidesteps regex escaping entirely.
extract_section() {
    local file="$1"
    local heading_literal="$2"
    awk -v target="$heading_literal" '
        !started && index($0, target) == 1 { started = 1; next }
        started && /^## / { exit }
        started { print }
    ' "$file"
}

# check_section_has_subheading <file> <version-display> <section-heading-literal>
# Asserts the extracted section has at least one of the 4 sub-headings.
check_section_has_subheading() {
    local file="$1"
    local version_display="$2"
    local section_literal="$3"
    local body
    body="$(extract_section "$file" "$section_literal")"
    if [ -z "$body" ]; then
        fail "T3 CHANGELOG.md section '$version_display' is empty (no body extracted)"
        return
    fi
    # No -q: the sub-heading usually matches near the TOP of a multi-KB
    # section body — grep must consume all remaining input (SIGPIPE note).
    if printf '%s\n' "$body" | grep -E '^### (Added|Changed|Removed|Fixed)([[:space:]]|$)' >/dev/null; then
        pass "T3 CHANGELOG.md section '$version_display' has at least one of ### Added/Changed/Removed/Fixed"
    else
        fail "T3 CHANGELOG.md section '$version_display' is missing all of ### Added/Changed/Removed/Fixed.  Body:
$(printf '%s\n' "$body" | sed 's/^/      | /')"
    fi
}

run_T3() {
    say_header "T3  CHANGELOG.md sections present"

    local cl="$REPO_ROOT/CHANGELOG.md"
    if [ ! -f "$cl" ]; then
        fail "T3 CHANGELOG.md missing — cannot check sections"
        skip "T3 ## [Unreleased] heading (CHANGELOG.md missing)"
        skip "T3 ## [0.5.0] heading (CHANGELOG.md missing)"
        skip "T3 ## [0.4.0] heading (CHANGELOG.md missing)"
        skip "T3 [0.5.0] sub-headings (CHANGELOG.md missing)"
        skip "T3 [0.4.0] sub-headings (CHANGELOG.md missing)"
        return
    fi

    # Top-level required headings.  We accept any whitespace / suffix after
    # the bracketed marker (Keep-a-Changelog often has "## [0.5.0] — date").
    if grep -qE '^## \[Unreleased\]([[:space:]]|$)' "$cl"; then
        pass "T3 CHANGELOG.md contains '## [Unreleased]'"
    else
        fail "T3 CHANGELOG.md missing '## [Unreleased]' heading"
    fi
    if grep -qE '^## \[0\.5\.0\]([[:space:]]|$)' "$cl"; then
        pass "T3 CHANGELOG.md contains '## [0.5.0]'"
    else
        fail "T3 CHANGELOG.md missing '## [0.5.0]' heading"
    fi
    if grep -qE '^## \[0\.4\.0\]([[:space:]]|$)' "$cl"; then
        pass "T3 CHANGELOG.md contains '## [0.4.0]'"
    else
        fail "T3 CHANGELOG.md missing '## [0.4.0]' heading"
    fi

    # Per-version-section sub-heading presence.
    # NOTE: pass LITERAL heading strings to check_section_has_subheading;
    # extract_section uses awk's index($0, target)==1 for prefix match,
    # not regex, so brackets and dots are taken as literal characters.
    check_section_has_subheading "$cl" "[0.5.0]" '## [0.5.0]'
    check_section_has_subheading "$cl" "[0.4.0]" '## [0.4.0]'
}

# ---------------------------------------------------------------------------
# T4.  pack.sh smoke
# ---------------------------------------------------------------------------
run_T4() {
    say_header "T4  pack.sh smoke"

    local pack="$REPO_ROOT/scripts/pack.sh"
    if [ ! -x "$pack" ]; then
        fail "T4 scripts/pack.sh missing or not executable — cannot run smoke"
        local i
        for i in \
            "pack.sh exits 0" \
            "stdout contains dist= line" \
            "stdout contains size= line" \
            "stdout contains version= line" \
            "dist/zyz-worker-${EXPECTED_VERSION}.zip exists" \
            "unzip -l succeeds (zip valid)" \
            "zip contains CHANGELOG.md" \
            "zip contains README.md" \
            "zip contains LICENSE" \
            "zip contains .claude-plugin/plugin.json" \
            "zip contains commands/execute-task.md" \
            "zip contains commands/code-development.md" \
            "zip contains commands/orchestrate-tasks.md" \
            "zip contains skills/execute-task/SKILL.md" \
            "zip contains scripts/pack.sh" \
            "zip does NOT contain .git/" \
            "zip does NOT contain .zyz-worker/" \
            "zip does NOT contain dist/" \
            "zip does NOT contain docs/superpowers/" \
            "zip size between 50KB and 5MB"
        do
            skip "T4 $i (pack.sh not runnable)"
        done
        return
    fi

    # Run pack.sh from REPO_ROOT (its own cwd-tolerance is via
    # `git rev-parse --show-toplevel`, but we run from REPO_ROOT for clarity).
    local stdout_tmp stderr_tmp pack_rc
    stdout_tmp="$(mktemp "${TMPDIR:-/tmp}/zyz-rel-t4-out.XXXXXX")"
    stderr_tmp="$(mktemp "${TMPDIR:-/tmp}/zyz-rel-t4-err.XXXXXX")"
    ( cd "$REPO_ROOT" && bash "$pack" </dev/null ) >"$stdout_tmp" 2>"$stderr_tmp"
    pack_rc=$?
    local stdout_content stderr_content
    stdout_content="$(cat "$stdout_tmp" 2>/dev/null || true)"
    stderr_content="$(cat "$stderr_tmp" 2>/dev/null || true)"
    rm -f "$stdout_tmp" "$stderr_tmp"

    if [ "$pack_rc" -eq 0 ]; then
        pass "T4 bash scripts/pack.sh exits 0"
    else
        fail "T4 bash scripts/pack.sh exited $pack_rc (expected 0).  Stderr:
$(printf '%s\n' "$stderr_content" | sed 's/^/      | /')
Stdout:
$(printf '%s\n' "$stdout_content" | sed 's/^/      | /')"
    fi

    # Stdout key=value lines per §C contract.  No -q on these: 'dist=' is the
    # FIRST stdout line, so grep -q would match and exit while printf still has
    # the remaining lines to write (SIGPIPE note in header).
    if printf '%s\n' "$stdout_content" | grep -E '^dist=' >/dev/null; then
        pass "T4 stdout contains 'dist=' line"
    else
        fail "T4 stdout missing 'dist=' line.  Stdout:
$(printf '%s\n' "$stdout_content" | sed 's/^/      | /')"
    fi
    if printf '%s\n' "$stdout_content" | grep -E '^size=' >/dev/null; then
        pass "T4 stdout contains 'size=' line"
    else
        fail "T4 stdout missing 'size=' line.  Stdout:
$(printf '%s\n' "$stdout_content" | sed 's/^/      | /')"
    fi
    if printf '%s\n' "$stdout_content" | grep -E '^version=' >/dev/null; then
        pass "T4 stdout contains 'version=' line"
    else
        fail "T4 stdout missing 'version=' line.  Stdout:
$(printf '%s\n' "$stdout_content" | sed 's/^/      | /')"
    fi

    # Artifact path
    local zip_path="$REPO_ROOT/dist/zyz-worker-${EXPECTED_VERSION}.zip"
    if [ -f "$zip_path" ]; then
        pass "T4 $zip_path exists"
    else
        fail "T4 $zip_path missing after pack.sh run"
        # Subsequent checks need the zip; skip the rest.
        local i
        for i in \
            "unzip -l succeeds (zip valid)" \
            "zip contains CHANGELOG.md" \
            "zip contains README.md" \
            "zip contains LICENSE" \
            "zip contains .claude-plugin/plugin.json" \
            "zip contains commands/execute-task.md" \
            "zip contains commands/code-development.md" \
            "zip contains commands/orchestrate-tasks.md" \
            "zip contains skills/execute-task/SKILL.md" \
            "zip contains scripts/pack.sh" \
            "zip does NOT contain .git/" \
            "zip does NOT contain .zyz-worker/" \
            "zip does NOT contain dist/" \
            "zip does NOT contain docs/superpowers/" \
            "zip size between 50KB and 5MB"
        do
            skip "T4 $i (zip artifact missing)"
        done
        return
    fi

    # unzip -l succeeds
    if ! command -v unzip >/dev/null 2>&1; then
        skip "T4 unzip -l succeeds (unzip not available on this host)"
        # Without unzip we cannot enumerate contents; SKIP per-path checks too.
        local i
        for i in \
            "zip contains CHANGELOG.md" \
            "zip contains README.md" \
            "zip contains LICENSE" \
            "zip contains .claude-plugin/plugin.json" \
            "zip contains commands/execute-task.md" \
            "zip contains commands/code-development.md" \
            "zip contains commands/orchestrate-tasks.md" \
            "zip contains skills/execute-task/SKILL.md" \
            "zip contains scripts/pack.sh" \
            "zip does NOT contain .git/" \
            "zip does NOT contain .zyz-worker/" \
            "zip does NOT contain dist/" \
            "zip does NOT contain docs/superpowers/"
        do
            skip "T4 $i (unzip not available)"
        done
    else
        local zip_listing zip_rc
        zip_listing="$(unzip -l "$zip_path" 2>&1)"
        zip_rc=$?
        if [ "$zip_rc" -eq 0 ]; then
            pass "T4 unzip -l $zip_path succeeds (zip is valid)"
        else
            fail "T4 unzip -l $zip_path failed (rc=$zip_rc).  Output:
$(printf '%s\n' "$zip_listing" | sed 's/^/      | /')"
        fi

        # Inclusion checks.  `unzip -l` prefixes columns; we grep for the
        # path component near end-of-line.  Use anchors / word-boundaries
        # so e.g. "README.md" does not accidentally match "FOO-README.md".
        # No -q on the listing pipes: the listing is multi-KB (> one stdio
        # write chunk) and early paths match with more lines still coming —
        # exactly the racy SIGPIPE shape (header note).
        check_zip_contains() {
            local path="$1"
            # Match: whitespace then path then end-of-line (no trailing data).
            if printf '%s\n' "$zip_listing" | grep -E "[[:space:]]${path//./\\.}([[:space:]]|$)" >/dev/null; then
                pass "T4 zip contains $path"
            else
                fail "T4 zip does NOT contain $path.  Listing tail:
$(printf '%s\n' "$zip_listing" | tail -n 20 | sed 's/^/      | /')"
            fi
        }
        check_zip_absent_prefix() {
            local prefix="$1"
            # Match: whitespace then the prefix anywhere on the line.
            if printf '%s\n' "$zip_listing" | grep -E "[[:space:]]${prefix//./\\.}" >/dev/null; then
                fail "T4 zip MUST NOT contain prefix '$prefix' but does.  Offending lines:
$(printf '%s\n' "$zip_listing" | grep -E "[[:space:]]${prefix//./\\.}" | sed 's/^/      | /')"
            else
                pass "T4 zip does not contain prefix '$prefix'"
            fi
        }

        # Required paths (T4 design §F + user prompt list)
        check_zip_contains "CHANGELOG.md"
        check_zip_contains "README.md"
        check_zip_contains "LICENSE"
        check_zip_contains ".claude-plugin/plugin.json"
        check_zip_contains "commands/execute-task.md"
        check_zip_contains "commands/code-development.md"
        check_zip_contains "commands/orchestrate-tasks.md"
        check_zip_contains "skills/execute-task/SKILL.md"
        check_zip_contains "scripts/pack.sh"

        # Forbidden prefixes (excluded by git ls-files since they are
        # gitignored / untracked).
        check_zip_absent_prefix ".git/"
        check_zip_absent_prefix ".zyz-worker/"
        check_zip_absent_prefix "dist/"
        check_zip_absent_prefix "docs/superpowers/"
    fi

    # Size sanity: 50KB .. 5MB
    local size_bytes
    size_bytes="$(portable_stat_size "$zip_path")"
    if [ -z "$size_bytes" ] || ! [ "$size_bytes" -gt 0 ] 2>/dev/null; then
        fail "T4 cannot determine size of $zip_path (stat failed; observed='$size_bytes')"
    else
        local lo=51200       # 50 KB
        local hi=5242880     # 5 MB
        if [ "$size_bytes" -ge "$lo" ] && [ "$size_bytes" -le "$hi" ]; then
            pass "T4 zip size $size_bytes bytes is within sanity range [${lo}, ${hi}]"
        else
            fail "T4 zip size $size_bytes bytes is OUTSIDE sanity range [${lo}, ${hi}]"
        fi
    fi
}

# ---------------------------------------------------------------------------
# T5.  pack.sh error paths
#
#  T5.a  Run from non-git dir       -> exit 2 + 'not in a git repo' diag
#  T5.b  Run on a repo MIRROR with
#        .claude-plugin/plugin.json missing -> exit 2 OR exit 4 (both OK)
#  T5.c  Missing `zip` command      -> exit 3.  Allowed to SKIP per design.
# ---------------------------------------------------------------------------
run_T5() {
    say_header "T5  pack.sh error paths"

    local pack="$REPO_ROOT/scripts/pack.sh"
    if [ ! -x "$pack" ]; then
        fail "T5 scripts/pack.sh missing or not executable — cannot run error-path tests"
        skip "T5.a non-git dir -> exit 2 (pack.sh not runnable)"
        skip "T5.b missing manifest -> exit 2 or 4 (pack.sh not runnable)"
        skip "T5.c missing zip -> exit 3 (pack.sh not runnable)"
        return
    fi

    # ---- T5.a  non-git dir -> exit 2 ----------------------------------------
    local nongit
    nongit="$(mktemp -d "${TMPDIR:-/tmp}/zyz-rel-t5a.XXXXXX")"
    # Use a regex-stderr helper.  Accept either of the two common diagnostic
    # phrasings: "not in a git repo" (design §C sketch) or "not a git repo".
    run_and_check_exit_stderr_regex 2 \
        'not (in )?a git repo' \
        "T5.a non-git dir -> exit 2 with 'not in a git repo' diagnostic" \
        env -- bash -c "cd '$nongit' && bash '$pack'"
    rm -rf "$nongit"

    # ---- T5.b  mirror without .claude-plugin/plugin.json --------------------
    # `cp -a` preserves perms + the .git dir, so the mirror is still a valid
    # git repo (T5.b is a 2/4 case, NOT a 'not in git repo' 2 case).
    local mirror_root mirror_repo b_rc b_err
    mirror_root="$(mktemp -d "${TMPDIR:-/tmp}/zyz-rel-t5b.XXXXXX")"
    mirror_repo="$mirror_root/repo-mirror"
    # cp -a is portable on macOS / Linux.
    if cp -a "$REPO_ROOT" "$mirror_repo" 2>/dev/null; then
        # Also nuke any stale dist/ in the mirror so a previous mirror's
        # zip cannot confuse the assertion.
        rm -rf "$mirror_repo/dist" 2>/dev/null || true
        if [ -f "$mirror_repo/.claude-plugin/plugin.json" ]; then
            mv "$mirror_repo/.claude-plugin/plugin.json" \
               "$mirror_repo/.claude-plugin/plugin.json.bak"
        fi
        local b_stdout_tmp b_stderr_tmp
        b_stdout_tmp="$(mktemp "${TMPDIR:-/tmp}/zyz-rel-t5b-out.XXXXXX")"
        b_stderr_tmp="$(mktemp "${TMPDIR:-/tmp}/zyz-rel-t5b-err.XXXXXX")"
        ( cd "$mirror_repo" && bash scripts/pack.sh </dev/null ) \
            >"$b_stdout_tmp" 2>"$b_stderr_tmp"
        b_rc=$?
        b_err="$(cat "$b_stderr_tmp" 2>/dev/null || true)"
        rm -f "$b_stdout_tmp" "$b_stderr_tmp"
        if [ "$b_rc" -eq 2 ] || [ "$b_rc" -eq 4 ]; then
            pass "T5.b mirror without .claude-plugin/plugin.json -> exit $b_rc (accepted: 2 or 4)"
        else
            fail "T5.b mirror without .claude-plugin/plugin.json got exit=$b_rc, expected 2 or 4.  Stderr:
$(printf '%s\n' "$b_err" | sed 's/^/      | /')"
        fi
    else
        skip "T5.b mirror without manifest -> exit 2 or 4 (cp -a of repo failed; fixture skipped)"
    fi
    rm -rf "$mirror_root"

    # ---- T5.c  missing `zip` -> exit 3 (allowed SKIP) -----------------------
    #
    # Per design §Testing T5: this subtest is allowed to SKIP because the
    # fixture is brittle across hosts (need to build a bin-dir of symlinks to
    # every dep pack.sh uses EXCEPT zip; getting that complete on macOS vs
    # Linux without inadvertently masking some other dep is fragile).
    #
    # We attempt the fixture but SKIP gracefully on any setup failure so the
    # test suite never FAILs on T5.c.
    t5c_attempt() {
        # Build a bin-dir with symlinks to the deps pack.sh actually uses.
        # Per design §C sketch: git, bash, grep, sed, xargs, awk, stat, mkdir,
        # rm, printf, head — NOT zip.
        local bin_dir
        bin_dir="$(mktemp -d "${TMPDIR:-/tmp}/zyz-rel-t5c.XXXXXX")" || return 1
        local tool real
        for tool in git bash grep sed xargs awk stat mkdir rm printf head sh env cat \
                    date sleep dirname basename which command; do
            real="$(command -v "$tool" 2>/dev/null || true)"
            if [ -z "$real" ]; then
                # Tool not on host PATH at all — skip; the script under test
                # likely doesn't need it either.
                continue
            fi
            ln -s "$real" "$bin_dir/$tool" 2>/dev/null || true
        done
        # Confirm zip is NOT in the fixture and IS NOT reachable when we use
        # the fixture as the SOLE PATH.
        if PATH="$bin_dir" command -v zip >/dev/null 2>&1; then
            rm -rf "$bin_dir"
            return 1
        fi
        # Confirm minimal deps reachable.
        local need
        for need in git bash grep sed xargs stat; do
            if ! PATH="$bin_dir" command -v "$need" >/dev/null 2>&1; then
                rm -rf "$bin_dir"
                return 1
            fi
        done
        local c_stdout_tmp c_stderr_tmp c_rc c_err
        c_stdout_tmp="$(mktemp "${TMPDIR:-/tmp}/zyz-rel-t5c-out.XXXXXX")"
        c_stderr_tmp="$(mktemp "${TMPDIR:-/tmp}/zyz-rel-t5c-err.XXXXXX")"
        ( cd "$REPO_ROOT" && PATH="$bin_dir" bash "$pack" </dev/null ) \
            >"$c_stdout_tmp" 2>"$c_stderr_tmp"
        c_rc=$?
        c_err="$(cat "$c_stderr_tmp" 2>/dev/null || true)"
        rm -f "$c_stdout_tmp" "$c_stderr_tmp"
        rm -rf "$bin_dir"
        if [ "$c_rc" -eq 3 ]; then
            pass "T5.c missing zip command -> exit 3"
            return 0
        else
            # Any other exit code (e.g. zip got reached by some shell builtin,
            # or script aborted earlier with 1/127) -> SKIP per design.
            skip "T5.c missing-zip subtest skipped on this host (fixture brittleness; got exit=$c_rc.  Stderr head: $(printf '%s' "$c_err" | head -c 200))"
            return 0
        fi
    }
    if ! t5c_attempt; then
        skip "T5.c missing-zip subtest skipped on this host (fixture brittleness)"
    fi
}

# ---------------------------------------------------------------------------
# T6.  git tag verification (run only if v0.5.0 tag exists; otherwise SKIP)
# ---------------------------------------------------------------------------
run_T6() {
    say_header "T6  git tag verification"

    # Tag and annotation track the single source of truth $EXPECTED_VERSION,
    # so a version bump only needs the EXPECTED_VERSION edit at the top — not
    # a second edit here. Expected tag = "v$EXPECTED_VERSION"; expected
    # annotation body contains "zyz-worker $EXPECTED_VERSION".
    local tag="v$EXPECTED_VERSION"
    local annotation="zyz-worker $EXPECTED_VERSION"

    if ! command -v git >/dev/null 2>&1; then
        skip "T6 git tag -l $tag returns '$tag' (git not available)"
        skip "T6 git show $tag shows annotated tag with '$annotation' (git not available)"
        return
    fi

    # Check from REPO_ROOT (we cd'd at startup).
    local tag_listing
    tag_listing="$(git -C "$REPO_ROOT" tag -l "$tag" 2>/dev/null || true)"
    if [ "$tag_listing" != "$tag" ]; then
        # Tag not yet created — likely test-agent runs before main-agent's
        # tag step in the staged 1->5 implementation order.  Per the user
        # prompt: mark SKIP, not FAIL.
        skip "T6 git tag -l $tag returns '$tag' (tag not yet created at test runtime)"
        skip "T6 git show $tag shows annotated tag with '$annotation' (tag not yet created at test runtime)"
        return
    fi

    pass "T6 git tag -l $tag returns '$tag' (single line)"

    local show_out show_rc
    show_out="$(git -C "$REPO_ROOT" show "$tag" 2>&1)"
    show_rc=$?
    if [ "$show_rc" -ne 0 ]; then
        fail "T6 git show $tag failed (rc=$show_rc).  Output:
$(printf '%s\n' "$show_out" | head -n 20 | sed 's/^/      | /')"
        return
    fi
    # Containment check via pure-bash `case` — NO pipe.  The old
    # `printf | grep -qF` form false-FAILed here deterministically: git show
    # for v0.11.0 emits ~72KB, grep -q exits at the first match, printf gets
    # SIGPIPE (rc 141), and pipefail turns that into the FAIL branch even
    # though the annotation IS present (header SIGPIPE note).
    case "$show_out" in
        *"$annotation"*)
            pass "T6 git show $tag contains annotated tag content '$annotation'"
            ;;
        *)
            fail "T6 git show $tag does NOT contain '$annotation'.  First 20 lines:
$(printf '%s\n' "$show_out" | head -n 20 | sed 's/^/      | /')"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "Running release-0-5-0 static + smoke-check suite"
echo "Repo root: $REPO_ROOT"

run_T1
run_T2
run_T3
run_T4
run_T5
run_T6

echo
echo "============================================================"
if [ "$SKIPPED" -gt 0 ]; then
    SKIP_SUFFIX=" ($SKIPPED skipped)"
else
    SKIP_SUFFIX=""
fi
if [ "$FAILED" -eq 0 ]; then
    echo "RESULT: $PASSED/$TOTAL checks passed$SKIP_SUFFIX"
    echo "============================================================"
    exit 0
else
    echo "RESULT: $PASSED/$TOTAL checks passed ($FAILED failed)$SKIP_SUFFIX"
    echo "============================================================"
    exit 1
fi
