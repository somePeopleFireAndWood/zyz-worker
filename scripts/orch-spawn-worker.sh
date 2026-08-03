#!/usr/bin/env bash
#
# orch-spawn-worker.sh — create the worktree + tmux session + in-pane heartbeat
# daemon for a single task, and write the Phase-1 dispatch.md. That is ALL it
# does: it builds the container. It NEVER starts claude. Starting the worker
# (claude + /execute-task, with confirmation-page handling and readiness
# probing) is the exclusive job of the L2 driver subagent.
#
# Contract:
#   Inputs:
#     $1  <task-id>               must match [A-Za-z0-9_-]+
#     $2  <list-dir>              master list directory
#
#   Side effects:
#     - Reads <list-dir>/tasks/<task-id>.md frontmatter.
#     - Creates <list-dir>/runtime/<task-id>/.
#     - Writes the INITIAL <list-dir>/runtime/<task-id>/worker-status.md
#       (phase=design). After this preflight write the file is owned
#       exclusively by L3 (the worker); spawn never rewrites it.
#     - `git worktree add <worktree> -b <branch> <base>` (creates the branch).
#     - `tmux new-session -d -s <tmux-session> -c <worktree>` (creates the session).
#     - Sends an in-pane background command to start the heartbeat daemon.
#     - Sends env-var exports into the pane.
#     - Writes <list-dir>/runtime/<task-id>/dispatch.md (Phase-1).
#     Does NOT start claude (that is the L2 driver subagent's job).
#
#   Output (stdout):
#     session-name=<tmux-session>
#     worktree=<worktree>
#     source-repo=<expanded-absolute-path>
#
#   Exit codes:
#     0  success
#     2  argument error / invalid task-id
#     3  missing dependency (tmux / git)
#     4  <list-dir>/tasks/<task-id>.md missing or unreadable
#     5  worktree path conflict OR runtime dir conflict OR source-repo
#        missing / non-absolute / non-existent / not a git work tree
#     6  tmux session name conflict
#     7  `git worktree add` failed
#
#   Exit-code precedence (evaluated in this order):
#     2  argv shape / task-id charset
#     4  master entry file missing
#     5  source-repo missing / invalid (validated before tmux/git)
#     3  tmux / git not on PATH
#     5/6/7  remaining collision / git-worktree-add checks
#
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <task-id> <list-dir>" >&2
}

if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi

TASK_ID="$1"
LIST_DIR="$2"

# task-id whitelist.
case "$TASK_ID" in
    ''|*[!A-Za-z0-9_-]*)
        echo "error: invalid task-id (must match [A-Za-z0-9_-]+): '$TASK_ID'" >&2
        exit 2
        ;;
esac

if [ -z "$LIST_DIR" ]; then
    usage
    exit 2
fi

MASTER_ENTRY="$LIST_DIR/tasks/$TASK_ID.md"
if [ ! -f "$MASTER_ENTRY" ] || [ ! -r "$MASTER_ENTRY" ]; then
    echo "error: master entry not found or unreadable: $MASTER_ENTRY" >&2
    exit 4
fi

# Frontmatter field extractor (same logic as the other helpers).
fm_field() {
    local file="$1"
    local key="$2"
    # Guard an absent/unreadable file: awk would exit non-zero and, under
    # `set -e`, kill the caller. Callers treat a missing field as empty.
    [ -f "$file" ] && [ -r "$file" ] || { printf ''; return 0; }
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
                sub(/[[:space:]]+#.*$/, "", v)
                if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2) }
                else if (v ~ /^'\''.*'\''$/) { v = substr(v, 2, length(v) - 2) }
                print v
                exit
            }
        }
    ' "$file"
}

# source-repo validation. Runs BEFORE the tmux/git dependency check so that
# the negative spawn cases (T4' in scripts/test-orchestration-helpers.sh)
# fire even on hosts without tmux. The order matters: argv (2) → master
# entry missing (4) → source-repo invalid (5) → tmux/git missing (3) →
# rest.
# --- Repo discovery (D2). Multi-repo tasks declare additional repos via the
# numbered flat keys source-repo-2, source-repo-3, ... (numbering MUST start at
# 2 and be contiguous). The primary (repo 1) is the unnumbered `source-repo:`.
# Read raw declared values until the first empty key; REPO_COUNT is the count.
# A single-repo entry (only `source-repo:`) yields REPO_COUNT=1 and walks the
# exact legacy code path below (byte-identical diagnostics — T4' depends on it).
declare -a RAW_SOURCE_REPOS
i=1
while :; do
    if [ "$i" -ge 2 ]; then rkey="source-repo-$i"; else rkey="source-repo"; fi
    rval="$(fm_field "$MASTER_ENTRY" "$rkey")"
    [ -n "$rval" ] || break
    RAW_SOURCE_REPOS[$i]="$rval"
    i=$((i + 1))
