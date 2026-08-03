#!/usr/bin/env bash
#
# orch-worker-mcp-args.sh — print the MCP-isolation CLI args for a worker's
# `claude` launch command. Side-effect-free: reads ONE host env var and writes
# one line to stdout (possibly empty). It never touches tmux — spawn / reuse
# call it at container-build time and snapshot the result into dispatch.md
# (`worker-mcp-args:`), which is where the L2 driver and the crash-recovery
# `claude --resume` command read it back from.
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
#   Input (host env, optional):
#     ZYZ_WORKER_MCP   MCP inheritance policy. One of:
#       none (default)  -> print `--strict-mcp-config`
#                          (worker gets ZERO MCP servers; ~745 MB/worker saved
#                          per stdio server the host has configured)
#       inherit         -> print nothing
#                          (legacy behavior: worker inherits the host's global
#                          ~/.claude.json mcpServers, paying the full baseline)
#       <config-path>   -> print `--strict-mcp-config --mcp-config '<path>'`
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

POLICY="${ZYZ_WORKER_MCP:-none}"

case "$POLICY" in
    none)
        printf -- '--strict-mcp-config\n'
        exit 0
        ;;
    inherit)
        exit 0
        ;;
esac

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
