#!/usr/bin/env bash
#
# teammate-track.sh — record agent-team teammates' turns, so an idle teammate
# is not counted as an executor (lib.sh `idle agent-team teammates`).
#
# ## Trigger point
#
# - PostToolUse, matcher Agent: a spawn answered `teammate_spawned` records the
#   teammate (name, the descriptions its background_tasks entry may carry) as
#   busy. Any caller: a teammate may spawn teammates too.
# - SubagentStart, matcher `*`: a teammate starting a turn (at spawn, and on
#   every wake by a message) is busy.
# - TeammateIdle: the teammate ended its turn — idle.
# Tool calls in between mark it busy too (heartbeat.sh), as does nothing else.
#
# ## Inputs
#
# - stdin: hook JSON. PostToolUse: tool_input.{description,prompt,name},
#   tool_response.{status,name}. SubagentStart: agent_id, agent_type.
#   TeammateIdle: teammate_name.
#
# ## Outputs
#
# Nothing on stdout. Writes under the session's primary task:
# runtime/teammates/<name>.state (`busy|idle <epoch>`) and <name>.keys (JSON
# list: the spawn description, and the prompt's first 50 UTF-16 units plus
# "..." when it is longer — the form Claude Code 2.1.251 lists).
#
# ## Failure behavior
#
# Fail open: missing input, pointer, parser or write errors exit 0 silently.
# A teammate this hook never saw stays an executor (no false no-executor).
#
# ## Supported agents
#
# Claude Code agent teams. Codex has no TeammateIdle and no teammates; there
# the hook never matches anything.

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

zyz_json_ok || exit 0
ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"
[ -n "$ZYZ_HOOK_INPUT" ] || exit 0

base="$(zyz_get cwd)"
[ -n "$base" ] || base="${CODEX_PROJECT_DIR:-}"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || base="$PWD"

root="$(zyz_task_root "$base")"
[ -n "$root" ] || exit 0

case "$(zyz_get hook_event_name)" in
    TeammateIdle)
        zyz_teammate_mark "$root" "$(zyz_get teammate_name)" idle
        ;;
    SubagentStart)
        name="$(zyz_teammate_name)"
        [ -n "$name" ] && zyz_teammate_mark "$root" "$name" busy
        ;;
    PostToolUse)
        [ "$(zyz_get tool_response.status)" = teammate_spawned ] || exit 0
        command -v python3 >/dev/null 2>&1 || exit 0
        name="$(zyz_get tool_response.name)"
        [ -n "$name" ] || name="$(zyz_get tool_input.name)"
        [ -n "$name" ] || exit 0
        mkdir -p "$root/runtime/teammates" 2>/dev/null || exit 0
        keys="$root/runtime/teammates/$(zyz_sanitize "$name").keys"
        printf '%s' "$ZYZ_HOOK_INPUT" | python3 -c '
import json, os, sys
try:
    ti = json.load(sys.stdin).get("tool_input") or {}
except Exception:
    sys.exit(0)
keys = []
desc = ti.get("description")
if isinstance(desc, str) and desc:
    keys.append(desc)
prompt = ti.get("prompt")
if isinstance(prompt, str) and prompt:
    # JavaScript substring(0, 50) counts UTF-16 code units.
    units = prompt.encode("utf-16-le", "surrogatepass")
    head = units[:100].decode("utf-16-le", "surrogatepass")
    keys.append(head + ("..." if len(units) > 100 else ""))
tmp = sys.argv[1] + ".tmp.%d" % os.getpid()
with open(tmp, "w") as f:
    json.dump(keys, f)
os.replace(tmp, sys.argv[1])
' "$keys" 2>/dev/null || exit 0
        zyz_teammate_mark "$root" "$name" busy
        ;;
esac
exit 0