done
REPO_COUNT=$((i - 1))

# Primary source-repo is mandatory. Message kept byte-identical to the legacy
# single-repo path.
if [ "$REPO_COUNT" -lt 1 ]; then
    echo "error: master entry has no source-repo field: $MASTER_ENTRY" >&2
    exit 5
fi

# Numbering-gap detection: the discovery loop stops at the first empty key, so a
# hole (e.g. source-repo-3 present but source-repo-2 absent) would silently drop
# the higher repos. Probe indices past REPO_COUNT (up to 9); any populated higher
# key means the numbering is not contiguous → exit 5 naming the gap.
gap_probe=$((REPO_COUNT + 1))
while [ "$gap_probe" -le 9 ]; do
    if [ -n "$(fm_field "$MASTER_ENTRY" "source-repo-$gap_probe")" ]; then
        echo "error: source-repo numbering gap: source-repo-$((REPO_COUNT + 1)) is missing but source-repo-$gap_probe is present" >&2
        exit 5
    fi
    gap_probe=$((gap_probe + 1))
done

# --- Per-repo validation (D4-1). Run the existing four checks (non-empty /
# absolute-or-~ / exists / is-git-work-tree) for every repo. For a single-repo
# entry the diagnostics are byte-identical to the legacy path (pfx empty); for
# repo N>=2 each message carries a `repo <N> (<path>)` prefix.
declare -a SOURCE_REPOS
n=1
while [ "$n" -le "$REPO_COUNT" ]; do
    sr="${RAW_SOURCE_REPOS[$n]}"
    if [ "$n" -ge 2 ]; then pfx="repo $n ($sr): "; else pfx=""; fi
    # Expand a leading `~/` if present (bash does not expand ~ inside a
    # variable). The `~/` pattern MUST be quoted inside ${…#PAT} — otherwise
    # bash treats the leading `~` as the tilde-expansion metachar and the
    # strip silently becomes a no-op, leaving e.g. `$HOME/~/workspace/...`
    # which then fails the path-existence check below.
    case "$sr" in
        "~/"*) sr="$HOME/${sr#"~/"}" ;;
    esac
    # After expansion, the path must be absolute. Reject everything that is
    # neither `/...` nor a `~/...` that just got expanded. (`~` alone with no
    # trailing `/` also lands here — see §Important Details > Quoting and `~`.)
    case "$sr" in
        /*) : ;;
        *)
            echo "error: ${pfx}source-repo must be an absolute path or start with ~/: $sr" >&2
            exit 5
            ;;
    esac
    if [ ! -e "$sr" ]; then
        echo "error: ${pfx}source-repo path does not exist: $sr" >&2
        exit 5
    fi
    if ! git -C "$sr" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "error: ${pfx}source-repo is not a git work tree: $sr" >&2
        exit 5
    fi
    SOURCE_REPOS[$n]="$sr"
    n=$((n + 1))
done

# Primary repo scalar (repo 1). Downstream single-repo write paths and the
# dispatch.md/stdout primary fields use this byte-identically.
SOURCE_REPO="${SOURCE_REPOS[1]}"

# Dependencies. Checked AFTER source-repo so the source-repo negative
# tests fire even when tmux is absent. (Note: the source-repo git
# rev-parse above requires `git`; if `git` is missing it will fall
# through to the rev-parse failure branch above and exit 5 with the
# "not a git work tree" message — that is acceptable because no host
# realistically has `git` missing.)
for dep in tmux git; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "error: missing dependency: $dep" >&2
        exit 3
    fi
done

# Resolve where this script lives, so we can address sibling helpers by
# absolute path even when the user invokes us from a different cwd. Hoisted
# above PLUGIN_ROOT (which derives from $SCRIPT_DIR/..) and the dispatch.md
# Phase-1 write.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the plugin root (hoisted to top-level so the dispatch.md Phase-1
# write can record it in the `plugin-root:` field — the L2 driver reads that
# field to launch `claude --plugin-dir <plugin-root>`). The warn-only sanity
# check fires on every spawn — a missing skills/execute-task directory is a
# misconfiguration regardless of how the worker is started. We only warn (not
# exit) because a heterogenous install layout could legitimately put skills
# elsewhere.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
if [ ! -d "$PLUGIN_ROOT/skills/execute-task" ]; then
    echo "warn: PLUGIN_ROOT=$PLUGIN_ROOT does not contain skills/execute-task" >&2
fi

# Read frontmatter; apply defaults.
PROJECT="$(fm_field "$MASTER_ENTRY" project)"
PROJECT="${PROJECT:-$(basename "$SOURCE_REPO")}"

# Repo-1 branch/base resolution (unchanged single-repo semantics). These also
# serve as the default-inheritance source for repos N>=2: branch-N defaults to
# the RESOLVED value of branch, base-N to the RESOLVED value of base.
BRANCH="$(fm_field "$MASTER_ENTRY" branch)"
[ -z "$BRANCH" ] && BRANCH="task/$TASK_ID"

BASE="$(fm_field "$MASTER_ENTRY" base)"
[ -z "$BASE" ] && BASE="main"

# Per-repo branch / base / worktree resolution (D4-2, layout D3).
#
# Worktree default layout:
#   single-repo (REPO_COUNT==1): ~/.zyz-worker/worktrees/<project>/<branch>
#       (byte-identical to legacy).
#   multi-repo  (REPO_COUNT>=2): every repo — including the primary — nests under
#       the shared task dir as siblings:
#       ~/.zyz-worker/worktrees/<primary-project>/task/<task-id>/<repo-basename>
#
# The resolved values are the authoritative concrete values written into
# dispatch.md (02-D0): downstream merge/cleanup read them, so branch-N/base-N/
# worktree-N are never left empty.
declare -a BRANCHES BASES WORKTREES
n=1
while [ "$n" -le "$REPO_COUNT" ]; do
    sr="${SOURCE_REPOS[$n]}"
    if [ "$n" -ge 2 ]; then
        bkey="branch-$n"; basekey="base-$n"; wkey="worktree-$n"
    else
        bkey="branch"; basekey="base"; wkey="worktree"
    fi

    # branch-N defaults to the resolved repo-1 branch; base-N to resolved base.
    br="$(fm_field "$MASTER_ENTRY" "$bkey")"
    [ -z "$br" ] && br="$BRANCH"
    ba="$(fm_field "$MASTER_ENTRY" "$basekey")"
    [ -z "$ba" ] && ba="$BASE"

    # worktree-N default layout depends on REPO_COUNT (see above).
    wt="$(fm_field "$MASTER_ENTRY" "$wkey")"
    if [ -z "$wt" ]; then
        if [ "$REPO_COUNT" -ge 2 ]; then
            wt="$HOME/.zyz-worker/worktrees/$PROJECT/task/$TASK_ID/$(basename "$sr")"
        else
            wt="$HOME/.zyz-worker/worktrees/$PROJECT/$BRANCH"
        fi
    fi
    # Expand a leading `~/` if present. Quote the pattern — see the
    # source-repo expansion above for why the bare `~/` form is a no-op.
    case "$wt" in
        "~/"*) wt="$HOME/${wt#"~/"}" ;;
    esac

    BRANCHES[$n]="$br"
    BASES[$n]="$ba"
    WORKTREES[$n]="$wt"
    n=$((n + 1))
done

# Repo-1 scalars (byte-compat with the legacy single-repo write/stdout paths).
BRANCH="${BRANCHES[1]}"
BASE="${BASES[1]}"
WORKTREE="${WORKTREES[1]}"

TMUX_SESSION="$(fm_field "$MASTER_ENTRY" tmux-session)"
[ -z "$TMUX_SESSION" ] && TMUX_SESSION="zyz-task-$TASK_ID"

# Runtime files.
RUNTIME_DIR="$LIST_DIR/runtime/$TASK_ID"
WORKER_STATUS_FILE="$RUNTIME_DIR/worker-status.md"
HEARTBEAT_FILE="$RUNTIME_DIR/heartbeat"
QUESTION_FILE="$RUNTIME_DIR/question.md"
ANSWER_FILE="$RUNTIME_DIR/answer.md"

# Step 3: cross-list / cross-source collision checks.
# - tmux session must not exist
# - worktree path must not exist
# - runtime dir must not exist
# - any other list's runtime/<task-id>/ must not exist (cross-list collision)

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "error: tmux session already exists: $TMUX_SESSION" >&2
    exit 6
fi

# Per-repo worktree-existence check (loop). Single-repo message byte-identical.
n=1
while [ "$n" -le "$REPO_COUNT" ]; do
    if [ -e "${WORKTREES[$n]}" ]; then
        echo "error: worktree path already exists: ${WORKTREES[$n]}" >&2
        exit 5
    fi
    n=$((n + 1))
done

# NEW pairwise-distinctness check (D4-3b, review finding 6): no two resolved
# worktree paths may be equal. Two source-repos with the same basename resolve
# to the same default nested path; the existence check above passes for both
# (nothing created yet) and only the SECOND `git worktree add` would fail (as
# exit 7, not the intended exit 5). This runs before any creation so the
# collision surfaces as exit 5, naming the colliding repos.
if [ "$REPO_COUNT" -ge 2 ]; then
    a=1
    while [ "$a" -le "$REPO_COUNT" ]; do
        b=$((a + 1))
        while [ "$b" -le "$REPO_COUNT" ]; do
            if [ "${WORKTREES[$a]}" = "${WORKTREES[$b]}" ]; then
                echo "error: worktree path collision between repo $a and repo $b: ${WORKTREES[$a]} (give an explicit worktree-$b:)" >&2
                exit 5
            fi
            b=$((b + 1))
        done
        a=$((a + 1))
    done
fi

# NEW no-colon check (D4-3c, review finding 7): ZYZ_WORKTREES / the reuse-config
# `worktrees:` line use ':' as the path separator, so no worktree path may
# contain a colon. The default sibling layout never contains one; this guards
# user-supplied worktree-N: overrides.
#
# The same loop also rejects a single quote. Every `tmux send-keys` payload below
# wraps these values in single quotes ("... '$WORKTREE' ..."), so a `'` in the
# value closes the quote and the remainder is interpreted as shell by the pane.
# The value is user-written (their own master entry), so this is robustness, not
# a privilege boundary — but orch-build-env.sh already rejects `'` in
# ZYZ_GO_TMPFS_DIR for exactly this reason, so spawn matches that guard.
n=1
while [ "$n" -le "$REPO_COUNT" ]; do
    if [ "$n" -ge 2 ]; then wpfx="repo $n "; else wpfx=""; fi
    case "${WORKTREES[$n]}" in
        *:*)
            echo "error: ${wpfx}worktree path must not contain ':': ${WORKTREES[$n]}" >&2
            exit 5
            ;;
    esac
    case "${WORKTREES[$n]}" in
        *\'*)
            echo "error: ${wpfx}worktree path must not contain a single quote: ${WORKTREES[$n]}" >&2
            exit 5
            ;;
    esac
    case "${BRANCHES[$n]}" in
        *\'*)
            echo "error: ${wpfx}branch must not contain a single quote: ${BRANCHES[$n]}" >&2
            exit 5
            ;;
    esac
    n=$((n + 1))
done

if [ -e "$RUNTIME_DIR" ]; then
    echo "error: runtime dir already exists: $RUNTIME_DIR" >&2
    exit 5
fi

# Cross-list collision check: scan sibling directories of <list-dir> for any
# orchestration dir that already has runtime/<task-id>/.
LIST_PARENT="$(cd "$LIST_DIR/.." 2>/dev/null && pwd || true)"
LIST_BASE="$(basename "$LIST_DIR")"
if [ -n "$LIST_PARENT" ] && [ -d "$LIST_PARENT" ]; then
    for other in "$LIST_PARENT"/*/; do
        [ -d "$other" ] || continue
        other_base="$(basename "$other")"
        [ "$other_base" = "$LIST_BASE" ] && continue
        if [ -e "${other}runtime/$TASK_ID" ]; then
            echo "error: task-id collision in another list: ${other}runtime/$TASK_ID" >&2
            exit 5
        fi
    done
