#!/usr/bin/env bash
#
# test-e2e-layered.sh — end-to-end acceptance for the 3-layer orchestration
# scheduling architecture. It fixes the manual e2e walkthrough into a portable
# script so a Linux dev machine can validate the whole chain with one command:
#
#     spawn (container-only)
#        -> L2 launches a REAL claude in the recorded pane (clears the startup
#           confirmation pages, probes for readiness)
#        -> parent-shell invariant (claude is a DIRECT child of the pane shell)
#        -> exactly-once idempotency (re-running the pre-launch authority check
#           does NOT double-launch)
#        -> dispatch-bound (a trivial LLM round-trip materializes the transcript
#           so orch-check-worker.sh flips dispatch-bound=true)
#        -> command-resolves (the namespaced `/zyz-worker:execute-task <task-id>`
#           is accepted by the same live Claude process and advances its
#           transcript without producing "Unknown command")
#
# Usage:
#     bash scripts/test-e2e-layered.sh [--keep]
#
#     --keep   Do NOT clean up the fixture on exit. Prints the retained paths
#              (temp list-dir, temp source repo, worktree, tmux session) so you
#              can attach and inspect. Default is to clean everything up.
#
# Dependencies (all looked up via PATH — NEVER hardcoded):
#     tmux     real tmux on PATH.
#     git      real git on PATH.
#     claude   real claude CLI on PATH, ALREADY LOGGED IN. The script launches
#              an actual claude process and (assertion A4) sends it a trivial
#              prompt that triggers one LLM round-trip.
#
# WARNING — A4 CONSUMES API QUOTA. The dispatch-bound assertion sends claude a
# real prompt ("reply with PONG") to force the first LLM round-trip, because the
# session pointer + transcript files are only written by Claude Code AFTER that
# first round-trip (see skills/orchestration-scheduling-task/SKILL.md
# "How dispatch.md binding works"). A5 then sends one more real command
# (`/zyz-worker:execute-task <task-id>`) to prove the namespaced slash command
# resolves in the worker session — two round-trips per run (A4 PONG + A5
# command).
#
# Cross-platform notes (this is the whole point — it must run on Linux AND
# macOS bash 3.2):
#     - No hardcoded tool paths. `command -v tmux/git/claude` only.
#     - `pgrep -P <shell-pid> -n -x claude` and
#       `pgrep -P <shell-pid> -x claude | wc -l` behave identically on Linux and
#       BSD (`comm` truncates to 15 chars on Linux; `claude` is 6 chars, safe).
#     - The `❯ ` ready glyph and the confirmation-page wording are claude-VERSION
#       specific (not OS specific). We match LOOSELY: poll capture-pane for any
#       of several ready indicators, and grep confirmation pages for keywords
#       ("trust", "Bypass Permissions", "Yes, I accept") rather than exact full
#       strings. Between confirmation keystrokes we capture -> match -> send key
#       -> capture again to confirm the page advanced (never blind-send).
#       Claude 2.1.251 adds a generic `Enter to confirm · Esc to cancel` footer;
#       Enter is sent only after the selected row is positively identified as
#       the accepting choice. A reject-selected or unknown page is never blindly
#       confirmed.
#     - Readiness probe has a 30s timeout; on timeout it PRINTS the pane content
#       for diagnosis rather than hanging.
#     - `set -uo pipefail`, NO `set -e`, so every assertion result prints.
#     - No bash-4-only features (no associative arrays) so macOS bash 3.2 runs.
#     - `mktemp -d` for temp dirs; `pwd -P` where physical paths matter (to
#       match how orch-spawn-worker.sh records encoded-cwd).
#
# Observation ceiling: A5 proves that the live Claude child accepted enough of
# the namespaced command to persist new transcript state, then remained alive
# without an Unknown command diagnostic through a short stabilization window.
# It does not wait for the execute-task workflow to finish. Do not read the
# green check as workflow-completion proof.
#
# Mutation manifest:
#   confirmation safety -> replace state-aware selection with unconditional
#     `tmux send-keys ... Enter` -> A2 ready/live-child guard must turn red on a
#     reject-selected confirmation page;
#   live-session gate -> remove the direct-child+ready check before A4/A5 -> A4
#     or A5 must no longer be allowed to send and pass after Claude exits;
#   positive A5 evidence -> delete transcript-advance requirement -> mutation
#     is SURVIVED only by the banned absence-only oracle, so A5 must require both
#     transcript advancement and absence of Unknown command.
#   A4 response decoration -> remove Claude 2.1.251's `⏺` from the explicit
#     decoration set -> exact decorated `⏺ PONG` must turn the A4 gate red.
#
# Exit codes:
#     0   all assertions passed (A1.1, A1.2, A2, A3, A4, A5)
#     1   one or more assertions failed
#     3   a required dependency (tmux / git / claude) is missing from PATH
#
set -uo pipefail

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------

