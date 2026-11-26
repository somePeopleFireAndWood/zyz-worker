#!/usr/bin/env bash
#
# test-review-round.sh — the execute-task tier mechanics (design §10.3–§10.5,
# §10.7 items 1, 2, 9):
#   * hooks/scripts/review-round.sh (+ review_round.py): open / start / result /
#     grant / check / close / tier / status, the per-tier caps, the strict-tier
#     convergence-check gate, mode and cross-harness, forced full rounds,
#     closing and reopening, per-point tiers, tasks without a Tier
#     (fail open), validation, atomic writes that never touch other content,
#     parallel writers sharing expect.sh's lock;
#   * hooks/scripts/review-gate.sh: the PreToolUse gate on review-agent
#     dispatches (marker present and equal to the latest started round);
#   * hooks/scripts/dispatch-scope-guard.sh (L5): a verified mode=incremental
#     marker passes, everything else keeps the old behaviour;
#   * hooks/hooks.json registration and hooks/README.md contract.
# The cross-review.sh side (--point/--round skip, fingerprint excluding the
# task dir) is in scripts/test-cross-review.sh.
#
# WHAT THIS SUITE DOES NOT PROVE:
#  * That the host delivers the PreToolUse deny for an Agent dispatch to the
#    model (platform behaviour, the same contract L5 already relies on).
#  * That the main agent asks the user before `grant` or `tier --by user` —
#    the script cannot tell who decided; the prompts own that rule.
#  * That a dispatch outside the review-agent type (a general-purpose agent
#    asked to "review") is a review — the gate only sees the subagent type.
#
# Mutation record (2026-11-26, each mutant applied to an out-of-tree copy of
# hooks/ + scripts/ and run against this suite; every one turns a check red):
#  M1  review_round.py decide(): drop the cap test (`n > cap` -> `False`)
#  M2  review_round.py decide(): a grant authorizes every later round
#      (`(point, n) in grants` -> any grant for the point)
#  M3  review_round.py decide(): strict check window one round too wide
#      (`range(n - 3, n)` -> `range(n - 4, n)`: a round-3 check would count
#      for round 7)
#  M4  review_round.py decide(): ignore an escalate outcome
#  M5  review_round.py decide(): skip the needs-result rule
#  M6  review_round.py cross_harness(): impl/aggregate yes on every round
#  M7  review_round.py cmd_tier(): allow a downgrade without --by user
#  M8  review_round.py check_marker(): accept any started round of a point
#  M9  review_round.py check_marker(): ignore the round's recorded mode
#  M10 review_round.py read_tier(): read the Tier inside HTML comments too
#  M11 review-gate.sh: drop the review-agent target filter
#  M12 review-gate.sh: ignore ZYZ_REVIEW_GATE_DISABLE
#  M13 lib.sh zyz_review_incremental_ok: accept the bare `mode=incremental`
#      text without asking review_round.py
#  M14 dispatch-scope-guard.sh: let the incremental exemption cover every role
#  M15 review_round.py edit(): drop the lock (parallel writers lose rows;
#      a race: red on both runs so far — 5 and 4 of 8 rows survived — but
#      not guaranteed on every run)
#  M16 review_round.py cmd_gate(): treat a task without a Tier as tiered
#  M20 review_round.py decide(): forget that a point is closed
#  M21 review_round.py cmd_close(): passed with blocking left
#  M22 review_round.py cmd_close(): residual/split without --by user
#  M23 review_round.py effective(): ignore the point's own tier
#  M24 review_round.py cmd_open(): a point tier below the task tier
#  M25 review_round.py read_state(): no new set of records after a close
#  M26 review_round.py rewrite(): drop mode=full when the result is written
#  M29 review_round.py cmd_gate(): skip the dispatch Tier-line check
#  M30 review_round.py _match(): compare against the task tier, not the
#      point's effective tier
#  M31 review_round.py DISPATCH_TIER_RE: accept `Tier:` anywhere (the quoted
#      `- Tier:` status row then passes)
#  M32 review_round.py cmd_gate(): drop the invalid-value message (first
#      survived — the mismatch check still denied; a check on the message
#      was added)
# The cross-review.sh mutants (M17–M19, M27, M28) are recorded in
# test-cross-review.sh.
#
# Usage:  bash scripts/test-review-round.sh   (exit 0 iff every check passed)

set -u
# Never reach the user's real IM (~/.zyz-worker/notify.json).
ZYZ_TEST_NO_NOTIFY="/nonexistent/zyz-worker-test/notify.json"
export ZYZ_NOTIFY_CONFIG="$ZYZ_TEST_NO_NOTIFY"
unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
unset ZYZ_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CLAUDE_PID ZYZ_TASK_DIR
unset ZYZ_HOOKS_DISABLE ZYZ_REVIEW_GATE_DISABLE ZYZ_SCOPE_GUARD_DISABLE ZYZ_CROSS_REVIEW

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
H="$ROOT/hooks/scripts"
RR="$H/review-round.sh"
GATE="$H/review-gate.sh"
L5="$H/dispatch-scope-guard.sh"

TOTAL=0; PASSED=0; FAILED=0
pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); echo "PASS  $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); echo "FAIL  $1${2:+ — $2}"; }
has() { case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" "missing: $2 | got: $(printf '%s' "$1" | head -c 400)" ;; esac; }
lacks() { case "$1" in *"$2"*) fail "$3" "unexpected: $2" ;; *) pass "$3" ;; esac; }
rc_is() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "rc=$1 want $2"; fi; }

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP  all — python3 unavailable"; echo "RESULT: 0/0 checks passed (all skipped)"; exit 0
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/zyz-review-round-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
PROJ="$SANDBOX/proj"
T="$PROJ/.zyz-worker/tasks/t1"
mkdir -p "$T"

