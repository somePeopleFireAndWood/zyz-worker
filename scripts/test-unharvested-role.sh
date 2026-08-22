#!/usr/bin/env bash
#
# test-unharvested-role.sh — tests for the L3/L4 "terminal-but-unharvested
# subagent role" detection (task watchdog-unharvested-role).
#
# SCOPE / WHY A SEPARATE FILE: scripts/test-watchdog-hooks.sh is frozen and in
# active concurrent use by another task; this suite is standalone and touches
# nothing it owns. It exercises ONLY the two new inline python filters:
#   - L4 (primary):  hooks/scripts/stop-gate-main.sh  (unharvested_roles=... filter)
#   - L3 (backup):   monitors/watchdog.sh             (runtime_events=... filter)
# plus the shared cooldown primitive (hooks/scripts/lib.sh zyz_cooldown_ok).
#
# HOW: the exact python filter TEXT is extracted at run time from the two
# production files (see extract_filter) — so these tests bind to the real
# shipped code, not a hand-copied duplicate, and would fail if the production
# filter diverges. Each filter is fed fabricated observer JSON on stdin and its
# stdout asserted byte-exact. Killing mutations are applied by transforming the
# extracted text (sed) and re-running: a mutation that does not change the
# asserted output would be UNKILLED and is recorded as such honestly.
#
# STRUCTURAL COVERAGE CEILING (registered, not silently omitted):
#   - These tests drive the FILTER LOGIC with fabricated JSON directly. They do
#     NOT exercise the real observer (zyz_runtime_observe / runtime_state.py
#     hook-observe) nor the macOS-vs-Linux capability split. On Darwin the real
#     observer returns genesis-capability-unavailable, so the whole detector is
#     INERT (same boundary as the existing dead-role scan); the fabricated-JSON
#     path here works on ANY platform because it bypasses the observer. What is
#     proven: predicate correctness, guard safety, message wiring, cooldown.
#     What is NOT proven here: the observer emits terminal_epoch on the real
#     terminal paths (that lives in runtime_state.py + its own checks), and the
#     end-to-end "notification dropped in a live session" event (not reproducible
#     in a harness).
#
# MUTATION MANIFEST (each mechanism -> mutation -> expected result):
#   M1  boundary <= : flip both `<=` to `<`      -> boundary case (equality) FLIPS flagged->empty  [KILLED, L4+L3]
#   M2  status conjunct : drop `and status_mtime<=te` -> case (c) wrongly FLAGS                     [KILLED, L4+L3]
#   M3  main_hb conjunct: drop `main_hb<=te and `     -> case (b) wrongly FLAGS                     [KILLED, L4+L3]
#   M4  L3 epoch guard  : delete isinstance(main_hb/te) guard -> case (h) None<=int throws, shared
#                         loop aborts, co-present NON-terminal stale event LOST                     [KILLED, L3]
#   M5  L4 te guard     : delete `if not isinstance(te,int):continue` -> case (h-L4) throws, whole
#                         loop aborts, co-present VALID terminal flag LOST                          [KILLED, L4]
#   M6  L4 main_hb guard: delete top `sys.exit(0)` guard -> case (g1) output UNCHANGED (empty either
#                         way; single-purpose filter + outer except:pass MASK it)                   [UNKILLED, recorded]
# A full manifest is also written to
#   .zyz-worker/tasks/watchdog-unharvested-role/subtasks/test-mutation-manifest.md
#
# Usage:  bash scripts/test-unharvested-role.sh
# Exits 0 iff every check passed; prints PASS/FAIL and a RESULT summary line.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
cd "$REPO_ROOT" || { echo "FATAL: cannot cd into '$REPO_ROOT'" >&2; exit 2; }

L4_FILE="hooks/scripts/stop-gate-main.sh"
L3_FILE="monitors/watchdog.sh"
LIB_FILE="hooks/scripts/lib.sh"

