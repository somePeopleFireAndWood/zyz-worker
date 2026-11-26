#!/usr/bin/env bash
#
# test-no-executor.sh — the declaration-driven watchdog of #24: the
# "active task with no executor" detection, and the agent's declarations
# (expect.sh) that legitimately quiet it or schedule wake-ups.
#
# Covers, by driving the real hook/monitor scripts in a sandbox:
#   L4  stop-gate-main.sh  no-executor clause, observing-phase clause, the
#       stop-snapshot side effect, Tune of status-stale
#   L3  monitors/watchdog.sh  scan_declarations: due waits (wake + re-remind +
#       page), dead `wait --ref`, observing with nothing scheduled, no executor
#   L2  stop-gate-subagent.sh  waiting-ending check
#   L1  status-freshness.sh  declarations and Tune
#   expect.sh / expect_state.py  set / clear / tune / list and their refusals
#   lib.sh helpers (SubTask scoreboard parse, executor ids, residents),
#   heartbeat.sh / main-state.sh snapshot invalidation and the user-prompt epoch.
#
# WHAT THIS SUITE DOES NOT PROVE:
#  * The real fixed-pack observer's output. The live-role term is driven by a
#    stand-in runtime_state.py in a sandbox mirror (N12); that the real
#    observer reports non-terminal instances the same way lives in its own
#    suites (and is genesis-gated, i.e. inert on stock macOS).
#  * That Claude Code keeps the background_tasks shape probed on 2.1.251
#    (shell/subagent entries with status "running" that DISAPPEAR once
#    finished; the plugin watchdog monitor listed as a running shell task;
#    Monitor-tool watchers as shell tasks). How an idle persistent agent-team
#    teammate is listed was not reproducible and stays unverified; N1i only
#    pins the defensive status vocabulary.
#  * That a monitor stdout line actually wakes an idle session (platform).
#
# Mutation record (0.30.0, each mutant applied to an out-of-tree copy): 41
# targeted mutants across L1/L3/L4, expect_state.py and lib.sh; every one turns
# a check red except these equivalent ones, recorded rather than hidden:
#  - L4 `own_active` term: zyz_task_has_pending_work already needs an active phase.
#  - read_snapshot mapping a 2-field snapshot's ids to "" instead of leaving
#    `unknown`: zyz_expect_eval maps "" to unknown anyway.
#  - scan()'s `last` ignoring blank lines / the sections==1 guard: comment lines
#    are skipped before it, and a second section makes the writer refuse; the
#    only difference is whether a row lands before or after a blank line.
#  - edit_rows' verify(): defence in depth behind a placement that is correct
#    by construction, so no input reaches it.
#
# Mutation record (task-notification is not the user speaking, N4h–N4k; each
# mutant applied in place to main-state.sh, restored from a backup copy): 6
# mutants, all red — never take the skip branch (N4h/N4i/N4k), drop the
# user_spoke guard on the epoch write (N4h/N4i/N4k), no indentation strip
# (N4i), look only at the first line (N4i), substring instead of prefix match
# (N4j), also skip the stop-snapshot delete (N4h). That the host fires
# UserPromptSubmit for `<task-notification>` turns and NOT for agent-team
# teammate messages was probed on Claude Code 2.1.251 (interactive, team mode);
# this suite only pins the plugin's reaction to that prompt shape.
#
# Usage:  bash scripts/test-no-executor.sh   (exit 0 iff every check passed)

set -u
# Never reach the user's real IM (~/.zyz-worker/notify.json): checks that
# exercise the notifier point ZYZ_NOTIFY_CONFIG at their own capture config.
ZYZ_TEST_NO_NOTIFY="/nonexistent/zyz-worker-test/notify.json"
export ZYZ_NOTIFY_CONFIG="$ZYZ_TEST_NO_NOTIFY"
set -o pipefail
unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
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

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP  all — python3 unavailable"; echo "RESULT: 0/0 checks passed (all skipped)"; exit 0
fi

LIB="hooks/scripts/lib.sh"
STOP_MAIN="hooks/scripts/stop-gate-main.sh"
STOP_SUB="hooks/scripts/stop-gate-subagent.sh"
HEARTBEAT="hooks/scripts/heartbeat.sh"
MAIN_STATE="hooks/scripts/main-state.sh"
WATCHDOG="monitors/watchdog.sh"

for f in "$LIB" "$STOP_MAIN" "$STOP_SUB" "$HEARTBEAT" "$MAIN_STATE" "$WATCHDOG"; do
    if bash -n "$f" 2>/dev/null; then pass "S0 syntax: $f"; else fail "S0 syntax: $f"; fi
done

SB="$(mktemp -d "${TMPDIR:-/tmp}/zyz-no-executor.XXXXXX")"
cleanup() { rm -rf "$SB" 2>/dev/null || true; }
trap cleanup EXIT
PROJ="$SB/proj"
ROOT="$PROJ/.zyz-worker/tasks/demo-task"
mkdir -p "$ROOT"
printf 'demo-task\n' > "$PROJ/.zyz-worker/current-task"
export ZYZ_NOTIFY_CONFIG="$SB/no-notify.json"

NOW="$(date +%s)"
WATCHDOG_SHELL='{"id":"b1","type":"shell","status":"running","description":"execute-task watchdog","command":"\"/home/u/.claude/plugins/cache/zyz-worker/zyz-worker/0.28.0\"/monitors/watchdog.sh \"/p\""}'

# write_status <phase> [agent-state-rows] [subtasks-section]
write_status() {
    {
        printf '# 任务状态\n\n## 元数据\n\n- Current Phase: %s\n\n## Agent State\n\n- 主 agent: x\n' "$1"
        [ -z "${2:-}" ] || printf '%s\n' "$2"
        printf '\n## SubTasks\n\n'
        [ -z "${3:-}" ] || printf '%s\n' "$3"
        printf '\n## 下一步行动\n\n- 下一步: x\n'
    } > "$ROOT/status.md"
}
reset_runtime() { rm -rf "$ROOT/runtime" 2>/dev/null; }
# stop_json <background_tasks-json|ABSENT> [session_crons-json] [stop_hook_active]
stop_json() {
    local bt=""
    [ "$1" = ABSENT ] || bt=",\"background_tasks\":$1"
    printf '{"cwd":"%s","hook_event_name":"Stop","stop_hook_active":%s%s,"session_crons":%s}' \
        "$PROJ" "${3:-false}" "$bt" "${2:-[]}"
}
run_stop() { stop_json "$@" | ZYZ_STOP_GATE_COOLDOWN_SEC=0 bash "$STOP_MAIN" 2>/dev/null; }
is_noexec_block() { printf '%s' "$1" | grep -q '"decision"' && printf '%s' "$1" | grep -q '没有任何执行者'; }

LIST_ST='- SubTask ID: ST1
- Committed: abc1234
- SubTask ID: ST4
- Committed:'

# ===========================================================================
echo "--- N1: L4 no-executor clause ---"
write_status implementation "" "$LIST_ST"; reset_runtime
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N1a active + empty background_tasks + no wait -> block"; else fail "N1a block" "out=[$out]"; fi
if printf '%s' "$out" | grep -q 'SubTask ST4 尚未提交'; then pass "N1b reason names the uncommitted SubTask"; else fail "N1b uncommitted named" "out=[$out]"; fi
if printf '%s' "$out" | grep -q 'ST1'; then fail "N1c committed ST1 must not be listed" "out=[$out]"; else pass "N1c committed ST1 not listed"; fi
if printf '%s' "$out" | grep -q 'expect.sh --task' && printf '%s' "$out" | grep -q 'set <key> user'; then pass "N1d reason teaches expect.sh (user / wait / resident)"; else fail "N1d expect.sh hint" "out=[$out]"; fi

out="$(run_stop "[$WATCHDOG_SHELL]")"
if is_noexec_block "$out"; then pass "N1e plugin watchdog monitor alone is not an executor"; else fail "N1e watchdog monitor excluded" "out=[$out]"; fi
out="$(run_stop '[{"id":"m","type":"shell","status":"running","command":"/x/.claude/plugins/cache/other/p/1.0/monitors/poll.sh"}]')"
if is_noexec_block "$out"; then pass "N1f another plugin monitor is not an executor"; else fail "N1f plugin monitor excluded" "out=[$out]"; fi
out="$(run_stop '[{"id":"m","type":"shell","status":"running","command":"\"/home/u/src/zyz-worker\"/monitors/watchdog.sh \"/p\""}]')"
if is_noexec_block "$out"; then pass "N1f2 project-mode watchdog monitor (no plugins/ path) is not an executor"; else fail "N1f2 project-mode watchdog" "out=[$out]"; fi
out="$(run_stop '[{"id":"s","type":"shell","status":"running","command":"go test ./..."}]')"
if [ -z "$out" ]; then pass "N1g running shell task -> no block"; else fail "N1g running shell" "out=[$out]"; fi
out="$(run_stop '[{"id":"a","type":"subagent","status":"running","agent_type":"zyz-worker:implementation-agent"}]')"
if [ -z "$out" ]; then pass "N1h running background subagent -> no block"; else fail "N1h running subagent" "out=[$out]"; fi
out="$(run_stop '[{"id":"a","type":"subagent","status":"completed"},{"id":"t","type":"teammate","status":"idle"}]')"
if is_noexec_block "$out"; then pass "N1i completed subagent + idle teammate are not executors"; else fail "N1i finished entries" "out=[$out]"; fi
out="$(run_stop '[]' '[{"id":"c","schedule":"*/5 * * * *","recurring":true,"prompt":"p"}]')"
if [ -z "$out" ]; then pass "N1j a session cron/wakeup -> no block"; else fail "N1j session cron" "out=[$out]"; fi
out="$(run_stop ABSENT)"
if [ -z "$out" ]; then pass "N1k no background_tasks array (Codex) -> fail open"; else fail "N1k absent array" "out=[$out]"; fi
out="$(run_stop '[]' '[]' true)"
if [ -z "$out" ]; then pass "N1l stop_hook_active -> never blocks"; else fail "N1l stop_hook_active" "out=[$out]"; fi

