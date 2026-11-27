#!/usr/bin/env bash
#
# test-review-round.sh — the execute-task tier mechanics (design §10.3–§10.5,
# §10.7 items 1, 2, 9, §10.8 items 1, 2, 5, 6, 7, §11.4):
#   * hooks/scripts/review-round.sh (+ review_round.py): open / start / result /
#     grant / check / close / tier / status, the per-tier caps, the strict-tier
#     convergence-check gate, mode and cross-harness, forced full rounds,
#     closing and reopening, per-point tiers, tasks without a Tier
#     (fail open), validation, atomic writes that never touch other content,
#     parallel writers sharing expect.sh's lock;
#   * §11.4 (section L): the standard tier's early stop when round 2 did not
#     converge, the four-way hand-over to the user, result --induced /
#     --pending, close --outcome carried, pending keeping `passed` shut, the
#     design-document snapshots and the revision size (delta / growing),
#     rows from before these fields;
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
#  * That a later round reaches a fresh reviewer: re-using a resident reviewer
#    teammate via SendMessage bypasses the gate and L5 entirely; only the
#    prompts ("每一轮评审都重新派发 review-agent") forbid it.
#  * That a re-run `result` or a later `check` is honest: the main agent can
#    lower `rejected` or overwrite an `escalate` by rewriting its own record.
#  * That `--induced` / `--pending` (and `--blocking` / `--rejected` before
#    them) are the true counts: the main agent reports them itself. The
#    script only checks that they are given from round 2 on, that induced <=
#    blocking + rejected, and that pending is a count. A `--pending 0` while
#    a blocking still waits on the user does not keep `passed` shut; an
#    understated round 2 passes the early stop.
#  * That the snapshot holds what the reviewer actually read: it copies the
#    documents named by --docs or the `- 设计文档:` line at `start`; a document
#    not listed there, or edited after `start`, is not measured.
#  * That `delta` measures meaning: it counts changed lines, so reflowing a
#    paragraph counts and a one-line rule that changes everything barely does.
#  * That the user chose `carried` (or a grant after the early stop): as for
#    `residual` / `split`, `--by user` is the main agent's word.
#
# Mutation record (2026-11-26, each mutant applied to an out-of-tree copy of
# hooks/ + scripts/ and run against this suite; every one turns a check red):
#  M1  review_round.py decide(): drop the cap test (`n > cap` -> `False`)
#  M2  review_round.py decide(): a grant authorizes every later round
#      (`(point, n) in grants` -> any grant for the point)
#  M3  review_round.py decide(): strict check window one round too wide
#      (superseded by M39 once §10.8-5 required round == n-1)
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
#  M35 cmd_open(): reopening drops the point's own tier (F1)
#  M36 cmd_open(): lowering the tier on reopen without --by user (F1)
#  M37 decide(): escalate only checked at the strict 3-round boundary (F2)
#  M38 decide(): escalate never spent by a later started round (F2)
#  M39 decide(): any check in rounds n-3..n-1 counts again (F3)
#  M40 cross_harness(): aggregate full rounds get cross-harness (F5)
#  M41 _match(): a round that already has a result still dispatches (B1)
#  M42 cmd_close(): passed with rejected blockings (B2)
#  M43 cmd_close(): passed without a recorded rejected count (B2)
#  M44 cmd_result(): close hint on blocking=0 regardless of rejected (B2)
#  M45 cmd_result(): --rejected not written to the row (B2)
#  M49 append_rows(): silently drops an unrelated line (F6; only the
#      byte-for-byte G check catches it)
#
# Mutation record for §11.4 (2026-11-27, same method; every one turns a check
# red — N31 and N44 first survived and got the checks named below):
#  N1  CAPS: standard design cap back to 2          N2  ... or 4
#  N3  decide(): no early stop
#  N4  decide(): early stop only when round 2 is larger (>= -> >)
#  N5  reported(): accepted blockings only (rejected not counted)
#  N6  decide(): a grant does not release the early stop
#  N7  decide(): early stop on every tier
#  N8  decide(): early stop on design points only
#  N9  ask_user(): no trend in a refusal
#  N10 ask_user(): the carried option missing
#  N11 decide(): cap refusal without the four choices
#  N12 decide(): escalate refusal without the trend / choices
#  N13 cmd_result(): --induced / --pending never required
#  N14 cmd_result(): ... required on a task without a Tier
#  N15 cmd_result(): ... required from round 1
#  N58 cmd_result(): only --induced required      N59 only --pending required
#  N16 cmd_result(): no upper bound on --induced
#  N17 cmd_result(): the bound of --induced is --blocking alone
#  N57 cmd_result(): --pending bounded by --blocking + --rejected (it is the
#      point's state, not a part of the round: it may exceed them)
#  N61 cmd_result(): --pending value not validated
#  N60 cmd_result(): close hint on blocking=0 rejected=0 with pending left
#  N18 cmd_result(): induced not written       N19 ... pending not written
#  N20 review_line(): induced= / pending= before behavior=
#  N21 cmd_close(): passed ignores pending
#  N22 cmd_close(): carried without --by user
#  N23 parse_row(): carried is not a valid Review-Close outcome
#  N24 parse_row(): induced / pending required (old rows invalid)
#  N25 parse_row(): pending without a result accepted
#  N26 parse_row(): any delta value accepted
#  N27 cmd_start(): snapshot on every stage
#  N28 take_snapshot(): a failure propagates (no fail open)
#  N29 take_snapshot(): growing on an equal count (> -> >=)
#  N30 take_snapshot(): growing compares removed lines
#  N31 take_snapshot(): stale r<n>/ and diff of an earlier set kept (first
#      survived — the reopen case had no earlier snapshot to be stale; the
#      "Leftovers of an earlier set" checks were rebuilt)   N55/N56: one of the two
#  N32 take_snapshot(): diff file not written
#  N33 cmd_start(): delta not written to the row   N34 rewrite(): result drops it
#  N35 cmd_start(): prev never passed
#  N36 find_docs(): status line resolved against cwd first
#  N37 find_docs(): --docs resolved against the task dir first
#  N38 find_docs(): full-width parenthesised notes kept
#  N39 find_docs(): --docs ignored
#  N40 find_docs(): document line read inside HTML comments
#  N41 find_docs(): no 、 / ， separators
#  N42 find_docs(): the whole value not tried as one path
#  N43 cmd_status(): rounds not listed
#  N44 cmd_status(): the refusal's trend repeated (first survived — the check
#      anchored on the two-space indent; it now counts the line anywhere)
#  N45 trend(): delta column missing
#  N46 snap_diff(): diff header lines counted as changes
#  N47 cmd_start(): --docs on a non-design point is an error
#  N48 cmd_start(): --docs with no path accepted
#  N49 result_usage(): needs-result never asks for --induced / --pending
#  N50 take_snapshot(): no note when nothing is readable
#  N51 snap_name(): outside-task documents stored by basename
#  N52 take_snapshot(): a missing r<n-1> compared anyway
#  N53 decide(): 0 against 0 counts as not converging
#  N54 decide(): early stop one round late
# Not killable here: "early stop at round >= 3" (every standard cap is 3, so
# a later round is refused by the cap first — equivalent under the caps).
# M46–M48 (N11, lanes/ in the unharvested texts of watchdog.sh and
# stop-gate-main.sh) are caught by scripts/test-session-pointer.sh S8.
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
# run_rounds <point> <k>: k × (start + result); prints the last start rc. The
# blocking count goes down to 1 (k, k-1, … 1), so a standard point is not
# stopped before round 3 for not converging (§11.3-7; section L tests that).
run_rounds() {
    local i r=0
    for i in $(seq 1 "$2"); do
        rr start "$1" >/dev/null 2>&1; r=$?
        [ "$r" -eq 0 ] || { echo "$r"; return; }
        rr result "$1" --blocking "$(($2 - i + 1))" --induced 0 --pending 0 >/dev/null 2>&1
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
grep -q '^- Review: point=impl-main; stage=impl; kind=main; round=0; started=[0-9]*; blocking=-; rejected=-; behavior=-; induced=-; pending=-$' "$T/status.md" \
    && pass "A3 open writes a round=0 row in the §10.4 format (+ rejected=, §10.8-1; induced= / pending=, §11.4)" || fail "A3 open row format" "$(grep 'point=impl-main' "$T/status.md")"
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
grep -q 'point=impl-main; stage=impl; kind=main; round=1; started=[0-9]*; blocking=2; rejected=-; behavior=1; induced=-; pending=-$' "$T/status.md" \
    && pass "A8 result fills blocking/behavior in place" || fail "A8 result in place"
rr result impl-main --blocking 3 --rejected 1 >/dev/null
grep -q 'round=1; started=[0-9]*; blocking=3; rejected=1; behavior=-; induced=-; pending=-$' "$T/status.md" && pass "A8 result can be corrected, rejected= recorded" || fail "A8 result correction"
rr result impl-main --blocking 0 --rejected x >/dev/null 2>&1; rc_is "$?" 2 "A8 --rejected must be a count"
# rejected= sits between blocking= and behavior= (lane E's template order);
# reading does not depend on field order, so rows in the other order still count.
python3 - "$T/status.md" <<'PY'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
s = re.sub(r"(point=impl-main; .*round=1; started=\d+); blocking=3; rejected=1; behavior=-", r"\1; blocking=0; behavior=-; rejected=0", s)
io.open(p, "w", encoding="utf-8").write(s)
PY
has "$(rr status impl-main)" "round=1 blocking=0 rejected=0 behavior=-" "A8 a row with rejected= after behavior= still parses"
# B2 (§10.8-1): the close hint only when the reviewer's blockings are all gone.
out="$(rr result impl-main --blocking 0 --rejected 0)"
has "$out" "close impl-main --outcome passed" "A8 blocking=0 rejected=0 points at close --outcome passed"
out="$(rr result impl-main --blocking 0)"
lacks "$out" "--outcome passed --reason" "A8 blocking=0 without --rejected: no close hint"
has "$out" "--rejected 0" "A8 ... and asks for --rejected"
out="$(rr result impl-main --blocking 0 --rejected 2)"
lacks "$out" "--outcome passed --reason" "A8 blocking=0 rejected=2: no close hint"
has "$out" "复核" "A8 ... and says the rejections go to the next round for review"

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
        has "$out" "四选一" "B $tier/$stage: refusal hands the user the four options (§11.3-8)"
        has "$out" "close $p --outcome carried --by user" "B $tier/$stage: ... one of them is carrying the rest into implementation"
        has "$out" "  r$cap blocking=1 rejected=- induced=0 pending=0 delta=-" "B $tier/$stage: ... with the trend of the rounds"
        lacks "$out" "没有收敛" "B $tier/$stage: ... as a cap refusal, not the early stop"
    fi
    rr grant "$p" --reason "用户批准再开一轮" >/dev/null
    out="$(rr start "$p" 2>&1)"; rc=$?
    rc_is "$rc" 0 "B $tier/$stage: a grant allows round $((cap+1))"
    rr result "$p" --blocking 1 --induced 0 --pending 0 >/dev/null
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
cap_case standard design 3
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
# F3 (§10.8-5): only a check made after round n-1 opens round n; an early
# check inside the window does not count.
mk_status "$T" "- Tier: strict"
rr open impl-a --stage impl --kind aux >/dev/null
run_rounds impl-a 2 >/dev/null
rr check impl-a --outcome reorder --reason early >/dev/null
rc="$(run_rounds impl-a 1)"; rc_is "$rc" 0 "B strict: a continue-type check at round 2 does not hold round 3"
out="$(rr start impl-a 2>&1)"; rc=$?
rc_is "$rc" 3 "B strict: a check at round 2 does NOT cover round 4"
has "$out" "第 3 轮之后" "B strict: ... the refusal asks for a check after round 3"
rr check impl-a --outcome continue --reason "第 3 轮后" >/dev/null
rr start impl-a >/dev/null 2>&1; rc_is "$?" 0 "B strict: the round-3 check opens round 4"
rr result impl-a --blocking 1 --induced 0 --pending 0 >/dev/null
rc="$(run_rounds impl-a 2)"; rc_is "$rc" 0 "B strict: rounds 5..6 need no check"
# The next period: a check after round 5 (one round early) does not open 7.
mk_status "$T" "- Tier: strict"
rr open impl-b --stage impl >/dev/null
run_rounds impl-b 3 >/dev/null; rr check impl-b --outcome continue --reason r3 >/dev/null
run_rounds impl-b 2 >/dev/null; rr check impl-b --outcome continue --reason r5 >/dev/null
run_rounds impl-b 1 >/dev/null
rr start impl-b >/dev/null 2>&1; rc_is "$?" 3 "B strict: a check at round 5 does not open round 7"
# F2 (§10.8-5): escalate holds the next round at any round, any tier.
for tier in strict standard; do
    mk_status "$T" "- Tier: $tier"
    rr open esc --stage impl >/dev/null
    run_rounds esc 1 >/dev/null
    rr check esc --outcome escalate --reason "交用户" >/dev/null
    out="$(rr start esc 2>&1)"; rc=$?
    rc_is "$rc" 3 "B $tier: escalate after round 1 holds round 2"
    has "$out" "escalate" "B $tier: ... and says why"
    has "$(rr status esc)" "gate=escalated" "B $tier: status shows gate=escalated"
    rr grant esc --reason "用户：继续" >/dev/null
    rr start esc >/dev/null 2>&1; rc_is "$?" 0 "B $tier: the user's grant releases round 2"
    rr result esc --blocking 0 --induced 0 --pending 0 >/dev/null
    rr start esc >/dev/null 2>&1; rc_is "$?" 0 "B $tier: the escalate is spent once a later round started"
done
mk_status "$T" "- Tier: strict"
rr open esc --stage impl >/dev/null
run_rounds esc 2 >/dev/null
rr check esc --outcome escalate --reason a >/dev/null
rr check esc --outcome continue --reason "用户说继续" >/dev/null
rr start esc >/dev/null 2>&1; rc_is "$?" 0 "B strict: a later non-escalate check at the same round replaces the escalate"

# ---------------------------------------------------------------------------
# C — mode and cross-harness
# ---------------------------------------------------------------------------
# startline <point> [blocking]: the first line of start (a design point adds
# lines about its snapshot, section L), then a result.
startline() { rr start "$1" 2>&1 | head -1; rr result "$1" --blocking "${2:-1}" --induced 0 --pending 0 >/dev/null 2>&1; }
mk_status "$T" "- Tier: standard"
for p in d:design i:impl a:aggregate; do rr open "${p%%:*}" --stage "${p#*:}" >/dev/null; done
[ "$(startline d)" = "round=1 mode=full cross-harness=yes" ] && pass "C standard design r1: full, cross-harness" || fail "C standard design r1"
[ "$(startline d)" = "round=2 mode=incremental cross-harness=yes" ] && pass "C standard design r2: incremental, cross-harness stays" || fail "C standard design r2"
[ "$(startline i)" = "round=1 mode=full cross-harness=yes" ] && pass "C impl r1: full, cross-harness" || fail "C impl r1"
[ "$(startline i)" = "round=2 mode=incremental cross-harness=no" ] && pass "C impl r2: incremental, no cross-harness" || fail "C impl r2"
[ "$(startline a 2)" = "round=1 mode=full cross-harness=yes" ] && pass "C aggregate r1: cross-harness" || fail "C aggregate r1"
[ "$(startline a)" = "round=2 mode=incremental cross-harness=no" ] && pass "C aggregate r2: no cross-harness" || fail "C aggregate r2"
[ "$(rr start a --full --reason "结构改了" 2>&1)" = "round=3 mode=full cross-harness=no" ] && pass "C aggregate forced full round: still no cross-harness (§10.8-7)" || fail "C aggregate forced full"
rr result a --blocking 1 --induced 0 --pending 0 >/dev/null
has "$(rr status a)" "next=4 mode=incremental cross-harness=no" "C status agrees for aggregate"
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
has "$out" "impl-main stage=impl kind=main tier=standard round=3 blocking=1 rejected=- behavior=- history=3→2→1 cap=3 closed=no next=4 mode=incremental cross-harness=no gate=needs-grant" "F status line"
has "$out" "四选一" "F status explains a blocked next round"
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
G_BEFORE="$SANDBOX/g-before.md"; cp "$T/status.md" "$G_BEFORE"
rr start ok >/dev/null; rc_is "$?" 0 "G writes go on next to bad rows"
grep -qx -- '- Review: point=bad; stage=bogus; kind=main; round=1; started=1700000000; blocking=-; behavior=-' "$T/status.md" \
    && pass "G the bad row is kept byte-for-byte" || fail "G bad row rewritten"
# Byte-for-byte: drop the one row this start added and the file must equal
# the text before it; the row sits inside the section (before `## 下一步`),
# right after the section's last pre-existing line, not inside the comment.
python3 - "$T/status.md" "$G_BEFORE" <<'PY' && pass "G only the new row added, everything else byte-for-byte" || fail "G layout"
import sys
after = open(sys.argv[1], encoding="utf-8", newline="").read()
before = open(sys.argv[2], encoding="utf-8", newline="").read()
lines = after.split("\n")
new = [i for i, l in enumerate(lines) if l.startswith("- Review: point=ok; stage=impl; kind=main; round=1;")]
assert len(new) == 1, new
i = new[0]
assert "\n".join(lines[:i] + lines[i + 1:]) == before, "text other than the new row changed"
assert lines.index("-->") < i < lines.index("## 下一步") and lines.index("## 评审收口") < i, i
assert lines[i - 1].startswith("- Review-Grant: point=ok; round=1;"), lines[i - 1]
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
l5() { payload "$@" | bash "$L5"; }
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
rr result impl-main --blocking 3 >/dev/null; rr start impl-main >/dev/null
out="$(gate zyz-worker:review-agent "$P1")"
denied "$out" && pass "H stale marker (round 1 after round 2 started) -> deny" || fail "H stale"
has "$out" "review-point=impl-main round=2 mode=incremental" "H ... and gives the right marker"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental")"; [ -z "$out" ] && pass "H round 2 incremental -> allow" || fail "H r2 incremental"
# B1 (§10.8-2): once the round has a result, its marker no longer dispatches.
rr result impl-main --blocking 1 --induced 0 --pending 0 >/dev/null
out="$(gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "H a round that already has a result -> deny" || fail "H resulted round allowed" "$out"
has "$out" "已经记录了结果" "H ... and says so"
has "$out" "start impl-main" "H ... and points at start"
out="$(l5 zyz-worker:review-agent "增量复审：只核实上一轮的 blocking 是否落地，重点问题就行。 review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "H L5: no incremental exemption for a round that has a result" || fail "H L5 resulted round"
# The over-cap replay from the final review: cap reached, reuse the last marker.
rr result impl-main --blocking 2 --induced 0 --pending 0 >/dev/null; rr start impl-main >/dev/null; rr result impl-main --blocking 2 --induced 0 --pending 0 >/dev/null
rr start impl-main >/dev/null 2>&1; rc_is "$?" 3 "H (B1 replay) round 4 refused at the cap"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=3 mode=incremental")"
denied "$out" && pass "H (B1 replay) reusing round 3's marker past the cap -> deny" || fail "H B1 replay allowed" "$out"
rr result impl-main --blocking 2 --induced 0 --pending 0 >/dev/null
mk_status "$T" "- Tier: standard"
rr open impl-main --stage impl >/dev/null
rr open design-main --stage design >/dev/null
rr start impl-main >/dev/null; rr result impl-main --blocking 2 >/dev/null; rr start impl-main >/dev/null
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
out="$(gate zyz-worker:review-agent "review-point=impl-main round=2 mode=full")"; [ -z "$out" ] && pass "J gate: forced-full round with mode=full -> allow" || fail "J gate forced full" "$out"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "J gate: forced-full round marked incremental -> deny" || fail "J gate forced incremental"
out="$(l5 zyz-worker:review-agent "$CAP review-point=impl-main round=2 mode=incremental")"
denied "$out" && pass "J L5: no incremental exemption on a forced-full round" || fail "J L5 forced"
rr result impl-main --blocking 1 --induced 0 --pending 0 >/dev/null
grep -q '^- Review: point=impl-main; stage=impl; kind=main; round=2; started=[0-9]*; blocking=1; rejected=-; behavior=-; induced=0; pending=0; mode=full; reason=结构改了$' "$T/status.md" \
    && pass "J forced-full row keeps mode=full through result" || fail "J forced row" "$(grep 'round=2' "$T/status.md")"
out="$(rr start impl-main)"; [ "$out" = "round=3 mode=incremental cross-harness=no" ] && pass "J the round after a forced one is incremental again" || fail "J r3" "$out"
rr result impl-main --blocking 1 --induced 0 --pending 0 >/dev/null
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
rr close other --outcome passed --reason "零 blocking" >/dev/null; rc_is "$?" 3 "J close passed without a recorded rejected count -> exit 3"
rr result other --blocking 0 --rejected 1 >/dev/null
out="$(rr close other --outcome passed --reason "零 blocking")"; rc=$?
rc_is "$rc" 3 "J close passed with rejected blockings -> exit 3 (§10.8-1)"
has "$out" "复核" "J ... and says the rejections need an independent re-check"
rr result other --blocking 0 --rejected 0 >/dev/null
rr close other --outcome passed --reason "零 blocking" >/dev/null; rc_is "$?" 0 "J close passed after blocking=0 rejected=0"
rr start other >/dev/null 2>&1; rc_is "$?" 3 "J a closed point under its cap still refuses start"
# reopen: a new set of records, the old ones kept
rr open impl-main >/dev/null; rc_is "$?" 0 "J reopen a closed point (stage taken from its records)"
[ "$(grep -c '^- Review: point=impl-main; stage=impl; kind=main; round=0;' "$T/status.md")" -eq 2 ] && pass "J reopen appends a new round=0 row, history kept" || fail "J reopen row"
out="$(rr start impl-main)"; [ "$out" = "round=1 mode=full cross-harness=yes" ] && pass "J reopened point counts from round 1" || fail "J reopen start" "$out"
out="$(gate zyz-worker:review-agent "review-point=impl-main round=1 mode=full")"; [ -z "$out" ] && pass "J gate follows the newest set of records" || fail "J gate reopen" "$out"
rr result impl-main --blocking 3 >/dev/null
rc="$(run_rounds impl-main 2)"; rc_is "$rc" 0 "J reopened point gets its own cap (rounds 2..3)"
rr start impl-main >/dev/null 2>&1; rc_is "$?" 3 "J ... and is capped again at 3"
# per-point tiers
mk_status "$T" "- Tier: standard"
rr open design-replay --stage design --kind aux --tier strict >/dev/null; rc_is "$?" 0 "J open --tier strict on a standard task"
grep -q '^- Review: point=design-replay; stage=design; kind=aux; tier=strict; round=0;' "$T/status.md" && pass "J tier= field on the point's row" || fail "J tier field"
rc="$(run_rounds design-replay 3)"; out="$(rr start design-replay 2>&1)"; rc="$rc$?"
rc_is "$rc" 03 "J strict point: round 4 needs a convergence check"
has "$out" "check design-replay --outcome" "J ... a check, not the standard cap's grant"
rr check design-replay --outcome continue --reason "仍在收敛" >/dev/null
rr start design-replay >/dev/null 2>&1; rc_is "$?" 0 "J strict point: past the standard design cap of 3"
grep -q '^- Review: point=design-replay; .*tier=strict; round=4;' "$T/status.md" && pass "J start carries the point tier onto new rows" || fail "J tier carried"
out="$(GATE_TIER=strict gate zyz-worker:review-agent "review-point=design-replay round=4 mode=incremental")"
[ -z "$out" ] && pass "J gate: dispatch Tier = the point's effective tier (strict) -> allow" || fail "J gate point tier" "$out"
out="$(GATE_TIER=standard gate zyz-worker:review-agent "review-point=design-replay round=4 mode=incremental")"
denied "$out" && pass "J gate: dispatch Tier = the task tier, not the point's -> deny" || fail "J gate task tier accepted"
has "$out" "Tier: strict" "J ... and names the point's tier"
rr result design-replay --blocking 1 --induced 0 --pending 0 >/dev/null
has "$(rr status design-replay)" "tier=strict" "J status shows the point's effective tier"
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
# F1 (§10.8-6): reopening a closed point keeps its own tier; lowering it on
# reopen is a downgrade and needs --by user.
close_passed() { rr start "$1" >/dev/null; rr result "$1" --blocking 0 --rejected 0 >/dev/null; rr close "$1" --outcome passed --reason ok >/dev/null; }
rr open up --stage impl --tier strict >/dev/null
close_passed up
rr open up >/dev/null; rc_is "$?" 0 "J reopen a strict point without --tier"
has "$(rr status up)" "tier=strict" "J ... keeps its strict tier"
[ "$(grep -c '^- Review: point=up; stage=impl; kind=main; tier=strict; round=0;' "$T/status.md")" -eq 2 ] \
    && pass "J ... the new round=0 row carries tier=strict" || fail "J reopen tier row"
close_passed up
rr open up --stage impl >/dev/null; has "$(rr status up)" "tier=strict" "J reopen with --stage only still keeps the tier"
close_passed up
before="$(sha "$T/status.md")"
out="$(rr open up --tier standard)"; rc=$?
rc_is "$rc" 3 "J reopen with a lower --tier without --by user -> exit 3"
has "$out" "--by user" "J ... and names --by user"
[ "$before" = "$(sha "$T/status.md")" ] && pass "J ... writes nothing" || fail "J lowering reopen wrote"
rr open up --tier standard --by user >/dev/null; rc_is "$?" 0 "J reopen lower with --by user"
has "$(rr status up)" "tier=standard" "J ... the point is back on the task tier"
close_passed up
rr open up --tier strict >/dev/null; rc_is "$?" 0 "J reopen with a higher --tier needs no --by user"
mk_status "$T" "- Tier: fast"
rr open dz --stage design --tier standard >/dev/null
[ "$(rr start dz | head -1)" = "round=1 mode=full cross-harness=yes" ] && pass "J fast task, standard design point: allowed, with cross-harness" || fail "J fast task standard point"
mk_status "$T" ""
rr open dz --stage design --tier strict >/dev/null 2>&1; rc_is "$?" 2 "J --tier on a task without a Tier -> exit 2"

# ---------------------------------------------------------------------------
# L — §11.4: convergence — the early stop, induced / pending, carried,
#     the revision size of design rounds (snapshots and delta)
# ---------------------------------------------------------------------------
# two_rounds <tier-line> <point> <stage> <r1: b rj> <r2: b rj> [open args…]:
# a fresh task, rounds 1 and 2 with those results ("-" = no --rejected).
two_rounds() {
    local tier="$1" p="$2" stage="$3" b1="$4" j1="$5" b2="$6" j2="$7"; shift 7
    mk_status "$T" "$tier"
    rr open "$p" --stage "$stage" "$@" >/dev/null
    rr start "$p" >/dev/null 2>&1
    if [ "$j1" = - ]; then rr result "$p" --blocking "$b1" >/dev/null; else rr result "$p" --blocking "$b1" --rejected "$j1" >/dev/null; fi
    rr start "$p" >/dev/null 2>&1
    if [ "$j2" = - ]; then rr result "$p" --blocking "$b2" --induced 0 --pending 0 >/dev/null; else rr result "$p" --blocking "$b2" --rejected "$j2" --induced 0 --pending 0 >/dev/null; fi
}
# L1 — the early stop: standard tier, round 3, round 2 no smaller than round 1.
two_rounds "- Tier: standard" dm design 5 0 4 0
rr start dm >/dev/null 2>&1; rc_is "$?" 0 "L1 standard design: round 2 smaller than round 1 -> round 3 starts"
rr result dm --blocking 1 --induced 0 --pending 0 >/dev/null
rr start dm >/dev/null 2>&1; rc_is "$?" 3 "L1 standard design: round 4 refused (cap 3, §11.3-6)"
two_rounds "- Tier: standard" dm design 5 0 5 0
before="$(sha "$T/status.md")"
out="$(rr start dm 2>&1)"; rc=$?
rc_is "$rc" 3 "L1 standard design: round 2 equal to round 1 -> round 3 refused (exit 3)"
[ "$before" = "$(sha "$T/status.md")" ] && pass "L1 ... the refusal writes nothing" || fail "L1 early stop wrote"
has "$out" "第 2 轮没有收敛" "L1 ... says round 2 did not converge"
has "$out" "第 1 轮 5 条、第 2 轮 5 条" "L1 ... with the two totals"
has "$out" "  r1 blocking=5 rejected=0 induced=- pending=- delta=-" "L1 ... the trend: round 1"
has "$out" "  r2 blocking=5 rejected=0 induced=0 pending=0 delta=-" "L1 ... the trend: round 2"
has "$out" "四选一" "L1 ... hands the user the four options"
has "$out" "原有漏报" "L1 ... names the diagnosis to give (§11.3-8)"
has "$out" "结构类" "L1 ... structure vs detail"
has "$out" "review-round.sh grant dm --reason" "L1 ... option 1: grant"
has "$out" "review-round.sh start dm" "L1 ... then start"
has "$out" "review-round.sh close dm --outcome carried --by user --reason" "L1 ... option 2: carried"
has "$out" "review-round.sh close dm --outcome residual --by user --reason" "L1 ... option 3: residual"
has "$out" "review-round.sh close dm --outcome split --by user --reason" "L1 ... option 4: split"
has "$(rr status dm)" "gate=not-converging" "L1 status shows gate=not-converging"
rr grant dm --reason "用户：再开一轮" >/dev/null
rr start dm >/dev/null 2>&1; rc_is "$?" 0 "L1 the user's grant releases round 3"
rr result dm --blocking 1 --induced 0 --pending 0 >/dev/null
out="$(rr start dm 2>&1)"; rc=$?
rc_is "$rc" 3 "L1 that grant covered round 3 only: round 4 is at the cap"
has "$out" "已用满上限 3 轮" "L1 ... and the refusal is the cap's"
two_rounds "- Tier: standard" dm design 5 0 6 0
rr start dm >/dev/null 2>&1; rc_is "$?" 3 "L1 standard design: round 2 larger than round 1 -> refused"
# blocking + rejected is what counts (§11.3-7).
two_rounds "- Tier: standard" dm design 5 0 3 2
rr start dm >/dev/null 2>&1; rc_is "$?" 3 "L1 accepted 3 + rejected 2 against 5: not smaller -> refused"
two_rounds "- Tier: standard" dm design 3 2 4 0
rr start dm >/dev/null 2>&1; rc_is "$?" 0 "L1 4 against accepted 3 + rejected 2: smaller -> starts"
two_rounds "- Tier: standard" dm design 0 0 0 0
rr start dm >/dev/null 2>&1; rc_is "$?" 0 "L1 a round 2 that reported nothing has converged (0 against 0 is not a stall)"
two_rounds "- Tier: standard" dm design 0 0 1 0
rr start dm >/dev/null 2>&1; rc_is "$?" 3 "L1 ... 1 against 0 is"
two_rounds "- Tier: standard" dm design 2 - 1 1
rr start dm >/dev/null 2>&1; rc_is "$?" 3 "L1 a round without --rejected counts its accepted ones only"
out="$(rr result dm --blocking 1 --rejected 1 --induced 0 --pending 0)"
has "$out" "下一轮现在还不能开" "L1 result itself says the next round is held"
has "$out" "第 2 轮没有收敛" "L1 ... and why"
# Other stages, other tiers.
two_rounds "- Tier: standard" im impl 2 0 2 0
out="$(rr start im 2>&1)"; rc=$?
rc_is "$rc" 3 "L1 standard impl: the same early stop"
has "$out" "第 2 轮没有收敛" "L1 ... same message"
two_rounds "- Tier: standard" im impl 2 0 1 0
rr start im >/dev/null 2>&1; rc_is "$?" 0 "L1 standard impl: converging -> round 3 starts"
two_rounds "- Tier: standard" ag aggregate 2 0 2 0
rr start ag >/dev/null 2>&1; rc_is "$?" 3 "L1 standard aggregate: the same early stop"
two_rounds "- Tier: strict" dm design 5 0 5 0
rr start dm >/dev/null 2>&1; rc_is "$?" 0 "L1 strict: no early stop"
two_rounds "- Tier: fast" im impl 2 0 2 0
out="$(rr start im 2>&1)"; rc=$?
rc_is "$rc" 3 "L1 fast impl: round 3 is over the cap of 2"
has "$out" "已用满上限 2 轮" "L1 ... refused as the cap"
lacks "$out" "没有收敛" "L1 ... not as the early stop"
two_rounds "" dm design 5 0 5 0
rr start dm >/dev/null 2>&1; rc_is "$?" 0 "L1 a task without a Tier: no early stop"
two_rounds "- Tier: fast" dz design 5 0 5 0 --tier standard
rr start dz >/dev/null 2>&1; rc_is "$?" 3 "L1 a standard point on a fast task: early stop by the point's tier"
two_rounds "- Tier: standard" ds design 5 0 5 0 --tier strict
rr start ds >/dev/null 2>&1; rc_is "$?" 0 "L1 a strict point on a standard task: no early stop"
# The escalate refusal carries the same trend and choices (§11.3-8).
mk_status "$T" "- Tier: strict"
rr open esc --stage design >/dev/null; run_rounds esc 2 >/dev/null
rr check esc --outcome escalate --reason "交用户" >/dev/null
out="$(rr start esc 2>&1)"
has "$out" "  r2 blocking=1 rejected=- induced=0 pending=0 delta=-" "L1 escalate refusal carries the trend"
has "$out" "close esc --outcome carried --by user" "L1 ... and the four options"
has "$out" "grant esc --reason" "L1 ... grant among them"

# L2 — result --induced / --pending.
mk_status "$T" "- Tier: standard"
rr open dm --stage design >/dev/null; rr start dm >/dev/null 2>&1
rr result dm --blocking 4 --rejected 1 >/dev/null; rc_is "$?" 0 "L2 round 1 needs neither --induced nor --pending"
rr start dm >/dev/null 2>&1
before="$(sha "$T/status.md")"
USAGE="usage: review-round.sh result <point> --blocking N [--rejected R] [--induced I] [--pending P] [--behavior M]"
out="$(rr result dm --blocking 2 --rejected 1 --pending 0 2>&1)"; rc=$?
rc_is "$rc" 2 "L2 round 2 on a tiered task without --induced -> exit 2"
has "$out" "needs --induced." "L2 ... the message names --induced"
has "$out" "$USAGE" "L2 ... and gives the usage"
out="$(rr result dm --blocking 2 --rejected 1 --induced 0 2>&1)"; rc=$?
rc_is "$rc" 2 "L2 round 2 on a tiered task without --pending -> exit 2"
has "$out" "needs --pending." "L2 ... the message names --pending"
has "$out" "$USAGE" "L2 ... and gives the usage"
out="$(rr result dm --blocking 2 --rejected 1 2>&1)"; rc=$?
rc_is "$rc" 2 "L2 round 2 without either -> exit 2"
has "$out" "needs --induced and --pending." "L2 ... the message names both"
[ "$before" = "$(sha "$T/status.md")" ] && pass "L2 ... nothing written" || fail "L2 missing --induced / --pending wrote"
for bad in "--induced 4 --pending 0" "--induced x --pending 0" "--induced -1 --pending 0" "--induced 0 --pending x" "--induced 0 --pending -1"; do
    # shellcheck disable=SC2086
    rr result dm --blocking 2 --rejected 1 $bad >/dev/null 2>&1; rc_is "$?" 2 "L2 result rejects (blocking 2 + rejected 1): $bad"
done
rr result dm --blocking 2 --induced 3 --pending 0 >/dev/null 2>&1; rc_is "$?" 2 "L2 without --rejected the bound of --induced is --blocking alone"
[ "$before" = "$(sha "$T/status.md")" ] && pass "L2 rejected values write nothing" || fail "L2 bad value wrote"
out="$(rr result dm --blocking 2 --rejected 1 --induced 3 --pending 7 --behavior 1)"; rc=$?
rc_is "$rc" 0 "L2 --induced up to blocking + rejected; --pending is a state and may exceed them"
has "$out" "round=2; started=" "L2 result prints the row"
grep -q '^- Review: point=dm; stage=design; kind=main; round=2; started=[0-9]*; blocking=2; rejected=1; behavior=1; induced=3; pending=7$' "$T/status.md" \
    && pass "L2 induced= and pending= written after behavior= (§11.4)" || fail "L2 row format" "$(grep 'point=dm.*round=2' "$T/status.md")"
rr result dm --blocking 2 --rejected 1 --induced 1 --pending 0 >/dev/null
grep -q 'round=2; started=[0-9]*; blocking=2; rejected=1; behavior=-; induced=1; pending=0$' "$T/status.md" && pass "L2 a corrected result refills the whole row" || fail "L2 correction"
mk_status "$T" ""
rr open dm --stage design >/dev/null; rr start dm >/dev/null 2>&1; rr result dm --blocking 2 >/dev/null; rr start dm >/dev/null 2>&1
rr result dm --blocking 2 >/dev/null; rc_is "$?" 0 "L2 a task without a Tier: round 2 needs neither"
rr result dm --blocking 2 --induced 3 --pending 0 >/dev/null 2>&1; rc_is "$?" 2 "L2 ... but a given value is still validated"
rr result dm --blocking 2 --pending x >/dev/null 2>&1; rc_is "$?" 2 "L2 ... --pending too"
# The needs-result refusal names the right usage.
mk_status "$T" "- Tier: standard"
rr open dm --stage design >/dev/null; rr start dm >/dev/null 2>&1
has "$(rr start dm 2>&1)" "--rejected <R> [--induced <I>] [--pending <P>]" "L2 needs-result at round 1: both optional"
rr result dm --blocking 2 >/dev/null; rr start dm >/dev/null 2>&1
has "$(rr start dm 2>&1)" "--rejected <R> --induced <I> --pending <P>" "L2 needs-result at round 2 asks for --induced and --pending"

# L3 — pending keeps `passed` shut; carried.
# pending is the point's state: blockings still waiting on a user answer,
# earlier rounds' included; the reviewer does not report them again, so a
# later round can have blocking=0 rejected=0 and still not pass.
mk_status "$T" "- Tier: standard"
rr open dm --stage design >/dev/null; rr start dm >/dev/null 2>&1
rr result dm --blocking 3 --rejected 0 --pending 2 >/dev/null
rr start dm >/dev/null 2>&1; rc_is "$?" 0 "L3 start is not held by pending"
out="$(rr result dm --blocking 0 --rejected 0 --induced 0 --pending 2)"
has "$out" "在等用户回答" "L3 result with blocking=0 rejected=0 pending=2 says the point cannot pass yet"
lacks "$out" "--outcome passed --reason" "L3 ... and gives no close hint"
before="$(sha "$T/status.md")"
out="$(rr close dm --outcome passed --reason x)"; rc=$?
rc_is "$rc" 3 "L3 close passed with blocking=0 rejected=0 pending=2 -> exit 3"
has "$out" "还有 2 条 blocking 在等用户回答" "L3 ... because blockings wait on the user"
[ "$before" = "$(sha "$T/status.md")" ] && pass "L3 ... writes nothing" || fail "L3 refused passed wrote"
rr start dm >/dev/null 2>&1; rc_is "$?" 0 "L3 start is not held by pending at round 3 either (0 reported: converged)"
rr result dm --blocking 0 --rejected 0 --induced 0 --pending 1 >/dev/null
rr close dm --outcome passed --reason x >/dev/null; rc_is "$?" 3 "L3 pending=1 still keeps passed shut"
out="$(rr result dm --blocking 0 --rejected 0 --induced 0 --pending 0)"
has "$out" "close dm --outcome passed" "L3 pending=0: result points at close --outcome passed"
rr close dm --outcome passed --reason "用户已回答，改动已复审" >/dev/null; rc_is "$?" 0 "L3 pending=0 -> passed"
mk_status "$T" "- Tier: standard"
rr open dm --stage design >/dev/null; rr start dm >/dev/null 2>&1; rr result dm --blocking 0 --rejected 0 >/dev/null
rr close dm --outcome passed --reason x >/dev/null; rc_is "$?" 0 "L3 pending=- counts as 0 -> passed"
mk_status "$T" "- Tier: standard"
rr open dm --stage design >/dev/null; rr start dm >/dev/null 2>&1; rr result dm --blocking 1 --rejected 0 --pending 1 >/dev/null
has "$(rr close dm --outcome passed --reason x)" "在等用户回答" "L3 with blocking left too, the refusal names the pending ones first"
mk_status "$T" "- Tier: standard"
rr open dm --stage design >/dev/null; rr open im --stage impl >/dev/null
rr start dm >/dev/null 2>&1; rr result dm --blocking 3 --rejected 0 >/dev/null
before="$(sha "$T/status.md")"
out="$(rr close dm --outcome carried --reason "细节类带进实现")"; rc=$?
rc_is "$rc" 3 "L3 close carried without --by user -> exit 3"
has "$out" "close dm --outcome carried --by user" "L3 ... names the command"
[ "$before" = "$(sha "$T/status.md")" ] && pass "L3 ... writes nothing" || fail "L3 refused carried wrote"
rr close dm --outcome carried --by user --reason "用户：细节类带进实现" >/dev/null; rc_is "$?" 0 "L3 close carried --by user"
grep -q '^- Review-Close: point=dm; round=1; outcome=carried; at=[0-9]*; reason=用户：细节类带进实现$' "$T/status.md" \
    && pass "L3 Review-Close row with outcome=carried" || fail "L3 carried row"
out="$(rr status)"
has "$out" "closed=carried@1" "L3 status shows the carried close"
lacks "$out" "INVALID" "L3 ... the row is valid"
has "$out" "unclosed: im" "L3 ... and the point no longer counts as unclosed"
rr start dm >/dev/null 2>&1; rc_is "$?" 3 "L3 start on a carried point -> exit 3"
out="$(gate zyz-worker:review-agent "review-point=dm round=1 mode=full")"
denied "$out" && pass "L3 gate: a carried point takes no more review dispatches" || fail "L3 gate carried" "$out"
has "$out" "已经关闭（carried）" "L3 ... and says how it was closed"
rr open dm >/dev/null; rc_is "$?" 0 "L3 a carried point can be reopened"
[ "$(rr start dm | head -1)" = "round=1 mode=full cross-harness=yes" ] && pass "L3 ... and counts from round 1 again" || fail "L3 reopen carried"

# L4 — the revision size of design rounds: snapshots, delta, growing.
# mk_docs <task-dir> <设计文档 value>: status.md with that metadata line.
mk_docs() {
    mk_status "$1" "- Tier: ${3:-strict}"
    python3 - "$1/status.md" "$2" <<'PY'
import io, sys
p, v = sys.argv[1:]
s = io.open(p, encoding="utf-8").read()
s = s.replace("- Current Phase:", "- 设计文档: %s\n- Current Phase:" % v, 1)
io.open(p, "w", encoding="utf-8").write(s)
PY
    rm -rf "$1/reviews" "$1/design"; mkdir -p "$1/design"
}
# lines <file> <first> <last>: write "<name> line <i>" for i in first..last.
lines() { local i; : > "$1"; for i in $(seq "$2" "$3"); do echo "$(basename "$1") line $i" >> "$1"; done; }
add_lines() { local i; for i in $(seq 1 "$2"); do echo "added $3 $i" >> "$1"; done; }
# start prints absolute, normalised paths ($TMPDIR may end with a slash).
SNAP="$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$T/reviews/snap")"
mk_docs "$T" '索引 `design/main.md`；分册 `design/engine.md`、design/facts.md（都在任务目录，见 `design/none.md`）'
lines "$T/design/main.md" 1 40; lines "$T/design/engine.md" 1 20; lines "$T/design/facts.md" 1 10; lines "$T/design/none.md" 1 5
rr open dm --stage design >/dev/null
out="$(rr start dm)"; rc=$?
rc_is "$rc" 0 "L4 round 1 of a design point starts"
[ "$(printf '%s\n' "$out" | sed -n 1p)" = "round=1 mode=full cross-harness=yes" ] && pass "L4 line 1 is still the round line" || fail "L4 line 1" "$out"
has "$out" "snapshot=$SNAP/dm/r1 docs=3" "L4 round 1: three documents snapshotted (the status line's list)"
lacks "$out" "delta=" "L4 round 1 has no delta"
for f in main engine facts; do
    cmp -s "$T/design/$f.md" "$SNAP/dm/r1/design/$f.md" && pass "L4 snapshot holds a copy of design/$f.md" || fail "L4 snapshot copy $f"
