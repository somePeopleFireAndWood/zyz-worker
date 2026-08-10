#!/usr/bin/env bash
#
# Cross-runtime adapter for orchestration workers.  It is deliberately small
# and side-effect-free: callers use it to resolve the selected agent runtime,
# render launch/resume commands, and discover a persisted session.
#
# Runtime selection:
#   ZYZ_AGENT_RUNTIME=claude|codex  explicit override
#   ZYZ_AGENT_RUNTIME=auto         detect the host agent (default)
#
# Auto detection prefers the current host's exported identity.  Outside an
# agent session it falls back to Claude for backwards compatibility with every
# release before the Codex adapter existed.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  orch-agent-runtime.sh detect
  orch-agent-runtime.sh process-name <claude|codex>
  orch-agent-runtime.sh launch-command <runtime> <plugin-root> <worktree> <task-id> <runtime-args> [worktrees]
  orch-agent-runtime.sh resume-command <runtime> <plugin-root> <worktree> <session-id> <runtime-args> [worktrees]
  orch-agent-runtime.sh discover-session <runtime> <agent-pid> <worktree> <spawn-iso>
EOF
}

shell_quote() {
    # Keep legacy/simple commands readable; quote only when shell syntax needs it.
    case "$1" in
        ''|*[!A-Za-z0-9_./:@+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}

detect_runtime() {
    local requested="${ZYZ_AGENT_RUNTIME:-auto}"
    case "$requested" in
        claude|codex) printf '%s\n' "$requested"; return 0 ;;
        auto|'') ;;
        *)
            echo "warning: invalid ZYZ_AGENT_RUNTIME='$requested'; using auto detection" >&2
            ;;
    esac

    if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_CI:-}" ]; then
        printf 'codex\n'
    elif [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] || [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        printf 'claude\n'
    else
        printf 'claude\n'
    fi
}

append_codex_add_dirs() {
    local primary="$1" all="${2:-}" out="" item rest
    [ -n "$all" ] || { printf ''; return 0; }
    rest="$all"
    while :; do
        case "$rest" in
            *:*) item="${rest%%:*}"; rest="${rest#*:}" ;;
            *) item="$rest"; rest="" ;;
        esac
        if [ -n "$item" ] && [ "$item" != "$primary" ]; then
            out="$out --add-dir $(shell_quote "$item")"
        fi
        [ -n "$rest" ] || break
    done
    printf '%s' "$out"
}

launch_command() {
    local runtime="$1" plugin_root="$2" worktree="$3" task_id="$4"
    local runtime_args="${5:-}" worktrees="${6:-}" prompt add_dirs
    case "$runtime" in
        claude)
            printf 'claude --plugin-dir %s --permission-mode bypassPermissions --dangerously-skip-permissions --settings '\''{"ultracode": true}'\''' \
                "$(shell_quote "$plugin_root")"
            [ -n "$runtime_args" ] && printf ' %s' "$runtime_args"
            printf '\n'
            ;;
        codex)
            add_dirs="$(append_codex_add_dirs "$worktree" "$worktrees")"
            prompt="Execute zyz-worker task $task_id. Use the zyz-worker:execute-task skill. If that installed skill is unavailable, read and follow the complete skill at $plugin_root/skills/execute-task/SKILL.md and every controller/reference it requires. The orchestrated ZYZ_* environment is authoritative."
            printf 'codex -C %s%s --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust --no-alt-screen' \
                "$(shell_quote "$worktree")" "$add_dirs"
            [ -n "$runtime_args" ] && printf ' %s' "$runtime_args"
            printf ' %s\n' "$(shell_quote "$prompt")"
            ;;
        *) echo "error: unsupported agent runtime: $runtime" >&2; exit 2 ;;
    esac
}

