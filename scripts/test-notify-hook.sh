#!/usr/bin/env bash
#
# Static + smoke-check suite for the L7 IM stop-notifier (hooks/scripts/notify.sh
# plus its hooks.json registration and monitors/watchdog.sh bridge).
#
# Test groups:
#   N1  file layout + executable bit + bash -n syntax
#   N2  hooks.json registers Notification / StopFailure / SessionEnd → notify.sh
#       with async:true; watchdog.sh wires notify_stuck; README documents it
#   N3  behavior smoke in a tmp sandbox (needs jq or python3): event→category
#       mapping, scope gate, config gate, event whitelist + default set,
#       include_message redaction, cooldown, direct stuck mode
#
# Usage:   bash scripts/test-notify-hook.sh
# Exit:    0 on success, 1 if any check failed.
# Compatibility: macOS bash 3.2 + Linux bash. Smoke tests SKIP without jq/python3.

set -u
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

json_tool() {
    command -v jq >/dev/null 2>&1 && return 0
    command -v python3 >/dev/null 2>&1 && return 0
    return 1
}

NOTIFY=hooks/scripts/notify.sh

# ---- N1 static ---------------------------------------------------------------
if [ -f "$NOTIFY" ]; then pass "N1 $NOTIFY exists"; else fail "N1 $NOTIFY exists"; fi
if [ -x "$NOTIFY" ]; then pass "N1 $NOTIFY is executable"; else fail "N1 $NOTIFY is executable"; fi
if bash -n "$NOTIFY" 2>/dev/null; then pass "N1 $NOTIFY bash -n clean"; else fail "N1 $NOTIFY bash -n clean"; fi

# ---- N2 wiring ---------------------------------------------------------------
if json_tool; then
    reg="$(python3 - <<'PY' 2>/dev/null || true
import json
d = json.load(open("hooks/hooks.json"))
h = d.get("hooks", {})
ok = []
for ev in ("Notification", "StopFailure", "SessionEnd"):
    groups = h.get(ev) or []
    hit = False
    for g in groups:
        for hook in g.get("hooks", []):
            if "notify.sh" in (hook.get("command") or "") and hook.get("async") is True:
                hit = True
    ok.append(ev if hit else "!" + ev)
print(" ".join(ok))
PY
)"
    for ev in Notification StopFailure SessionEnd; do
        case " $reg " in
            *" $ev "*) pass "N2 hooks.json registers $ev → notify.sh (async)" ;;
            *) fail "N2 hooks.json registers $ev → notify.sh (async)" "$reg" ;;
        esac
    done
else
    skip "N2 hooks.json registrations" "no jq/python3"
fi

if grep -q 'notify_stuck' monitors/watchdog.sh 2>/dev/null \
    && grep -q 'notify.sh' monitors/watchdog.sh 2>/dev/null; then
    pass "N2 watchdog.sh wires notify_stuck → notify.sh"
else
    fail "N2 watchdog.sh wires notify_stuck → notify.sh"
fi

if grep -q 'notify.sh' hooks/README.md 2>/dev/null; then
    pass "N2 hooks/README.md documents notify.sh"
else
    fail "N2 hooks/README.md documents notify.sh"
fi

# ---- N3 behavior smoke -------------------------------------------------------
if ! json_tool; then
    skip "N3 behavior smoke" "no jq/python3"