write_status design "" "$LIST_ST"
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N1m design phase -> no block"; else fail "N1m design" "out=[$out]"; fi

# ===========================================================================
echo "--- N2: delivery phase needs an uncommitted SubTask ---"
write_status delivery "" '- SubTask ID: ST1
- Committed: abc1234'
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N2a delivery with every SubTask committed -> no block"; else fail "N2a delivery all committed" "out=[$out]"; fi
write_status delivery "" "$LIST_ST"
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N2b delivery with an uncommitted SubTask -> block"; else fail "N2b delivery uncommitted" "out=[$out]"; fi
write_status delivery "" '| SubTask | Coded | Committed |
|---|---|---|
| ST1 | true | abc1234 |
| ST7 | true | （未提交） |'
out="$(run_stop '[]')"
if is_noexec_block "$out" && printf '%s' "$out" | grep -q 'SubTask ST7 尚未提交'; then
    pass "N2c table scoreboard parsed (ST7 uncommitted)"; else fail "N2c table scoreboard" "out=[$out]"; fi

# ===========================================================================
echo "--- N3: explicit waits mute it, idle does not ---"
write_status implementation "- Awaiting-User: since-epoch=$((NOW - 10)); reason=等用户裁决 ST4 的接口方案" "$LIST_ST"
reset_runtime
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N3a valid Awaiting-User -> no block"; else fail "N3a Awaiting-User" "out=[$out]"; fi
mkdir -p "$ROOT/runtime"; printf '%s\n' "$((NOW - 2))" > "$ROOT/runtime/user-prompt-epoch"
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N3b Awaiting-User lapses once the user has spoken since"; else fail "N3b lapse" "out=[$out]"; fi
write_status implementation "- Awaiting-User: since-epoch=$((NOW + 3600)); reason=x" "$LIST_ST"; reset_runtime
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N3c future since-epoch is invalid"; else fail "N3c future" "out=[$out]"; fi
write_status implementation "- Awaiting-User: since-epoch=$((NOW - 10)); reason=  " "$LIST_ST"
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N3d blank reason is invalid"; else fail "N3d blank reason" "out=[$out]"; fi
write_status implementation "- Awaiting-User: since-epoch=$((NOW - 10)); reason=a
- Awaiting-User: since-epoch=$((NOW - 9)); reason=b" "$LIST_ST"
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N3e duplicate rows: the first stands, the duplicate is reported and ignored"; else fail "N3e duplicate rows" "out=[$out]"; fi
write_status implementation "- Waiting On: instance-key=lane-a; since-epoch=$((NOW - 60)); next-check-epoch=$((NOW + 600)); reason=全量用例" "$LIST_ST"
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N3f valid Waiting On -> no block"; else fail "N3f Waiting On" "out=[$out]"; fi
write_status implementation "" "$LIST_ST"
( . "$LIB"; zyz_main_state_set "$ROOT" idle )
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N3g main-state idle does not mute it"; else fail "N3g idle" "out=[$out]"; fi
( . "$LIB"; zyz_main_state_set "$ROOT" awaiting-user )
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N3h main-state awaiting-user (e.g. idle_prompt) does not mute it"; else fail "N3h awaiting-user" "out=[$out]"; fi

# ===========================================================================
echo "--- N4: cooldown + stop-snapshot ---"
reset_runtime
out1="$(stop_json '[]' | ZYZ_STOP_GATE_COOLDOWN_SEC=600 bash "$STOP_MAIN" 2>/dev/null)"
out2="$(stop_json '[]' | ZYZ_STOP_GATE_COOLDOWN_SEC=600 bash "$STOP_MAIN" 2>/dev/null)"
if is_noexec_block "$out1" && [ -z "$out2" ]; then pass "N4a blocks once per cooldown window"; else fail "N4a cooldown" "1=[$out1] 2=[$out2]"; fi
snap="$(cat "$ROOT/runtime/stop-snapshot" 2>/dev/null)"
case "$snap" in [0-9]*" 0 - 0") pass "N4b snapshot written as '<epoch> 0 -' (also inside the cooldown)" ;; *) fail "N4b snapshot" "[$snap]" ;; esac
run_stop '[{"id":"s","type":"shell","status":"running","command":"sleep 9"}]' '[]' true >/dev/null
snap="$(cat "$ROOT/runtime/stop-snapshot" 2>/dev/null)"
case "$snap" in [0-9]*" 1 s 0") pass "N4c snapshot written under stop_hook_active too, with the running id ('<epoch> 1 s')" ;; *) fail "N4c snapshot" "[$snap]" ;; esac
run_stop ABSENT >/dev/null
snap="$(cat "$ROOT/runtime/stop-snapshot" 2>/dev/null)"
case "$snap" in [0-9]*" unknown unknown 0") pass "N4d snapshot records unknown without background_tasks" ;; *) fail "N4d snapshot" "[$snap]" ;; esac
printf '{"cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read"}' "$PROJ" | bash "$HEARTBEAT" >/dev/null 2>&1
if [ ! -e "$ROOT/runtime/stop-snapshot" ]; then pass "N4e a main-agent tool call deletes the snapshot"; else fail "N4e heartbeat delete"; fi
run_stop '[]' >/dev/null
printf '{"cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read","agent_id":"sub1","agent_type":"zyz-worker:test-agent"}' "$PROJ" | bash "$HEARTBEAT" >/dev/null 2>&1
if [ -e "$ROOT/runtime/stop-snapshot" ]; then pass "N4f a subagent tool call keeps it"; else fail "N4f subagent keeps snapshot"; fi
printf '{"cwd":"%s","hook_event_name":"UserPromptSubmit"}' "$PROJ" | bash "$MAIN_STATE" >/dev/null 2>&1
upe="$(cat "$ROOT/runtime/user-prompt-epoch" 2>/dev/null)"
if [ ! -e "$ROOT/runtime/stop-snapshot" ] && [ -n "$upe" ] && [ "$upe" -ge "$NOW" ]; then
    pass "N4g UserPromptSubmit deletes the snapshot and stamps user-prompt-epoch"; else fail "N4g user prompt" "upe=[$upe]"; fi