# mk_status <task-dir> <tier-line|""> — a status.md shaped like the template:
# the row format documented inside a comment, prose, then the next section.
mk_status() {
    mkdir -p "$1"
    {
        printf '# 任务状态\n\n## 元数据\n\n- Task: %s\n- Current Phase: implementation\n' "$(basename "$1")"
        [ -z "$2" ] || printf '%s\n' "$2"
        printf '\n## 评审收口\n\n'
        printf '<!-- 行格式：\n- Review: point=example; stage=impl; kind=main; round=7; started=1700000000; blocking=-; behavior=-\n- Tier: fast\n-->\n'
        printf '（每个评审点的轮次由 review-round.sh 写入。）\n\n## 下一步\n\n- 继续\n'
    } > "$1/status.md"
    rm -rf "$1/log" "$1/runtime"
}
rr() { bash "$RR" --task "$T" "$@"; }
sha() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
# run_rounds <point> <k>: k × (start + result --blocking 1); prints the last start rc.
run_rounds() {
    local i r=0
    for i in $(seq 1 "$2"); do
        rr start "$1" >/dev/null 2>&1; r=$?
        [ "$r" -eq 0 ] || { echo "$r"; return; }
        rr result "$1" --blocking 1 >/dev/null 2>&1
    done
    echo "$r"
}

# ---------------------------------------------------------------------------
# A — CLI basics and validation
# ---------------------------------------------------------------------------
mk_status "$T" "- Tier: standard"
out="$(bash "$RR" 2>&1)"; rc=$?
rc_is "$rc" 2 "A1 no command -> usage, exit 2"
has "$out" "Usage:" "A1 usage text printed"
out="$( (cd "$SANDBOX" && bash "$RR" status) 2>&1)"; rc=$?
rc_is "$rc" 2 "A2 no task pointer -> exit 2"
has "$out" "task-pointer.sh arm" "A2 says how to arm"
printf 't1\n' > "$PROJ/.zyz-worker/current-task"
out="$( (cd "$PROJ" && bash "$RR" open impl-main --stage impl) 2>&1)"; rc=$?
rc_is "$rc" 0 "A3 default task = this session's pointer"
grep -q '^- Review: point=impl-main; stage=impl; kind=main; round=0; started=[0-9]*; blocking=-; behavior=-$' "$T/status.md" \
    && pass "A3 open writes a round=0 row in the §10.4 format" || fail "A3 open row format" "$(grep 'point=impl-main' "$T/status.md")"
for bad in "open Bad_Point --stage impl" "open x --stage build" "open x --stage impl --kind side" "open x" "open -x --stage impl" \
           "start nope" "result impl-main --blocking 1" "grant impl-main" "check impl-main --outcome later --reason r" \
           "tier quick --reason r" "tier fast" "frobnicate" "start impl-main extra"; do
    # shellcheck disable=SC2086
    rr $bad >/dev/null 2>&1; rc=$?
    rc_is "$rc" 2 "A4 invalid input exits 2: $bad"
done
out="$(rr start nope 2>&1)"
has "$out" "open nope --stage" "A4 start on an unopened point says to open it"
out="$(rr open impl-main --stage impl 2>&1)"; rc=$?
rc_is "$rc" 0 "A5 re-open with the same stage/kind is idempotent"
[ "$(grep -c 'point=impl-main' "$T/status.md")" -eq 1 ] && pass "A5 no duplicate row" || fail "A5 no duplicate row"
rr open impl-main --stage design >/dev/null 2>&1; rc_is "$?" 2 "A5 re-open with another stage -> exit 2"
rr start impl-main >/dev/null 2>&1
for bad in "--blocking x" "--blocking 2 --behavior 3" "--blocking -1" "--behavior 1"; do
    # shellcheck disable=SC2086
    rr result impl-main $bad >/dev/null 2>&1; rc_is "$?" 2 "A6 result rejects: $bad"
done
out="$(rr start impl-main 2>&1)"; rc=$?
rc_is "$rc" 3 "A7 next start before the last round's result -> exit 3"
has "$out" "result impl-main --blocking" "A7 says to record the result first"
rr result impl-main --blocking 2 --behavior 1 >/dev/null
grep -q 'point=impl-main; stage=impl; kind=main; round=1; started=[0-9]*; blocking=2; behavior=1$' "$T/status.md" \
    && pass "A8 result fills blocking/behavior in place" || fail "A8 result in place"
rr result impl-main --blocking 3 >/dev/null
grep -q 'round=1; started=[0-9]*; blocking=3; behavior=-$' "$T/status.md" && pass "A8 result can be corrected" || fail "A8 result correction"
out="$(rr result impl-main --blocking 0)"
has "$out" "close impl-main --outcome passed" "A8 zero blocking points at close --outcome passed"

# ---------------------------------------------------------------------------
# B — caps per tier, grants, strict convergence checks
# ---------------------------------------------------------------------------
cap_case() { # <tier> <stage> <cap>
    local tier="$1" stage="$2" cap="$3" p="p-$2" before after out rc
    mk_status "$T" "- Tier: $tier"
    rr open "$p" --stage "$stage" >/dev/null
    if [ "$cap" -gt 0 ]; then
        rc="$(run_rounds "$p" "$cap")"
        rc_is "$rc" 0 "B $tier/$stage: rounds 1..$cap allowed"
    fi
    before="$(sha "$T/status.md")"
    out="$(rr start "$p" 2>&1)"; rc=$?
    rc_is "$rc" 3 "B $tier/$stage: round $((cap+1)) refused (exit 3)"
    [ "$before" = "$(sha "$T/status.md")" ] && pass "B $tier/$stage: a refusal writes nothing" || fail "B $tier/$stage: refusal wrote"
    has "$out" "grant $p --reason" "B $tier/$stage: refusal names the grant command"
    if [ "$cap" -eq 0 ]; then
        has "$out" "快速档不派设计评审" "B $tier/$stage: cap 0 explains the fast tier has no design review"
    else
        has "$out" "三选一" "B $tier/$stage: refusal hands the user the three options"
    fi
    rr grant "$p" --reason "用户批准再开一轮" >/dev/null
    out="$(rr start "$p" 2>&1)"; rc=$?
    rc_is "$rc" 0 "B $tier/$stage: a grant allows round $((cap+1))"
    rr result "$p" --blocking 1 >/dev/null
    rr start "$p" >/dev/null 2>&1; rc=$?
    rc_is "$rc" 3 "B $tier/$stage: the grant covered one round only"
    out="$(rr grant "$p" --reason again)"
    rr grant "$p" --reason again-twice >/dev/null
    [ "$(grep -c "Review-Grant: point=$p; round=$((cap+2));" "$T/status.md")" -eq 1 ] \
        && pass "B $tier/$stage: granting the same round twice adds one row" || fail "B $tier/$stage: duplicate grant rows"
}
cap_case fast design 0
cap_case fast impl 2
cap_case fast aggregate 1
cap_case standard design 2
cap_case standard impl 3
cap_case standard aggregate 3