else
    SB="$(mktemp -d)"
    PROJ="$SB/proj"
    ROOT="$PROJ/.zyz-worker/tasks/demo-task"
    mkdir -p "$ROOT"
    printf 'demo-task\n' > "$PROJ/.zyz-worker/current-task"
    printf '# Status\n- Current Phase: implementation\n' > "$ROOT/status.md"
    CAP="$SB/captured.txt"
    CFG="$SB/notify.json"
    export ZYZ_NOTIFY_CONFIG="$CFG"

    write_cfg() { printf '%s\n' "$1" > "$CFG"; }
    # A capturing command, deliberately free of double quotes so it embeds in
    # JSON without escaping: print the event category (no spaces) then append the
    # stdin payload JSON. Message/task_id/etc. are asserted from that payload.
    CMD="{ printf 'EV=%s ' \$ZYZ_NOTIFY_EVENT; cat; echo; } >> $CAP"

    run_hook() { # $1 = stdin JSON
        printf '%s' "$1" | bash "$NOTIFY"
        # notify.sh runs the command in the foreground, so no sleep needed.
    }

    # (a) needs_input fires with correct category + message
    write_cfg "{\"enabled\":true,\"command\":\"$CMD\",\"cooldown_sec\":0}"
    : > "$CAP"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"cwd\":\"$PROJ\",\"message\":\"perm please\"}"
    if grep -q 'EV=needs_input ' "$CAP" 2>/dev/null && grep -q '"message":"perm please"' "$CAP" 2>/dev/null; then
        pass "N3 permission_prompt → needs_input (env + message)"
    else
        fail "N3 permission_prompt → needs_input" "$(cat "$CAP")"
    fi
    if grep -q '"event":"needs_input"' "$CAP" 2>/dev/null && grep -q '"task_id":"demo-task"' "$CAP" 2>/dev/null; then
        pass "N3 stdin payload JSON carries event + task_id"
    else
        fail "N3 stdin payload JSON carries event + task_id" "$(cat "$CAP")"
    fi

    # (b) session_end filtered by default (events absent)
    : > "$CAP"
    run_hook "{\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\",\"cwd\":\"$PROJ\"}"
    if [ ! -s "$CAP" ]; then pass "N3 session_end off by default"; else fail "N3 session_end off by default" "$(cat "$CAP")"; fi

    # (c) session_end fires when explicitly enabled
    write_cfg "{\"enabled\":true,\"command\":\"$CMD\",\"cooldown_sec\":0,\"events\":[\"session_end\"]}"
    : > "$CAP"
    run_hook "{\"hook_event_name\":\"SessionEnd\",\"reason\":\"logout\",\"cwd\":\"$PROJ\"}"
    if grep -q 'EV=session_end ' "$CAP" 2>/dev/null; then pass "N3 session_end fires when whitelisted"; else fail "N3 session_end fires when whitelisted" "$(cat "$CAP")"; fi

    # (d) needs_input NOT in the explicit whitelist → filtered
    : > "$CAP"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$PROJ\"}"
    if [ ! -s "$CAP" ]; then pass "N3 explicit whitelist excludes others"; else fail "N3 explicit whitelist excludes others" "$(cat "$CAP")"; fi

    # (e) unknown notification_type ignored
    write_cfg "{\"enabled\":true,\"command\":\"$CMD\",\"cooldown_sec\":0}"
    : > "$CAP"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"auth_success\",\"cwd\":\"$PROJ\"}"
    if [ ! -s "$CAP" ]; then pass "N3 unknown notification_type ignored"; else fail "N3 unknown notification_type ignored" "$(cat "$CAP")"; fi

    # (f) StopFailure → failed with error text
    : > "$CAP"
    run_hook "{\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"cwd\":\"$PROJ\"}"
    if grep -q 'EV=failed ' "$CAP" 2>/dev/null && grep -q '"message":"rate_limit"' "$CAP" 2>/dev/null; then pass "N3 StopFailure → failed (error text)"; else fail "N3 StopFailure → failed" "$(cat "$CAP")"; fi

    # (g) no task pointer → no fire (workflow scope)
    : > "$CAP"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$SB\"}"
    if [ ! -s "$CAP" ]; then pass "N3 no current-task pointer → no fire"; else fail "N3 no current-task pointer → no fire" "$(cat "$CAP")"; fi

    # (h) disabled config → no fire
    write_cfg "{\"enabled\":false,\"command\":\"$CMD\",\"cooldown_sec\":0}"
    : > "$CAP"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$PROJ\"}"
    if [ ! -s "$CAP" ]; then pass "N3 enabled:false → no fire"; else fail "N3 enabled:false → no fire" "$(cat "$CAP")"; fi

    # (i) include_message:false blanks the message but still fires with the category
    write_cfg "{\"enabled\":true,\"command\":\"$CMD\",\"cooldown_sec\":0,\"include_message\":false}"
    : > "$CAP"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"cwd\":\"$PROJ\",\"message\":\"secret content\"}"
    if grep -q 'EV=needs_input ' "$CAP" 2>/dev/null && grep -q '"message":""' "$CAP" 2>/dev/null && ! grep -q 'secret content' "$CAP" 2>/dev/null; then
        pass "N3 include_message:false redacts message, still fires"
    else
        fail "N3 include_message:false redacts message" "$(cat "$CAP")"
    fi

    # (j) cooldown suppresses a second event inside the window. Clear any marker
    # left by earlier needs_input fires so the first event here is not itself
    # suppressed by a stale stamp.
    rm -f "$ROOT"/runtime/nag/notify-*.last 2>/dev/null
    write_cfg "{\"enabled\":true,\"command\":\"$CMD\",\"cooldown_sec\":3600}"
    : > "$CAP"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"cwd\":\"$PROJ\"}"
    first="$(wc -c < "$CAP")"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"cwd\":\"$PROJ\"}"
    second="$(wc -c < "$CAP")"
    if [ "$first" -gt 0 ] && [ "$first" = "$second" ]; then
        pass "N3 per-category cooldown suppresses the second event"
    else
        fail "N3 per-category cooldown suppresses the second event" "first=$first second=$second"
    fi

    # (k) direct stuck mode (watchdog path)
    write_cfg "{\"enabled\":true,\"command\":\"$CMD\",\"cooldown_sec\":0}"
    : > "$CAP"
    bash "$NOTIFY" --event stuck --task-root "$ROOT" --message "role test-agent silent 25 min"
    if grep -q 'EV=stuck ' "$CAP" 2>/dev/null && grep -q '"message":"role test-agent silent 25 min"' "$CAP" 2>/dev/null; then
        pass "N3 direct --event stuck fires (watchdog path)"
    else
        fail "N3 direct --event stuck fires" "$(cat "$CAP")"
    fi

    # (l) global disable switch
    : > "$CAP"
    ZYZ_NOTIFY_DISABLE=1 run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"cwd\":\"$PROJ\"}"
    if [ ! -s "$CAP" ]; then pass "N3 ZYZ_NOTIFY_DISABLE=1 → no fire"; else fail "N3 ZYZ_NOTIFY_DISABLE=1 → no fire" "$(cat "$CAP")"; fi

    unset ZYZ_NOTIFY_CONFIG
    rm -rf "$SB"
fi

echo
if [ "$SKIPPED" -gt 0 ]; then
    echo "RESULT: $PASSED/$TOTAL checks passed ($SKIPPED skipped)"
else
    echo "RESULT: $PASSED/$TOTAL checks passed"
fi
[ "$FAILED" -eq 0 ]