done
[ ! -e "$SNAP/dm/r1/design/none.md" ] && pass "L4 a path inside a full-width parenthesis is a note, not a document" || fail "L4 parenthesised path snapshotted"
grep -q 'point=dm; .*round=1; .*delta=' "$T/status.md" && fail "L4 round 1 row has no delta=" || pass "L4 round 1 row has no delta="
rr result dm --blocking 6 --rejected 0 >/dev/null
# Revision 1: +5 / -2 in main.md, +3 in engine.md.
sed -i.bak -e '3,4d' "$T/design/main.md" && rm -f "$T/design/main.md.bak"
add_lines "$T/design/main.md" 5 r2; add_lines "$T/design/engine.md" 3 r2
out="$(rr start dm)"
[ "$(printf '%s\n' "$out" | sed -n 2p)" = "delta=+8/-2 prev=- growing=no" ] && pass "L4 round 2: delta=+8/-2 prev=- growing=no" || fail "L4 round 2 delta line" "$out"
has "$out" "snapshot=$SNAP/dm/r2 docs=3" "L4 round 2 snapshot"
has "$out" "diff=$SNAP/dm/r1-r2.diff" "L4 round 2 names the diff file"
lacks "$out" "修订量在变大" "L4 round 2 has nothing to compare with: no warning"
grep -q '^+added r2 5$' "$SNAP/dm/r1-r2.diff" && grep -q '^-main.md line 3$' "$SNAP/dm/r1-r2.diff" \
    && grep -q '^--- r1/design/main.md$' "$SNAP/dm/r1-r2.diff" && grep -q '^+++ r2/design/engine.md$' "$SNAP/dm/r1-r2.diff" \
    && pass "L4 the diff file is a unified diff of the two snapshots" || fail "L4 diff file" "$(head -20 "$SNAP/dm/r1-r2.diff" 2>&1)"