KEEP=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--keep]"
            echo "  --keep   retain the fixture (temp list-dir, source repo, worktree, tmux session) for debugging"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "Usage: $(basename "$0") [--keep]" >&2
            exit 3
            ;;
    esac
done

# Dependency checks (PATH lookup only — never hardcoded paths).
MISSING=""
for dep in tmux git claude; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        MISSING="$MISSING $dep"
    fi
done
if [ -n "$MISSING" ]; then
    echo "error: missing required dependency on PATH:$MISSING" >&2
    echo "  This acceptance script needs tmux, git, and claude all on PATH." >&2
    echo "  claude must additionally be LOGGED IN (the dispatch-bound assertion" >&2
    echo "  triggers a real LLM round-trip). Install/login the missing tool(s)" >&2
    echo "  and re-run. Exiting without running any assertion." >&2
    exit 3
fi

# Resolve PLUGIN_ROOT the same way orch-spawn-worker.sh does: default to the
# script's parent dir, allow $CLAUDE_PLUGIN_ROOT to override.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SPAWN_SCRIPT="$SCRIPT_DIR/orch-spawn-worker.sh"
CHECK_SCRIPT="$SCRIPT_DIR/orch-check-worker.sh"

if [ ! -x "$SPAWN_SCRIPT" ]; then
    echo "error: spawn helper not found or not executable: $SPAWN_SCRIPT" >&2
    exit 3
fi
if [ ! -x "$CHECK_SCRIPT" ]; then
    echo "error: check helper not found or not executable: $CHECK_SCRIPT" >&2
    exit 3
fi

# Globally-unique prefix to avoid collisions with concurrent runs or stale
# fixtures. $$ (this script's PID) is stable for the run.
PREFIX="zyz-e2e-$$"
TASK_ID="$PREFIX"
TMUX_SESSION="zyz-task-$TASK_ID"

# Fixture roots (filled in by the fixture step; referenced by cleanup).
LIST_DIR=""
SOURCE_REPO=""
WORKTREE=""

# ---------------------------------------------------------------------------
# Output helpers (mirror scripts/test-orchestration-helpers.sh style:
# 2-space indent, PASS / FAIL prefixes).
# ---------------------------------------------------------------------------
PASSED=0
FAILED=0

pass() {
    PASSED=$((PASSED + 1))
    echo "  PASS  $1"
}

fail() {
    FAILED=$((FAILED + 1))
    echo "  FAIL  $1"
}

info() {
    echo "  ...   $1"
}

# Dump a labelled block of pane content for diagnosis (indented for readability).
dump_pane() {
    local label="$1"
    local content="$2"
    echo "  ----- $label -----"
    printf '%s\n' "$content" | sed 's/^/      | /'
    echo "  -------------------"
}

