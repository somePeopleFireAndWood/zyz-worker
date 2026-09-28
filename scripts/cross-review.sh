#!/usr/bin/env bash
#
# cross-review.sh — run a read-only review session in every OTHER agent
# harness installed on this machine, alongside the task's own reviewAgent
# subagent. If the execute-task main agent runs in Claude Code and `codex` is
# installed, this launches a `codex exec` review; if it runs in Codex and
# `claude` is installed, it launches a `claude -p` review. The host's own
# harness is never re-launched (that is what the reviewAgent subagent is).
#
# Why: a reviewer from a different product has different blind spots. Its
# report is ADVISORY — the execute-task workflow verifies every cross-harness
# finding independently before accepting it and may reject any of them with a
# recorded reason (see skills/execute-task/SKILL.md `## Cross-Harness Review`).
# This script only launches the sessions and captures their reports; it never
# adjudicates anything.
#
# Contract:
#   cross-review.sh detect
#     stdout: `host=<claude|codex>` and `reviewers=<space-separated list>`
#             (empty list = no other harness available, or disabled).
#   cross-review.sh run --task-dir <dir> --kind <design|implementation|aggregate>
#                       --brief <file> [--label <label>] [--cwd <dir>]
#     Launches every selected reviewer CONCURRENTLY and waits for all of them.
#     Per reviewer, under <task-dir>/reviews/cross/:
#       <label>.<harness>.md          the reviewer's final report (captured)
#       <label>.<harness>.jsonl       full event stream (for a lost/empty report)
#       <label>.<harness>.stderr      reviewer stderr
#       <label>.<harness>.prompt.md   the exact prompt sent
#       <label>.<harness>.meta        key=value bookkeeping (status, rc, tree
#                                     fingerprint at start/end)
#     stdout, one line per reviewer:
#       cross-review harness=<h> status=<ok|empty|failed|timeout> rc=<n> tree-stable=<yes|no|n/a> report=<path> meta=<path>
#     or, when nothing runs:
#       cross-review status=none host=<h> reason=<text>
#     Exit: 0 whenever the arguments were valid (a failed/timed-out reviewer is
#     reported on stdout, never as a script failure — cross-harness review is
#     optional and must not block the workflow); 2 on a usage error.
#
#   Env (all optional):
#     ZYZ_CROSS_REVIEW          auto (default: every installed non-host harness)
#                               | off | explicit list, e.g. `codex` (comma or
#                               space separated; host and unknown/uninstalled
#                               names are dropped with a warning)
#     ZYZ_AGENT_RUNTIME         host override (claude|codex), same knob the
#                               orchestration adapter uses for detection
#     ZYZ_CROSS_REVIEW_TIMEOUT  seconds per reviewer, default 2400
#     ZYZ_CROSS_REVIEW_MCP      MCP inheritance for the reviewer session, same
#                               values as ZYZ_WORKER_MCP; default none (zero
#                               MCP servers — review is code reading)
#     ZYZ_CROSS_REVIEW_CODEX_ARGS / ZYZ_CROSS_REVIEW_CLAUDE_ARGS
#                               extra CLI args (word-split), e.g. `-m <model>`
#
# Isolation of the reviewer session:
#   - read-only: Codex runs with `-s read-only`; Claude runs with
#     `--permission-mode dontAsk` and an allowlist of read/search tools plus
#     read-only git commands, with every editing tool disallowed.
#   - every ZYZ_* variable is scrubbed and ZYZ_HOOKS_DISABLE=1 is set, so the
#     plugin's own hooks (installed in both harnesses) stay inert in the child
#     and it never writes this task's heartbeat, status, or worker-status file.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPT_TEMPLATE="$PLUGIN_ROOT/skills/execute-task/templates/cross-review-prompt.md"
KNOWN_HARNESSES="claude codex"

usage() {
    cat >&2 <<'EOF'
Usage:
  cross-review.sh detect
  cross-review.sh run --task-dir <dir> --kind <design|implementation|aggregate> --brief <file> [--label <label>] [--cwd <dir>]
EOF
}

