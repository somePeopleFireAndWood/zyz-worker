#!/usr/bin/env bash
#
# api-failure.sh — records API-error terminations (StopFailure) as facts the L3
# watchdog turns into a wake-up for the main agent (0.32.0).
#
# ## Trigger point
#
# Registered in hooks/hooks.json for StopFailure, after notify.sh. The host
# fires StopFailure instead of Stop / SubagentStop when a turn ends on an API
# error (rate_limit, billing_error, server_error, ...), in the main session and
# inside a subagent or an in-process agent-team teammate (the common agent_id /
# agent_type fields then name it). Its output is ignored by the host, so a
# record on disk is the only way the event can reach the main agent: notify.sh
# alone told the user (who may be asleep) and left the main agent waiting
# forever for a result that would never come — the 11-19 incident, where a
# reviewer teammate died on a 402 at 04:14 and nothing moved until 10:49.
#
# ## Inputs
#
# - stdin: hook JSON (cwd, agent_id?, agent_type?, error, error_details?,
#   last_assistant_message?).
# - env: ZYZ_HOOKS_DISABLE=1 skips.
#
# ## Outputs
#
# - None on stdout.
# - Side effect: one file per event,
#   <primary-task>/runtime/api-failures/<epoch>-<pid>-<rand>.rec, holding one
#   tab-separated line `<epoch> <agent_id|-> <agent_type|-> <error|unknown>
#   <details|->`. monitors/watchdog.sh reports pending records and moves them
#   under api-failures/reported/; records older than 7 days (reported, or
#   pending because every task had finished) are pruned here. A record of the
#   main agent's own turn also sets main-state to idle (that turn has ended).
#
# ## Failure behavior
#
# Fail open: missing input, pointer, python3 or a write error exits 0 with no
# side effect.
#
# ## Supported agents
#
# All (main agent, subagents, teammates). No-op unless a task pointer of this
# session resolves (zyz_task_roots); records go to the primary task, where every
# subagent record lives.

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

command -v python3 >/dev/null 2>&1 || exit 0
ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"
[ -n "$ZYZ_HOOK_INPUT" ] || exit 0

# One parse for every field: cwd first (pointer resolution), then the record.
fields="$(printf '%s' "$ZYZ_HOOK_INPUT" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, dict) or d.get("hook_event_name") not in (None, "StopFailure"):
    sys.exit(0)
def one(v, n):
    v = " ".join(str(v or "").split())[:n]
    return v or "-"
idv = one(d.get("agent_id"), 128)
if not re.fullmatch(r"[A-Za-z0-9._:@-]{1,128}", idv):
    idv = "-"
print(one(d.get("cwd"), 4096))
print("\t".join((idv, one(d.get("agent_type"), 128), one(d.get("error") or "unknown", 64),
                 one(d.get("error_details") or d.get("last_assistant_message"), 300))))
' 2>/dev/null)" || exit 0
[ -n "$fields" ] || exit 0
cwd="${fields%%
*}"
record="${fields#*
}"
[ "$cwd" != "-" ] || cwd=""

base="$cwd"
[ -n "$base" ] || base="${CODEX_PROJECT_DIR:-}"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || base="$PWD"
roots="$(zyz_task_roots "$base")"
[ -n "$roots" ] || exit 0
root="${roots%%
*}"

dir="$root/runtime/api-failures"
mkdir -p "$dir" 2>/dev/null || exit 0
now="$(zyz_now)"
tab="$(printf '\t')"
zyz_write_atomic "$dir/$now-$$-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo 0).rec" \
    "$now$tab$record"
# The main agent's own turn ended: like a Stop, it is idle now. Without this
# main-state stays `working` and the status-stale finding (muted only while
# idle / awaiting-user) piles a 15-minute wake-up on top of session silence.
case "$record" in
    -"$tab"*)
        while IFS= read -r r; do
            [ -n "$r" ] && zyz_main_state_set "$r" idle
        done <<ZYZ_AF_ROOTS
$roots
ZYZ_AF_ROOTS
        ;;
esac
# Bounded lifecycle: reported records, and pending ones no scan consumed (every
# task finished), go after 7 days, so a reopened task never reports stale ones.
find "$dir" -maxdepth 2 -type f -name '*.rec' -mtime +7 -delete 2>/dev/null || true
exit 0