# ---------------------------------------------------------------------------
# Cleanup (trap EXIT). Idempotent / best-effort: every step guarded with
# `|| true` so a partial fixture never leaves the trap erroring. --keep skips
# the rm steps and prints the retained paths.
# ---------------------------------------------------------------------------
cleanup() {
    if [ "$KEEP" -eq 1 ]; then
        echo
        echo "  --keep set: retaining fixture for debugging:"
        echo "    list-dir   : ${LIST_DIR:-<unset>}"
        echo "    source-repo: ${SOURCE_REPO:-<unset>}"
        echo "    worktree   : ${WORKTREE:-<unset>}"
        echo "    tmux       : tmux attach -t $TMUX_SESSION"
        echo "    (kill manually: tmux kill-session -t $TMUX_SESSION)"
        return
    fi

    # Kill the tmux session (this also SIGHUPs the in-pane heartbeat daemon and
    # the claude process, the natural teardown path).
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    # Remove the worktree + delete its branch from the source repo.
    if [ -n "$SOURCE_REPO" ] && [ -d "$SOURCE_REPO" ]; then
        if [ -n "$WORKTREE" ]; then
            git -C "$SOURCE_REPO" worktree remove --force "$WORKTREE" 2>/dev/null || true
        fi
        git -C "$SOURCE_REPO" worktree prune 2>/dev/null || true
        git -C "$SOURCE_REPO" branch -D "task/$TASK_ID" 2>/dev/null || true
    fi

    # Remove the temp dirs.
    [ -n "$LIST_DIR" ] && rm -rf "$LIST_DIR" 2>/dev/null || true
    [ -n "$SOURCE_REPO" ] && rm -rf "$SOURCE_REPO" 2>/dev/null || true
    # The worktree usually lives under $HOME/.zyz-worker/worktrees/...; remove
    # the leaf in case `git worktree remove` could not (e.g. already pruned).
    [ -n "$WORKTREE" ] && rm -rf "$WORKTREE" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Fixture
# ---------------------------------------------------------------------------

echo "=== test-e2e-layered: building fixture (task-id=$TASK_ID) ==="

# Temp source repo: a real git repo with one commit on `main`.
SOURCE_REPO="$(mktemp -d "${TMPDIR:-/tmp}/$PREFIX-repo.XXXXXX")"
(
    cd "$SOURCE_REPO" || exit 1
    git init -q . >/dev/null 2>&1
    git config user.email "e2e@example.com"
    git config user.name "E2E Test"
    git checkout -q -b main 2>/dev/null || git checkout -q main
    echo "e2e-layered fixture source repo" > README.md
    git add README.md
    git commit -q -m "initial"
) || {
    echo "error: failed to initialize temp source repo at $SOURCE_REPO" >&2
    exit 1
}

# Temp list-dir with one ready task whose source-repo points at the temp repo.
# Place the worktree under the list-dir tree so cleanup is fully contained.
LIST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/$PREFIX-list.XXXXXX")"
WORKTREE="$LIST_DIR/worktree-$TASK_ID"
mkdir -p "$LIST_DIR/tasks"
{
    echo "---"
    echo "task-id: $TASK_ID"
    echo "project: e2e-layered"
    echo "source-repo: $SOURCE_REPO"
    echo "state: ready"
    echo "priority: normal"
    echo "branch: task/$TASK_ID"
    echo "base: main"
    echo "worktree: $WORKTREE"
    echo "tmux-session: $TMUX_SESSION"
    echo "blocked-by: []"
    echo "merged-with: []"
    echo "deps-tentative: false"
    echo "last-seen:"
    echo "heartbeat-stale-sec: 300"
    echo "created-at: 2026-06-21"
    echo "updated-at: 2026-06-21"
    echo "---"
    echo ""
    echo "# $TASK_ID (e2e-layered)"
    echo ""
    echo "## Description"
    echo ""
    echo "End-to-end layered-architecture acceptance fixture."
} > "$LIST_DIR/tasks/$TASK_ID.md"

DISPATCH_FILE="$LIST_DIR/runtime/$TASK_ID/dispatch.md"

# ---------------------------------------------------------------------------
# Frontmatter field reader (awk one-liner) — same fence-aware logic the
# helpers use, scoped to dispatch.md Phase-1 keys we read back.
# ---------------------------------------------------------------------------
fm_field() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || { printf ''; return 0; }
    awk -v k="$key" '
        BEGIN { in_fm = 0; fence = 0 }
        /^---[[:space:]]*$/ {
            fence++
            if (fence == 1) { in_fm = 1; next }
            if (fence == 2) { exit }
        }
        in_fm == 1 {
            if (match($0, "^[[:space:]]*" k "[[:space:]]*:")) {
                v = substr($0, RSTART + RLENGTH)
                sub(/^[[:space:]]+/, "", v)
                sub(/[[:space:]]+$/, "", v)
                print v
                exit
            }
        }
    ' "$file"
}

# ---------------------------------------------------------------------------
# Pane helpers (LOOSE matching — version-resilient).
# ---------------------------------------------------------------------------

# Capture the current pane content as plain text.
capture() {
    tmux capture-pane -p -t "$PANE_ID" 2>/dev/null || true
}

