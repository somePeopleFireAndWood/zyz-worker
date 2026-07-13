#!/usr/bin/env bash
#
# Static + smoke-check suite for the clean-tmp-skill task.
#
# Implements T1-T6 from
#   .zyz-worker/tasks/clean-tmp-skill/design.md  ##  Testing Plan
#
# Usage:
#   bash scripts/test-clean-tmp-skill.sh
#
# Behavior:
#   - Runs all six test groups to completion (does NOT bail on first failure).
#   - Prints PASS / FAIL / SKIP per check with offending paths on FAIL.
#   - Prints a final summary line:
#       RESULT: <passed>/<total> checks passed  [(<skipped> skipped)]
#   - Exits 0 on success, 1 if any check failed.  SKIP does not count as fail.
#
# Compatibility:
#   - macOS bash 3.2 and Linux bash 4+; no bash 4 features used (no associative
#     arrays, no ${var,,}).
#   - Uses `set -u` and `set -o pipefail` only — never `set -e` so the operator
#     sees the full picture across all checks.
#
# Self-scan note (design ## Important Details): this script itself contains the
# strings "0.9.0", "clean-tmp", "kill -0", "lsof", "ss -lxp", "TMPDIR",
# "rm -rf /tmp", etc.  To avoid self-scan false positives EVERY grep below is
# anchored to a specific named file path (the manifest / skill / doc under
# test) — there is deliberately NO repo-wide `git ls-files | xargs grep`.

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

# Single source of truth for the expected release version (design §5).  A
# future bump is one edit here.
EXPECTED_VERSION="0.9.2"
# Regex-escaped form of EXPECTED_VERSION (dots escaped) for use inside `grep -E`
# patterns.  Derived so a version bump only requires editing EXPECTED_VERSION.
EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/\./\\./g')"

# The skill under test.
SKILL_REL="skills/clean-tmp/SKILL.md"
SKILL="$REPO_ROOT/$SKILL_REL"

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

# assert_literal_in_file <file> <literal> <label>
# PASS if <literal> occurs as a plain substring anywhere in <file> (grep -F),
# FAIL otherwise.  Anchored to the named file — never a repo-wide scan.
assert_literal_in_file() {
    local file="$1"
    local literal="$2"
    local label="$3"
    if grep -qF -- "$literal" "$file" 2>/dev/null; then
        pass "$label (found literal '$literal' in $file)"
    else
        fail "$label (missing literal '$literal' in $file)"
    fi
}

# ---------------------------------------------------------------------------
# T1.  File existence
#
#   skills/clean-tmp/SKILL.md exists.
# ---------------------------------------------------------------------------
run_T1() {
    say_header "T1  File existence"

    if [ -f "$SKILL" ]; then
        pass "T1 $SKILL_REL exists"
    else
        fail "T1 $SKILL_REL missing"
    fi
}