fi

# Step 4: create the worktrees (one per repo, in ascending N).
#
# Partial-failure rollback: if repo k fails, reverse-order
# `git worktree remove --force` the worktrees already created for repos 1..k-1
# (their newly-created branches are intentionally NOT deleted — a stray branch
# is harmless and deleting one risks clobbering a pre-existing branch), then
# exit 7. Preserves the "exit 7 = container not built" semantics.
#
# Single-repo: this loop runs exactly once and the failure diagnostic is
# byte-identical to the legacy path (kfx empty for repo 1).
n=1
while [ "$n" -le "$REPO_COUNT" ]; do
    sr="${SOURCE_REPOS[$n]}"
    wt="${WORKTREES[$n]}"
    br="${BRANCHES[$n]}"
    ba="${BASES[$n]}"
    mkdir -p "$(dirname "$wt")"
    if ! git -C "$sr" worktree add "$wt" -b "$br" "$ba" >/dev/null 2>&1; then
        # Try again without -b (branch may already exist locally).
        if ! git -C "$sr" worktree add "$wt" "$br" >/dev/null 2>&1; then
            if [ "$n" -ge 2 ]; then kfx="repo $n "; else kfx=""; fi
            # Roll back worktrees already created for repos 1..n-1 (reverse order).
            rolled=""
            k=$((n - 1))
            while [ "$k" -ge 1 ]; do
                if git -C "${SOURCE_REPOS[$k]}" worktree remove --force "${WORKTREES[$k]}" >/dev/null 2>&1; then
                    rolled="repo $k (${WORKTREES[$k]})${rolled:+, }$rolled"
                fi
                k=$((k - 1))
            done
            if [ -n "$rolled" ]; then
                echo "error: ${kfx}git worktree add failed (branch=$br base=$ba target=$wt); rolled back: $rolled" >&2
            else
                echo "error: ${kfx}git worktree add failed (branch=$br base=$ba target=$wt)" >&2
            fi
            exit 7
        fi
    fi
    n=$((n + 1))
