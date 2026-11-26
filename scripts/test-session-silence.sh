#!/usr/bin/env bash
#
# test-session-silence.sh — the 0.32.0 liveness floor of the watchdog:
#   * L0 heartbeat.sh stamps runtime/activity for every caller (main agent,
#     subagent, teammate) — no fixed-pack capability, no role-name matcher;
#   * L3 monitors/watchdog.sh scan_declarations (5) session silence: an active
#     task with work left whose whole session has not moved for silence-sec,
#     with nothing declared and no dialog open;
#   * hooks/scripts/api-failure.sh records StopFailure, and the L3
#     scan_failures turns subagent / teammate records into one wake-up each;
#   * the main-state dialog semantics the silence scan relies on (idle_prompt
#     is not a dialog; a Stop closes every dialog).
#
# The R section replays the 11-19 incident shape: an active review task, 16
# entries still listed by the host at the last Stop, a teammate that ended on a
# 402, and no tool call anywhere in the session for 35 minutes. Before 0.32.0
# every layer stayed silent on it (macOS has no fixed-pack observer; the
# teammate's agent_type matched no role; 16 "executors" kept no-executor quiet;
# idle muted status-stale).
# R2 replays the 11-17 shape behind issue #24 (f0b8d80a): a teammate's two
# background shells finished 3 min after the main agent stopped next to 12
# idle teammates; the user noticed 31 min in. The current code reports it at
# silence-sec (1 h, the shipped default) through the floor; no-executor stays
# masked by the teammates, pinned as a known limitation.
#
# WHAT THIS SUITE DOES NOT PROVE:
#  * That the host fires tool hooks inside in-process teammates with this
#    session's id (documented by Claude Code; not reproducible here).
#  * That StopFailure carries agent_id for a subagent / teammate turn (the
#    documented common field). A record without it is read as the main agent's.
#  * That a monitor stdout line wakes an idle session (platform).
#
# Mutation record (0.32.0, each mutant applied to an out-of-tree copy, run
# against this suite and test-main-state.sh): 51 targeted mutants in two
# rounds, every one turns a check red.
#  * Floor & dialogs (28): watchdog.sh — dialog mute; wait / user and legacy
#    Waiting On mutes; pending work; due-wait deferral; cron-scheduled mute and
#    its 1 h bound; failure cooldown; failure scan only while a task is open;
#    malformed-record guard; every task's records scanned; note time filter and
#    main-only scope. lib.sh — dialog close ignoring the owner; status write and
#    user prompt as progress. heartbeat.sh — subagent stamp; owner closes its
#    own dialog; an answered AskUserQuestion recorded as the user speaking.
#    notify.sh — idle_prompt mapping; the dialog owner from agent_id.
#    api-failure.sh — id charset; main failure sets idle; 7-day prune.
#    expect_state.py — silence-sec floor.
#  * IM policy (23): notify.sh — subagent StopFailure, idle_prompt, idle
#    category, unless-user-since, title prefix, name vs include_message.
#    heartbeat.sh / expect.sh — the question IMs. expect_state.py — watch
#    mutes nothing, watch=yes only, silence cap 24 h (lowered and opened).
#    main-state.sh — hand-off dedupe and reset, observing as hand-off, design
#    fallback honouring user rows and executors. watchdog.sh notify_stuck —
#    page on first report, escalate gap, once per stretch, progress compare.
#    lib.sh zyz_session_name — custom title first; the id charset (first
#    survived: '../x' resolved nothing either way — I1e2 now traverses to a
#    real transcript).
# Two earlier survivors were traced to vacuous checks and fixed: B7c compared a
# below-floor Tune against the default (max() hides the floor; it now asserts
# expect.sh refuses the row) and B9c spent its one in-cooldown tick before
# asserting.
#
# Usage:  bash scripts/test-session-silence.sh   (exit 0 iff every check passed)

set -u
# Never reach the user's real IM (~/.zyz-worker/notify.json): checks that
# exercise the notifier point ZYZ_NOTIFY_CONFIG at their own capture config.
ZYZ_TEST_NO_NOTIFY="/nonexistent/zyz-worker-test/notify.json"
export ZYZ_NOTIFY_CONFIG="$ZYZ_TEST_NO_NOTIFY"
set -o pipefail
unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
unset ZYZ_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CLAUDE_PID ZYZ_TASK_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
cd "$REPO_ROOT" || { echo "FATAL: cannot cd into '$REPO_ROOT'" >&2; exit 2; }

TOTAL=0; PASSED=0; FAILED=0
pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); echo "PASS  $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); echo "FAIL  $1${2:+ — $2}"; }

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP  all — python3 unavailable"; echo "RESULT: 0/0 checks passed (all skipped)"; exit 0
fi

LIB="hooks/scripts/lib.sh"
HEARTBEAT="hooks/scripts/heartbeat.sh"
MAIN_STATE="hooks/scripts/main-state.sh"
NOTIFY="hooks/scripts/notify.sh"
FAILREC="hooks/scripts/api-failure.sh"
STOP_MAIN="hooks/scripts/stop-gate-main.sh"
WATCHDOG="monitors/watchdog.sh"

for f in "$LIB" "$HEARTBEAT" "$MAIN_STATE" "$NOTIFY" "$FAILREC" "$WATCHDOG"; do
    if bash -n "$f" 2>/dev/null; then pass "S0 syntax: $f"; else fail "S0 syntax: $f"; fi
done
if [ -x "$FAILREC" ]; then pass "S0 api-failure.sh is executable"; else fail "S0 api-failure.sh is executable"; fi

SB="$(mktemp -d "${TMPDIR:-/tmp}/zyz-silence.XXXXXX")"
cleanup() { rm -rf "$SB" 2>/dev/null || true; }
trap cleanup EXIT
PROJ="$SB/proj"
ROOT="$PROJ/.zyz-worker/tasks/demo-task"
mkdir -p "$ROOT"
printf 'demo-task\n' > "$PROJ/.zyz-worker/current-task"
export ZYZ_NOTIFY_CONFIG="$SB/no-notify.json"
# The checks below are written against a 30-minute threshold (35 min silent
# fires, 25 min does not); the shipped default (1 h) is asserted in B2b.
export ZYZ_WATCHDOG_SILENCE_SEC=1800
NOW="$(date +%s)"

