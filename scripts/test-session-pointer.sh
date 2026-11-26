#!/usr/bin/env bash
#
# test-session-pointer.sh — per-session task pointers (issue #23).
#
# Before #23 a directory had exactly one `.zyz-worker/current-task`, so two
# sessions running execute-task in the same directory either overwrote each
# other's pointer (the first session's watchdog silently re-attached to the new
# task) or one of them ran unarmed. Pointers are now keyed by session id:
# `.zyz-worker/sessions/<session-id>`, one task per line.
#
# Test groups:
#   S1  resolver: own pointer only, multi-line, dangling lines, fallback order
#       (session -> current-task -> $ZYZ_TASK_DIR), still no search (#18)
#   S2  hooks: two sessions in one dir only touch their own task
#       (heartbeat/main-state, status-freshness, Stop gate, notify, scope guard)
#   S3  watchdog: per-session scan, multi-task reports, live Claude registry id,
#       unarmed check ignores tasks other sessions claim
#   S4  legacy: a session without a session pointer behaves exactly as before
#   S5  task-pointer.sh: arm/disarm/show, idempotence, legacy fallback
#   S6  Codex: start-watchdog.sh hands the payload session_id to the watchdog
#
# What this suite does NOT prove: that a real host injects these ids. That was
# verified by hand on Claude Code 2.1.251 and codex-cli 0.151.0 (hook payload
# session_id equals $CLAUDE_CODE_SESSION_ID / $CODEX_THREAD_ID, and stays the
# PARENT id inside subagent hooks); the hook payloads here are synthetic.
#
# Usage: bash scripts/test-session-pointer.sh
# Exits 0 when every check passes, 1 otherwise. macOS bash 3.2 + Linux bash.

set -u
# Never reach the user's real IM (~/.zyz-worker/notify.json): checks that
# exercise the notifier point ZYZ_NOTIFY_CONFIG at their own capture config.
ZYZ_TEST_NO_NOTIFY="/nonexistent/zyz-worker-test/notify.json"
export ZYZ_NOTIFY_CONFIG="$ZYZ_TEST_NO_NOTIFY"
# Keep the invoking session's identity and project dir out of the resolver.
unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR ZYZ_SESSION_ID CLAUDE_CODE_SESSION_ID \
    CODEX_THREAD_ID CLAUDE_PID ZYZ_TASK_DIR
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || { echo "FATAL: cannot cd into '$REPO_ROOT'" >&2; exit 2; }

TOTAL=0; PASSED=0; FAILED=0; SKIPPED=0
pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); echo "PASS  $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); echo "FAIL  $1${2:+ — $2}"; }
skip() { TOTAL=$((TOTAL+1)); SKIPPED=$((SKIPPED+1)); echo "SKIP  $1${2:+ — $2}"; }
check() { # $1 name, $2 condition result (0 = pass), $3 detail
    if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "${3:-}"; fi
}

if ! command -v python3 >/dev/null 2>&1 && ! command -v jq >/dev/null 2>&1; then
    echo "SKIP  all — neither jq nor python3"; echo "RESULT: 0/0 checks passed (all skipped)"; exit 0
fi

H="$REPO_ROOT/hooks/scripts"
WD="$REPO_ROOT/monitors/watchdog.sh"
TP="$H/task-pointer.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zyz-sp.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
# No IM config anywhere: notify.sh records state, then stops at its config gate.
export ZYZ_NOTIFY_CONFIG="$TMP/no-notify.json"
# Keep the real ~/.claude/sessions registry out of every lookup.
export CLAUDE_CONFIG_DIR="$TMP/claude-config"

SA="aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
SB="bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"

# mk_task <base> <id> <phase> — task dir with an OLD status.md (stale for every
# threshold below) and no runtime state.
mk_task() {
    mkdir -p "$1/.zyz-worker/tasks/$2"
    printf -- '## Metadata\n\n- Current Phase: %s\n' "$3" > "$1/.zyz-worker/tasks/$2/status.md"
    touch -t 202001010000 "$1/.zyz-worker/tasks/$2/status.md"
}
# point <base> <sid> <line>... — write a session pointer.
point() {
    local b="$1" s="$2"; shift 2
    mkdir -p "$b/.zyz-worker/sessions"
    printf '%s\n' "$@" > "$b/.zyz-worker/sessions/$s"
}
resolve() { # <base> [env assignments...] -> zyz_task_roots output
    local b="$1"; shift
    env "$@" bash -c '. "$1/lib.sh" && zyz_task_roots "$2"' _ "$H" "$b"
}
hook() { # <script> <json> -> stdout of the hook
    printf '%s' "$2" | bash "$H/$1" 2>/dev/null
}
state_of() { head -n1 "$1/runtime/main-state" 2>/dev/null | awk '{print $1}'; }