grep -q "facts.md" "$SNAP/dm/r1-r2.diff" && fail "L4 an unchanged document is not in the diff" || pass "L4 an unchanged document is not in the diff"
grep -q '^- Review: point=dm; .*round=2; started=[0-9]*; blocking=-; rejected=-; behavior=-; induced=-; pending=-; delta=+8/-2$' "$T/status.md" \
    && pass "L4 the round's row carries delta=+8/-2" || fail "L4 delta field" "$(grep 'point=dm.*round=2' "$T/status.md")"
rr result dm --blocking 4 --rejected 0 --induced 1 --pending 0 >/dev/null
grep -q '^- Review: point=dm; .*round=2; .*blocking=4; rejected=0; behavior=-; induced=1; pending=0; delta=+8/-2$' "$T/status.md" \
    && pass "L4 result keeps delta= on the row" || fail "L4 delta after result" "$(grep 'point=dm.*round=2' "$T/status.md")"
# Revision 2: +8 (equal) -> not growing.
add_lines "$T/design/facts.md" 8 r3
out="$(rr start dm)"
[ "$(printf '%s\n' "$out" | sed -n 2p)" = "delta=+8/-0 prev=+8/-2 growing=no" ] && pass "L4 round 3: as many added lines as the round before -> growing=no" || fail "L4 round 3 delta line" "$out"
lacks "$out" "修订量在变大" "L4 ... no warning"
rr result dm --blocking 3 --rejected 0 --induced 1 --pending 0 >/dev/null
rr check dm --outcome continue --reason "仍在收敛" >/dev/null
# Revision 3: +9 -> growing: a warning, never a refusal.
add_lines "$T/design/main.md" 9 r4
out="$(rr start dm)"; rc=$?
rc_is "$rc" 0 "L4 a growing revision does not refuse the round"
[ "$(printf '%s\n' "$out" | sed -n 2p)" = "delta=+9/-0 prev=+8/-0 growing=yes" ] && pass "L4 round 4: more added lines than the round before -> growing=yes" || fail "L4 round 4 delta line" "$out"
has "$out" "note: 第 4 轮评审的修订新增 9 行，多于上一轮的 8 行" "L4 ... with a one-line warning"
has "$out" "修订量在变大" "L4 ... that the revision is growing"
rr result dm --blocking 2 --rejected 0 --induced 2 --pending 1 >/dev/null
out="$(rr status)"
has "$out" "  r1 blocking=6 rejected=0 induced=- pending=- delta=-
  r2 blocking=4 rejected=0 induced=1 pending=0 delta=+8/-2
  r3 blocking=3 rejected=0 induced=1 pending=0 delta=+8/-0
  r4 blocking=2 rejected=0 induced=2 pending=1 delta=+9/-0" "L4 status lists every round: blocking / rejected / induced / pending / delta"