# ---------------------------------------------------------------------------
# T2.  Frontmatter
#
#   First ~10 lines contain `name: clean-tmp` and a `description:` line.
#   Per design F5 (accepted), `argument-hint` is intentionally DROPPED — we
#   assert it is ABSENT so a careless edit cannot re-introduce the
#   slash-command-only field.
# ---------------------------------------------------------------------------
run_T2() {
    say_header "T2  Frontmatter"

    if [ ! -f "$SKILL" ]; then
        fail "T2 cannot check frontmatter — $SKILL_REL does not exist"
        skip "T2 name: clean-tmp ($SKILL_REL missing)"
        skip "T2 description: present ($SKILL_REL missing)"
        skip "T2 argument-hint absent ($SKILL_REL missing)"
        return
    fi

    local head10
    head10="$(head -n 10 "$SKILL")"

    # name: clean-tmp  (allow trailing whitespace only)
    if printf '%s\n' "$head10" | grep -qE '^name: clean-tmp[[:space:]]*$'; then
        pass "T2 $SKILL_REL frontmatter has 'name: clean-tmp'"
    else
        fail "T2 $SKILL_REL frontmatter is missing 'name: clean-tmp' (first 10 lines):
$(printf '%s\n' "$head10" | sed 's/^/      | /')"
    fi

    # description: <non-empty>
    if printf '%s\n' "$head10" | grep -qE '^description:[[:space:]]*[^[:space:]]'; then
        pass "T2 $SKILL_REL frontmatter has a non-empty 'description:' line"
    else
        fail "T2 $SKILL_REL frontmatter is missing a non-empty 'description:' line (first 10 lines):
$(printf '%s\n' "$head10" | sed 's/^/      | /')"
    fi

    # argument-hint MUST be absent (design F5).
    if printf '%s\n' "$head10" | grep -qE '^argument-hint:'; then
        fail "T2 $SKILL_REL frontmatter must NOT declare 'argument-hint' (design F5 dropped it):
$(printf '%s\n' "$head10" | grep -nE '^argument-hint:' | sed 's/^/      | /')"
    else
        pass "T2 $SKILL_REL frontmatter has no 'argument-hint' (correctly dropped per F5)"
    fi
}

# ---------------------------------------------------------------------------
# T3.  Version consistency == $EXPECTED_VERSION across the 3 manifests +
#      the release-test single source of truth.
#
#   Every grep is anchored to a specific named file (NO repo-wide scan) to
#   avoid self-scan false positives — this script itself contains "0.9.0".
#
#   - .claude-plugin/plugin.json     : exactly one '"version"' line == VERSION
#   - .claude-plugin/marketplace.json: exactly one '"version"' line == VERSION
#         (plugins[0].version; no top-level version field)
#   - .codex-plugin/plugin.json      : exactly one '"version"' line matching
#         "VERSION+codex.<14 digits>"
#   - scripts/test-release-0-5-0.sh  : contains EXPECTED_VERSION="VERSION"
# ---------------------------------------------------------------------------

# check_single_version_line <file> <value-regex> <label>
# Asserts the file has exactly one '"version"' line and that it matches the
# given ERE value pattern.
check_single_version_line() {
    local file="$1"
    local value_re="$2"
    local label="$3"
    if [ ! -f "$file" ]; then
        fail "$label ($file missing)"
        return
    fi
    local hits count
    hits="$(grep -nE '"version"' "$file" 2>/dev/null || true)"
    if [ -z "$hits" ]; then
        count=0
    else
        count="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
    fi
    if [ "$count" -ne 1 ]; then
        fail "$label ($file has $count '\"version\"' lines, expected 1).  Hits:
$(printf '%s\n' "$hits" | sed 's/^/      | /')"
        return
    fi
    if printf '%s\n' "$hits" | grep -qE "\"version\"[[:space:]]*:[[:space:]]*\"$value_re\""; then
        pass "$label"
    else
        fail "$label — '\"version\"' line did not match.  Line:
$(printf '%s\n' "$hits" | sed 's/^/      | /')"
    fi
}

run_T3() {
    say_header "T3  Version consistency == $EXPECTED_VERSION"

    check_single_version_line \
        "$REPO_ROOT/.claude-plugin/plugin.json" \
        "$EXPECTED_VERSION_RE" \
        "T3 .claude-plugin/plugin.json has exactly one \"version\": \"$EXPECTED_VERSION\""

    check_single_version_line \
        "$REPO_ROOT/.claude-plugin/marketplace.json" \
        "$EXPECTED_VERSION_RE" \
        "T3 .claude-plugin/marketplace.json has exactly one \"version\": \"$EXPECTED_VERSION\" (plugins[0].version, no top-level version)"

    check_single_version_line \
        "$REPO_ROOT/.codex-plugin/plugin.json" \
        "$EXPECTED_VERSION_RE\\+codex\\.[0-9]{14}" \
        "T3 .codex-plugin/plugin.json \"version\" matches \"$EXPECTED_VERSION+codex.<14 digits>\""

    # Release-test single source of truth.  Anchored to the named file.
    local rel="$REPO_ROOT/scripts/test-release-0-5-0.sh"
    if [ ! -f "$rel" ]; then
        fail "T3 scripts/test-release-0-5-0.sh missing"
    elif grep -qF "EXPECTED_VERSION=\"$EXPECTED_VERSION\"" "$rel"; then
        pass "T3 scripts/test-release-0-5-0.sh has EXPECTED_VERSION=\"$EXPECTED_VERSION\""
    else
        fail "T3 scripts/test-release-0-5-0.sh missing EXPECTED_VERSION=\"$EXPECTED_VERSION\".  version lines:
$(grep -nE 'EXPECTED_VERSION=' "$rel" | sed 's/^/      | /')"
    fi
}

