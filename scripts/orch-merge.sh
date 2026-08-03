#!/usr/bin/env bash
#
# orch-merge.sh — merge a finished worker's branch into the base branch and
# push, WITHOUT marking the master entry completed and WITHOUT cleaning up the
# worktree.
#
# This is the decoupled "merge only" path: the user wrote `merge` (or
# `merge: <base>`) in the master entry `## Pending Merge Approval` section to
# merge the task branch to base, but delivery is recorded separately. The
# `confirmed` token no longer writes `state: completed` directly — it now relays
# the user's confirmation to the worker (see the orchestration gate step), which
# advances to `phase=done`; the orchestrator then mirrors `state: completed`. The
# worktree is removed separately (`cleanup-approved` / orch-cleanup-worker.sh).
# The legacy combined path is orch-merge-and-cleanup.sh (the `approved` token).
# This script only merges; it never writes `state:`.
#
# Order (mirrors orch-merge-and-cleanup.sh, minus the state write and cleanup):
#
#   1. preconditions (`merge` token present; every repo worktree clean; repo
#                     locatable) — fail-fast across ALL repos before any merge
#   2. merge        (gh pr merge --merge, OR fall back to local `git merge --no-ff`)
#                    per repo, repo 1..N
#   3. push         (only if origin exists), per repo
#
# Multi-repo (design 02-D0/D1/D2): the authoritative repo set comes from the
# RESOLVED numbered field groups in `runtime/<task-id>/dispatch.md` (written by
# spawn/reuse), NOT the master entry. dispatch.md carries, after the unnumbered
# `base:` line, for N=2..count ascending: worktree-N / source-repo-N / branch-N /
# base-N — all resolved non-empty. Repo 1 = the unnumbered worktree/branch/base.
# SINGLE-REPO FALLBACK: if dispatch.md is absent or lacks `worktree:`, the legacy
# single-repo path is used (N=1): worktree from the master entry `worktree:`,
# branch from the existing resolution, base from argv/`merge:` token. This
# dispatch-ABSENT single-repo fallback is byte-for-byte identical to the
# pre-multi-repo behaviour. When dispatch.md IS present, the base (and branch) are
# sourced from dispatch.md's resolved fields per the design's authoritative-
# dispatch decision (02-D0), so it is not byte-identical to the legacy path.
#
# Contract:
#   Inputs:
#     $1  <task-id>           must match [A-Za-z0-9_-]+
#     $2  <list-dir>          master list directory
#     $3  <base-branch>       merge target (e.g. main); a base in the `merge:`
#                             token overrides this argument for ALL repos
#
#   Side effects:
#     - Merges each repo's <branch-N> into <base-N> in that repo's main checkout.
#     - Pushes each <base-N> to origin if origin is configured.
#     - Does NOT write `state:`; does NOT clean up the worktree.
#
#   Output (stdout):
#     merge-status=success            (repo 1; unnumbered = repo 1)
#     pr-url=<url-or-empty>           (repo 1)
#     gh-fallback=true|false          (repo 1)
#     merge-status-2=…  pr-url-2=…    (repo 2..N when multi-repo)
#
#   Exit codes:
#     0   success
#     2   argument error / invalid task-id
#     3   missing dependency (git)
#     4   master entry missing
#     10  `## Pending Merge Approval` does not contain `merge`
#     11  worker worktree is dirty / repo not found
#     12  merge conflict (state UNCHANGED, no push)
#     13  push failed (merge already done; user can retry)
#
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <task-id> <list-dir> <base-branch>" >&2
}

if [ "$#" -ne 3 ]; then
    usage
    exit 2
fi

TASK_ID="$1"
LIST_DIR="$2"
BASE_BRANCH="$3"

case "$TASK_ID" in
    ''|*[!A-Za-z0-9_-]*)
        echo "error: invalid task-id (must match [A-Za-z0-9_-]+): '$TASK_ID'" >&2
        exit 2
        ;;
esac

if [ -z "$LIST_DIR" ] || [ -z "$BASE_BRANCH" ]; then
    usage
    exit 2
fi

# Dependency check (design §E top: every helper must `command -v tmux git`).
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