TOTAL=0; PASSED=0; FAILED=0; SKIPPED=0
pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); echo "PASS  $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); echo "FAIL  $1${2:+ — $2}"; }
skip() { TOTAL=$((TOTAL+1)); SKIPPED=$((SKIPPED+1)); echo "SKIP  $1${2:+ — $2}"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP  all — python3 unavailable"; echo "RESULT: 0/0 checks passed (all skipped)"; exit 0; }

# --- Filter extraction -----------------------------------------------------
# Pull the EXACT inline python body shipped in production, so the tests bind to
# the real code. The body is the run of lines between the `python3 -c '` opener
# (identified by its assignment anchor) and the closing `'` line that passes the
# trailing argv. awk prints strictly the lines in between.
extract_l4() { # -> L4 python body (unharvested_roles filter in stop-gate-main.sh)
    awk '
        /unharvested_roles="\$\(printf/ {grab=1; next}
        grab && /^'"'"' "\$status_mtime"/ {grab=0}
        grab {print}
    ' "$L4_FILE"
}
extract_l3() { # -> L3 python body (runtime_events filter in watchdog.sh)
    awk '
        /runtime_events="\$\(printf/ {grab=1; next}
        grab && /^'"'"' "\$ROLE_STALE"/ {grab=0}
        grab {print}
    ' "$L3_FILE"
}

L4_BODY="$(extract_l4)"
L3_BODY="$(extract_l3)"

# Sanity: the extraction must have captured a non-trivial body containing the
# load-bearing predicate. If production is refactored so the anchors move, these
# guards fail loudly rather than the whole suite silently passing on empty input.
if printf '%s' "$L4_BODY" | grep -q 'terminal_epoch' \
    && printf '%s' "$L4_BODY" | grep -q 'main_hb<=te and status_mtime<=te'; then
    pass "extract: L4 filter body captured with predicate"
else
    fail "extract: L4 filter body captured with predicate" "anchors moved in $L4_FILE"
fi
if printf '%s' "$L3_BODY" | grep -q 'unharvested' \
    && printf '%s' "$L3_BODY" | grep -q 'main_hb<=te and status_mtime<=te'; then
    pass "extract: L3 filter body captured with predicate"
else
    fail "extract: L3 filter body captured with predicate" "anchors moved in $L3_FILE"
fi

# --- Filter runners --------------------------------------------------------
# run_l4 <body> <json> <status_mtime>            -> filter stdout
run_l4() { printf '%s' "$2" | python3 -c "$1" "$3" 2>/dev/null; }
# run_l3 <body> <json> <stale> <horizon> <now> <status_mtime> -> filter stdout
run_l3() { printf '%s' "$2" | python3 -c "$1" "$3" "$4" "$5" "$6" 2>/dev/null; }

# assert_eq <label> <expected> <actual>
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}
# assert_empty <label> <actual>
assert_empty() { if [ -z "$2" ]; then pass "$1"; else fail "$1" "expected empty, got [$2]"; fi }
# assert_contains <label> <needle> <haystack>
assert_contains() {
    case "$3" in *"$2"*) pass "$1";; *) fail "$1" "missing [$2] in [$3]";; esac
}
# assert_not_contains <label> <needle> <haystack>
assert_not_contains() {
    case "$3" in *"$2"*) fail "$1" "unexpected [$2] in [$3]";; *) pass "$1";; esac
}

TAB="$(printf '\t')"

# ===========================================================================
# Fixtures. Fixed epochs: terminal_epoch (te) = 1000. L3 scan args below.
# ===========================================================================
L3_STALE=1200; L3_HORIZON=21600; L3_NOW=100000