done

# Step 5: create the runtime dir.
mkdir -p "$RUNTIME_DIR"

# Step 6: write initial worker-status.md (atomic).
NOW_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"
TMP_STATUS="$WORKER_STATUS_FILE.tmp.$$"
cat > "$TMP_STATUS" <<EOF
---
task-id: $TASK_ID
phase: design
phase-since: $NOW_ISO
wait-state: none
waiting-reason:
expected-resume-by:
last-flush: $NOW_ISO
---

# Worker Status

## Current Activity

(initialized by orchestrator; awaiting worker start)

## Last Output Summary

(none yet)

## Next Action

Start the worker: attach to tmux session $TMUX_SESSION, then run claude + /execute-task.
EOF
mv -f "$TMP_STATUS" "$WORKER_STATUS_FILE"

# Step 7: create the tmux session (detached). This MUST come before launching
# the heartbeat daemon — the daemon must live inside the pane's process group
# so the pane's death sends SIGHUP and tears the daemon down.
if ! tmux new-session -d -s "$TMUX_SESSION" -c "$WORKTREE" 2>/dev/null; then
    echo "error: failed to create tmux session: $TMUX_SESSION" >&2
    exit 6
fi

# SCRIPT_DIR was resolved earlier (above the PLUGIN_ROOT hoist). Address the
# sibling heartbeat daemon by absolute path even when the user invokes us
# from a different cwd.
DAEMON_SCRIPT="$SCRIPT_DIR/orch-heartbeat-daemon.sh"

