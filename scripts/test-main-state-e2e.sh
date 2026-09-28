#!/usr/bin/env bash
#
# test-main-state-e2e.sh — END-TO-END acceptance for the pure-signal main-agent
# state machine (design: .zyz-worker/tasks/main-state-machine/design.md).
#
# Covers design §Testing Plan E2E items 13, 14, 15, 15b, 16, 17 plus the
# observer-dependent regression items 9 and 10 (which need the same fixed-pack
# fixture as 15). It drives the REAL scripts across a real temp task-dir + real
# .zyz-worker/current-task pointer, injects epoch/mtime instead of ever really
# waiting, and runs the watchdog one shot (ZYZ_WATCHDOG_ONCE=1).
#
# OBSERVATION MECHANISM:
#   * A sandbox MIRROR of hooks/ + monitors/ is built with notify.sh REPLACED by
#     a fake recorder that appends its argv (incl --event / --origin) to
#     $ZYZ_FAKE_NOTIFY_LOG. The watchdog and main-state.sh under test resolve
#     their sibling/relative notify.sh to this fake, so we observe the EXACT
#     origin split and the idle-IM call at the argv boundary — the only place
#     --origin is visible (notify.sh never surfaces it into payload/env).
#   * State WRITES that must go through the real notify.sh awaiting-user path
#     (13c) use the REAL repo notify.sh; the fake only intercepts the stuck/idle
#     DELIVERY side.
#   * Epoch is injected by rewriting runtime/main-state directly (the no-TTL
#     proof: gating is a string compare, so any epoch — 15h ago or now — yields
#     the same verdict).
#
# ---------------------------------------------------------------------------
# WHAT THIS SUITE DOES NOT PROVE (do not read greens as these):
#   * NOT real IM/webhook delivery — the fake recorder proves the CALL was made
#     with the right args; whether Feishu/Telegram received it is a live-host
#     concern with no local observation point. 17c exercises the real notify.sh
#     send path up to running the user command, still local.
#   * The subagent-death-under-suppression cases (9/10/15/15b) require the
#     fixed-pack observer's durable GENESIS capability. On a host without it
#     (stock macOS returns genesis-capability-unavailable) the WHOLE detector is
#     inert, so those cases SKIP with the capability named — a green macOS run
#     does NOT prove subagent reporting; only a GENESIS-capable host (Linux CI)
#     does. This is the same ceiling as scripts/test-unharvested-role.sh.
#   * F3 main-agent tool-hang blind spot is a DESIGN-ACCEPTED gap (no TTL): there
#     is deliberately no test that a hung main agent is reported in suppress
#     state, because by design it is not.
# ---------------------------------------------------------------------------

set -u
# Keep the invoking session's project dir out of zyz_task_root's fallback.
unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
cd "$REPO_ROOT" || { echo "FATAL: cannot cd into '$REPO_ROOT'" >&2; exit 2; }