detect_host() {
    local host
    host="$("$SCRIPT_DIR/orch-agent-runtime.sh" detect 2>/dev/null || true)"
    case "$host" in
        claude|codex) printf '%s\n' "$host" ;;
        *) printf 'claude\n' ;;
    esac
}

# select_reviewers <host> — print the reviewer list (space separated).
select_reviewers() {
    local host="$1" policy="${ZYZ_CROSS_REVIEW:-auto}" wanted h out="" explicit=1
    case "$policy" in
        off|OFF|0|false|no|none) printf '\n'; return 0 ;;
        auto|AUTO) wanted="$KNOWN_HARNESSES"; explicit=0 ;;
        *) wanted="$(printf '%s' "$policy" | tr ',' ' ')" ;;
    esac
    for h in $wanted; do
        case " $KNOWN_HARNESSES " in
            *" $h "*) ;;
            *) echo "warning: unknown cross-review harness '$h' ignored" >&2; continue ;;
        esac
        # The host's own review is the reviewAgent subagent; only an explicit
        # request for it deserves a warning.
        if [ "$h" = "$host" ]; then
            [ "$explicit" -eq 0 ] || echo "warning: '$h' is the host harness (reviewed by the reviewAgent subagent) — skipped" >&2
            continue
        fi
        if ! command -v "$h" >/dev/null 2>&1; then
            [ "$explicit" -eq 0 ] || echo "warning: cross-review harness '$h' is not installed — skipped" >&2
            continue
        fi
        case " $out " in *" $h "*) continue ;; esac
        out="${out:+$out }$h"
    done
    printf '%s\n' "$out"
}

sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

# tree_fingerprint <dir> — hash of the working tree's uncommitted state
# (tracked diff vs HEAD + untracked non-ignored files), excluding the
# `.zyz-worker/` task artifacts that the workflow itself keeps writing.
# Prints `n/a` outside a git work tree.
tree_fingerprint() {
    local dir="$1"
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf 'n/a\n'; return 0; }
    {
        git -C "$dir" rev-parse HEAD 2>/dev/null
        git -C "$dir" diff HEAD --binary -- . ':(exclude).zyz-worker' 2>/dev/null
        git -C "$dir" ls-files -o --exclude-standard -z -- . ':(exclude).zyz-worker' 2>/dev/null |
            while IFS= read -r -d '' f; do
                printf '%s\n' "$f"
                [ -f "$dir/$f" ] && cat "$dir/$f"
            done
    } | sha256_stdin
}

# scrubbed_env_prefix — print (NUL-separated) an `env` argv prefix that
# unsets every ZYZ_* variable and disables the plugin hooks in the child.
scrubbed_env_prefix() {
    local name
    printf 'env\0'
    for name in $(env | sed -n 's/^\(ZYZ_[A-Za-z0-9_]*\)=.*/\1/p'); do
        printf -- '-u\0%s\0' "$name"
    done
    printf 'ZYZ_HOOKS_DISABLE=1\0'
}

# mcp_args <harness> — print the MCP-isolation args (NUL-separated).
mcp_args() {
    local harness="$1" line
    line="$(ZYZ_WORKER_MCP="${ZYZ_CROSS_REVIEW_MCP:-none}" "$SCRIPT_DIR/orch-worker-mcp-args.sh" "$harness" 2>/dev/null)" || {
        # Fail closed for Claude; for Codex a missing override list only means
        # the reviewer inherits the user's MCP servers, which costs memory,
        # not safety (the session is read-only either way).
        [ "$harness" = "claude" ] && printf -- '--strict-mcp-config\0'
        return 0
    }
    [ -n "$line" ] || return 0
    # The helper prints a shell-quoted fragment (server names are validated
    # to [A-Za-z0-9_-]); re-split it the way a shell would.
    local -a parts
    eval "parts=($line)"
    [ "${#parts[@]}" -gt 0 ] && printf '%s\0' "${parts[@]}"
    return 0
}

