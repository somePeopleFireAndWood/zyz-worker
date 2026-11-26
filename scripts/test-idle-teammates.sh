#!/usr/bin/env bash
#
# test-idle-teammates.sh — an idle agent-team teammate, and the background
# tasks it started, are not executors (L4 no-executor clause, the L3 backstop,
# the design-phase needs_input fallback).
#
# Claude Code lists an in-process teammate in background_tasks as
# `{"type":"teammate","status":"running"}` for as long as it exists, and an
# idle teammate is not woken by its own background task finishing. Before this
# change every teammate counted as an executor, so with a team present the
# no-executor check could never fire (11-17 f0b8d80a: 12 idle teammates and an
# idle teammate's two finished shells; the user found the stall 31 min later).
#
# Groups:
#   L  live replay: scripts/fixtures/teammate-live-2.1.251.jsonl holds the real
#      hook payloads of an interactive Claude Code 2.1.251 session (trimmed to
#      the fields the hooks read): spawn a teammate that starts a background
#      `sleep 45` and ends its turn "waiting for notification", Stop, wake it
#      with SendMessage, Stop, let it go idle, Stop. Replayed in order through
#      heartbeat.sh / teammate-track.sh / stop-gate-main.sh.
#   U  unit cases: recording, mapping (description / prompt-prefix keys incl.
#      UTF-16 counting, collisions, unrecorded entries), shell ownership,
#      plain subagents, unarmed sessions.
#   W  L3: a teammate busy at the Stop that goes idle afterwards.
#   D  the design-phase needs_input fallback.
#   S  static: hooks.json wiring, message text.
#
# WHAT THIS SUITE DOES NOT PROVE: that later Claude Code versions keep the
# observed shapes (teammate agent_id `a<name>-<hex>`, SubagentStart on every
# wake, TeammateIdle at every turn end, the entry description, an idle teammate
# not woken by its own task). The fixture pins 2.1.251.
#
# Mutation record (each mutant applied to an out-of-tree rsync copy): 19
# targeted mutants, all killed.
#  * lib.sh — teammate detection by agent_id pattern dropped (U14); collision
#    rule `all idle` -> `any idle` (U8); shell ownership ignored (L1, U11);
#    idle-for-<sec> ignored in the L3 view (W2); a teammate without a state
#    record counted as idle (W5); the jq -> python3 fallback removed (U18b).
#  * teammate-track.sh — TeammateIdle ignored (L1, L4); SubagentStart ignored
#    (L1, U6); prompt-prefix key dropped (L1, L2); prefix cut by code points
#    instead of UTF-16 units (U18); records written for any Agent launch (U16).
#  * heartbeat.sh — a teammate's tool call not marking it busy (U5); ownership
#    not written (L1, L3); Monitor taskId not read (U10, U11).
#  * stop-gate-main.sh — idle teammates not subtracted (L1, U3).
#  * watchdog.sh — the post-Stop recount removed (W3, W7); residents left out
#    of it (W7).  main-state.sh — design fallback not subtracting (D1).
#  * hooks.json — TeammateIdle not registered (S1).
#
# Usage: bash scripts/test-idle-teammates.sh   (exit 0 iff every check passed)

set -u
ZYZ_TEST_NO_NOTIFY="/nonexistent/zyz-worker-test/notify.json"
export ZYZ_NOTIFY_CONFIG="$ZYZ_TEST_NO_NOTIFY"
set -o pipefail
unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR ZYZ_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CLAUDE_PID ZYZ_TASK_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || { echo "FATAL: cannot cd into '$REPO_ROOT'" >&2; exit 2; }

