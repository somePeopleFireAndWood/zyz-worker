#!/usr/bin/env bash
#
# test-main-state.sh — UNIT + REGRESSION suite for the pure-signal main-agent
# state machine (design: .zyz-worker/tasks/main-state-machine/design.md).
#
# Covers design §Testing Plan items:
#   UNIT:       1, 2, 3, 3b, 4, 4b, 5, 6, 6b, 6c, 7
#   REGRESSION: 8, 11, 12, 12b
# The remaining items (9, 10, 13-17) live in scripts/test-main-state-e2e.sh
# because they require the genuine end-to-end watchdog run and/or the
# fixed-pack observer (genesis capability) — see that file's header.
#
# Style/harness mirrors scripts/test-notify-hook.sh and
# scripts/test-unharvested-role.sh: PASS/FAIL/SKIP per check, RESULT summary,
# tmp sandbox, exit 0 iff every check passed. macOS bash 3.2 + Linux.
#
# ---------------------------------------------------------------------------
# WHAT THIS SUITE DOES NOT PROVE (read the green checks accordingly):
#
#  * It does NOT prove the real IM command is delivered to Feishu/Telegram — the
#    "sends" cases assert only that notify.sh reached and ran its configured
#    user command (a local capturing shell command). Real webhook delivery is a
#    live-host concern with no local observation point.
#  * It does NOT prove the watchdog/stop-gate END-TO-END suppression across a
#    real 15h wait — that is scripts/test-main-state-e2e.sh (this file drives
#    the helpers and single scripts in isolation, not the whole chain).
#  * It does NOT prove subagent-death reporting under suppression — that needs
#    the fixed-pack observer and lives in the e2e file (genesis-gated; SKIPs on
#    a host without the durable GENESIS capability, e.g. stock macOS).
#  * notify.sh does NOT surface --origin into its payload/env, so origin-split
#    can only be observed at the argv boundary (fake recorder, e2e) — here the
#    origin gate is proved via the DIRECT-mode early-exit (no user command ran),
#    which is the mechanism, not via reading an origin field.
#
# Do not read a green run here as proof of any of the four claims above.
# ---------------------------------------------------------------------------

set -u
# Never reach the user's real IM (~/.zyz-worker/notify.json): checks that
# exercise the notifier point ZYZ_NOTIFY_CONFIG at their own capture config.
ZYZ_TEST_NO_NOTIFY="/nonexistent/zyz-worker-test/notify.json"
export ZYZ_NOTIFY_CONFIG="$ZYZ_TEST_NO_NOTIFY"
set -o pipefail
# zyz_task_root falls back to the session project dir; never let the invoking
# session's own dir leak a real task into this sandbox.
unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
# ...and its session identity out of the per-session pointer lookup (#23).
unset ZYZ_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CLAUDE_PID

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

json_tool() {
    command -v jq >/dev/null 2>&1 && return 0
    command -v python3 >/dev/null 2>&1 && return 0
    return 1
}

LIB="hooks/scripts/lib.sh"
HEARTBEAT="hooks/scripts/heartbeat.sh"
NOTIFY="hooks/scripts/notify.sh"
MAIN_STATE="hooks/scripts/main-state.sh"

# ===========================================================================
# 0  static layout (mirror T1/N1)
# ===========================================================================
for f in "$LIB" "$HEARTBEAT" "$NOTIFY" "$MAIN_STATE"; do
    if [ -f "$f" ]; then pass "S0 exists: $f"; else fail "S0 exists: $f" "missing"; fi
done
if [ -x "$MAIN_STATE" ]; then pass "S0 executable: $MAIN_STATE"; else fail "S0 executable: $MAIN_STATE"; fi
for f in "$HEARTBEAT" "$NOTIFY" "$MAIN_STATE"; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then pass "S0 syntax: $f"; else fail "S0 syntax: $f"; fi
done

# NO-TTL mechanical guard (design Acceptance 2): the suppression/immunity gates
# must never subtract main-state epochs. A source scan can only prove "this file
# does not phrase a now-minus-epoch on the main-state read" — it cannot prove no
# other file does; that is why the e2e no-TTL proof (13g) exists at the behavior
# layer. This guard blocks a future maintainer from reintroducing a TTL into the
# helpers themselves. If it ever fires for a legitimate reason, do NOT relax the
# regex — move the time math out of the gate.
if [ -f "$LIB" ]; then
    # Extract the two gate function bodies and assert neither does time math.
    # Comments are stripped FIRST (sed 's/#.*//') because the functions' own
    # doc lines literally say "no epoch / no-TTL" — scanning raw text would
    # match that prose and false-positive. We assert on CODE only: no epoch
    # reference, no zyz_now, no now-minus arithmetic on the main-state read.
    gate_body="$(awk '/^zyz_main_state_suppresses\(\)/{g=1} g{print} g&&/^}/{g=0}' "$LIB" | sed 's/#.*//')"
    if printf '%s' "$gate_body" | grep -Eq 'epoch|zyz_now|\$\(\(|[0-9][[:space:]]*-[[:space:]]*[0-9]'; then
        fail "S0 no-TTL: suppression/immunity gate does time math" "gate must be pure string compare (design §Important Details)"
    else
        pass "S0 no-TTL: suppression/immunity gates are pure string compare (comment-stripped code scan)"
    fi
fi

# ===========================================================================
# Shared sandbox for helper + script driving.
# ===========================================================================
SB="$(mktemp -d "${TMPDIR:-/tmp}/zyz-main-state.XXXXXX")"
cleanup() { chmod -R u+rwx "$SB" 2>/dev/null || true; rm -rf "$SB" 2>/dev/null || true; }
trap cleanup EXIT
PROJ="$SB/proj"
ROOT="$PROJ/.zyz-worker/tasks/demo-task"
mkdir -p "$ROOT"
printf 'demo-task\n' > "$PROJ/.zyz-worker/current-task"
printf '# Status\n- Current Phase: implementation\n' > "$ROOT/status.md"