# Return 0 if the pane is showing the trust-folder confirmation page.
pane_is_trust_page() {
    local content="$1"
    printf '%s\n' "$content" | tail -15 | grep -qiE 'trust the files|trust this folder|do you trust'
}

# Return 0 if the pane is showing the bypass-permissions risk page.
pane_is_bypass_page() {
    local content="$1"
    printf '%s\n' "$content" | tail -15 | grep -qiE 'Bypass Permissions mode|bypass permissions\?|Yes, I accept|WARNING:.*[Bb]ypass'
}

# Return 0 for any interactive confirmation surface, including versions whose
# page-specific heading drifted but whose confirmation footer is stable.
pane_is_confirmation_page() {
    local content="$1"
    pane_is_trust_page "$content" || pane_is_bypass_page "$content" \
        || printf '%s\n' "$content" | tail -12 | grep -qiE 'Enter to confirm.*Esc to cancel|Esc to cancel.*Enter to confirm'
}

# The selected row is the only safe basis for Enter. Headings containing words
# such as "trust" or "accept" are deliberately irrelevant.
confirmation_accept_selected() {
    printf '%s\n' "$1" | tail -12 \
        | grep -qiE '^[[:space:]]*[❯>●].*(Yes|accept|trust|continue|proceed)'
}

confirmation_reject_selected() {
    printf '%s\n' "$1" | tail -12 \
        | grep -qiE '^[[:space:]]*[❯>●].*(No|exit|cancel|decline)'
}

# Return 0 if the pane looks like a ready claude UI. We accept any of several
# indicators because the exact glyph/banner varies by claude version.
#
# CRITICAL: a confirmation page is NEVER "ready". The trust-folder and
# bypass-permissions risk pages render a selection menu whose cursor line is
# "❯ 1. No, exit" — that line contains the "❯ " glyph, so a naive ready-glyph
# match would fire on the confirmation page and the A2 loop would `break` before
# ever clearing it (claude then stays stuck on the page forever). Exclude the
# confirmation pages FIRST so the readiness check can never be satisfied by a
# menu-selection arrow. Also tighten the "❯ " match: a real ready prompt is
# "❯ " followed by whitespace or the user's typed text, NOT "❯ <digit>." (a
# numbered menu option).
pane_is_ready() {
    local content="$1"
    if pane_is_confirmation_page "$content"; then
        return 1
    fi
    printf '%s\n' "$content" | tail -12 \
        | grep -qE '❯ ([^0-9]|$)|bypass permissions on|Bypass permissions on|for shortcuts'
}

# Count claude processes that are direct children of the recorded pane shell.
claude_child_count() {
    pgrep -P "$SHELL_PID" -x claude 2>/dev/null | wc -l | tr -d ' '
}

# Newest claude that is a direct child of the recorded pane shell (empty if none).
claude_child_newest() {
    pgrep -P "$SHELL_PID" -n -x claude 2>/dev/null || true
}

claude_session_ready_now() {
    local content
    content="$(capture)"
    [ "$(claude_child_count)" = "1" ] \
        && [ -n "$(claude_child_newest)" ] \
        && pane_is_ready "$content"
}

# advance_confirmation_page <captured-content>
# Returns 0 only after sending Enter to an accepting selected row. If a reject
# row is selected, move once and re-capture; Enter is still forbidden unless the
# accepting row is then visibly selected. This is the guard Claude 2.1.251's
# default "No, exit" selection requires.
advance_confirmation_page() {
    local before="$1" selected
    selected="$before"
    if confirmation_reject_selected "$selected"; then
        info "confirmation page has reject/exit selected; sending Down only"
        tmux send-keys -t "$PANE_ID" Down
        sleep 1
        selected="$(capture)"
    fi
    if ! confirmation_accept_selected "$selected"; then
        info "confirmation page accepting row is not positively selected; refusing Enter"
        return 1
    fi
    info "confirmation page accepting row selected; sending Enter"
    tmux send-keys -t "$PANE_ID" Enter
    sleep 1
    [ "$(claude_child_count)" = "1" ]
}

file_fingerprint() {
    [ -f "$1" ] || { printf ''; return 0; }
    cksum "$1" 2>/dev/null | awk '{print $1 ":" $2}'
}

# ===========================================================================
# A1 — spawn container-only
# ===========================================================================
echo
echo "=== A1: spawn container-only ==="