TOTAL=0; PASSED=0; FAILED=0; SKIPPED=0
pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); echo "PASS  $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); echo "FAIL  $1${2:+ — $2}"; }
skip() { TOTAL=$((TOTAL+1)); SKIPPED=$((SKIPPED+1)); echo "SKIP  $1${2:+ — $2}"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP  all — python3 unavailable"; echo "RESULT: 0/0 checks passed (all skipped)"; exit 0; }

LIB="$REPO_ROOT/hooks/scripts/lib.sh"
NOTIFY="$REPO_ROOT/hooks/scripts/notify.sh"
STOP_GATE="$REPO_ROOT/hooks/scripts/stop-gate-main.sh"
SUBAGENT_TRACK="$REPO_ROOT/hooks/scripts/subagent-track.sh"
RUNTIME_CLI="$REPO_ROOT/hooks/scripts/agent-runtime-state.sh"

# genesis-availability oracle (copied verbatim from test-watchdog-hooks.sh so
# these tests SKIP — never silently pass — when the observer is inert).
fixed_observer_genesis_unavailable() { # rc json task-dir include-no-output
    [ "$1" -eq 4 ] || return 1
    printf '%s' "$2" | python3 -c 'import json,sys
try:x=json.load(sys.stdin)
except Exception:raise SystemExit(1)
err=x.get("error")
ok=(x.get("ok") is False and x.get("state")=="error" and
 isinstance(err,dict) and err.get("code")=="genesis-capability-unavailable")
raise SystemExit(0 if ok else 1)'
}

# ===========================================================================
# Fixture
# ===========================================================================
SB="$(mktemp -d "${TMPDIR:-/tmp}/zyz-main-state-e2e.XXXXXX")"
cleanup() { chmod -R u+rwx "$SB" 2>/dev/null || true; rm -rf "$SB" 2>/dev/null || true; }
trap cleanup EXIT

PROJ="$SB/proj"
ROOT="$PROJ/.zyz-worker/tasks/demo-task"
mkdir -p "$ROOT/runtime"
printf 'demo-task\n' > "$PROJ/.zyz-worker/current-task"
STATE_FILE="$ROOT/runtime/main-state"

# sandbox mirror with the fake recorder notify.sh
MIRROR="$SB/mirror"
mkdir -p "$MIRROR"
cp -R "$REPO_ROOT/hooks" "$MIRROR/hooks"
cp -R "$REPO_ROOT/monitors" "$MIRROR/monitors"
cat > "$MIRROR/hooks/scripts/notify.sh" <<'EOF'
#!/usr/bin/env bash
# Fake recorder: capture argv (incl --event/--origin), never deliver.
printf '%s\n' "$*" >> "${ZYZ_FAKE_NOTIFY_LOG:?ZYZ_FAKE_NOTIFY_LOG unset}"
exit 0
EOF
chmod +x "$MIRROR/hooks/scripts/notify.sh"
MIRROR_MS="$MIRROR/hooks/scripts/main-state.sh"
MIRROR_HB="$MIRROR/hooks/scripts/heartbeat.sh"
MIRROR_WD="$MIRROR/monitors/watchdog.sh"
NOTIFY_LOG="$SB/notify-argv.log"
: > "$NOTIFY_LOG"

read_state() { head -n1 "$STATE_FILE" 2>/dev/null | awk '{print $1}'; }
now_epoch() { ( . "$LIB" 2>/dev/null; zyz_now ); }
age_state() { # $1 state, $2 seconds-ago
    mkdir -p "$ROOT/runtime"
    printf '%s %s\n' "$1" "$(( $(now_epoch) - $2 ))" > "$STATE_FILE"
}
set_phase_old() { # $1 phase ; NO Waiting On line so suppression is attributable
    printf '# Status\n- Current Phase: %s\n' "$1" > "$ROOT/status.md"
    touch -t 202001010000 "$ROOT/status.md" 2>/dev/null || true
}
# main-state.sh via mirror (fake notify) — used when we must observe idle IM /
# stuck delivery; backgrounds notify so flush with a short sleep (async flush,
# not a real timer wait). CRITICAL: export ZYZ_FAKE_NOTIFY_LOG so the notify.sh
# that main-state.sh BACKGROUNDS from its idle-IM path inherits it and actually
# records — otherwise the recorder aborts on the unset var and every idle-IM
# assertion (17a positive AND the 16 / 17-design negatives) reads an empty log,
# making the negatives pass vacuously.
ms() { printf '%s' "$1" | ZYZ_FAKE_NOTIFY_LOG="$NOTIFY_LOG" bash "$MIRROR_MS" 2>/dev/null; sleep 1; }
# watchdog one-shot via mirror; COOLDOWN=0 so emissions are deterministic across
# repeated runs (the per-key nag cooldown otherwise hides the 2nd emission).
WD_OUT=""
run_wd() {
    : > "$NOTIFY_LOG"
    WD_OUT="$(ZYZ_WATCHDOG_ONCE=1 ZYZ_WATCHDOG_STATUS_STALE_SEC=1 \
        ZYZ_WATCHDOG_ROLE_STALE_SEC=1 ZYZ_ROLE_STALE_HORIZON_SEC=21600 \
        ZYZ_WATCHDOG_COOLDOWN_SEC=0 ZYZ_FAKE_NOTIFY_LOG="$NOTIFY_LOG" \
        bash "$MIRROR_WD" "$PROJ" 2>/dev/null)"
    sleep 1
}
run_stop_gate() { # $1 extra env pairs applied inline; prints stdout
    printf '{"cwd":"%s","stop_hook_active":false,"background_tasks":[]}' "$PROJ" \
        | ZYZ_STOP_STATUS_STALE_SEC=1 ZYZ_ROLE_STALE_SEC=1 ZYZ_STOP_GATE_COOLDOWN_SEC=0 \
          bash "$STOP_GATE" 2>/dev/null
}

REQ_OK=1
for f in "$MIRROR_MS" "$MIRROR_HB" "$MIRROR_WD"; do
    if [ ! -x "$f" ]; then fail "E0 required script present+exec: $f" "missing — implement per design"; REQ_OK=0; fi
done

# ===========================================================================
# 13 — wait scenario (simulate 15h), core no-TTL invariant
# ===========================================================================
echo "--- E2E 13: wait scenario (no-TTL) ---"
set_phase_old implementation
# 13a UserPromptSubmit -> working
ms "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$PROJ\"}"
[ "$(read_state)" = working ] && pass "13a UserPromptSubmit -> working" || fail "13a UserPromptSubmit -> working" "got [$(read_state)]"
# 13b main PreToolUse heartbeat -> working. Clear state FIRST so this is an
# independent proof that the heartbeat itself writes working, not a pass
# corroborated by 13a's prior write (mechanism also covered by unit 7).
rm -f "$STATE_FILE" 2>/dev/null || true
printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash"}' "$PROJ" | bash "$MIRROR_HB" 2>/dev/null
[ "$(read_state)" = working ] && pass "13b main heartbeat -> working" || fail "13b main heartbeat -> working" "got [$(read_state)]"
# 13c Notification(permission_prompt) via REAL notify.sh -> awaiting-user
export ZYZ_NOTIFY_CONFIG="$SB/no-config.json"; rm -f "$ZYZ_NOTIFY_CONFIG"
printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"%s"}' "$PROJ" | bash "$NOTIFY" 2>/dev/null
[ "$(read_state)" = awaiting-user ] && pass "13c Notification(permission_prompt) -> awaiting-user" || fail "13c Notification -> awaiting-user" "got [$(read_state)] (awaiting-user write must precede config gate)"
# 13d force epoch to 15h ago; status.md already old + active + NO Waiting On
age_state awaiting-user 54000
# 13e watchdog one shot -> NO status-stale stdout, NO main-origin stuck
run_wd
if printf '%s' "$WD_OUT" | grep -qi 'status file'; then fail "13e watchdog suppresses status-stale stdout" "$WD_OUT"; else pass "13e watchdog: NO status-stale stdout in awaiting-user"; fi
if grep -q -- '--origin main' "$NOTIFY_LOG" 2>/dev/null; then fail "13e no main-origin stuck IM" "log=[$(cat "$NOTIFY_LOG")]"; else pass "13e watchdog: NO main-origin notify_stuck recorded"; fi
# 13f stop-gate -> status-stale clause absent from any block reason
out13f="$(run_stop_gate)"
if printf '%s' "$out13f" | grep -qi 'status file'; then fail "13f stop-gate omits status-stale clause" "$out13f"; else pass "13f stop-gate: status-stale clause absent under awaiting-user"; fi
# 13g no-TTL: verdict independent of how old (or new) the epoch is
g_fail=0
for ep in 54000 999999999 0; do
    age_state awaiting-user "$ep"
    run_wd
    printf '%s' "$WD_OUT" | grep -qi 'status file' && g_fail=1