# ---------------------------------------------------------------------------
# S1  resolver
# ---------------------------------------------------------------------------
D="$TMP/s1"
mk_task "$D" ta implementation
mk_task "$D" tb implementation
mk_task "$D" legacy implementation
point "$D" "$SA" ta
point "$D" "$SB" "$D/.zyz-worker/tasks/tb"
printf 'legacy\n' > "$D/.zyz-worker/current-task"
TA="$D/.zyz-worker/tasks/ta"; TB="$D/.zyz-worker/tasks/tb"; TL="$D/.zyz-worker/tasks/legacy"

out="$(resolve "$D" ZYZ_HOOK_INPUT="{\"session_id\":\"$SA\"}")"
check "S1 session A (hook payload) resolves only its own task" "$([ "$out" = "$TA" ]; echo $?)" "got [$out]"
out="$(resolve "$D" ZYZ_HOOK_INPUT="{\"session_id\":\"$SB\"}")"
check "S1 session B (absolute pointer line) resolves only its own task" "$([ "$out" = "$TB" ]; echo $?)" "got [$out]"
out="$(resolve "$D" CLAUDE_CODE_SESSION_ID="$SA")"
check "S1 no payload: \$CLAUDE_CODE_SESSION_ID selects the session pointer" "$([ "$out" = "$TA" ]; echo $?)" "got [$out]"
out="$(resolve "$D" CODEX_THREAD_ID="$SB")"
check "S1 no payload: \$CODEX_THREAD_ID selects the session pointer" "$([ "$out" = "$TB" ]; echo $?)" "got [$out]"
out="$(resolve "$D" ZYZ_HOOK_INPUT="{\"session_id\":\"$SA\"}" CLAUDE_CODE_SESSION_ID="$SB")"
check "S1 the payload session_id wins over the environment" "$([ "$out" = "$TA" ]; echo $?)" "got [$out]"

mk_task "$D" tc implementation
point "$D" "$SA" ta "" "nonexistent-task" "$D/.zyz-worker/tasks/tc" ta
out="$(resolve "$D" ZYZ_SESSION_ID="$SA" | tr '\n' ' ')"
check "S1 multi-line pointer: every task, blank/dangling skipped, duplicates dropped" \
    "$([ "$out" = "$TA $D/.zyz-worker/tasks/tc " ]; echo $?)" "got [$out]"
out="$(env ZYZ_SESSION_ID="$SA" bash -c '. "$1/lib.sh" && zyz_task_root "$2"' _ "$H" "$D")"
check "S1 zyz_task_root is the first pointer line (primary task)" "$([ "$out" = "$TA" ]; echo $?)" "got [$out]"

out="$(resolve "$D" ZYZ_SESSION_ID="cccccccc-no-pointer")"
check "S1 own session pointer missing -> legacy current-task" "$([ "$out" = "$TL" ]; echo $?)" "got [$out]"
point "$D" "dangling-only" "nonexistent-task"
out="$(resolve "$D" ZYZ_SESSION_ID="dangling-only")"
check "S1 session pointer with only dangling lines -> legacy current-task" "$([ "$out" = "$TL" ]; echo $?)" "got [$out]"
rm -f "$D/.zyz-worker/current-task"
out="$(resolve "$D" ZYZ_SESSION_ID="cccccccc-no-pointer" ZYZ_TASK_DIR="$TB")"
check "S1 no session pointer, no current-task -> \$ZYZ_TASK_DIR" "$([ "$out" = "$TB" ]; echo $?)" "got [$out]"
out="$(resolve "$D" ZYZ_SESSION_ID="cccccccc-no-pointer")"; rc=$?
check "S1 other sessions' pointers are never searched (#18): empty, rc 0" \
    "$([ -z "$out" ] && [ "$rc" -eq 0 ]; echo $?)" "out=[$out] rc=$rc"
out="$(resolve "$D")"
check "S1 no session id and no current-task -> empty (other sessions' pointers ignored)" "$([ -z "$out" ]; echo $?)" "got [$out]"

# Pointer under the session project dir while the payload cwd drifted.
P="$TMP/s1-project"
mk_task "$P" tp implementation
point "$P" "$SA" tp
mkdir -p "$P/sub"
out="$(resolve "$P/sub" ZYZ_SESSION_ID="$SA" CLAUDE_PROJECT_DIR="$P")"
check "S1 session pointer under the session project dir resolves from a drifted cwd" \
    "$([ "$out" = "$P/.zyz-worker/tasks/tp" ]; echo $?)" "got [$out]"

