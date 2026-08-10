#!/usr/bin/env bash
#
# orch-worker-mcp-args.sh — print the runtime-specific MCP-isolation CLI args
# for a worker agent. Side-effect-free: reads one host env var and writes
# one line to stdout (possibly empty). It never touches tmux — spawn / reuse
# call it at container-build time and snapshot the result into dispatch.md
# (`worker-mcp-args:`), which is where the L2 driver and the crash-recovery
# runtime resume command read it back from.
#
# Why: every worker is a full `claude` process, and Claude Code spawns stdio
# MCP servers PER PROCESS — they cannot be shared. So each worker re-pays the
# host's entire global mcpServers baseline (measured: ~745 MB/worker for one
# lark-mcp alone, ~695 MB of it Private per smaps_rollup — genuinely N copies).
# Most execute-task work is pure code work that never touches those tools, so
# the default is NOT to inherit them: `--strict-mcp-config` with no
# `--mcp-config` gives the worker zero MCP servers. This is the memory-axis
# sibling of orch-build-env.sh (which caps `workers × go-build -p` disk I/O):
# same shape, `workers × MCP baseline`, and the knob to turn is the inheritance
# policy — not the worker count.
#
# Contract:
#   Input:
#     $1 (optional)     claude | codex; auto-detected when omitted
#     ZYZ_WORKER_MCP   MCP inheritance policy. One of:
#       none (default)  -> Claude: `--strict-mcp-config`
#                          Codex: one `-c mcp_servers.<name>.enabled=false`
#                          override per currently-enabled server
#                          (worker gets ZERO MCP servers; ~745 MB/worker saved
#                          per stdio server the host has configured)
#       inherit         -> print nothing
#                          (legacy behavior: worker inherits the host's global
#                          ~/.claude.json mcpServers, paying the full baseline)
#       <config-path>   -> Claude only: print
#                          `--strict-mcp-config --mcp-config '<path>'`
#                          (worker gets EXACTLY the servers in that JSON file
#                          — the hook for pointing workers at a shared server;
#                          see the security caveat in the README before
#                          exposing any credential-bearing server)
#     A `~/`-prefixed path is expanded. A <config-path> that is not an existing
#     readable file, is not absolute after expansion, or contains a single
#     quote (it would break the single-quote wrapping in the launch command)
#     falls back to `none` with a warning on stderr — fail CLOSED to zero MCP,
#     never silently open to full inheritance.
#
#   Output (stdout): exactly one line (or empty for `inherit`).
#   Exit codes: 0 always.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="${1:-}"
if [ -z "$RUNTIME" ]; then
    RUNTIME="$("$SCRIPT_DIR/orch-agent-runtime.sh" detect 2>/dev/null || printf 'claude')"
fi
case "$RUNTIME" in
    claude|codex) ;;
    *) echo "warning: invalid worker runtime '$RUNTIME'; defaulting to claude MCP semantics" >&2; RUNTIME=claude ;;
esac

POLICY="${ZYZ_WORKER_MCP:-none}"

case "$POLICY" in
    none)
        if [ "$RUNTIME" = "codex" ]; then
            # Interactive `codex` does not accept the exec-only
            # --ignore-user-config flag, and `-c mcp_servers={}` is merged with
            # (not substituted for) user config. Snapshot every enabled server
            # and disable it explicitly. Names are quoted as TOML key segments.
            if ! command -v codex >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
                echo "warning: codex/python3 unavailable; cannot build fail-closed MCP overrides" >&2
                exit 1
            fi
            MCP_JSON="$(codex mcp list --json 2>/dev/null)" || {
                echo "warning: 'codex mcp list --json' failed; cannot build fail-closed MCP overrides" >&2
                exit 1
            }
            ZYZ_MCP_JSON="$MCP_JSON" python3 - <<'PY'
import json, os, re, sys
try:
    items = json.loads(os.environ.get("ZYZ_MCP_JSON", "[]"))
except Exception as exc:
    print(f"warning: invalid Codex MCP JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)
args = []
for item in items:
    if not item.get("enabled"):
        continue
    name = item.get("name") or ""
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        print(f"warning: unsupported Codex MCP server name {name!r}; cannot safely render override", file=sys.stderr)
        raise SystemExit(1)
    args.append(f"-c 'mcp_servers.{name}.enabled=false' ")
print("".join(args).rstrip())
PY
        else
            printf -- '--strict-mcp-config\n'
        fi
        exit 0
        ;;
    inherit)
        exit 0
        ;;
esac

if [ "$RUNTIME" = "codex" ]; then
    echo "warning: ZYZ_WORKER_MCP custom config paths are Claude-only; Codex is falling back to explicit disable-all MCP overrides" >&2
    POLICY=none
    MCP_JSON="$(codex mcp list --json 2>/dev/null)" || exit 1
    ZYZ_MCP_JSON="$MCP_JSON" python3 - <<'PY'
import json, os, re, sys
items = json.loads(os.environ.get("ZYZ_MCP_JSON", "[]"))
args = []
for item in items:
    if not item.get("enabled"):
        continue
    name = item.get("name") or ""
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        raise SystemExit(1)
    args.append(f"-c 'mcp_servers.{name}.enabled=false' ")
print("".join(args).rstrip())
PY
    exit $?
fi

# Anything else is a config path. Expand ~/ with the same quoted-pattern idiom
# the other helpers use.
case "$POLICY" in
    "~/"*) POLICY="$HOME/${POLICY#"~/"}" ;;
esac

fallback() {
    echo "warning: ZYZ_WORKER_MCP='$1' $2; falling back to 'none' (--strict-mcp-config, zero MCP)" >&2
    printf -- '--strict-mcp-config\n'
    exit 0
}

case "$POLICY" in
    *\'*) fallback "$POLICY" "contains a single quote (would break the launch command's quoting)" ;;
    /*) : ;;
    *) fallback "$POLICY" "is not an absolute path (after ~/ expansion)" ;;
esac

if [ ! -f "$POLICY" ] || [ ! -r "$POLICY" ]; then
    fallback "$POLICY" "is not an existing readable file"
fi

printf -- "--strict-mcp-config --mcp-config '%s'\n" "$POLICY"
exit 0