# This suite is explicitly the real-Claude acceptance layer. A Codex-hosted
# parent exports CODEX_CI/CODEX_THREAD_ID; isolate those host identities and
# force Claude so dispatch.md and worker runtime args match the CLI launched
# below. Runtime auto-detection is covered by test-codex-adaptation.sh instead.
SPAWN_OUT="$(
    unset CODEX_CI CODEX_THREAD_ID
    ZYZ_AGENT_RUNTIME=claude bash "$SPAWN_SCRIPT" "$TASK_ID" "$LIST_DIR" 2>&1
)"
SPAWN_RC=$?

if [ "$SPAWN_RC" -ne 0 ]; then
    fail "A1 spawn exited $SPAWN_RC (expected 0)"
    dump_pane "spawn output" "$SPAWN_OUT"
    # Without dispatch.md the rest cannot run; emit FAILs for A2-A5 and finish.
    fail "A2 parent-shell invariant (skipped: spawn failed)"
    fail "A3 exactly-once idempotency (skipped: spawn failed)"
    fail "A4 dispatch-bound (skipped: spawn failed)"
    fail "A5 command-resolves (skipped: spawn failed)"
    echo
    echo "E2E RESULT: $PASSED passed, $FAILED failed"
    exit 1
fi

# Assertion A1.1: stdout must NOT contain an `auto-start=` line (spawn is
# container-only; the --auto-start flag was removed in the layered redesign).
if printf '%s\n' "$SPAWN_OUT" | grep -qE '^auto-start='; then
    fail "A1 spawn stdout contains an 'auto-start=' line (must be container-only)"
    dump_pane "spawn output" "$SPAWN_OUT"
else
    pass "A1 spawn stdout has no 'auto-start=' line (container-only)"
fi

# Read back the Phase-1 dispatch.md fields the rest of the script depends on.
if [ ! -f "$DISPATCH_FILE" ]; then
    fail "A1 dispatch.md not written at $DISPATCH_FILE"
    fail "A2 parent-shell invariant (skipped: no dispatch.md)"
    fail "A3 exactly-once idempotency (skipped: no dispatch.md)"
    fail "A4 dispatch-bound (skipped: no dispatch.md)"
    fail "A5 command-resolves (skipped: no dispatch.md)"
    echo
    echo "E2E RESULT: $PASSED passed, $FAILED failed"
    exit 1
fi

SHELL_PID="$(fm_field "$DISPATCH_FILE" shell-pid)"
PANE_ID="$(fm_field "$DISPATCH_FILE" tmux-pane-id)"
DISPATCH_PLUGIN_ROOT="$(fm_field "$DISPATCH_FILE" plugin-root)"
DISPATCH_RUNTIME="$(fm_field "$DISPATCH_FILE" agent-runtime)"

if [ -z "$SHELL_PID" ] || [ -z "$PANE_ID" ]; then
    fail "A1 dispatch.md missing shell-pid ('$SHELL_PID') or tmux-pane-id ('$PANE_ID')"
    dump_pane "dispatch.md" "$(cat "$DISPATCH_FILE" 2>/dev/null)"
    fail "A2 parent-shell invariant (skipped: incomplete dispatch.md)"
    fail "A3 exactly-once idempotency (skipped: incomplete dispatch.md)"
    fail "A4 dispatch-bound (skipped: incomplete dispatch.md)"
    fail "A5 command-resolves (skipped: incomplete dispatch.md)"
    echo
    echo "E2E RESULT: $PASSED passed, $FAILED failed"
    exit 1
fi
info "shell-pid=$SHELL_PID  tmux-pane-id=$PANE_ID  plugin-root=$DISPATCH_PLUGIN_ROOT"

if [ "$DISPATCH_RUNTIME" = "claude" ]; then
    pass "A1 dispatch.md records agent-runtime=claude for real-Claude E2E"
else
    fail "A1 dispatch.md agent-runtime='$DISPATCH_RUNTIME' (expected claude; refusing to launch mismatched CLI/runtime args)"
    fail "A2 parent-shell invariant (skipped: fixture runtime mismatch)"
    fail "A3 exactly-once idempotency (skipped: fixture runtime mismatch)"
    fail "A4 dispatch-bound (skipped: fixture runtime mismatch)"
    fail "A5 command-resolves (skipped: fixture runtime mismatch)"
    echo
    echo "E2E RESULT: $PASSED passed, $FAILED failed"
    exit 1