# ---------------------------------------------------------------------------
# S2  two sessions, one directory: hooks touch only their own task
# ---------------------------------------------------------------------------
D="$TMP/s2"
mk_task "$D" ta implementation
mk_task "$D" tb implementation
point "$D" "$SA" ta
point "$D" "$SB" tb
TA="$D/.zyz-worker/tasks/ta"; TB="$D/.zyz-worker/tasks/tb"

hook heartbeat.sh "{\"cwd\":\"$D\",\"session_id\":\"$SA\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\"}" >/dev/null
check "S2 heartbeat of session A marks A's task working" "$([ "$(state_of "$TA")" = working ]; echo $?)" "A=[$(state_of "$TA")]"
check "S2 heartbeat of session A leaves B's task untouched" "$([ ! -e "$TB/runtime/main-state" ]; echo $?)" "B=[$(state_of "$TB")]"

hook main-state.sh "{\"cwd\":\"$D\",\"session_id\":\"$SB\",\"hook_event_name\":\"Stop\"}" >/dev/null
check "S2 Stop of session B idles B's task" "$([ "$(state_of "$TB")" = idle ]; echo $?)" "B=[$(state_of "$TB")]"
check "S2 Stop of session B leaves A's task working" "$([ "$(state_of "$TA")" = working ]; echo $?)" "A=[$(state_of "$TA")]"

hook notify.sh "{\"cwd\":\"$D\",\"session_id\":\"$SA\",\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\"}" >/dev/null
check "S2 Notification of session A records awaiting-user on A's task" "$([ "$(state_of "$TA")" = awaiting-user ]; echo $?)" "A=[$(state_of "$TA")]"
check "S2 Notification of session A leaves B's task idle" "$([ "$(state_of "$TB")" = idle ]; echo $?)" "B=[$(state_of "$TB")]"

rm -f "$TA/runtime/main-state" "$TB/runtime/main-state"
out="$(ZYZ_STATUS_STALE_SEC=1 hook status-freshness.sh "{\"cwd\":\"$D\",\"session_id\":\"$SB\",\"tool_name\":\"Bash\"}")"
check "S2 status-freshness for session B names B's status file" "$(printf '%s' "$out" | grep -qF "$TB/status.md"; echo $?)" "got [$out]"
check "S2 status-freshness for session B never names A's status file" "$(! printf '%s' "$out" | grep -qF "$TA/status.md"; echo $?)" "got [$out]"

out="$(ZYZ_STOP_STATUS_STALE_SEC=1 hook stop-gate-main.sh "{\"cwd\":\"$D\",\"session_id\":\"$SA\",\"hook_event_name\":\"Stop\"}")"
check "S2 Stop gate of session A blocks on A's stale status" \
    "$(printf '%s' "$out" | grep -q '"decision":"block"' && printf '%s' "$out" | grep -qF "$TA/status.md"; echo $?)" "got [$out]"
check "S2 Stop gate of session A never cites B's task" "$(! printf '%s' "$out" | grep -qF "$TB"; echo $?)" "got [$out]"

prompt='Review the diff. Report only the top 3 findings.'
hook dispatch-scope-guard.sh "{\"cwd\":\"$D\",\"session_id\":\"$SB\",\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"review-agent\",\"prompt\":\"$prompt\"}}" >/dev/null
check "S2 scope-guard denial of session B is logged under B's task" "$([ -s "$TB/runtime/scope-guard.log" ]; echo $?)"
check "S2 scope-guard denial of session B is not logged under A's task" "$([ ! -e "$TA/runtime/scope-guard.log" ]; echo $?)"

# A subagent hook carries the PARENT session id (verified on both hosts) — it
# must land on the parent's task, not on whatever the directory last pointed at.
hook heartbeat.sh "{\"cwd\":\"$D\",\"session_id\":\"$SA\",\"agent_id\":\"sub-1\",\"agent_type\":\"zyz-worker:test-agent\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\"}" >/dev/null
out="$(ZYZ_STATUS_STALE_SEC=1 hook status-freshness.sh "{\"cwd\":\"$D\",\"session_id\":\"$SA\",\"agent_id\":\"sub-1\",\"agent_type\":\"zyz-worker:test-agent\",\"tool_name\":\"Bash\"}")"
check "S2 subagent hook of session A is attributed to A's task" \
    "$(printf '%s' "$out" | grep -qF "$TA/status.md" && ! printf '%s' "$out" | grep -qF "$TB"; echo $?)" "got [$out]"
check "S2 subagent heartbeat never writes main-state" "$([ ! -e "$TA/runtime/main-state" ]; echo $?)"

