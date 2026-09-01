#!/usr/bin/env bash
#
# Static + smoke-check suite for the clean-tmp skill.
#
# Implements T1-T6 from
#   .zyz-worker/tasks/clean-tmp-skill/design.md  ##  Testing Plan
# plus the 0.11.0 evolution extensions (T3/T5/T6 updates + new T7-T11) from
#   .zyz-worker/tasks/clean-tmp-skill-evolution/design.md  ##  Testing Plan
#
# Usage:
#   bash scripts/test-clean-tmp-skill.sh
#
# Behavior:
#   - Runs all eleven test groups to completion (does NOT bail on first failure).
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
#   - SIGPIPE discipline: under pipefail, `<producer> | grep -q` is unsafe
#     whenever the producer can still be writing after grep's first match —
#     grep -q exits immediately, the producer's next write hits a closed pipe,
#     SIGPIPE makes the pipeline rc 141, and the check takes the wrong branch
#     (false FAIL for positive checks; worse, false PASS for must-be-absent
#     checks).  Therefore NO `| grep -q` pipelines in this file: containment
#     checks on captured output use grep WITHOUT -q + >/dev/null (grep then
#     consumes all input, so the producer never gets SIGPIPE).  `grep -q`
#     directly ON A FILE is safe (no pipe) and stays.
#
# Self-scan note (design ## Important Details): this script itself contains the
# strings "0.9.0", "clean-tmp", "kill -0", "lsof", "ss -lxp", "TMPDIR",
# "rm -rf /tmp", "--auto", "docker image prune", "go clean -modcache",
# "quota -s", etc.  To avoid self-scan false positives EVERY grep below is
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
EXPECTED_VERSION="0.18.1"
# Regex-escaped form of EXPECTED_VERSION (dots escaped) for use inside `grep -E`
# patterns.  Derived so a version bump only requires editing EXPECTED_VERSION.
EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/\./\\./g')"

# The skill under test.
SKILL_REL="skills/clean-tmp/SKILL.md"
SKILL="$REPO_ROOT/$SKILL_REL"

# The two on-demand reference docs split out of SKILL.md (evolution design D1).
# T11 asserts their filesystem existence; T6 asserts they are in the zip.
REF_MACOS_REL="skills/clean-tmp/references/macos-tmpdir-trap.md"
REF_SOCKET_REL="skills/clean-tmp/references/socket-liveness.md"

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

    # No -q on the $head10 pipes: 'name:' matches on line 2 with 8 more lines
    # still coming from printf (header SIGPIPE note).

    # name: clean-tmp  (allow trailing whitespace only)
    if printf '%s\n' "$head10" | grep -E '^name: clean-tmp[[:space:]]*$' >/dev/null; then
        pass "T2 $SKILL_REL frontmatter has 'name: clean-tmp'"
    else
        fail "T2 $SKILL_REL frontmatter is missing 'name: clean-tmp' (first 10 lines):
$(printf '%s\n' "$head10" | sed 's/^/      | /')"
    fi

    # description: <non-empty>
    if printf '%s\n' "$head10" | grep -E '^description:[[:space:]]*[^[:space:]]' >/dev/null; then
        pass "T2 $SKILL_REL frontmatter has a non-empty 'description:' line"
    else
        fail "T2 $SKILL_REL frontmatter is missing a non-empty 'description:' line (first 10 lines):