TOTAL=0; PASSED=0; FAILED=0
pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); echo "PASS  $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); echo "FAIL  $1${2:+ — $2}"; }
check() { if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP  all — python3 unavailable"; echo "RESULT: 0/0 checks passed (all skipped)"; exit 0
fi

H="$REPO_ROOT/hooks/scripts"
WD="$REPO_ROOT/monitors/watchdog.sh"
FIX="$SCRIPT_DIR/fixtures/teammate-live-2.1.251.jsonl"
SB="$(mktemp -d "${TMPDIR:-/tmp}/zyz-idle-tm.XXXXXX")"
SB="$(cd "$SB" && pwd -P)"
trap 'rm -rf "$SB"' EXIT
export ZYZ_NOTIFY_CONFIG="$SB/no-notify.json"
export CLAUDE_CONFIG_DIR="$SB/claude-config"

for f in lib.sh heartbeat.sh teammate-track.sh stop-gate-main.sh main-state.sh; do
    bash -n "$H/$f" 2>/dev/null; check "S0 syntax: $f" $?
done
[ -x "$H/teammate-track.sh" ]; check "S0 teammate-track.sh is executable" $?

SID="3b48559f-a536-4efd-b4ad-d66134a7f3ee"   # the live session's id
# new_proj <dir> <phase> [subtasks] — an armed task for session $SID.
new_proj() {
    P="$1"; R="$P/.zyz-worker/tasks/tm"
    rm -rf "$P"; mkdir -p "$R" "$P/.zyz-worker/sessions"
    printf -- '# 任务状态\n\n## 元数据\n\n- Current Phase: %s\n\n## Agent State\n\n- 主 agent: x\n\n## SubTasks\n\n%s\n' \
        "$2" "${3:-}" > "$R/status.md"
    printf '%s\n' "$R" > "$P/.zyz-worker/sessions/$SID"
}
# feed <script> <json> — run one hook with the payload's cwd set to $P.
with_cwd() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["cwd"]=sys.argv[1]; d.setdefault("session_id", sys.argv[2]); print(json.dumps(d))' "$P" "$SID"; }
feed() { with_cwd "$2" | ZYZ_STOP_GATE_COOLDOWN_SEC=0 bash "$H/$1" 2>/dev/null; }
is_block() { printf '%s' "$1" | grep -q '"decision":"block"' && printf '%s' "$1" | grep -q '没有任何执行者'; }
state_of() { awk '{print $1}' "$R/runtime/teammates/$1.state" 2>/dev/null; }
stop_json() { # <background_tasks json>
    printf '{"hook_event_name":"Stop","stop_hook_active":false,"background_tasks":%s,"session_crons":[]}' "$1"
}

# ===========================================================================
echo "--- L: live payload replay (Claude Code 2.1.251) ---"
new_proj "$SB/live" implementation
decisions=""
while IFS= read -r line; do
    ev="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hook_event_name"])')"
    case "$ev" in
        PreToolUse) feed heartbeat.sh "$line" >/dev/null ;;
        PostToolUse) feed heartbeat.sh "$line" >/dev/null; feed teammate-track.sh "$line" >/dev/null ;;
        SubagentStart|TeammateIdle) feed teammate-track.sh "$line" >/dev/null ;;
        Stop)
            out="$(feed stop-gate-main.sh "$line")"
            if is_block "$out"; then decisions="${decisions}B"; else decisions="${decisions}a"; fi
            ;;
    esac
done < "$FIX"
check "L1 the six Stops decide block/allow/block/allow/allow/block (idle teammate + its running shell blocks)" \
    "$([ "$decisions" = BaBaaB ]; echo $?)" "got [$decisions]"
check "L2 the spawn recorded both keys the host may list (description, prompt prefix)" \
    "$([ "$(cat "$R/runtime/teammates/tw1.keys" 2>/dev/null)" = '["tm verify worker", "Run the Bash command '"'"'sleep 45; echo started'"'"' with..."]' ]; echo $?)" \
    "got [$(cat "$R/runtime/teammates/tw1.keys" 2>/dev/null)]"
check "L3 the teammate's background Bash is recorded as its own" \
    "$([ "$(cat "$R/runtime/teammates/owned/bdcp5jy20" 2>/dev/null)" = tw1 ]; echo $?)"
check "L4 the last event (TeammateIdle) leaves it idle" "$([ "$(state_of tw1)" = idle ]; echo $?)"
check "L5 the snapshot keeps every running id (a wait --ref on them stays alive)" \
    "$(grep -q ' t05ff5hag ' "$R/runtime/stop-snapshot"; echo $?)" "snap=[$(cat "$R/runtime/stop-snapshot")]"
check "L6 the plain internal subagents of the session left no teammate record" \
    "$([ "$(ls "$R/runtime/teammates" | grep -c '\.state$')" = 1 ]; echo $?)" "ls=[$(ls "$R/runtime/teammates")]"

