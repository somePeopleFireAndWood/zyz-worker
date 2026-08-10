#!/usr/bin/env bash
#
# orch-check-worker.sh — inspect a single worker's runtime state.
#
# Contract:
#   Inputs:
#     $1  <task-id>          must match [A-Za-z0-9_-]+
#     $2  <list-dir>         master list directory
#
#   Side effects:
#     Mostly read-only. The ONE write path: when a dispatch.md is present in the
#     worker's runtime dir, this helper lazily populates its Phase-2 frontmatter
#     fields (claude-pid, claude-session-id, transcript-path, first-seen-iso) and
#     regenerates the `## Recovery` body once claude has bound. The rewrite is
#     atomic (tmpfile + rename) and idempotent: a non-empty stored Phase-2 field
#     is never overwritten. When no dispatch.md exists (pre-feature workers), the
#     bind block is skipped entirely and the helper stays read-only.
#
#   Output (stdout):
#     Multi-line key=value report. Always emits the following keys:
#       session-alive=true|false
#       heartbeat-status=fresh|suspect|stale|missing
#       heartbeat-mtime=<iso-or-empty>
#       phase=<value-or-empty>
#       phase-since=<iso-or-empty>
#       wait-state=<value-or-empty>
#       waiting-reason=<value-or-empty>
#       expected-resume-by=<iso-or-empty>
#       dispatch-bound=true|false|<empty>
#         empty => dispatch.md absent (pre-feature worker / spawn crashed pre-write)
#         false => dispatch.md present but the Phase-2 trio is not all populated
#         true  => dispatch.md present and claude-pid + claude-session-id +
#                  transcript-path are all populated (worker is bound)
#
#     worker-status-malformed=true
#         Emitted ONLY when worker-status.md exists but carries no `---` fence
#         (a bare field dump the frontmatter parser reads as all-empty). Absent
#         otherwise — do not expect a `=false` form. Distinguishes "fence-less
#         file" from "genuinely empty"; the orchestrator treats it as the
#         malformed-worker-status case (cadence branch `unknown-investigate`).
#
#   Heartbeat thresholds:
#     Base threshold S = max(per-task `heartbeat-stale-sec` frontmatter,
#                            $ZYZ_HEARTBEAT_STALE_SEC, default 300).
#     If wait-state=waiting-user → threshold = max(S, $ZYZ_HEARTBEAT_WAITING_USER_SEC, 900).
#     Both env knobs are validated; a non-numeric value falls back to its default
#     rather than aborting (a bare arithmetic use would exit 1 under `set -u`).
#     fresh   : age <= threshold
#     suspect : threshold < age <= 3 * threshold
#     stale   : age > 3 * threshold
#     missing : the heartbeat file does not exist, OR its mtime could not be read
#               (neither `stat -c %Y` nor `stat -f %m` worked on this host)
#
#   Exit codes:
#     0  always when arguments parse (including worker dead — that is a legal report)
#     2  argument error / invalid task-id
#     3  missing required dependency (`tmux`)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_ADAPTER="$SCRIPT_DIR/orch-agent-runtime.sh"

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

# Dependency: tmux.
if ! command -v tmux >/dev/null 2>&1; then
    echo "error: missing dependency: tmux" >&2
    exit 3
fi

MASTER_ENTRY="$LIST_DIR/tasks/$TASK_ID.md"
RUNTIME_DIR="$LIST_DIR/runtime/$TASK_ID"
WORKER_STATUS_FILE="$RUNTIME_DIR/worker-status.md"
HEARTBEAT_FILE="$RUNTIME_DIR/heartbeat"
DISPATCH_FILE="$RUNTIME_DIR/dispatch.md"