$(printf '%s\n' "$head10" | sed 's/^/      | /')"
    fi

    # argument-hint MUST be absent (design F5).  No -q is load-bearing here:
    # with -q, a PRESENT argument-hint would match early, SIGPIPE printf, and
    # the rc-141 pipeline would take the else (pass) branch — masking the very
    # violation this check exists to catch.
    if printf '%s\n' "$head10" | grep -E '^argument-hint:' >/dev/null; then
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
    # $hits is exactly one line here (count==1 guard) so this is SIGPIPE-safe
    # either way, but we standardize on no-q (header SIGPIPE note).
    if printf '%s\n' "$hits" | grep -E "\"version\"[[:space:]]*:[[:space:]]*\"$value_re\"" >/dev/null; then
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
#     - has a `## [0.9.0]` heading (historical entry, kept as regression guard).
#     - has a `## [0.11.0]` heading (evolution design D8).  Both regexes
#       tolerate a ` — <date>` tail via `([[:space:]]|$)`.
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
        fail "T5 CHANGELOG.md missing — cannot check version headings"
        skip "T5 CHANGELOG.md contains '## [0.11.0]' heading (CHANGELOG.md missing)"
        return
    fi
    if grep -qE '^## \[0\.9\.0\]([[:space:]]|$)' "$cl"; then
        pass "T5 CHANGELOG.md contains '## [0.9.0]' heading"
    else
        fail "T5 CHANGELOG.md missing '## [0.9.0]' heading"
    fi
    # Evolution entry (design D8).  `([[:space:]]|$)` tolerates the house
    # `## [0.11.0] — <date>` em-dash date tail.
    if grep -qE '^## \[0\.11\.0\]([[:space:]]|$)' "$cl"; then
        pass "T5 CHANGELOG.md contains '## [0.11.0]' heading"
    else
        fail "T5 CHANGELOG.md missing '## [0.11.0]' heading"
    fi
}

# ---------------------------------------------------------------------------
# T6.  pack.sh smoke (design F2).
#
#   Runs `bash scripts/pack.sh`, asserts exit 0, asserts the versioned zip
#   exists, and (if `unzip` is available) asserts the zip listing contains
#   skills/clean-tmp/SKILL.md plus the two references/ docs (evolution design:
#   zip-content assertions belong to T6, filesystem existence to T11).  SKIPs
#   the unzip sub-checks when unzip is absent.
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
        skip "T6 zip contains $REF_MACOS_REL (pack.sh not runnable)"
        skip "T6 zip contains $REF_SOCKET_REL (pack.sh not runnable)"
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
        skip "T6 zip contains $REF_MACOS_REL (zip artifact missing)"
        skip "T6 zip contains $REF_SOCKET_REL (zip artifact missing)"
        return
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        skip "T6 zip contains $SKILL_REL (unzip not available on this host)"
        skip "T6 zip contains $REF_MACOS_REL (unzip not available on this host)"
        skip "T6 zip contains $REF_SOCKET_REL (unzip not available on this host)"
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
    local rel
    for rel in "$SKILL_REL" "$REF_MACOS_REL" "$REF_SOCKET_REL"; do
        # No -q: SKILL.md sits mid-listing with many lines still coming from
        # printf after the match (header SIGPIPE note).
        if printf '%s\n' "$zip_listing" | grep -F "$rel" >/dev/null; then
            pass "T6 zip contains $rel"
        else
            fail "T6 zip does NOT contain $rel (was it 'git add'-ed before pack?).  Listing tail:
$(printf '%s\n' "$zip_listing" | tail -n 20 | sed 's/^/      | /')"
        fi
    done
}

