#!/usr/bin/env bash
#
# orch-cleanup-worker.sh — kill a worker's tmux session, remove its git
# worktree, and archive its runtime directory.
#
# Contract:
#   Inputs:
#     $1  <task-id>           must match [A-Za-z0-9_-]+
#     $2  <list-dir>          master list directory
#     $3  --force (optional)  actually perform the destructive actions (default
#                             is a dry-run that prints what would be done)
#
#   Side effects (when --force):
#     - `tmux kill-session -t <tmux-session>` (also kills the in-pane heartbeat
#       daemon via SIGHUP).
#     - `git worktree remove <worktree>` (or `--force` variant when forced).
#     - Moves <list-dir>/runtime/<task-id>/ to
#       <list-dir>/runtime/.archive/<task-id>-<timestamp>/ to preserve audit.
#
#   Output (stdout):
#     cleanup-status=dry-run|success
#     tmux-killed=true|false|skipped
#     worktree-removed=true|false|skipped
#     worktree-removed-2=…            (multi-repo only: one line per extra repo)
#     runtime-archived=true|false|skipped
#     archive-path=<path-or-empty>
#
#   Multi-repo (D0/D1/D3): the worktree SET is discovered from the resolved
#   numbered field group in runtime/<task-id>/dispatch.md (worktree, worktree-2,
#   …), resolved at the top BEFORE the archive step so dispatch.md is never read
#   after it is archived. Single-repo entries (dispatch.md absent or carrying no
#   `worktree:` field) fall back to the master entry `worktree:` and are handled
#   byte-for-byte as before (N=1, unsuffixed keys).
#
#   Exit codes:
#     0  success (including dry-run)
#     2  argument error / invalid task-id
#     3  missing dependency (tmux / git)
#     4  master entry missing
#     8  a worktree could not be located/removed (per-repo; mid-removal failures
#        do not abort the remaining repos, but the script exits 8 at the end)
#     9  tmux kill-session failed
#
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <task-id> <list-dir> [--force]" >&2
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    usage
    exit 2
fi

TASK_ID="$1"
LIST_DIR="$2"
FORCE="false"

if [ "$#" -eq 3 ]; then
    case "$3" in
        --force) FORCE="true" ;;
        *) usage; exit 2 ;;
    esac
fi

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

for dep in tmux git; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "error: missing dependency: $dep" >&2
        exit 3
    fi
done

MASTER_ENTRY="$LIST_DIR/tasks/$TASK_ID.md"
if [ ! -f "$MASTER_ENTRY" ] || [ ! -r "$MASTER_ENTRY" ]; then
    echo "error: master entry not found or unreadable: $MASTER_ENTRY" >&2
    exit 4
fi

fm_field() {
    local file="$1"
    local key="$2"
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

TMUX_SESSION="$(fm_field "$MASTER_ENTRY" tmux-session)"
[ -z "$TMUX_SESSION" ] && TMUX_SESSION="zyz-task-$TASK_ID"

RUNTIME_DIR="$LIST_DIR/runtime/$TASK_ID"
DISPATCH_FILE="$RUNTIME_DIR/dispatch.md"

# ─── Resolve the worktree SET (D0/D1/D3) ─────────────────────────────────────
#
# The single source of truth for the repo set is the RESOLVED numbered field
# group in dispatch.md (worktree, worktree-2, …), written fully-resolved by
# spawn/reuse. We resolve it HERE, at the top, BEFORE the archive step below —
# archiving moves runtime/<task-id>/ (and dispatch.md with it), so any read
# after that point would miss the file. Resolving up front guarantees no
# read-after-archive.
#
# WT[] holds the physical worktree paths (index 0 = primary = repo 1). N = its
# length. Single-repo legacy fallback: if dispatch.md is absent or carries no
# `worktree:` field, read the master entry `worktree:` (byte-identical to the
# historical single-repo path). Multi-repo discovery relies on dispatch.md's
# numbered group; the master-entry fallback can only ever yield one worktree.
WT=()
# Read the dispatch.md primary worktree ONLY when the file exists — the private
# fm_field awk has no missing-file guard, so calling it on an absent dispatch.md
# would abort. The `[ -f ]` gate is also the single-repo fallback trigger below.
DISPATCH_PRIMARY=""
[ -f "$DISPATCH_FILE" ] && DISPATCH_PRIMARY="$(fm_field "$DISPATCH_FILE" worktree)"
if [ -f "$DISPATCH_FILE" ] && [ -n "$DISPATCH_PRIMARY" ]; then
    # dispatch.md is authoritative: loop the numbered group until empty. The
    # values are already resolved concrete paths (spawn/reuse expand `~/`), but
    # expand a leading `~/` defensively with the same quoted-pattern form used
    # everywhere in this family.
    i=1
    while :; do
        key="worktree"
        [ "$i" -ge 2 ] && key="worktree-$i"
        v="$(fm_field "$DISPATCH_FILE" "$key")"
        [ -n "$v" ] || break
        case "$v" in
            "~/"*) v="$HOME/${v#"~/"}" ;;
        esac
        WT+=("$v")
        i=$((i + 1))
    done
