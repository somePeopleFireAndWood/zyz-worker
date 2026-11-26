#!/usr/bin/env bash
#
# task-pointer.sh — write / remove / inspect this session's task pointer (#23).
#
# ## Trigger point
#
# Run by the MAIN agent from its own Bash tool (execute-task §1 step 4), never
# by a hook and never by a subagent: a Codex sub-agent's shell carries its own
# child thread id, so a pointer it wrote would be keyed to the wrong session.
#
# ## Usage
#
#   task-pointer.sh arm <task-dir> [--base <dir>] [--session-id <id>]
#   task-pointer.sh disarm <task-dir> [--base <dir>] [--session-id <id>]
#   task-pointer.sh show [--base <dir>] [--session-id <id>]
#   task-pointer.sh session-id
#
# - <dir> defaults to $PWD, which must be the session cwd (the `cwd` hooks see).
# - arm appends the task dir's absolute path to
#   `<dir>/.zyz-worker/sessions/<session-id>` (one task per line; arming an
#   already-listed task is a no-op). Without a session id it falls back to the
#   legacy shared `<dir>/.zyz-worker/current-task` and says so on stderr; the
#   hooks read that file only when they too have no session id.
# - disarm removes that task's line (and the file once it is empty).
# - show prints the session id, the pointer file, and every task dir the hooks
#   resolve for this session (the same zyz_task_roots the hooks call), plus a
#   leftover current-task the session ignores.
#
# ## Session id
#
# --session-id, else $ZYZ_SESSION_ID, else the harness this shell runs under —
# the nearest `claude` or `codex` ancestor process: $CLAUDE_CODE_SESSION_ID for
# Claude Code, $CODEX_THREAD_ID for Codex. The ancestor decides because both
# variables leak into nested harnesses (a Codex worker spawned from a Claude
# session inherits $CLAUDE_CODE_SESSION_ID, and vice versa), so their mere
# presence does not say whose shell this is. For Claude Code the live id in
# ~/.claude/sessions/<pid>.json is armed too when it differs from the
# environment's. Both ids are verified to equal the hook payload `session_id`.
#
# ## Failure behavior
#
# Exits 2 on usage errors or a missing task dir; 0 otherwise. Never touches any
# other session's pointer.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" || exit 2

usage() {
    sed -n '13,16p' "$0" | sed 's/^# *//' >&2
    exit 2
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift
task_dir=""
case "$cmd" in
    arm|disarm)
        [ -n "${1:-}" ] || usage
        task_dir="$1"
        shift
        ;;
    show|session-id) ;;
    *) usage ;;
esac

base="$PWD"
opt_sid=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --base) base="${2:-}"; shift 2 || usage ;;
        --session-id) opt_sid="${2:-}"; shift 2 || usage ;;
        *) usage ;;
    esac
done
[ -d "$base" ] || { echo "task-pointer: base dir not found: $base" >&2; exit 2; }
base="$(cd "$base" && pwd)"

# Nearest harness ancestor: prints "claude <pid>" or "codex <pid>", or nothing.
harness_ancestor() {
    local pid comm i
    pid="$PPID"
    i=0
    while [ "$i" -lt 64 ]; do
        case "$pid" in ''|*[!0-9]*|0|1) return 0 ;; esac
        comm="$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "${comm##*/}" in
            claude) printf 'claude %s' "$pid"; return 0 ;;
            codex) printf 'codex %s' "$pid"; return 0 ;;
        esac
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
        i=$((i + 1))
    done
    return 0
}