render_prompt() {
    local harness="$1" host="$2" kind="$3" cwd="$4" task_dir="$5" brief="$6" tpl
    tpl="$(cat "$PROMPT_TEMPLATE")"
    tpl="${tpl//\{\{HARNESS\}\}/$harness}"
    tpl="${tpl//\{\{HOST\}\}/$host}"
    tpl="${tpl//\{\{KIND\}\}/$kind}"
    tpl="${tpl//\{\{CWD\}\}/$cwd}"
    tpl="${tpl//\{\{TASK_DIR\}\}/$task_dir}"
    tpl="${tpl//\{\{PLUGIN_ROOT\}\}/$PLUGIN_ROOT}"
    printf '%s\n\n' "$tpl"
    cat "$brief"
    printf '\n'
}

# extract_claude_result <jsonl> — print the final `result` text of a Claude
# stream-json run; fall back to the concatenated assistant text blocks.
extract_claude_result() {
    python3 - "$1" <<'PY' 2>/dev/null
import json, sys
result, texts = None, []
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        ev = json.loads(raw)
    except Exception:
        continue
    if ev.get("type") == "result" and isinstance(ev.get("result"), str):
        result = ev["result"]
    elif ev.get("type") == "assistant":
        for block in (ev.get("message") or {}).get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text":
                texts.append(block.get("text") or "")
if result and result.strip():
    sys.stdout.write(result)
elif texts:
    sys.stdout.write("\n\n".join(texts))
PY
}

# build_cmd <harness> <cwd> <task-dir> <report> <with-mcp:1|0> — print the
# reviewer argv (NUL-separated).
build_cmd() {
    local harness="$1" cwd="$2" task_dir="$3" report="$4" with_mcp="$5" x
    local -a mcp extra
    mcp=(); extra=()
    if [ "$with_mcp" = "1" ]; then
        while IFS= read -r -d '' x; do mcp+=("$x"); done < <(mcp_args "$harness")
    fi
    case "$harness" in
        codex)
            # shellcheck disable=SC2206
            [ -n "${ZYZ_CROSS_REVIEW_CODEX_ARGS:-}" ] && extra=(${ZYZ_CROSS_REVIEW_CODEX_ARGS})
            printf '%s\0' codex exec -C "$cwd" -s read-only --skip-git-repo-check \
                -c 'approval_policy="never"' --json -o "$report" \
                ${mcp[@]+"${mcp[@]}"} ${extra[@]+"${extra[@]}"} -
            ;;
        claude)
            # shellcheck disable=SC2206
            [ -n "${ZYZ_CROSS_REVIEW_CLAUDE_ARGS:-}" ] && extra=(${ZYZ_CROSS_REVIEW_CLAUDE_ARGS})
            printf '%s\0' claude -p --output-format stream-json --verbose \
                --permission-mode dontAsk \
                --allowedTools 'Read,Grep,Glob,LS,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(git ls-files:*),Bash(git blame:*),Bash(shasum:*),Bash(sha256sum:*),Bash(ls:*),Bash(wc:*)' \
                --disallowedTools 'Edit,Write,MultiEdit,NotebookEdit,Agent,Task' \
                --add-dir "$task_dir" --add-dir "$PLUGIN_ROOT" \
                ${mcp[@]+"${mcp[@]}"} ${extra[@]+"${extra[@]}"}
            ;;
    esac
}