# A host task-notification turn (background subagent / Bash finished, a monitor
# line) also fires UserPromptSubmit (verified, Claude Code 2.1.251) — it is not
# the user speaking, so the epoch stays and a `user` declaration stays valid.
tn_prompt() { printf '{"cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$PROJ" "$1" | bash "$MAIN_STATE" >/dev/null 2>&1; }
printf '%s\n' "$((NOW - 50))" > "$ROOT/runtime/user-prompt-epoch"
run_stop '[]' >/dev/null
tn_prompt '<task-notification>\n<task-id>bx1</task-id>\n<status>completed</status>\n</task-notification>'
upe="$(cat "$ROOT/runtime/user-prompt-epoch" 2>/dev/null)"
if [ "$upe" = "$((NOW - 50))" ] && [ ! -e "$ROOT/runtime/stop-snapshot" ] \
    && [ "$(awk '{print $1}' "$ROOT/runtime/main-state")" = working ]; then
    pass "N4h a task-notification turn: working, snapshot deleted, user-prompt-epoch NOT stamped"; else fail "N4h task-notification" "upe=[$upe] state=[$(cat "$ROOT/runtime/main-state")]"; fi
tn_prompt '  \n  <task-notification>\n<summary>Monitor event</summary>\n</task-notification>'
upe="$(cat "$ROOT/runtime/user-prompt-epoch" 2>/dev/null)"
if [ "$upe" = "$((NOW - 50))" ]; then pass "N4i ... also after leading blank lines and indentation"; else fail "N4i leading whitespace" "upe=[$upe]"; fi
tn_prompt 'please look at <task-notification> handling'
upe="$(cat "$ROOT/runtime/user-prompt-epoch" 2>/dev/null)"
if [ -n "$upe" ] && [ "$upe" -ge "$NOW" ]; then pass "N4j a human prompt merely mentioning the tag still counts as the user speaking"; else fail "N4j human prompt" "upe=[$upe]"; fi
write_status implementation "- Awaiting-User: since-epoch=$((NOW - 10)); reason=等用户裁决 ST4 的接口方案" "$LIST_ST"
reset_runtime
tn_prompt '<task-notification>\n<task-id>bx2</task-id>\n</task-notification>'
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N4k a task-notification arriving while waiting on the user keeps Awaiting-User valid"; else fail "N4k declaration lapsed on a notification" "out=[$out]"; fi
write_status implementation "" "$LIST_ST"

# ===========================================================================
echo "--- N5: L3 no-executor scan ---"
run_wd() { ZYZ_WATCHDOG_ONCE=1 ZYZ_WATCHDOG_COOLDOWN_SEC="${2:-900}" ZYZ_WATCHDOG_NO_EXECUTOR_SEC="${1:-600}" bash "$WATCHDOG" "$PROJ" 2>/dev/null; }
set_snap() { mkdir -p "$ROOT/runtime"; printf '%s %s\n' "$1" "$2" > "$ROOT/runtime/stop-snapshot"; }
write_status implementation "" "$LIST_ST"; reset_runtime
( . "$LIB"; zyz_main_state_set "$ROOT" awaiting-user )
set_snap "$((NOW - 700))" 0
out="$(run_wd)"
if printf '%s' "$out" | grep -q '没有任何执行者'; then pass "N5a stopped 700s ago with 0 executors -> line (despite awaiting-user state)"; else fail "N5a L3 fires" "out=[$out]"; fi
out="$(run_wd)"
if printf '%s' "$out" | grep -q '没有任何执行者'; then fail "N5b repeated within cooldown" "out=[$out]"; else pass "N5b rate-limited by its cooldown"; fi
reset_runtime
mkdir -p "$ROOT/runtime/nag"; date +%s > "$ROOT/runtime/nag/stopgate.last"
set_snap "$((NOW - 700))" 0
out="$(run_wd)"
if printf '%s' "$out" | grep -q '没有任何执行者'; then pass "N5c fires while the L4 gate is in its cooldown"; else fail "N5c independent of L4 cooldown" "out=[$out]"; fi
reset_runtime; set_snap "$((NOW - 100))" 0
out="$(run_wd)"
if [ -z "$out" ]; then pass "N5d stopped only 100s ago -> silent"; else fail "N5d young snapshot" "out=[$out]"; fi
reset_runtime; set_snap "$((NOW - 700))" 1
out="$(run_wd)"
if [ -z "$out" ]; then pass "N5e an executor was in flight at the Stop -> silent"; else fail "N5e executor" "out=[$out]"; fi
reset_runtime; set_snap "$((NOW - 700))" unknown
out="$(run_wd)"
if [ -z "$out" ]; then pass "N5f unknown executors -> silent"; else fail "N5f unknown" "out=[$out]"; fi
reset_runtime
out="$(run_wd)"
if [ -z "$out" ]; then pass "N5g no snapshot (main agent active since) -> silent"; else fail "N5g no snapshot" "out=[$out]"; fi
write_status implementation "- Awaiting-User: since-epoch=$((NOW - 10)); reason=等用户确认" "$LIST_ST"
reset_runtime; set_snap "$((NOW - 700))" 0
out="$(run_wd)"
if [ -z "$out" ]; then pass "N5h explicit Awaiting-User -> silent"; else fail "N5h Awaiting-User" "out=[$out]"; fi

# stall-origin IM survives the idle suppression that drops main-origin stuck.
# 0.32.0: it is an escalation — the first report wakes the main agent, the
# same finding unanswered on a later scan pages (ESCALATE=0 here).
CAP="$SB/cap.txt"
printf '{"enabled":true,"command":"{ printf %s $ZYZ_NOTIFY_EVENT; } >> %s","cooldown_sec":0}\n' "'EV=%s '" "$CAP" > "$SB/notify.json"
write_status implementation "" "$LIST_ST"; reset_runtime
( . "$LIB"; zyz_main_state_set "$ROOT" idle )
set_snap "$((NOW - 700))" 0
ZYZ_WATCHDOG_ESCALATE_SEC=0 ZYZ_NOTIFY_CONFIG="$SB/notify.json" run_wd 600 0 >/dev/null
sleep 0.5
if [ -s "$CAP" ]; then fail "N5i0 the first no-executor report pages nobody" "cap=[$(cat "$CAP")]"; else pass "N5i0 the first no-executor report pages nobody"; fi
ZYZ_WATCHDOG_ESCALATE_SEC=0 ZYZ_NOTIFY_CONFIG="$SB/notify.json" run_wd 600 0 >/dev/null
i=0; while [ ! -s "$CAP" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if grep -q 'EV=stuck' "$CAP" 2>/dev/null; then pass "N5i stuck IM sent while main-state is idle (origin stall)"; else fail "N5i stall IM" "cap=[$(cat "$CAP" 2>/dev/null)]"; fi

# ===========================================================================
echo "--- N6: due waits wake the main agent, then re-remind ---"
is_due() { printf '%s' "$1" | grep -q "到点了：你声明的等待 $2"; }
is_rem() { printf '%s' "$1" | grep -q "次提醒：等待 $2"; }
write_status implementation "- Waiting On: instance-key=lane-a; since-epoch=$((NOW - 120)); next-check-epoch=$((NOW - 5)); reason=DuckDB 全量用例" "$LIST_ST"
reset_runtime
out="$(run_wd)"
if is_due "$out" lane-a && printf '%s' "$out" | grep -q 'DuckDB 全量用例'; then pass "N6a due legacy Waiting On -> wake-up naming key and reason"; else fail "N6a due reminder" "out=[$out]"; fi
out="$(run_wd)"
if is_due "$out" lane-a || is_rem "$out" lane-a; then fail "N6b reported again inside remind-sec" "out=[$out]"; else pass "N6b not repeated inside remind-sec"; fi
set -- $(cat "$ROOT/runtime/nag/expect-due-lane-a"); printf '%s %s %s\n' "$1" "$(( $2 - 1900 ))" "$3" > "$ROOT/runtime/nag/expect-due-lane-a"
out="$(run_wd)"
if is_rem "$out" lane-a && printf '%s' "$out" | grep -q '第 2 次提醒'; then pass "N6c re-reminds after remind-sec (default 1800s) while the row is unchanged"; else fail "N6c re-remind" "out=[$out]"; fi
write_status implementation "- Waiting On: instance-key=lane-a; since-epoch=$((NOW - 120)); next-check-epoch=$((NOW - 2)); reason=DuckDB 全量用例" "$LIST_ST"
out="$(run_wd)"
if is_due "$out" lane-a; then pass "N6d a re-set time re-arms immediately as a fresh wake-up"; else fail "N6d re-arm" "out=[$out]"; fi
write_status implementation "- Waiting On: instance-key=lane-b; since-epoch=$((NOW - 120)); next-check-epoch=$((NOW + 600)); reason=x" "$LIST_ST"
reset_runtime
out="$(run_wd)"
if [ -z "$out" ]; then pass "N6e a row not yet due -> silent"; else fail "N6e not yet due" "out=[$out]"; fi

# ===========================================================================
echo "--- N7: L2 waiting-ending check ---"
write_status implementation "" "$LIST_ST"; reset_runtime
TR_BG="$SB/agent-bg.jsonl"; TR_MON="$SB/agent-mon.jsonl"; TR_NONE="$SB/agent-none.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"go test ./... > /tmp/t.log 2>&1","run_in_background":true}}]}}' > "$TR_BG"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Monitor","input":{"command":"tail -f /tmp/t.log"}}]}}' > "$TR_MON"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"go test ./..."}}]}}' > "$TR_NONE"
sub_json() { # <agent-id> <message> <transcript|""> [stop_hook_active]
    python3 -c 'import json,sys
d={"cwd":sys.argv[1],"hook_event_name":"SubagentStop","agent_id":sys.argv[2],"agent_type":"zyz-worker:implementation-agent","last_assistant_message":sys.argv[3],"stop_hook_active":sys.argv[5]=="true"}
if sys.argv[4]: d["agent_transcript_path"]=sys.argv[4]
print(json.dumps(d))' "$PROJ" "$1" "$2" "$3" "${4:-false}"
}
run_sub() { sub_json "$@" | bash "$STOP_SUB" 2>/dev/null; }
is_wait_block() { printf '%s' "$1" | grep -q '"decision"' && printf '%s' "$1" | grep -q '等待后台任务'; }
out="$(run_sub ag1 'Waiting for the completion notification.' "$TR_BG")"
if is_wait_block "$out"; then pass "N7a 'waiting' ending + run_in_background -> waiting block"; else fail "N7a" "out=[$out]"; fi
out="$(run_sub ag1 'Waiting on the monitor notifications.' "$TR_BG" true)"
if [ -z "$out" ]; then pass "N7b at most once per role instance"; else fail "N7b once" "out=[$out]"; fi
out="$(run_sub ag2 'Waiting on the monitor notifications.' "$TR_MON" true)"
if is_wait_block "$out"; then pass "N7c blocks even under stop_hook_active (the incident's second ending)"; else fail "N7c stop_hook_active" "out=[$out]"; fi
out="$(run_sub ag3 '已经在后台启动 DuckDB 全量用例（约 60 分钟），等待完成通知后再汇报结果，届时更新 SubTask 状态文件。' "$TR_MON")"
if is_wait_block "$out"; then pass "N7d Chinese waiting ending + Monitor -> block"; else fail "N7d Chinese" "out=[$out]"; fi
long_wait='Implemented ST4 in internal/dw/sync.go and added cases in sync_test.go; the full suite was started. Waiting for the test run to finish.'
out="$(run_sub ag4 "$long_wait" "$TR_NONE")"
if [ -z "$out" ]; then pass "N7e no background evidence in the transcript -> pass"; else fail "N7e no evidence" "out=[$out]"; fi
out="$(run_sub ag5 "$long_wait" "")"
if is_wait_block "$out"; then pass "N7f no transcript (host without it) -> phrase alone blocks"; else fail "N7f no transcript" "out=[$out]"; fi
done_msg='Implemented ST4 in internal/dw/sync.go; go test ./internal/dw/... passed 131/131 (rc=0). No blockers; ready for review.'
out="$(run_sub ag6 "$done_msg" "$TR_BG")"
if [ -z "$out" ]; then pass "N7g a finished report with background evidence -> pass"; else fail "N7g finished report" "out=[$out]"; fi
out="$(run_sub ag8 '全量用例仍在后台运行中（任务 b7x，日志 /tmp/t.log，预计 22:25 完成），完成后请主 agent 读取日志并派发变异验证。' "$TR_BG")"
if [ -z "$out" ]; then pass "N7i an explicit hand-off to the main agent is not blocked"; else fail "N7i hand-off" "out=[$out]"; fi
out="$(run_sub ag7 'ok' "$TR_NONE")"
if printf '%s' "$out" | grep -q '最终消息太短'; then pass "N7h short-message check unchanged"; else fail "N7h short message" "out=[$out]"; fi