mk_status "$T" "- Tier: strict"
rr open design-main --stage design >/dev/null
rc="$(run_rounds design-main 3)"; rc_is "$rc" 0 "B strict: rounds 1..3 need no check"
out="$(rr start design-main 2>&1)"; rc=$?
rc_is "$rc" 3 "B strict: round 4 without a convergence check refused"
has "$out" "check design-main --outcome" "B strict: refusal names the check command"
rr check design-main --outcome continue --reason "仍在收敛" >/dev/null
grep -q '^- Review-Check: point=design-main; round=3; outcome=continue; at=[0-9]*; reason=仍在收敛$' "$T/status.md" \
    && pass "B strict: check row in the §10.4 format, at the latest round" || fail "B strict: check row format"
rc="$(run_rounds design-main 3)"; rc_is "$rc" 0 "B strict: after the check, rounds 4..6 run"
rr start design-main >/dev/null 2>&1; rc_is "$?" 3 "B strict: round 7 needs a new check (the round-3 one does not count)"
rr check design-main --outcome class-fix --reason "类级修复" >/dev/null
rc="$(run_rounds design-main 3)"; rc_is "$rc" 0 "B strict: class-fix lets rounds 7..9 run"
rr check design-main --outcome escalate --reason "交用户" >/dev/null
out="$(rr start design-main 2>&1)"; rc=$?
rc_is "$rc" 3 "B strict: an escalate check holds round 10 for the user"
has "$out" "escalate" "B strict: refusal says why"
rr grant design-main --reason "用户决定继续" >/dev/null
rr start design-main >/dev/null 2>&1; rc_is "$?" 0 "B strict: the user's grant releases round 10"
# A check made early inside the window still counts.
mk_status "$T" "- Tier: strict"
rr open impl-a --stage impl --kind aux >/dev/null
run_rounds impl-a 2 >/dev/null
rr check impl-a --outcome reorder --reason early >/dev/null
rc="$(run_rounds impl-a 2)"; rc_is "$rc" 0 "B strict: a check at round 2 covers round 4 (window 1..3)"

# ---------------------------------------------------------------------------
# C — mode and cross-harness
# ---------------------------------------------------------------------------
startline() { rr start "$1" 2>&1; rr result "$1" --blocking 1 >/dev/null 2>&1; }
mk_status "$T" "- Tier: standard"
for p in d:design i:impl a:aggregate; do rr open "${p%%:*}" --stage "${p#*:}" >/dev/null; done
[ "$(startline d)" = "round=1 mode=full cross-harness=yes" ] && pass "C standard design r1: full, cross-harness" || fail "C standard design r1"
[ "$(startline d)" = "round=2 mode=incremental cross-harness=yes" ] && pass "C standard design r2: incremental, cross-harness stays" || fail "C standard design r2"
[ "$(startline i)" = "round=1 mode=full cross-harness=yes" ] && pass "C impl r1: full, cross-harness" || fail "C impl r1"
[ "$(startline i)" = "round=2 mode=incremental cross-harness=no" ] && pass "C impl r2: incremental, no cross-harness" || fail "C impl r2"
[ "$(startline a)" = "round=1 mode=full cross-harness=yes" ] && pass "C aggregate r1: cross-harness" || fail "C aggregate r1"
[ "$(startline a)" = "round=2 mode=incremental cross-harness=no" ] && pass "C aggregate r2: no cross-harness" || fail "C aggregate r2"
mk_status "$T" "- Tier: strict"
rr open d --stage design >/dev/null; startline d >/dev/null; startline d >/dev/null
[ "$(startline d)" = "round=3 mode=incremental cross-harness=yes" ] && pass "C strict design r3: cross-harness" || fail "C strict design r3"
mk_status "$T" "- Tier: fast"
rr open d --stage design >/dev/null; rr grant d --reason "用户要设计评审" >/dev/null
[ "$(startline d)" = "round=1 mode=full cross-harness=no" ] && pass "C fast design (granted): no cross-harness" || fail "C fast design granted"
rr open i --stage impl >/dev/null
[ "$(ZYZ_CROSS_REVIEW=off bash "$RR" --task "$T" start i 2>&1)" = "round=1 mode=full cross-harness=no" ] \
    && pass "C ZYZ_CROSS_REVIEW=off -> cross-harness=no" || fail "C ZYZ_CROSS_REVIEW=off"

# ---------------------------------------------------------------------------
# D — tasks without a Tier: no cap, recorded as usual (fail open)
# ---------------------------------------------------------------------------
for variant in "" "- Tier:" "- Tier: fast|standard|strict" "- Tier: quick"; do
    mk_status "$T" "$variant"
    rr open i --stage impl >/dev/null
    rc="$(run_rounds i 7)"
    rc_is "$rc" 0 "D no valid Tier ('${variant:-absent}'): 7 impl rounds, no cap, no check"
    [ "$(grep -c '^- Review: point=i;' "$T/status.md")" -eq 8 ] && pass "D ('${variant:-absent}'): every round recorded" || fail "D rows recorded"
done
# The `- Tier: fast` inside the template comment is not the tier.
mk_status "$T" ""
out="$(rr status)"
has "$out" "Tier: none" "D a Tier line inside an HTML comment is ignored"
lacks "$out" "example" "D a Review row inside an HTML comment is not a review point"
lacks "$out" "INVALID" "D ... nor reported as invalid"