# launch_and_wait <cwd> <prompt> <log> <err> <timeout> <argv...> — run one
# reviewer session with a scrubbed env; sets globals LAUNCH_RC and
# LAUNCH_TIMED_OUT.
launch_and_wait() {
    local cwd="$1" prompt="$2" log="$3" err="$4" timeout="$5" x
    shift 5
    local -a envp
    envp=(); while IFS= read -r -d '' x; do envp+=("$x"); done < <(scrubbed_env_prefix)
    ( cd "$cwd" && exec "${envp[@]}" "$@" ) < "$prompt" > "$log" 2> "$err" &
    local pid=$! elapsed=0
    LAUNCH_TIMED_OUT=0
    # Group redirect: bash prints the "Terminated" job notice for a killed
    # reviewer on its own stderr whenever it next reaps, not via `wait`.
    {
        while kill -0 "$pid"; do
            if [ "$elapsed" -ge "$timeout" ]; then
                LAUNCH_TIMED_OUT=1
                kill -TERM "$pid"
                sleep 5
                kill -KILL "$pid"
                break
            fi
            sleep 2
            elapsed=$((elapsed + 2))
        done
        wait "$pid"
    } 2>/dev/null
    LAUNCH_RC=$?
}

# run_one <harness> <host> <kind> <label> <cwd> <task-dir> <brief> <out-dir> <summary-file>
run_one() {
    local harness="$1" host="$2" kind="$3" label="$4" cwd="$5" task_dir="$6" brief="$7" out_dir="$8" summary="$9"
    local base="$out_dir/$label.$harness"
    local report="$base.md" log="$base.jsonl" err="$base.stderr" prompt="$base.prompt.md" meta="$base.meta"
    local timeout="${ZYZ_CROSS_REVIEW_TIMEOUT:-2400}" started finished fp_start fp_end stable x
    local mcp_mode="isolated" rc timed_out
    local -a cmd
    case "$timeout" in ''|*[!0-9]*|0) timeout=2400 ;; esac

    render_prompt "$harness" "$host" "$kind" "$cwd" "$task_dir" "$brief" > "$prompt"
    : > "$report"
    [ "${ZYZ_CROSS_REVIEW_MCP:-none}" = "inherit" ] && mcp_mode="inherit"

    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fp_start="$(tree_fingerprint "$cwd")"
    cmd=(); while IFS= read -r -d '' x; do cmd+=("$x"); done < <(build_cmd "$harness" "$cwd" "$task_dir" "$report" 1)
    launch_and_wait "$cwd" "$prompt" "$log" "$err" "$timeout" "${cmd[@]}"
    # Defensive: if codex still refuses to load its config with the MCP
    # disable overrides (a server shape orch-worker-mcp-args.sh does not
    # anticipate), the session never started — retry once inheriting the
    # user's MCP servers. A transient read-only reviewer pays that memory
    # once, which beats having no review.
    if [ "$harness" = "codex" ] && [ "$LAUNCH_TIMED_OUT" -eq 0 ] && [ "$LAUNCH_RC" -ne 0 ] &&
       [ "$mcp_mode" = "isolated" ] && grep -q 'Error loading config' "$err" 2>/dev/null; then
        mv "$err" "$base.mcp-isolation.stderr"
        mcp_mode="inherit-fallback"
        cmd=(); while IFS= read -r -d '' x; do cmd+=("$x"); done < <(build_cmd "$harness" "$cwd" "$task_dir" "$report" 0)
        launch_and_wait "$cwd" "$prompt" "$log" "$err" "$timeout" "${cmd[@]}"
    fi
    rc="$LAUNCH_RC"; timed_out="$LAUNCH_TIMED_OUT"
    finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fp_end="$(tree_fingerprint "$cwd")"

    if [ "$harness" = "claude" ] && [ -s "$log" ]; then
        extract_claude_result "$log" > "$report"
    fi

    local status
    if [ "$timed_out" -eq 1 ]; then
        status=timeout
    elif [ "$rc" -ne 0 ]; then
        status=failed
    elif [ -s "$report" ] && grep -q '[^[:space:]]' "$report"; then
        status=ok
    else
        status=empty
    fi
    if [ "$fp_start" = "n/a" ]; then stable=n/a
    elif [ "$fp_start" = "$fp_end" ]; then stable=yes
    else stable=no
    fi

    {
        printf 'harness=%s\nhost=%s\nkind=%s\nlabel=%s\ncwd=%s\n' "$harness" "$host" "$kind" "$label" "$cwd"
        printf 'status=%s\nrc=%s\nstarted=%s\nfinished=%s\nmcp=%s\n' "$status" "$rc" "$started" "$finished" "$mcp_mode"
        printf 'tree-fingerprint-start=%s\ntree-fingerprint-end=%s\ntree-stable=%s\n' "$fp_start" "$fp_end" "$stable"
        printf 'report=%s\nlog=%s\nstderr=%s\nprompt=%s\n' "$report" "$log" "$err" "$prompt"
    } > "$meta"
    printf 'cross-review harness=%s status=%s rc=%s tree-stable=%s report=%s meta=%s\n' \
        "$harness" "$status" "$rc" "$stable" "$report" "$meta" > "$summary"
}