# Step 8: start the heartbeat daemon INSIDE the tmux pane via `send-keys`.
# `... &` puts it in the background of the pane's shell.
#
# Critical: do NOT wrap the daemon in `nohup` — `nohup` makes the daemon
# immune to SIGHUP, which is exactly the signal we want to propagate when
# the pane / session dies. On macOS bash, `shopt -s huponexit` is off by
# default so background children may not receive SIGHUP from the shell on
# exit either; therefore the daemon ALSO actively watchdogs the tmux
# session via `tmux has-session` (see orch-heartbeat-daemon.sh). We pass
# the session name through the `ZYZ_TMUX_SESSION` env var.
tmux send-keys -t "$TMUX_SESSION" \
    "ZYZ_TMUX_SESSION='$TMUX_SESSION' '$DAEMON_SCRIPT' '$HEARTBEAT_FILE' 30 >/dev/null 2>&1 &" Enter

# Step 9: export env vars into the pane so the worker (claude + execute-task)
# sees them when started.
tmux send-keys -t "$TMUX_SESSION" \
    "export ZYZ_WORKER_STATUS_FILE='$WORKER_STATUS_FILE' ZYZ_TASK_ID='$TASK_ID' ZYZ_QUESTION_FILE='$QUESTION_FILE' ZYZ_ANSWER_FILE='$ANSWER_FILE' ZYZ_HEARTBEAT_FILE='$HEARTBEAT_FILE'" \
    Enter