fi

# Assertion A1.2: spawn must NOT have started claude. No claude child of the
# pane shell should exist yet.
A1_CLAUDE_COUNT="$(claude_child_count)"
if [ "$A1_CLAUDE_COUNT" = "0" ]; then
    pass "A1 no claude child of shell-pid after spawn (count=0; spawn never starts claude)"
else
    fail "A1 spawn unexpectedly started claude (pgrep -P $SHELL_PID -x claude count=$A1_CLAUDE_COUNT, expected 0)"
fi

# ===========================================================================
# A2 — parent-shell invariant (simulate L2 first-dispatch)
# ===========================================================================
echo
echo "=== A2: parent-shell invariant (L2 first-dispatch launch) ==="

# Launch claude into the RECORDED pane so it becomes a DIRECT child of
# SHELL_PID. NO nohup / setsid / subshell / & / new window — any reparent would
# break pgrep -P <shell-pid>. Use the plugin-root recorded in dispatch.md (fall
# back to PLUGIN_ROOT if somehow empty). Append the worker-mcp-args snapshot
# from dispatch.md, exactly as the L2 driver contract specifies (issue #2 —
# default policy renders --strict-mcp-config, so the worker starts MCP-free).
LAUNCH_PLUGIN_ROOT="${DISPATCH_PLUGIN_ROOT:-$PLUGIN_ROOT}"
DISPATCH_MCP_ARGS="$(awk -F': ' '/^worker-mcp-args:/{sub(/^ +/,"",$2); print $2; exit}' "$DISPATCH_FILE" 2>/dev/null || true)"
LAUNCH_CMD="claude --plugin-dir '$LAUNCH_PLUGIN_ROOT' --permission-mode bypassPermissions --dangerously-skip-permissions --settings '{\"ultracode\": true}'${DISPATCH_MCP_ARGS:+ $DISPATCH_MCP_ARGS}"
info "send-keys launch into pane $PANE_ID: $LAUNCH_CMD"
tmux send-keys -t "$PANE_ID" "$LAUNCH_CMD" Enter

# State-aware confirmation/readiness probe (<=45s). A page may change from
# trust to bypass confirmation, so every iteration reclassifies current state;
# there are no stale TRUST_DONE/BYPASS_DONE flags and no blind late-page Enter.
READY=0
CLAUDE_WAS_SEEN=0
READY_DEADLINE=$(( $(date +%s) + 45 ))
while [ "$(date +%s)" -lt "$READY_DEADLINE" ]; do
    CONTENT="$(capture)"
    CURRENT_CHILD_COUNT="$(claude_child_count)"
    if [ "$CURRENT_CHILD_COUNT" = "1" ]; then
        CLAUDE_WAS_SEEN=1
    elif [ "$CLAUDE_WAS_SEEN" -eq 1 ]; then
        info "Claude direct child disappeared during confirmation handling"
        break
    fi
    if [ "$CURRENT_CHILD_COUNT" = "1" ] && pane_is_ready "$CONTENT"; then
        READY=1
        break
    fi
    if pane_is_confirmation_page "$CONTENT"; then
        advance_confirmation_page "$CONTENT" || true
    fi
    sleep 1
done

if [ "$READY" -ne 1 ]; then
    fail "A2 claude did not remain a direct live child and reach a non-confirmation ready prompt within 45s"
    dump_pane "pane content at readiness timeout" "$(capture)"
fi

# Assertion A2: claude must be a DIRECT child of the recorded pane shell, and
# exactly one such claude must exist.
A2_NEWEST="$(claude_child_newest)"
A2_COUNT="$(claude_child_count)"
if [ -n "$A2_NEWEST" ] && [ "$A2_COUNT" = "1" ]; then
    pass "A2 claude is a direct child of shell-pid (pid=$A2_NEWEST, count=1; parent-shell invariant holds)"
else
    fail "A2 parent-shell invariant broken (pgrep -P $SHELL_PID -n -x claude='$A2_NEWEST', count=$A2_COUNT; expected one direct child)"
    dump_pane "pane content" "$(capture)"
fi

# ===========================================================================
# A3 — exactly-once idempotency
# ===========================================================================
echo
echo "=== A3: exactly-once idempotency (re-run pre-launch authority check) ==="

