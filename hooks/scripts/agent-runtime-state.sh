#!/usr/bin/env bash
# Supported, fail-closed interface for execute-task runtime state changes.
# Exact public command set (implemented by runtime_state.py):
# adopt-legacy finalize gc-step probe-ack probe-cancel probe-create probe-status
# reconcile-start reconcile-stop
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$SCRIPT_DIR/runtime_state.py" "$@"
fi
printf '%s\n' '{"ok":false,"state":"error","error":{"code":"python-unavailable","message":"python3 is required for bounded runtime state mutations","retryable":false}}'
exit 1
