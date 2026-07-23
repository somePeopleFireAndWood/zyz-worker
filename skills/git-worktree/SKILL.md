---
name: git-worktree
description: Use when the user or another agent needs to run `git worktree add` (create), list, move, remove, lock, unlock, prune, or repair a git worktree. Provides a default target path `~/.zyz-worker/worktrees/${repo}/${branch}` when `git worktree add` is called without an explicit target.
---

# Git Worktree

## When to use this skill

Load this skill whenever the current conversation needs to create, inspect, move, delete, lock, unlock, prune, or repair a git worktree. Typical triggers include the user (or a parent agent) saying things like "open a worktree for branch X", "create a worktree", "list worktrees", "remove the worktree at …", or otherwise referencing `git worktree` sub-commands.

The skill is also the right entry point when an agent needs a stable, conventional location for a freshly created worktree instead of inventing an ad-hoc path next to the repository or under `/tmp`.

## Default location for `git worktree add`

When the user does not explicitly specify a target path for `git worktree add`, derive the target as:

```text
~/.zyz-worker/worktrees/${PROJECT}/${BRANCH}
```

Where:

- `PROJECT = basename "$(git rev-parse --show-toplevel)"` — used verbatim. Do not strip a `.git` suffix; do not sanitize. A repository whose root directory is literally `cool.git` produces the project name `cool.git`.
- `BRANCH` is the branch name as given by the user or chosen by the agent, used verbatim. If the branch name contains `/` (for example `feature/foo`), it naturally forms a multi-level subdirectory: `~/.zyz-worker/worktrees/${PROJECT}/feature/foo`. Do not replace `/` with another character.
- `$HOME` is resolved by the shell. Do not hard-code an absolute home path.

When the user has explicitly given a target path, use that path verbatim — do not silently rewrite it into the default location.

Whether the target comes from the default rule or from the user, always create the parent directory with `mkdir -p "$(dirname "$TARGET")"` before calling `git worktree add`. `mkdir -p` is a no-op when the directory already exists, and `git worktree add` itself still requires `$TARGET` not to exist, so this does not risk overwriting an existing worktree.

## Sub-commands

### add

Procedure for `git worktree add`:

1. Resolve the repository root and project name. If the user already provided an explicit target path, skip the default-path derivation but still keep the conflict pre-checks and the `mkdir -p` step below. If no target was provided, derive `$TARGET` from the default rule.
2. Run the two lightweight pre-checks below (`test -e` and a `grep -Fxq` match against `git worktree list --porcelain`). If either pre-check fires, stop and surface a concrete next step (change the path, run `git worktree remove "$TARGET"`, or pass `--force`); do not let the user read a raw git error.
3. Create the parent directory with `mkdir -p "$(dirname "$TARGET")"` — applied to both the default path and a user-supplied path.
4. Run `git worktree add "$TARGET" "$BRANCH"`. If the branch does not yet exist, the agent decides whether to add `-b <branch>` (create a new branch) or use `--detach` (detached HEAD) based on the user's intent.
5. After a successful `add`, output `$TARGET` so the calling agent can `cd` into it if needed. Do not automatically `cd` into the new worktree.

Pseudocode (POSIX shell):

```bash
# Only derive $TARGET this way if the user did not specify a target.
REPO_ROOT="$(git rev-parse --show-toplevel)" \
  || { echo "not in a git worktree (or in a bare repo)"; exit 1; }
PROJECT="$(basename "$REPO_ROOT")"
BRANCH="<branch name given by the user or chosen by the agent>"
TARGET="$HOME/.zyz-worker/worktrees/$PROJECT/$BRANCH"

# Normalize: resolve $TARGET to an absolute path before pre-checks so relative
# paths, `~`, or `./..` cannot slip past the duplicate check. If the parent
# directory does not yet exist (common on the first default-path `add`), keep
# $TARGET as-is — the later `mkdir -p` will create the directory tree and the
# pre-checks below still operate on the unnormalized value.
PARENT_DIR="$(dirname "$TARGET")"
if [ -d "$PARENT_DIR" ]; then
  TARGET="$(cd "$PARENT_DIR" && pwd)/$(basename "$TARGET")"
fi

# Pre-check 1: any existing file/dir at $TARGET is a conflict.
test -e "$TARGET" && { echo "target exists: $TARGET"; exit 1; }

# Pre-check 2: exact whole-line match against existing registered worktrees.
git worktree list --porcelain | awk '/^worktree /{print $2}' \
  | grep -Fxq "$TARGET" && { echo "already registered: $TARGET"; exit 1; }

# Ensure the parent directory exists (no-op if already present; runs for both
# the default path and any user-supplied path).
mkdir -p "$(dirname "$TARGET")"

git worktree add "$TARGET" "$BRANCH"
```