# ---------------------------------------------------------------------------
# S2b  one session, several tasks: main-agent hooks cover every task
# ---------------------------------------------------------------------------
D="$TMP/s2b"
mk_task "$D" t1 implementation
mk_task "$D" t2 testing
point "$D" "$SA" t1 t2
T1="$D/.zyz-worker/tasks/t1"; T2="$D/.zyz-worker/tasks/t2"
hook heartbeat.sh "{\"cwd\":\"$D\",\"session_id\":\"$SA\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\"}" >/dev/null
check "S2b main heartbeat marks every task of the session working" \
    "$([ "$(state_of "$T1")" = working ] && [ "$(state_of "$T2")" = working ]; echo $?)" "t1=[$(state_of "$T1")] t2=[$(state_of "$T2")]"
rm -f "$T1/runtime/main-state" "$T2/runtime/main-state"
out="$(ZYZ_STOP_STATUS_STALE_SEC=1 hook stop-gate-main.sh "{\"cwd\":\"$D\",\"session_id\":\"$SA\",\"hook_event_name\":\"Stop\"}")"
check "S2b Stop gate blocks once, citing every stale task" \
    "$(printf '%s' "$out" | grep -qF "$T1/status.md" && printf '%s' "$out" | grep -qF "$T2/status.md" && [ "$(printf '%s\n' "$out" | grep -c decision)" -eq 1 ]; echo $?)" "got [$out]"
out="$(ZYZ_STATUS_STALE_SEC=1 hook status-freshness.sh "{\"cwd\":\"$D\",\"session_id\":\"$SA\",\"tool_name\":\"Bash\"}")"
check "S2b status-freshness reminds about every stale task" \
    "$(printf '%s' "$out" | grep -qF "$T1/status.md" && printf '%s' "$out" | grep -qF "$T2/status.md"; echo $?)" "got [$out]"

# ---------------------------------------------------------------------------
# S3  watchdog
# ---------------------------------------------------------------------------
wd_once() { # <base> [env...] -> watchdog stdout of one tick
    local b="$1"; shift
    env ZYZ_WATCHDOG_ONCE=1 ZYZ_WATCHDOG_STATUS_STALE_SEC=1 ZYZ_WATCHDOG_COOLDOWN_SEC=0 "$@" \
        bash "$WD" "$b" 2>/dev/null
}
D="$TMP/s3"
mk_task "$D" ta implementation
mk_task "$D" tb implementation
point "$D" "$SA" ta
point "$D" "$SB" tb
TA="$D/.zyz-worker/tasks/ta"; TB="$D/.zyz-worker/tasks/tb"

out="$(wd_once "$D" CLAUDE_CODE_SESSION_ID="$SA")"
check "S3 Claude monitor of session A reports A's stale status" "$(printf '%s' "$out" | grep -qF "$TA/status.md"; echo $?)" "got [$out]"
check "S3 Claude monitor of session A never reports B's task" "$(! printf '%s' "$out" | grep -qF "$TB"; echo $?)" "got [$out]"
out="$(wd_once "$D" ZYZ_SESSION_ID="$SB" CLAUDE_CODE_SESSION_ID="$SA")"
check "S3 \$ZYZ_SESSION_ID (Codex starter) selects session B, not a leaked Claude id" \
    "$(printf '%s' "$out" | grep -qF "$TB/status.md" && ! printf '%s' "$out" | grep -qF "$TA"; echo $?)" "got [$out]"

# Live registry id: the monitor env is frozen at spawn; the registry follows
# the process (e.g. after /clear).
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
printf '{"pid":424242,"sessionId":"%s"}\n' "$SB" > "$CLAUDE_CONFIG_DIR/sessions/424242.json"
out="$(wd_once "$D" CLAUDE_CODE_SESSION_ID="stale-env-id" CLAUDE_PID=424242)"
check "S3 the live ~/.claude/sessions/<pid>.json id is honored" "$(printf '%s' "$out" | grep -qF "$TB/status.md"; echo $?)" "got [$out]"
rm -f "$CLAUDE_CONFIG_DIR/sessions/424242.json"

# One session pointer, two tasks: each checked and reported on its own.
D="$TMP/s3m"
mk_task "$D" t1 implementation
mk_task "$D" t2 review
mk_task "$D" t3 design
point "$D" "$SA" t1 t2 t3
out="$(wd_once "$D" CLAUDE_CODE_SESSION_ID="$SA")"
n="$(printf '%s\n' "$out" | grep -c '分钟没有更新')"
check "S3 multi-task pointer: one status finding per active task" \
    "$([ "$n" -eq 2 ] && printf '%s' "$out" | grep -qF "t1/status.md" && printf '%s' "$out" | grep -qF "t2/status.md"; echo $?)" "n=$n got [$out]"