# Re-run the L2 pre-launch authority check: capture-pane; if a claude UI is
# already present, treat the worker as already started and DO NOT launch again.
CONTENT="$(capture)"
if pane_is_ready "$CONTENT"; then
    info "pre-launch check: claude UI already present -> skip launch (idempotent)"
    # Intentionally do NOT send the launch command again.
else
    info "pre-launch check: no claude UI detected -> (would launch); not re-launching in this probe"
fi

# Assertion A3: still exactly one claude child of the pane shell (no double-launch).
A3_COUNT="$(claude_child_count)"
if [ "$A3_COUNT" = "1" ]; then
    pass "A3 still exactly one claude child after re-check (count=1; no double-launch)"
else
    fail "A3 claude child count is $A3_COUNT after re-check (expected 1; idempotency violated)"
    dump_pane "pane content" "$(capture)"
fi

# ===========================================================================
# A4 — dispatch-bound (consumes API quota: one LLM round-trip)
# ===========================================================================
echo
echo "=== A4: dispatch-bound (trivial LLM round-trip; CONSUMES API QUOTA) ==="

# Send only after a fresh boundary check proves input still targets the one live
# Claude child, not a zsh pane left behind by a rejected confirmation page.
A4_SENT=0
if claude_session_ready_now; then
    info "sending trivial prompt 'reply with PONG' to the verified live Claude child"
    tmux send-keys -t "$PANE_ID" "reply with PONG" Enter
    A4_SENT=1
else
    info "refusing A4 prompt: pane is not one direct live, non-confirmation-ready Claude session"
fi

# Poll orch-check-worker.sh for dispatch-bound=true (it lazily fills Phase-2 and
# discovers the transcript once it lands). Up to ~60s.
A4_BOUND=""
A4_ALIVE=""
A4_PONG=0
A4_READY_AFTER=0
A4_DEADLINE=$(( $(date +%s) + 60 ))
while [ "$A4_SENT" -eq 1 ] && [ "$(date +%s)" -lt "$A4_DEADLINE" ]; do
    CHECK_OUT="$(bash "$CHECK_SCRIPT" "$TASK_ID" "$LIST_DIR" 2>/dev/null || true)"
    A4_BOUND="$(printf '%s\n' "$CHECK_OUT" | sed -n 's/^dispatch-bound=//p')"
    A4_ALIVE="$(printf '%s\n' "$CHECK_OUT" | sed -n 's/^session-alive=//p')"
    A4_CONTENT="$(capture)"
    # Full-line response equality after an explicit, finite Claude decoration
    # set: substring containment is banned because the echoed user prompt itself
    # contains PONG and would satisfy it tautologically. Claude 2.1.251 renders
    # completed assistant output with `⏺`; older supported UIs use ●/•/*/│.
    if printf '%s\n' "$A4_CONTENT" | grep -qE '^[[:space:]│●•*⏺]*PONG[[:space:]]*$'; then
        A4_PONG=1
    fi
    if claude_session_ready_now; then
        A4_READY_AFTER=1
    else
        A4_READY_AFTER=0
    fi
    if [ "$A4_BOUND" = "true" ] && [ "$A4_ALIVE" = "true" ] \
        && [ "$A4_PONG" -eq 1 ] && [ "$A4_READY_AFTER" -eq 1 ]; then
        break
    fi
    sleep 3
done

if [ "$A4_SENT" -eq 1 ] && [ "$A4_BOUND" = "true" ] && [ "$A4_ALIVE" = "true" ] \
    && [ "$A4_PONG" -eq 1 ] && [ "$A4_READY_AFTER" -eq 1 ]; then
    A4_OK=1
    pass "A4 dispatch-bound/session-alive with PONG and live Claude ready for next input"
else
    A4_OK=0
    fail "A4 sent=$A4_SENT dispatch-bound='$A4_BOUND' session-alive='$A4_ALIVE' pong=$A4_PONG ready-after=$A4_READY_AFTER (expected all positive within 60s)"
    dump_pane "orch-check-worker.sh output" "$(bash "$CHECK_SCRIPT" "$TASK_ID" "$LIST_DIR" 2>&1 || true)"
    dump_pane "dispatch.md" "$(cat "$DISPATCH_FILE" 2>/dev/null)"
    dump_pane "pane content" "$(capture)"