done
# also an epoch in the "future"/near-now: still awaiting-user -> still suppressed
printf 'awaiting-user %s\n' "$(( $(now_epoch) + 100 ))" > "$STATE_FILE"
run_wd
printf '%s' "$WD_OUT" | grep -qi 'status file' && g_fail=1
[ "$g_fail" -eq 0 ] && pass "13g no-TTL: suppression independent of epoch (string compare only)" || fail "13g no-TTL invariant" "an epoch value changed the verdict"

# ===========================================================================
# 14 — recovery (MANDATORY positive control: the gate is not vacuous)
# ===========================================================================
echo "--- E2E 14: recovery positive control ---"
# user answers: UserPromptSubmit -> working, status.md STILL old
ms "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$PROJ\"}"
[ "$(read_state)" = working ] && pass "14 recovery: UserPromptSubmit -> working" || fail "14 recovery -> working" "got [$(read_state)]"
run_wd
if printf '%s' "$WD_OUT" | grep -qi 'status file'; then pass "14 status-stale stdout REAPPEARS under working (gate not vacuous)"; else fail "14 status-stale reappears under working" "gate may be vacuous: [$WD_OUT]"; fi
if grep -q -- '--origin main' "$NOTIFY_LOG" 2>/dev/null; then pass "14 main-origin notify_stuck recorded under working (positive control)"; else fail "14 main-origin stuck recorded under working" "log=[$(cat "$NOTIFY_LOG")]"; fi