STATE_FILE="$ROOT/runtime/main-state"
read_state() { head -n1 "$STATE_FILE" 2>/dev/null | awk '{print $1}'; }
read_epoch() { head -n1 "$STATE_FILE" 2>/dev/null | awk '{print $2}'; }
set_state() { # write directly via the real helper (independent of the scripts)
    ( . "$LIB" 2>/dev/null; zyz_main_state_set "$ROOT" "$1" )
}
clear_state() { rm -f "$STATE_FILE" 2>/dev/null || true; }

# ===========================================================================
# UNIT 1 — zyz_main_state_set
# ===========================================================================
echo "--- UNIT 1: zyz_main_state_set ---"
for s in working awaiting-user idle ended; do
    clear_state
    ( . "$LIB" 2>/dev/null; zyz_main_state_set "$ROOT" "$s" )
    got_state="$(read_state)"; got_epoch="$(read_epoch)"
    # Independent anchor: the state we asked to write; the epoch must be a bare
    # integer (the diagnostic field), asserted by shape not by recomputation.
    if [ "$got_state" = "$s" ]; then pass "1 set legal '$s' writes state"; else fail "1 set legal '$s'" "got [$got_state]"; fi
    case "$got_epoch" in
        ''|*[!0-9]*) fail "1 set '$s' epoch is an integer" "got [$got_epoch]" ;;
        *) pass "1 set '$s' epoch is an integer" ;;
    esac
done
# illegal value -> no write / file unchanged
set_state working
( . "$LIB" 2>/dev/null; zyz_main_state_set "$ROOT" foo )
if [ "$(read_state)" = "working" ]; then pass "1 set illegal 'foo' is a no-op (file unchanged)"; else fail "1 set illegal 'foo' no-op" "got [$(read_state)]"; fi
# illegal value with NO prior file -> still no file
clear_state
( . "$LIB" 2>/dev/null; zyz_main_state_set "$ROOT" bogus )
if [ ! -f "$STATE_FILE" ]; then pass "1 set illegal with no prior file writes nothing"; else fail "1 set illegal writes nothing" "file appeared: [$(read_state)]"; fi
# missing runtime dir -> mkdir then write
FRESH="$SB/fresh-task"
mkdir -p "$FRESH"
( . "$LIB" 2>/dev/null; zyz_main_state_set "$FRESH" idle )
if [ "$(head -n1 "$FRESH/runtime/main-state" 2>/dev/null | awk '{print $1}')" = "idle" ]; then
    pass "1 set auto-mkdir runtime then write"
else
    fail "1 set auto-mkdir runtime then write"
fi
# mkdir fail (read-only parent) -> no-op, no error (rc 0). Skip as root.
if [ "$(id -u)" = "0" ]; then
    skip "1 set read-only parent -> no-op" "running as root; chmod would not deny"
else
    RO="$SB/ro"; mkdir -p "$RO"; chmod 555 "$RO"
    rc=0
    ( . "$LIB" 2>/dev/null; zyz_main_state_set "$RO/task" working ) || rc=$?
    chmod 755 "$RO" 2>/dev/null || true
    if [ "$rc" -eq 0 ] && [ ! -e "$RO/task/runtime/main-state" ]; then
        pass "1 set read-only parent -> rc0 no-op (fail-open)"
    else
        fail "1 set read-only parent -> rc0 no-op" "rc=$rc file-exists=$([ -e "$RO/task/runtime/main-state" ] && echo yes || echo no)"
    fi
fi

# ===========================================================================
# UNIT 2 — zyz_main_state_get
# ===========================================================================
echo "--- UNIT 2: zyz_main_state_get ---"
mkdir -p "$ROOT/runtime"
printf 'idle 1700000000\n' > "$STATE_FILE"
if [ "$( . "$LIB" 2>/dev/null; zyz_main_state_get "$ROOT" )" = "idle" ]; then pass "2 get normal -> first field"; else fail "2 get normal"; fi
# missing file -> empty
clear_state
if [ -z "$( . "$LIB" 2>/dev/null; zyz_main_state_get "$ROOT" )" ]; then pass "2 get missing file -> empty"; else fail "2 get missing file -> empty"; fi
# corrupt: empty file -> empty
: > "$STATE_FILE"
if [ -z "$( . "$LIB" 2>/dev/null; zyz_main_state_get "$ROOT" )" ]; then pass "2 get empty file -> empty"; else fail "2 get empty file -> empty"; fi
# corrupt: non-whitelist first token -> empty
printf 'garbage 123\n' > "$STATE_FILE"
if [ -z "$( . "$LIB" 2>/dev/null; zyz_main_state_get "$ROOT" )" ]; then pass "2 get non-whitelist state -> empty"; else fail "2 get non-whitelist state -> empty"; fi
# corrupt: binary -> empty
printf '\000\001\002\n' > "$STATE_FILE"
if [ -z "$( . "$LIB" 2>/dev/null; zyz_main_state_get "$ROOT" )" ]; then pass "2 get binary -> empty"; else fail "2 get binary -> empty" "[$( . "$LIB" 2>/dev/null; zyz_main_state_get "$ROOT" )]"; fi
# Per design §269: the file format is `<state> <epoch>`, and get returns field 1
# (the state) — any fields AFTER the state (the epoch, plus any extra trailing
# tokens) are ignored, so a valid state with a trailing epoch and even 3+
# trailing fields yields the state, NOT empty. "Corrupt -> empty" means the
# FIRST field is non-whitelisted / the file is empty / binary (asserted above).
printf 'awaiting-user 1700000000 extra junk\n' > "$STATE_FILE"
if [ "$( . "$LIB" 2>/dev/null; zyz_main_state_get "$ROOT" )" = "awaiting-user" ]; then
    pass "2 get valid-state + trailing fields -> state (design §269: get returns field 1)"
else
    fail "2 get valid-state + trailing fields -> state" "design §269: get keeps field 1"