fi

# ===========================================================================
# A5 — command-resolves (the namespaced /execute-task spelling the driver sends
#      actually resolves; consumes API quota: one more command into the SAME
#      already-launched session — no new claude process)
# ===========================================================================
echo
echo "=== A5: command-resolves (positive transcript evidence; CONSUMES API QUOTA) ==="

# Send the exact spelling the L2 orch-driver-agent sends — the namespaced
# `/zyz-worker:execute-task <task-id>` — into the SAME recorded pane that A2-A4
# used. Background: in current Claude Code the bare `/execute-task` does NOT
# resolve (plugin commands register namespaced-only AND `execute-task` also
# exists as a skill — name collision), so a worker fed the bare form dies at the
# very first hop with `Unknown command: /execute-task`. The namespaced form must
# resolve.
# The independent positive observation is transcript advancement from a
# quiescent post-PONG baseline. Pane substring containment is insufficient: the
# terminal echoes typed input even when zsh, rather than Claude, owns the pane.
A5_TRANSCRIPT="$(fm_field "$DISPATCH_FILE" transcript-path)"
A5_BEFORE_FP="$(file_fingerprint "$A5_TRANSCRIPT")"
A5_SENT=0
if [ "$A4_OK" -eq 1 ] && [ -n "$A5_TRANSCRIPT" ] && [ -n "$A5_BEFORE_FP" ] \
    && claude_session_ready_now; then
    info "sending '/zyz-worker:execute-task $TASK_ID' to verified live Claude child"
    tmux send-keys -t "$PANE_ID" "/zyz-worker:execute-task $TASK_ID" Enter
    A5_SENT=1
else
    info "refusing A5 command: no live-ready Claude or no quiescent transcript baseline"
fi

A5_UNKNOWN=0
A5_CHILD_LOST=0
A5_TRANSCRIPT_ADVANCED=0
A5_STABLE=0
A5_ADVANCED_AT=""
A5_DEADLINE=$(( $(date +%s) + 30 ))
while [ "$A5_SENT" -eq 1 ] && [ "$(date +%s)" -lt "$A5_DEADLINE" ]; do
    A5_CONTENT="$(capture)"
    if printf '%s\n' "$A5_CONTENT" | grep -qF "Unknown command"; then
        A5_UNKNOWN=1
        break
    fi
    if [ "$(claude_child_count)" != "1" ] || [ -z "$(claude_child_newest)" ]; then
        A5_CHILD_LOST=1
        break
    fi
    A5_AFTER_FP="$(file_fingerprint "$A5_TRANSCRIPT")"
    if [ -n "$A5_AFTER_FP" ] && [ "$A5_AFTER_FP" != "$A5_BEFORE_FP" ]; then
        A5_TRANSCRIPT_ADVANCED=1
        if [ -z "$A5_ADVANCED_AT" ]; then
            A5_ADVANCED_AT="$(date +%s)"
        fi
    fi
    # Do not succeed on the first transcript write: an immediate resolver
    # diagnostic may render just after that write. Keep observing the same
    # live child and pane for three seconds after positive transcript evidence.
    if [ "$A5_TRANSCRIPT_ADVANCED" -eq 1 ] \
        && [ $(( $(date +%s) - A5_ADVANCED_AT )) -ge 3 ]; then
        A5_STABLE=1
        break
    fi
    sleep 1
done

if [ "$A5_SENT" -eq 1 ] && [ "$A5_UNKNOWN" -eq 0 ] \
    && [ "$A5_CHILD_LOST" -eq 0 ] && [ "$A5_TRANSCRIPT_ADVANCED" -eq 1 ] \
    && [ "$A5_STABLE" -eq 1 ]; then
    pass "A5 '/zyz-worker:execute-task' handled by live Claude (transcript advanced; child stable; no Unknown command)"
else
    fail "A5 sent=$A5_SENT transcript-advanced=$A5_TRANSCRIPT_ADVANCED stable=$A5_STABLE unknown=$A5_UNKNOWN child-lost=$A5_CHILD_LOST — positive live-Claude command handling not proved"
    dump_pane "pane content at A5 failure" "$(capture)"
fi

# ===========================================================================
# 3. Output
# ===========================================================================
echo
echo "E2E RESULT: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