# ===========================================================================
# 9 / 10 / 15 / 15b — subagent death still reported under suppression;
# subagent-origin stuck IM bypasses, main-origin suppressed.
# Requires the fixed-pack observer (GENESIS). SKIPs when inert.
# ===========================================================================
echo "--- E2E 9/10/15/15b: subagent death under suppression ---"
printf '{"cwd":"%s","hook_event_name":"SubagentStart","agent_id":"waiting-stale","agent_type":"implementation-agent"}' "$PROJ" \
    | bash "$SUBAGENT_TRACK" 2>/dev/null
obs="$(bash "$RUNTIME_CLI" hook-observe "$ROOT" true 2>/dev/null)"; obs_rc=$?
if fixed_observer_genesis_unavailable "$obs_rc" "$obs" "$ROOT" true; then
    skip "15 subagent death stdout under suppression" "requires durable GENESIS capability (observer inert on this host)"
    skip "15b subagent-origin stuck IM bypass" "requires durable GENESIS capability"
    skip "9 stop-gate still blocks stale role under suppression" "requires durable GENESIS capability"
    skip "10 watchdog subagent finding stdout under suppression" "requires durable GENESIS capability"
elif [ "$obs_rc" -ne 0 ] || ! printf '%s' "$obs" | python3 -c 'import json,sys;x=json.load(sys.stdin);raise SystemExit(0 if x.get("ok") is True and x.get("state")=="observed" else 1)'; then
    fail "15 observer prerequisite" "observer rc=$obs_rc out=$obs"
    fail "15b observer prerequisite" "observer rc=$obs_rc out=$obs"
    fail "9 observer prerequisite" "observer rc=$obs_rc out=$obs"
    fail "10 observer prerequisite" "observer rc=$obs_rc out=$obs"
else
    sleep 2  # bounded ageing so ROLE_STALE_SEC=1 fires (mirrors T13)
    set_phase_old implementation
    for st in awaiting-user idle; do
        age_state "$st" 54000
        # 10/15 watchdog: subagent stdout present, status-stale absent
        run_wd
        if printf '%s' "$WD_OUT" | grep -q 'waiting-stale'; then pass "10/15 ($st) subagent death stdout STILL emitted"; else fail "10/15 ($st) subagent stdout emitted" "$WD_OUT"; fi
        if printf '%s' "$WD_OUT" | grep -qi 'status file'; then fail "15 ($st) status-stale still suppressed" "$WD_OUT"; else pass "15 ($st) status-stale still suppressed alongside subagent report"; fi
        # 15b origin split at argv boundary
        if grep -q -- '--origin subagent' "$NOTIFY_LOG" 2>/dev/null; then pass "15b ($st) subagent-origin stuck IM recorded (bypasses suppression, F2)"; else fail "15b ($st) subagent-origin stuck recorded" "log=[$(cat "$NOTIFY_LOG")]"; fi
        if grep -q -- '--origin main' "$NOTIFY_LOG" 2>/dev/null; then fail "15b ($st) main-origin stuck suppressed" "unexpected: [$(cat "$NOTIFY_LOG")]"; else pass "15b ($st) main-origin stuck IM suppressed"; fi
        # 9 stop-gate: role still blocks, status-stale clause absent
        out9="$(run_stop_gate)"
        if printf '%s' "$out9" | grep -q 'waiting-stale'; then pass "9 ($st) stop-gate STILL blocks stale role (A-scope)"; else fail "9 ($st) stop-gate blocks stale role" "$out9"; fi
        if printf '%s' "$out9" | grep -qi 'status file'; then fail "9 ($st) stop-gate status-stale clause absent" "$out9"; else pass "9 ($st) stop-gate status-stale clause absent under suppression"; fi
    done
fi