# The 0.32.1 behaviour on the same Stop (#11 of the fixture): without records
# both entries count — the blind spot this change closes.
new_proj "$SB/live-norec" implementation
out="$(feed stop-gate-main.sh "$(sed -n '11p' "$FIX")")"
check "L7 control: the same Stop without teammate records is allowed (unrecorded teammates stay executors)" \
    "$(! is_block "$out"; echo $?)" "got [$out]"

# ===========================================================================
echo "--- U: recording and mapping ---"
new_proj "$SB/u" implementation '- SubTask ID: ST1
- Committed:'
spawn() { # <name> <description> <prompt>
    feed teammate-track.sh "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"name":sys.argv[1],"description":sys.argv[2],"prompt":sys.argv[3]},"tool_response":{"status":"teammate_spawned","name":sys.argv[1]}}))' "$1" "$2" "$3")" >/dev/null
}
idle() { feed teammate-track.sh "{\"hook_event_name\":\"TeammateIdle\",\"teammate_name\":\"$1\"}" >/dev/null; }
tool_call() { # <name> [tool] [response-json]
    local resp='{}'
    [ -z "${3:-}" ] || resp="$3"
    feed heartbeat.sh "{\"hook_event_name\":\"PostToolUse\",\"agent_id\":\"a$1-0123456789abcdef\",\"agent_type\":\"$1\",\"tool_name\":\"${2:-Read}\",\"tool_response\":$resp}" >/dev/null
}
entry() { printf '{"id":"%s","type":"teammate","status":"running","description":%s}' "$1" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")"; }

spawn alpha "alpha work" "short prompt"
check "U1 a spawn answered teammate_spawned records the teammate busy" "$([ "$(state_of alpha)" = busy ]; echo $?)"
out="$(feed stop-gate-main.sh "$(stop_json "[$(entry t1 'alpha work')]")")"
check "U2 busy teammate (matched by description) is an executor" "$(! is_block "$out"; echo $?)" "got [$out]"
idle alpha
out="$(feed stop-gate-main.sh "$(stop_json "[$(entry t1 'alpha work')]")")"
check "U3 after TeammateIdle it is not: the Stop is blocked" "$(is_block "$out"; echo $?)" "got [$out]"
check "U3b the block reason explains idle teammates" "$(printf '%s' "$out" | grep -q '空闲 teammate'; echo $?)" "got [$out]"
out="$(feed stop-gate-main.sh "$(stop_json "[$(entry t1 'short prompt')]")")"
check "U4 the prompt form (<= 50 units, no ellipsis) maps too" "$(is_block "$out"; echo $?)" "got [$out]"
tool_call alpha
out="$(feed stop-gate-main.sh "$(stop_json "[$(entry t1 'alpha work')]")")"
check "U5 a tool call after TeammateIdle (an unobserved wake) makes it an executor again" "$(! is_block "$out"; echo $?)" "got [$out]"
idle alpha
feed teammate-track.sh '{"hook_event_name":"SubagentStart","agent_id":"aalpha-0123456789abcdef","agent_type":"alpha"}' >/dev/null
check "U6 SubagentStart (a wake by message) marks it busy" "$([ "$(state_of alpha)" = busy ]; echo $?)"
idle alpha

out="$(feed stop-gate-main.sh "$(stop_json "[$(entry t1 'alpha work'),$(entry t9 'someone else')]")")"
check "U7 an unrecorded teammate entry stays an executor" "$(! is_block "$out"; echo $?)" "got [$out]"

spawn beta "same desc" "p1"
spawn gamma "same desc" "p2"
idle beta
out="$(feed stop-gate-main.sh "$(stop_json "[$(entry t2 'same desc'),$(entry t3 'same desc')]")")"
check "U8 two teammates share a description, one busy: both entries stay executors" "$(! is_block "$out"; echo $?)" "got [$out]"
idle gamma
out="$(feed stop-gate-main.sh "$(stop_json "[$(entry t2 'same desc'),$(entry t3 'same desc')]")")"
check "U9 ... both idle: neither is" "$(is_block "$out"; echo $?)" "got [$out]"