# Authoritative repo set (design 02-D0) lives in the RESOLVED numbered field
# groups of dispatch.md, discovered below (after the token scan). BRANCH/WORKTREE
# resolution moves into that discovery block so the single-repo fallback stays
# byte-for-byte identical to the legacy master-entry path.
DISPATCH_FILE="$LIST_DIR/runtime/$TASK_ID/dispatch.md"

# ---------------------------------------------------------------------------
# Step 1: preconditions (merge token)
# ---------------------------------------------------------------------------

# Scan the `## Pending Merge Approval` section for a `merge` token. Accept both
# the bare `merge` form and `merge: <base>` (where the base overrides $3). The
# `confirmed` token must NOT satisfy this check, and the `awaiting-confirmation`
# phase string must never match — `merge` is bounded by non-word chars below.
SECTION="$(awk '
    BEGIN { in_section = 0 }
    /^## Pending Merge Approval[[:space:]]*$/ { in_section = 1; next }
    /^## / && in_section == 1 { in_section = 0 }
    in_section == 1 { print }
' "$MASTER_ENTRY")"

MERGE_TOKEN="false"
if printf '%s\n' "$SECTION" | grep -qE '(^|[^a-zA-Z0-9_-])merge([^a-zA-Z0-9_-]|$)'; then
    MERGE_TOKEN="true"
fi

if [ "$MERGE_TOKEN" != "true" ]; then
    echo "error: master entry has no 'merge' token in '## Pending Merge Approval': $MASTER_ENTRY" >&2
    exit 10
fi

# If the token carries an explicit base (`merge: <base>`), it overrides $3.
# The `|| true` guards against `set -o pipefail` aborting when the bare `merge`
# token (no `: <base>`) yields no grep match.
TOKEN_BASE="$( { printf '%s\n' "$SECTION" \
    | grep -oE '(^|[^a-zA-Z0-9_-])merge[[:space:]]*:[[:space:]]*[^[:space:]]+' \
    | head -n1 \
    | sed -E 's/.*merge[[:space:]]*:[[:space:]]*//'; } || true)"
if [ -n "$TOKEN_BASE" ]; then
    BASE_BRANCH="$TOKEN_BASE"
fi

# ---------------------------------------------------------------------------
# Repo-set discovery (design 02-D0/D1). The authoritative repo set = the RESOLVED
# numbered field groups in dispatch.md. Fill parallel arrays WT / BR / BASE_ARR,
# repo 1 at index 0. Single-repo fallback (dispatch.md absent or no `worktree:`)
# reads the master entry so the legacy path stays byte-for-byte identical.
# ---------------------------------------------------------------------------
WT=()
BR=()
BASE_ARR=()

DISPATCH_WORKTREE=""
if [ -f "$DISPATCH_FILE" ]; then
    DISPATCH_WORKTREE="$(fm_field "$DISPATCH_FILE" worktree)"
fi

if [ -n "$DISPATCH_WORKTREE" ]; then
    # Multi-repo capable path: iterate worktree / worktree-2 / … until empty.
    disc_n=1
    while :; do
        if [ "$disc_n" -ge 2 ]; then
            wt="$(fm_field "$DISPATCH_FILE" "worktree-$disc_n")"
            br="$(fm_field "$DISPATCH_FILE" "branch-$disc_n")"
            bs="$(fm_field "$DISPATCH_FILE" "base-$disc_n")"
        else
            wt="$DISPATCH_WORKTREE"
            br="$(fm_field "$DISPATCH_FILE" branch)"
            bs="$(fm_field "$DISPATCH_FILE" base)"
        fi
        if [ -z "$wt" ]; then
            # Numbering-gap detection, mirroring orch-spawn-worker.sh's probe.
            # This loop stops at the first empty worktree-N, so a hole (worktree-3
            # present, worktree-2 absent) would silently truncate the repo set and
            # this script would merge only the repos before the hole while still
            # reporting merge-status=success — silent data loss on the delivery
            # path. Spawn rejects such an entry with exit 5; a reader must not be
            # more permissive than the writer.
            gap_probe="$disc_n"
            while [ "$gap_probe" -le 9 ]; do
                if [ -n "$(fm_field "$DISPATCH_FILE" "worktree-$gap_probe")" ]; then
                    echo "error: worktree numbering gap in $DISPATCH_FILE: worktree-$disc_n is missing but worktree-$gap_probe is present" >&2
                    exit 11
                fi
                gap_probe=$((gap_probe + 1))
            done
            break
        fi
        case "$wt" in
            "~/"*) wt="$HOME/${wt#"~/"}" ;;
        esac
        # An explicit `merge: <base>` token overrides ALL repos' base (design
        # 02-D2-2); otherwise use this repo's own resolved base-N.
        [ -n "$TOKEN_BASE" ] && bs="$BASE_BRANCH"
        WT+=("$wt")
        BR+=("$br")
        BASE_ARR+=("$bs")
        disc_n=$((disc_n + 1))
    done