# ===========================================================================
# 16 — Stop overwrite immunity e2e
# ===========================================================================
echo "--- E2E 16: Stop overwrite immunity ---"
set_phase_old implementation
age_state awaiting-user 54000
: > "$NOTIFY_LOG"
ms "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
[ "$(read_state)" = awaiting-user ] && pass "16 Stop keeps awaiting-user (immunity)" || fail "16 Stop keeps awaiting-user" "got [$(read_state)]"
if grep -q -- '--event idle' "$NOTIFY_LOG" 2>/dev/null; then fail "16 no idle IM on immunity" "unexpected: [$(cat "$NOTIFY_LOG")]"; else pass "16 no idle IM fired on immunity"; fi
run_wd
if printf '%s' "$WD_OUT" | grep -qi 'status file'; then fail "16 still no status-stale after immune Stop" "$WD_OUT"; else pass "16 still no status-stale after immune Stop"; fi
# Positive control (mirrors test 14 discipline): the SAME recorder DOES capture
# an idle IM when one should fire (working+Stop, active) — proves the "no idle
# IM on immunity" negative above is NON-vacuous (recorder + idle-IM path live).
set_phase_old implementation
age_state working 54000
: > "$NOTIFY_LOG"
ms "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
if grep -q -- '--event idle' "$NOTIFY_LOG" 2>/dev/null; then pass "16 control: recorder DOES capture idle IM when fired (16 immunity negative non-vacuous)"; else fail "16 control: recorder captures idle IM when fired" "recorder dead -> 16 negative vacuous: [$(cat "$NOTIFY_LOG")]"; fi

# ===========================================================================
# 17 — idle IM e2e (F4)
# ===========================================================================
echo "--- E2E 17: idle IM (F4) ---"
# (a) working + Stop (active) -> idle + idle IM recorded
set_phase_old implementation
age_state working 54000
: > "$NOTIFY_LOG"
ms "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
[ "$(read_state)" = idle ] && pass "17a working+Stop(active) -> idle" || fail "17a -> idle" "got [$(read_state)]"
if grep -q -- '--event idle' "$NOTIFY_LOG" 2>/dev/null && grep -qF -- "--task-root $ROOT" "$NOTIFY_LOG" 2>/dev/null; then
    pass "17a idle IM recorded: notify.sh --event idle --task-root <root>"
else
    fail "17a idle IM recorded" "log=[$(cat "$NOTIFY_LOG")]"
fi
# (b) watchdog with old status -> status-stale suppressed (idle suppresses, F4)
run_wd
if printf '%s' "$WD_OUT" | grep -qi 'status file'; then fail "17b idle suppresses status-stale" "$WD_OUT"; else pass "17b idle suppresses status-stale stdout (F4)"; fi
# (c) real notify.sh idle send path with a minimal enabled notify.json incl idle
CAP17="$SB/cap17.txt"; CFG17="$SB/notify17.json"; : > "$CAP17"
CMD17="{ printf 'EV=%s ' \$ZYZ_NOTIFY_EVENT; cat; echo; } >> $CAP17"
printf '{"enabled":true,"command":"%s","cooldown_sec":0,"events":["idle"]}\n' "$CMD17" > "$CFG17"
rm -f "$ROOT"/runtime/nag/notify-idle.last 2>/dev/null || true
ZYZ_NOTIFY_CONFIG="$CFG17" bash "$NOTIFY" --event idle --task-root "$ROOT" 2>/dev/null
if grep -q 'EV=idle ' "$CAP17" 2>/dev/null; then pass "17c real notify.sh idle send path fires user command"; else fail "17c idle send path" "cap=[$(cat "$CAP17")]"; fi
# design phase + Stop -> NO idle IM. Paired positive control FIRST (mirrors
# test 14 discipline): an active-phase Stop on the SAME recorder must record the
# idle IM, proving the design-phase negative below is non-vacuous.
set_phase_old implementation
age_state working 54000
: > "$NOTIFY_LOG"
ms "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
if grep -q -- '--event idle' "$NOTIFY_LOG" 2>/dev/null; then pass "17 control: active-phase Stop records idle IM (design-phase negative non-vacuous)"; else fail "17 control: active-phase Stop records idle IM" "recorder dead -> design negative vacuous: [$(cat "$NOTIFY_LOG")]"; fi
set_phase_old design
age_state working 54000
: > "$NOTIFY_LOG"
ms "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
if grep -q -- '--event idle' "$NOTIFY_LOG" 2>/dev/null; then fail "17 design phase -> no idle IM" "unexpected: [$(cat "$NOTIFY_LOG")]"; else pass "17 design (non-active) phase Stop -> NO idle IM"; fi

unset ZYZ_NOTIFY_CONFIG 2>/dev/null || true

echo
if [ "$SKIPPED" -gt 0 ]; then
    echo "RESULT: $PASSED/$TOTAL checks passed ($SKIPPED skipped)"
else
    echo "RESULT: $PASSED/$TOTAL checks passed"
fi
[ "$FAILED" -eq 0 ]