else
    # Single-repo legacy fallback: master entry `worktree:` (N=1, or empty).
    # Byte-identical to the historical single-repo expansion (T5 BUG-1 grep
    # asserts this exact quoted `${WORKTREE#"~/"}` form is present).
    WORKTREE="$(fm_field "$MASTER_ENTRY" worktree)"
    case "$WORKTREE" in
        "~/"*) WORKTREE="$HOME/${WORKTREE#"~/"}" ;;
    esac
    [ -n "$WORKTREE" ] && WT+=("$WORKTREE")
fi

# Primary worktree kept as WORKTREE too, so the single-repo code paths below
# read byte-identically.
WORKTREE="${WT[0]:-}"

# Dry-run: report what would be done.
if [ "$FORCE" != "true" ]; then
    printf 'cleanup-status=dry-run\n'
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        printf 'tmux-killed=false\n'
        printf '# would: tmux kill-session -t %s\n' "$TMUX_SESSION"
    else
        printf 'tmux-killed=skipped\n'
    fi
    # Per-repo would-remove lines. Index 0 = primary = unsuffixed key
    # (single-repo byte-compat); index j>=1 = worktree-removed-$((j+1)).
    if [ "${#WT[@]}" -eq 0 ]; then
        printf 'worktree-removed=skipped\n'
    else
        j=0
        while [ "$j" -lt "${#WT[@]}" ]; do
            suffix=""
            [ "$j" -ge 1 ] && suffix="-$((j + 1))"
            wt="${WT[$j]}"
            if [ -n "$wt" ] && [ -e "$wt" ]; then
                printf 'worktree-removed%s=false\n' "$suffix"
                printf '# would: git worktree remove %s\n' "$wt"
            else
                printf 'worktree-removed%s=skipped\n' "$suffix"
            fi
            j=$((j + 1))
        done
    fi
    if [ -d "$RUNTIME_DIR" ]; then
        printf 'runtime-archived=false\n'
        printf '# would: mv %s %s/runtime/.archive/%s-<timestamp>/\n' \
            "$RUNTIME_DIR" "$LIST_DIR" "$TASK_ID"
    else
        printf 'runtime-archived=skipped\n'
    fi
    printf 'archive-path=\n'
    exit 0
fi

# --force: actually perform the actions.
TMUX_KILLED="skipped"
RUNTIME_ARCHIVED="skipped"
ARCHIVE_PATH=""

# Kill tmux session if alive (ONCE, session is task-level — unchanged). Killing
# the session sends SIGHUP to all panes; the in-pane heartbeat daemon's trap
# handles SIGHUP and exits cleanly.
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    if tmux kill-session -t "$TMUX_SESSION" 2>/dev/null; then
        TMUX_KILLED="true"
    else
        echo "error: failed to kill tmux session: $TMUX_SESSION" >&2
        exit 9
    fi
fi

# Per-repo removal (D3). Parallel arrays index-aligned with WT[]:
#   STATUS[j] : skipped | true | false  (reported as worktree-removed[-N]=)
#   DIRTY[j]  : true|false              (probed in the precheck)
#   MAINREPO[j]: resolved main-repo checkout for `git worktree remove -C`
# Index 0 = primary = unsuffixed key (single-repo byte-compat).
STATUS=()
DIRTY=()
MAINREPO=()