fi
clear_state

# ===========================================================================
# UNIT 3 / 3b — awaiting + suppresses truth tables
# ===========================================================================
echo "--- UNIT 3/3b: dialog-open + suppresses ---"
# 3 (0.32.0): zyz_user_dialog_open — awaiting-user means a dialog is open, every
# other state (and a missing one) means none; no epoch is read (not a TTL).
# The line names the dialog's owner; zyz_dialog_close_by closes it only for
# that owner, so another agent's activity never reads as "the user answered".
dialog_open() { ( . "$LIB" 2>/dev/null; zyz_user_dialog_open "$ROOT" ); }
close_by() { ( . "$LIB" 2>/dev/null; zyz_dialog_close_by "$ROOT" "$1" ); }
state_line() { cat "$STATE_FILE" 2>/dev/null; }
for line in 'awaiting-user 1700000100 main' 'awaiting-user 1700000100 a1b2' 'awaiting-user 1700000100'; do
    printf '%s\n' "$line" > "$STATE_FILE"
    dialog_open && pass "3 dialog: [$line] -> open" || fail "3 dialog: [$line] -> open"
done
for st in working idle ended; do
    printf '%s 1700000100\n' "$st" > "$STATE_FILE"
    if dialog_open; then fail "3 dialog: $st is never an open dialog" "returned 0"; else pass "3 dialog: $st is never an open dialog"; fi
done
clear_state
if dialog_open; then fail "3 dialog: missing state -> closed" "returned 0"; else pass "3 dialog: missing state -> closed"; fi
( . "$LIB" 2>/dev/null; zyz_main_state_set "$ROOT" awaiting-user )
[ "$(awk '{print $1, $3}' "$STATE_FILE")" = "awaiting-user main" ] && pass "3 owner: awaiting-user defaults to owner main" || fail "3 owner default" "line=[$(state_line)]"
( . "$LIB" 2>/dev/null; zyz_main_state_set "$ROOT" awaiting-user 'a b;c' )
[ "$(awk '{print $3}' "$STATE_FILE")" = "a_b_c" ] && [ "$(awk '{print NF}' "$STATE_FILE")" = 3 ] && pass "3 owner: sanitized to one field" || fail "3 owner sanitize" "line=[$(state_line)]"
( . "$LIB" 2>/dev/null; zyz_main_state_set "$ROOT" idle a1b2 )
[ "$(awk '{print NF}' "$STATE_FILE")" = 2 ] && pass "3 owner: only awaiting-user carries one" || fail "3 owner idle" "line=[$(state_line)]"
printf 'awaiting-user 1700000100 a1b2\n' > "$STATE_FILE"
close_by c3d4
[ "$(state_line)" = "awaiting-user 1700000100 a1b2" ] && pass "3 close_by: another agent leaves the dialog open" || fail "3 close_by other" "line=[$(state_line)]"
close_by ""
[ "$(state_line)" = "awaiting-user 1700000100 a1b2" ] && pass "3 close_by: empty id is a no-op" || fail "3 close_by empty" "line=[$(state_line)]"
close_by a1b2
[ "$(awk '{print $1}' "$STATE_FILE")" = idle ] && pass "3 close_by: the owner closes it (idle)" || fail "3 close_by owner" "line=[$(state_line)]"
printf 'awaiting-user 1700000100 main\n' > "$STATE_FILE"
close_by a1b2
[ "$(awk '{print $1}' "$STATE_FILE")" = awaiting-user ] && pass "3 close_by: a subagent never closes the main agent's dialog" || fail "3 close_by main" "line=[$(state_line)]"
printf 'awaiting-user 1700000100\n' > "$STATE_FILE"
close_by a1b2
[ "$(awk '{print $1}' "$STATE_FILE")" = awaiting-user ] && pass "3 close_by: an ownerless (pre-0.32.0) dialog is the main agent's" || fail "3 close_by legacy" "line=[$(state_line)]"
printf 'working 1700000100\n' > "$STATE_FILE"
close_by a1b2
[ "$(state_line)" = "working 1700000100" ] && pass "3 close_by: no dialog -> untouched" || fail "3 close_by working" "line=[$(state_line)]"
clear_state
if ( . "$LIB" 2>/dev/null; type zyz_main_state_awaiting >/dev/null 2>&1 ); then fail "3 zyz_main_state_awaiting removed with the Stop immunity" "still defined"; else pass "3 zyz_main_state_awaiting removed with the Stop immunity"; fi
# 3b: suppresses on {awaiting-user, idle}
for s in awaiting-user idle; do
    set_state "$s"
    if ( . "$LIB" 2>/dev/null; zyz_main_state_suppresses "$ROOT" ); then pass "3b suppresses($s) rc0"; else fail "3b suppresses($s) rc0"; fi
done
for s in working ended; do
    set_state "$s"
    if ( . "$LIB" 2>/dev/null; zyz_main_state_suppresses "$ROOT" ); then fail "3b suppresses($s) rc1" "returned 0"; else pass "3b suppresses($s) rc1"; fi
done
# empty + corrupt -> non-suppress (fail-open to full reporting)
clear_state
if ( . "$LIB" 2>/dev/null; zyz_main_state_suppresses "$ROOT" ); then fail "3b suppresses(empty) rc1 fail-open" "returned 0"; else pass "3b suppresses(empty) rc1 fail-open"; fi
printf 'garbage 1\n' > "$STATE_FILE"
if ( . "$LIB" 2>/dev/null; zyz_main_state_suppresses "$ROOT" ); then fail "3b suppresses(corrupt) rc1 fail-open" "returned 0"; else pass "3b suppresses(corrupt) rc1 fail-open"; fi
clear_state