resume_command() {
    local runtime="$1" plugin_root="$2" worktree="$3" session_id="$4"
    local runtime_args="${5:-}" worktrees="${6:-}" add_dirs
    case "$runtime" in
        claude)
            printf 'cd %s && claude --resume %s --plugin-dir %s' \
                "$(shell_quote "$worktree")" "$(shell_quote "$session_id")" "$(shell_quote "$plugin_root")"
            [ -n "$runtime_args" ] && printf ' %s' "$runtime_args"
            printf '\n'
            ;;
        codex)
            add_dirs="$(append_codex_add_dirs "$worktree" "$worktrees")"
            printf 'codex resume %s -C %s%s --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust --no-alt-screen' \
                "$(shell_quote "$session_id")" "$(shell_quote "$worktree")" "$add_dirs"
            [ -n "$runtime_args" ] && printf ' %s' "$runtime_args"
            printf '\n'
            ;;
        *) echo "error: unsupported agent runtime: $runtime" >&2; exit 2 ;;
    esac
}

discover_session() {
    local runtime="$1" agent_pid="$2" worktree="$3" spawn_iso="$4"
    case "$runtime" in
        claude)
            local pointer sid transcript
            pointer="$HOME/.claude/sessions/$agent_pid.json"
            [ -f "$pointer" ] || return 0
            command -v python3 >/dev/null 2>&1 || return 0
            sid="$(ZYZ_POINTER="$pointer" python3 -c 'import json, os
try:
    print(json.load(open(os.environ["ZYZ_POINTER"])).get("sessionId", ""))
except Exception:
    pass' 2>/dev/null || true)"
            [ -n "$sid" ] || return 0
            transcript="$(find "$HOME/.claude/projects" -name "$sid.jsonl" 2>/dev/null | head -1)"
            [ -f "$transcript" ] || transcript=""
            printf '%s\t%s\n' "$sid" "$transcript"
            ;;
        codex)
            command -v python3 >/dev/null 2>&1 || return 0
            ZYZ_CODEX_CWD="$worktree" ZYZ_SPAWN_ISO="$spawn_iso" python3 - <<'PY'
import datetime as dt
import glob
import json
import os

cwd = os.path.realpath(os.environ.get("ZYZ_CODEX_CWD", ""))
spawn_raw = os.environ.get("ZYZ_SPAWN_ISO", "")
try:
    spawn = dt.datetime.strptime(spawn_raw, "%Y-%m-%dT%H:%M:%S%z").timestamp()
except Exception:
    spawn = 0

best = None
root = os.path.expanduser("~/.codex/sessions")
for path in glob.glob(root + "/**/*.jsonl", recursive=True):
    try:
        if os.path.getmtime(path) + 5 < spawn:
            continue
        with open(path, "r", encoding="utf-8") as fh:
            first = json.loads(fh.readline())
        if first.get("type") != "session_meta":
            continue
        payload = first.get("payload") or {}
        if os.path.realpath(payload.get("cwd") or "") != cwd:
            continue
        sid = payload.get("id") or payload.get("session_id")
        if not sid:
            continue
        candidate = (os.path.getmtime(path), sid, path)
        if best is None or candidate > best:
            best = candidate
    except Exception:
        continue
if best:
    print(f"{best[1]}\t{best[2]}")
PY
            ;;
        *) echo "error: unsupported agent runtime: $runtime" >&2; exit 2 ;;
    esac
}

cmd="${1:-}"
case "$cmd" in
    detect) [ "$#" -eq 1 ] || { usage; exit 2; }; detect_runtime ;;
    process-name)
        [ "$#" -eq 2 ] || { usage; exit 2; }
        case "$2" in claude|codex) printf '%s\n' "$2" ;; *) exit 2 ;; esac
        ;;
    launch-command) [ "$#" -ge 6 ] && [ "$#" -le 7 ] || { usage; exit 2; }; shift; launch_command "$@" ;;
    resume-command) [ "$#" -ge 6 ] && [ "$#" -le 7 ] || { usage; exit 2; }; shift; resume_command "$@" ;;
    discover-session) [ "$#" -eq 5 ] || { usage; exit 2; }; shift; discover_session "$@" ;;
    *) usage; exit 2 ;;
esac