[ "$(printf '%s\n' "$out" | tail -1)" = "unclosed: dm" ] && pass "L4 status still ends with the unclosed line" || fail "L4 status last line" "$out"
has "$(rr status dm)" "  r4 blocking=2 rejected=0 induced=2 pending=1 delta=+9/-0" "L4 status <point> lists the rounds too"
# The refusal's trend is not repeated under status (the rounds are listed once).
two_rounds "- Tier: standard" dm design 5 0 5 0
out="$(rr status)"
[ "$(printf '%s\n' "$out" | grep -c 'r2 blocking=5 ')" -eq 1 ] && pass "L4 status: a held point lists its rounds once" || fail "L4 status repeats the trend" "$out"
lacks "$out" "各轮走势" "L4 status: ... without the refusal's own trend block"
has "$out" "    (2) 带着进实现" "L4 status: the next step is indented under the point"
[ "$(printf '%s\n' "$out" | tail -1)" = "unclosed: dm" ] && pass "L4 status: last line unchanged with a held point" || fail "L4 status last line (held)"
# Path resolution. The status line: the task dir first, then cwd.
CW="$SANDBOX/cwd"; mkdir -p "$CW/design" "$SANDBOX/home/docs"
mk_docs "$T" "design/main.md, design/only-cwd.md，~/docs/home.md、$SANDBOX/abs.md"
echo "in task dir" > "$T/design/main.md"; echo "in cwd" > "$CW/design/main.md"; echo "only cwd" > "$CW/design/only-cwd.md"
echo home > "$SANDBOX/home/docs/home.md"; echo abs > "$SANDBOX/abs.md"
rr open dm --stage design >/dev/null
out="$( (cd "$CW" && HOME="$SANDBOX/home" bash "$RR" --task "$T" start dm) )"
has "$out" "docs=4" "L4 status line: comma / full-width comma / 、 separated paths all resolve"
[ "$(cat "$SNAP/dm/r1/design/main.md" 2>/dev/null)" = "in task dir" ] && pass "L4 status line: a relative path resolves against the task dir first" || fail "L4 task-dir-first"
REAL_SB="$(cd "$SANDBOX" && pwd -P)"
[ "$(cat "$SNAP/dm/r1/${REAL_SB#/}/cwd/design/only-cwd.md" 2>/dev/null)" = "only cwd" ] && pass "L4 status line: then against cwd (stored under its absolute path)" || fail "L4 cwd fallback" "$(find "$SNAP" -type f)"
[ -f "$SNAP/dm/r1/${REAL_SB#/}/home/docs/home.md" ] && pass "L4 status line: ~/ expands" || fail "L4 tilde"
[ -f "$SNAP/dm/r1/${REAL_SB#/}/abs.md" ] && pass "L4 status line: an absolute path outside the task dir" || fail "L4 absolute"
# --docs: cwd first, and it replaces the status line's list.
rr result dm --blocking 1 >/dev/null
out="$( (cd "$CW" && bash "$RR" --task "$T" start dm --docs design/main.md design/nope.md) )"; rc=$?
rc_is "$rc" 0 "L4 --docs with an unreadable path still starts the round"
has "$out" "docs=1" "L4 --docs replaces the status line's list"
has "$out" "已跳过：design/nope.md" "L4 ... and names the path it skipped"
[ "$(cat "$SNAP/dm/r2/${REAL_SB#/}/cwd/design/main.md" 2>/dev/null)" = "in cwd" ] && pass "L4 --docs: a relative path resolves against cwd first" || fail "L4 --docs cwd-first" "$(find "$SNAP/dm/r2" -type f)"
rr result dm --blocking 1 --induced 0 --pending 0 >/dev/null
out="$( (cd "$SANDBOX" && bash "$RR" --task "$T" start dm --full --reason "结构改了" --docs design/main.md) )"
has "$out" "round=3 mode=full" "L4 --docs goes with --full --reason"
[ "$(cat "$SNAP/dm/r3/design/main.md" 2>/dev/null)" = "in task dir" ] && pass "L4 --docs: then against the task dir" || fail "L4 --docs task-dir fallback"
rr result dm --blocking 1 --induced 0 --pending 0 >/dev/null
rr start dm --docs >/dev/null 2>&1; rc_is "$?" 2 "L4 --docs without a path -> exit 2"
rr start dm --docs --full --reason x >/dev/null 2>&1; rc_is "$?" 2 "L4 --docs followed by another flag -> exit 2"
# A path with a blank: the whole value is tried as one path.
mk_docs "$T" "design/my design.md"
echo spaced > "$T/design/my design.md"
rr open dm --stage design >/dev/null
has "$(rr start dm)" "docs=1" "L4 status line: a path with a blank"
# No readable document: skip, do not fail. The template's own placeholder
# names `change-note.md` inside a full-width parenthesis.
mk_docs "$T" '（标准档、严格档写设计文档路径，不列评审历史文件；快速档写 `change-note.md`）'
echo note > "$T/change-note.md"
rr open dm --stage design >/dev/null
out="$(rr start dm)"; rc=$?
rc_is "$rc" 0 "L4 the template placeholder as the document line: the round starts"
has "$out" "note: 没有找到可读的设计文档" "L4 ... with a note that nothing is measured"
[ ! -e "$SNAP" ] && pass "L4 ... and no snapshot (the parenthesised change-note.md is not a document)" || fail "L4 placeholder snapshotted" "$(find "$SNAP" -type f)"
rm -f "$T/change-note.md"
mk_status "$T" "- Tier: standard"
rr open dm --stage design >/dev/null
out="$(rr start dm)"; rc=$?
rc_is "$rc" 0 "L4 no document line at all: the round starts"
has "$out" "note: 没有找到可读的设计文档" "L4 ... same note"
# Not a design point: nothing measured, one line of output.
mk_docs "$T" "design/main.md" standard
lines "$T/design/main.md" 1 5
rr open im --stage impl >/dev/null; rr open ag --stage aggregate >/dev/null
[ "$(rr start im)" = "round=1 mode=full cross-harness=yes" ] && pass "L4 an impl point prints the round line only" || fail "L4 impl output"
[ "$(rr start ag)" = "round=1 mode=full cross-harness=yes" ] && pass "L4 an aggregate point prints the round line only" || fail "L4 aggregate output"
[ ! -e "$SNAP" ] && pass "L4 ... and takes no snapshot" || fail "L4 non-design snapshot"
rr result im --blocking 2 >/dev/null
out="$(rr start im --docs design/main.md)"; rc=$?
rc_is "$rc" 0 "L4 --docs on an impl point is accepted"
has "$out" "--docs 已忽略" "L4 ... and ignored with a note"
[ ! -e "$SNAP" ] && pass "L4 ... still no snapshot" || fail "L4 impl --docs snapshot"
# A snapshot that cannot be written must not keep the round from starting.
mk_docs "$T" "design/main.md" standard
lines "$T/design/main.md" 1 5
: > "$T/reviews"   # a file where the snapshot directory should go
rr open dm --stage design >/dev/null
out="$(rr start dm 2>&1)"; rc=$?
rc_is "$rc" 0 "L4 snapshot failure: the round still starts (fail open)"
has "$out" "round=1 mode=full cross-harness=yes" "L4 ... the round line is printed"
has "$out" "note: 设计文档快照失败" "L4 ... with a note"
grep -q '^- Review: point=dm; .*round=1;' "$T/status.md" && pass "L4 ... and the round is recorded" || fail "L4 fail-open row"
rm -f "$T/reviews"
# The round before has no snapshot: no delta this round, measured from the next.
rr result dm --blocking 3 >/dev/null
out="$(rr start dm)"
has "$out" "snapshot=$SNAP/dm/r2 docs=1" "L4 round 2 after a failed round-1 snapshot: snapshot taken"
has "$out" "note: 第 1 轮没有快照" "L4 ... no delta, with a note"
lacks "$out" "delta=" "L4 ... no delta line"
rr result dm --blocking 1 --induced 0 --pending 0 >/dev/null
add_lines "$T/design/main.md" 2 r3
[ "$(rr start dm | sed -n 2p)" = "delta=+2/-0 prev=- growing=no" ] && pass "L4 round 3 is measured against round 2" || fail "L4 round 3 after a gap"
# Leftovers of an earlier set of records do not pass for this set's snapshot.
mk_docs "$T" "design/main.md, design/engine.md" standard
lines "$T/design/main.md" 1 5; lines "$T/design/engine.md" 1 5
rr open dm --stage design >/dev/null
rr start dm >/dev/null; rr result dm --blocking 2 --rejected 0 >/dev/null
add_lines "$T/design/main.md" 2 r2
rr start dm >/dev/null; rr result dm --blocking 0 --rejected 0 --induced 0 --pending 0 >/dev/null
rr close dm --outcome passed --reason ok >/dev/null
[ -f "$SNAP/dm/r1/design/engine.md" ] && [ -d "$SNAP/dm/r2" ] && [ -f "$SNAP/dm/r1-r2.diff" ] \
    && pass "L4 (setup) the first set of records left r1/, r2/ and r1-r2.diff" || fail "L4 stale setup" "$(find "$SNAP" -type f)"
rr open dm >/dev/null
out="$(rr start dm --docs "$T/design/main.md")"
has "$out" "docs=1" "L4 reopened point: round 1 snapshots this round's list"
[ ! -e "$SNAP/dm/r1/design/engine.md" ] && pass "L4 ... a document of the earlier set's r1 does not stay in the new r1" || fail "L4 stale file in r1"
rr result dm --blocking 0 --rejected 0 >/dev/null; rr close dm --outcome passed --reason ok >/dev/null
rr open dm >/dev/null
python3 - "$T/status.md" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
io.open(p, "w", encoding="utf-8").write(s.replace("- 设计文档: design/main.md, design/engine.md\n", "- 设计文档:\n", 1))
PY
rr start dm >/dev/null
[ ! -e "$SNAP/dm/r1" ] && pass "L4 reopened point, round 1 without documents: the old r1 snapshot is removed" || fail "L4 stale r1 kept"
rr result dm --blocking 2 >/dev/null
out="$(rr start dm --docs "$T/design/main.md")"
has "$out" "note: 第 1 轮没有快照" "L4 ... so round 2 is not measured against the earlier set's r1"
lacks "$out" "delta=" "L4 ... no delta line"
[ ! -e "$SNAP/dm/r1-r2.diff" ] && pass "L4 ... and the earlier set's r1-r2.diff is gone" || fail "L4 stale diff kept"
# A document line inside an HTML comment is not the document line.
mk_status "$T" "- Tier: standard"
printf '<!--\n- 设计文档: design/main.md\n-->\n' >> "$T/status.md"
mkdir -p "$T/design"; lines "$T/design/main.md" 1 3
rr open dm --stage design >/dev/null
has "$(rr start dm)" "没有找到可读的设计文档" "L4 a document line inside an HTML comment is ignored"

# L5 — rows from before §11.4 (no rejected / induced / pending / delta).
mk_status "$T" "- Tier: standard"
python3 - "$T/status.md" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
s = s.replace("（每个评审点的轮次由 review-round.sh 写入。）\n",
              "（每个评审点的轮次由 review-round.sh 写入。）\n"
              "- Review: point=old; stage=design; kind=main; round=0; started=1700000000; blocking=-; behavior=-\n"
              "- Review: point=old; stage=design; kind=main; round=1; started=1700000001; blocking=5; rejected=1; behavior=2\n"
              "- Review: point=old; stage=design; kind=main; round=2; started=1700000002; blocking=3; behavior=-\n"
              "- Review: point=bad1; stage=design; kind=main; round=0; started=1700000000; blocking=-; behavior=-\n"
              "- Review: point=bad1; stage=design; kind=main; round=1; started=1700000001; blocking=1; behavior=-; induced=x\n"
              "- Review: point=bad2; stage=design; kind=main; round=0; started=1700000000; blocking=-; behavior=-\n"
              "- Review: point=bad2; stage=design; kind=main; round=1; started=1700000001; blocking=-; behavior=-; delta=12\n"
              "- Review: point=bad3; stage=design; kind=main; round=0; started=1700000000; blocking=-; behavior=-\n"
              "- Review: point=bad3; stage=design; kind=main; round=1; started=1700000001; blocking=-; behavior=-; pending=1\n")
io.open(p, "w", encoding="utf-8").write(s)
PY
out="$(rr status)"
has "$out" "old stage=design kind=main tier=standard round=2 blocking=3 rejected=- behavior=- history=5→3 cap=3" "L5 rows without the new fields parse"
has "$out" "  r1 blocking=5 rejected=1 induced=- pending=- delta=-
  r2 blocking=3 rejected=- induced=- pending=- delta=-" "L5 ... their missing fields read as -"
has "$out" "induced=x  <- induced must be a count or -" "L5 a bad induced value is reported"
has "$out" "delta=12  <- delta must be" "L5 a bad delta value is reported"
has "$out" "pending=1  <- pending comes with a result" "L5 pending without a result is reported"
rr start old >/dev/null 2>&1; rc_is "$?" 0 "L5 an old-format point goes on: round 3 starts (3 < 5 + 1)"
rr result old --blocking 1 --rejected 0 --induced 1 --pending 0 >/dev/null; rc_is "$?" 0 "L5 ... and takes a new-format result"
grep -qx -- '- Review: point=old; stage=design; kind=main; round=2; started=1700000002; blocking=3; behavior=-' "$T/status.md" \
    && pass "L5 the old rows are kept byte-for-byte" || fail "L5 old row rewritten"

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
for w in review-round.sh review-gate.sh ZYZ_REVIEW_GATE_DISABLE "mode=incremental" "Review-Grant" \
         "--induced" "--pending" "carried" "not-converging" "reviews/snap" "--docs" "growing=yes|no" "四选一"; do
    grep -q -- "$w" "$ROOT/hooks/README.md" && pass "K hooks/README.md documents $w" || fail "K README lacks $w"
done

echo
echo "RESULT: $PASSED/$TOTAL checks passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