# ===========================================================================
# UNIT 4 — main-state.sh event mapping (Stop always writes idle since 0.32.0)
# ===========================================================================
echo "--- UNIT 4: main-state.sh event mapping ---"
run_ms() { # $1 = stdin JSON ; runs the (sandbox-independent) real main-state.sh
    printf '%s' "$1" | bash "$MAIN_STATE" 2>/dev/null
}
if [ ! -x "$MAIN_STATE" ]; then
    fail "4 main-state.sh event mapping (REQUIRED)" "$MAIN_STATE missing/not executable — implement per design §新增 hooks/scripts/main-state.sh"
else
    # UserPromptSubmit -> working (unconditional)
    clear_state
    run_ms "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$PROJ\"}"
    [ "$(read_state)" = working ] && pass "4 UserPromptSubmit -> working" || fail "4 UserPromptSubmit -> working" "got [$(read_state)]"
    # SessionEnd -> ended
    clear_state
    run_ms "{\"hook_event_name\":\"SessionEnd\",\"cwd\":\"$PROJ\",\"reason\":\"logout\"}"
    [ "$(read_state)" = ended ] && pass "4 SessionEnd -> ended" || fail "4 SessionEnd -> ended" "got [$(read_state)]"
    # other event (PreToolUse) -> no write
    clear_state
    run_ms "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$PROJ\",\"tool_name\":\"Bash\"}"
    [ ! -f "$STATE_FILE" ] && pass "4 other event -> no write" || fail "4 other event -> no write" "wrote [$(read_state)]"
    # 0.32.0: no Stop immunity. A Stop ends the turn, so any dialog is closed:
    # awaiting-user + Stop -> idle.
    set_state awaiting-user
    run_ms "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
    [ "$(read_state)" = idle ] && pass "4 Stop: awaiting-user -> idle (the turn ended, so the dialog is closed)" || fail "4 Stop: awaiting-user -> idle" "got [$(read_state)]"
    # current working + Stop -> idle
    set_state working
    run_ms "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
    [ "$(read_state)" = idle ] && pass "4 Stop: working -> idle" || fail "4 Stop: working -> idle" "got [$(read_state)]"
    # no state + Stop -> idle
    clear_state
    run_ms "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
    [ "$(read_state)" = idle ] && pass "4 Stop: no-state -> idle" || fail "4 Stop: no-state -> idle" "got [$(read_state)]"
    # agent_id non-empty (subagent) -> exit 0, no write
    clear_state
    run_ms "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$PROJ\",\"agent_id\":\"sub-1\"}"
    [ ! -f "$STATE_FILE" ] && pass "4 agent_id set -> no write" || fail "4 agent_id set -> no write" "wrote [$(read_state)]"
    # no pointer -> exit 0, no write (cwd points at a dir with no current-task)
    clear_state
    NOPTR="$SB/noptr"; mkdir -p "$NOPTR"
    run_ms "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$NOPTR\"}"
    [ ! -f "$STATE_FILE" ] && pass "4 no pointer -> no write" || fail "4 no pointer -> no write" "wrote [$(read_state)]"
fi
clear_state

# ===========================================================================
# UNIT 4b — idle IM trigger from main-state.sh Stop (fake notify recorder)
# ===========================================================================
echo "--- UNIT 4b: idle IM trigger (fake notify recorder) ---"
# Build a sandbox MIRROR of hooks/ so main-state.sh calls a FAKE sibling
# notify.sh that records its exact argv. This is the ONLY observation point for
# the argv (--event idle --task-root <root>); notify.sh does not surface it
# elsewhere. main-state.sh backgrounds the call, so we sleep briefly to let the
# recorder flush (this is an async flush, NOT a real wait on any timer).
MIRROR="$SB/mirror"
mkdir -p "$MIRROR"
cp -R "$REPO_ROOT/hooks" "$MIRROR/hooks"
NOTIFY_LOG="$SB/notify-argv.log"
cat > "$MIRROR/hooks/scripts/notify.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NOTIFY_LOG"
exit 0
EOF
chmod +x "$MIRROR/hooks/scripts/notify.sh"
MIRROR_MS="$MIRROR/hooks/scripts/main-state.sh"
run_ms_mirror() { printf '%s' "$1" | bash "$MIRROR_MS" 2>/dev/null; sleep 1; }

if [ ! -x "$MIRROR_MS" ]; then
    fail "4b idle IM trigger (REQUIRED)" "$MIRROR_MS missing — implement main-state.sh"