PENDING_ST='- SubTask ID: ST3
- Committed:'
# write_status <phase> [agent-state-rows] [subtasks] — then backdates status.md
# by 40 minutes so only the epochs a check sets decide the outcome.
write_status() {
    {
        printf '# 任务状态\n\n## 元数据\n\n- Current Phase: %s\n\n## Agent State\n\n- 主 agent: x\n' "$1"
        [ -z "${2:-}" ] || printf '%s\n' "$2"
        printf '\n## SubTasks\n\n%s\n\n## 下一步行动\n\n- 下一步: x\n' "${3-$PENDING_ST}"
    } > "$ROOT/status.md"
    age_file "$ROOT/status.md" 2400
}
age_file() { python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
reset_runtime() { rm -rf "$ROOT/runtime"; mkdir -p "$ROOT/runtime"; }
set_activity() { printf '%s %s\n' "$((NOW - $1))" "${2:-main}" > "$ROOT/runtime/activity"; }
# set_state <state> <age-sec> [owner] — owner applies to awaiting-user.
set_state() { printf '%s %s%s\n' "$1" "$((NOW - $2))" "${3:+ $3}" > "$ROOT/runtime/main-state"; }
# One watchdog scan. Every scan's cooldown markers are dropped first unless
# KEEP_NAG=1, so each check judges one tick.
tick() {
    [ "${KEEP_NAG:-0}" = 1 ] || rm -rf "$ROOT/runtime/nag"
    ZYZ_WATCHDOG_ONCE=1 bash "$WATCHDOG" "$PROJ" 2>>"$SB/tick.err"
}
is_silence() { printf '%s' "$1" | grep -q '没有任何动静'; }
is_failure() { printf '%s' "$1" | grep -q '因 API 错误中断：'; }

# ===========================================================================
echo "--- A: L0 activity stamp ---"
write_status implementation; reset_runtime
printf '{"cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Bash"}' "$PROJ" | bash "$HEARTBEAT"
set -- $(cat "$ROOT/runtime/activity" 2>/dev/null)
if [ "${2:-}" = main ] && [ $(( $(date +%s) - ${1:-0} )) -le 5 ]; then pass "A1 main tool call stamps activity <now> main"; else fail "A1 main activity" "got [$*]"; fi
rm -f "$ROOT/runtime/activity"
printf '{"cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read","agent_id":"ast3-review-r1-89c2","agent_type":"st3-review-r1"}' "$PROJ" | bash "$HEARTBEAT"
set -- $(cat "$ROOT/runtime/activity" 2>/dev/null)
if [ "${2:-}" = ast3-review-r1-89c2 ]; then pass "A2 a teammate's tool call (no role-name match, no fixed-pack) stamps activity"; else fail "A2 teammate activity" "got [$*]"; fi
reset_runtime
printf '{"cwd":"%s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' "$PROJ" | bash "$HEARTBEAT"
if [ "$(awk '{print $1, $3}' "$ROOT/runtime/main-state")" = "awaiting-user main" ] \
    && ( . "$LIB"; zyz_user_dialog_open "$ROOT" ); then
    pass "A3 AskUserQuestion opens a dialog owned by the main agent"
else
    fail "A3 AskUserQuestion dialog open" "state=[$(cat "$ROOT/runtime/main-state")]"
fi
printf '{"cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Read","agent_id":"ast9","agent_type":"x"}' "$PROJ" | bash "$HEARTBEAT"
if [ "$(awk '{print $1}' "$ROOT/runtime/main-state")" = awaiting-user ]; then pass "A3b a teammate working meanwhile does not close the main agent's dialog"; else fail "A3b other agent" "state=[$(cat "$ROOT/runtime/main-state")]"; fi
if [ ! -e "$ROOT/runtime/user-prompt-epoch" ]; then pass "A3c ... nor count as the user speaking"; else fail "A3c no prompt epoch"; fi
printf '{"cwd":"%s","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}' "$PROJ" | bash "$HEARTBEAT"
if [ "$(awk '{print $1}' "$ROOT/runtime/main-state")" = working ] && [ $(( $(date +%s) - $(cat "$ROOT/runtime/user-prompt-epoch" 2>/dev/null || echo 0) )) -le 5 ]; then
    pass "A3d the answer closes it and is recorded as the user speaking (lapses kind=user)"
else
    fail "A3d answered" "state=[$(cat "$ROOT/runtime/main-state")] upe=[$(cat "$ROOT/runtime/user-prompt-epoch" 2>/dev/null)]"
fi
write_status implementation
mkdir -p "$SB/bare"
printf '{"cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Bash"}' "$SB/bare" | bash "$HEARTBEAT"
if [ ! -e "$SB/bare/.zyz-worker" ]; then pass "A4 no task pointer -> nothing written"; else fail "A4 no pointer"; fi

# ===========================================================================
echo "--- B: L3 session silence ---"
write_status implementation; reset_runtime; set_activity 2100; set_state idle 2100
out="$(tick)"
if is_silence "$out" && printf '%s' "$out" | grep -q '35 分钟' && printf '%s' "$out" | grep -q 'SubTask ST3 尚未提交'; then
    pass "B1 active + work left + 35 min silent + nothing declared -> silence finding (minutes, pending SubTask)"
else
    fail "B1 silence fires" "out=[$out]"
fi
if printf '%s' "$out" | grep -q 'expect.sh --task' && printf '%s' "$out" | grep -q 'wait --at' && printf '%s' "$out" | grep -q 'silence-sec'; then
    pass "B1b the finding names how to clear it (wait / user / tune silence-sec / phase)"
else
    fail "B1b clear instructions" "out=[$out]"
fi
set_activity 1500
out="$(tick)"
if [ -z "$out" ]; then pass "B2 25 min silent (< 30 min threshold) -> quiet"; else fail "B2 below threshold" "out=[$out]"; fi
set_activity 3300; age_file "$ROOT/status.md" 4000
out="$(rm -rf "$ROOT/runtime/nag"; env -u ZYZ_WATCHDOG_SILENCE_SEC ZYZ_WATCHDOG_ONCE=1 bash "$WATCHDOG" "$PROJ" 2>>"$SB/tick.err")"
if ! is_silence "$out"; then pass "B2b shipped default is 1 h: 55 min silent -> quiet"; else fail "B2b default 55 min" "out=[$out]"; fi
set_activity 3700
out="$(rm -rf "$ROOT/runtime/nag"; env -u ZYZ_WATCHDOG_SILENCE_SEC ZYZ_WATCHDOG_ONCE=1 bash "$WATCHDOG" "$PROJ" 2>>"$SB/tick.err")"
if is_silence "$out"; then pass "B2c ... 61 min silent -> fires"; else fail "B2c default 61 min" "out=[$out]"; fi
age_file "$ROOT/status.md" 2400
set_activity 2100; touch "$ROOT/status.md"
out="$(tick)"
if ! is_silence "$out"; then pass "B3 a status write 0 min ago counts as progress -> quiet"; else fail "B3 status write is progress" "out=[$out]"; fi
age_file "$ROOT/status.md" 2400
printf '%s\n' "$((NOW - 120))" > "$ROOT/runtime/user-prompt-epoch"
out="$(tick)"
if ! is_silence "$out"; then pass "B4 a user prompt 2 min ago counts as progress -> quiet"; else fail "B4 user prompt is progress" "out=[$out]"; fi
rm -f "$ROOT/runtime/user-prompt-epoch"
out="$(tick)"
if is_silence "$out"; then pass "B4b control: same state without the prompt -> fires"; else fail "B4b control" "out=[$out]"; fi

write_status implementation "- Expect: key=lane; kind=wait; at=$((NOW + 1800)); ref=-; reason=全量用例"
out="$(tick)"
if [ -z "$out" ]; then pass "B5 a valid wait mutes it"; else fail "B5 wait mutes" "out=[$out]"; fi
write_status implementation "- Expect: key=lane; kind=wait; at=$((NOW - 60)); ref=-; reason=全量用例"
out="$(tick)"
if ! is_silence "$out" && printf '%s' "$out" | grep -q '到点了'; then pass "B5b a due wait gets its own reminder, not a second silence line"; else fail "B5b due wait" "out=[$out]"; fi
write_status implementation "- Expect: key=q; kind=user; since=$((NOW - 3000)); reason=等用户裁决"
out="$(tick)"
if [ -z "$out" ]; then pass "B6 a valid user declaration mutes it"; else fail "B6 user mutes" "out=[$out]"; fi
printf '%s\n' "$((NOW - 2500))" > "$ROOT/runtime/user-prompt-epoch"
out="$(tick)"
if is_silence "$out"; then pass "B6b a user declaration lapsed by a later prompt no longer mutes it"; else fail "B6b lapsed user" "out=[$out]"; fi
rm -f "$ROOT/runtime/user-prompt-epoch"
write_status implementation "- Waiting On: instance-key=lane; since-epoch=$((NOW - 60)); next-check-epoch=$((NOW + 600)); reason=legacy"
out="$(tick)"
if [ -z "$out" ]; then pass "B6c a valid legacy Waiting On row mutes it"; else fail "B6c legacy wait" "out=[$out]"; fi

write_status implementation "- Tune: silence-sec=3600"
out="$(tick)"
if [ -z "$out" ]; then pass "B7 Tune silence-sec=3600 relaxes it (35 min quiet)"; else fail "B7 tune quiet" "out=[$out]"; fi
set_activity 3900; age_file "$ROOT/status.md" 4000
out="$(tick)"
if is_silence "$out"; then pass "B7b ... and it fires past the tuned threshold (65 min)"; else fail "B7b tune fires" "out=[$out]"; fi
# A Tune only ever relaxes (every layer takes max(Tune, default)), so the
# floor is enforced where it can matter: expect.sh refuses to write the row.
write_status implementation
if bash "hooks/scripts/expect.sh" --task "$ROOT" tune silence-sec=599 >/dev/null 2>&1; then
    fail "B7c expect.sh refuses silence-sec below the 600 floor" "row written: [$(grep '^- Tune:' "$ROOT/status.md")]"
else
    pass "B7c expect.sh refuses silence-sec below the 600 floor"
fi
if bash "hooks/scripts/expect.sh" --task "$ROOT" tune silence-sec=600 >/dev/null 2>&1 && grep -q '^- Tune: silence-sec=600$' "$ROOT/status.md"; then
    pass "B7d ... and accepts the floor itself (the refusal above is not a broken writer)"
else
    fail "B7d floor accepted" "status=[$(grep '^- Tune:' "$ROOT/status.md")]"
fi

write_status implementation; set_activity 2100
set_state awaiting-user 2100 main
out="$(tick)"
if [ -z "$out" ]; then pass "B8 an open dialog mutes it (AskUserQuestion pending for hours)"; else fail "B8 dialog mutes" "out=[$out]"; fi
set_state awaiting-user 7200 main; set_activity 2100 ast9
out="$(tick)"
if [ -z "$out" ]; then pass "B8a ... even when a teammate moved after the dialog opened (it is not the owner)"; else fail "B8a other agent's progress" "out=[$out]"; fi
set_state awaiting-user 2400 ast9
printf '{"cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Bash","agent_id":"ast9","agent_type":"x"}' "$PROJ" | bash "$HEARTBEAT"
set_activity 2100 ast9
out="$(tick)"
if is_silence "$out" && [ "$(awk '{print $1}' "$ROOT/runtime/main-state")" = idle ]; then
    pass "B8b a subagent's own permission prompt is closed by its next tool call -> fires once the session is silent"
else
    fail "B8b owner closes" "out=[$out] state=[$(cat "$ROOT/runtime/main-state")]"
fi
set_state idle 2100
out="$(tick)"
if is_silence "$out"; then pass "B8c main-state idle does not mute it (idle is the symptom)"; else fail "B8c idle" "out=[$out]"; fi

printf '%s 16 a,b,c,d 0\n' "$((NOW - 2100))" > "$ROOT/runtime/stop-snapshot"
out="$(tick)"
if is_silence "$out"; then pass "B9 16 executors listed at the last Stop do not mute it"; else fail "B9 host list" "out=[$out]"; fi
printf '%s 0 - 0\n' "$((NOW - 2100))" > "$ROOT/runtime/stop-snapshot"
out="$(tick)"
if printf '%s' "$out" | grep -q '没有任何执行者' && ! is_silence "$out"; then
    pass "B9b zero executors at the Stop -> the no-executor finding, never both in one tick"
else
    fail "B9b one finding per tick" "out=[$out]"
fi
# B9b's tick stamped the no-executor cooldown; the very next tick is inside it.
out="$(KEEP_NAG=1 tick)"
if [ -z "$out" ]; then pass "B9c no-executor inside its cooldown does not hand over to silence"; else fail "B9c no hand-over" "out=[$out]"; fi
printf '%s 2 a,b 1\n' "$((NOW - 2100))" > "$ROOT/runtime/stop-snapshot"
out="$(tick)"
if [ -z "$out" ]; then pass "B9d a wakeup scheduled at the last Stop (session_crons) mutes it for a bounded time"; else fail "B9d cron mute" "out=[$out]"; fi
printf '%s 2 a,b 1\n' "$((NOW - 5500))" > "$ROOT/runtime/stop-snapshot"; set_activity 5500
out="$(tick)"
if is_silence "$out"; then pass "B9e ... and fires once silence-sec + 1 h has passed (a cron that never comes)"; else fail "B9e cron bound" "out=[$out]"; fi
set_activity 2100
rm -f "$ROOT/runtime/stop-snapshot"

for ph in design awaiting-confirmation done; do
    write_status "$ph"
    out="$(tick)"
    if [ -z "$out" ]; then pass "B10 phase $ph -> quiet"; else fail "B10 phase $ph" "out=[$out]"; fi
done
write_status observing "- Expect: key=r; kind=wait; at=$((NOW + 3600)); ref=-; reason=次日对账"
out="$(tick)"
if [ -z "$out" ]; then pass "B10b observing with a scheduled wait -> quiet"; else fail "B10b observing" "out=[$out]"; fi
write_status delivery "" '- SubTask ID: ST1
- Committed: abc1234'
out="$(tick)"
if [ -z "$out" ]; then pass "B11 delivery with every SubTask committed -> quiet"; else fail "B11 delivery done" "out=[$out]"; fi
write_status delivery
out="$(tick)"
if is_silence "$out"; then pass "B11b delivery with an uncommitted SubTask -> fires"; else fail "B11b delivery pending" "out=[$out]"; fi

write_status implementation; rm -rf "$ROOT/runtime/nag"
out1="$(KEEP_NAG=1 tick)"; out2="$(KEEP_NAG=1 tick)"
if is_silence "$out1" && [ -z "$out2" ]; then pass "B12 repeats at most once per remind-sec"; else fail "B12 cooldown" "1=[$out1] 2=[$out2]"; fi
printf '%s\n' "$((NOW - 1900))" > "$ROOT/runtime/nag/watchdog-silence.last"
out3="$(KEEP_NAG=1 tick)"
if is_silence "$out3"; then pass "B12b ... and fires again once remind-sec has passed"; else fail "B12b re-remind" "out=[$out3]"; fi

# IM (0.32.0): the main agent is woken first; the user is paged only when that
# wake went unanswered — a second report >= ESCALATE later with nobody moving.
CAP="$SB/im.log"
printf '{"enabled":true,"command":"printf \\"%%s|%%s|%%s\\\\n\\" \\"$ZYZ_NOTIFY_EVENT\\" \\"$ZYZ_NOTIFY_TITLE\\" \\"$ZYZ_NOTIFY_MESSAGE\\" >> %s","cooldown_sec":0}\n' "$CAP" > "$SB/notify.json"
wait_cap() { local i=0; while [ "$i" -lt 33 ]; do [ "$(grep -c '^stuck|' "$CAP" 2>/dev/null)" -ge "$1" ] && return 0; sleep 0.3; i=$((i+1)); done; return 1; }
im_tick() { rm -f "$ROOT/runtime/nag/watchdog-silence.last"; ZYZ_NOTIFY_CONFIG="$SB/notify.json" KEEP_NAG=1 tick; }
: > "$CAP"; rm -rf "$ROOT/runtime/nag"; set_state idle 2100
out1="$(im_tick)"; sleep 1.5
if is_silence "$out1" && [ ! -s "$CAP" ]; then pass "B13 the first report wakes the main agent and pages nobody"; else fail "B13 first report" "out=[$out1] cap=[$(cat "$CAP")]"; fi
out2="$(im_tick)"; sleep 1.5
if is_silence "$out2" && [ ! -s "$CAP" ]; then pass "B13a a second report inside ESCALATE (600 s) still pages nobody"; else fail "B13a inside escalate" "cap=[$(cat "$CAP")]"; fi
read -r p_ st_ first_ < "$ROOT/runtime/nag/watchdog-escalate"
printf '%s reported %s\n' "$p_" "$((first_ - 700))" > "$ROOT/runtime/nag/watchdog-escalate"
out3="$(im_tick)"; wait_cap 1
if is_silence "$out3" && grep -q '^stuck|.*此后会话里没有任何动作：任务仍在 implementation 阶段，但整个会话已' "$CAP"; then
    pass "B13b unanswered for >= ESCALATE with no progress -> one stuck page (even while main-state is idle)"
else
    fail "B13b escalation page" "cap=[$(cat "$CAP")]"
fi
for _ in 1 2 3; do im_tick >/dev/null; done; sleep 1.5
if [ "$(grep -c '^stuck|' "$CAP")" = 1 ]; then pass "B13c one page per silent stretch (the main agent keeps hearing every report)"; else fail "B13c once" "cap=[$(cat "$CAP")]"; fi
set_activity 2050
im_tick >/dev/null; sleep 1
read -r p_ st_ first_ < "$ROOT/runtime/nag/watchdog-escalate"
if [ "$st_" = reported ] && [ "$(grep -c '^stuck|' "$CAP")" = 1 ]; then pass "B13d progress starts a new stretch (reported again, not paged)"; else fail "B13d reset" "mark=[$p_ $st_ $first_] cap=[$(cat "$CAP")]"; fi
printf '%s reported %s\n' "$p_" "$((first_ - 700))" > "$ROOT/runtime/nag/watchdog-escalate"
im_tick >/dev/null; wait_cap 2
if [ "$(grep -c '^stuck|' "$CAP")" = 2 ]; then pass "B13e ... and that stretch can escalate once of its own"; else fail "B13e second stretch" "cap=[$(cat "$CAP")]"; fi
set_activity 2100

# Multi-task session: progress is session-wide.
SID="sess-silence-1"
ROOT2="$PROJ/.zyz-worker/tasks/second"
mkdir -p "$ROOT2" "$PROJ/.zyz-worker/sessions"
cp "$ROOT/status.md" "$ROOT2/status.md"; age_file "$ROOT2/status.md" 2400
printf '%s\n%s\n' "$ROOT" "$ROOT2" > "$PROJ/.zyz-worker/sessions/$SID"
set_activity 60
out="$(rm -rf "$ROOT/runtime/nag" "$ROOT2/runtime/nag"; ZYZ_SESSION_ID="$SID" ZYZ_WATCHDOG_ONCE=1 bash "$WATCHDOG" "$PROJ" 2>/dev/null)"
if ! is_silence "$out"; then pass "B14 activity recorded under the primary task counts for the session's other task"; else fail "B14 session-wide progress" "out=[$out]"; fi
set_activity 2100
out="$(rm -rf "$ROOT/runtime/nag" "$ROOT2/runtime/nag"; ZYZ_SESSION_ID="$SID" ZYZ_WATCHDOG_ONCE=1 bash "$WATCHDOG" "$PROJ" 2>/dev/null)"
if printf '%s' "$out" | grep -q '任务 second 仍在' && printf '%s' "$out" | grep -q '任务 demo-task 仍在'; then pass "B14b a silent session reports each of its active tasks"; else fail "B14b per task" "out=[$out]"; fi
rm -rf "$PROJ/.zyz-worker/sessions" "$ROOT2"

# ===========================================================================
echo "--- C: api-failure.sh records StopFailure ---"
write_status implementation; reset_runtime
recs() { cat "$ROOT"/runtime/api-failures/*.rec 2>/dev/null; }
printf '{"hook_event_name":"StopFailure","cwd":"%s","agent_id":"ast3-review-r1-89c2","agent_type":"st3-review-r1","error":"billing_error","error_details":"402\\tbad\\nresponse"}' "$PROJ" | bash "$FAILREC"
line="$(recs)"
if [ "$(printf '%s' "$line" | awk -F '\t' '{print NF}')" = 5 ] \
    && [ "$(printf '%s' "$line" | cut -f2,3,4)" = "$(printf 'ast3-review-r1-89c2\tst3-review-r1\tbilling_error')" ] \
    && [ "$(printf '%s' "$line" | cut -f5)" = "402 bad response" ]; then
    pass "C1 one record: epoch, agent_id, agent_type, error, whitespace-collapsed details"
else
    fail "C1 record" "line=[$line]"
fi
reset_runtime
printf '{"hook_event_name":"StopFailure","cwd":"%s","error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"}' "$PROJ" | bash "$FAILREC"
if [ "$(recs | cut -f2,4,5)" = "$(printf -- '-\trate_limit\tAPI Error: Rate limit reached')" ]; then pass "C2 no agent_id -> '-' (the main agent); details fall back to last_assistant_message"; else fail "C2 main record" "line=[$(recs)]"; fi
reset_runtime
printf '{"hook_event_name":"StopFailure","cwd":"%s","agent_id":"x;rm -rf /","error":"unknown"}' "$PROJ" | bash "$FAILREC"
if [ "$(recs | cut -f2)" = - ]; then pass "C3 an agent_id outside the safe charset is dropped"; else fail "C3 id charset" "line=[$(recs)]"; fi
reset_runtime
printf '{"hook_event_name":"StopFailure","cwd":"%s","error":"x"}' "$SB/bare" | bash "$FAILREC"
printf '{"hook_event_name":"StopFailure","cwd":"%s","error":"x"}' "$PROJ" | ZYZ_HOOKS_DISABLE=1 bash "$FAILREC"
printf '{"hook_event_name":"Stop","cwd":"%s","error":"x"}' "$PROJ" | bash "$FAILREC"
printf 'not json' | bash "$FAILREC"; rc=$?
if [ -z "$(recs)" ] && [ ! -e "$SB/bare/.zyz-worker" ] && [ "$rc" = 0 ]; then pass "C4 no pointer / disabled / other event / bad JSON -> no record, exit 0"; else fail "C4 fail-open" "recs=[$(recs)] rc=$rc"; fi
if python3 -c 'import json,sys; h=json.load(open("hooks/hooks.json"))["hooks"]["StopFailure"][0]["hooks"]; sys.exit(0 if any("/hooks/scripts/api-failure.sh" in x["command"] and not x.get("async") for x in h) else 1)'; then
    pass "C5 hooks.json registers api-failure.sh on StopFailure (sync: the record must land before the session idles)"
else
    fail "C5 registration"
fi

# ===========================================================================
echo "--- D: L3 scan_failures ---"
write_status implementation; reset_runtime; set_activity 30
fail_rec() { # <agent-id|-> <type> <error> <details>
    printf '{"hook_event_name":"StopFailure","cwd":"%s"%s,"agent_type":"%s","error":"%s","error_details":"%s"}' \
        "$PROJ" "$([ "$1" = - ] || printf ',"agent_id":"%s"' "$1")" "$2" "$3" "$4" | bash "$FAILREC"
}
fail_rec ast3-review-r1-89c2 st3-review-r1 billing_error "402 bad response status code 402"
out="$(tick)"
if is_failure "$out" && printf '%s' "$out" | grep -q 'st3-review-r1（ast3-review-r1-89c2）' && printf '%s' "$out" | grep -q 'billing_error（402 bad response status code 402）'; then
    pass "D1 a teammate's API-error death wakes the main agent (who, when, error, details)"
else
    fail "D1 failure wake" "out=[$out]"
fi
if printf '%s' "$out" | grep -q '续做而非重做' && printf '%s' "$out" | grep -q 'wait --at +30m'; then pass "D1b it says how to handle it (continue-not-redo; declare a wait on a recurring error)"; else fail "D1b guidance" "out=[$out]"; fi
if [ -z "$(ls "$ROOT"/runtime/api-failures/*.rec 2>/dev/null)" ] && [ -n "$(ls "$ROOT"/runtime/api-failures/reported/*.rec 2>/dev/null)" ]; then pass "D2 the record moves to reported/"; else fail "D2 consumed" "$(ls -R "$ROOT/runtime/api-failures")"; fi
out="$(tick)"
if ! is_failure "$out"; then pass "D2b a reported record is never reported again"; else fail "D2b once" "out=[$out]"; fi

reset_runtime; set_activity 30; set_state working 30
fail_rec - - billing_error "402"
if [ "$(awk '{print $1}' "$ROOT/runtime/main-state")" = idle ]; then pass "D3a the main agent's own failure ends its turn: main-state idle (no status-stale pile-up)"; else fail "D3a main idle" "state=[$(cat "$ROOT/runtime/main-state")]"; fi
out="$(tick)"
if ! is_failure "$out" && [ -n "$(ls "$ROOT"/runtime/api-failures/reported/*.rec 2>/dev/null)" ]; then
    pass "D3 the main agent's own failure is not a wake-up (no poll-rate loop on a persistent error); filed as reported"
else
    fail "D3 main failure" "out=[$out]"
fi
set_activity 2100
out="$(tick)"
if is_silence "$out" && printf '%s' "$out" | grep -q '主 agent 的 API 错误中断：主 agent' && printf '%s' "$out" | grep -q 'billing_error（402）'; then
    pass "D3b ... the silence finding names it instead"
else
    fail "D3b silence note" "out=[$out]"
fi
# A main failure from before the last progress is old news.
reset_runtime; set_activity 30
fail_rec - - billing_error "402"
tick >/dev/null
set_activity 2000
for f in "$ROOT"/runtime/api-failures/reported/*.rec; do
    printf '%s\t-\t-\tbilling_error\t402\n' "$((NOW - 2050))" > "$f"
done
out="$(tick)"
if is_silence "$out" && ! printf '%s' "$out" | grep -q '主 agent 的 API 错误'; then pass "D3d a main failure older than the last progress is not named"; else fail "D3d note time filter" "out=[$out]"; fi
set_state working 30
reset_runtime; set_activity 2100; set_state working 2100
fail_rec ast3 st3-review-r1 billing_error "402"
if [ "$(awk '{print $1}' "$ROOT/runtime/main-state")" = working ]; then pass "D3e a teammate's failure leaves main-state alone"; else fail "D3e teammate state" "state=[$(cat "$ROOT/runtime/main-state")]"; fi
out="$(tick)"
if is_silence "$out" && ! printf '%s' "$out" | grep -q '主 agent 的 API 错误'; then pass "D3c a teammate failure is not repeated inside the silence note"; else fail "D3c note scope" "out=[$out]"; fi

reset_runtime; set_activity 30
fail_rec a1 implementation-agent server_error "500"
KEEP_NAG=1 tick >/dev/null
fail_rec a2 test-agent server_error "500"
fail_rec a3 review-agent rate_limit "429"
out="$(KEEP_NAG=1 tick)"
if ! is_failure "$out" && [ "$(ls "$ROOT"/runtime/api-failures/*.rec 2>/dev/null | wc -l | tr -d ' ')" = 2 ]; then
    pass "D4 records inside the failure cooldown stay pending (no fast re-dispatch loop)"
else
    fail "D4 cooldown" "out=[$out]"
fi
printf '%s\n' "$((NOW - 700))" > "$ROOT/runtime/nag/watchdog-api-failure.last"
out="$(KEEP_NAG=1 tick)"
if printf '%s' "$out" | grep -q '有 2 个 subagent / teammate' && printf '%s' "$out" | grep -q 'a2' && printf '%s' "$out" | grep -q 'a3'; then
    pass "D4b ... and are batched into one line once it has passed"
else
    fail "D4b batch" "out=[$out]"
fi

reset_runtime; set_activity 30
write_status design
fail_rec a4 review-agent overloaded "529"
out="$(tick)"
if is_failure "$out"; then pass "D5 reported in the design phase too (a design-review lane dying leaves design waiting)"; else fail "D5 design" "out=[$out]"; fi
write_status done
fail_rec a5 review-agent overloaded "529"
out="$(tick)"
if ! is_failure "$out"; then pass "D5b not reported for a finished task"; else fail "D5b done" "out=[$out]"; fi
write_status implementation "- Expect: key=lane; kind=wait; at=$((NOW + 1800)); ref=-; reason=x"
out="$(tick)"
if is_failure "$out"; then pass "D6 a declaration does not mute a failure (facts beat declarations)"; else fail "D6 not muted" "out=[$out]"; fi

# Malformed records are filed, never reported, never crash the scan.
write_status implementation; reset_runtime; set_activity 30
mkdir -p "$ROOT/runtime/api-failures"
printf 'garbage\tx\ty\n' > "$ROOT/runtime/api-failures/bad1.rec"
printf '\n' > "$ROOT/runtime/api-failures/bad2.rec"
: > "$SB/tick.err.bad"
out="$(rm -rf "$ROOT/runtime/nag"; ZYZ_WATCHDOG_ONCE=1 bash "$WATCHDOG" "$PROJ" 2>"$SB/tick.err.bad")"
if ! is_failure "$out" && [ -z "$(ls "$ROOT"/runtime/api-failures/*.rec 2>/dev/null)" ] && [ ! -s "$SB/tick.err.bad" ]; then
    pass "D7 malformed records are archived silently"
else
    fail "D7 bad records" "out=[$out] err=[$(cat "$SB/tick.err.bad")] left=[$(ls "$ROOT"/runtime/api-failures/)]"
fi
# Records live under the task that was primary when written; every task is scanned.
SID="sess-fail-1"
ROOT2="$PROJ/.zyz-worker/tasks/second"
mkdir -p "$ROOT2/runtime/api-failures" "$PROJ/.zyz-worker/sessions"
cp "$ROOT/status.md" "$ROOT2/status.md"
printf '%s\n%s\n' "$ROOT" "$ROOT2" > "$PROJ/.zyz-worker/sessions/$SID"
printf '%s\tafar\treview-agent\tserver_error\t500\n' "$NOW" > "$ROOT2/runtime/api-failures/x.rec"
out="$(rm -rf "$ROOT/runtime/nag" "$ROOT2/runtime/nag"; ZYZ_SESSION_ID="$SID" ZYZ_WATCHDOG_ONCE=1 bash "$WATCHDOG" "$PROJ" 2>>"$SB/tick.err")"
if is_failure "$out" && printf '%s' "$out" | grep -q afar && [ -e "$ROOT2/runtime/api-failures/reported/x.rec" ]; then
    pass "D8 a record under a non-primary task is reported and filed there"
else
    fail "D8 secondary root" "out=[$out]"
fi
rm -rf "$PROJ/.zyz-worker/sessions" "$ROOT2"
# Bounded lifecycle: records older than 7 days go on the next StopFailure.
reset_runtime; mkdir -p "$ROOT/runtime/api-failures/reported"
printf 'x\n' > "$ROOT/runtime/api-failures/reported/old.rec"; age_file "$ROOT/runtime/api-failures/reported/old.rec" $((8 * 86400))
printf 'x\n' > "$ROOT/runtime/api-failures/stale.rec"; age_file "$ROOT/runtime/api-failures/stale.rec" $((8 * 86400))
printf 'x\n' > "$ROOT/runtime/api-failures/reported/recent.rec"; age_file "$ROOT/runtime/api-failures/reported/recent.rec" $((6 * 86400))
fail_rec a9 review-agent server_error "500"
if [ ! -e "$ROOT/runtime/api-failures/reported/old.rec" ] && [ ! -e "$ROOT/runtime/api-failures/stale.rec" ] \
    && [ -e "$ROOT/runtime/api-failures/reported/recent.rec" ] && [ "$(ls "$ROOT"/runtime/api-failures/*.rec | wc -l | tr -d ' ')" = 1 ]; then
    pass "D9 records older than 7 days (reported or never consumed) are pruned; newer ones and the new record stay"
else
    fail "D9 prune" "$(ls -R "$ROOT/runtime/api-failures")"
fi

# ===========================================================================
echo "--- R: the 11-19 incident shape ---"
write_status review "" '- SubTask ID: ST2
- Committed:
- SubTask ID: ST3
- Committed:
- SubTask ID: ST4
- Committed:'
reset_runtime
printf '{"cwd":"%s","hook_event_name":"Stop","stop_hook_active":false,"background_tasks":[%s],"session_crons":[]}' "$PROJ" \
    "$(python3 -c 'import json; print(",".join(json.dumps({"id":"t%d"%i,"type":"teammate" if i<5 else "shell","status":"running"}) for i in range(16)))')" \
    | ZYZ_STOP_GATE_COOLDOWN_SEC=0 bash "$STOP_MAIN" >/dev/null 2>&1
printf '{"cwd":"%s","hook_event_name":"Stop"}' "$PROJ" | bash "$MAIN_STATE"
printf '{"cwd":"%s","hook_event_name":"Notification","notification_type":"idle_prompt"}' "$PROJ" | bash "$NOTIFY"
if [ "$(awk '{print $2}' "$ROOT/runtime/stop-snapshot" 2>/dev/null)" = 16 ] && [ "$(awk '{print $1}' "$ROOT/runtime/main-state")" = idle ]; then
    pass "R0 setup: 16 executors at the Stop; idle_prompt leaves main-state idle"
else
    fail "R0 setup" "snap=[$(cat "$ROOT/runtime/stop-snapshot" 2>/dev/null)] state=[$(cat "$ROOT/runtime/main-state")]"
fi
fail_rec ast3-review-r1-89c2 st3-review-r1 billing_error "402"
set_activity 2100 ast3-review-r1-89c2
python3 - "$ROOT/runtime/stop-snapshot" "$ROOT/runtime/main-state" "$((NOW - 2100))" <<'PY'
import sys
for p in sys.argv[1:3]:
    head, *rest = open(p).read().split()
    if p.endswith("main-state"):
        open(p, "w").write("%s %s\n" % (head, sys.argv[3]))
    else:
        open(p, "w").write(" ".join([sys.argv[3]] + rest) + "\n")
PY
out="$(tick)"
if is_failure "$out" && is_silence "$out"; then
    pass "R1 both floors fire: the teammate's 402 death, and 35 min with nobody moving (before 0.32.0: silence)"
else
    fail "R1 incident" "out=[$out]"
fi

# ===========================================================================
echo "--- R2: the 11-17 incident shape (f0b8d80a, the issue #24 report) ---"
# tipsy-ab-config, 11-17. The main agent's last tool call was 22:22:07 and it
# stopped at 22:22:27 with ST4 uncommitted in `implementation`. The ST4
# teammate had started a Monitor and a background shell on its DuckDB suite at
# 21:25 and ended its turn "Waiting for the completion notification"; both
# finished at 22:25:05, their notifications were queued and never acted on, and
# nobody moved until the user asked at 22:53:44 (31 min after the last tool
# call). The Stop's background_tasks then held 12 agent-team teammates — in
# Claude Code 2.1.251 an in-process teammate is listed while it exists, idle or
# not (`isIdle` is not exported; static reading of the binary's Stop-input
# builder) — the teammate's two shells, and this watchdog.
write_status implementation "" '| SubTask | 内容 | 依赖 | Coded | Tested | Reviewed | Committed |
|---|---|---|---|---|---|---|
| ST1 | 回滚终止后端 | 无 | true | true | true | true（a5877d3，未推送） |
| ST4 | 数仓 SQL/文档 + DuckDB | 无 | true | true | false | false |
| ST5 | 文档和注释 | ST1 | true | true | true | true（774a827，未推送） |'
reset_runtime
r2_tasks="$(python3 -c '
import json
t = [{"id":"bwd00001","type":"shell","status":"running","description":"execute-task watchdog","command":"\"/Users/u/.claude/plugins/cache/zyz-worker/zyz-worker/0.28.0\"/monitors/watchdog.sh \"/p\""}]
t += [{"id":"t%07d" % i,"type":"teammate","status":"running","description":n} for i, n in enumerate(
    ["st4-impl","st4-test","st1-run","st1-test-r3","st2-impl","st2-review-r2","st5-review","st3-impl","st6-impl","st4-review","st1-review","st2-test"])]
t += [{"id":"bl1z6235k","type":"shell","status":"running","description":"ST4 round-4 mutations and full suite","command":"cd /tmp; for m in MB2a MB2b; do until grep -q rc= st4_mut4_$m.out; do sleep 10; done; done"},
      {"id":"bmsfp4gru","type":"shell","status":"running","description":"wait for ST4 runs","command":"cd /tmp; until grep -q ^rc= /tmp/st4_r4_full.log; do sleep 15; done"}]
print(",".join(json.dumps(x) for x in t))')"
r2_stop() { printf '{"cwd":"%s","hook_event_name":"Stop","stop_hook_active":false,"background_tasks":[%s],"session_crons":[]}' "$PROJ" "$1" \
    | ZYZ_STOP_GATE_COOLDOWN_SEC=0 bash "$STOP_MAIN" 2>/dev/null; }
out="$(r2_stop "$r2_tasks")"
if ! printf '%s' "$out" | grep -q '没有任何执行者' && [ "$(awk '{print $2}' "$ROOT/runtime/stop-snapshot" 2>/dev/null)" = 14 ]; then
    pass "R2a the 22:22 Stop: 12 teammates + 2 running shells are executors (correct then: the shells were running)"
else
    fail "R2a Stop" "out=[$out] snap=[$(cat "$ROOT/runtime/stop-snapshot" 2>/dev/null)]"
fi
printf '{"cwd":"%s","hook_event_name":"Stop"}' "$PROJ" | bash "$MAIN_STATE"
r2_age() { # <sec>: the last tool call, the status write, the Stop and its snapshot all <sec> ago
    set_activity "$1" main
    age_file "$ROOT/status.md" "$1"
    python3 - "$ROOT/runtime/stop-snapshot" "$ROOT/runtime/main-state" "$((NOW - $1))" <<'PY'
import sys
for p in sys.argv[1:3]:
    head, *rest = open(p).read().split()
    if p.endswith("main-state"):
        open(p, "w").write("%s %s\n" % (head, sys.argv[3]))
    else:
        open(p, "w").write(" ".join([sys.argv[3]] + rest) + "\n")
PY
}
export ZYZ_WATCHDOG_SILENCE_SEC=3600   # the shipped default, as on 11-17
r2_age 1860
out="$(tick)"
if [ -z "$out" ]; then
    pass "R2b 22:53 (31 min, when the user noticed): still silent — the documented window below silence-sec"
else
    fail "R2b 31 min" "out=[$out]"
fi
r2_age 3660
out="$(tick)"
if is_silence "$out" && printf '%s' "$out" | grep -q 'SubTask ST4 尚未提交' && ! printf '%s' "$out" | grep -q '没有任何执行者'; then
    pass "R2c 23:23 (61 min): the session-silence floor reports it, naming ST4 (the 0.31.0 code prints nothing on this replay)"
else
    fail "R2c 61 min" "out=[$out]"
fi
export ZYZ_WATCHDOG_SILENCE_SEC=1800
# Known limitation, pinned so a fix is noticed: a Stop taken after the shells
# ended still lists the idle teammates as running, so the faster no-executor
# check (L4 now, L3 after no-executor-sec) cannot fire while a team exists.
r2_team="$(printf '%s' "$r2_tasks" | python3 -c 'import json,sys; t=json.loads("["+sys.stdin.read()+"]"); print(",".join(json.dumps(x) for x in t if x["type"]!="shell" or "watchdog" in x["command"]))')"
out="$(r2_stop "$r2_team")"
if ! printf '%s' "$out" | grep -q '没有任何执行者'; then
    pass "R2d idle teammates listed as running mask no-executor (blind spot, docs/design/watchdog-design.md §8)"
else
    fail "R2d team masks no-executor (limitation changed — update §8 and this check)" "out=[$out]"
fi
out="$(r2_stop "$(printf '%s' "$r2_tasks" | python3 -c 'import json,sys; t=json.loads("["+sys.stdin.read()+"]"); print(",".join(json.dumps(x) for x in t if "watchdog" in x.get("command","")))')")"
if printf '%s' "$out" | grep -q '没有任何执行者'; then
    pass "R2e control: with the team gone and only the plugin monitor left, the same Stop is blocked"
else
    fail "R2e control" "out=[$out]"
fi

# ===========================================================================
echo "--- M: main-state dialog semantics used by the floor ---"
write_status implementation; reset_runtime
set_state awaiting-user 10
printf '{"cwd":"%s","hook_event_name":"Stop"}' "$PROJ" | bash "$MAIN_STATE"
if [ "$(awk '{print $1}' "$ROOT/runtime/main-state")" = idle ]; then pass "M1 Stop closes an open dialog (idle)"; else fail "M1 Stop" "state=[$(cat "$ROOT/runtime/main-state")]"; fi
for nt in permission_prompt elicitation_dialog; do
    set_state working 10
    printf '{"cwd":"%s","hook_event_name":"Notification","notification_type":"%s"}' "$PROJ" "$nt" | bash "$NOTIFY"
    if [ "$(awk '{print $1}' "$ROOT/runtime/main-state")" = awaiting-user ]; then pass "M2 $nt opens a dialog"; else fail "M2 $nt" "state=[$(cat "$ROOT/runtime/main-state")]"; fi
done
printf '{"cwd":"%s","hook_event_name":"Notification","notification_type":"permission_prompt","agent_id":"ast9"}' "$PROJ" | bash "$NOTIFY"
if [ "$(awk '{print $1, $3}' "$ROOT/runtime/main-state")" = "awaiting-user ast9" ]; then pass "M2b a subagent's prompt is recorded as its own dialog"; else fail "M2b owner" "state=[$(cat "$ROOT/runtime/main-state")]"; fi
printf '{"cwd":"%s","hook_event_name":"Notification","notification_type":"permission_prompt"}' "$PROJ" | bash "$NOTIFY"
if [ "$(awk '{print $1, $3}' "$ROOT/runtime/main-state")" = "awaiting-user main" ]; then pass "M2c without agent_id it is the main agent's"; else fail "M2c owner main" "state=[$(cat "$ROOT/runtime/main-state")]"; fi
printf '{"cwd":"%s","hook_event_name":"Notification","notification_type":"idle_prompt"}' "$PROJ" | bash "$NOTIFY"
if [ "$(awk '{print $1}' "$ROOT/runtime/main-state")" = idle ]; then pass "M3 idle_prompt is not a dialog (idle)"; else fail "M3 idle_prompt" "state=[$(cat "$ROOT/runtime/main-state")]"; fi

# ===========================================================================
echo "--- I: IM policy — page on questions and hand-off, name the session ---"
write_status implementation; reset_runtime
ICAP="$SB/im2.log"
printf '{"enabled":true,"command":"printf \\"%%s|%%s|%%s|%%s\\\\n\\" \\"$ZYZ_NOTIFY_EVENT\\" \\"$ZYZ_NOTIFY_SESSION_NAME\\" \\"$ZYZ_NOTIFY_TITLE\\" \\"$ZYZ_NOTIFY_MESSAGE\\" >> %s","cooldown_sec":0}\n' "$ICAP" > "$SB/notify-i.json"
FAKE_CC="$SB/claude-home"; FAKE_CX="$SB/codex-home"
mkdir -p "$FAKE_CC/projects/p1" "$FAKE_CC/sessions" "$FAKE_CX"
SID_A="aaaa1111-2222-3333-4444-555566667777"
{ printf '{"type":"ai-title","aiTitle":"旧标题","sessionId":"%s"}\n' "$SID_A"
  printf '{"type":"user","message":"x"}\n'
  printf '{"type":"custom-title","customTitle":"combo v3","sessionId":"%s"}\n' "$SID_A"
  printf '{"type":"ai-title","aiTitle":"更新的 AI 标题","sessionId":"%s"}\n' "$SID_A"; } > "$FAKE_CC/projects/p1/$SID_A.jsonl"
SID_B="bbbb1111-2222-3333-4444-555566667777"
printf '{"type":"ai-title","aiTitle":"只有  AI\\t标题","sessionId":"%s"}\n' "$SID_B" > "$FAKE_CC/projects/p1/$SID_B.jsonl"
SID_C="cccc1111-2222-3333-4444-555566667777"
printf '{"pid":1,"sessionId":"%s","name":"proj-4c"}\n' "$SID_C" > "$FAKE_CC/sessions/1.json"
SID_D="019a0000-0000-7000-8000-000000000001"
{ printf '{"id":"%s","thread_name":"第一版名字"}\n' "$SID_D"; printf '{"id":"%s","thread_name":"改过的线程名"}\n' "$SID_D"; } > "$FAKE_CX/session_index.jsonl"
sname() { ( . "$LIB"; CLAUDE_CONFIG_DIR="$FAKE_CC" CODEX_HOME="$FAKE_CX" zyz_session_name "$@" ); }
[ "$(sname "$SID_A")" = "combo v3" ] && pass "I1 session name: /rename title wins over a later AI title" || fail "I1 custom title" "got [$(sname "$SID_A")]"
[ "$(sname "$SID_B")" = "只有 AI 标题" ] && pass "I1b ... else the AI title, whitespace collapsed" || fail "I1b ai title" "got [$(sname "$SID_B")]"
[ "$(sname "$SID_C")" = "proj-4c" ] && pass "I1c ... else the session registry name" || fail "I1c registry" "got [$(sname "$SID_C")]"
[ "$(sname "$SID_D")" = "改过的线程名" ] && pass "I1d Codex: the last thread_name" || fail "I1d codex" "got [$(sname "$SID_D")]"
[ -z "$(sname "nope-0000")$(sname '')" ] && pass "I1e unknown ids -> empty" || fail "I1e empty"
[ -z "$(sname "../p1/$SID_A")" ] && pass "I1e2 an id that would traverse to another transcript is refused" || fail "I1e2 traversal" "got [$(sname "../p1/$SID_A")]"
[ "$(sname "$SID_B" "$FAKE_CC/projects/p1/$SID_A.jsonl")" = "combo v3" ] && pass "I1f an explicit transcript path is read first" || fail "I1f transcript arg"

inotify() { CLAUDE_CONFIG_DIR="$FAKE_CC" CODEX_HOME="$FAKE_CX" ZYZ_NOTIFY_CONFIG="$SB/notify-i.json" bash "$NOTIFY" "$@"; }
: > "$ICAP"
inotify --event stuck --origin stall --task-root "$ROOT" --session-id "$SID_A" --message "m1"
if grep -q '^stuck|combo v3|【combo v3】Agent 似乎卡住了|m1$' "$ICAP"; then pass "I2 the IM carries the session name (env + title prefix)"; else fail "I2 name in IM" "cap=[$(cat "$ICAP")]"; fi
printf '{"enabled":true,"command":"printf \\"%%s|%%s|%%s\\\\n\\" \\"$ZYZ_NOTIFY_EVENT\\" \\"$ZYZ_NOTIFY_SESSION_NAME\\" \\"$ZYZ_NOTIFY_TITLE\\" >> %s","cooldown_sec":0,"include_message":false}\n' "$ICAP" > "$SB/notify-i2.json"
: > "$ICAP"
CLAUDE_CONFIG_DIR="$FAKE_CC" ZYZ_NOTIFY_CONFIG="$SB/notify-i2.json" bash "$NOTIFY" --event stuck --origin stall --task-root "$ROOT" --session-id "$SID_A" --message m
if grep -q '^stuck||【aaaa1111】Agent 似乎卡住了$' "$ICAP"; then pass "I2b include_message=false: no derived name, the short session id instead"; else fail "I2b privacy" "cap=[$(cat "$ICAP")]"; fi

# AskUserQuestion pages after the delay unless answered first. The payload
# carries a session id, and a session with an id is armed only by its own
# pointer (never by the shared current-task), so arm SID_A for this task.
: > "$ICAP"; reset_runtime
mkdir -p "$PROJ/.zyz-worker/sessions"; printf '%s\n' "$ROOT" > "$PROJ/.zyz-worker/sessions/$SID_A"
ask='{"cwd":"%s","session_id":"%s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"用 A 还是 B？"},{"question":"现在发版吗？"}]}}'
printf "$ask" "$PROJ" "$SID_A" | CLAUDE_CONFIG_DIR="$FAKE_CC" ZYZ_NOTIFY_CONFIG="$SB/notify-i.json" ZYZ_NOTIFY_ASK_DELAY_SEC=1 bash "$HEARTBEAT"
for _ in $(seq 1 20); do [ -s "$ICAP" ] && break; sleep 0.3; done
if grep -q '^needs_input|combo v3|【combo v3】Agent 需要你的输入|主 agent 在问你：用 A 还是 B？ / 现在发版吗？$' "$ICAP"; then pass "I3 AskUserQuestion pages the user with the question (deferred)"; else fail "I3 ask IM" "cap=[$(cat "$ICAP")]"; fi
: > "$ICAP"
printf "$ask" "$PROJ" "$SID_A" | CLAUDE_CONFIG_DIR="$FAKE_CC" ZYZ_NOTIFY_CONFIG="$SB/notify-i.json" ZYZ_NOTIFY_ASK_DELAY_SEC=2 bash "$HEARTBEAT"
sleep 1.1
printf '{"cwd":"%s","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}' "$PROJ" | bash "$HEARTBEAT"
sleep 2.5
if [ ! -s "$ICAP" ]; then pass "I3b answered before the delay -> nothing sent"; else fail "I3b answered" "cap=[$(cat "$ICAP")]"; fi
: > "$ICAP"
printf '{"cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash"}' "$PROJ" | ZYZ_NOTIFY_CONFIG="$SB/notify-i.json" ZYZ_NOTIFY_ASK_DELAY_SEC=0 bash "$HEARTBEAT"
printf '{"cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read","agent_id":"ast9"}' "$PROJ" | ZYZ_NOTIFY_CONFIG="$SB/notify-i.json" ZYZ_NOTIFY_ASK_DELAY_SEC=0 bash "$HEARTBEAT"
sleep 1
if [ ! -s "$ICAP" ]; then pass "I3c ordinary main / subagent tool calls page nobody"; else fail "I3c no IM" "cap=[$(cat "$ICAP")]"; fi

# A question asked in prose: expect.sh user pages (deferred, dropped once answered).
: > "$ICAP"; reset_runtime
ZYZ_NOTIFY_CONFIG="$SB/notify-i.json" ZYZ_NOTIFY_ASK_DELAY_SEC=1 bash hooks/scripts/expect.sh --task "$ROOT" set q user --reason "选 A 还是 B" >/dev/null
for _ in $(seq 1 20); do [ -s "$ICAP" ] && break; sleep 0.3; done
if grep -q '^needs_input|.*|主 agent 在等你回复：选 A 还是 B$' "$ICAP"; then pass "I4 expect.sh set <key> user pages the user"; else fail "I4 user declaration IM" "cap=[$(cat "$ICAP")]"; fi
: > "$ICAP"
ZYZ_NOTIFY_CONFIG="$SB/notify-i.json" ZYZ_NOTIFY_ASK_DELAY_SEC=2 bash hooks/scripts/expect.sh --task "$ROOT" set q user --reason "再问一次" >/dev/null
sleep 1.1; printf '%s\n' "$(( $(date +%s) + 1 ))" > "$ROOT/runtime/user-prompt-epoch"; sleep 2.5
if [ ! -s "$ICAP" ]; then pass "I4b ... not when the user has replied within the delay"; else fail "I4b replied" "cap=[$(cat "$ICAP")]"; fi
: > "$ICAP"
ZYZ_NOTIFY_CONFIG="$SB/notify-i.json" ZYZ_NOTIFY_ASK_DELAY_SEC=0 bash hooks/scripts/expect.sh --task "$ROOT" set w wait --at +1h --reason x >/dev/null
ZYZ_NOTIFY_CONFIG="$SB/notify-i.json" ZYZ_NOTIFY_ASK_DELAY_SEC=0 bash hooks/scripts/expect.sh --task "$ROOT" set q user --reason "" >/dev/null 2>&1
sleep 1
if [ ! -s "$ICAP" ]; then pass "I4c a wait, or a refused user row, pages nobody"; else fail "I4c no IM" "cap=[$(cat "$ICAP")]"; fi

# --watch: the user is paged, the watchdog keeps watching.
write_status implementation; reset_runtime; set_activity 2100; set_state idle 2100
: > "$ICAP"
ZYZ_NOTIFY_CONFIG="$SB/notify-i.json" ZYZ_NOTIFY_ASK_DELAY_SEC=0 bash hooks/scripts/expect.sh --task "$ROOT" set q user --watch --reason "顺便问一下命名" >/dev/null
for _ in $(seq 1 20); do [ -s "$ICAP" ] && break; sleep 0.3; done
grep -q '^- Expect: key=q; kind=user; since=[0-9]*; watch=yes; reason=顺便问一下命名$' "$ROOT/status.md" && grep -q '^needs_input|' "$ICAP" \
    && pass "I5 user --watch writes watch=yes and pages the user" || fail "I5 watch row" "status=[$(grep Expect "$ROOT/status.md")] cap=[$(cat "$ICAP")]"
age_file "$ROOT/status.md" 2400
out="$(tick)"
if is_silence "$out"; then pass "I5b ... and does not mute session silence"; else fail "I5b watch mutes nothing" "out=[$out]"; fi
printf '%s 0 - 0\n' "$((NOW - 2100))" > "$ROOT/runtime/stop-snapshot"
out="$(tick)"
if printf '%s' "$out" | grep -q '没有任何执行者'; then pass "I5c ... nor no-executor"; else fail "I5c watch noexec" "out=[$out]"; fi
rm -f "$ROOT/runtime/stop-snapshot"
if bash hooks/scripts/expect.sh --task "$ROOT" set w wait --at +1h --watch --reason x >/dev/null 2>&1; then fail "I5d --watch is refused for wait"; else pass "I5d --watch is refused for kind wait"; fi
write_status implementation "- Expect: key=q; kind=user; since=$((NOW - 60)); watch=no; reason=x"
if bash hooks/scripts/expect.sh --task "$ROOT" list | grep -q '^INVALID'; then pass "I5e a hand-written watch=no row is INVALID"; else fail "I5e watch=no"; fi

# Silence duration is the main agent's choice, up to 24 h.
write_status implementation
if bash hooks/scripts/expect.sh --task "$ROOT" tune silence-sec=86400 remind-sec=86400 >/dev/null 2>&1 \
    && ! bash hooks/scripts/expect.sh --task "$ROOT" tune silence-sec=86401 >/dev/null 2>&1; then
    pass "I6 tune silence-sec / remind-sec accept 24 h and refuse more"
else
    fail "I6 24h cap" "status=[$(grep Tune "$ROOT/status.md")]"
fi
reset_runtime; set_state idle 80000; set_activity 80000; age_file "$ROOT/status.md" 80000
out="$(tick)"
if [ -z "$out" ]; then pass "I6b silence-sec=86400: 22 h quiet -> nothing"; else fail "I6b 22h" "out=[$out]"; fi
set_activity 86500; age_file "$ROOT/status.md" 86500
out="$(tick)"
if is_silence "$out"; then pass "I6c ... past 24 h it fires"; else fail "I6c 24h fires" "out=[$out]"; fi
write_status implementation; reset_runtime

# ===========================================================================
echo "--- G: documentation anchors ---"
grep -q '## 2. 设计方向：agent 主导，插件做工具与保障者' docs/design/watchdog-design.md 2>/dev/null \
    && pass "G1 docs/design/watchdog-design.md states the long-term direction" || fail "G1 design doc direction"
grep -q 'api-failure.sh' hooks/README.md && grep -q '会话静默' hooks/README.md \
    && pass "G2 hooks/README.md documents api-failure.sh and session silence" || fail "G2 hooks README"
grep -q '会话静默' skills/execute-task/SKILL.md && grep -q 'API 错误中断' skills/execute-task/SKILL.md \
    && pass "G3 SKILL.md watchdog section names both new findings" || fail "G3 SKILL.md"
grep -q 'silence-sec' skills/execute-task/SKILL.md && grep -q 'ZYZ_WATCHDOG_SILENCE_SEC' hooks/README.md \
    && pass "G4 the silence threshold is documented where thresholds live" || fail "G4 threshold docs"
grep -q '### 5.1 IM：只在需要人的时候发' docs/design/watchdog-design.md && grep -q '### IM 策略' hooks/README.md \
    && grep -q 'ZYZ_NOTIFY_SESSION_NAME' docs/notify.md && grep -q 'user --watch' skills/execute-task/SKILL.md \
    && pass "G6 the IM policy is documented (design doc, hooks README, notify.md, SKILL.md)" || fail "G6 IM policy docs"
! grep -q '"idle"' docs/notify.md hooks/scripts/notify.sh \
    && pass "G7 the retired idle category is gone from the notifier and its guide" || fail "G7 idle retired"
grep -q 'watchdog-design.md' docs/architecture.md \
    && pass "G5 architecture.md points to the design doc" || fail "G5 architecture pointer"

if [ ! -s "$SB/tick.err" ]; then pass "Z every watchdog tick ran without stderr (no set -u / parse crash)"; else fail "Z tick stderr" "$(head -5 "$SB/tick.err")"; fi

echo "----------------------------------------------------------------------"
echo "RESULT: $PASSED/$TOTAL checks passed"
[ "$FAILED" -eq 0 ]
