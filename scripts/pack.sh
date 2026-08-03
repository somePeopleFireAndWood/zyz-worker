#!/usr/bin/env bash
#
# pack.sh — package the zyz-worker plugin into a release zip.
#
# ## Inputs
#
# - None on the command line.
# - Reads the `version` field from `.claude-plugin/plugin.json` at the repo
#   root. The repo root is resolved via `git rev-parse --show-toplevel`.
#
# ## Output (stdout)
#
# On success, prints three structured `key=value` lines:
#
#     dist=<absolute path to the produced zip>
#     size=<size in bytes>
#     version=<X.Y.Z[+build-meta]>
#
# Stderr is empty on the happy path. A non-fatal warning is emitted to stderr
# when the working tree is dirty (the zip ships the git index content, so any
# staged-but-uncommitted changes will land in the archive).
#
# ## Side effects
#
# - Creates `dist/` at the repo root if missing.
# - Removes any pre-existing `dist/zyz-worker-<version>.zip` before writing.
# - Writes `dist/zyz-worker-<version>.zip` containing every file tracked by
#   `git ls-files` at HEAD (or the current index, see dirty-tree warning).
#
# ## Exit codes
#
# - 0  success.
# - 2  not in a git repo, or `.claude-plugin/plugin.json` is missing.
# - 3  `zip` command not found on PATH, or `zip` invocation failed.
# - 4  version field present but unparseable.
#
set -euo pipefail

# Resolve repo root first. If we are not in a git repo, exit 2 before doing
# anything else.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "error: not in a git repo" >&2; exit 2; }

# `.claude-plugin/plugin.json` is the single source of truth for the version.
# If it is missing, exit 2 (same class as "release context not present").
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
if [ ! -f "$MANIFEST" ]; then
    echo "error: missing .claude-plugin/plugin.json at $REPO_ROOT" >&2
    exit 2
fi

# Parse the `version` field with a portable grep+sed pipeline. We intentionally
# avoid `jq` here so pack.sh works on minimal hosts.
# `|| true` is required: on a manifest with no "version" line the inner grep
# exits 1 and, under `set -o pipefail`, the whole command substitution fails —
# aborting with exit 1 and no message before the documented exit 4 below could
# ever be reached.
VERSION="$(grep -E '"version"' "$MANIFEST" | head -n1 \
    | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
if [ -z "${VERSION:-}" ]; then
    echo "error: cannot parse version from $MANIFEST" >&2
    exit 4
fi

# `zip` is required.
if ! command -v zip >/dev/null 2>&1; then
    echo "error: zip command not found on PATH" >&2
    exit 3
fi

# Prepare output path.
mkdir -p "$REPO_ROOT/dist"
TARGET="$REPO_ROOT/dist/zyz-worker-$VERSION.zip"
rm -f "$TARGET"

# Operate from the repo root so the paths inside the zip are repo-relative.
cd "$REPO_ROOT"

# Dirty-tree warning (informational, not fatal). `git ls-files` decides WHICH
# paths ship (the index), but `zip` then reads each path from the WORKING TREE —
# so the archive carries current on-disk content, including unstaged edits, not
# HEAD and not the staged blobs. Surface this so a release operator notices.
if ! git diff-index --quiet HEAD --; then
    echo "warning: working tree is dirty; the zip ships current on-disk file content (including unstaged edits), not HEAD" >&2
fi

# Use `git ls-files` as the single source of truth for what ships:
#   - excludes everything untracked (e.g. dist/, docs/superpowers/)
#   - excludes everything gitignored (e.g. .zyz-worker/)
#   - one canonical inclusion list (the git index)
#
# We use `xargs -0` instead of `zip -@` for portability across BSD (macOS) and
# GNU. `zip` appends to an existing archive by default, so multi-batch xargs
# invocations are safe (the `rm -f "$TARGET"` above guarantees a clean start).
if ! git ls-files -z | xargs -0 zip -q "$TARGET"; then
    echo "error: zip failed" >&2
    exit 3
fi

# `stat -f %z` is the macOS form; `stat -c %s` is the GNU form. Try macOS
# first, then fall back to GNU.
SIZE="$(stat -f %z "$TARGET" 2>/dev/null || stat -c %s "$TARGET")"

printf 'dist=%s\nsize=%s\nversion=%s\n' "$TARGET" "$SIZE" "$VERSION"