else
    # 0.32.0 policy: an ordinary stop of an executing task pages nobody; the
    # user is paged when the task is handed to them (once per hand-off phase
    # entry) or the main agent stops at the design gate with nothing running.
    for ph in implementation review delivery; do
        : > "$NOTIFY_LOG"
        printf '# Status\n- Current Phase: %s\n' "$ph" > "$ROOT/status.md"
        set_state working
        run_ms_mirror "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
        if [ -s "$NOTIFY_LOG" ]; then fail "4b $ph Stop pages nobody" "log=[$(cat "$NOTIFY_LOG")]"; else pass "4b $ph Stop pages nobody (no idle IM)"; fi
    done
    for ph in awaiting-confirmation observing done; do
        : > "$NOTIFY_LOG"
        printf '# Status\n- Current Phase: %s\n' "$ph" > "$ROOT/status.md"
        run_ms_mirror "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
        if grep -q -- '--event completed' "$NOTIFY_LOG" && grep -qF -- "--task-root $ROOT" "$NOTIFY_LOG"; then
            pass "4b entering $ph -> completed IM"
        else
            fail "4b entering $ph -> completed IM" "log=[$(cat "$NOTIFY_LOG")]"
        fi
        : > "$NOTIFY_LOG"
        run_ms_mirror "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
        if [ -s "$NOTIFY_LOG" ]; then fail "4b a second Stop in $ph -> no repeat" "log=[$(cat "$NOTIFY_LOG")]"; else pass "4b a second Stop in $ph -> no repeat (once per entry)"; fi
    done
    printf '# Status\n- Current Phase: implementation\n' > "$ROOT/status.md"
    run_ms_mirror "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
    printf '# Status\n- Current Phase: done\n' > "$ROOT/status.md"; : > "$NOTIFY_LOG"
    run_ms_mirror "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
    if grep -q -- '--event completed' "$NOTIFY_LOG"; then pass "4b reopened then done again -> announced again"; else fail "4b re-entry" "log=[$(cat "$NOTIFY_LOG")]"; fi
    # design gate: nothing running, nothing declared -> needs_input
    printf '# Status\n- Current Phase: design\n\n## Agent State\n\n- 主 agent: x\n' > "$ROOT/status.md"; : > "$NOTIFY_LOG"
    run_ms_mirror "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\",\"background_tasks\":[],\"session_crons\":[]}"
    if grep -q -- '--event needs_input' "$NOTIFY_LOG"; then pass "4b design Stop with no executor and no declaration -> needs_input IM"; else fail "4b design gate" "log=[$(cat "$NOTIFY_LOG")]"; fi
    : > "$NOTIFY_LOG"
    run_ms_mirror "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\",\"background_tasks\":[{\"id\":\"r1\",\"type\":\"subagent\",\"status\":\"running\"}],\"session_crons\":[]}"
    if [ -s "$NOTIFY_LOG" ]; then fail "4b design Stop with a running reviewer -> no IM" "log=[$(cat "$NOTIFY_LOG")]"; else pass "4b design Stop with a running reviewer -> no IM"; fi
    : > "$NOTIFY_LOG"
    run_ms_mirror "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\"}"
    if [ -s "$NOTIFY_LOG" ]; then fail "4b design Stop, executors unknown -> no IM" "log=[$(cat "$NOTIFY_LOG")]"; else pass "4b design Stop, executors unknown (no background_tasks) -> no IM"; fi
    ( cd "$PROJ" && bash "$REPO_ROOT/hooks/scripts/expect.sh" --task "$ROOT" set gate user --reason "等批准设计" >/dev/null 2>&1 )
    : > "$NOTIFY_LOG"
    run_ms_mirror "{\"hook_event_name\":\"Stop\",\"cwd\":\"$PROJ\",\"background_tasks\":[],\"session_crons\":[]}"
    if [ -s "$NOTIFY_LOG" ]; then fail "4b design Stop with a user declaration -> no second IM" "log=[$(cat "$NOTIFY_LOG")]"; else pass "4b design Stop with a user declaration -> no fallback IM (the declaration paged)"; fi
fi
# restore active phase for later tests
printf '# Status\n- Current Phase: implementation\n' > "$ROOT/status.md"
clear_state

# ===========================================================================
# UNIT 5 — notify.sh hook mode -> awaiting-user mapping
# ===========================================================================
echo "--- UNIT 5: notify.sh hook mode -> awaiting-user ---"
if ! json_tool; then
    skip "5 notify.sh awaiting-user mapping" "no jq/python3"
else
    # Point config at a NON-existent file: the awaiting-user write is placed
    # BEFORE the config gate, so state must still be written with no notify.json.
    export ZYZ_NOTIFY_CONFIG="$SB/does-not-exist.json"
    rm -f "$ZYZ_NOTIFY_CONFIG"
    feed_notify() { printf '%s' "$1" | bash "$NOTIFY" 2>/dev/null; }
    for nt in permission_prompt agent_needs_input elicitation_dialog elicitation_url_dialog; do
        clear_state
        feed_notify "{\"hook_event_name\":\"Notification\",\"notification_type\":\"$nt\",\"cwd\":\"$PROJ\"}"
        if [ "$(read_state)" = awaiting-user ]; then pass "5 $nt -> awaiting-user"; else fail "5 $nt -> awaiting-user" "got [$(read_state)] (write must precede config gate)"; fi
    done
    # 0.32.0: idle_prompt ("finished ~60 s ago, you haven't typed") follows EVERY
    # Stop; it is not a dialog, so it records idle — even over a stale
    # awaiting-user — and never awaiting-user.
    set_state awaiting-user
    feed_notify "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$PROJ\"}"
    if [ "$(read_state)" = idle ]; then pass "5 idle_prompt -> idle (not a dialog)"; else fail "5 idle_prompt -> idle" "got [$(read_state)] (write must precede config gate)"; fi
    # agent_completed -> NOT awaiting-user (pre-seed working, must stay working)
    set_state working
    feed_notify "{\"hook_event_name\":\"Notification\",\"notification_type\":\"agent_completed\",\"cwd\":\"$PROJ\"}"
    if [ "$(read_state)" = working ]; then pass "5 agent_completed -> NOT awaiting-user (stays working)"; else fail "5 agent_completed leaves state" "got [$(read_state)]"; fi
    # non-needs-input types -> NOT awaiting-user
    for nt in auth_success elicitation_complete elicitation_response quota_exceeded; do
        set_state working
        feed_notify "{\"hook_event_name\":\"Notification\",\"notification_type\":\"$nt\",\"cwd\":\"$PROJ\"}"
        if [ "$(read_state)" = working ]; then pass "5 $nt -> NOT awaiting-user"; else fail "5 $nt -> NOT awaiting-user" "got [$(read_state)]"; fi
    done
    export ZYZ_NOTIFY_CONFIG="$ZYZ_TEST_NO_NOTIFY"
fi
clear_state

# ===========================================================================
# UNIT 6 / 6b / 6c / 12b — notify.sh direct mode: stuck origin split, set -u,
# idle event, backward compat. Observed via a capturing user command: the
# command RUNS iff notify.sh reached the config-gate/dispatch (i.e. did NOT
# early-exit on the suppression gate). Empty capture == suppressed.
# ===========================================================================
echo "--- UNIT 6/6b/6c/12b: notify.sh direct mode ---"
if ! json_tool; then
    skip "6 notify.sh direct-mode gating" "no jq/python3"