# (a) terminal + main idle since + no status since -> FLAGGED
J_A='{"ok":true,"state":"observed","main_heartbeat_epoch":900,"instances":[{"instance_key":"k-impl-1","role":"implementationAgent","terminal":true,"terminal_epoch":1000}]}'
# (b) terminal but main acted after completion (main_hb > te) -> NOT flagged
J_B='{"ok":true,"state":"observed","main_heartbeat_epoch":1100,"instances":[{"instance_key":"k-impl-1","role":"implementationAgent","terminal":true,"terminal_epoch":1000}]}'
# (c) terminal but status written after completion (status_mtime > te) -> NOT flagged
J_C='{"ok":true,"state":"observed","main_heartbeat_epoch":900,"instances":[{"instance_key":"k-impl-1","role":"implementationAgent","terminal":true,"terminal_epoch":1000}]}'
# (d) non-terminal stale role -> existing branch, NOT unharvested
J_D='{"ok":true,"state":"observed","main_heartbeat_epoch":900,"instances":[{"instance_key":"k-test-1","role":"testAgent","terminal":false,"tracking_capability":"armed","last_liveness_epoch":95000}]}'
# (e) observer error / not observed -> fail open
J_E1='{"ok":false}'
J_E2='{"ok":true,"state":"error","instances":[{"instance_key":"k","role":"r","terminal":true,"terminal_epoch":1000}]}'
# (g1) main_heartbeat_epoch None -> guarded, no throw, no event
J_G1='{"ok":true,"state":"observed","main_heartbeat_epoch":null,"instances":[{"instance_key":"k-impl-1","role":"implementationAgent","terminal":true,"terminal_epoch":1000}]}'
# (g2) terminal_epoch None -> guarded, no throw, no event
J_G2='{"ok":true,"state":"observed","main_heartbeat_epoch":900,"instances":[{"instance_key":"k-impl-1","role":"implementationAgent","terminal":true,"terminal_epoch":null}]}'
# boundary: main_hb == te == status_mtime == 1000 -> FLAGGED (<= fail-toward-flag)
J_BND='{"ok":true,"state":"observed","main_heartbeat_epoch":1000,"instances":[{"instance_key":"k-impl-1","role":"implementationAgent","terminal":true,"terminal_epoch":1000}]}'
# (h-L3) MIXED, bad-terminal FIRST then non-terminal stale: guard must let the
# loop reach the stale instance. Order is load-bearing for the M4 mutation.
J_H_L3='{"ok":true,"state":"observed","main_heartbeat_epoch":900,"instances":[{"instance_key":"k-bad","role":"reviewAgent","terminal":true,"terminal_epoch":null},{"instance_key":"k-test-1","role":"testAgent","terminal":false,"tracking_capability":"armed","last_liveness_epoch":95000}]}'
# (h-L4) MIXED, bad-terminal FIRST then a VALID terminal-unharvested: guard must
# let the loop reach the valid one. Order is load-bearing for the M5 mutation.
J_H_L4='{"ok":true,"state":"observed","main_heartbeat_epoch":900,"instances":[{"instance_key":"k-bad","role":"reviewAgent","terminal":true,"terminal_epoch":null},{"instance_key":"k-impl-1","role":"implementationAgent","terminal":true,"terminal_epoch":1000}]}'

L4_FLAG_A="k-impl-1${TAB}implementationAgent"
L4_FLAG_VALID="k-impl-1${TAB}implementationAgent"
L3_FLAG_A="unharvested${TAB}k-impl-1${TAB}implementationAgent${TAB}0${TAB}-"

echo "--- L4 (stop-gate-main.sh, primary) truth table ---"
assert_eq    "L4 (a) FLAGGED"                 "$L4_FLAG_A" "$(run_l4 "$L4_BODY" "$J_A" 900)"
assert_empty "L4 (b) main acted after -> none" "$(run_l4 "$L4_BODY" "$J_B" 900)"
assert_empty "L4 (c) status after -> none"     "$(run_l4 "$L4_BODY" "$J_C" 1100)"
assert_empty "L4 (d) non-terminal -> none"     "$(run_l4 "$L4_BODY" "$J_D" 900)"
assert_empty "L4 (e1) ok:false -> none"        "$(run_l4 "$L4_BODY" "$J_E1" 900)"
assert_empty "L4 (e2) state:error -> none"     "$(run_l4 "$L4_BODY" "$J_E2" 900)"
assert_empty "L4 (g1) main_hb None -> none"    "$(run_l4 "$L4_BODY" "$J_G1" 900)"
assert_empty "L4 (g2) te None -> none"         "$(run_l4 "$L4_BODY" "$J_G2" 900)"
assert_eq    "L4 boundary (==) FLAGGED"        "$L4_FLAG_A" "$(run_l4 "$L4_BODY" "$J_BND" 1000)"
# (h-L4): only the valid terminal flags; the missing-te one is skipped, not fatal.
H_L4_OUT="$(run_l4 "$L4_BODY" "$J_H_L4" 900)"
assert_eq    "L4 (h) mixed: valid flag survives" "$L4_FLAG_VALID" "$H_L4_OUT"
assert_not_contains "L4 (h) bad-terminal not emitted" "k-bad" "$H_L4_OUT"