# Step 9a: multi-repo only — export ZYZ_WORKTREES (colon-separated, primary
# first) so the worker (claude + execute-task) knows it owns N worktrees and has
# full write access to each. Single-repo does NOT export this: its absence means
# single-worktree legacy behavior (D4-6, D6). Injected the same way as the
# other env above.
if [ "$REPO_COUNT" -ge 2 ]; then
    ZYZ_WT_LIST=""
    n=1
    while [ "$n" -le "$REPO_COUNT" ]; do
        ZYZ_WT_LIST="${ZYZ_WT_LIST:+$ZYZ_WT_LIST:}${WORKTREES[$n]}"
        n=$((n + 1))
    done
    tmux send-keys -t "$TMUX_SESSION" \
        "export ZYZ_WORKTREES='$ZYZ_WT_LIST'" \
        Enter
fi

# Step 9b: inject Go build I/O optimization (GOTMPDIR tmpfs + GOFLAGS=-p=N) into
# the pane BEFORE the L2 driver starts claude, so claude's `go build` children
# inherit it. orch-build-env.sh bakes the candidate values and the snippet's own
# in-pane guards handle no-clobber + auto-degrade. Non-blocking: if the helper is
# missing or errors, BUILD_ENV_LINE is empty and we simply skip injection.
BUILD_ENV_LINE="$("$SCRIPT_DIR/orch-build-env.sh" 2>/dev/null || true)"
if [ -n "$BUILD_ENV_LINE" ]; then
    tmux send-keys -t "$TMUX_SESSION" "$BUILD_ENV_LINE" Enter
fi

# Step 10: write the Phase-1 dispatch.md (atomic). This is the LAST step —
# dispatch.md presence reliably means "spawn ran preflight to completion". The
# check helper (orch-check-worker.sh) lazily fills the Phase-2 fields on later
# polls once the L2 driver has started claude inside the pane.
#
# tmux-window-id / tmux-pane-id / shell-pid are read back from the session we
# created seconds ago (Step 7). It has exactly one window with one pane, so
# `head -1` is correct. set -e is in effect: if list-panes returned no rows
# the spawn fails fast (the session vanishing microseconds after creation is
# not recoverable).
#
# encoded-cwd is computed from the PHYSICAL path (`pwd -P`) of the worktree,
# NOT the raw $WORKTREE: claude records the cwd it actually entered, and on
# macOS standard temp dirs (/var/folders/...) are symlinks to /private/var/...
# Using the symlinked form would make any path derived from it diverge.
# encoded-cwd matches Claude Code's ~/.claude/projects/<dir> naming: physical
# path with both `/` and `.` replaced by `-`, then consecutive `-` squeezed.
# NOTE: orch-check-worker.sh discovers the transcript by session-id, not by this
# field — it is kept for diagnostics and the recovery command path.
DISPATCH_FILE="$RUNTIME_DIR/dispatch.md"
TMUX_PANE_INFO="$(tmux list-panes -t "$TMUX_SESSION" -F '#{window_id} #{pane_id} #{pane_pid}' | head -1)"
TMUX_WINDOW_ID="$(echo "$TMUX_PANE_INFO" | awk '{print $1}')"
TMUX_PANE_ID="$(echo "$TMUX_PANE_INFO" | awk '{print $2}')"
SHELL_PID="$(echo "$TMUX_PANE_INFO" | awk '{print $3}')"
WORKTREE_PHYS="$(cd "$WORKTREE" && pwd -P)"
ENCODED_CWD="$(echo "$WORKTREE_PHYS" | tr '/.' '--' | tr -s '-')"

