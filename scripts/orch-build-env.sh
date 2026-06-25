#!/usr/bin/env bash
#
# orch-build-env.sh — print ONE shell snippet that injects Go build I/O
# optimization into a worker's tmux pane (GOTMPDIR on a tmpfs RAM disk +
# GOFLAGS=-p=N to cap per-build compile concurrency). Side-effect-free: it
# reads three host env vars and writes a single line to stdout (empty when
# disabled). It NEVER touches tmux — spawn / reuse call it and send-keys the
# line into the new pane themselves.
#
# Why: total compile parallelism across the host ≈ (worker count) × (each
# `go build`'s `-p`, default ≈ NumCPU). With many parallel workers all writing
# link intermediates to the same disk, a single nvme gets saturated (the I/O
# incident this feature addresses). Steering each build's intermediates to a
# RAM disk and lowering per-build `-p` defuses the second-order blow-up without
# capping worker count.
#
# Contract:
#   Inputs (host env, all optional):
#     ZYZ_GO_BUILD_OPT   master switch. Default ON. Lowercased value in
#                        {0,false,off,no} => print nothing, exit 0.
#     ZYZ_GO_BUILD_P     the N in GOFLAGS=-p=N. Must match ^[1-9][0-9]*$ AND
#                        be <= 64; anything else falls back to 4. The <= 64
#                        clamp exists because `-p` is the one knob that can
#                        silently re-detonate the incident (total = workers × p):
#                        an accidental -p=999 would explode link concurrency
#                        again, so absurd values are rejected, not trusted.
#     ZYZ_GO_TMPFS_DIR   tmpfs base dir candidate. Default /dev/shm. A value
#                        containing a single quote is ignored (it would break
#                        the single-quote wrapping in the emitted snippet) and
#                        falls back to /dev/shm.
#
#   Output (stdout): exactly one line (or empty when disabled):
#     { [ -z "${GOTMPDIR:-}" ] && [ -d '<BASE>' ] && [ -w '<BASE>' ] && mkdir -p '<BASE>/zyz-gobuild' 2>/dev/null && export GOTMPDIR='<BASE>/zyz-gobuild'; }; { [ -z "${GOFLAGS:-}" ] && export GOFLAGS='-p=<P>'; }; true
#
#   The host bakes <BASE> and <P> as literals, but the GUARDS run in the pane:
#     - `[ -z "${GOTMPDIR:-}" ]` / `[ -z "${GOFLAGS:-}" ]` are the SOLE
#       no-clobber authority. Any value the pane inherited (including a user's
#       host-side `export GOTMPDIR=...` before starting the orchestrator) always
#       wins; the baked literal is only a candidate.
#     - `[ -d '<BASE>' ] && [ -w '<BASE>' ]` is an existence+writable probe, NOT
#       a filesystem-type check. It auto-degrades on hosts without tmpfs (macOS
#       has no /dev/shm => GOTMPDIR is skipped, GOFLAGS still set). Footgun:
#       pointing ZYZ_GO_TMPFS_DIR at a plain disk dir probes true and writes to
#       disk — documented, user's own risk.
#     - `mkdir -p` because Go does NOT auto-create GOTMPDIR (and /dev/shm is
#       wiped on reboot). On failure the `&&` chain breaks and nothing exports.
#     - GOCACHE and GOMAXPROCS are NEVER emitted (GOCACHE stays on disk for
#       cross-build reuse; GOMAXPROCS is left untouched on purpose).
#     - Trailing `; true` keeps the pane's exit status clean after send-keys.
#
#   Exit codes:
#     0  always (disabled => empty stdout, exit 0; enabled => snippet, exit 0)
#
set -euo pipefail

# ─── Master switch ────────────────────────────────────────────────────────────
# Default ON. Off only for an explicit falsey value (case-insensitive).
OPT_RAW="${ZYZ_GO_BUILD_OPT:-}"
OPT_LC="$(printf '%s' "$OPT_RAW" | tr '[:upper:]' '[:lower:]')"
case "$OPT_LC" in
    0|false|off|no)
        exit 0
        ;;
esac

# ─── -p value (clamped) ───────────────────────────────────────────────────────
# Valid = positive integer with no leading zero AND <= 64; else fall back to 4.
P_VALUE="4"
P_RAW="${ZYZ_GO_BUILD_P:-}"
if printf '%s' "$P_RAW" | grep -Eq '^[1-9][0-9]*$' && [ "$P_RAW" -le 64 ]; then
    P_VALUE="$P_RAW"
fi

# ─── tmpfs base dir candidate ─────────────────────────────────────────────────
# Default /dev/shm. Reject a value containing a single quote (it would break the
# single-quote wrapping in the emitted snippet) and fall back to the default.
BASE_DIR="${ZYZ_GO_TMPFS_DIR:-/dev/shm}"
case "$BASE_DIR" in
    *\'*) BASE_DIR="/dev/shm" ;;
esac

# ─── Emit the one-line snippet ────────────────────────────────────────────────
# Baked literals (<BASE>, <P>); runtime guards executed in the pane.
printf "%s\n" "{ [ -z \"\${GOTMPDIR:-}\" ] && [ -d '${BASE_DIR}' ] && [ -w '${BASE_DIR}' ] && mkdir -p '${BASE_DIR}/zyz-gobuild' 2>/dev/null && export GOTMPDIR='${BASE_DIR}/zyz-gobuild'; }; { [ -z \"\${GOFLAGS:-}\" ] && export GOFLAGS='-p=${P_VALUE}'; }; true"