echo "--- L3 (watchdog.sh, backup) truth table ---"
assert_eq    "L3 (a) FLAGGED"                 "$L3_FLAG_A" "$(run_l3 "$L3_BODY" "$J_A" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 900)"
assert_empty "L3 (b) main acted after -> none" "$(run_l3 "$L3_BODY" "$J_B" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 900)"
assert_empty "L3 (c) status after -> none"     "$(run_l3 "$L3_BODY" "$J_C" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 1100)"
# (d) non-terminal: L3 routes to the existing stale branch (NOT unharvested).
D_L3_OUT="$(run_l3 "$L3_BODY" "$J_D" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 900)"
assert_contains     "L3 (d) non-terminal -> stale branch"      "stale${TAB}k-test-1" "$D_L3_OUT"
assert_not_contains "L3 (d) non-terminal not unharvested"      "unharvested"         "$D_L3_OUT"
assert_empty "L3 (e1) ok:false -> none"        "$(run_l3 "$L3_BODY" "$J_E1" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 900)"
assert_empty "L3 (e2) state:error -> none"     "$(run_l3 "$L3_BODY" "$J_E2" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 900)"
assert_empty "L3 (g1) main_hb None -> none"    "$(run_l3 "$L3_BODY" "$J_G1" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 900)"
assert_empty "L3 (g2) te None -> none"         "$(run_l3 "$L3_BODY" "$J_G2" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 900)"
assert_eq    "L3 boundary (==) FLAGGED"        "$L3_FLAG_A" "$(run_l3 "$L3_BODY" "$J_BND" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 1000)"
# (h-L3): guarded terminal is skipped; the co-present non-terminal stale STILL emits.
H_L3_OUT="$(run_l3 "$L3_BODY" "$J_H_L3" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 900)"
assert_contains     "L3 (h) mixed: non-terminal stale survives" "stale${TAB}k-test-1" "$H_L3_OUT"
assert_not_contains "L3 (h) mixed: bad-terminal not emitted"    "k-bad"               "$H_L3_OUT"

echo "--- (f) cooldown suppresses a second emission ---"
# The filters themselves are stateless; suppression is the caller's
# zyz_cooldown_ok gate. Both layers use it: L3 a per-key file
# runtime/nag/watchdog-unharvested-<key>.last; L4 the shared runtime/nag/stopgate.last.
# Verify the shared primitive: first call opens (rc 0), an immediate second is
# suppressed (rc 1) within the window; a distinct key is independent.
COOL_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/zyz-unharv-cool.XXXXXX")"
cleanup_cool() { rm -rf "$COOL_SANDBOX"; }
trap cleanup_cool EXIT
if ( . "$LIB_FILE" 2>/dev/null
     nag="$COOL_SANDBOX/runtime/nag/watchdog-unharvested-k-impl-1.last"
     zyz_cooldown_ok "$nag" 900 ) ; then
    pass "(f) L3 first emission opens cooldown (rc 0)"
else
    fail "(f) L3 first emission opens cooldown (rc 0)"
fi
if ( . "$LIB_FILE" 2>/dev/null
     nag="$COOL_SANDBOX/runtime/nag/watchdog-unharvested-k-impl-1.last"
     zyz_cooldown_ok "$nag" 900 ) ; then
    fail "(f) L3 second emission within window suppressed (rc 1)" "expected rc 1"
else
    pass "(f) L3 second emission within window suppressed (rc 1)"