# ---------------------------------------------------------------------------
# E — tier
# ---------------------------------------------------------------------------
mk_status "$T" ""
out="$(rr tier standard --reason "首次定档")"; rc=$?
rc_is "$rc" 0 "E set the first tier"
awk '/^- Current Phase:/{getline n; print n; exit}' "$T/status.md" | grep -qx -- '- Tier: standard' \
    && pass "E Tier inserted right under Current Phase" || fail "E Tier placement" "$(sed -n 1,12p "$T/status.md")"
[ "$(grep -c '^- Tier: standard$' "$T/status.md")" -eq 1 ] && [ "$(grep -c '^- Tier: fast$' "$T/status.md")" -eq 1 ] \
    && pass "E one Tier line written, the commented example untouched" || fail "E Tier line count"
grep -q -- '-\{0,1\} - -> standard; by=agent; reason=首次定档$' "$T/log/tier.md" && pass "E log/tier.md entry" || fail "E log entry" "$(cat "$T/log/tier.md" 2>/dev/null)"
rr tier standard --reason same >/dev/null
[ "$(grep -c ' -> ' "$T/log/tier.md")" -eq 1 ] && pass "E same tier: no change, no log entry" || fail "E same tier logged"
rr tier strict --reason "涉及鉴权" >/dev/null; rc_is "$?" 0 "E the agent may upgrade"
grep -qx -- '- Tier: strict' "$T/status.md" && pass "E Tier replaced in place" || fail "E Tier replaced"
before="$(sha "$T/status.md")"
out="$(rr tier fast --reason "想快点")"; rc=$?
rc_is "$rc" 3 "E downgrade without --by user refused (exit 3)"
has "$out" "--by user" "E refusal names --by user"
[ "$before" = "$(sha "$T/status.md")" ] && pass "E refused downgrade writes nothing" || fail "E refused downgrade wrote"
rr tier fast --by user --reason "用户：这个走快速" >/dev/null; rc_is "$?" 0 "E downgrade with --by user"
grep -q 'strict -> fast; by=user; reason=用户：这个走快速$' "$T/log/tier.md" && pass "E downgrade logged with by=user" || fail "E downgrade log"
[ "$(grep -c ' -> ' "$T/log/tier.md")" -eq 3 ] && pass "E log appends (3 changes)" || fail "E log count"
printf '# s\n\n## 元数据\n\n- Task: x\n' > "$T/status.md"
rr tier fast --reason r >/dev/null 2>&1; rc_is "$?" 2 "E no Current Phase line -> exit 2"

# ---------------------------------------------------------------------------
# F — status
# ---------------------------------------------------------------------------
mk_status "$T" "- Tier: standard"
rr open impl-main --stage impl >/dev/null
run_rounds impl-main 3 >/dev/null
out="$(rr status)"
has "$out" "Tier: standard" "F status shows the tier"
has "$out" "impl-main stage=impl kind=main tier=standard round=3 blocking=1 behavior=- history=1→1→1 cap=3 closed=no next=4 mode=incremental cross-harness=no gate=needs-grant" "F status line"
has "$out" "三选一" "F status explains a blocked next round"
out="$(rr status impl-main)"; rc_is "$?" 0 "F status <point>"
rr status nope >/dev/null 2>&1; rc_is "$?" 2 "F status <unknown point> -> exit 2"

# ---------------------------------------------------------------------------
# G — robustness: bad rows, layout, CRLF, parallel writers
# ---------------------------------------------------------------------------
mk_status "$T" "- Tier: standard"
python3 - "$T/status.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("（每个评审点的轮次由 review-round.sh 写入。）\n",
              "（每个评审点的轮次由 review-round.sh 写入。）\n"
              "- Review: point=bad; stage=bogus; kind=main; round=1; started=1700000000; blocking=-; behavior=-\n"
              "- Review: point=ok; stage=impl; kind=main; round=0; started=1700000000; blocking=-; behavior=-\n"
              "- Review: point=ok; stage=impl; kind=main; round=0; started=1700000001; blocking=-; behavior=-\n"
              "- Review-Grant: point=ok; round=1; at=1700000000\n")
open(p, "w", encoding="utf-8").write(s)
PY
out="$(rr status)"
has "$out" "INVALID  - Review: point=bad; stage=bogus" "G a malformed row is reported"
has "$out" "duplicate round" "G a duplicate round row is reported"
has "$out" "Review-Grant: point=ok; round=1; at=1700000000  <- fields must be" "G a grant without a reason is reported"
has "$out" "ok stage=impl" "G the valid point still parses"
rr start ok >/dev/null; rc_is "$?" 0 "G writes go on next to bad rows"
grep -qx -- '- Review: point=bad; stage=bogus; kind=main; round=1; started=1700000000; blocking=-; behavior=-' "$T/status.md" \
    && pass "G the bad row is kept byte-for-byte" || fail "G bad row rewritten"