# Extract a frontmatter field. Same logic as orch-scan-tasks.sh.
fm_field() {
    local file="$1"
    local key="$2"
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

# Atomically rewrite dispatch.md, preserving Phase-1 frontmatter verbatim and
# emitting the (possibly freshly-discovered) Phase-2 values + a regenerated body.
#
#   $1  dispatch file path
#   $2  agent-pid           (in-memory value)
#   $3  agent-session-id    (in-memory value)
#   $4  transcript-path     (in-memory value)
#   $5  first-seen-iso      (in-memory value)
#
# The body is ALWAYS regenerated from the current in-memory state (no
# preserve-verbatim branch): a placeholder while the trio is incomplete, the
# concrete `## Recovery` commands once the trio is complete. The complete-trio
# body is reuse-aware (three-way): plain spawn (reuse-from empty) and independent
# reuse sessions (reuse-claude-effective in {false, n/a}) get attach + --resume;
# a same-claude reuse (reuse-from set AND reuse-claude-effective=true) gets an
# ATTACH-ONLY body (the session-id is the shared old+new session — resuming it
# independently is a footgun). All <…> tokens in the recovery block are
# substituted with real values at generation time, so the rendered body contains
# no angle brackets. Phase-1 keys (INCLUDING the four reuse fields reuse-from /
# reuse-scope / reuse-claude-effective / heartbeat-window-id AND the multi-repo
# numbered field group worktree-N / source-repo-N / branch-N / base-N, all of
# which would otherwise be dropped by this fixed-field-list rewrite) are read
# back via fm_field BEFORE the unquoted heredoc (fm_field can't run inside it
# cleanly).
rewrite_dispatch_atomic() {
    local file="$1"
    local r_agent_pid="$2"
    local r_agent_sid="$3"
    local r_transcript="$4"
    local r_first_seen="$5"

    # Phase-1 frontmatter — read back verbatim from the existing file.
    local p1_task_id p1_spawn_iso p1_tmux_session p1_tmux_window p1_tmux_pane
    local p1_shell_pid p1_worktree p1_source_repo p1_branch p1_base
    local p1_plugin_root p1_encoded_cwd p1_agent_runtime p1_worker_runtime
    local p1_reuse_from p1_reuse_scope p1_reuse_agent_eff p1_heartbeat_window
    p1_task_id="$(fm_field "$file" task-id)"
    p1_spawn_iso="$(fm_field "$file" spawn-iso)"
    p1_tmux_session="$(fm_field "$file" tmux-session)"
    p1_tmux_window="$(fm_field "$file" tmux-window-id)"
    p1_tmux_pane="$(fm_field "$file" tmux-pane-id)"
    p1_shell_pid="$(fm_field "$file" shell-pid)"
    p1_worktree="$(fm_field "$file" worktree)"
    p1_source_repo="$(fm_field "$file" source-repo)"
    p1_branch="$(fm_field "$file" branch)"
    p1_base="$(fm_field "$file" base)"
    p1_plugin_root="$(fm_field "$file" plugin-root)"
    p1_encoded_cwd="$(fm_field "$file" encoded-cwd)"
    p1_agent_runtime="$(fm_field "$file" agent-runtime)"
    [ -z "$p1_agent_runtime" ] && p1_agent_runtime="claude"
    p1_worker_runtime="$(fm_field "$file" worker-runtime-args)"
    # Reuse fields (Phase-1; written by orch-reuse-worker.sh, empty for plain
    # spawn). These MUST be read back and re-emitted here, otherwise the first
    # Phase-2 poll that triggers a rewrite would DROP them — this function is the
    # one and only fixed-field-list rewriter of dispatch.md.
    p1_reuse_from="$(fm_field "$file" reuse-from)"
    p1_reuse_scope="$(fm_field "$file" reuse-scope)"
    p1_reuse_agent_eff="$(fm_field "$file" reuse-agent-effective)"
    [ -z "$p1_reuse_agent_eff" ] && p1_reuse_agent_eff="$(fm_field "$file" reuse-claude-effective)"
    p1_heartbeat_window="$(fm_field "$file" heartbeat-window-id)"
    # MCP inheritance snapshot (issue #2; written by spawn/reuse). Read back and
    # re-emitted for the same reason as the reuse fields: this fixed-field-list
    # rewriter would otherwise DROP it on the first Phase-2 poll — and the
    # recovery `--resume` command below embeds it, so losing it would make a
    # resumed worker silently re-inherit the host's full mcpServers.
    local p1_worker_mcp
    p1_worker_mcp="$(fm_field "$file" worker-mcp-args)"
    [ -z "$p1_worker_runtime" ] && p1_worker_runtime="$p1_worker_mcp"

    # Multi-repo numbered field group (worktree-N / source-repo-N / branch-N /
    # base-N, written by spawn for REPO_COUNT>=2). Like the reuse fields above,
    # these are unknown to this fixed-field-list rewriter and would be silently
    # DROPPED on the first Phase-2 rewrite unless read back and re-emitted here.
    # Accumulated into ONE variable BEFORE the heredoc (the heredoc cannot loop);
    # it carries a LEADING newline and no trailing newline so it splices directly
    # after the `base:` scalar. Single-repo dispatch.md has no source-repo-2, so
    # the loop never runs, the variable stays empty, and the rewrite is
    # byte-identical to the legacy layout.
    local p1_numbered p1_worktrees ni nwt nsr nbr nba
    p1_numbered=""
    p1_worktrees="$p1_worktree"
    ni=2
    while :; do
        nsr="$(fm_field "$file" "source-repo-$ni")"
        [ -n "$nsr" ] || break
        nwt="$(fm_field "$file" "worktree-$ni")"
        nbr="$(fm_field "$file" "branch-$ni")"
        nba="$(fm_field "$file" "base-$ni")"
        p1_numbered="${p1_numbered}
worktree-$ni: $nwt
source-repo-$ni: $nsr
branch-$ni: $nbr
base-$ni: $nba"
        p1_worktrees="$p1_worktrees:$nwt"
        ni=$((ni + 1))
    done

    # Body — pure function of trio-completeness AND the stored reuse fields.
    # Three-way once the trio is complete (CC1; conditions read the stored
    # reuse-from / reuse-claude-effective above, NOT any in-memory Phase-2 state):
    #   reuse-from empty                          -> attach + --resume (plain spawn)
    #   reuse-from set AND reuse-claude-eff=true   -> ATTACH-ONLY (shared session;
    #                                                 no independent --resume)
    #   reuse-from set AND reuse-claude-eff in
    #     {false, n/a}                             -> attach + --resume (independent
    #                                                 session, same as plain spawn)
    local body resume_command
    if [ -n "$r_agent_pid" ] && [ -n "$r_agent_sid" ] && [ -n "$r_transcript" ]; then
        if [ -n "$p1_reuse_from" ] && [ "$p1_reuse_agent_eff" = "true" ]; then
            local shared_resume_warning
            if [ "$p1_agent_runtime" = "claude" ]; then
                shared_resume_warning="Do NOT run an independent \`claude --resume\` for this task"
            else
                shared_resume_warning="Do NOT independently resume this task"
            fi
            body="This worker REUSES a shared $p1_agent_runtime session from task \`$p1_reuse_from\` (reuse-scope=$p1_reuse_scope, same agent process). Its \`agent-session-id\` \`$r_agent_sid\` is the SHARED (old+new merged) session. Recovery:

- ONLY \`tmux attach -t $p1_tmux_session\` while the session is alive.
- $shared_resume_warning — resuming the shared session-id from two dispatch.md files is a known footgun.
- Transcript file (for read-only inspection): \`$r_transcript\`

Discovered at $r_first_seen."
        else
            resume_command="$("$RUNTIME_ADAPTER" resume-command "$p1_agent_runtime" "$p1_plugin_root" "$p1_worktree" "$r_agent_sid" "$p1_worker_runtime" "$p1_worktrees")"
            body="This worker is bound to $p1_agent_runtime session \`$r_agent_sid\`. Recovery commands:

- If tmux session \`$p1_tmux_session\` is still alive: \`tmux attach -t $p1_tmux_session\`
- If tmux is dead but the transcript exists: \`$resume_command\`
- Transcript file (for read-only inspection): \`$r_transcript\`

Discovered at $r_first_seen."
        fi
    else
        body="(awaiting $p1_agent_runtime startup; orch-check-worker.sh populates this after the runtime has registered a persisted session)"
    fi

    local tmp="$file.tmp.$$"
    cat > "$tmp" <<EOF
---
task-id: $p1_task_id
spawn-iso: $p1_spawn_iso
tmux-session: $p1_tmux_session
tmux-window-id: $p1_tmux_window
tmux-pane-id: $p1_tmux_pane
shell-pid: $p1_shell_pid
worktree: $p1_worktree
source-repo: $p1_source_repo
branch: $p1_branch
base: $p1_base$p1_numbered
plugin-root: $p1_plugin_root
encoded-cwd: $p1_encoded_cwd
agent-runtime: $p1_agent_runtime
worker-runtime-args: $p1_worker_runtime
worker-mcp-args: $p1_worker_mcp
reuse-from: $p1_reuse_from
reuse-scope: $p1_reuse_scope
reuse-agent-effective: $p1_reuse_agent_eff
reuse-claude-effective: $p1_reuse_agent_eff
heartbeat-window-id: $p1_heartbeat_window
agent-pid: $r_agent_pid
agent-session-id: $r_agent_sid
claude-pid: $r_agent_pid
claude-session-id: $r_agent_sid
transcript-path: $r_transcript
first-seen-iso: $r_first_seen
---

# Dispatch Info

## Recovery

$body
EOF
    mv -f "$tmp" "$file"
}

# Determine tmux session name. A reuse dispatch can point at another task's
# session, so dispatch is authoritative, then master entry, then convention.
TMUX_SESSION="$(fm_field "$DISPATCH_FILE" tmux-session)"
[ -z "$TMUX_SESSION" ] && TMUX_SESSION="$(fm_field "$MASTER_ENTRY" tmux-session)"
if [ -z "$TMUX_SESSION" ]; then
    TMUX_SESSION="zyz-task-$TASK_ID"
fi

# session-alive check.
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    SESSION_ALIVE="true"
else
    SESSION_ALIVE="false"
fi

# Worker-status fields.
PHASE="$(fm_field "$WORKER_STATUS_FILE" phase)"
PHASE_SINCE="$(fm_field "$WORKER_STATUS_FILE" phase-since)"
WAIT_STATE="$(fm_field "$WORKER_STATUS_FILE" wait-state)"
WAITING_REASON="$(fm_field "$WORKER_STATUS_FILE" waiting-reason)"
EXPECTED_RESUME_BY="$(fm_field "$WORKER_STATUS_FILE" expected-resume-by)"

# Compute the heartbeat threshold.
#
# Both env knobs are validated the same way the per-task frontmatter override
# below is. An unvalidated non-numeric value reaches an arithmetic context
# (`THRESHOLD * 3`), where bash under `set -u` treats the string as a variable
# NAME and aborts with "unbound variable" — exit 1, which this script's contract
# does not define and the orchestrator has no branch for. Since L1 polls every
# active worker through this helper on every tick, one typo'd env var would
# silently blind the whole poll loop. Malformed values fall back to the default.
BASE_THRESHOLD="${ZYZ_HEARTBEAT_STALE_SEC:-300}"
case "$BASE_THRESHOLD" in
    ''|*[!0-9]*) BASE_THRESHOLD=300 ;;
esac
PER_TASK_THRESHOLD="$(fm_field "$MASTER_ENTRY" heartbeat-stale-sec)"
if [ -n "$PER_TASK_THRESHOLD" ]; then
    case "$PER_TASK_THRESHOLD" in
        ''|*[!0-9]*) ;;  # ignore malformed
        *)
            if [ "$PER_TASK_THRESHOLD" -gt "$BASE_THRESHOLD" ]; then
                BASE_THRESHOLD="$PER_TASK_THRESHOLD"
            fi
            ;;
    esac
fi

# Widen for waiting-user.
THRESHOLD="$BASE_THRESHOLD"
if [ "$WAIT_STATE" = "waiting-user" ]; then
    WIDE="${ZYZ_HEARTBEAT_WAITING_USER_SEC:-900}"
    case "$WIDE" in
        ''|*[!0-9]*) WIDE=900 ;;
    esac
    if [ "$WIDE" -gt "$THRESHOLD" ]; then
        THRESHOLD="$WIDE"
    fi
fi

# Heartbeat status.
HEARTBEAT_STATUS="missing"
HEARTBEAT_MTIME=""

if [ -f "$HEARTBEAT_FILE" ] && [ -r "$HEARTBEAT_FILE" ]; then
    # mtime in epoch seconds. Try GNU `stat -c %Y` then BSD `stat -f %m`.
    if mtime_epoch="$(stat -c %Y "$HEARTBEAT_FILE" 2>/dev/null)"; then
        :
    elif mtime_epoch="$(stat -f %m "$HEARTBEAT_FILE" 2>/dev/null)"; then
        :
    else
        mtime_epoch=""
    fi

    if [ -n "$mtime_epoch" ]; then
        now_epoch="$(date +%s)"
        age=$(( now_epoch - mtime_epoch ))
        if [ "$age" -lt 0 ]; then
            age=0
        fi
        triple=$(( THRESHOLD * 3 ))
        if [ "$age" -le "$THRESHOLD" ]; then
            HEARTBEAT_STATUS="fresh"
        elif [ "$age" -le "$triple" ]; then
            HEARTBEAT_STATUS="suspect"
        else
            HEARTBEAT_STATUS="stale"
        fi

        # Format the mtime as ISO timestamp. Use GNU `date -d @epoch` or BSD `date -r epoch`.
        if iso="$(date -d "@$mtime_epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null)"; then
            HEARTBEAT_MTIME="$iso"
        elif iso="$(date -r "$mtime_epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null)"; then
            HEARTBEAT_MTIME="$iso"
        else
            HEARTBEAT_MTIME=""
        fi
    fi
fi

# Phase-2 lazy fill — dispatch.md.
#
# DISPATCH_BOUND is initialized OUTSIDE the file-existence gate so the stdout key
# always has a well-defined value:
#   ""     => dispatch.md absent (pre-feature worker, or spawn crashed pre-write)
#   false  => dispatch.md present, the Phase-2 trio is NOT all populated
#   true   => dispatch.md present, the trio is all populated
#
# Backwards compat: when dispatch.md is absent, the entire block is skipped and
# DISPATCH_BOUND stays "". The helper performs no writes in that case.
DISPATCH_BOUND=""

if [ -f "$DISPATCH_FILE" ]; then
    DISPATCH_BOUND="false"   # present-but-incomplete default; flipped at Step D.

    # Read all current values from dispatch.md.
    AGENT_RUNTIME="$(fm_field "$DISPATCH_FILE" agent-runtime)"
    [ -z "$AGENT_RUNTIME" ] && AGENT_RUNTIME="claude"
    if [ "$AGENT_RUNTIME" = "claude" ]; then
        AGENT_PID="$(fm_field "$DISPATCH_FILE" claude-pid)"
        AGENT_SID="$(fm_field "$DISPATCH_FILE" claude-session-id)"
    else
        AGENT_PID="$(fm_field "$DISPATCH_FILE" agent-pid)"
        AGENT_SID="$(fm_field "$DISPATCH_FILE" agent-session-id)"
    fi
    TRANSCRIPT="$(fm_field "$DISPATCH_FILE" transcript-path)"
    FIRST_SEEN="$(fm_field "$DISPATCH_FILE" first-seen-iso)"
    DISPATCH_SHELL_PID="$(fm_field "$DISPATCH_FILE" shell-pid)"
    DISPATCH_WORKTREE="$(fm_field "$DISPATCH_FILE" worktree)"
    DISPATCH_SPAWN_ISO="$(fm_field "$DISPATCH_FILE" spawn-iso)"
    # encoded-cwd is preserved verbatim into the rewrite (rewrite_dispatch_atomic
    # re-reads it directly from the file via fm_field). It is no longer used for
    # transcript discovery — Step C finds the JSONL by session-id — so it is not
    # read into a local here.

    NEEDS_REWRITE="false"

    # Step A: discover the selected runtime's newest direct child of the pane.
    PROCESS_NAME="$("$RUNTIME_ADAPTER" process-name "$AGENT_RUNTIME")"
    if [ -z "$AGENT_PID" ] && [ -n "$DISPATCH_SHELL_PID" ]; then
        CANDIDATE="$(pgrep -P "$DISPATCH_SHELL_PID" -n -x "$PROCESS_NAME" 2>/dev/null || true)"
        if [ -n "$CANDIDATE" ]; then
            AGENT_PID="$CANDIDATE"
            NEEDS_REWRITE="true"
        fi
    fi

    # Steps B/C: runtime-specific persisted-session discovery. Claude resolves
    # its PID pointer then project transcript; Codex scans rollout session_meta
    # records matching this physical worktree and spawn time.
    if [ -n "$AGENT_PID" ] && { [ -z "$AGENT_SID" ] || [ -z "$TRANSCRIPT" ]; }; then
        CAND_SESSION="$("$RUNTIME_ADAPTER" discover-session "$AGENT_RUNTIME" "$AGENT_PID" "$DISPATCH_WORKTREE" "$DISPATCH_SPAWN_ISO" 2>/dev/null || true)"
        CAND_SID="${CAND_SESSION%%$'\t'*}"
        if [[ "$CAND_SESSION" == *$'\t'* ]]; then CAND_TRANSCRIPT="${CAND_SESSION#*$'\t'}"; else CAND_TRANSCRIPT=""; fi
        if [ -n "$CAND_SID" ] && { [ -z "$AGENT_SID" ] || [ "$AGENT_SID" = "$CAND_SID" ]; }; then
            if [ -z "$AGENT_SID" ]; then AGENT_SID="$CAND_SID"; NEEDS_REWRITE="true"; fi
            if [ -z "$TRANSCRIPT" ] && [ -n "$CAND_TRANSCRIPT" ] && [ -f "$CAND_TRANSCRIPT" ]; then
                TRANSCRIPT="$CAND_TRANSCRIPT"
                NEEDS_REWRITE="true"
            fi
        fi
    fi

    # Step D: bind on the generic pid + session-id + transcript trio.
    # first-seen-iso is stamped only the first time the trio completes.
    NEWLY_BOUND="false"
    if [ -n "$AGENT_PID" ] && [ -n "$AGENT_SID" ] && [ -n "$TRANSCRIPT" ]; then
        DISPATCH_BOUND="true"
        if [ -z "$FIRST_SEEN" ]; then
            FIRST_SEEN="$(date +%Y-%m-%dT%H:%M:%S%z)"
            NEWLY_BOUND="true"
            NEEDS_REWRITE="true"
        fi
    fi

    if [ "$NEEDS_REWRITE" = "true" ]; then
        rewrite_dispatch_atomic "$DISPATCH_FILE" \
            "$AGENT_PID" "$AGENT_SID" "$TRANSCRIPT" "$FIRST_SEEN"
    fi
fi

printf 'session-alive=%s\n' "$SESSION_ALIVE"
printf 'heartbeat-status=%s\n' "$HEARTBEAT_STATUS"
printf 'heartbeat-mtime=%s\n' "$HEARTBEAT_MTIME"
printf 'phase=%s\n' "$PHASE"
printf 'phase-since=%s\n' "$PHASE_SINCE"
printf 'wait-state=%s\n' "$WAIT_STATE"
printf 'waiting-reason=%s\n' "$WAITING_REASON"
printf 'expected-resume-by=%s\n' "$EXPECTED_RESUME_BY"
printf 'dispatch-bound=%s\n' "$DISPATCH_BOUND"
[ -f "$DISPATCH_FILE" ] && printf 'agent-runtime=%s\n' "${AGENT_RUNTIME:-claude}"

# Malformed-frontmatter guard: a worker-status.md that exists but has no `---`
# fence is a bare field dump that fm_field cannot parse (all fields read empty).
# Emit an explicit marker so the orchestrator can diagnose "fence-less file" vs
# "genuinely empty". Read-only; no output when the file is absent or well-formed.
if [ -f "$WORKER_STATUS_FILE" ] && ! grep -qE '^---[[:space:]]*$' "$WORKER_STATUS_FILE"; then
    echo "worker-status-malformed=true"
fi

exit 0