fi
if ( . "$LIB_FILE" 2>/dev/null
     nag="$COOL_SANDBOX/runtime/nag/watchdog-unharvested-k-OTHER.last"
     zyz_cooldown_ok "$nag" 900 ) ; then
    pass "(f) L3 distinct key has independent cooldown (rc 0)"
else
    fail "(f) L3 distinct key has independent cooldown (rc 0)"
fi
# L4 shared stopgate token: a prior stale-role block within the window suppresses
# the unharvested block (design Risks note — accepted, shared runtime/nag/stopgate.last).
( . "$LIB_FILE" 2>/dev/null; zyz_cooldown_ok "$COOL_SANDBOX/runtime/nag/stopgate.last" 600 ) >/dev/null 2>&1
if ( . "$LIB_FILE" 2>/dev/null
     zyz_cooldown_ok "$COOL_SANDBOX/runtime/nag/stopgate.last" 600 ) ; then
    fail "(f) L4 shared stopgate token suppresses within window" "expected rc 1"
else
    pass "(f) L4 shared stopgate token suppresses within window"
fi

# ===========================================================================
# KILLING MUTATIONS. Each transforms the extracted filter body and re-runs the
# case that the mechanism protects; a mutation is KILLED iff the case output
# CHANGES. An unchanged output is reported as UNKILLED (honest, not hidden).
# ===========================================================================
echo "--- Killing mutations ---"

# M1: boundary <= -> <  (L4 + L3). Boundary case (all epochs == te) must flip
# FLAGGED -> empty.
M_L4="$(printf '%s' "$L4_BODY" | sed 's/main_hb<=te and status_mtime<=te/main_hb<te and status_mtime<te/')"
if [ "$(run_l4 "$M_L4" "$J_BND" 1000)" != "$L4_FLAG_A" ]; then
    pass "M1 L4 boundary <=->< KILLED (equality no longer flags)"
else
    fail "M1 L4 boundary <=->< KILLED"
fi
M_L3="$(printf '%s' "$L3_BODY" | sed 's/main_hb<=te and status_mtime<=te/main_hb<te and status_mtime<te/')"
if [ "$(run_l3 "$M_L3" "$J_BND" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 1000)" != "$L3_FLAG_A" ]; then
    pass "M1 L3 boundary <=->< KILLED (equality no longer flags)"
else
    fail "M1 L3 boundary <=->< KILLED"
fi

# M2: drop the status_mtime conjunct (L4 + L3). Case (c) (status written after
# completion) must WRONGLY flag under the mutant -> mutation KILLED.
M_L4="$(printf '%s' "$L4_BODY" | sed 's/main_hb<=te and status_mtime<=te/main_hb<=te/')"
if [ "$(run_l4 "$M_L4" "$J_C" 1100)" = "$L4_FLAG_A" ]; then
    pass "M2 L4 drop status conjunct KILLED (case c wrongly flags)"
else
    fail "M2 L4 drop status conjunct KILLED"
fi
M_L3="$(printf '%s' "$L3_BODY" | sed 's/main_hb<=te and status_mtime<=te/main_hb<=te/')"
if [ "$(run_l3 "$M_L3" "$J_C" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 1100)" = "$L3_FLAG_A" ]; then
    pass "M2 L3 drop status conjunct KILLED (case c wrongly flags)"
else
    fail "M2 L3 drop status conjunct KILLED"
fi

# M3: drop the main_hb conjunct (L4 + L3). Case (b) (main acted after) must
# WRONGLY flag under the mutant -> mutation KILLED.
M_L4="$(printf '%s' "$L4_BODY" | sed 's/main_hb<=te and status_mtime<=te/status_mtime<=te/')"
if [ "$(run_l4 "$M_L4" "$J_B" 900)" = "$L4_FLAG_A" ]; then
    pass "M3 L4 drop main_hb conjunct KILLED (case b wrongly flags)"
else
    fail "M3 L4 drop main_hb conjunct KILLED"