# Multi-repo numbered field group (D4-7). Accumulated into a single variable
# BEFORE the heredoc so it can be expanded inline (the heredoc cannot loop).
# For N=2..REPO_COUNT, in ascending N and this exact per-repo order:
#   worktree-N: / source-repo-N: / branch-N: / base-N:
# Values are the RESOLVED concrete values (never empty) — 02-D0 relies on this.
# The variable carries a LEADING newline (so it splices directly after the
# `base:` scalar) and NO trailing newline. Single-repo: it stays empty, so the
# `base: $BASE$NUMBERED_FIELDS` line renders byte-identically to the legacy
# layout (`base: <value>` with the next line being `plugin-root:`).
NUMBERED_FIELDS=""
if [ "$REPO_COUNT" -ge 2 ]; then
    n=2
    while [ "$n" -le "$REPO_COUNT" ]; do
        NUMBERED_FIELDS="${NUMBERED_FIELDS}
worktree-$n: ${WORKTREES[$n]}
source-repo-$n: ${SOURCE_REPOS[$n]}
branch-$n: ${BRANCHES[$n]}
base-$n: ${BASES[$n]}"
        n=$((n + 1))
    done
fi

TMP_DISPATCH="$DISPATCH_FILE.tmp.$$"
# MCP inheritance policy snapshot (issue #2). Evaluated ONCE here at container
# build time via orch-worker-mcp-args.sh (reads ZYZ_WORKER_MCP; default `none`
# => `--strict-mcp-config` => worker gets ZERO MCP servers). Persisted into
# dispatch.md so the L2 driver's launch command and the crash-recovery
# `claude --resume` command use the SAME args — a resume that silently
# re-inherited the host's full mcpServers would re-pay the per-worker MCP
# baseline the policy exists to eliminate (~745 MB/worker measured).
# Fail CLOSED, not open: an empty value renders as `inherit`, so a missing or
# non-executable helper would silently restore the very full-MCP inheritance
# this feature removes — and nothing downstream could tell that apart from a
# deliberate `inherit`. Degrade to the safe default (`--strict-mcp-config`,
# zero MCP) and warn, matching the helper's own invalid-path behavior.
if ! WORKER_MCP_ARGS="$("$SCRIPT_DIR/orch-worker-mcp-args.sh" 2>/dev/null)"; then
    echo "warning: orch-worker-mcp-args.sh missing or failed; defaulting to --strict-mcp-config (zero MCP). Set ZYZ_WORKER_MCP=inherit explicitly if the worker needs the host's MCP servers." >&2
    WORKER_MCP_ARGS="--strict-mcp-config"
fi
cat > "$TMP_DISPATCH" <<EOF
---
task-id: $TASK_ID
spawn-iso: $NOW_ISO
tmux-session: $TMUX_SESSION
tmux-window-id: $TMUX_WINDOW_ID
tmux-pane-id: $TMUX_PANE_ID
shell-pid: $SHELL_PID
worktree: $WORKTREE
source-repo: $SOURCE_REPO
branch: $BRANCH
base: $BASE$NUMBERED_FIELDS
plugin-root: $PLUGIN_ROOT
encoded-cwd: $ENCODED_CWD
worker-mcp-args: $WORKER_MCP_ARGS
reuse-from:
reuse-scope:
reuse-claude-effective:
heartbeat-window-id:
claude-pid:
claude-session-id:
transcript-path:
first-seen-iso:
---

# Dispatch Info

## Recovery

(awaiting claude startup; orch-check-worker.sh populates this on the first poll where claude has registered AND first LLM round-trip has produced a transcript)
EOF
mv -f "$TMP_DISPATCH" "$DISPATCH_FILE"

# Step 11: stdout report. spawn never starts claude — that is the L2 driver's
# job. spawn's job ends here, with the container built and dispatch.md written.
# Single-repo output is byte-identical (session-name= / worktree= / source-repo=
# = primary). Multi-repo appends worktree-N= / source-repo-N= for N=2..REPO_COUNT
# and repo-count=<N> (repo-count is emitted ONLY for multi-repo, so existing
# single-repo line-set assertions are not broken).
printf 'session-name=%s\n' "$TMUX_SESSION"
printf 'worktree=%s\n' "$WORKTREE"
printf 'source-repo=%s\n' "$SOURCE_REPO"
if [ "$REPO_COUNT" -ge 2 ]; then
    n=2
    while [ "$n" -le "$REPO_COUNT" ]; do
        printf 'worktree-%s=%s\n' "$n" "${WORKTREES[$n]}"
        printf 'source-repo-%s=%s\n' "$n" "${SOURCE_REPOS[$n]}"
        n=$((n + 1))
    done
    printf 'repo-count=%s\n' "$REPO_COUNT"
fi

exit 0