tool_call alpha Bash '{"backgroundTaskId":"bsh1"}'
tool_call alpha Monitor '{"taskId":"bmon1"}'
idle alpha
shells='{"id":"bsh1","type":"shell","status":"running","command":"x"},{"id":"bmon1","type":"shell","status":"running","command":"y"}'
check "U10 Bash backgroundTaskId and Monitor taskId are recorded as the teammate's" \
    "$([ "$(cat "$R/runtime/teammates/owned/bsh1")" = alpha ] && [ "$(cat "$R/runtime/teammates/owned/bmon1")" = alpha ]; echo $?)"
out="$(feed stop-gate-main.sh "$(stop_json "[$(entry t1 'alpha work'),$shells]")")"
check "U11 shells started by an idle teammate are not executors (it will never read them)" "$(is_block "$out"; echo $?)" "got [$out]"
feed teammate-track.sh '{"hook_event_name":"SubagentStart","agent_id":"aalpha-0123456789abcdef","agent_type":"alpha"}' >/dev/null
out="$(feed stop-gate-main.sh "$(stop_json "[$shells]")")"
check "U12 ... while it is busy they are" "$(! is_block "$out"; echo $?)" "got [$out]"
idle alpha
out="$(feed stop-gate-main.sh "$(stop_json '[{"id":"bmain","type":"shell","status":"running","command":"go test"}]')")"
check "U13 a shell nobody recorded (the main agent's own) stays an executor" "$(! is_block "$out"; echo $?)" "got [$out]"

feed heartbeat.sh '{"hook_event_name":"PostToolUse","agent_id":"adf2771700423f0c7","agent_type":"general-purpose","tool_name":"Bash","tool_response":{"backgroundTaskId":"bsub"}}' >/dev/null
check "U14 a plain subagent (agent_id a<hex>) leaves no teammate record and no ownership" \
    "$([ ! -e "$R/runtime/teammates/general-purpose.state" ] && [ ! -e "$R/runtime/teammates/owned/bsub" ]; echo $?)"
feed heartbeat.sh '{"hook_event_name":"PostToolUse","agent_id":"azeta-xyz","agent_type":"zeta","tool_name":"Read"}' >/dev/null
check "U15 an agent_id that is not a<name>-<hex> is not a teammate" "$([ ! -e "$R/runtime/teammates/zeta.state" ]; echo $?)"
feed teammate-track.sh '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"name":"late"},"tool_response":{"status":"async_launched","agentId":"a1"}}' >/dev/null
check "U16 an ordinary async Agent launch records nothing" "$([ ! -e "$R/runtime/teammates/late.keys" ]; echo $?)"

# UTF-16 prefix: the host's substring(0, 50) counts code units — an emoji is 2.
long="$(python3 -c 'print("评审"*30 + "😀" + "尾巴")')"
spawn delta "" "$long"
want="$(python3 -c 'import sys; s=sys.argv[1]; u=s.encode("utf-16-le","surrogatepass"); print(u[:100].decode("utf-16-le","surrogatepass") + "...")' "$long")"
idle delta
out="$(feed stop-gate-main.sh "$(stop_json "[$(entry t4 "$want")]")")"
check "U17 a long CJK prompt maps through its 50-unit prefix + ..." "$(is_block "$out"; echo $?)" "got [$out] want=[$want]"
check "U17b an empty description is not recorded as a key" "$(! grep -q '""' "$R/runtime/teammates/delta.keys"; echo $?)" "keys=[$(cat "$R/runtime/teammates/delta.keys")]"
emo="$(python3 -c 'print("x"*49 + "😀" + "tail")')"
spawn epsilon "" "$emo"
idle epsilon
e5="$(python3 -c 'import json; print(json.dumps({"id":"t5","type":"teammate","status":"running","description":"x"*49 + "\ud83d..."}))')"
out="$(feed stop-gate-main.sh "$(stop_json "[$e5]")")"
check "U18 an emoji split at unit 50 maps like the host's lone surrogate" "$(is_block "$out"; echo $?)" "got [$out] tm=[$(cat "$R/runtime/stop-teammates")]"
got="$(ZYZ_HOOK_INPUT="$(stop_json "[$e5]" | sed 's/^{/{"cwd":"\/x",/')" bash -c '. "$1/lib.sh"; zyz_get cwd' _ "$H")"
check "U18b zyz_get still reads a payload with a lone surrogate escape (jq rejects it)" "$([ "$got" = /x ]; echo $?)" "got [$got]"