# ---------------------------------------------------------------------------
# T4.  Cross-platform + safety lint on the skill body.
#
#   Asserts the guardrail markers are present so a later careless edit cannot
#   silently strip the cross-platform / safety semantics (design Goals 2+3,
#   AC#1).  All checks target the named SKILL.md only — no self-scan risk even
#   though this script also contains these strings.
#
#   Markers:
#     - kill -0          (POSIX liveness check, replaces /proc/$pid)
#     - lsof             (socket/dir holder probe, both platforms)
#     - ss -lxp          (Linux-preferred unix-socket->pid branch)
#     - TMPDIR           (macOS per-user temp root, $TMPDIR)
#     - rm -rf /tmp      (the `rm -rf /tmp/*` prohibition)
#     - claude / tmux / mcp / ssh  (the four default keep-list categories)
#   Plus a combined root-relative-keep check: body mentions BOTH TMPDIR and
#   tmux (the F1 correction: tmux socket lives under $TMPDIR on macOS, so the
#   keep-list must be relative to each enumerated root).
# ---------------------------------------------------------------------------
run_T4() {
    say_header "T4  Cross-platform + safety lint on skill body"

    if [ ! -f "$SKILL" ]; then
        fail "T4 cannot lint body — $SKILL_REL does not exist"
        local i
        for i in \
            "kill -0 marker" \
            "lsof marker" \
            "ss -lxp marker" \
            "TMPDIR marker" \
            "rm -rf /tmp prohibition" \
            "fail->keep safety marker" \
            "keep-list: claude" \
            "keep-list: tmux" \
            "keep-list: mcp" \
            "keep-list: ssh" \
            "root-relative keep (TMPDIR + tmux)"
        do
            skip "T4 $i ($SKILL_REL missing)"
        done
        return
    fi

    # Cross-platform command markers.
    assert_literal_in_file "$SKILL" "kill -0" "T4 body has 'kill -0' (POSIX liveness check)"
    assert_literal_in_file "$SKILL" "lsof"    "T4 body has 'lsof' (socket/dir holder probe)"
    assert_literal_in_file "$SKILL" "ss -lxp" "T4 body has 'ss -lxp' (Linux unix-socket branch)"
    assert_literal_in_file "$SKILL" "TMPDIR"  "T4 body mentions 'TMPDIR' (macOS per-user temp root)"

    # Safety prohibition.
    assert_literal_in_file "$SKILL" "rm -rf /tmp" "T4 body has 'rm -rf /tmp' prohibition"

    # Fail->keep safety rule (design §6 T4, AC#1): when the socket holder is
    # undetermined the skill MUST default to KEEP and never silently classify
    # STALE and delete.  '持有者无法确定' is the load-bearing marker for that rule.
    assert_literal_in_file "$SKILL" "持有者无法确定" "T4 body has '持有者无法确定' fail->keep safety marker"

    # Default keep-list categories.
    assert_literal_in_file "$SKILL" "claude" "T4 keep-list mentions 'claude'"
    assert_literal_in_file "$SKILL" "tmux"   "T4 keep-list mentions 'tmux'"
    assert_literal_in_file "$SKILL" "mcp"    "T4 keep-list mentions 'mcp'"
    assert_literal_in_file "$SKILL" "ssh"    "T4 keep-list mentions 'ssh'"

    # Combined root-relative keep semantics (design F1): TMPDIR + tmux both
    # present is the load-bearing correction (tmux socket under $TMPDIR on
    # macOS must be protected too).
    if grep -qF -- "TMPDIR" "$SKILL" && grep -qF -- "tmux" "$SKILL"; then
        pass "T4 body has root-relative keep-list markers (both 'TMPDIR' and 'tmux' present)"
    else
        fail "T4 body missing root-relative keep-list markers (need BOTH 'TMPDIR' and 'tmux' in $SKILL_REL)"
    fi
}