# ── Dirty/locatability PRECHECK for ALL repos BEFORE removing any (fail-fast,
#    mirroring the merge fail-fast approach): a repo whose main-repo checkout
#    cannot be located aborts with exit 8 having removed NOTHING. This preserves
#    the single-repo semantics (locate-fail → exit 8) while guaranteeing a
#    multi-repo set is never left half-removed because of an unlocatable repo.
j=0
while [ "$j" -lt "${#WT[@]}" ]; do
    wt="${WT[$j]}"
    if [ -z "$wt" ] || [ ! -e "$wt" ]; then
        STATUS[$j]="skipped"
        DIRTY[$j]="false"
        MAINREPO[$j]=""
        j=$((j + 1))
        continue
    fi

    # Probe dirtiness from inside the worktree.
    d="false"
    if porcelain="$(git -C "$wt" status --porcelain 2>/dev/null)"; then
        if [ -n "$porcelain" ]; then
            d="true"
        fi
    fi
    DIRTY[$j]="$d"

    # Resolve the main repo so `git worktree remove` runs in a context that
    # can actually find the worktree registration. Without `-C <main-repo>`
    # this command silently fails when this helper is invoked from a cwd
    # that is not inside any git repo (e.g. the plugin root during T6
    # integration tests). See merge-and-cleanup.sh for the same pattern.
    common_dir="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)"
    case "$common_dir" in
        /*) ;;
        *) common_dir="$(cd "$wt" && cd "$common_dir" && pwd)" ;;
    esac
    main_repo="$(dirname "$common_dir")"
    if [ -z "$main_repo" ] || [ ! -d "$main_repo" ]; then
        echo "error: cannot locate main repo checkout for worktree $wt" >&2
        exit 8
    fi
    MAINREPO[$j]="$main_repo"
    STATUS[$j]="pending"
    j=$((j + 1))
done

# ── Removal loop (repos are independent — a mid-set failure does NOT abort the
#    remaining repos; we record the failure and exit 8 at the end). When --force
#    is set (we are in this branch) a dirty worktree is removed with git's
#    --force. Let stderr surface on failure — silently dropping it previously
#    masked T6's "worktree still present after cleanup" symptom.
REMOVAL_FAILED="false"
j=0
while [ "$j" -lt "${#WT[@]}" ]; do
    if [ "${STATUS[$j]}" != "pending" ]; then
        j=$((j + 1))
        continue
    fi
    wt="${WT[$j]}"
    main_repo="${MAINREPO[$j]}"
    if [ "${DIRTY[$j]}" = "true" ]; then
        if git -C "$main_repo" worktree remove --force "$wt" >/dev/null; then
            STATUS[$j]="true"
        else
            echo "error: failed to git worktree remove --force $wt (main repo: $main_repo)" >&2
            STATUS[$j]="false"
            REMOVAL_FAILED="true"
        fi
    else
        if git -C "$main_repo" worktree remove "$wt" >/dev/null; then
            STATUS[$j]="true"
        else
            echo "error: failed to git worktree remove $wt (main repo: $main_repo)" >&2
            STATUS[$j]="false"
            REMOVAL_FAILED="true"
        fi
    fi
    j=$((j + 1))
done

# emit_worktree_lines — print the per-repo worktree-removed[-N]= lines. Index 0
# = unsuffixed key (single-repo byte-compat); index j>=1 = worktree-removed-$((j+1)).
emit_worktree_lines() {
    local k=0
    if [ "${#WT[@]}" -eq 0 ]; then
        printf 'worktree-removed=skipped\n'
        return
    fi
    while [ "$k" -lt "${#WT[@]}" ]; do
        if [ "$k" -eq 0 ]; then
            printf 'worktree-removed=%s\n' "${STATUS[$k]}"
        else
            printf 'worktree-removed-%d=%s\n' "$((k + 1))" "${STATUS[$k]}"
        fi
        k=$((k + 1))
    done
}

# A mid-removal failure leaves the container partially cleaned; do NOT archive
# runtime/<task-id>/ (its dispatch.md is the authoritative worktree set — the
# operator needs it to retry the failed repo). Exit 8.
#
# stdout on failure: the original single-repo script exits 8 with NO stdout, so
# for N<=1 we preserve that byte-for-byte (the stderr message was already emitted
# in the removal loop). For a multi-repo set (N>=2) we report per-repo status so
# the operator can see which repo to retry (design D3).
if [ "$REMOVAL_FAILED" = "true" ]; then
    if [ "${#WT[@]}" -ge 2 ]; then
        emit_worktree_lines
    fi
    exit 8
fi

# Archive runtime dir (ONCE, unchanged — AFTER all worktree removals).
if [ -d "$RUNTIME_DIR" ]; then
    TS="$(date +%Y%m%d-%H%M%S)"
    ARCHIVE_DIR="$LIST_DIR/runtime/.archive"
    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE_PATH="$ARCHIVE_DIR/$TASK_ID-$TS"
    mv "$RUNTIME_DIR" "$ARCHIVE_PATH"
    RUNTIME_ARCHIVED="true"
fi

printf 'cleanup-status=success\n'
printf 'tmux-killed=%s\n' "$TMUX_KILLED"
emit_worktree_lines
printf 'runtime-archived=%s\n' "$RUNTIME_ARCHIVED"
printf 'archive-path=%s\n' "$ARCHIVE_PATH"

exit 0
