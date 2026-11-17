#!/usr/bin/env bash
#
# test-no-executor.sh — the "active task with no executor" detection (#24).
#
# Covers, by driving the real hook/monitor scripts in a sandbox:
#   L4  stop-gate-main.sh  no-executor clause (c) + the stop-snapshot side effect
#   L3  monitors/watchdog.sh  scan_no_executor + the Waiting On due reminder
#   L2  stop-gate-subagent.sh  waiting-ending check
#   shared helpers in hooks/scripts/lib.sh (Awaiting-User lapse, SubTask
#   scoreboard parse, executor count), heartbeat.sh / main-state.sh snapshot
#   invalidation and the user-prompt epoch.
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
# Mutation record (scripts edited in place, restored byte-for-byte after each):
# every guard below has a check that turns red when it is removed, except the
# L4 `own_active` term, which is an equivalent mutant —
# zyz_task_has_pending_work already requires an active phase.
#
# Usage:  bash scripts/test-no-executor.sh   (exit 0 iff every check passed)

set -u
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
if printf '%s' "$out" | grep -q 'Awaiting-User: since-epoch='; then pass "N1d reason teaches the Awaiting-User row"; else fail "N1d Awaiting-User hint"; fi

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
if is_noexec_block "$out"; then pass "N3e two Awaiting-User rows are invalid"; else fail "N3e duplicate rows" "out=[$out]"; fi
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
case "$snap" in [0-9]*" 0") pass "N4b snapshot written as '<epoch> 0' (also inside the cooldown)" ;; *) fail "N4b snapshot" "[$snap]" ;; esac
run_stop '[{"id":"s","type":"shell","status":"running","command":"sleep 9"}]' '[]' true >/dev/null
snap="$(cat "$ROOT/runtime/stop-snapshot" 2>/dev/null)"
case "$snap" in [0-9]*" 1") pass "N4c snapshot written under stop_hook_active too ('<epoch> 1')" ;; *) fail "N4c snapshot" "[$snap]" ;; esac
run_stop ABSENT >/dev/null
snap="$(cat "$ROOT/runtime/stop-snapshot" 2>/dev/null)"
case "$snap" in [0-9]*" unknown") pass "N4d snapshot records unknown without background_tasks" ;; *) fail "N4d snapshot" "[$snap]" ;; esac
printf '{"cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read"}' "$PROJ" | bash "$HEARTBEAT" >/dev/null 2>&1
if [ ! -e "$ROOT/runtime/stop-snapshot" ]; then pass "N4e a main-agent tool call deletes the snapshot"; else fail "N4e heartbeat delete"; fi
run_stop '[]' >/dev/null
printf '{"cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read","agent_id":"sub1","agent_type":"zyz-worker:test-agent"}' "$PROJ" | bash "$HEARTBEAT" >/dev/null 2>&1
if [ -e "$ROOT/runtime/stop-snapshot" ]; then pass "N4f a subagent tool call keeps it"; else fail "N4f subagent keeps snapshot"; fi
printf '{"cwd":"%s","hook_event_name":"UserPromptSubmit"}' "$PROJ" | bash "$MAIN_STATE" >/dev/null 2>&1
upe="$(cat "$ROOT/runtime/user-prompt-epoch" 2>/dev/null)"
if [ ! -e "$ROOT/runtime/stop-snapshot" ] && [ -n "$upe" ] && [ "$upe" -ge "$NOW" ]; then
    pass "N4g UserPromptSubmit deletes the snapshot and stamps user-prompt-epoch"; else fail "N4g user prompt" "upe=[$upe]"; fi

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
CAP="$SB/cap.txt"
printf '{"enabled":true,"command":"{ printf %s $ZYZ_NOTIFY_EVENT; } >> %s","cooldown_sec":0}\n' "'EV=%s '" "$CAP" > "$SB/notify.json"
write_status implementation "" "$LIST_ST"; reset_runtime
( . "$LIB"; zyz_main_state_set "$ROOT" idle )
set_snap "$((NOW - 700))" 0
ZYZ_NOTIFY_CONFIG="$SB/notify.json" run_wd >/dev/null
i=0; while [ ! -s "$CAP" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if grep -q 'EV=stuck' "$CAP" 2>/dev/null; then pass "N5i stuck IM sent while main-state is idle (origin stall)"; else fail "N5i stall IM" "cap=[$(cat "$CAP" 2>/dev/null)]"; fi

# ===========================================================================
echo "--- N6: Waiting On due reminder ---"
write_status implementation "- Waiting On: instance-key=lane-a; since-epoch=$((NOW - 120)); next-check-epoch=$((NOW - 5)); reason=DuckDB 全量用例" "$LIST_ST"
reset_runtime
out="$(run_wd)"
if printf '%s' "$out" | grep -q 'lane-a' && printf '%s' "$out" | grep -q '复查时间'; then pass "N6a due Waiting On -> reminder naming the key"; else fail "N6a due reminder" "out=[$out]"; fi
out="$(run_wd 600 0)"
if printf '%s' "$out" | grep -q '复查时间'; then fail "N6b same key+next-check reported again" "out=[$out]"; else pass "N6b once per (key, next-check-epoch)"; fi
write_status implementation "- Waiting On: instance-key=lane-a; since-epoch=$((NOW - 120)); next-check-epoch=$((NOW - 2)); reason=DuckDB 全量用例" "$LIST_ST"
out="$(run_wd)"
if printf '%s' "$out" | grep -q '复查时间'; then fail "N6c renewed row inside cooldown" "out=[$out]"; else pass "N6c a renewed row is still rate-limited by the cooldown"; fi
out="$(run_wd 600 0)"
if printf '%s' "$out" | grep -q '复查时间'; then pass "N6d renewed row re-arms once the cooldown allows"; else fail "N6d re-arm" "out=[$out]"; fi
write_status implementation "- Waiting On: instance-key=lane-b; since-epoch=$((NOW - 120)); next-check-epoch=$((NOW + 600)); reason=x" "$LIST_ST"
reset_runtime
out="$(run_wd 600 0)"
if printf '%s' "$out" | grep -q '复查时间'; then fail "N6e not yet due" "out=[$out]"; else pass "N6e a row not yet due -> silent"; fi

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

# ===========================================================================
echo "--- N8: helpers ---"
obs='{"ok":true,"state":"observed","instances":[{"terminal":false,"last_liveness_epoch":'"$((NOW - 30))"'},{"terminal":true},{"terminal":false,"last_liveness_epoch":'"$((NOW - 99999))"'},{"terminal":false}]}'
n="$(printf '%s' "$obs" | ( . "$LIB"; zyz_live_role_count 21600 ))"
if [ "$n" = 2 ]; then pass "N8a live roles: non-terminal within horizon (and epoch-less) count"; else fail "N8a live count" "got [$n]"; fi
n="$(printf '%s' '{"ok":false,"state":"genesis-capability-unavailable"}' | ( . "$LIB"; zyz_live_role_count 21600 ))"
if [ -z "$n" ]; then pass "N8b unobservable -> empty (unknown), not 0"; else fail "N8b unobservable" "got [$n]"; fi
n="$( ( ZYZ_HOOK_INPUT='{"background_tasks":[{"id":"x","type":"workflow","status":"running"},{"id":"y","type":"MCP task","status":"failed"}],"session_crons":[]}'; . "$LIB"; zyz_bg_executor_count ) )"
if [ "$n" = 1 ]; then pass "N8c executor count: unknown types count, failed ones do not"; else fail "N8c executor count" "got [$n]"; fi

echo
echo "RESULT: $PASSED/$TOTAL checks passed${SKIPPED:+ ($SKIPPED skipped)}"
[ "$FAILED" -eq 0 ]
