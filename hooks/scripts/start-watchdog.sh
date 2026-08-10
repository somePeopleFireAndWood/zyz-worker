#!/usr/bin/env bash
# Codex has no Claude monitor manifest lifecycle, so start the same watchdog
# from SessionStart. Claude keeps using monitors/monitors.json and exits here.
set -u

case "${ZYZ_AGENT_RUNTIME:-}" in
    codex) ;;
    *) [ -n "${CODEX_THREAD_ID:-}${CODEX_CI:-}" ] || exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0
ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"

base=""
if [ -n "$ZYZ_HOOK_INPUT" ] && zyz_json_ok; then
    base="$(zyz_get cwd)"
fi
[ -n "$base" ] || base="${CODEX_PROJECT_DIR:-}"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || base="$PWD"

key="$(zyz_sanitize "${CODEX_THREAD_ID:-session-$$}")"
tmp_base="${TMPDIR:-/tmp}"
pid_file="$tmp_base/zyz-worker-codex-watchdog-$key.pid"
log_file="$tmp_base/zyz-worker-codex-watchdog-$key.log"

if [ -f "$pid_file" ]; then
    old_pid="$(head -n1 "$pid_file" 2>/dev/null || true)"
    case "$old_pid" in
        ''|*[!0-9]*) ;;
        *) kill -0 "$old_pid" 2>/dev/null && exit 0 ;;
    esac
fi

# Codex currently skips async hooks. Detach explicitly so SessionStart remains
# fast; stdout goes to a per-thread diagnostic log because Codex has no monitor
# notification channel equivalent to Claude's monitors.json.
nohup env ZYZ_WATCHDOG_PARENT_PID="$PPID" ZYZ_WATCHDOG_PID_FILE="$pid_file" \
    "$SCRIPT_DIR/../../monitors/watchdog.sh" "$base" \
    >>"$log_file" 2>&1 </dev/null &
printf '%s\n' "$!" > "$pid_file"
exit 0