# Every original line survives, in order, and the new row sits inside the
# section (before `## 下一步`), not inside the comment.
python3 - "$T/status.md" <<'PY' && pass "G only rows added, inside the section" || fail "G layout"
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
i_sec, i_next = lines.index("## 评审收口"), lines.index("## 下一步")
new = [i for i, l in enumerate(lines) if l.startswith("- Review: point=ok; stage=impl; kind=main; round=1;")]
end_comment = lines.index("-->")
assert len(new) == 1 and end_comment < new[0] < i_next and i_sec < new[0], (new, end_comment, i_next)
assert lines[-3:] == ["## 下一步", "", "- 继续"] or lines[-4:-1] == ["## 下一步", "", "- 继续"], lines[-4:]
PY
# No section at all -> created at the end.
printf '# s\n\n## 元数据\n\n- Current Phase: implementation\n- Tier: fast\n' > "$T/status.md"
rr open impl-main --stage impl >/dev/null
python3 - "$T/status.md" <<'PY' && pass "G a missing section is created at the end" || fail "G section creation"
import sys
s = open(sys.argv[1], encoding="utf-8").read()
assert s.startswith("# s\n\n## 元数据\n\n- Current Phase: implementation\n- Tier: fast\n"), s
assert "\n## 评审收口\n\n- Review: point=impl-main; stage=impl; kind=main; round=0;" in s, s
PY
# Two sections -> refuse to write.
printf '\n## 评审收口\n\n' >> "$T/status.md"
before="$(sha "$T/status.md")"
rr open other --stage impl >/dev/null 2>&1; rc_is "$?" 2 "G two '## 评审收口' sections -> exit 2"
[ "$before" = "$(sha "$T/status.md")" ] && pass "G ... and nothing written" || fail "G wrote despite two sections"
# CRLF stays CRLF.
mk_status "$T" "- Tier: standard"
python3 -c 'import sys;p=sys.argv[1];s=open(p,newline="").read();open(p,"w",newline="").write(s.replace("\n","\r\n"))' "$T/status.md"
rr open impl-main --stage impl >/dev/null && rr start impl-main >/dev/null && rr tier strict --reason up >/dev/null
python3 - "$T/status.md" <<'PY' && pass "G CRLF newline style preserved" || fail "G CRLF"
import sys
raw = open(sys.argv[1], "rb").read()
assert b"\r\n" in raw and raw.count(b"\n") == raw.count(b"\r\n"), raw[:200]
assert b"round=1; started=" in raw and b"- Tier: strict\r\n" in raw
PY
# Parallel writers: review-round.sh and expect.sh share runtime/expect.lock.
mk_status "$T" "- Tier: standard"
pids=""
for i in 1 2 3 4 5 6 7 8; do rr open "p$i" --stage impl >/dev/null 2>&1 & pids="$pids $!"; done
for i in 1 2 3 4; do bash "$H/expect.sh" --task "$T" set "k$i" wait --at +2h --reason "r$i" >/dev/null 2>&1 & pids="$pids $!"; done
# shellcheck disable=SC2086
wait $pids
[ "$(grep -c '^- Review: point=p[1-8]; ' "$T/status.md")" -eq 8 ] && pass "G 8 parallel opens: no row lost" || fail "G parallel opens" "$(grep -c '^- Review: point=p' "$T/status.md")"
[ "$(grep -c '^- Expect: key=k[1-4]; ' "$T/status.md")" -eq 4 ] && pass "G parallel expect.sh writes: no row lost" || fail "G parallel expect rows"

# ---------------------------------------------------------------------------
# H — review-gate.sh
# ---------------------------------------------------------------------------
# payload <subagent-type> <prompt> [field] — JSON-escaped hook input.
payload() {
    python3 -c 'import json,sys
print(json.dumps({"cwd":sys.argv[1],"session_id":sys.argv[4],"tool_name":"Agent",
                  "tool_input":{sys.argv[5]:sys.argv[2],"prompt":sys.argv[3]}}))' \
        "$PROJ" "$1" "$2" "${GATE_SID:-}" "${3:-subagent_type}" 2>/dev/null
}
# gate <type> <prompt> [field]: the prompt gets a `Tier: $GATE_TIER` line of
# its own (as main-agent.md writes it) unless GATE_TIER is set to "".
GATE_TIER=standard
gate() {
    local p="$2"
    [ -z "$GATE_TIER" ] || p="$p
Tier: $GATE_TIER"
    payload "$1" "$p" "${3:-subagent_type}" | bash "$GATE"
}
denied() { printf '%s' "$1" | grep -q '"permissionDecision": *"deny"'; }
mk_status "$T" "- Tier: standard"
rr open impl-main --stage impl >/dev/null
rr open design-main --stage design >/dev/null
rr start impl-main >/dev/null
P1="评审 ST1 的实现。review-point=impl-main round=1 mode=full"
out="$(gate zyz-worker:review-agent "评审 ST1 的实现，覆盖全部维度。")"
denied "$out" && pass "H no marker -> deny" || fail "H no marker" "$out"
has "$out" "[zyz-worker watchdog]" "H deny carries the watchdog prefix"
has "$out" "review-round.sh start <point>" "H deny names the command"
has "$out" "impl-main（第 1 轮）" "H deny lists the points and their rounds"
printf '%s' "$out" | python3 -c 'import json,sys;d=json.load(sys.stdin)["hookSpecificOutput"];assert d["hookEventName"]=="PreToolUse" and d["permissionDecisionReason"]' \
    && pass "H deny uses the PreToolUse hookSpecificOutput shape" || fail "H deny shape"