# ---------------------------------------------------------------------------
# T5.  Doc wiring (lockstep).
#
#   README.md (anchored):
#     - bullet list references the literal `skills/clean-tmp/SKILL.md`
#     - repo-structure ASCII tree has a `clean-tmp/` dir entry (line ending in
#       clean-tmp/) — design F4: the tree is a SECOND enumeration that would
#       go stale if only the bullet were updated.
#     - count of `clean-tmp` occurrences >= 2 confirms BOTH enumerations exist.
#   CHANGELOG.md (anchored):
#     - has a `## [0.9.0]` heading.
# ---------------------------------------------------------------------------
run_T5() {
    say_header "T5  Doc wiring (README + CHANGELOG)"

    # ---- README.md ----------------------------------------------------------
    local readme="$REPO_ROOT/README.md"
    if [ ! -f "$readme" ]; then
        fail "T5 README.md missing — cannot check doc wiring"
        skip "T5 README bullet -> skills/clean-tmp/SKILL.md (README.md missing)"
        skip "T5 README structure tree has clean-tmp/ entry (README.md missing)"
        skip "T5 README has >= 2 'clean-tmp' occurrences (README.md missing)"
    else
        # (a) bullet list reference (design §4a, AC#3).
        if grep -qF "skills/clean-tmp/SKILL.md" "$readme"; then
            pass "T5 README.md references 'skills/clean-tmp/SKILL.md' (current-status bullet)"
        else
            fail "T5 README.md is missing 'skills/clean-tmp/SKILL.md' bullet reference"
        fi

        # (b) repo-structure ASCII tree dir entry (design §4a, F4).  The tree
        # dir line ends in 'clean-tmp/'; the bullet ends in 'SKILL.md', so this
        # ERE (clean-tmp/ at end of line, allowing trailing whitespace) matches
        # the tree entry specifically, not the bullet.
        if grep -qE 'clean-tmp/[[:space:]]*$' "$readme"; then
            pass "T5 README.md repo-structure tree has a 'clean-tmp/' dir entry"
        else
            fail "T5 README.md repo-structure tree is missing a 'clean-tmp/' dir entry (line ending in clean-tmp/)"
        fi

        # (c) count sanity: both enumerations => >= 2 occurrences of clean-tmp.
        local cnt
        cnt="$(grep -oF "clean-tmp" "$readme" 2>/dev/null | wc -l | tr -d ' ')"
        if [ "${cnt:-0}" -ge 2 ]; then
            pass "T5 README.md has >= 2 'clean-tmp' occurrences (both bullet + tree wired), found $cnt"
        else
            fail "T5 README.md has only ${cnt:-0} 'clean-tmp' occurrence(s), expected >= 2 (bullet + tree)"
        fi
    fi

    # ---- CHANGELOG.md -------------------------------------------------------
    local cl="$REPO_ROOT/CHANGELOG.md"
    if [ ! -f "$cl" ]; then
        fail "T5 CHANGELOG.md missing — cannot check version heading"
    elif grep -qE '^## \[0\.9\.0\]([[:space:]]|$)' "$cl"; then
        pass "T5 CHANGELOG.md contains '## [0.9.0]' heading"
    else
        fail "T5 CHANGELOG.md missing '## [0.9.0]' heading"
    fi
}