cmd_run() {
    local task_dir="" kind="" brief="" label="" cwd="$PWD"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --task-dir) task_dir="${2:-}"; shift 2 ;;
            --kind) kind="${2:-}"; shift 2 ;;
            --brief) brief="${2:-}"; shift 2 ;;
            --label) label="${2:-}"; shift 2 ;;
            --cwd) cwd="${2:-}"; shift 2 ;;
            *) echo "error: unknown argument: $1" >&2; usage; return 2 ;;
        esac
    done
    [ -n "$task_dir" ] && [ -d "$task_dir" ] || { echo "error: --task-dir must be an existing directory" >&2; return 2; }
    case "$kind" in design|implementation|aggregate) ;; *) echo "error: --kind must be design|implementation|aggregate" >&2; return 2 ;; esac
    [ -n "$brief" ] && [ -s "$brief" ] || { echo "error: --brief must be a non-empty file" >&2; return 2; }
    [ -d "$cwd" ] || { echo "error: --cwd must be an existing directory" >&2; return 2; }
    [ -r "$PROMPT_TEMPLATE" ] || { echo "error: missing prompt template: $PROMPT_TEMPLATE" >&2; return 2; }
    task_dir="$(cd "$task_dir" && pwd)"
    cwd="$(cd "$cwd" && pwd)"
    brief="$(cd "$(dirname "$brief")" && pwd)/$(basename "$brief")"
    [ -n "$label" ] || label="$kind-$(date -u +%Y%m%dT%H%M%SZ)"
    label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '-')"

    local host reviewers
    host="$(detect_host)"
    reviewers="$(select_reviewers "$host")"
    if [ -z "$reviewers" ]; then
        case "${ZYZ_CROSS_REVIEW:-auto}" in
            off|OFF|0|false|no|none) printf 'cross-review status=none host=%s reason=disabled-by-ZYZ_CROSS_REVIEW\n' "$host" ;;
            *) printf 'cross-review status=none host=%s reason=no-other-harness-installed\n' "$host" ;;
        esac
        return 0
    fi
    if printf ' %s ' "$reviewers" | grep -q ' claude ' && ! command -v python3 >/dev/null 2>&1; then
        echo "warning: python3 missing; the claude reviewer's report cannot be extracted from its event stream" >&2
    fi

    local out_dir="$task_dir/reviews/cross" h tmp
    mkdir -p "$out_dir" || { echo "error: cannot create $out_dir" >&2; return 2; }
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/zyz-cross-review.XXXXXX")"
    for h in $reviewers; do
        run_one "$h" "$host" "$kind" "$label" "$cwd" "$task_dir" "$brief" "$out_dir" "$tmp/$h.summary" &
    done
    wait
    for h in $reviewers; do
        if [ -s "$tmp/$h.summary" ]; then
            cat "$tmp/$h.summary"
        else
            printf 'cross-review harness=%s status=failed rc=-1 tree-stable=n/a report= meta=\n' "$h"
        fi
    done
    rm -rf "$tmp"
    return 0
}

case "${1:-}" in
    detect)
        [ "$#" -eq 1 ] || { usage; exit 2; }
        host="$(detect_host)"
        printf 'host=%s\nreviewers=%s\n' "$host" "$(select_reviewers "$host")"
        ;;
    run) shift; cmd_run "$@"; exit $? ;;
    *) usage; exit 2 ;;
esac