# ===========================================================================
echo "--- N9: the real status template ---"
# status.md is created from the template, whose `## Agent State` carries an
# HTML comment documenting the row formats with example `- Waiting On:` and
# `- Awaiting-User:` lines. Those examples must not make real rows invalid.
TPL="skills/execute-task/templates/task-status.md"
from_template() { # <phase> [row to add under ## Agent State]
    python3 - "$TPL" "$ROOT/status.md" "$1" "${2:-}" <<'PY'
import sys
tpl, out, phase, row = sys.argv[1:5]
s = open(tpl, encoding="utf-8").read()
s = s.replace("- Current Phase:", "- Current Phase: " + phase, 1)
if row:
    s = s.replace("- reviewAgent:\n", "- reviewAgent:\n" + row + "\n", 1)
open(out, "w", encoding="utf-8").write(s)
PY
}
reset_runtime
from_template implementation "- Awaiting-User: since-epoch=$((NOW - 10)); reason=等用户裁决接口方案"
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N9a template-based status + valid Awaiting-User -> no block"; else fail "N9a template Awaiting-User" "out=[$out]"; fi
set_snap "$((NOW - 700))" 0
out="$(run_wd)"
if [ -z "$out" ]; then pass "N9b ...and L3 stays silent"; else fail "N9b template Awaiting-User L3" "out=[$out]"; fi
from_template implementation "- Waiting On: instance-key=lane-a; since-epoch=$((NOW - 60)); next-check-epoch=$((NOW + 600)); reason=全量用例"
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N9c template-based status + valid Waiting On -> no block"; else fail "N9c template Waiting On" "out=[$out]"; fi
from_template implementation
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N9d template-based status without a declaration -> block"; else fail "N9d template no declaration" "out=[$out]"; fi

# ===========================================================================
echo "--- N10: Committed shapes the docs allow ---"
write_status delivery "" '- SubTask ID: ST1
- Committed:
  - api:abc1234
  - web:def5678