# ---------------------------------------------------------------------------
# T7.  Dual mode + auto-mode DELETE criteria (evolution design D2/D3, AC#1/2).
#
#   All checks target the named SKILL.md only.  Markers:
#     - --auto / 交互模式 / 自动模式 / 事后报告   (mode split + post-hoc report)
#     - five-condition criteria: -mmin -2880 (48h probe), 48 小时 (threshold
#       prose), lsof (open-handle probe), id -un (owner condition),
#       local-review- (one-shot-artifact allowlist literal)
#     - -maxdepth 0 AND -print -quit — BOTH must be present: the file probe
#       uses `-maxdepth 0` while the directory probe drops it and short-circuits
#       with `-print -quit` (design F3/Round-2 F1: `| head -n 1` would swallow
#       find's exit code and defeat fail->keep)
#     - noatime  (why mtime, not atime)
#     - fail->keep direction marker (see inline comment)
#     - trigger words quota + docker in the frontmatter description or the
#       「何时加载」 section (AC#6)
# ---------------------------------------------------------------------------
run_T7() {
    say_header "T7  Dual mode + auto-mode DELETE criteria"

    if [ ! -f "$SKILL" ]; then
        fail "T7 cannot lint body — $SKILL_REL does not exist"
        local i
        for i in \
            "--auto marker" \
            "交互模式 marker" \
            "自动模式 marker" \
            "事后报告 marker" \
            "-mmin -2880 marker" \
            "48 小时 marker" \
            "lsof five-condition marker" \
            "id -un owner marker" \
            "local-review- allowlist marker" \
            "-maxdepth 0 file-probe marker" \
            "-print -quit dir-probe marker" \
            "noatime marker" \
            "fail->keep direction marker" \
            "trigger word quota" \
            "trigger word docker"
        do
            skip "T7 $i ($SKILL_REL missing)"
        done
        return
    fi

    # Mode split + post-hoc report.
    assert_literal_in_file "$SKILL" "--auto"   "T7 body has '--auto' (auto-mode switch)"
    assert_literal_in_file "$SKILL" "交互模式" "T7 body has '交互模式'"
    assert_literal_in_file "$SKILL" "自动模式" "T7 body has '自动模式'"
    assert_literal_in_file "$SKILL" "事后报告" "T7 body has '事后报告' (post-hoc report)"

    # Five-condition DELETE criteria markers (design D2: owner / >48h /
    # unprotected / no open handle / on the one-shot allowlist).
    assert_literal_in_file "$SKILL" "-mmin -2880"   "T7 body has '-mmin -2880' (48h find probe)"
    assert_literal_in_file "$SKILL" "48 小时"        "T7 body has '48 小时' (threshold prose)"
    assert_literal_in_file "$SKILL" "lsof"          "T7 body has 'lsof' (open-handle condition)"
    assert_literal_in_file "$SKILL" "id -un"        "T7 body has 'id -un' (owner condition)"
    assert_literal_in_file "$SKILL" "local-review-" "T7 body has 'local-review-' (allowlist literal)"

    # File probe vs directory probe are DISTINCT (design D3): the file probe
    # keeps `-maxdepth 0`; the directory probe drops it (top-level dir mtime
    # misses deep writes) and short-circuits via find's own `-print -quit` so
    # find's exit code stays checkable.  Both literals must be present.
    assert_literal_in_file "$SKILL" "-maxdepth 0"  "T7 body has '-maxdepth 0' (file mtime probe)"
    assert_literal_in_file "$SKILL" "-print -quit" "T7 body has '-print -quit' (recursive dir mtime probe)"

    # Why mtime and not atime.
    assert_literal_in_file "$SKILL" "noatime" "T7 body has 'noatime' (mtime-not-atime rationale)"

    # Fail->keep direction marker (design D2/D3, AC#2): a failed probe must
    # classify KEEP, never "old enough to delete".  Both accepted literals
    # come verbatim from the design text: 'probe-failed' is the keep-reason
    # tag in the D3 probe snippets; 'fail→keep' is D2's direction phrase.
    if grep -qF -- "probe-failed" "$SKILL" || grep -qF -- "fail→keep" "$SKILL"; then
        pass "T7 body states fail->keep probe direction ('probe-failed' or 'fail→keep')"
    else
        fail "T7 body missing fail->keep direction marker (need 'probe-failed' or 'fail→keep' in $SKILL_REL)"
    fi

    # Trigger words (design D7, AC#6): quota + docker must appear in the
    # frontmatter description or the 「何时加载」 section — NOT merely anywhere
    # in the body ('docker' trivially appears in the Docker cleanup section,
    # so a whole-file grep would be vacuous).  Frontmatter is approximated by
    # the first 15 lines (house frontmatter is well under 10 lines); the
    # 何时加载 section runs from its `## ` heading to the next `## ` heading.
    local trigger_region
    trigger_region="$(head -n 15 "$SKILL"; awk '/^## /{f=0} /^##.*何时加载/{f=1} f' "$SKILL")"
    local w
    for w in quota docker; do
        # No -q: both words match inside the multi-line frontmatter head while
        # printf still has the 何时加载 lines to write (header SIGPIPE note).
        if printf '%s\n' "$trigger_region" | grep -iF -- "$w" >/dev/null; then
            pass "T7 trigger word '$w' present in frontmatter description or 何时加载 section"
        else
            fail "T7 trigger word '$w' missing from frontmatter description and 何时加载 section of $SKILL_REL"
        fi
    done
}

