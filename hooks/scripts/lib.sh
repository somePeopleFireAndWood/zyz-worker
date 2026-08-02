#!/usr/bin/env bash
#
# lib.sh — shared helpers for zyz-worker hook and monitor scripts.
#
# ## Trigger point
#
# Never executed directly; sourced by every script in this directory.
#
# ## Inputs
#
# - Callers set ZYZ_HOOK_INPUT to the raw hook JSON read from stdin before
#   calling zyz_get.
#
# ## Provided functions
#
# - zyz_json_ok                 0 when a JSON parser (jq or python3) exists.
# - zyz_get <dot.path>          string value at a dot path of ZYZ_HOOK_INPUT,
#                               or empty.
# - zyz_mtime <file>            mtime as epoch seconds (BSD or GNU stat).
# - zyz_now / zyz_iso           current epoch seconds / ISO 8601 timestamp.
# - zyz_sanitize <s>            s with chars outside [A-Za-z0-9._-] -> '_'.
# - zyz_task_root <base>        the current task directory resolved via the
#                               `<base>/.zyz-worker/current-task` pointer
#                               (first line = task-id, or a path relative to
#                               <base>, or an absolute path), or empty when
#                               missing/dangling.
# - zyz_write_atomic <f> <line> tmpfile+rename single-line write.
# - zyz_emit_context <ev> <msg> print hookSpecificOutput additionalContext
#                               JSON for event <ev>.
# - zyz_emit_block <reason>     print top-level {"decision":"block",...}.
# - zyz_role_of <agent_type>    agent_type with plugin scope prefix stripped.
# - zyz_phase_of <status.md>    lowercased "Current Phase" value, or empty.
# - zyz_phase_active <phase>    0 when phase is implementation/testing/
#                               review/delivery (an active execution phase).
# - zyz_epoch_in <file>         first line of <file> as an epoch int.
# - zyz_cooldown_ok <marker> <sec>
#                               0 when <sec> has elapsed since the marker's
#                               stored epoch (stamps the marker); 1 inside
#                               the cooldown window. Rate-limits nagging.
# - zyz_bg_running_types        agent_type of every background subagent task
#                               in ZYZ_HOOK_INPUT that is not completed or
#                               failed, one per line (Stop-event input).
# - zyz_scan_stale <dir> <stale-sec> <horizon-sec>
#                               one "key<TAB>age" line per not-done agent
#                               whose last liveness is older than <stale-sec>
#                               but younger than <horizon-sec>.
#
# ## Failure behavior
#
# Every helper prints nothing and returns success on missing input. Callers
# treat empty output as "not available" and exit 0 — hooks fail open and
# must never break the agent loop.
#
# ## Supported agents
#
# All. Compatible with macOS bash 3.2 and Linux bash; no associative arrays.

zyz_json_ok() {
    command -v jq >/dev/null 2>&1 && return 0
    command -v python3 >/dev/null 2>&1 && return 0
    return 1
}

zyz_get() {
    [ -n "${ZYZ_HOOK_INPUT:-}" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$ZYZ_HOOK_INPUT" | jq -r ".${1} // empty" 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$ZYZ_HOOK_INPUT" | python3 -c '
import json, sys
path = sys.argv[1].split(".")
try:
    node = json.load(sys.stdin)
    for key in path:
        node = node[key]
    if node is None:
        sys.exit(0)
    if isinstance(node, bool):
        print("true" if node else "false")
    elif isinstance(node, (dict, list)):
        print(json.dumps(node))
    else:
        print(node)
except Exception:
    pass
' "$1" 2>/dev/null
        return 0
    fi
    return 0
}

zyz_mtime() {
    [ -e "${1:-}" ] || return 0
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

zyz_now() {
    date +%s
}

zyz_iso() {
    date +%Y-%m-%dT%H:%M:%S%z
}

zyz_sanitize() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

zyz_task_root() {
    [ -n "${1:-}" ] || return 0
    local pointer target
    pointer="$1/.zyz-worker/current-task"
    [ -f "$pointer" ] || return 0
    target="$(head -n1 "$pointer" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$target" ] || return 0
    case "$target" in
        /*) ;;
        */*) target="$1/$target" ;;
        *) target="$1/.zyz-worker/tasks/$(zyz_sanitize "$target")" ;;
    esac
    [ -d "$target" ] || return 0
    printf '%s' "$target"
}