- SubTask ID: ST2
- Committed: [abc1234](https://example.com/commit/abc1234)
- SubTask ID: ST3
- Committed: 未推送（无 remote），本地 commit 9f8e7d6
- SubTask ID: ST4
- Committed: commit 失败：pre-commit hook 拒绝'
reset_runtime
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N10a multi-repo / linked / local-only / failed commits all count as committed"; else fail "N10a committed shapes" "out=[$out]"; fi
write_status delivery "" '- SubTask ID: ST1
- Committed:
  - api:abc1234
- SubTask ID: ST2
- Committed: （本 SubTask 自主提交的 commit sha）
- 备注: x'
out="$(run_stop '[]')"
if is_noexec_block "$out" && printf '%s' "$out" | grep -q 'SubTask ST2 尚未提交'; then
    pass "N10b the template placeholder is uncommitted (and ST1 is not listed)"; else fail "N10b placeholder" "out=[$out]"; fi
if printf '%s' "$out" | grep -q 'ST1'; then fail "N10c ST1 listed" "out=[$out]"; else pass "N10c multi-repo ST1 not listed"; fi

# ===========================================================================
echo "--- N11: L3 mutes ---"
write_status implementation "- Waiting On: instance-key=lane-a; since-epoch=$((NOW - 60)); next-check-epoch=$((NOW + 600)); reason=x" "$LIST_ST"
reset_runtime; set_snap "$((NOW - 700))" 0
out="$(run_wd)"
if [ -z "$out" ]; then pass "N11a valid Waiting On -> L3 no-executor silent"; else fail "N11a L3 Waiting On" "out=[$out]"; fi
write_status delivery "" '- SubTask ID: ST1
- Committed: abc1234'
reset_runtime; set_snap "$((NOW - 700))" 0
out="$(run_wd)"
if [ -z "$out" ]; then pass "N11b delivery with everything committed -> L3 silent"; else fail "N11b L3 pending-work gate" "out=[$out]"; fi

# ===========================================================================
echo "--- N12: live roles (stand-in observer) and multi-task scope ---"
# The real fixed-pack observer is inert without GENESIS (stock macOS), so a
# sandbox mirror replaces runtime_state.py with one that returns
# <task>/fake-observe.json (same technique as test-session-pointer.sh S8).
M="$SB/mirror"; mkdir -p "$M"
cp -R hooks monitors "$M/"
cat > "$M/hooks/scripts/runtime_state.py" <<'PY'
import os, sys
if len(sys.argv) > 2 and sys.argv[1] == "hook-observe":
    p = os.path.join(sys.argv[2], "fake-observe.json")
    sys.stdout.write(open(p).read() if os.path.exists(p) else '{"ok":false}')
PY
live_obs() { printf '{"ok":true,"state":"observed","main_heartbeat_epoch":%s,"instances":[{"instance_key":"k-live","role":"test-agent","terminal":false,"tracking_capability":"armed","last_liveness_epoch":%s}]}' "$NOW" "$((NOW - 30))" > "$1/fake-observe.json"; }
done_obs() { printf '{"ok":true,"state":"observed","main_heartbeat_epoch":%s,"instances":[{"instance_key":"k-done","role":"test-agent","terminal":true,"terminal_epoch":%s}]}' "$NOW" "$((NOW - 30))" > "$1/fake-observe.json"; }
m_stop() { stop_json '[]' | ZYZ_STOP_GATE_COOLDOWN_SEC=0 bash "$M/hooks/scripts/stop-gate-main.sh" 2>/dev/null; }
m_wd() { ZYZ_WATCHDOG_ONCE=1 ZYZ_WATCHDOG_COOLDOWN_SEC=0 ZYZ_WATCHDOG_NO_EXECUTOR_SEC=600 bash "$M/monitors/watchdog.sh" "$PROJ" 2>/dev/null; }
write_status implementation "" "$LIST_ST"; reset_runtime
live_obs "$ROOT"
out="$(m_stop)"
if [ -z "$out" ]; then pass "N12a L4: an open dispatched role is an executor"; else fail "N12a L4 live role" "out=[$out]"; fi
set_snap "$((NOW - 700))" 0
out="$(m_wd)"
if printf '%s' "$out" | grep -q '没有任何执行者'; then fail "N12b L3 live role" "out=[$out]"; else pass "N12b L3: an open dispatched role is an executor"; fi
done_obs "$ROOT"; reset_runtime
out="$(m_stop)"
if is_noexec_block "$out"; then pass "N12c L4: a terminal role is not"; else fail "N12c L4 terminal role" "out=[$out]"; fi
set_snap "$((NOW - 700))" 0
out="$(m_wd)"
if printf '%s' "$out" | grep -q '没有任何执行者'; then pass "N12d L3: a terminal role is not"; else fail "N12d L3 terminal role" "out=[$out]"; fi
# Two tasks in one session: the primary (records) is in design, the second is
# active. The live role recorded under the primary keeps BOTH quiet; without
# it only the active task is named.
ROOT2="$PROJ/.zyz-worker/tasks/second-task"; mkdir -p "$ROOT2"
printf -- '- Current Phase: implementation\n## Agent State\n## SubTasks\n' > "$ROOT2/status.md"
write_status design "" "$LIST_ST"; reset_runtime; rm -rf "$ROOT2/runtime"
mkdir -p "$PROJ/.zyz-worker/sessions"
printf '%s\n%s\n' "$ROOT" "$ROOT2" > "$PROJ/.zyz-worker/sessions/sess-24"
live_obs "$ROOT"
out="$(stop_json '[]' | ZYZ_SESSION_ID=sess-24 ZYZ_STOP_GATE_COOLDOWN_SEC=0 bash "$M/hooks/scripts/stop-gate-main.sh" 2>/dev/null)"
if [ -z "$out" ]; then pass "N12e multi-task: a live role under the primary counts session-wide"; else fail "N12e multi-task live" "out=[$out]"; fi
done_obs "$ROOT"
out="$(stop_json '[]' | ZYZ_SESSION_ID=sess-24 ZYZ_STOP_GATE_COOLDOWN_SEC=0 bash "$M/hooks/scripts/stop-gate-main.sh" 2>/dev/null)"
if is_noexec_block "$out" && printf '%s' "$out" | grep -q '任务 second-task' && ! printf '%s' "$out" | grep -q '任务 demo-task'; then
    pass "N12f multi-task: only the active task is named"; else fail "N12f multi-task scope" "out=[$out]"; fi
rm -rf "$PROJ/.zyz-worker/sessions" "$ROOT2"

# in_section <file> <regex>: 0 when a line matching <regex> is inside the single
# `## Agent State` section and OUTSIDE any HTML comment (what the parser sees).
in_section() {
    python3 - "$1" "$2" <<'PY'
import re, sys
sys.path.insert(0, "hooks/scripts")
import expect_state
sections, lines = expect_state.agent_state_lines(open(sys.argv[1], encoding="utf-8").read())
sys.exit(0 if sections == 1 and any(re.search(sys.argv[2], l) for _, l in lines) else 1)
PY
}

# ===========================================================================
echo "--- N13: expect.sh (the agent's declarations) ---"
EXP="hooks/scripts/expect.sh"
exp() { bash "$EXP" --task "$ROOT" "$@"; }
write_status implementation "" "$LIST_ST"; reset_runtime
if exp set srv resident --ref bwrnt9uyc --reason "vite dev server" >/dev/null \
    && grep -qx -- '- Expect: key=srv; kind=resident; ref=bwrnt9uyc; reason=vite dev server' "$ROOT/status.md"; then
    pass "N13a set resident writes one validated row into ## Agent State"; else fail "N13a set resident" "$(grep -n Expect "$ROOT/status.md")"; fi
if in_section "$ROOT/status.md" '^- Expect: key=srv;'; then
    pass "N13b the row lands inside the Agent State section, outside comments"; else fail "N13b row placement"; fi
exp set srv resident --ref other123 --reason "vite dev server" >/dev/null
if [ "$(grep -c 'key=srv;' "$ROOT/status.md")" = 1 ] && grep -q 'ref=other123' "$ROOT/status.md"; then
    pass "N13c set with the same key replaces the row"; else fail "N13c replace" "$(grep -n Expect "$ROOT/status.md")"; fi
before="$(cksum < "$ROOT/status.md")"
exp set bad resident --reason x >/dev/null 2>&1; r1=$?
exp set bad wait --reason x >/dev/null 2>&1; r2=$?
exp set bad wait --at +10m --reason "" >/dev/null 2>&1; r3=$?
exp set bad wait --at +30d --reason x >/dev/null 2>&1; r4=$?
exp set 'bad key' user --reason x >/dev/null 2>&1; r5=$?
exp tune remind-sec=5 >/dev/null 2>&1; r6=$?
exp tune bogus=600 >/dev/null 2>&1; r7=$?
if [ "$r1$r2$r3$r4$r5$r6$r7" != 0000000 ] && [ "$r1" != 0 ] && [ "$r2" != 0 ] && [ "$r3" != 0 ] && [ "$r4" != 0 ] \
    && [ "$r5" != 0 ] && [ "$r6" != 0 ] && [ "$r7" != 0 ] && [ "$(cksum < "$ROOT/status.md")" = "$before" ]; then
    pass "N13d invalid declarations are refused and leave status.md untouched"; else fail "N13d refusals" "rcs=$r1$r2$r3$r4$r5$r6$r7"; fi
exp clear srv >/dev/null
if grep -q 'key=srv;' "$ROOT/status.md"; then fail "N13e clear"; else pass "N13e clear removes the row"; fi
exp clear nosuch >/dev/null 2>&1 && fail "N13f clear of an unknown key succeeds" || pass "N13f clear of an unknown key fails loudly"
exp set w1 wait --at +2h --reason a >/dev/null; exp set u1 user --reason b >/dev/null
exp clear --all >/dev/null
if grep -q '^- Expect:' "$ROOT/status.md"; then fail "N13g clear --all"; else pass "N13g clear --all removes every Expect row"; fi
exp set w2 wait --at +90m --reason "看批跑" >/dev/null
python3 - "$ROOT/status.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("- 主 agent: x\n", "- 主 agent: x\n- Expect: key=broken; kind=wait; at=soon; reason=x\n", 1))
PY
lst="$(exp list)"
if printf '%s' "$lst" | grep -q '^valid *wait *w2' && printf '%s' "$lst" | grep -q '^INVALID'; then
    pass "N13h list shows valid rows and flags a hand-written broken row"; else fail "N13h list" "$lst"; fi
cp "$ROOT/status.md" "$SB/s.bak"
TPL_ROOT="$SB/tpl"; mkdir -p "$TPL_ROOT"; cp skills/execute-task/templates/task-status.md "$TPL_ROOT/status.md"
bash "$EXP" --task "$TPL_ROOT" set w wait --at +1h --reason x >/dev/null
if in_section "$TPL_ROOT/status.md" '^- Expect: key=w;' \
    && [ "$(grep -c '^## Agent State' "$TPL_ROOT/status.md")" = 1 ] \
    && python3 hooks/scripts/expect_state.py evalsh "$TPL_ROOT/status.md" 0 unknown | grep -qx "mutes$(printf '\t')1"; then
    pass "N13i works on a template-created status.md (comment block left intact)"; else fail "N13i template"; fi
out="$( (cd "$PROJ" && bash "$OLDPWD/$EXP" list) 2>&1)"
if printf '%s' "$out" | grep -q 'w2'; then pass "N13j defaults to this session's primary task"; else fail "N13j default task" "$out"; fi

# ===========================================================================
echo "--- N14: declarations drive the checks ---"
write_status implementation "" "$LIST_ST"; reset_runtime
SRV='{"id":"srv1","type":"shell","status":"running","command":"npm run dev"}'
out="$(run_stop "[$SRV]")"
if [ -z "$out" ]; then pass "N14a an undeclared dev server counts as an executor"; else fail "N14a undeclared" "out=[$out]"; fi
exp set srv resident --ref srv1 --reason "dev server for e2e" >/dev/null
out="$(run_stop "[$SRV]")"
if is_noexec_block "$out"; then pass "N14b declared resident -> not an executor -> block"; else fail "N14b resident" "out=[$out]"; fi
snap="$(cat "$ROOT/runtime/stop-snapshot")"
case "$snap" in [0-9]*" 0 srv1 0") pass "N14c snapshot: 0 executors, running ids kept" ;; *) fail "N14c snapshot" "[$snap]" ;; esac
out="$(run_stop "[$SRV,{\"id\":\"t9\",\"type\":\"shell\",\"status\":\"running\",\"command\":\"go test ./...\"}]")"
if [ -z "$out" ]; then pass "N14d resident + a real run -> the real run is an executor"; else fail "N14d mixed" "out=[$out]"; fi
out="$(run_stop '[]' '[{"id":"cr1","schedule":"0 * * * *","recurring":true,"prompt":"p"}]')"
if [ -z "$out" ]; then pass "N14e an undeclared cron counts"; else fail "N14e cron" "out=[$out]"; fi
exp set cr resident --ref cr1 --reason "unrelated hourly cron" >/dev/null
out="$(run_stop '[]' '[{"id":"cr1","schedule":"0 * * * *","recurring":true,"prompt":"p"}]')"
if is_noexec_block "$out"; then pass "N14f a cron declared resident does not count"; else fail "N14f resident cron" "out=[$out]"; fi
exp clear --all >/dev/null
# wait --ref: honoured while its task runs, dropped (and reported) once it is gone
exp set lane wait --at +2h --ref t9 --reason "全量用例" >/dev/null
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N14g wait --ref whose task is gone does not mute (fact beats declaration)"; else fail "N14g dead ref" "out=[$out]"; fi
reset_runtime
# Discriminating form: t9 is running but declared resident, so it is not an
# executor; only the wait (whose ref IS running) can keep L4 quiet.
exp set t9r resident --ref t9 --reason "only here to zero the executor count" >/dev/null
out="$(run_stop '[{"id":"t9","type":"shell","status":"running","command":"go test ./..."}]')"
if [ -z "$out" ]; then pass "N14h wait --ref with its task running mutes (executor count is 0 here)"; else fail "N14h live ref" "out=[$out]"; fi
exp clear t9r >/dev/null
set_snap "$((NOW - 700))" "0 -"
out="$(run_wd)"
if printf '%s' "$out" | grep -q '绑定的后台任务 t9 已经不在运行了'; then pass "N14i L3 reports a wait whose ref task is gone"; else fail "N14i dead ref L3" "out=[$out]"; fi
out="$(run_wd 600 0)"
if printf '%s' "$out" | grep -q '已经不在运行了'; then fail "N14j dead ref repeated" "out=[$out]"; else pass "N14j ...once per (key, ref)"; fi
exp clear --all >/dev/null
# wait without ref (outside batch job): mutes until due
exp set batch wait --at +3h --reason "等 T+1 批跑" >/dev/null
reset_runtime
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N14k wait (no ref) before its time mutes L4"; else fail "N14k wait mutes" "out=[$out]"; fi
set_snap "$((NOW - 700))" 0
out="$(run_wd)"
if [ -z "$out" ]; then pass "N14l ...and L3"; else fail "N14l wait mutes L3" "out=[$out]"; fi
exp clear --all >/dev/null
# user via expect.sh, lapses on the next user prompt
exp set q user --reason "等用户裁决接口方案" >/dev/null
reset_runtime
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N14m set user mutes"; else fail "N14m user" "out=[$out]"; fi
sleep 1
printf '{"cwd":"%s","hook_event_name":"UserPromptSubmit"}' "$PROJ" | bash "$MAIN_STATE" >/dev/null 2>&1
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N14n ...until the user speaks again"; else fail "N14n user lapse" "out=[$out]"; fi
exp clear --all >/dev/null
# Tune: per-task thresholds
write_status implementation "" "$LIST_ST"; reset_runtime
exp tune no-executor-sec=3600 >/dev/null
set_snap "$((NOW - 700))" 0
out="$(run_wd)"
if [ -z "$out" ]; then pass "N14o Tune no-executor-sec=3600 -> L3 waits longer"; else fail "N14o tune L3" "out=[$out]"; fi
exp tune --clear >/dev/null
out="$(run_wd)"
if printf '%s' "$out" | grep -q '没有任何执行者'; then pass "N14p ...back to the default once cleared"; else fail "N14p tune clear" "out=[$out]"; fi
reset_runtime
touch -t "$(date -r $((NOW - 1500)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((NOW - 1500)) +%Y%m%d%H%M.%S)" "$ROOT/status.md"
out="$(run_stop '[{"id":"s","type":"shell","status":"running","command":"x"}]')"
if printf '%s' "$out" | grep -q '分钟没有更新'; then pass "N14q status 25 min old -> status-stale block at the default 20 min"; else fail "N14q stale default" "out=[$out]"; fi
cp "$ROOT/status.md" "$SB/keep"; exp tune status-stale-sec=3600 >/dev/null
touch -t "$(date -r $((NOW - 1500)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((NOW - 1500)) +%Y%m%d%H%M.%S)" "$ROOT/status.md"
reset_runtime
out="$(run_stop '[{"id":"s","type":"shell","status":"running","command":"x"}]')"
if [ -z "$out" ]; then pass "N14r Tune status-stale-sec=3600 relaxes L4"; else fail "N14r tune L4" "out=[$out]"; fi
out="$(printf '{"cwd":"%s","tool_name":"Bash"}' "$PROJ" | bash hooks/scripts/status-freshness.sh 2>/dev/null)"
if [ -z "$out" ]; then pass "N14s ...and L1"; else fail "N14s tune L1" "out=[$out]"; fi
exp tune --clear >/dev/null
touch -t "$(date -r $((NOW - 1500)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((NOW - 1500)) +%Y%m%d%H%M.%S)" "$ROOT/status.md"
rm -rf "$ROOT/runtime/nag"
out="$(printf '{"cwd":"%s","tool_name":"Bash"}' "$PROJ" | bash hooks/scripts/status-freshness.sh 2>/dev/null)"
if printf '%s' "$out" | grep -q 'additionalContext'; then pass "N14t L1 nags again without the Tune row"; else fail "N14t L1 default" "out=[$out]"; fi
exp set batch wait --at +3h --reason "等 T+1 批跑" >/dev/null
touch -t "$(date -r $((NOW - 1500)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((NOW - 1500)) +%Y%m%d%H%M.%S)" "$ROOT/status.md"
rm -rf "$ROOT/runtime/nag"
out="$(printf '{"cwd":"%s","tool_name":"Bash"}' "$PROJ" | bash hooks/scripts/status-freshness.sh 2>/dev/null)"
if [ -z "$out" ]; then pass "N14u an Expect wait mutes L1 too"; else fail "N14u L1 wait" "out=[$out]"; fi
exp clear --all >/dev/null
# A hand-written wait beyond ZYZ_EXPECT_MAX_SEC (7 days) is ignored, not honoured.
python3 - "$ROOT/status.md" "$((NOW + 30 * 86400))" <<'PY'
import sys
p, at = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("- 主 agent: x\n", "- 主 agent: x\n- Expect: key=far; kind=wait; at=%s; ref=-; reason=x\n" % at, 1))
PY
reset_runtime
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N14v a hand-written wait beyond 7 days does not mute"; else fail "N14v horizon" "out=[$out]"; fi
if bash "$EXP" --task "$ROOT" list | grep -q '^note.*more than'; then pass "N14w ...and list says why"; else fail "N14w horizon note"; fi
write_status implementation "" "$LIST_ST"
# The template documents the row format inside an HTML comment. Even a
# well-formed row there is documentation, not a declaration.
from_template implementation
python3 - "$ROOT/status.md" "$((NOW + 3600))" <<'PY'
import sys
p, at = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
s = s.replace("expect.sh 写出来的行形如：\n", "expect.sh 写出来的行形如：\n- Expect: key=doc; kind=wait; at=%s; ref=-; reason=example\n" % at, 1)
open(p, "w", encoding="utf-8").write(s)
PY
if grep -q 'key=doc; kind=wait' "$ROOT/status.md"; then pass "N14x0 fixture: a well-formed row sits inside the template comment"; else fail "N14x0 fixture"; fi
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N14x a well-formed Expect row inside an HTML comment mutes nothing"; else fail "N14x comment row" "out=[$out]"; fi
write_status implementation "" "$LIST_ST"