# A session that never armed records nothing (S9 of test-session-pointer.sh
# covers every other hook).
mkdir -p "$SB/unarmed"
printf '{"cwd":"%s","session_id":"cccccccc-plain","hook_event_name":"TeammateIdle","teammate_name":"x"}' "$SB/unarmed" | bash "$H/teammate-track.sh"
check "U19 an unarmed session records nothing" "$([ -z "$(find "$SB/unarmed" -type f)" ]; echo $?)"

# wait --ref on an idle teammate's shell: still alive (the id stays a fact) and
# it mutes the clause.
new_proj "$SB/ref" implementation '- SubTask ID: ST1
- Committed:'
spawn alpha "alpha work" "p"
tool_call alpha Bash '{"backgroundTaskId":"bsh1"}'
idle alpha
"$H/expect.sh" --task "$R" set suite wait --at +1h --ref bsh1 --reason "full suite" >/dev/null 2>&1
out="$(feed stop-gate-main.sh "$(stop_json '[{"id":"bsh1","type":"shell","status":"running","command":"x"}]')")"
check "U20 a wait --ref on that shell mutes the clause" "$(! is_block "$out"; echo $?)" "got [$out]"
ev="$(bash -c '. "$1/lib.sh"; zyz_expect_eval "$2" "bsh1"' _ "$H" "$R" | awk -F '\t' '$1=="dead"')"
check "U21 ... and is not reported dead while the shell runs" "$([ -z "$ev" ]; echo $?)" "got [$ev]"

# ===========================================================================
echo "--- W: L3 backstop ---"
wd() { env ZYZ_WATCHDOG_ONCE=1 ZYZ_WATCHDOG_NO_EXECUTOR_SEC=600 ZYZ_WATCHDOG_SILENCE_SEC=86400 \
    ZYZ_WATCHDOG_COOLDOWN_SEC=0 CLAUDE_CODE_SESSION_ID="$SID" bash "$WD" "$P" 2>>"$SB/wd.err"; }
age_stop() { # <sec>: the Stop, and the main agent's last move, <sec> ago
    local t=$(( $(date +%s) - $1 ))
    set -- $(cat "$R/runtime/stop-snapshot"); shift
    printf '%s %s\n' "$t" "$*" > "$R/runtime/stop-snapshot"
    printf '%s main\n' "$t" > "$R/runtime/activity"
    python3 -c 'import os,sys; os.utime(sys.argv[1],(int(sys.argv[2]),)*2)' "$R/status.md" "$t"
}
idle_at() { printf 'idle %s\n' "$(( $(date +%s) - $2 ))" > "$R/runtime/teammates/$1.state"; }
is_noexec() { printf '%s' "$1" | grep -q '期间没有任何执行者'; }

new_proj "$SB/w" implementation '- SubTask ID: ST1
- Committed:'
spawn alpha "alpha work" "p"
tool_call alpha Bash '{"backgroundTaskId":"bsh1"}'
sh1='{"id":"bsh1","type":"shell","status":"running","command":"x"}'
out="$(feed stop-gate-main.sh "$(stop_json "[$(entry t1 'alpha work'),$sh1]")")"
check "W0 setup: Stop while the teammate works is allowed, snapshot counts 2" \
    "$(! is_block "$out" && [ "$(awk '{print $2}' "$R/runtime/stop-snapshot")" = 2 ]; echo $?)" "snap=[$(cat "$R/runtime/stop-snapshot")]"