# ---------------------------------------------------------------------------
# T6.  pack.sh smoke (design F2).
#
#   Runs `bash scripts/pack.sh`, asserts exit 0, asserts the versioned zip
#   exists, and (if `unzip` is available) asserts the zip listing contains
#   skills/clean-tmp/SKILL.md.  SKIPs the unzip sub-check when unzip is absent.
#
#   IMPORTANT CAVEAT: pack.sh packs `git ls-files` (the git index), so this
#   test only passes once the new skill has been `git add`-ed.  The main agent
#   stages files (design Implementation Plan step 5) BEFORE running the tests;
#   this test does NOT itself stage anything, and this agent does NOT run it.
# ---------------------------------------------------------------------------
run_T6() {
    say_header "T6  pack.sh smoke"

    local pack="$REPO_ROOT/scripts/pack.sh"
    if [ ! -x "$pack" ]; then
        if [ -e "$pack" ]; then
            fail "T6 scripts/pack.sh exists but is NOT executable — cannot run smoke"
        else
            fail "T6 scripts/pack.sh missing — cannot run smoke"
        fi
        skip "T6 bash scripts/pack.sh exits 0 (pack.sh not runnable)"
        skip "T6 dist/zyz-worker-${EXPECTED_VERSION}.zip exists (pack.sh not runnable)"
        skip "T6 zip contains $SKILL_REL (pack.sh not runnable)"
        return
    fi

    local stdout_tmp stderr_tmp pack_rc
    stdout_tmp="$(mktemp "${TMPDIR:-/tmp}/zyz-clean-t6-out.XXXXXX")"
    stderr_tmp="$(mktemp "${TMPDIR:-/tmp}/zyz-clean-t6-err.XXXXXX")"
    ( cd "$REPO_ROOT" && bash "$pack" </dev/null ) >"$stdout_tmp" 2>"$stderr_tmp"
    pack_rc=$?
    local stderr_content
    stderr_content="$(cat "$stderr_tmp" 2>/dev/null || true)"
    rm -f "$stdout_tmp" "$stderr_tmp"

    if [ "$pack_rc" -eq 0 ]; then
        pass "T6 bash scripts/pack.sh exits 0"
    else
        fail "T6 bash scripts/pack.sh exited $pack_rc (expected 0).  Stderr:
$(printf '%s\n' "$stderr_content" | sed 's/^/      | /')"
    fi

    local zip_path="$REPO_ROOT/dist/zyz-worker-${EXPECTED_VERSION}.zip"
    if [ -f "$zip_path" ]; then
        pass "T6 $zip_path exists"
    else
        fail "T6 $zip_path missing after pack.sh run"
        skip "T6 zip contains $SKILL_REL (zip artifact missing)"
        return
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        skip "T6 zip contains $SKILL_REL (unzip not available on this host)"
        return
    fi

    local zip_listing zip_rc
    zip_listing="$(unzip -l "$zip_path" 2>&1)"
    zip_rc=$?
    if [ "$zip_rc" -ne 0 ]; then
        fail "T6 unzip -l $zip_path failed (rc=$zip_rc).  Output:
$(printf '%s\n' "$zip_listing" | sed 's/^/      | /')"
        return
    fi
    if printf '%s\n' "$zip_listing" | grep -qF "$SKILL_REL"; then
        pass "T6 zip contains $SKILL_REL"
    else
        fail "T6 zip does NOT contain $SKILL_REL (was the new skill 'git add'-ed before pack?).  Listing tail:
$(printf '%s\n' "$zip_listing" | tail -n 20 | sed 's/^/      | /')"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "Running clean-tmp-skill static + smoke-check suite"
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