# ---------------------------------------------------------------------------
# T8.  Docker cleanup surface (evolution design D4, AC#3).
#
#   Anchored to SKILL.md.  Markers: pre-probe, image/volume prune commands,
#   daemon-unreachable whole-block skip, rootless-quota motivation path.
# ---------------------------------------------------------------------------
run_T8() {
    say_header "T8  Docker cleanup surface"

    if [ ! -f "$SKILL" ]; then
        fail "T8 cannot lint body — $SKILL_REL does not exist"
        local i
        for i in \
            "docker system df marker" \
            "docker image prune -a -f marker" \
            "docker volume prune -f marker" \
            "整块跳过 marker" \
            "~/.local/share/docker marker"
        do
            skip "T8 $i ($SKILL_REL missing)"
        done
        return
    fi

    assert_literal_in_file "$SKILL" "docker system df"        "T8 body has 'docker system df' (pre-probe)"
    assert_literal_in_file "$SKILL" "docker image prune -a -f" "T8 body has 'docker image prune -a -f'"
    assert_literal_in_file "$SKILL" "docker volume prune -f"   "T8 body has 'docker volume prune -f'"
    # Daemon unreachable => skip the whole block, not a failure (fail->keep).
    assert_literal_in_file "$SKILL" "整块跳过"                 "T8 body has '整块跳过' (daemon-unreachable skip)"
    # Rootless docker data counts against the user's uid quota — the incident
    # motivation for this cleanup surface.
    assert_literal_in_file "$SKILL" "~/.local/share/docker"    "T8 body has '~/.local/share/docker' (rootless quota motivation)"
}

# ---------------------------------------------------------------------------
# T9.  Compiler / package-manager cache surface (evolution design D5, AC#4).
#
#   Anchored to SKILL.md.  Markers: the tiered table's commands, the modcache
#   keep semantic ON ITS OWN LINE, tool-queried cache paths, CLI existence
#   probes, and the 1G default threshold.
# ---------------------------------------------------------------------------
run_T9() {
    say_header "T9  Compiler/package cache surface"

    if [ ! -f "$SKILL" ]; then
        fail "T9 cannot lint body — $SKILL_REL does not exist"
        local i
        for i in \
            "go clean -cache marker" \
            "go clean -modcache marker" \
            "go clean -modcache line 不删 marker" \
            "go env GOCACHE marker" \
            "pnpm store prune marker" \
            "uv cache clean marker" \
            "npm cache clean marker" \
            "playwright marker" \
            "command -v marker" \
            "1G threshold marker"
        do
            skip "T9 $i ($SKILL_REL missing)"
        done
        return
    fi

    assert_literal_in_file "$SKILL" "go clean -cache" "T9 body has 'go clean -cache' (build cache, over-threshold delete)"

    # `go clean -modcache` must be present AND its own line must carry the
    # 「不删」 semantic (design D5: module cache rebuild = re-download every
    # dependency, so auto mode never deletes it).  Checking the SAME line
    # guards against the command and the keep rule drifting apart.
    local mod_lines
    mod_lines="$(grep -F -- "go clean -modcache" "$SKILL" 2>/dev/null || true)"
    if [ -z "$mod_lines" ]; then
        fail "T9 body missing 'go clean -modcache' in $SKILL_REL"
        fail "T9 'go clean -modcache' line 不删 marker (command itself missing)"
    else
        pass "T9 body has 'go clean -modcache'"
        # No -q: $mod_lines may hold several lines with the marker on an early
        # one (header SIGPIPE note).
        if printf '%s\n' "$mod_lines" | grep -F -- "不删" >/dev/null; then
            pass "T9 'go clean -modcache' line carries '不删' (module cache keep semantic)"
        else
            fail "T9 'go clean -modcache' line(s) missing '不删' marker in $SKILL_REL:
$(printf '%s\n' "$mod_lines" | sed 's/^/      | /')"
        fi
    fi

    # Cache paths are queried from the tool itself, never hardcoded (design F2:
    # macOS default cache dirs differ from Linux).
    assert_literal_in_file "$SKILL" "go env GOCACHE"  "T9 body has 'go env GOCACHE' (tool-queried cache path)"
    assert_literal_in_file "$SKILL" "pnpm store prune" "T9 body has 'pnpm store prune'"
    assert_literal_in_file "$SKILL" "uv cache clean"   "T9 body has 'uv cache clean'"
    assert_literal_in_file "$SKILL" "npm cache clean"  "T9 body has 'npm cache clean' (interactive-only)"
    assert_literal_in_file "$SKILL" "playwright"       "T9 body has 'playwright' (needs-your-call browser caches)"
    assert_literal_in_file "$SKILL" "command -v"       "T9 body has 'command -v' (CLI existence probe)"
    assert_literal_in_file "$SKILL" "1G"               "T9 body has '1G' (default --go-cache-threshold)"
}