else
    CAP="$SB/cap.txt"
    CFG="$SB/notify.json"
    export ZYZ_NOTIFY_CONFIG="$CFG"
    # Capturing command: prints the event category then the payload. No double
    # quotes so it embeds in JSON without escaping (mirrors test-notify-hook.sh).
    CMD="{ printf 'EV=%s ' \$ZYZ_NOTIFY_EVENT; cat; echo; } >> $CAP"
    write_cfg() { printf '%s\n' "$1" > "$CFG"; }
    reset_cap() { : > "$CAP"; rm -f "$ROOT"/runtime/nag/notify-*.last 2>/dev/null || true; }

    write_cfg "{\"enabled\":true,\"command\":\"$CMD\",\"cooldown_sec\":0}"

    # 6: main-origin stuck in suppress state -> exit 0, command NOT run
    for s in awaiting-user idle; do
        set_state "$s"; reset_cap
        bash "$NOTIFY" --event stuck --origin main --task-root "$ROOT" --message "m" 2>/dev/null
        [ ! -s "$CAP" ] && pass "6 stuck --origin main + $s -> suppressed (no IM cmd)" || fail "6 stuck main + $s suppressed" "cap=[$(cat "$CAP")]"
        # omitted --origin defaults to main -> also suppressed
        reset_cap
        bash "$NOTIFY" --event stuck --task-root "$ROOT" --message "m" 2>/dev/null
        [ ! -s "$CAP" ] && pass "6 stuck (no --origin=main default) + $s -> suppressed" || fail "6 stuck default-origin + $s suppressed" "cap=[$(cat "$CAP")]"
    done
    # 6: subagent-origin stuck in suppress state -> NOT suppressed, command runs
    for s in awaiting-user idle; do
        set_state "$s"; reset_cap
        bash "$NOTIFY" --event stuck --origin subagent --task-root "$ROOT" --message "role dead" 2>/dev/null
        if grep -q 'EV=stuck ' "$CAP" 2>/dev/null; then pass "6 stuck --origin subagent + $s -> sent (bypasses suppression, F2)"; else fail "6 stuck subagent + $s sent" "cap=[$(cat "$CAP")]"; fi
    done
    # 6: any origin + working -> sent
    for o in main subagent; do
        set_state working; reset_cap
        bash "$NOTIFY" --event stuck --origin "$o" --task-root "$ROOT" --message "m" 2>/dev/null
        if grep -q 'EV=stuck ' "$CAP" 2>/dev/null; then pass "6 stuck --origin $o + working -> sent"; else fail "6 stuck $o + working sent" "cap=[$(cat "$CAP")]"; fi
    done

    # 6b: set -u safety — direct stuck + main + working must NOT crash on unbound
    # hook_event/ntype (never assigned in direct mode). Assert rc 0 AND no
    # "unbound variable" on stderr. This is the F1(b) mutation guard.
    set_state working; reset_cap
    ERRF="$SB/err.txt"; : > "$ERRF"
    rc=0
    bash "$NOTIFY" --event stuck --origin main --task-root "$ROOT" --message "m" 2>"$ERRF" || rc=$?
    if [ "$rc" -eq 0 ] && ! grep -qi 'unbound variable' "$ERRF" 2>/dev/null; then
        pass "6b set -u: direct stuck+main+working reaches gate without unbound-variable crash"
    else
        fail "6b set -u direct stuck no crash" "rc=$rc err=[$(cat "$ERRF")]"
    fi

    # 6c (0.32.0): the per-Stop `idle` IM is retired — the category is no
    # longer accepted, even when a config lists it.
    write_cfg "{\"enabled\":true,\"command\":\"$CMD\",\"cooldown_sec\":0,\"events\":[\"idle\",\"stuck\"]}"
    set_state idle; reset_cap
    bash "$NOTIFY" --event idle --task-root "$ROOT" 2>/dev/null
    if [ -s "$CAP" ]; then fail "6c --event idle is retired" "cap=[$(cat "$CAP")]"; else pass "6c --event idle is retired (nothing sent)"; fi
    write_cfg "{\"enabled\":true,\"command\":\"$CMD\",\"cooldown_sec\":0}"
    reset_cap
    printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"%s"}' "$PROJ" | bash "$NOTIFY" 2>/dev/null
    sleep 0.3
    if [ -s "$CAP" ]; then fail "6c idle_prompt pages nobody" "cap=[$(cat "$CAP")]"; else pass "6c idle_prompt pages nobody (it only moves main-state)"; fi
    printf '{"hook_event_name":"StopFailure","agent_id":"a1","error":"rate_limit","cwd":"%s"}' "$PROJ" | bash "$NOTIFY" 2>/dev/null
    if [ -s "$CAP" ]; then fail "6c a subagent StopFailure pages nobody" "cap=[$(cat "$CAP")]"; else pass "6c a subagent StopFailure pages nobody (the watchdog tells the main agent)"; fi
    printf '{"hook_event_name":"StopFailure","error":"billing_error","cwd":"%s"}' "$PROJ" | bash "$NOTIFY" 2>/dev/null
    if grep -q 'EV=failed ' "$CAP" 2>/dev/null; then pass "6c the main agent's StopFailure pages (nothing will resume it)"; else fail "6c main StopFailure" "cap=[$(cat "$CAP")]"; fi

    # 12b: backward compat — a caller that passes NO --origin, non-suppress
    # state, still sends stuck exactly as before the origin change.
    write_cfg "{\"enabled\":true,\"command\":\"$CMD\",\"cooldown_sec\":0}"
    set_state working; reset_cap
    bash "$NOTIFY" --event stuck --task-root "$ROOT" --message "legacy caller" 2>/dev/null
    if grep -q 'EV=stuck ' "$CAP" 2>/dev/null; then pass "12b no --origin + working -> stuck sent (backward compat)"; else fail "12b backward compat stuck sent" "cap=[$(cat "$CAP")]"; fi

    export ZYZ_NOTIFY_CONFIG="$ZYZ_TEST_NO_NOTIFY"
fi
clear_state

