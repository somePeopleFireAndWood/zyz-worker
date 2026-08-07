#!/usr/bin/env bash
#
# checkout-guard.sh — L6 shared-worktree revert guard (PreToolUse on Bash).
#
# ## Trigger point
#
# Registered in hooks/hooks.json for PreToolUse with matcher "^Bash$", sync
# (a deny decision requires sync).
#
# ## Why
#
# Real accident (issue #6): several subagents shared one git worktree; an audit
# agent reverted its throwaway mutation with `git checkout <file>` — which
# resets to HEAD — and deleted another agent's UNCOMMITTED work in the same
# file (~5000 chars of security-guard code). The damage class is uniquely
# nasty: never-committed content is in NO git recovery mechanism (no reflog,
# no stash, no fsck), and the build stayed green because the lost code hung
# off a runtime type-assertion seam. The only recovery was replaying the
# author agent's transcript.
#
# `git checkout/restore <path>` is the natural way to "undo my change", which
# is exactly why a prompt-level ban is not enough: the instruction "restore
# byte-identical" invites it. This hook makes the dangerous form mechanically
# fail with the safe alternative in the message.
#
# ## What is denied
#
# Only when the session has an active task pointer (same gate as every other
# layer — this protects multi-agent task work, not general git usage):
#
# - `git checkout`/`git restore` whose arguments name a file that currently
#   has UNCOMMITTED MODIFICATIONS (per `git status --porcelain`). Reverting a
#   clean file is a no-op and passes; switching branches passes (a branch name
#   is not a modified path); `git checkout -b ...` passes.
# - `git stash` in its state-moving forms (bare / push / save / pop / apply /
#   drop / clear). `git stash list` / `git stash show` pass (read-only).
#   This mechanizes the P2-20 prompt ban: a pop can land on the wrong state,
#   and another agent's stash may be present.
#
# The deny reason gives the safe recipe: cp-backup before mutating, mv back to
# restore; `git show HEAD:<file>` to only LOOK at the HEAD version;
# `git diff > /tmp/x.patch` + `git apply -R` for temporary set-asides.
#
# ## Inputs
#
# - stdin: hook JSON (cwd, tool_input.command).
# - env: ZYZ_HOOKS_DISABLE=1 disables the whole layer,
#        ZYZ_CHECKOUT_GUARD_DISABLE=1 just this guard (matching is heuristic
#        — shell cannot be parsed perfectly by shell — so an escape hatch is
#        mandatory, same policy as the L5 scope guard).
#
# ## Failure behavior
#
# Fail open: missing input/parser/pointer, git absent, or any internal error
# exits 0 (allow). A guard must never break the workflow it protects. The
# porcelain check anchors at the COMMAND's cwd, so files outside a repo simply
# never match.
#
# ## Supported agents
#
# All (main agent and every subagent) — the accident was a subagent's command.

set -u
[ "${ZYZ_HOOKS_DISABLE:-0}" = "1" ] && exit 0
[ "${ZYZ_CHECKOUT_GUARD_DISABLE:-0}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh" 2>/dev/null || exit 0

zyz_json_ok || exit 0
ZYZ_HOOK_INPUT="$(cat 2>/dev/null || true)"
[ -n "$ZYZ_HOOK_INPUT" ] || exit 0

base="$(zyz_get cwd)"
[ -n "$base" ] || base="${CLAUDE_PROJECT_DIR:-}"
[ -n "$base" ] || exit 0

# Same arming gate as every other layer: no active task, no guard. General
# (non-task) sessions keep full git freedom.
root="$(zyz_task_root "$base")"
[ -n "$root" ] || exit 0

cmd="$(zyz_get tool_input.command)"
[ -n "$cmd" ] || exit 0

# Cheap pre-filter before any parsing.
case "$cmd" in
    *git*) ;;
    *) exit 0 ;;
esac

command -v git >/dev/null 2>&1 || exit 0