fi
M_L3="$(printf '%s' "$L3_BODY" | sed 's/main_hb<=te and status_mtime<=te/status_mtime<=te/')"
if [ "$(run_l3 "$M_L3" "$J_B" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 900)" = "$L3_FLAG_A" ]; then
    pass "M3 L3 drop main_hb conjunct KILLED (case b wrongly flags)"
else
    fail "M3 L3 drop main_hb conjunct KILLED"
fi

# M4: remove the L3 epoch isinstance guard. On the MIXED fixture J_H_L3 the
# first (bad, te=null) terminal instance now hits `900<=None` -> TypeError ->
# outer except:pass aborts the WHOLE loop -> the co-present non-terminal stale
# event (k-test-1) is LOST. This is the case (h) regression the guard prevents.
M_L3="$(printf '%s' "$L3_BODY" | sed '/if not isinstance(main_hb,int) or not isinstance(te,int):continue/d')"
M4_OUT="$(run_l3 "$M_L3" "$J_H_L3" "$L3_STALE" "$L3_HORIZON" "$L3_NOW" 900)"
case "$M4_OUT" in
    *"stale${TAB}k-test-1"*) fail "M4 L3 remove epoch guard KILLED" "stale event survived (guard not load-bearing?)";;
    *)                       pass "M4 L3 remove epoch guard KILLED (mixed case h loses co-present stale event)";;
esac
# Positive control: unmutated body keeps the co-present event on the SAME fixture.
case "$H_L3_OUT" in
    *"stale${TAB}k-test-1"*) pass "M4 control: unmutated L3 keeps co-present stale event";;
    *)                       fail "M4 control: unmutated L3 keeps co-present stale event" "$H_L3_OUT";;
esac

# M5: remove the L4 terminal_epoch isinstance guard. On the MIXED fixture J_H_L4
# the first (bad, te=null) terminal instance now hits `900<=None` -> TypeError ->
# outer except:pass aborts the whole filter -> the co-present VALID unharvested
# flag (k-impl-1) is LOST.
M_L4="$(printf '%s' "$L4_BODY" | sed '/if not isinstance(te,int):continue/d')"
M5_OUT="$(run_l4 "$M_L4" "$J_H_L4" 900)"
if [ "$M5_OUT" != "$L4_FLAG_VALID" ]; then
    pass "M5 L4 remove te guard KILLED (mixed case h loses valid flag)"
else
    fail "M5 L4 remove te guard KILLED" "valid flag survived (guard not load-bearing?)"
fi
# Positive control: unmutated body keeps the valid flag on the SAME fixture.
assert_eq "M5 control: unmutated L4 keeps valid flag" "$L4_FLAG_VALID" "$H_L4_OUT"

# M6: remove the L4 top-level main_hb guard (`sys.exit(0)`). Case (g1) main_hb=None
# is UNKILLED and recorded so: this filter's only job is unharvested detection,
# so on (g1) the correct output is empty; without the guard the None reaches
# `None<=te` -> TypeError -> outer except:pass -> still empty. The guard is an
# early-exit optimization, not the sole thing making (g1) safe (the outer
# except:pass is a second net). Recorded UNKILLED honestly (manifest M6). The
# guard's OBSERVABLE value would show only if a downstream instance in the same
# loop should have emitted after a None main_hb — but main_hb is a top-level
# field shared by all instances, so no such divergence exists. This SKIP marks
# that the mutation is deliberately not claimed as killed.
M_L4="$(printf '%s' "$L4_BODY" | sed '/if not isinstance(main_hb,int):sys.exit(0)/d')"
M6_OUT="$(run_l4 "$M_L4" "$J_G1" 900)"
if [ -z "$M6_OUT" ]; then
    skip "M6 L4 remove main_hb sys.exit guard" "UNKILLED-by-design: outer except:pass masks it, output empty either way (see manifest)"
else
    pass "M6 L4 remove main_hb sys.exit guard KILLED (unexpectedly observable — even better)"
fi

echo "----------------------------------------------------------------------"
echo "RESULT: $PASSED/$TOTAL checks passed$([ "$SKIPPED" -gt 0 ] && printf ' (%d skipped)' "$SKIPPED")"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