[ -s "$T/runtime/review-gate.log" ] && pass "H deny appended to runtime/review-gate.log" || fail "H gate log"
out="$(gate zyz-worker:review-agent "$P1")"; [ -z "$out" ] && pass "H marker = latest started round -> allow" || fail "H matching marker" "$out"
out="$(gate review-agent "$P1")"; [ -z "$out" ] && pass "H bare role name, matching marker -> allow" || fail "H bare role allow"
out="$(gate zyz-worker:review-agent "\`review-point=impl-main round=1 mode=full\`")"; [ -z "$out" ] && pass "H marker inside backticks -> allow" || fail "H backtick marker"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "H marker ahead of the recorded round -> deny" || fail "H ahead"
has "$out" "start impl-main" "H ... and says to run start"
rr result impl-main --blocking 2 >/dev/null; rr start impl-main >/dev/null
out="$(gate zyz-worker:review-agent "$P1")"
denied "$out" && pass "H stale marker (round 1 after round 2 started) -> deny" || fail "H stale"
has "$out" "review-point=impl-main round=2 mode=incremental" "H ... and gives the right marker"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental")"; [ -z "$out" ] && pass "H round 2 incremental -> allow" || fail "H r2 incremental"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=2 mode=full")"
denied "$out" && pass "H mode=full on an incremental round -> deny" || fail "H r2 full"
has "$out" "start impl-main --full" "H ... and points at start --full for a full re-review"
out="$(gate zyz-worker:review-agent "review-point=design-main round=1 mode=full")"
denied "$out" && pass "H opened but never started -> deny" || fail "H not started"
has "$out" "start design-main" "H ... and says to start it"
rr start design-main >/dev/null
out="$(gate zyz-worker:review-agent "review-point=design-main round=1 mode=incremental")"
denied "$out" && pass "H round 1 marked incremental -> deny" || fail "H r1 incremental"
has "$out" "mode=full" "H ... and says round 1 is full"
out="$(gate zyz-worker:review-agent "review-point=nope round=1 mode=full")"
denied "$out" && pass "H unknown point -> deny" || fail "H unknown point"
has "$out" "open nope --stage" "H ... and says to open it"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=2 mode=fulll")"
denied "$out" && pass "H malformed marker -> deny" || fail "H malformed marker"
has "$out" "格式不对" "H ... and says the format is wrong"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental；另外 review-point=design-main round=9 mode=incremental")"
denied "$out" && pass "H every marker must match (one stale -> deny)" || fail "H multi marker"
# The dispatch's own `Tier:` line must name the point's effective tier.
out="$(GATE_TIER= gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "H no dispatch Tier line -> deny" || fail "H no Tier line" "$out"
has "$out" "Tier: standard" "H ... and names the tier line to add"
out="$(GATE_TIER=strict gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "H dispatch Tier line != the point's tier -> deny" || fail "H wrong Tier line"
out="$(GATE_TIER=quick gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "H dispatch Tier line with a bad value -> deny" || fail "H bad Tier value"
has "$out" "不是 fast|standard|strict" "H ... and says the value is not a tier"
out="$(GATE_TIER= gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental
- Tier: standard")"
denied "$out" && pass "H a quoted '- Tier:' status row is not the dispatch tier line" || fail "H status row counted"
out="$(GATE_TIER= gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental
\`Tier: standard\`")"
[ -z "$out" ] && pass "H Tier line in backticks -> allow" || fail "H backtick Tier" "$out"
out="$(GATE_TIER= gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental Tier: standard")"
denied "$out" && pass "H Tier on the marker line (not its own line) -> deny" || fail "H same-line Tier"
out="$(gate review-agent "无标记" task_name)"
denied "$out" && pass "H Codex task_name=review-agent is gated too" || fail "H task_name"
for role in zyz-worker:implementation-agent test-agent Explore general-purpose; do
    out="$(gate "$role" "评审一下，没有标记")"; [ -z "$out" ] && pass "H $role dispatch untouched" || fail "H $role gated"
done
out="$(ZYZ_REVIEW_GATE_DISABLE=1 gate zyz-worker:review-agent "无标记")"; [ -z "$out" ] && pass "H ZYZ_REVIEW_GATE_DISABLE=1 -> allow" || fail "H gate disable"
out="$(ZYZ_HOOKS_DISABLE=1 gate zyz-worker:review-agent "无标记")"; [ -z "$out" ] && pass "H ZYZ_HOOKS_DISABLE=1 -> allow" || fail "H hooks disable"
out="$(printf 'not json' | bash "$GATE"; echo "rc=$?")"; [ "$out" = "rc=0" ] && pass "H malformed input -> fail open" || fail "H malformed input" "$out"
out="$(printf '' | bash "$GATE"; echo "rc=$?")"; [ "$out" = "rc=0" ] && pass "H empty input -> fail open" || fail "H empty input"
mk_status "$T" ""
out="$(gate zyz-worker:review-agent "无标记")"; [ -z "$out" ] && pass "H task without a Tier -> fail open" || fail "H legacy gated"
mk_status "$T" "- Tier: fast|standard|strict"
out="$(gate zyz-worker:review-agent "无标记")"; [ -z "$out" ] && pass "H placeholder Tier -> fail open" || fail "H placeholder gated"
mk_status "$T" "- Tier:"
out="$(gate zyz-worker:review-agent "无标记")"; [ -z "$out" ] && pass "H empty '- Tier:' -> fail open" || fail "H empty Tier gated"
mk_status "$T" "- Tier:   "
out="$(gate zyz-worker:review-agent "无标记")"; [ -z "$out" ] && pass "H whitespace-only '- Tier:' -> fail open" || fail "H blank Tier gated"
mk_status "$T" "- Tier: standard"
rm -f "$PROJ/.zyz-worker/current-task"
out="$(gate zyz-worker:review-agent "无标记")"; [ -z "$out" ] && pass "H no task pointer -> fail open" || fail "H no pointer"
# A session with two tasks: the marker may name a point of either.
T2="$PROJ/.zyz-worker/tasks/t2"
mk_status "$T2" "- Tier: strict"
mkdir -p "$PROJ/.zyz-worker/sessions"
printf '%s\n%s\n' "$T" "$T2" > "$PROJ/.zyz-worker/sessions/sid-1"
bash "$RR" --task "$T2" open agg --stage aggregate >/dev/null; bash "$RR" --task "$T2" start agg >/dev/null
out="$(GATE_SID=sid-1 GATE_TIER=strict gate zyz-worker:review-agent "review-point=agg round=1 mode=full")"
[ -z "$out" ] && pass "H multi-task session: marker for the second task -> allow" || fail "H multi-task" "$out"
out="$(GATE_SID=sid-1 gate zyz-worker:review-agent "无标记")"
denied "$out" && pass "H multi-task session: no marker -> deny" || fail "H multi-task no marker"
rm -rf "$PROJ/.zyz-worker/sessions" "$T2"
printf 't1\n' > "$PROJ/.zyz-worker/current-task"

# ---------------------------------------------------------------------------
# I — L5 lets a recorded incremental re-review through, nothing else
# ---------------------------------------------------------------------------
l5() { payload "$@" | bash "$L5"; }
CAP="增量复审：只核实上一轮的 blocking 是否落地，重点问题就行。"
mk_status "$T" "- Tier: standard"
rr open impl-main --stage impl >/dev/null
rr start impl-main >/dev/null
out="$(l5 zyz-worker:review-agent "$CAP")"
denied "$out" && pass "I control: the capped phrasing alone is denied by L5" || fail "I control" "$out"
out="$(l5 zyz-worker:review-agent "$CAP review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "I incremental marker for a round never started -> still denied" || fail "I unstarted marker passed"
rr result impl-main --blocking 2 >/dev/null; rr start impl-main >/dev/null
out="$(l5 zyz-worker:review-agent "$CAP review-point=impl-main round=2 mode=incremental")"
[ -z "$out" ] && pass "I recorded incremental round 2 -> L5 allows" || fail "I recorded incremental" "$out"
out="$(l5 zyz-worker:review-agent "$CAP mode=incremental")"
denied "$out" && pass "I bare 'mode=incremental' text -> denied" || fail "I bare text passed"
out="$(l5 zyz-worker:review-agent "$CAP review-point=impl-main round=2 mode=full")"
denied "$out" && pass "I mode=full marker gets the usual check" || fail "I full marker passed"
out="$(l5 zyz-worker:review-agent "$CAP review-point=impl-main round=1 mode=incremental")"
denied "$out" && pass "I stale incremental marker -> denied" || fail "I stale marker passed"
out="$(l5 zyz-worker:implementation-agent "$CAP review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "I the exemption is for review-agent only" || fail "I impl-agent exempted"
out="$(l5 zyz-worker:review-agent "Review ST5 implementation and tests against the design doc. Report all findings by severity.")"
[ -z "$out" ] && pass "I a legitimate full-scope prompt still passes" || fail "I legit prompt"
out="$(l5 zyz-worker:review-agent "only the top 3 findings is enough")"
denied "$out" && pass "I an ordinary cap without marker still denied" || fail "I ordinary cap"
mk_status "$T" ""
rr open impl-main --stage impl >/dev/null; run_rounds impl-main 1 >/dev/null; rr start impl-main >/dev/null
out="$(l5 zyz-worker:review-agent "$CAP review-point=impl-main round=2 mode=incremental")"
[ -z "$out" ] && pass "I task without a Tier: a recorded incremental round passes L5 too" || fail "I legacy incremental"

# ---------------------------------------------------------------------------
# J — §10.7: forced full rounds, closing, reopening, per-point tiers
# ---------------------------------------------------------------------------
mk_status "$T" "- Tier: standard"
rr open impl-main --stage impl >/dev/null
rr start impl-main >/dev/null; rr result impl-main --blocking 2 >/dev/null
rr start impl-main --full >/dev/null 2>&1; rc_is "$?" 2 "J --full needs --reason"
rr start impl-main --reason x >/dev/null 2>&1; rc_is "$?" 2 "J --reason without --full -> exit 2"
out="$(rr start impl-main --full --reason "结构改了")"
[ "$out" = "round=2 mode=full cross-harness=yes" ] && pass "J start --full: round 2 full, impl full round gets cross-harness" || fail "J start --full" "$out"
rr result impl-main --blocking 1 >/dev/null
grep -q '^- Review: point=impl-main; stage=impl; kind=main; round=2; started=[0-9]*; blocking=1; behavior=-; mode=full; reason=结构改了$' "$T/status.md" \
    && pass "J forced-full row keeps mode=full through result" || fail "J forced row" "$(grep 'round=2' "$T/status.md")"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=2 mode=full")"; [ -z "$out" ] && pass "J gate: forced-full round with mode=full -> allow" || fail "J gate forced full"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "J gate: forced-full round marked incremental -> deny" || fail "J gate forced incremental"
out="$(l5 zyz-worker:review-agent "$CAP review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "J L5: no incremental exemption on a forced-full round" || fail "J L5 forced"
out="$(rr start impl-main)"; [ "$out" = "round=3 mode=incremental cross-harness=no" ] && pass "J the round after a forced one is incremental again" || fail "J r3" "$out"
rr result impl-main --blocking 1 >/dev/null
rr start impl-main >/dev/null 2>&1; rc_is "$?" 3 "J a forced-full round counts toward the cap"
# close
before="$(sha "$T/status.md")"
out="$(rr close impl-main --outcome passed --reason done)"; rc=$?
rc_is "$rc" 3 "J close passed with blocking left -> exit 3"
[ "$before" = "$(sha "$T/status.md")" ] && pass "J refused close writes nothing" || fail "J refused close wrote"
rr close impl-main --outcome residual --reason r >/dev/null; rc_is "$?" 3 "J close residual without --by user -> exit 3"
rr close impl-main --outcome later --reason r >/dev/null 2>&1; rc_is "$?" 2 "J close with a bad outcome -> exit 2"
rr close impl-main --outcome residual --by user --reason "用户：接受为遗留风险 RR-1" >/dev/null; rc_is "$?" 0 "J close residual --by user"
grep -q '^- Review-Close: point=impl-main; round=3; outcome=residual; at=[0-9]*; reason=用户：接受为遗留风险 RR-1$' "$T/status.md" \
    && pass "J Review-Close row in the §10.7 format" || fail "J close row"
out="$(rr start impl-main)"; rc=$?
rc_is "$rc" 3 "J start on a closed point -> exit 3"
has "$out" "open impl-main" "J ... and says to reopen it"
for c in "result impl-main --blocking 0" "grant impl-main --reason r" "check impl-main --outcome continue --reason r" "close impl-main --outcome split --by user --reason r"; do
    # shellcheck disable=SC2086
    rr $c >/dev/null 2>&1; rc_is "$?" 2 "J closed point refuses: ${c%% *}"
done
out="$(gate zyz-worker:review-agent "review-point=impl-main round=3 mode=incremental")"
denied "$out" && pass "J gate: marker for a closed point -> deny" || fail "J gate closed"
has "$out" "已经关闭" "J ... and says it is closed"
out="$(rr status)"
has "$out" "closed=residual@3" "J status shows the close"
has "$out" "all review points closed" "J status: every point closed"
rr open other --stage aggregate >/dev/null
has "$(rr status)" "unclosed: other" "J status lists unclosed points"
# passed
rr start other >/dev/null; rr result other --blocking 0 >/dev/null
rr close other --outcome passed --reason "零 blocking" >/dev/null; rc_is "$?" 0 "J close passed after a zero-blocking round"
rr start other >/dev/null 2>&1; rc_is "$?" 3 "J a closed point under its cap still refuses start"
# reopen: a new set of records, the old ones kept
rr open impl-main >/dev/null; rc_is "$?" 0 "J reopen a closed point (stage taken from its records)"
[ "$(grep -c '^- Review: point=impl-main; stage=impl; kind=main; round=0;' "$T/status.md")" -eq 2 ] && pass "J reopen appends a new round=0 row, history kept" || fail "J reopen row"
out="$(rr start impl-main)"; [ "$out" = "round=1 mode=full cross-harness=yes" ] && pass "J reopened point counts from round 1" || fail "J reopen start" "$out"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=1 mode=full")"; [ -z "$out" ] && pass "J gate follows the newest set of records" || fail "J gate reopen" "$out"
rr result impl-main --blocking 1 >/dev/null
rc="$(run_rounds impl-main 2)"; rc_is "$rc" 0 "J reopened point gets its own cap (rounds 2..3)"
rr start impl-main >/dev/null 2>&1; rc_is "$?" 3 "J ... and is capped again at 3"
# per-point tiers
mk_status "$T" "- Tier: standard"
rr open design-replay --stage design --kind aux --tier strict >/dev/null; rc_is "$?" 0 "J open --tier strict on a standard task"
grep -q '^- Review: point=design-replay; stage=design; kind=aux; tier=strict; round=0;' "$T/status.md" && pass "J tier= field on the point's row" || fail "J tier field"
rc="$(run_rounds design-replay 3)"; rc_is "$rc" 0 "J strict point: past the standard design cap of 2"
grep -q '^- Review: point=design-replay; .*tier=strict; round=3;' "$T/status.md" && pass "J start carries the point tier onto new rows" || fail "J tier carried"
rr start design-replay >/dev/null 2>&1; rc_is "$?" 3 "J strict point: round 4 needs a convergence check"
has "$(rr status design-replay)" "tier=strict" "J status shows the point's effective tier"
out="$(GATE_TIER=strict gate zyz-worker:review-agent "review-point=design-replay round=3 mode=incremental")"
[ -z "$out" ] && pass "J gate: dispatch Tier = the point's effective tier (strict) -> allow" || fail "J gate point tier" "$out"
out="$(GATE_TIER=standard gate zyz-worker:review-agent "review-point=design-replay round=3 mode=incremental")"
denied "$out" && pass "J gate: dispatch Tier = the task tier, not the point's -> deny" || fail "J gate task tier accepted"
has "$out" "Tier: strict" "J ... and names the point's tier"
rr open d2 --stage design --tier fast >/dev/null 2>&1; rc_is "$?" 2 "J --tier below the task tier -> exit 2"
rr open i2 --stage impl >/dev/null; run_rounds i2 3 >/dev/null
rr start i2 >/dev/null 2>&1; rc_is "$?" 3 "J standard point capped at 3"
rr open i2 --tier strict >/dev/null; rc_is "$?" 0 "J re-tier an open point upward"
rr start i2 >/dev/null 2>&1; rc_is "$?" 3 "J ... now strict: round 4 waits for a check, not a grant"
has "$(rr status i2)" "gate=needs-check" "J ... status agrees"
before="$(sha "$T/status.md")"
rr open i2 --tier standard >/dev/null; rc_is "$?" 3 "J lowering a point's tier without --by user -> exit 3"
[ "$before" = "$(sha "$T/status.md")" ] && pass "J ... writes nothing" || fail "J lowering wrote"
rr open i2 --tier standard --by user >/dev/null; rc_is "$?" 0 "J back to the task tier with --by user"
has "$(rr status i2)" "tier=standard" "J ... the override is gone"
rr open i2 --stage design >/dev/null 2>&1; rc_is "$?" 2 "J re-open with another stage -> exit 2"
mk_status "$T" "- Tier: fast"
rr open dz --stage design --tier standard >/dev/null
[ "$(rr start dz)" = "round=1 mode=full cross-harness=yes" ] && pass "J fast task, standard design point: allowed, with cross-harness" || fail "J fast task standard point"
mk_status "$T" ""
rr open dz --stage design --tier strict >/dev/null 2>&1; rc_is "$?" 2 "J --tier on a task without a Tier -> exit 2"

# ---------------------------------------------------------------------------
# K — registration and docs
# ---------------------------------------------------------------------------
python3 - "$ROOT/hooks/hooks.json" <<'PY' && pass "K review-gate.sh registered sync on the dispatch matcher, after L5" || fail "K hooks.json registration"
import json, sys
groups = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
hit = [g for g in groups if any("/hooks/scripts/review-gate.sh" in h.get("command", "") for h in g["hooks"])]
assert len(hit) == 1, hit
g = hit[0]
assert g["matcher"] == "^(Agent|spawn_agent|collaboration\\.spawn_agent)$", g["matcher"]
cmds = [h["command"] for h in g["hooks"]]
assert "dispatch-scope-guard.sh" in cmds[0] and "review-gate.sh" in cmds[1], cmds
assert not any(h.get("async") for h in g["hooks"])
PY
for f in "$RR" "$GATE"; do [ -x "$f" ] && pass "K executable: ${f#"$ROOT"/}" || fail "K executable: ${f#"$ROOT"/}"; bash -n "$f" && pass "K syntax: ${f#"$ROOT"/}" || fail "K syntax"; done
for w in review-round.sh review-gate.sh ZYZ_REVIEW_GATE_DISABLE "mode=incremental" "Review-Grant"; do
    grep -q -- "$w" "$ROOT/hooks/README.md" && pass "K hooks/README.md documents $w" || fail "K README lacks $w"
done

echo
echo "RESULT: $PASSED/$TOTAL checks passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