# ===========================================================================
echo "--- N15: observing phase (main work delivered, checks scheduled) ---"
write_status observing "" "$LIST_ST"; reset_runtime
out="$(run_stop '[]')"
if printf '%s' "$out" | grep -q '"decision"' && printf '%s' "$out" | grep -q 'observing（观察期）'; then
    pass "N15a observing with nothing scheduled -> L4 blocks once"; else fail "N15a observing L4" "out=[$out]"; fi
if is_noexec_block "$out"; then fail "N15b observing must not raise no-executor" "out=[$out]"; else pass "N15b observing is not an active phase (no no-executor)"; fi
out="$(stop_json '[]' | ZYZ_STOP_GATE_COOLDOWN_SEC=600 bash "$STOP_MAIN" 2>/dev/null)"
if [ -z "$out" ]; then pass "N15c ...rate-limited by the cooldown"; else fail "N15c observing cooldown" "out=[$out]"; fi
out="$(run_wd)"
if printf '%s' "$out" | grep -q 'observing（观察期）'; then pass "N15d L3 reports it too"; else fail "N15d observing L3" "out=[$out]"; fi
out="$(run_wd 600 0)"
if printf '%s' "$out" | grep -q 'observing（观察期）'; then fail "N15e repeated inside ZYZ_WATCHDOG_OBSERVE_SEC" "out=[$out]"; else pass "N15e ...with its own long cooldown"; fi
exp set recon wait --at +1d --reason "T+1 批跑完后核对 dws 与源表行数和金额" >/dev/null
reset_runtime
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N15f a scheduled wait (even a day out) satisfies observing"; else fail "N15f scheduled" "out=[$out]"; fi
touch -t "$(date -r $((NOW - 7200)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((NOW - 7200)) +%Y%m%d%H%M.%S)" "$ROOT/status.md"
out="$(run_wd 600 0)"
if [ -z "$out" ]; then pass "N15g quiet between checks: no status-stale, no no-executor, no nag"; else fail "N15g quiet" "out=[$out]"; fi
out="$(printf '{"cwd":"%s","tool_name":"Bash"}' "$PROJ" | bash hooks/scripts/status-freshness.sh 2>/dev/null)"
if [ -z "$out" ]; then pass "N15h ...and no L1 freshness reminder"; else fail "N15h L1 quiet" "out=[$out]"; fi
# the check comes due: wake, re-remind, then page the user
python3 - "$ROOT/status.md" "$((NOW - 30))" <<'PY'
import re, sys
p, at = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(re.sub(r"(key=recon; kind=wait; at=)\d+", r"\g<1>" + at, s))
PY
CAP2="$SB/cap2.txt"; : > "$CAP2"
printf '{"enabled":true,"command":"{ printf %s $ZYZ_NOTIFY_EVENT; } >> %s","cooldown_sec":0}\n' "'EV=%s '" "$CAP2" > "$SB/notify2.json"
out="$(ZYZ_NOTIFY_CONFIG="$SB/notify2.json" run_wd)"
if is_due "$out" recon && printf '%s' "$out" | grep -q '核对 dws 与源表'; then pass "N15i at the scheduled time: wake-up with the reason"; else fail "N15i due wake" "out=[$out]"; fi
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N15i2 a due (not yet handled) wait still counts as scheduled for L4"; else fail "N15i2 due counts" "out=[$out]"; fi
out="$(ZYZ_NOTIFY_CONFIG="$SB/notify2.json" run_wd)"
if [ -z "$out" ]; then pass "N15j silent until remind-sec"; else fail "N15j quiet after wake" "out=[$out]"; fi
age_mark() { set -- $(cat "$ROOT/runtime/nag/expect-due-recon"); printf '%s %s %s\n' "$1" "$(( $2 - 1900 ))" "$3" > "$ROOT/runtime/nag/expect-due-recon"; }
sleep 0.5
if [ ! -s "$CAP2" ]; then pass "N15k0 the first due wake-up pages nobody"; else fail "N15k0 first wake" "cap=[$(cat "$CAP2")]"; fi
age_mark; out="$(ZYZ_WATCHDOG_ESCALATE_SEC=0 ZYZ_NOTIFY_CONFIG="$SB/notify2.json" run_wd)"
i=0; while [ ! -s "$CAP2" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if printf '%s' "$out" | grep -q '第 2 次提醒' && grep -q 'EV=stuck' "$CAP2"; then pass "N15k an unanswered reminder pages the user (escalation)"; else fail "N15k page" "out=[$out] cap=[$(cat "$CAP2")]"; fi
: > "$CAP2"
age_mark; out3="$(ZYZ_WATCHDOG_ESCALATE_SEC=0 ZYZ_NOTIFY_CONFIG="$SB/notify2.json" run_wd)"
sleep 0.5
if printf '%s' "$out3" | grep -q '第 3 次提醒' && [ ! -s "$CAP2" ]; then pass "N15k2 ... once per silent stretch (the 3rd reminder still wakes, pages nobody)"; else fail "N15k2 once" "out=[$out3] cap=[$(cat "$CAP2")]"; fi
exp tune remind-sec=7200 >/dev/null
age_mark; out="$(run_wd)"
if [ -z "$out" ]; then pass "N15l Tune remind-sec=7200 spaces reminders out"; else fail "N15l tune remind" "out=[$out]"; fi
exp tune --clear >/dev/null
exp set recon wait --at +6h --reason "再核对一次" >/dev/null
out="$(run_wd 600 0)"
if [ -z "$out" ]; then pass "N15m re-set to a later time -> quiet again"; else fail "N15m reset" "out=[$out]"; fi
write_status done "" "$LIST_ST"; reset_runtime
out="$(run_stop '[]')$(run_wd 600 0)"
if [ -z "$out" ]; then pass "N15n done -> nothing at all"; else fail "N15n done" "out=[$out]"; fi

# ===========================================================================
echo "--- N16: review round 2 (writer integrity, cross-layer agreement) ---"
# B4: parallel expect.sh calls must not drop rows.
write_status implementation "" "$LIST_ST"; reset_runtime
for k in p1 p2 p3 p4 p5 p6 p7 p8; do exp set "$k" wait --at +2h --reason "parallel $k" >/dev/null & done; wait
n="$(grep -c '^- Expect: key=p[1-8];' "$ROOT/status.md")"
if [ "$n" = 8 ]; then pass "N16a 8 parallel sets keep all 8 rows (locked read-modify-write)"; else fail "N16a parallel set" "rows=$n"; fi
exp clear --all >/dev/null
# B5: a multi-line comment holding a `## ` line, and a comment that mentions the heading.
cat > "$ROOT/status.md" <<'MD'
# 任务状态
- Current Phase: implementation
<!-- this mentions
## Agent State
but is only a comment -->

## Agent State

- 主 agent: x
<!-- notes
## not a heading
-->

## SubTasks
- SubTask ID: ST4
- Committed:
MD
exp set w wait --at +1h --reason x >/dev/null; rc=$?
if [ "$rc" = 0 ] && in_section "$ROOT/status.md" '^- Expect: key=w;' \
    && python3 hooks/scripts/expect_state.py evalsh "$ROOT/status.md" 0 unknown | grep -qx "mutes$(printf '\t')1"; then
    pass "N16b comments holding '## ' lines do not misplace the row"; else fail "N16b comment layout" "rc=$rc $(cat "$ROOT/status.md")"; fi
# The section's last non-blank line is the closing line of a comment whose
# body would swallow anything inserted before it: the row must go after it.
cat > "$ROOT/status.md" <<'MD'
- Current Phase: implementation
## Agent State
<!-- documentation only
- Expect: key=doc; kind=user; since=1; reason=example -->
## SubTasks
- SubTask ID: ST4
- Committed:
MD
exp set w wait --at +1h --reason x >/dev/null; rc=$?
if [ "$rc" = 0 ] && in_section "$ROOT/status.md" '^- Expect: key=w;' && ! in_section "$ROOT/status.md" 'key=doc'; then
    pass "N16b2 a section ending in a comment: the row goes after it, the commented example stays inert"; else fail "N16b2 trailing comment" "rc=$rc $(cat "$ROOT/status.md")"; fi
# A layout the writer cannot place a live row into is refused, never a silent success.
python3 - "$ROOT/status.md" <<'PY'
import sys
sys.path.insert(0, "hooks/scripts")
import expect_state
# simulate a writer that misplaces the row: verify() must catch it
p = sys.argv[1]
ok = expect_state.read_rows("## Agent State\n<!-- x\n- Expect: key=z; kind=user; since=1; reason=r\n-->\n")[0]
sys.exit(0 if not ok else 1)
PY
if [ $? = 0 ]; then pass "N16b3 a row inside a comment is never a declaration (what verify relies on)"; else fail "N16b3"; fi
# N6/N7: CRLF kept; trailing space on the heading is still the same section.
printf -- '- Current Phase: implementation\r\n## Agent State \r\n- 主 agent: x\r\n## SubTasks\r\n' > "$ROOT/status.md"
exp set w wait --at +1h --reason x >/dev/null
if [ "$(grep -c '^## Agent State' "$ROOT/status.md")" = 1 ] && [ "$(tr -cd '\r' < "$ROOT/status.md" | wc -c | tr -d ' ')" = 5 ]; then
    pass "N16c CRLF preserved and a heading with a trailing space is not duplicated"; else fail "N16c crlf/heading" "$(od -c "$ROOT/status.md" | head -5)"; fi
printf '\xff\xfe broken\n' > "$ROOT/status.md"
out="$(exp set w wait --at +1h --reason x 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'not valid UTF-8' && ! printf '%s' "$out" | grep -q Traceback; then
    pass "N16d non-UTF-8 status.md -> one-line diagnostic, no traceback"; else fail "N16d utf8" "$out"; fi
# B1: Tune can never tighten a check, in any layer.
write_status implementation "" "$LIST_ST"; reset_runtime
exp tune no-executor-sec=60 >/dev/null
set_snap "$((NOW - 120))" 0
out="$(run_wd)"
if [ -z "$out" ]; then pass "N16e Tune no-executor-sec=60 does not tighten L3 below its 600s default"; else fail "N16e tune tighten L3" "out=[$out]"; fi
exp tune --clear >/dev/null; exp tune status-stale-sec=900 >/dev/null
touch -t "$(date -r $((NOW - 1000)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((NOW - 1000)) +%Y%m%d%H%M.%S)" "$ROOT/status.md"
reset_runtime
out="$(ZYZ_WATCHDOG_ONCE=1 ZYZ_WATCHDOG_COOLDOWN_SEC=0 bash "$WATCHDOG" "$PROJ" 2>/dev/null)"
if printf '%s' "$out" | grep -q '分钟没有更新'; then fail "N16f tune tighten L3 status" "out=[$out]"; else pass "N16f Tune status-stale-sec=900 does not tighten L3 below its 1800s default"; fi
out="$(ZYZ_STOP_STATUS_STALE_SEC=1200 run_stop '[{"id":"s","type":"shell","status":"running","command":"x"}]')"
if [ -z "$out" ]; then pass "N16g ...nor L4 below its 1200s default"; else fail "N16g tune tighten L4" "out=[$out]"; fi
exp tune --clear >/dev/null
out="$(exp tune status-stale-sec=86400 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then pass "N16h status-stale-sec is capped at 4h (86400 refused)"; else fail "N16h cap" "$out"; fi
# B2 + M12/M13: L3 status-stale honours a wait and Tune, and checks a wait's ref
# against the last Stop's running ids.
write_status implementation "" "$LIST_ST"; reset_runtime
touch -t "$(date -r $((NOW - 2000)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((NOW - 2000)) +%Y%m%d%H%M.%S)" "$ROOT/status.md"
wd_stale() { ZYZ_WATCHDOG_ONCE=1 ZYZ_WATCHDOG_COOLDOWN_SEC=0 bash "$WATCHDOG" "$PROJ" 2>/dev/null | grep -c '分钟没有更新'; }
if [ "$(wd_stale)" = 1 ]; then pass "N16i baseline: L3 status-stale fires at 33 min"; else fail "N16i baseline"; fi
exp set lane wait --at +2h --ref t9 --reason x >/dev/null
touch -t "$(date -r $((NOW - 2000)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((NOW - 2000)) +%Y%m%d%H%M.%S)" "$ROOT/status.md"
set_snap "$NOW" "1 t9 0"
if [ "$(wd_stale)" = 0 ]; then pass "N16j a wait whose ref is running mutes L3 status-stale"; else fail "N16j L3 wait mutes stale"; fi
set_snap "$NOW" "1 other9 0"
if [ "$(wd_stale)" = 1 ]; then pass "N16k ...but not once its ref is gone from the last Stop's list (fact beats declaration)"; else fail "N16k L3 dead ref stale"; fi
rm -f "$ROOT/runtime/stop-snapshot"
if [ "$(wd_stale)" = 0 ]; then pass "N16l with no snapshot the ref is unknown, so the wait still mutes"; else fail "N16l unknown ref"; fi
set_snap "$NOW" "1"
if [ "$(wd_stale)" = 0 ]; then pass "N16m a two-field (pre-0.30) snapshot means unknown ids, not 'nothing ran'"; else fail "N16m legacy snapshot"; fi
exp clear --all >/dev/null; exp tune status-stale-sec=3600 >/dev/null
touch -t "$(date -r $((NOW - 2000)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((NOW - 2000)) +%Y%m%d%H%M.%S)" "$ROOT/status.md"
if [ "$(wd_stale)" = 0 ]; then pass "N16n Tune status-stale-sec=3600 relaxes L3"; else fail "N16n L3 tune relax"; fi
exp tune --clear >/dev/null
# N4: a user declaration mutes no-executor but NOT status-stale.
exp set q user --reason "等用户" >/dev/null
touch -t "$(date -r $((NOW - 2000)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((NOW - 2000)) +%Y%m%d%H%M.%S)" "$ROOT/status.md"
reset_runtime
out="$(ZYZ_STOP_STATUS_STALE_SEC=1200 run_stop '[]')"
if printf '%s' "$out" | grep -q '分钟没有更新' && ! is_noexec_block "$out"; then
    pass "N16o user mutes no-executor, not status-stale (keep status fresh if you keep working)"; else fail "N16o user scope" "out=[$out]"; fi
exp clear --all >/dev/null
# M6: a due wait suppresses the generic no-executor line (it has its own).
write_status implementation "- Expect: key=late; kind=wait; at=$((NOW - 30)); ref=-; reason=x" "$LIST_ST"; reset_runtime
set_snap "$((NOW - 700))" "0 - 0"
out="$(run_wd)"
if is_due "$out" late && ! printf '%s' "$out" | grep -q '没有任何执行者'; then pass "N16p a due wait replaces the generic no-executor line"; else fail "N16p due vs noexec" "out=[$out]"; fi
# M9 + N2: what counts as "scheduled" for observing.
write_status observing "" "$LIST_ST"; reset_runtime
exp set q user --reason "等用户确认对账口径" >/dev/null
out="$(run_stop '[]')"
if [ -z "$out" ]; then pass "N16q observing + a valid user declaration -> not blocked"; else fail "N16q observing user" "out=[$out]"; fi
exp clear --all >/dev/null; reset_runtime
out="$(run_stop '[]' '[{"id":"c1","schedule":"0 9 * * *","recurring":true,"prompt":"对账"}]')"
if [ -z "$out" ]; then pass "N16r observing + a host cron -> not blocked"; else fail "N16r observing cron" "out=[$out]"; fi
set_snap "$((NOW - 100))" "0 - 1"
out="$(run_wd 600 0)"
if [ -z "$out" ]; then pass "N16s ...and L3 reads the cron from the snapshot"; else fail "N16s L3 cron" "out=[$out]"; fi
exp set c resident --ref c1 --reason "unrelated cron" >/dev/null; reset_runtime
out="$(run_stop '[]' '[{"id":"c1","schedule":"0 9 * * *","recurring":true,"prompt":"x"}]')"
if printf '%s' "$out" | grep -q 'observing（观察期）'; then pass "N16t ...unless that cron is declared resident"; else fail "N16t resident cron" "out=[$out]"; fi
exp clear --all >/dev/null
# B3: unknown declarations (no python3 for the evaluator) fail open.
write_status observing "- Expect: key=recon; kind=wait; at=$((NOW + 86400)); ref=-; reason=x" "$LIST_ST"; reset_runtime
NOPY="$SB/nopy"; mkdir -p "$NOPY"
for t in bash sh cat awk sed grep tr head date mkdir mv rm basename dirname cksum wc stat touch printf env jq mktemp sleep cut; do
    p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$NOPY/$t"
done
if command -v jq >/dev/null 2>&1; then
    out="$(stop_json '[]' | PATH="$NOPY" ZYZ_STOP_GATE_COOLDOWN_SEC=0 "$NOPY/bash" "$STOP_MAIN" 2>/dev/null)"
    if [ -z "$out" ]; then pass "N16u jq but no python3: observing with a scheduled wait is not blocked (fail open)"; else fail "N16u no python" "out=[$out]"; fi
    out="$(PATH="$NOPY" ZYZ_WATCHDOG_ONCE=1 ZYZ_WATCHDOG_COOLDOWN_SEC=0 "$NOPY/bash" "$WATCHDOG" "$PROJ" 2>/dev/null)"
    if [ -z "$out" ]; then pass "N16u2 ...and L3 stays silent too"; else fail "N16u2 no python L3" "out=[$out]"; fi
else
    pass "N16u (jq unavailable; hooks need jq or python3, so the no-python3 path cannot run here)"
fi
# M11: residents from every task of the session count.
ROOT2="$PROJ/.zyz-worker/tasks/second-task"; mkdir -p "$ROOT2"
printf -- '- Current Phase: implementation\n## Agent State\n## SubTasks\n- SubTask ID: ST9\n- Committed:\n' > "$ROOT2/status.md"
write_status design "- Expect: key=srv; kind=resident; ref=srv1; reason=dev server" "$LIST_ST"; reset_runtime
mkdir -p "$PROJ/.zyz-worker/sessions"; printf '%s\n%s\n' "$ROOT" "$ROOT2" > "$PROJ/.zyz-worker/sessions/sess-30"
out="$(stop_json "[$SRV]" | ZYZ_SESSION_ID=sess-30 ZYZ_STOP_GATE_COOLDOWN_SEC=0 bash "$STOP_MAIN" 2>/dev/null)"
if is_noexec_block "$out" && printf '%s' "$out" | grep -q '任务 second-task'; then pass "N16v a resident declared in one task (the first) counts for every task of the session"; else fail "N16v cross-task resident" "out=[$out]"; fi
rm -rf "$PROJ/.zyz-worker/sessions" "$ROOT2"
# M21: two Agent State sections -> declarations ignored (and the writer refuses).
printf -- '- Current Phase: implementation\n## Agent State\n- Expect: key=w; kind=wait; at=%s; ref=-; reason=x\n## Agent State\n## SubTasks\n- SubTask ID: ST4\n- Committed:\n' "$((NOW + 3600))" > "$ROOT/status.md"; reset_runtime
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N16w two Agent State sections: no declaration is honoured"; else fail "N16w two sections" "out=[$out]"; fi
exp set x user --reason y >/dev/null 2>&1 && fail "N16x writer accepts two sections" || pass "N16x ...and expect.sh refuses to write"
# M22: a malformed ref is refused at write time and ignored at read time.
write_status implementation "" "$LIST_ST"
exp set w wait --at +1h --ref 'bad ref!' --reason x >/dev/null 2>&1 && fail "N16y bad ref accepted" || pass "N16y a malformed --ref is refused"
write_status implementation "- Expect: key=w; kind=wait; at=$((NOW + 3600)); ref=bad ref!; reason=x" "$LIST_ST"; reset_runtime
out="$(run_stop '[]')"
if is_noexec_block "$out"; then pass "N16z ...and a hand-written one mutes nothing"; else fail "N16z bad ref row" "out=[$out]"; fi
# N1: legacy Waiting On with next-check-epoch=0 is invalid, not due.
write_status implementation "- Waiting On: instance-key=z; since-epoch=$((NOW - 60)); next-check-epoch=0; reason=x" "$LIST_ST"; reset_runtime
out="$(run_wd 600 0)"
if is_due "$out" z; then fail "N16aa next-check-epoch=0 treated as due" "out=[$out]"; else pass "N16aa legacy next-check-epoch=0 is invalid, never 'due'"; fi
write_status implementation "" "$LIST_ST"

# ===========================================================================
echo "--- N8: helpers ---"
obs='{"ok":true,"state":"observed","instances":[{"terminal":false,"last_liveness_epoch":'"$((NOW - 30))"'},{"terminal":true},{"terminal":false,"last_liveness_epoch":'"$((NOW - 99999))"'},{"terminal":false}]}'
n="$(printf '%s' "$obs" | ( . "$LIB"; zyz_live_role_count 21600 ))"
if [ "$n" = 2 ]; then pass "N8a live roles: non-terminal within horizon (and epoch-less) count"; else fail "N8a live count" "got [$n]"; fi
n="$(printf '%s' '{"ok":false,"state":"genesis-capability-unavailable"}' | ( . "$LIB"; zyz_live_role_count 21600 ))"
if [ -z "$n" ]; then pass "N8b unobservable -> empty (unknown), not 0"; else fail "N8b unobservable" "got [$n]"; fi
n="$( ( ZYZ_HOOK_INPUT='{"background_tasks":[{"id":"x","type":"workflow","status":"running"},{"id":"y","type":"MCP task","status":"failed"},{"type":"shell","status":"running"}],"session_crons":[{"id":"c1"}]}'; . "$LIB"; zyz_bg_executor_ids ) )"
if [ "$n" = "x,?,c1" ]; then pass "N8c executor ids: unknown types and crons count, failed ones do not, id-less is ?"; else fail "N8c executor ids" "got [$n]"; fi
n="$( ( . "$LIB"; zyz_executors_left "x,?,c1,x" ",c1,," ) )"
if [ "$n" = 3 ]; then pass "N8d residents subtracted by exact id (both x entries and ? remain)"; else fail "N8d executors_left" "got [$n]"; fi
# A resident row can never carry `?` (ref must match the id grammar), so an
# id-less background task is always counted.
exp_out="$(bash hooks/scripts/expect.sh --task "$ROOT" set q resident --ref '?' --reason x 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then pass "N8e a resident ref of '?' is refused"; else fail "N8e ? ref" "$exp_out"; fi

echo
echo "RESULT: $PASSED/$TOTAL checks passed${SKIPPED:+ ($SKIPPED skipped)}"
[ "$FAILED" -eq 0 ]