else
    # Single-repo legacy fallback: master entry worktree/branch, argv/token base.
    br="$(fm_field "$MASTER_ENTRY" branch)"
    [ -z "$br" ] && br="task/$TASK_ID"
    wt="$(fm_field "$MASTER_ENTRY" worktree)"
    case "$wt" in
        "~/"*) wt="$HOME/${wt#"~/"}" ;;
    esac
    # Emptiness/existence is checked uniformly in the fail-fast precheck below
    # (same exit 11 + message as the legacy single-repo path).
    WT+=("$wt")
    BR+=("$br")
    BASE_ARR+=("$BASE_BRANCH")
fi

REPO_COUNT="${#WT[@]}"

# ---------------------------------------------------------------------------
# Step 2 precheck: fail-fast across ALL repos before any merge (design 02-D2-1).
# For each repo verify the worktree is non-empty + present, clean, and its main
# checkout is resolvable via the worktree's git common-dir. Any failure => exit
# 11 with nothing merged. MAIN_REPO_ARR is resolved here and reused in the loop.
# ---------------------------------------------------------------------------
MAIN_REPO_ARR=()
pre_i=0
while [ "$pre_i" -lt "$REPO_COUNT" ]; do
    pre_wt="${WT[$pre_i]}"
    if [ -z "$pre_wt" ] || [ ! -d "$pre_wt" ]; then
        echo "error: worktree path missing or invalid: $pre_wt" >&2
        exit 11
    fi
    if pre_porcelain="$(git -C "$pre_wt" status --porcelain 2>/dev/null)"; then
        if [ -n "$pre_porcelain" ]; then
            echo "error: worktree is dirty: $pre_wt" >&2
            exit 11
        fi
    else
        echo "error: cannot read git status in $pre_wt" >&2
        exit 11
    fi
    # Locate the main checkout via the worktree's git common-dir (same approach as
    # orch-merge-and-cleanup.sh — we cannot merge a branch into the worktree that
    # has it checked out).
    pre_common="$(git -C "$pre_wt" rev-parse --git-common-dir 2>/dev/null)"
    if [ -n "$pre_common" ]; then
        case "$pre_common" in
            /*) ;;
            *) pre_common="$(cd "$pre_wt" && cd "$pre_common" && pwd)" ;;
        esac
        pre_main="$(dirname "$pre_common")"
    else
        pre_main=""
    fi
    if [ -z "$pre_main" ] || [ ! -d "$pre_main" ]; then
        echo "error: cannot locate main repo checkout for worktree $pre_wt" >&2
        exit 11
    fi
    MAIN_REPO_ARR+=("$pre_main")
    pre_i=$((pre_i + 1))
done
# ---------------------------------------------------------------------------
# Step 2: per-repo merge loop (design 02-D2). Repo 1..N reuses the original
# single-repo flow (gh push+PR+merge, else local checkout base + merge --no-ff +
# push). Idempotency is split by path (D2-3): local uses merge-base --is-ancestor;
# gh probes PR state by head branch. Real conflict => exit 12 (merged repos NOT
# rolled back); push failure => record + continue, exit 13 after the loop.
# Per-repo results accumulate in RESULT_STATUS / RESULT_PRURL / RESULT_GHFB.
# ---------------------------------------------------------------------------
RESULT_STATUS=()
RESULT_PRURL=()
RESULT_GHFB=()
ANY_PUSH_FAILED="false"

# Emit accumulated per-repo results (design 02-D2-5): repo 1 uses the unnumbered
# keys (byte-unchanged for single-repo); repos 2..N append -N-suffixed keys.
emit_results() {
    local r=0 n
    while [ "$r" -lt "${#RESULT_STATUS[@]}" ]; do
        n=$((r + 1))
        if [ "$n" -eq 1 ]; then
            printf 'merge-status=%s\n' "${RESULT_STATUS[$r]}"
            printf 'pr-url=%s\n' "${RESULT_PRURL[$r]}"
            printf 'gh-fallback=%s\n' "${RESULT_GHFB[$r]}"
        else
            printf 'merge-status-%s=%s\n' "$n" "${RESULT_STATUS[$r]}"
            printf 'pr-url-%s=%s\n' "$n" "${RESULT_PRURL[$r]}"
            printf 'gh-fallback-%s=%s\n' "$n" "${RESULT_GHFB[$r]}"
        fi
        r=$((r + 1))
    done
}

# Restore each main checkout's original HEAD on ANY exit path (success, conflict
# 12, push-failure 13). The local merge path below runs `git checkout <base>` in
# the MAIN repo, which otherwise silently strands the operator on the base branch
# — their in-progress branch is switched out from under them with no notice. We
# record the pre-merge ref per repo and restore in a trap so no exit path leaks
# the switch. Only refs we actually moved are restored, and restore failures are
# non-fatal (never mask the real exit code).
RESTORE_REPO=()
RESTORE_REF=()
restore_checkouts() {
    local k=0
    while [ "$k" -lt "${#RESTORE_REPO[@]}" ]; do
        if [ -n "${RESTORE_REF[$k]}" ]; then
            git -C "${RESTORE_REPO[$k]}" checkout "${RESTORE_REF[$k]}" >/dev/null 2>&1 || true
        fi
        k=$((k + 1))
    done
}
trap restore_checkouts EXIT

loop_i=0
while [ "$loop_i" -lt "$REPO_COUNT" ]; do
    REPO_NUM=$((loop_i + 1))
    MAIN_REPO="${MAIN_REPO_ARR[$loop_i]}"
    BRANCH="${BR[$loop_i]}"
    BASE_BRANCH="${BASE_ARR[$loop_i]}"

    PR_URL=""
    GH_FALLBACK="false"
    MERGE_OK="false"
    STATUS="success"

    # Decide whether origin exists.
    HAS_ORIGIN="false"
    if git -C "$MAIN_REPO" remote get-url origin >/dev/null 2>&1; then
        HAS_ORIGIN="true"
    fi

    if command -v gh >/dev/null 2>&1 && [ "$HAS_ORIGIN" = "true" ]; then
        # gh path idempotency (design 02-D2-3): probe PR state by head branch.
        # `--head` is a `gh pr list` flag (NOT `gh pr view`). gh has a built-in
        # --jq, so no external jq. MERGED => already-merged skip; OPEN => reuse
        # the PR (merge only, no re-create); none => create + merge.
        gh_stderr="$(mktemp -t gh.XXXXXX 2>/dev/null || echo "/tmp/gh.$$")"
        pr_state=""
        pr_url_existing=""
        if gh_probe="$( (cd "$MAIN_REPO" && gh pr list --head "$BRANCH" --state all --json state,url,number --jq '.[0] | "\(.state)\t\(.url)"') 2>"$gh_stderr")"; then
            pr_state="${gh_probe%%$'\t'*}"
            pr_url_existing="${gh_probe#*$'\t'}"
            [ "$pr_url_existing" = "$pr_state" ] && pr_url_existing=""
        fi

        if [ "$pr_state" = "MERGED" ]; then
            # Already merged upstream: idempotent no-op.
            MERGE_OK="true"
            STATUS="already-merged"
            PR_URL="$pr_url_existing"
        else
            # Push the branch so gh has something to PR against.
            git -C "$MAIN_REPO" push origin "$BRANCH" >/dev/null 2>"$gh_stderr" || true

            if [ "$pr_state" = "OPEN" ]; then
                # Reuse the existing open PR — merge directly, do NOT re-create.
                PR_URL="$pr_url_existing"
                if (cd "$MAIN_REPO" && gh pr merge "$BRANCH" --merge) 2>"$gh_stderr"; then
                    MERGE_OK="true"
                fi
            elif gh_out="$( (cd "$MAIN_REPO" && gh pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "$TASK_ID" --body "Auto-created by orchestrator for task $TASK_ID") 2>"$gh_stderr")"; then
                PR_URL="$(printf '%s\n' "$gh_out" | grep -Eo 'https://[^[:space:]]+' | tail -n1 || true)"
                if (cd "$MAIN_REPO" && gh pr merge "$BRANCH" --merge) 2>>"$gh_stderr"; then
                    MERGE_OK="true"
                fi
            fi

            if [ "$MERGE_OK" != "true" ]; then
                gh_err_lc="$(LC_ALL=C tr '[:upper:]' '[:lower:]' < "$gh_stderr" 2>/dev/null || true)"
                if printf '%s' "$gh_err_lc" | grep -Eq 'already merged|no commits between'; then
                    # gh reports the branch is already merged / nothing to merge:
                    # normalize to already-merged, NOT a conflict (design 02-D2-3).
                    MERGE_OK="true"
                    STATUS="already-merged"
                elif printf '%s' "$gh_err_lc" | grep -Eq 'auth|unauthenticated|not logged in'; then
                    GH_FALLBACK="true"
                    PR_URL=""
                else
                    rm -f "$gh_stderr"
                    echo "error: gh merge failed for repo $REPO_NUM without auth-error indicator; treating as merge conflict; resume from repo $REPO_NUM" >&2
                    # stdout: report per-repo status accumulated so far (merged
                    # repos 1..k-1 are NOT rolled back — design 02-D2-3).
                    emit_results
                    exit 12
                fi
            fi
        fi
        rm -f "$gh_stderr"
    fi

    # Fallback / no-gh path: local idempotency + `git merge --no-ff`.
    if [ "$MERGE_OK" != "true" ]; then
        # Local idempotency (design 02-D2-3): branch already an ancestor of base.
        if git -C "$MAIN_REPO" merge-base --is-ancestor "$BRANCH" "$BASE_BRANCH" >/dev/null 2>&1; then
            MERGE_OK="true"
            STATUS="already-merged"
        elif ! _pre_ref="$(git -C "$MAIN_REPO" symbolic-ref --quiet --short HEAD 2>/dev/null \
                || git -C "$MAIN_REPO" rev-parse HEAD 2>/dev/null)"; then
            echo "error: cannot read current HEAD in $MAIN_REPO (repo $REPO_NUM)" >&2
            exit 11
        elif ! { git -C "$MAIN_REPO" checkout "$BASE_BRANCH" >/dev/null 2>&1 \
                && { RESTORE_REPO+=("$MAIN_REPO"); RESTORE_REF+=("$_pre_ref"); }; }; then
            echo "error: failed to checkout $BASE_BRANCH in $MAIN_REPO (repo $REPO_NUM)" >&2
            exit 11
        elif git -C "$MAIN_REPO" merge --no-ff "$BRANCH" >/dev/null 2>&1; then
            MERGE_OK="true"
        else
            git -C "$MAIN_REPO" merge --abort >/dev/null 2>&1 || true
            echo "error: local merge conflict between $BRANCH and $BASE_BRANCH (repo $REPO_NUM); resume from repo $REPO_NUM" >&2
            # merged repos 1..k-1 are NOT rolled back (design 02-D2-3).
            emit_results
            exit 12
        fi
    fi

    if [ "$MERGE_OK" != "true" ]; then
        echo "error: merge did not complete for repo $REPO_NUM" >&2
        exit 12
    fi

    # Step 3: push (only if origin exists, and only when we actually merged).
    # NO state write, NO cleanup. push failure is non-blocking (design 02-D2-3).
    if [ "$HAS_ORIGIN" = "true" ] && [ "$STATUS" != "already-merged" ]; then
        if ! git -C "$MAIN_REPO" push origin "$BASE_BRANCH" >/dev/null 2>&1; then
            echo "warning: push of $BASE_BRANCH failed for repo $REPO_NUM; merge already done; you can retry by re-running this script" >&2
            STATUS="push-failed"
            ANY_PUSH_FAILED="true"
        fi
    fi

    RESULT_STATUS+=("$STATUS")
    RESULT_PRURL+=("$PR_URL")
    RESULT_GHFB+=("$GH_FALLBACK")
    loop_i=$((loop_i + 1))
done

# ---------------------------------------------------------------------------
# stdout: all repos merged (some possibly already-merged). Emit per-repo keys.
# ---------------------------------------------------------------------------
emit_results

if [ "$ANY_PUSH_FAILED" = "true" ]; then
    exit 13
fi

exit 0