age_stop 1200
out="$(wd)"
check "W1 the teammate still busy 20 min later: silent" "$([ -z "$out" ]; echo $?)" "got [$out]"
idle_at alpha 300
out="$(wd)"
check "W2 idle for 5 min (< no-executor-sec): silent" "$([ -z "$out" ]; echo $?)" "got [$out]"
idle_at alpha 700
out="$(wd)"
check "W3 idle for 11 min with its shell: the no-executor finding (its idle notice was missed)" "$(is_noexec "$out"; echo $?)" "got [$out]"
printf 'busy %s\n' "$(date +%s)" > "$R/runtime/teammates/alpha.state"
out="$(wd)"
check "W4 busy again: silent" "$([ -z "$out" ]; echo $?)" "got [$out]"
idle_at alpha 700
"$H/expect.sh" --task "$R" set lr resident --ref t1 --reason "x" >/dev/null 2>&1
rm -f "$R/runtime/teammates/alpha.state"
out="$(wd)"
check "W5 a teammate with no state record stays an executor (fail closed to silent)" "$([ -z "$out" ]; echo $?)" "got [$out]"
"$H/expect.sh" --task "$R" clear lr >/dev/null 2>&1
idle_at alpha 700
printf '%s 2 bsh1,bother 0\n' "$(( $(date +%s) - 1200 ))" > "$R/runtime/stop-snapshot"
printf 'bsh1\talpha\t0\n' > "$R/runtime/stop-teammates"
out="$(wd)"
check "W6 another executor counted at the Stop keeps it silent" "$([ -z "$out" ]; echo $?)" "got [$out]"
"$H/expect.sh" --task "$R" set dev resident --ref bother --reason "dev server" >/dev/null 2>&1
out="$(wd)"
check "W7 ... unless that one is a declared resident" "$(is_noexec "$out"; echo $?)" "got [$out]"
check "W8 every watchdog tick ran without stderr" "$([ ! -s "$SB/wd.err" ]; echo $?)" "$(head -3 "$SB/wd.err" 2>/dev/null)"

# ===========================================================================
echo "--- D: design-phase needs_input fallback ---"
new_proj "$SB/d" design
spawn alpha "alpha work" "p"
idle alpha
printf '{"enabled":true,"command":"printf %%s \\"$ZYZ_NOTIFY_EVENT\\" >> %s","cooldown_sec":0}\n' "$SB/d-im.log" > "$SB/d-notify.json"
with_cwd "$(stop_json "[$(entry t1 'alpha work')]")" | ZYZ_NOTIFY_CONFIG="$SB/d-notify.json" bash "$H/main-state.sh" >/dev/null 2>&1
i=0; while [ ! -s "$SB/d-im.log" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
check "D1 design stop with only an idle teammate pages needs_input" "$(grep -q needs_input "$SB/d-im.log" 2>/dev/null; echo $?)" "im=[$(cat "$SB/d-im.log" 2>/dev/null)]"
: > "$SB/d-im.log"; rm -f "$R/runtime/nag/"*
feed teammate-track.sh '{"hook_event_name":"SubagentStart","agent_id":"aalpha-0123456789abcdef","agent_type":"alpha"}' >/dev/null
with_cwd "$(stop_json "[$(entry t1 'alpha work')]")" | ZYZ_NOTIFY_CONFIG="$SB/d-notify.json" bash "$H/main-state.sh" >/dev/null 2>&1
sleep 1
check "D2 ... but not while it works" "$([ ! -s "$SB/d-im.log" ]; echo $?)" "im=[$(cat "$SB/d-im.log" 2>/dev/null)]"

# ===========================================================================
echo "--- S: static wiring ---"
reg="$(python3 -c '
import json
h = json.load(open("hooks/hooks.json"))["hooks"]
out = []
for ev, blocks in h.items():
    for b in blocks:
        for x in b["hooks"]:
            if "teammate-track.sh" in x["command"]:
                out.append("%s:%s:%s" % (ev, b.get("matcher", "-"), "async" if x.get("async") else "sync"))
print(" ".join(sorted(out)))')"
check "S1 teammate-track.sh is wired to TeammateIdle, SubagentStart(*) and PostToolUse(Agent), sync" \
    "$([ "$reg" = 'PostToolUse:^(Agent|spawn_agent|collaboration\.spawn_agent)$:sync SubagentStart:*:sync TeammateIdle:-:sync' ]; echo $?)" "got [$reg]"
grep -q 'test-idle-teammates.sh' docs/architecture.md; check "S2 the suite is listed in docs/architecture.md" $?
grep -q 'TeammateIdle' hooks/README.md && grep -q 'teammate-track.sh' hooks/README.md; check "S3 hooks/README.md documents teammate-track.sh" $?

echo
echo "RESULT: $PASSED/$TOTAL checks passed"
[ "$FAILED" -eq 0 ]