# ===========================================================================
# UNIT 7 — heartbeat.sh main branch writes working; subagent does not
# ===========================================================================
echo "--- UNIT 7: heartbeat.sh main branch ---"
if ! json_tool; then
    skip "7 heartbeat main branch" "no jq/python3"
else
    clear_state
    printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash"}' "$PROJ" | bash "$HEARTBEAT" 2>/dev/null
    [ "$(read_state)" = working ] && pass "7 main heartbeat (agent_id empty) -> working" || fail "7 main heartbeat -> working" "got [$(read_state)]"
    # main PreToolUse(AskUserQuestion) -> awaiting-user (no Notification needed)
    set_state working
    printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"AskUserQuestion"}' "$PROJ" | bash "$HEARTBEAT" 2>/dev/null
    [ "$(read_state)" = awaiting-user ] && pass "7 main PreToolUse(AskUserQuestion) -> awaiting-user" || fail "7 main PreToolUse(AskUserQuestion) -> awaiting-user" "got [$(read_state)]"
    # main PostToolUse(AskUserQuestion) (user answered) -> working
    printf '{"hook_event_name":"PostToolUse","cwd":"%s","tool_name":"AskUserQuestion"}' "$PROJ" | bash "$HEARTBEAT" 2>/dev/null
    [ "$(read_state)" = working ] && pass "7 main PostToolUse(AskUserQuestion) -> working" || fail "7 main PostToolUse(AskUserQuestion) -> working" "got [$(read_state)]"
    # subagent PreToolUse(AskUserQuestion) -> does NOT write main-state
    clear_state
    printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"AskUserQuestion","agent_id":"sub-1","agent_type":"implementation-agent"}' "$PROJ" | bash "$HEARTBEAT" 2>/dev/null
    [ ! -f "$STATE_FILE" ] && pass "7 subagent PreToolUse(AskUserQuestion) -> no main-state write" || fail "7 subagent AskUserQuestion no main-state" "wrote [$(read_state)]"
    # subagent (agent_id set) -> does NOT write main-state
    clear_state
    printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","agent_id":"sub-1","agent_type":"implementation-agent"}' "$PROJ" | bash "$HEARTBEAT" 2>/dev/null
    [ ! -f "$STATE_FILE" ] && pass "7 subagent heartbeat -> no main-state write" || fail "7 subagent heartbeat no main-state" "wrote [$(read_state)]"

    # 7c: payload cwd drifted into a pointer-less subdir (the agent `cd`-ed into
    # the task dir). The hooks must still resolve the task via the session
    # project dir, the same dir the watchdog resolves from; otherwise main-state
    # freezes and the watchdog nags through the whole wait.
    DRIFT="$ROOT"
    clear_state
    printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"AskUserQuestion"}' "$DRIFT" \
        | CLAUDE_PROJECT_DIR="$PROJ" bash "$HEARTBEAT" 2>/dev/null
    [ "$(read_state)" = awaiting-user ] && pass "7c drifted cwd + project dir: PreToolUse(AskUserQuestion) -> awaiting-user" || fail "7c drifted cwd AskUserQuestion" "got [$(read_state)]"
    set_state working
    printf '{"hook_event_name":"Stop","cwd":"%s"}' "$DRIFT" | CLAUDE_PROJECT_DIR="$PROJ" bash "$MAIN_STATE" 2>/dev/null
    [ "$(read_state)" = idle ] && pass "7c drifted cwd + project dir: Stop -> idle" || fail "7c drifted cwd Stop -> idle" "got [$(read_state)]"
    # control: without a project dir the drifted cwd resolves nothing (no-op)
    set_state working
    printf '{"hook_event_name":"Stop","cwd":"%s"}' "$DRIFT" | bash "$MAIN_STATE" 2>/dev/null
    [ "$(read_state)" = working ] && pass "7c control: drifted cwd without project dir -> no-op" || fail "7c control no-op" "got [$(read_state)]"
    # a cwd with its own pointer still wins over the project dir
    OTHER="$SB/other"; mkdir -p "$OTHER/.zyz-worker/tasks/other-task"
    printf 'other-task\n' > "$OTHER/.zyz-worker/current-task"
    set_state working
    printf '{"hook_event_name":"Stop","cwd":"%s"}' "$OTHER" | CLAUDE_PROJECT_DIR="$PROJ" bash "$MAIN_STATE" 2>/dev/null
    if [ "$(read_state)" = working ] && [ "$(head -n1 "$OTHER/.zyz-worker/tasks/other-task/runtime/main-state" 2>/dev/null | awk '{print $1}')" = idle ]; then
        pass "7c cwd pointer takes precedence over project dir"
    else
        fail "7c cwd pointer precedence" "proj=[$(read_state)]"
    fi
fi
clear_state

# ===========================================================================
# REGRESSION 8 — zyz_status_waiting OR-arm still suppresses status-stale with
# NO main-state file (via stop-gate-main.sh, cross-platform: needs no observer).
# ===========================================================================
echo "--- REGRESSION 8: Waiting On OR-arm still works ---"
if ! command -v python3 >/dev/null 2>&1; then
    skip "8 Waiting On OR-arm" "no python3"