# This session's ids, one per line, the primary first.
session_ids() {
    local anc harness pid
    if [ -n "$opt_sid" ]; then printf '%s\n' "$opt_sid"; return 0; fi
    if [ -n "${ZYZ_SESSION_ID:-}" ]; then printf '%s\n' "$ZYZ_SESSION_ID"; return 0; fi
    anc="$(harness_ancestor)"
    harness="${anc%% *}"
    pid="${anc#* }"
    case "$harness" in
        claude)
            {
                printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-}"
                zyz_claude_registry_sid "$pid"
                printf '\n'
            } | awk 'NF && !seen[$0]++'
            ;;
        codex)
            [ -z "${CODEX_THREAD_ID:-}" ] || printf '%s\n' "$CODEX_THREAD_ID"
            ;;
        *)
            # No recognizable ancestor (e.g. `ps` unavailable): same order the
            # hooks use when a payload lacks session_id.
            ZYZ_HOOK_INPUT="" zyz_session_id
            printf '\n'
            ;;
    esac | awk 'NF'
}

sids="$(session_ids)"
primary="${sids%%
*}"

if [ "$cmd" = session-id ]; then
    [ -n "$primary" ] || { echo "task-pointer: no session id available" >&2; exit 0; }
    printf '%s\n' "$primary"
    exit 0
fi

if [ "$cmd" = show ]; then
    printf 'session-id: %s\n' "${primary:-<none>}"
    if [ -n "$primary" ]; then
        printf 'pointer: %s\n' "$base/.zyz-worker/sessions/$(zyz_sanitize "$primary")"
    else
        printf 'pointer: %s (legacy, shared by every session in this dir)\n' "$base/.zyz-worker/current-task"
    fi
    printf 'tasks:\n'
    ZYZ_HOOK_INPUT="" ZYZ_SESSION_ID="$primary" zyz_task_roots "$base" | sed 's/^/  /'
    if [ -n "$primary" ] && [ -f "$base/.zyz-worker/current-task" ]; then
        printf 'ignored: %s -> %s (the legacy shared pointer is read only when no session id is available; arm the task if it is this session'"'"'s)\n' \
            "$base/.zyz-worker/current-task" "$(head -n1 "$base/.zyz-worker/current-task" 2>/dev/null)"
    fi
    exit 0
fi

[ -d "$task_dir" ] || { echo "task-pointer: task dir not found: $task_dir" >&2; exit 2; }
task_dir="$(cd "$task_dir" && pwd)"

# Rewrites pointer file $1 with task line $2 added (arm) or removed (disarm).
rewrite_pointer() {
    local file tmp line dir found
    file="$1"
    tmp="$file.tmp.$$"
    found=0
    : > "$tmp" || return 1
    if [ -f "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue
            dir="$(zyz_resolve_ref_at "$base" "$line")"
            if [ -n "$dir" ] && [ "$(cd "$dir" && pwd)" = "$task_dir" ]; then
                found=1
                [ "$cmd" = disarm ] && continue
            fi
            printf '%s\n' "$line" >> "$tmp"
        done < "$file"
    fi
    [ "$cmd" = arm ] && [ "$found" = 0 ] && printf '%s\n' "$task_dir" >> "$tmp"
    if [ -s "$tmp" ]; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp" "$file"
    fi
}

if [ -z "$sids" ]; then
    if [ "$cmd" = arm ]; then
        mkdir -p "$base/.zyz-worker" || exit 2
        zyz_write_atomic "$base/.zyz-worker/current-task" "$task_dir"
        echo "task-pointer: no session id available; wrote the legacy shared pointer $base/.zyz-worker/current-task — another session armed in this dir will overwrite it, and hooks that do see a session id ignore it (confirm the layer is armed)" >&2
        printf 'armed: %s -> %s\n' "$base/.zyz-worker/current-task" "$task_dir"
    else
        if [ "$(zyz_resolve_pointer_at "$base")" = "$task_dir" ]; then
            rm -f "$base/.zyz-worker/current-task"
        fi
        printf 'disarmed: %s\n' "$task_dir"
    fi
    exit 0
fi

mkdir -p "$base/.zyz-worker/sessions" || exit 2
while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    pointer="$base/.zyz-worker/sessions/$(zyz_sanitize "$sid")"
    rewrite_pointer "$pointer" || exit 2
    printf '%s: session %s (%s) -> %s\n' "${cmd}ed" "$sid" "$pointer" "$task_dir"
done <<EOF
$sids
EOF
exit 0