# ---------------------------------------------------------------------------
# T10.  Protect-list + multi-user guardrail hardening (evolution design D6,
#       AC#5).  Anchored to SKILL.md.
# ---------------------------------------------------------------------------
run_T10() {
    say_header "T10  Protect-list + guardrail hardening"

    if [ ! -f "$SKILL" ]; then
        fail "T10 cannot lint body — $SKILL_REL does not exist"
        local i
        for i in \
            "vscode-* protect marker" \
            "*.keep protect marker" \
            "不带属主过滤 lesson marker" \
            "quota -s marker"
        do
            skip "T10 $i ($SKILL_REL missing)"
        done
        return
    fi

    assert_literal_in_file "$SKILL" "vscode-*" "T10 protect-list has 'vscode-*'"
    assert_literal_in_file "$SKILL" "*.keep"   "T10 protect-list has '*.keep'"
    # Field lesson: never size your own usage with an owner-unfiltered du.
    assert_literal_in_file "$SKILL" "不带属主过滤" "T10 body has '不带属主过滤' (du owner-filter lesson)"
    # Quota perspective: uid quota counts files filesystem-wide.
    assert_literal_in_file "$SKILL" "quota -s" "T10 body has 'quota -s' (quota perspective)"
}

# ---------------------------------------------------------------------------
# T11.  references/ split + doc lockstep (evolution design D1/D8, AC#6/8).
#
#   Filesystem existence of the two reference docs lives here; their presence
#   inside the packed zip is T6's job (design F9: no overlapping duties).
# ---------------------------------------------------------------------------
run_T11() {
    say_header "T11  references/ split + doc lockstep"

    # (a) The two reference docs exist and are non-empty.
    local rel
    for rel in "$REF_MACOS_REL" "$REF_SOCKET_REL"; do
        if [ -s "$REPO_ROOT/$rel" ]; then
            pass "T11 $rel exists and is non-empty"
        else
            fail "T11 $rel missing or empty"
        fi
    done

    # (b) SKILL.md explicitly points at both relative paths (on-demand load).
    if [ ! -f "$SKILL" ]; then
        fail "T11 cannot check reference links — $SKILL_REL does not exist"
        skip "T11 $SKILL_REL links references/macos-tmpdir-trap.md ($SKILL_REL missing)"
        skip "T11 $SKILL_REL links references/socket-liveness.md ($SKILL_REL missing)"
    else
        assert_literal_in_file "$SKILL" "references/macos-tmpdir-trap.md" "T11 $SKILL_REL links references/macos-tmpdir-trap.md"
        assert_literal_in_file "$SKILL" "references/socket-liveness.md"   "T11 $SKILL_REL links references/socket-liveness.md"
    fi

    # (c) README repo-structure tree shows references/ inside the clean-tmp
    # subtree.  Anchored: find the tree line ending in 'clean-tmp/' (same
    # anchor T5 uses), then require a 'references/' line within the next 6
    # lines — a plain whole-file grep for 'references/' would match other
    # skills' subtrees.
    local readme="$REPO_ROOT/README.md"
    if [ ! -f "$readme" ]; then
        fail "T11 README.md missing — cannot check tree references/ entry"
    elif awk '/clean-tmp\/[[:space:]]*$/ { w = NR + 6 } w && NR <= w && /references\// { found = 1 } END { exit(found ? 0 : 1) }' "$readme"; then
        pass "T11 README.md tree has 'references/' within the clean-tmp/ subtree"
    else
        fail "T11 README.md tree is missing a 'references/' entry within 6 lines after the 'clean-tmp/' line"
    fi

    # (d) project-structure.md no longer names clean-tmp as the
    # only-a-SKILL.md lightweight example (design D8: git-worktree stays as
    # that example; clean-tmp becomes the SKILL.md + references/ example).
    # The current L87 keeps BOTH forms in one paragraph line:
    #   "...ships only a `SKILL.md` (...), such as `git-worktree`. A skill may
    #    also pair its `SKILL.md` with a `references/` directory ..., such as
    #    ... `clean-tmp` (`SKILL.md` + `references/`)."
    # so a bare "line must not contain clean-tmp" check would false-fail.
    # Accurate assertion: on the line carrying the only-SKILL.md phrasing,
    # (d1) git-worktree is the example that follows that phrasing, and
    # (d2) clean-tmp is either absent or preceded by `references/` on the same
    # line (i.e. cited as the references form, never the only-SKILL.md form —
    # the pre-evolution text had no `references/` on this line at all, so it
    # fails d2 as required).
    local ps="$REPO_ROOT/docs/conventions/project-structure.md"
    if [ ! -f "$ps" ]; then
        fail "T11 docs/conventions/project-structure.md missing"
        skip "T11 project-structure.md only-SKILL.md example is git-worktree (file missing)"
        skip "T11 project-structure.md clean-tmp not the only-SKILL.md example (file missing)"
    else
        local ps_line
        ps_line="$(grep -E 'only a .?SKILL\.md|只带 .?SKILL\.md' "$ps" 2>/dev/null | head -n 1)"
        if [ -z "$ps_line" ]; then
            fail "T11 project-structure.md has no only-SKILL.md lightweight-skill example line"
            skip "T11 project-structure.md clean-tmp not the only-SKILL.md example (example line missing)"
        else
            # $ps_line is a single line (head -n 1) so these pipes are
            # SIGPIPE-safe either way; standardized on no-q (header note).
            # d1: git-worktree follows the only-SKILL.md phrasing.
            if printf '%s\n' "$ps_line" | grep -E '(only a .?SKILL\.md|只带 .?SKILL\.md).*git-worktree' >/dev/null; then
                pass "T11 project-structure.md only-SKILL.md example is git-worktree"
            else
                fail "T11 project-structure.md only-SKILL.md example line does not name git-worktree:
$(printf '%s\n' "$ps_line" | sed 's/^/      | /')"
            fi
            # d2: clean-tmp absent, or preceded by references/ on the line.
            if ! printf '%s\n' "$ps_line" | grep -F -- "clean-tmp" >/dev/null; then
                pass "T11 project-structure.md clean-tmp absent from the only-SKILL.md example line"
            elif printf '%s\n' "$ps_line" | grep -E 'references/.*clean-tmp' >/dev/null; then
                pass "T11 project-structure.md cites clean-tmp only as the SKILL.md + references/ form"
            else
                fail "T11 project-structure.md still cites clean-tmp as the only-SKILL.md example:
$(printf '%s\n' "$ps_line" | sed 's/^/      | /')"
            fi
        fi
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
run_T7
run_T8
run_T9
run_T10
run_T11

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