SAFE_RECIPE="Safe alternatives: (1) to revert a THROWAWAY mutation, take a copy BEFORE mutating (cp <file> <file>.zyz-mut-bak), then restore with mv and verify with git diff/cmp; (2) to only READ the committed version, use git show HEAD:<file> — it does not touch the working tree; (3) for a temporary set-aside, git diff > /tmp/<name>.patch then git apply -R. If this deny is a false positive, set ZYZ_CHECKOUT_GUARD_DISABLE=1 for the single command and turn it back off."

# ---- git stash state-moving forms -------------------------------------------
# Normalize whitespace, then look for `git stash <sub>` where sub moves state.
# `git stash list|show` are read-only and pass.
if printf '%s' "$cmd" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+stash([[:space:]]+(push|save|pop|apply|drop|clear)|[[:space:]]*($|[;&|]))' 2>/dev/null; then
    if ! printf '%s' "$cmd" | grep -qE 'git[[:space:]]+stash[[:space:]]+(list|show)' 2>/dev/null; then
        zyz_emit_deny "PreToolUse" "[zyz-worker watchdog] git stash moves shared working-tree state and is banned on a shared worktree (another agent's stash may exist, and a pop can land on the wrong state — an uncommitted-work loss here is unrecoverable from git). ${SAFE_RECIPE}"
        exit 0
    fi
fi

# ---- git checkout / git restore of a MODIFIED path --------------------------
# Extract the argument region after the subcommand, then test each plausible
# path token against `git status --porcelain`. Heuristic by design:
# - tokens starting with `-` are options, skipped (this lets `-b <branch>`,
#   `--theirs`, etc. pass unless a real modified path is also named);
# - a branch name passes because it is not a modified path in porcelain;
# - `.` / `:/` (tree-wide) deny if ANY tracked modification exists anywhere.
_deny_target=""
_args="$(printf '%s' "$cmd" | sed -nE 's/.*git[[:space:]]+(checkout|restore)[[:space:]]+(.*)$/\2/p' | head -n1)"
if [ -n "$_args" ]; then
    # Cut at the first shell metacharacter so we do not read into a following
    # command (git checkout f.go && make -> only "f.go").
    _args="$(printf '%s' "$_args" | sed -E 's/[;&|<>].*$//')"
    for tok in $_args; do
        case "$tok" in
            -*) continue ;;                       # options (incl. -b/--source)
            HEAD|HEAD~*|HEAD^*|main|master) continue ;;  # common ref spellings
        esac
        # strip simple quoting
        tok="${tok%\'}"; tok="${tok#\'}"; tok="${tok%\"}"; tok="${tok#\"}"
        [ -n "$tok" ] || continue
        if [ "$tok" = "." ] || [ "$tok" = ":/" ]; then
            if [ -n "$(git -C "$base" status --porcelain 2>/dev/null | grep -E '^.M|^M' 2>/dev/null)" ]; then
                _deny_target="$tok (tree-wide, with uncommitted modifications present)"
                break
            fi
            continue
        fi
        # Only tokens that are actual modified paths deny. status --porcelain
        # prints nothing for clean/unknown paths and for branch names.
        _st="$(git -C "$base" status --porcelain -- "$tok" 2>/dev/null | head -n1)"
        case "$_st" in
            "") continue ;;                        # clean or not a path
            \?\?*) continue ;;                     # untracked: checkout won't touch it
            *)
                _deny_target="$tok"
                break
                ;;
        esac
    done
fi

if [ -n "$_deny_target" ]; then
    zyz_emit_deny "PreToolUse" "[zyz-worker watchdog] This git checkout/restore would reset '${_deny_target}' to HEAD, and that file has UNCOMMITTED changes in the shared worktree — possibly another agent's in-flight work. Never-committed content is in NO git recovery mechanism (no reflog, no stash, no fsck); a real incident lost ~5000 chars of security-guard code this way while the build stayed green. ${SAFE_RECIPE}"
    exit 0
fi

exit 0