else
    R8="$SB/r8/.zyz-worker/tasks/t8"; mkdir -p "$R8/runtime"
    printf 't8\n' > "$SB/r8/.zyz-worker/current-task"
    now="$( . "$LIB" 2>/dev/null; zyz_now )"
    since=$((now - 60)); nxt=$((now + 600))
    {
        printf '# Status\n- Current Phase: implementation\n\n'
        printf '## Agent State\n'
        printf -- '- Waiting On: instance-key=a; since-epoch=%s; next-check-epoch=%s; reason=valid\n' "$since" "$nxt"
    } > "$R8/status.md"
    touch -t 202001010000 "$R8/status.md" 2>/dev/null || true
    clear_state  # no main-state file for t8 either
    rm -f "$R8/runtime/main-state"
    # No stale roles on macOS (observer inert) -> only the status-stale clause
    # could fire; the valid Waiting On must suppress it -> no block.
    out8="$(printf '{"cwd":"%s","stop_hook_active":false,"background_tasks":[]}' "$SB/r8" | ZYZ_STOP_STATUS_STALE_SEC=1 bash hooks/scripts/stop-gate-main.sh 2>/dev/null)"
    if ! printf '%s' "$out8" | grep -q '分钟没有更新'; then pass "8 valid Waiting On suppresses status-stale (no main-state)"; else fail "8 Waiting On suppresses status-stale" "$out8"; fi
    # Positive control: remove the Waiting On line -> status-stale REAPPEARS
    printf '# Status\n- Current Phase: implementation\n' > "$R8/status.md"
    touch -t 202001010000 "$R8/status.md" 2>/dev/null || true
    out8b="$(printf '{"cwd":"%s","stop_hook_active":false,"background_tasks":[]}' "$SB/r8" | ZYZ_STOP_STATUS_STALE_SEC=1 bash hooks/scripts/stop-gate-main.sh 2>/dev/null)"
    if printf '%s' "$out8b" | grep -q '分钟没有更新'; then pass "8 control: no Waiting On -> status-stale reappears"; else fail "8 control status-stale reappears" "gate may be vacuous: $out8b"; fi
fi

# ===========================================================================
# REGRESSION 11 — hooks.json wiring: new entries added, existing NOT removed.
# ===========================================================================
echo "--- REGRESSION 11: hooks.json wiring unchanged + additions ---"
if ! json_tool; then
    skip "11 hooks.json wiring" "no jq/python3"
else
    HJ="hooks/hooks.json"
    check11="$(python3 - "$HJ" <<'PY' 2>/dev/null || true
import json,sys
d=json.load(open(sys.argv[1]))
h=d.get("hooks",{})
def cmds(ev):
    out=[]
    for g in (h.get(ev) or []):
        for hook in g.get("hooks",[]):
            out.append(hook.get("command") or "")
    return out
res=[]
# UserPromptSubmit newly registers main-state.sh
res.append("ups-main-state" if any("main-state.sh" in c for c in cmds("UserPromptSubmit")) else "!ups-main-state")
# Stop still has stop-gate-main.sh AND now main-state.sh
sc=cmds("Stop")
res.append("stop-gate" if any("stop-gate-main.sh" in c for c in sc) else "!stop-gate")
res.append("stop-main-state" if any("main-state.sh" in c for c in sc) else "!stop-main-state")
# SessionEnd still has notify.sh AND now main-state.sh
se=cmds("SessionEnd")
res.append("se-notify" if any("notify.sh" in c for c in se) else "!se-notify")
res.append("se-main-state" if any("main-state.sh" in c for c in se) else "!se-main-state")
# Existing mounts NOT moved: heartbeat on PreToolUse/PostToolUse, status-freshness, scope-guard
res.append("hb-pre" if any("heartbeat.sh" in c for c in cmds("PreToolUse")) else "!hb-pre")
res.append("hb-post" if any("heartbeat.sh" in c for c in cmds("PostToolUse")) else "!hb-post")
allc=[c for ev in h for g in (h.get(ev) or []) for hook in g.get("hooks",[]) for c in [hook.get("command") or ""]]
res.append("status-freshness" if any("status-freshness.sh" in c for c in allc) else "!status-freshness")
res.append("scope-guard" if any("dispatch-scope-guard.sh" in c for c in allc) else "!scope-guard")
print(" ".join(res))
PY
)"
    for tok in ups-main-state stop-gate stop-main-state se-notify se-main-state hb-pre hb-post status-freshness scope-guard; do
        case " $check11 " in
            *" $tok "*) pass "11 hooks.json: $tok present" ;;
            *) fail "11 hooks.json: $tok" "got [$check11]" ;;
        esac
    done
fi

# ===========================================================================
# REGRESSION 12 — ZYZ_HOOKS_DISABLE=1 -> all state writes no-op.
# ===========================================================================
echo "--- REGRESSION 12: ZYZ_HOOKS_DISABLE=1 no-ops ---"
if ! json_tool; then
    skip "12 ZYZ_HOOKS_DISABLE" "no jq/python3"
else
    # heartbeat.sh
    clear_state
    printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash"}' "$PROJ" | ZYZ_HOOKS_DISABLE=1 bash "$HEARTBEAT" 2>/dev/null
    [ ! -f "$STATE_FILE" ] && pass "12 heartbeat.sh disabled -> no write" || fail "12 heartbeat disabled no write" "wrote [$(read_state)]"
    # notify.sh (hook mode Notification)
    clear_state
    export ZYZ_NOTIFY_CONFIG="$SB/does-not-exist.json"
    printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"%s"}' "$PROJ" | ZYZ_HOOKS_DISABLE=1 bash "$NOTIFY" 2>/dev/null
    [ ! -f "$STATE_FILE" ] && pass "12 notify.sh disabled -> no awaiting-user write" || fail "12 notify disabled no write" "wrote [$(read_state)]"
    export ZYZ_NOTIFY_CONFIG="$ZYZ_TEST_NO_NOTIFY"
    # main-state.sh
    if [ -x "$MAIN_STATE" ]; then
        clear_state
        printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s"}' "$PROJ" | ZYZ_HOOKS_DISABLE=1 bash "$MAIN_STATE" 2>/dev/null
        [ ! -f "$STATE_FILE" ] && pass "12 main-state.sh disabled -> no write" || fail "12 main-state disabled no write" "wrote [$(read_state)]"
    else
        fail "12 main-state.sh disabled -> no write" "$MAIN_STATE missing"
    fi
fi
clear_state

echo
if [ "$SKIPPED" -gt 0 ]; then
    echo "RESULT: $PASSED/$TOTAL checks passed ($SKIPPED skipped)"
else
    echo "RESULT: $PASSED/$TOTAL checks passed"
fi
[ "$FAILED" -eq 0 ]