check "S3 multi-task pointer: the design-phase task stays quiet" "$(! printf '%s' "$out" | grep -qF "t3/status.md"; echo $?)" "got [$out]"
mkdir -p "$D/.zyz-worker/tasks/t2/runtime"
printf 'idle 1\n' > "$D/.zyz-worker/tasks/t2/runtime/main-state"
out="$(wd_once "$D" CLAUDE_CODE_SESSION_ID="$SA")"
check "S3 multi-task pointer: per-task main-state suppression" \
    "$(printf '%s' "$out" | grep -qF "t1/status.md" && ! printf '%s' "$out" | grep -qF "t2/status.md"; echo $?)" "got [$out]"

# Unarmed check: tasks other sessions claim are not evidence of a lost pointer.
wd_unarmed() { # <base> [env...] -> count of unarmed reports over a few ticks
    local b="$1" p n; shift
    env ZYZ_WATCHDOG_INTERVAL_SEC=1 "$@" bash "$WD" "$b" > "$TMP/unarmed.out" 2>&1 &
    p=$!
    sleep 3
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
    n="$(grep -c '未启用：' "$TMP/unarmed.out" 2>/dev/null)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}
D="$TMP/s3u"
mk_task "$D" ta implementation
mk_task "$D" tb implementation
point "$D" "$SA" ta
point "$D" "$SB" "$D/.zyz-worker/tasks/tb"
n="$(wd_unarmed "$D" CLAUDE_CODE_SESSION_ID="cccccccc-plain-session")"
check "S3 a third session is not told it is unarmed by tasks A and B own" "$([ "$n" -eq 0 ]; echo $?)" "saw $n"
mk_task "$D" orphan implementation
n="$(wd_unarmed "$D" CLAUDE_CODE_SESSION_ID="cccccccc-plain-session")"
check "S3 an unclaimed live task still reports unarmed exactly once" "$([ "$n" -eq 1 ]; echo $?)" "saw $n"
check "S3 the unarmed report names the per-session pointer" "$(grep -qF '.zyz-worker/sessions/<session-id>' "$TMP/unarmed.out"; echo $?)"

# ---------------------------------------------------------------------------
# S4  legacy sessions: only current-task, behavior unchanged
# ---------------------------------------------------------------------------
D="$TMP/s4"
mk_task "$D" old implementation
printf 'old\n' > "$D/.zyz-worker/current-task"
TO="$D/.zyz-worker/tasks/old"
hook heartbeat.sh "{\"cwd\":\"$D\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\"}" >/dev/null
check "S4 payload without session_id: current-task still arms the heartbeat" "$([ "$(state_of "$TO")" = working ]; echo $?)"
rm -f "$TO/runtime/main-state"
hook heartbeat.sh "{\"cwd\":\"$D\",\"session_id\":\"$SA\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\"}" >/dev/null
check "S4 session id without a session pointer: current-task still arms the heartbeat" "$([ "$(state_of "$TO")" = working ]; echo $?)"
out="$(wd_once "$D")"
check "S4 watchdog without any session id still follows current-task" "$(printf '%s' "$out" | grep -qF "$TO/status.md"; echo $?)" "got [$out]"

# ---------------------------------------------------------------------------
# S5  task-pointer.sh
# ---------------------------------------------------------------------------
D="$TMP/s5"
mk_task "$D" t1 implementation
mk_task "$D" t2 implementation
(cd "$D" && "$TP" arm .zyz-worker/tasks/t1 --session-id "$SA" >/dev/null)
(cd "$D" && "$TP" arm "$D/.zyz-worker/tasks/t1" --session-id "$SA" >/dev/null)
(cd "$D" && "$TP" arm .zyz-worker/tasks/t2 --session-id "$SA" >/dev/null)
out="$(cat "$D/.zyz-worker/sessions/$SA" 2>/dev/null | tr '\n' ' ')"
check "S5 arm writes absolute paths, one per task, idempotently" \
    "$([ "$out" = "$D/.zyz-worker/tasks/t1 $D/.zyz-worker/tasks/t2 " ]; echo $?)" "got [$out]"
check "S5 arm never writes the shared current-task when a session id exists" "$([ ! -e "$D/.zyz-worker/current-task" ]; echo $?)"
out="$(cd "$D" && ZYZ_SESSION_ID="$SA" "$TP" show)"
check "S5 show lists the tasks the hooks resolve" \
    "$(printf '%s' "$out" | grep -qF "  $D/.zyz-worker/tasks/t2" && printf '%s' "$out" | grep -qF "session-id: $SA"; echo $?)" "got [$out]"
(cd "$D" && "$TP" arm .zyz-worker/tasks/t2 --session-id "$SB" >/dev/null)
(cd "$D" && "$TP" disarm .zyz-worker/tasks/t1 --session-id "$SA" >/dev/null)
out="$(cat "$D/.zyz-worker/sessions/$SA" 2>/dev/null | tr '\n' ' ')"
check "S5 disarm removes only that task's line" "$([ "$out" = "$D/.zyz-worker/tasks/t2 " ]; echo $?)" "got [$out]"
check "S5 another session's pointer is untouched" "$([ "$(cat "$D/.zyz-worker/sessions/$SB")" = "$D/.zyz-worker/tasks/t2" ]; echo $?)"
(cd "$D" && "$TP" disarm .zyz-worker/tasks/t2 --session-id "$SA" >/dev/null)
check "S5 disarming the last task removes the pointer file" "$([ ! -e "$D/.zyz-worker/sessions/$SA" ]; echo $?)"
(cd "$D" && "$TP" arm .zyz-worker/tasks/t1 --session-id 'we/ird id' >/dev/null)
check "S5 session ids are sanitized into one file name" "$([ -f "$D/.zyz-worker/sessions/we_ird_id" ]; echo $?)"
out="$( (cd "$D" && "$TP" arm .zyz-worker/tasks/missing --session-id "$SA") 2>&1)"; rc=$?
check "S5 arm of a missing task dir fails with rc 2" "$([ "$rc" -eq 2 ]; echo $?)" "rc=$rc out=[$out]"
out="$(cd "$D" && ZYZ_SESSION_ID="$SA" "$TP" session-id)"
check "S5 \$ZYZ_SESSION_ID overrides the harness id" "$([ "$out" = "$SA" ]; echo $?)" "got [$out]"

# Legacy fallback: no id anywhere (env cleared, empty registry).
D="$TMP/s5l"
mk_task "$D" t1 implementation
err="$( (cd "$D" && "$TP" arm .zyz-worker/tasks/t1) 2>&1 >/dev/null)"
check "S5 without any session id, arm falls back to the legacy current-task" \
    "$([ "$(cat "$D/.zyz-worker/current-task" 2>/dev/null)" = "$D/.zyz-worker/tasks/t1" ]; echo $?)" "err=[$err]"
check "S5 the legacy fallback warns that the pointer is shared" "$(printf '%s' "$err" | grep -q 'legacy shared pointer'; echo $?)" "err=[$err]"

# ---------------------------------------------------------------------------
# S6  Codex: start-watchdog.sh passes the payload session_id to the watchdog
# ---------------------------------------------------------------------------
D="$TMP/s6"
mk_task "$D" ta implementation
mk_task "$D" tb implementation
point "$D" "$SA" ta
point "$D" "$SB" tb
mkdir -p "$TMP/s6tmp"
printf '{"cwd":"%s","session_id":"%s","hook_event_name":"SessionStart"}' "$D" "$SB" \
    | env TMPDIR="$TMP/s6tmp" ZYZ_AGENT_RUNTIME=codex CODEX_THREAD_ID="$SB" CLAUDE_CODE_SESSION_ID="$SA" \
        ZYZ_WATCHDOG_ONCE=1 ZYZ_WATCHDOG_STATUS_STALE_SEC=1 bash "$H/start-watchdog.sh"
log="$TMP/s6tmp/zyz-worker-codex-watchdog-$SB.log"
i=0; while [ "$i" -lt 50 ] && ! grep -q '分钟没有更新' "$log" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
check "S6 Codex watchdog scans the payload session's task" "$(grep -qF "tb/status.md" "$log" 2>/dev/null; echo $?)" "log=[$(cat "$log" 2>/dev/null)]"
check "S6 Codex watchdog ignores a Claude id leaked into its env" "$(! grep -qF "ta/status.md" "$log" 2>/dev/null; echo $?)" "log=[$(cat "$log" 2>/dev/null)]"

# ---------------------------------------------------------------------------
# S8  subagent findings name no owning task in a multi-task session
#
# Subagent records sit under the primary task, but nothing says which task a
# role was dispatched for. The real fixed-pack observer is inert on hosts
# without GENESIS (stock macOS), so a sandbox mirror replaces runtime_state.py
# with a fake that returns `<task>/fake-observe.json`, and notify.sh with an
# argv recorder.
# ---------------------------------------------------------------------------
M="$TMP/mirror"
mkdir -p "$M"
cp -R "$REPO_ROOT/hooks" "$REPO_ROOT/monitors" "$M/"
cat > "$M/hooks/scripts/runtime_state.py" <<'PY'
import os, sys
if len(sys.argv) > 2 and sys.argv[1] == "hook-observe":
    p = os.path.join(sys.argv[2], "fake-observe.json")
    sys.stdout.write(open(p).read() if os.path.exists(p) else '{"ok":false}')
PY
cat > "$M/hooks/scripts/notify.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ZYZ_FAKE_NOTIFY_LOG:-/dev/null}"
SH
chmod +x "$M/hooks/scripts/notify.sh"
NOW="$(date +%s)"
fake_observe() { # <task-dir>: one stale live role + one finished role
    printf '{"ok":true,"state":"observed","main_heartbeat_epoch":%s,"instances":[{"instance_key":"k-stale","role":"test-agent","terminal":false,"tracking_capability":"armed","last_liveness_epoch":%s},{"instance_key":"k-done","role":"implementation-agent","terminal":true,"terminal_epoch":%s}]}' \
        "$((NOW - 60))" "$((NOW - 100))" "$((NOW - 50))" > "$1/fake-observe.json"
}
m_wd() { # <base> [env...]
    local b="$1"; shift
    env ZYZ_WATCHDOG_ONCE=1 ZYZ_WATCHDOG_ROLE_STALE_SEC=1 ZYZ_WATCHDOG_STATUS_STALE_SEC=1 \
        ZYZ_WATCHDOG_COOLDOWN_SEC=0 ZYZ_FAKE_NOTIFY_LOG="$TMP/s8-notify.log" "$@" \
        bash "$M/monitors/watchdog.sh" "$b" 2>/dev/null
}
NOTE='watchdog 无法判断这个角色是为哪一个派发的'

# Multi-task: the primary (records) is in design, the second task is active.
D="$TMP/s8"
mk_task "$D" t1 design
mk_task "$D" t2 implementation
point "$D" "$SA" t1 t2
T1="$D/.zyz-worker/tasks/t1"; T2="$D/.zyz-worker/tasks/t2"
fake_observe "$T1"
: > "$TMP/s8-notify.log"
out="$(m_wd "$D" CLAUDE_CODE_SESSION_ID="$SA")"; sleep 0.3
check "S8 subagent findings still fire while the primary task is in design but another is active" \
    "$(printf '%s' "$out" | grep -q '已静默'; echo $?)" "got [$out]"
check "S8 multi-task stale finding carries the no-owner note and lists every task" \
    "$(printf '%s\n' "$out" | grep '已静默' | grep -qF "$NOTE" && printf '%s' "$out" | grep -qF "$T2"; echo $?)" "got [$out]"
check "S8 multi-task note names where the runtime records live (for finalize)" \
    "$(printf '%s\n' "$out" | grep '已静默' | grep -qF "运行时记录在 $T1 下"; echo $?)" "got [$out]"
check "S8 multi-task unharvested finding points at the owning task, not the primary's files" \
    "$(printf '%s\n' "$out" | grep 'DONE/FINALIZED' | grep -q '所属任务的 subtasks/' && ! printf '%s\n' "$out" | grep 'DONE/FINALIZED' | grep -qF "$T1/subtasks"; echo $?)" "got [$out]"
check "S8 multi-task unharvested finding names the owning task's lanes/ first" \
    "$(printf '%s\n' "$out" | grep 'DONE/FINALIZED' | grep -q '所属任务的 lanes/ 下读取它的 lane 报告' && ! printf '%s\n' "$out" | grep 'DONE/FINALIZED' | grep -qF "$T1/lanes"; echo $?)" "got [$out]"
# The page is an escalation (0.32.0): the same findings, unanswered, on the
# next scan (ESCALATE=0 here).
m_wd "$D" CLAUDE_CODE_SESSION_ID="$SA" ZYZ_WATCHDOG_ESCALATE_SEC=0 >/dev/null
i=0; while ! grep -q -- '--origin subagent' "$TMP/s8-notify.log" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
check "S8 multi-task subagent IM is labeled with every task" \
    "$(grep -- '--origin subagent' "$TMP/s8-notify.log" | grep -q -- '--task-id t1,t2'; echo $?)" "log=[$(cat "$TMP/s8-notify.log")]"
check "S8 the design-phase primary gets no status-stale finding" "$(! printf '%s' "$out" | grep -qF "$T1/status.md 已有"; echo $?)" "got [$out]"

# The result was recorded in t2's status.md after the role finished: not unharvested.
touch "$T2/status.md"
out="$(m_wd "$D" CLAUDE_CODE_SESSION_ID="$SA")"
check "S8 a status write to ANY task of the session counts as harvesting" \
    "$(! printf '%s' "$out" | grep -q 'DONE/FINALIZED'; echo $?)" "got [$out]"
touch -t 202001010000 "$T2/status.md"

out="$(env ZYZ_ROLE_STALE_SEC=1 ZYZ_STOP_STATUS_STALE_SEC=1 bash -c 'printf "%s" "$1" | bash "$2"' _ \
    "{\"cwd\":\"$D\",\"session_id\":\"$SA\",\"hook_event_name\":\"Stop\"}" "$M/hooks/scripts/stop-gate-main.sh" 2>/dev/null)"
check "S8 Stop gate: subagent clauses carry the no-owner note in a multi-task session" \
    "$(printf '%s' "$out" | grep -qF "$NOTE" && printf '%s' "$out" | grep -q '所属任务的 subtasks/'; echo $?)" "got [$out]"
check "S8 Stop gate: the unharvested clause names lanes/ first" \
    "$(printf '%s' "$out" | grep -q '所属任务的 lanes/ 下读取它的 lane 报告'; echo $?)" "got [$out]"
check "S8 Stop gate: no status clause for the design-phase primary" \
    "$(! printf '%s' "$out" | grep -qF "（$T1/status.md）"; echo $?)" "got [$out]"

# No task of the session active -> no subagent findings at all.
printf -- '## Metadata\n\n- Current Phase: design\n' > "$T2/status.md"
out="$(m_wd "$D" CLAUDE_CODE_SESSION_ID="$SA")"
check "S8 no active task in the session -> silent" "$([ -z "$out" ]; echo $?)" "got [$out]"

# Single-task session: wording unchanged (no note, names the task's own files).
D="$TMP/s8single"
mk_task "$D" only implementation
point "$D" "$SA" only
TO="$D/.zyz-worker/tasks/only"
fake_observe "$TO"
: > "$TMP/s8-notify.log"
out="$(m_wd "$D" CLAUDE_CODE_SESSION_ID="$SA")"; sleep 0.3
check "S8 single-task stale finding has no no-owner note" \
    "$(printf '%s\n' "$out" | grep '已静默' >/dev/null && ! printf '%s' "$out" | grep -qF "$NOTE"; echo $?)" "got [$out]"
check "S8 single-task unharvested finding names the task's own subtasks/ and status.md" \
    "$(printf '%s\n' "$out" | grep 'DONE/FINALIZED' | grep -qF "$TO/subtasks/" ; echo $?)" "got [$out]"
# Lane reports live in lanes/<id>.md (tiers §10.6); subtasks/ is kept for old tasks.
check "S8 single-task unharvested finding names the task's lanes/ first" \
    "$(printf '%s\n' "$out" | grep 'DONE/FINALIZED' | grep -qF "读取 $TO/lanes/ 下它的 lane 报告" ; echo $?)" "got [$out]"
check "S8 single-task IM keeps the default task id" "$(! grep -q -- '--task-id' "$TMP/s8-notify.log"; echo $?)" "log=[$(cat "$TMP/s8-notify.log")]"

# Hook-mode IM (needs_input) belongs to the session: in a multi-task session
# it names every task.
D="$TMP/s8im"
mk_task "$D" t1 implementation
mk_task "$D" t2 implementation
point "$D" "$SA" t1 t2
printf '{"enabled":true,"command":"printf %%s \\"$ZYZ_NOTIFY_TASK_ID\\" > %s"}\n' "$TMP/s8-im.out" > "$TMP/s8-notify.json"
printf '{"cwd":"%s","session_id":"%s","hook_event_name":"Notification","notification_type":"permission_prompt"}' "$D" "$SA" \
    | ZYZ_NOTIFY_CONFIG="$TMP/s8-notify.json" bash "$H/notify.sh" >/dev/null 2>&1
check "S8 hook-mode IM of a multi-task session names every task" \
    "$([ "$(cat "$TMP/s8-im.out" 2>/dev/null)" = "t1,t2" ]; echo $?)" "got [$(cat "$TMP/s8-im.out" 2>/dev/null)]"

# ---------------------------------------------------------------------------
# Static: the contract is documented where the main agent reads it.
# ---------------------------------------------------------------------------
for f in skills/execute-task/SKILL.md skills/execute-task/prompts/main-agent.md; do
    check "S7 $f arms via task-pointer.sh" "$(grep -q 'task-pointer.sh arm' "$f"; echo $?)"
    check "S7 $f names the per-session pointer" "$(grep -qF '.zyz-worker/sessions/<session-id>' "$f"; echo $?)"
done
check "S7 hooks/README.md documents task-pointer.sh" "$(grep -q 'task-pointer.sh' hooks/README.md; echo $?)"

echo
if [ "$SKIPPED" -gt 0 ]; then
    echo "RESULT: $PASSED/$TOTAL checks passed ($SKIPPED skipped)"
else
    echo "RESULT: $PASSED/$TOTAL checks passed"
fi
[ "$FAILED" -eq 0 ]