Key invariants:

- `$BRANCH` is embedded into the path verbatim; a `/` inside the branch becomes a directory separator, and `mkdir -p` creates the intermediate directories.
- Do not replace `/`, do not strip a `refs/heads/` prefix — the input is a branch name, not a ref.
- `$HOME` is resolved by the shell; never hard-code an absolute home path inside this skill.
- The duplicate-detection step normalizes `$TARGET` to an absolute path first (only when the parent directory already exists; otherwise the unnormalized value is used), then performs an exact whole-line `grep -Fxq` against the output of `git worktree list --porcelain | awk '/^worktree /{print $2}'`.
- When `git rev-parse --show-toplevel` exits non-zero (not in a git worktree, or in a bare repo), abort immediately. Do not fall back to `pwd` or feed an empty string into `basename`; the `||` guard above prevents that.
- `PROJECT` is the literal `basename` result, used verbatim. No `.git` suffix stripping, no sanitization.

### list

Run `git worktree list` (optionally with `--porcelain` for machine-readable output) to enumerate the worktrees registered against the current repository.

### remove

Run `git worktree remove "$TARGET"` to delete a worktree. When the worktree's working tree still contains dirty or untracked data that blocks removal, pass `--force` to override the safety check.

### move

Run `git worktree move "$SOURCE" "$DESTINATION"` to relocate an existing worktree. When the destination lives inside a directory that does not yet exist, create the parent with `mkdir -p "$(dirname "$DESTINATION")"` first, mirroring the `add` flow.

### lock

Run `git worktree lock "$TARGET" [--reason <text>]` to prevent a worktree from being automatically pruned (useful for worktrees on removable media or otherwise temporarily inaccessible paths).

### unlock

Run `git worktree unlock "$TARGET"` to remove a previously applied lock so the worktree can again be pruned or removed normally.

### prune

Run `git worktree prune` to clean up administrative metadata for worktrees whose working directories have already been deleted out-of-band. When several worktrees have been removed externally and leave residual metadata in `.git/worktrees/`, run `git worktree prune` to reconcile state.

### repair

Run `git worktree repair [<path>...]` to fix the bidirectional links between the main repository and its worktrees after the main repository or a worktree was moved.

## Failure modes

- **Target path already exists.** Any file or directory at `$TARGET` (including an empty directory) trips pre-check 1. Do not silently overwrite; report the conflict and suggest either a different path or an explicit `--force`. Typical raw git error if this slips past the pre-check: `fatal: '<path>' already exists`.
- **Target path is already a registered worktree.** Pre-check 2 fires when the normalized `$TARGET` exactly matches a line in `git worktree list --porcelain`'s worktree entries. Suggest `git worktree remove "$TARGET"` first, or choose a different path. Typical raw git error: `fatal: '<path>' is already checked out at '...'`.
- **Not inside a git work tree.** `git rev-parse --show-toplevel` exits non-zero. Abort and tell the user to `cd` into a git working tree before retrying. Do not fall back to `pwd`.
- **Bare repository.** `git rev-parse --show-toplevel` also exits non-zero in a bare repo (stderr contains `fatal: this operation must be run in a work tree`). In this case, ask the user to supply an explicit target path instead of relying on the default rule.
- **Illegal branch name.** Branch names containing characters that git itself rejects are not sanitized by this skill. `git worktree add` will surface the underlying git error. Note that `mkdir -p` may already have created harmless intermediate directories (for example `<project>/..`) before git rejects the branch name; this is an expected side effect, not a bug.

## Long-Running Considerations

A git worktree provides an isolated execution checkout; it is not a place to track task state. A single task may hold several worktrees (one per repo it touches), but they are all execution isolation, not state. Persist task progress, decisions, and blockers in the task status file under `.zyz-worker/tasks/<task-id>/` (or the path provided by the dispatching agent). See [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md).