zyz_phase_of() {
    # $1 = status.md path. Prints the lowercased text after the first
    # "Current Phase" LABEL line (list item or field, not arbitrary prose).
    [ -f "${1:-}" ] || return 0
    grep -iE '^[[:space:]]*[-*]?[[:space:]]*current phase[[:space:]]*:' "$1" 2>/dev/null | head -n1 \
        | sed 's/^[^:]*:*//' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

zyz_phase_active() {
    # $1 = phase string. 0 when the phase is an active execution phase.
    case "${1:-}" in
        *implement*|*testing*|*review*|*deliver*) return 0 ;;
    esac
    return 1
}

zyz_epoch_in() {
    # $1 = file whose first line holds an epoch integer.
    [ -f "${1:-}" ] || return 0
    local v
    v="$(head -n1 "$1" 2>/dev/null | tr -d '[:space:]')"
    case "$v" in
        ''|*[!0-9]*) return 0 ;;
    esac
    printf '%s' "$v"
}

zyz_write_atomic() {
    local tmp
    tmp="$1.tmp.$$"
    printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    return 0
}

zyz_emit_context() {
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg e "$1" --arg m "$2" \
            '{hookSpecificOutput:{hookEventName:$e,additionalContext:$m}}' 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": sys.argv[1], "additionalContext": sys.argv[2]}}))
' "$1" "$2" 2>/dev/null
        return 0
    fi
    return 0
}

zyz_emit_block() {
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg r "$1" '{decision:"block",reason:$r}' 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
print(json.dumps({"decision": "block", "reason": sys.argv[1]}))
' "$1" 2>/dev/null
        return 0
    fi
    return 0
}

zyz_role_of() {
    printf '%s' "${1##*:}"
}

zyz_cooldown_ok() {
    # $1 marker file, $2 cooldown seconds.
    local last now cd
    cd="$2"
    case "$cd" in
        ''|*[!0-9]*) cd=300 ;;
    esac
    last="$(zyz_epoch_in "$1")"
    now="$(zyz_now)"
    if [ -n "$last" ] && [ $((now - last)) -lt "$cd" ]; then
        return 1
    fi
    mkdir -p "$(dirname "$1")" 2>/dev/null
    zyz_write_atomic "$1" "$now"
    return 0
}

zyz_bg_running_types() {
    [ -n "${ZYZ_HOOK_INPUT:-}" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$ZYZ_HOOK_INPUT" | jq -r '
            (.background_tasks // [])[]
            | select(.type == "subagent")
            | select((.status // "") | test("complet|fail") | not)
            | .agent_type // empty' 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$ZYZ_HOOK_INPUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    for t in data.get("background_tasks") or []:
        if t.get("type") != "subagent":
            continue
        status = (t.get("status") or "").lower()
        if "complet" in status or "fail" in status:
            continue
        at = t.get("agent_type")
        if at:
            print(at)
except Exception:
    pass
' 2>/dev/null
        return 0
    fi
    return 0
}

zyz_scan_stale() {
    # $1 agents dir, $2 stale-sec, $3 horizon-sec.
    # A subagent counts as stale when it has a .start stamp, no .done mark,
    # and its last liveness (newest of .start/.heartbeat) is older than
    # stale-sec. Entries older than horizon-sec are orphans from finished
    # work and are skipped instead of nagging forever.
    local dir stale horizon now f key last hb age
    dir="${1:-}"; stale="${2:-900}"; horizon="${3:-21600}"
    [ -d "$dir" ] || return 0
    now="$(zyz_now)"
    for f in "$dir"/*.start; do
        [ -e "$f" ] || continue
        key="$(basename "$f" .start)"
        [ "$key" = "main" ] && continue
        [ -f "$dir/$key.done" ] && continue
        last="$(zyz_mtime "$f")"
        hb="$(zyz_mtime "$dir/$key.heartbeat")"
        [ -n "$hb" ] && [ "$hb" -gt "$last" ] && last="$hb"
        [ -n "$last" ] || continue
        age=$((now - last))
        [ "$age" -gt "$stale" ] || continue
        [ "$age" -lt "$horizon" ] || continue
        printf '%s\t%s\n' "$key" "$age"
    done
    return 0
}
