#!/usr/bin/env bash
#
# Tests for scripts/cross-review.sh with FAKE `codex` / `claude` binaries on a
# restricted PATH. Observation boundary: this proves harness selection, the
# argv/env/stdin contract handed to each reviewer CLI (read-only flags, scrubbed
# ZYZ_* env, hook disable, MCP isolation + Codex fallback), report capture,
# status classification, and the tree fingerprint. It does NOT prove that a
# real Codex/Claude release honours those flags — that was smoke-checked by
# hand against codex-cli 0.151.0 and Claude Code 2.1.251 and is not asserted
# here.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/cross-review.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zyz-cross-review-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
skipped=0

ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1" >&2; }
skip() { skipped=$((skipped + 1)); printf 'SKIP  %s%s\n' "$1" "${2:+ — $2}"; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)" ;; esac; }
lacks() { case "$1" in *"$2"*) bad "$3 (unexpected: $2)" ;; *) ok "$3" ;; esac; }

BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
for t in python3 git; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$p" ] && ln -sf "$p" "$TOOLS/$t"
done

FAKE_LOG="$TMP/log"
mkdir -p "$FAKE_LOG"
export FAKE_LOG

# --- fake harness binaries ---------------------------------------------------
make_fake_codex() { # <dir>
    mkdir -p "$1"
    cat > "$1/codex" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "mcp" ]; then
    printf '[{"name":"plugsrv","enabled":true,"transport":{"type":"stdio","command":"/bin/plug"}},{"name":"offsrv","enabled":false,"transport":{"type":"stdio","command":"/bin/off"}}]\n'
    exit 0
fi
n="$(ls "$FAKE_LOG" | grep -c '^codex\.args\.' || true)"
printf '%s\n' "$@" > "$FAKE_LOG/codex.args.$n"
env > "$FAKE_LOG/codex.env.$n"
pwd > "$FAKE_LOG/codex.cwd.$n"
cat > "$FAKE_LOG/codex.stdin.$n"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
case "${FAKE_CODEX_MODE:-ok}" in
    fail) echo "boom" >&2; exit 3 ;;
    sleep) sleep 60; exit 0 ;;
    empty) exit 0 ;;
    mcpbad)
        case " $* " in *mcp_servers*) echo "Error loading config.toml: invalid transport" >&2; exit 1 ;; esac ;;
    mutate) printf 'changed\n' >> tracked.txt ;;
esac
printf '# Review Report\n\n## Result\n- Reviewer: cross-harness:codex\n' > "$out"
printf '{"type":"thread.started"}\n'
EOF
    chmod +x "$1/codex"
}

make_fake_claude() { # <dir>
    mkdir -p "$1"
    cat > "$1/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_LOG/claude.args"
env > "$FAKE_LOG/claude.env"
cat > "$FAKE_LOG/claude.stdin"
case "${FAKE_CLAUDE_MODE:-ok}" in
    fail) exit 4 ;;
esac
printf '%s\n' '{"type":"system","subtype":"init"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"# Review Report\n\n- Reviewer: cross-harness:claude"}'
EOF
    chmod +x "$1/claude"
}

BOTH="$TMP/bin-both"; make_fake_codex "$BOTH"; make_fake_claude "$BOTH"
ONLY_CODEX="$TMP/bin-codex"; make_fake_codex "$ONLY_CODEX"
NONE="$TMP/bin-none"; mkdir -p "$NONE"

# run_xr <bin-dir> <host> [VAR=val ...] -- <args...>
run_xr() {
    local bin="$1" host="$2"; shift 2
    local -a extra_env=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do extra_env+=("$1"); shift; done
    shift
    env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH="$bin:$TOOLS:$BASE_PATH" FAKE_LOG="$FAKE_LOG" \
        ZYZ_AGENT_RUNTIME="$host" ZYZ_TASK_DIR=/should/not/leak ZYZ_WORKER_STATUS_FILE=/should/not/leak \
        ${extra_env[@]+"${extra_env[@]}"} bash "$SCRIPT" "$@"
}

# --- fixture repo ------------------------------------------------------------
REPO="$TMP/repo"
TASK="$REPO/.zyz-worker/tasks/t1"
mkdir -p "$TASK"
REPO="$(cd "$REPO" && pwd)"; TASK="$REPO/.zyz-worker/tasks/t1"   # the script canonicalizes paths
git -C "$REPO" init -q
printf 'base\n' > "$REPO/tracked.txt"
git -C "$REPO" add tracked.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init
printf -- '- Design document: .zyz-worker/tasks/t1/design.md\n- BRIEF-SENTINEL-42\n' > "$TASK/brief.md"
reset_logs() { rm -f "$FAKE_LOG"/*; rm -rf "$TASK/reviews"; printf 'base\n' > "$REPO/tracked.txt"; }

# --- detect ------------------------------------------------------------------
out="$(run_xr "$BOTH" claude -- detect 2>/dev/null)"
has "$out" "host=claude" "detect: host override honoured"
has "$out" "reviewers=codex" "detect: claude host selects codex only (never itself)"
out="$(run_xr "$BOTH" codex -- detect 2>/dev/null)"
has "$out" "reviewers=claude" "detect: codex host selects claude only"
out="$(run_xr "$BOTH" claude ZYZ_CROSS_REVIEW=off -- detect 2>/dev/null)"
case "$out" in *"reviewers="$'\n'*|*"reviewers=") ok "detect: ZYZ_CROSS_REVIEW=off selects nothing" ;; *) bad "detect: off still selected: $out" ;; esac
err="$(run_xr "$BOTH" claude ZYZ_CROSS_REVIEW=claude,gemini -- detect 2>&1 >/dev/null)"
has "$err" "host harness" "detect: explicit host entry dropped with a warning"
has "$err" "unknown cross-review harness 'gemini'" "detect: unknown harness dropped with a warning"
if PATH="$NONE:$TOOLS:$BASE_PATH" command -v codex >/dev/null 2>&1; then
    skip "detect: nothing installed" "a real codex is on the base PATH"
else
    out="$(run_xr "$NONE" claude -- detect 2>/dev/null)"
    case "$out" in *"reviewers="$'\n'*|*"reviewers=") ok "detect: no other harness installed selects nothing" ;; *) bad "detect: phantom reviewer: $out" ;; esac
fi

# --- usage errors ------------------------------------------------------------
run_xr "$BOTH" claude -- run --task-dir "$TASK" --kind bogus --brief "$TASK/brief.md" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "run: invalid --kind is a usage error (exit 2)" || bad "run: invalid --kind not rejected"
run_xr "$BOTH" claude -- run --task-dir "$TASK" --kind design --brief "$TASK/missing.md" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "run: missing brief is a usage error (exit 2)" || bad "run: missing brief not rejected"

# --- none ----------------------------------------------------------------------
if PATH="$NONE:$TOOLS:$BASE_PATH" command -v codex >/dev/null 2>&1; then
    skip "run: status=none" "a real codex is on the base PATH"
else
    out="$(run_xr "$NONE" claude -- run --task-dir "$TASK" --kind design --brief "$TASK/brief.md" --cwd "$REPO")"; rc=$?
    [ "$rc" -eq 0 ] && ok "run: no reviewer exits 0" || bad "run: no reviewer rc=$rc"
    has "$out" "status=none host=claude reason=no-other-harness-installed" "run: reports status=none"
fi
out="$(run_xr "$BOTH" claude ZYZ_CROSS_REVIEW=off -- run --task-dir "$TASK" --kind design --brief "$TASK/brief.md" --cwd "$REPO")"
has "$out" "reason=disabled-by-ZYZ_CROSS_REVIEW" "run: off reports disabled"

# --- codex happy path ----------------------------------------------------------
reset_logs
out="$(run_xr "$BOTH" claude ZYZ_CROSS_REVIEW_MCP=inherit -- run --task-dir "$TASK" --kind implementation --brief "$TASK/brief.md" --cwd "$REPO" --label st1)"; rc=$?
[ "$rc" -eq 0 ] && ok "codex: run exits 0" || bad "codex: rc=$rc"
has "$out" "cross-review harness=codex status=ok rc=0 tree-stable=yes" "codex: summary line ok + tree stable"
lacks "$out" "harness=claude" "codex: host claude is not re-launched"
args="$(cat "$FAKE_LOG/codex.args.0" 2>/dev/null)"
has "$args" "exec" "codex: non-interactive exec"
has "$args" $'-s\nread-only' "codex: read-only sandbox"
has "$args" 'approval_policy="never"' "codex: never asks for approval"
has "$args" $'-C\n'"$REPO" "codex: working root is --cwd"
lacks "$args" "mcp_servers" "codex: ZYZ_CROSS_REVIEW_MCP=inherit renders no MCP overrides"
envd="$(cat "$FAKE_LOG/codex.env.0" 2>/dev/null)"
has "$envd" "ZYZ_HOOKS_DISABLE=1" "codex: plugin hooks disabled in the reviewer"
lacks "$envd" "ZYZ_TASK_DIR" "codex: ZYZ_TASK_DIR scrubbed"
lacks "$envd" "ZYZ_WORKER_STATUS_FILE" "codex: ZYZ_WORKER_STATUS_FILE scrubbed"
lacks "$envd" "ZYZ_AGENT_RUNTIME" "codex: every ZYZ_* var scrubbed"
stdin="$(cat "$FAKE_LOG/codex.stdin.0" 2>/dev/null)"
has "$stdin" "BRIEF-SENTINEL-42" "codex: brief appended to the prompt"
has "$stdin" 'Review kind: `implementation`' "codex: kind substituted"
has "$stdin" "$ROOT/subagents/review-agent.md" "codex: plugin root substituted"
lacks "$stdin" "{{" "codex: no unsubstituted placeholder"
has "$stdin" "strictly read-only" "codex: prompt carries the read-only rule"
report="$TASK/reviews/cross/st1.codex.md"
has "$(cat "$report" 2>/dev/null)" "cross-harness:codex" "codex: report captured via -o"
meta="$(cat "$TASK/reviews/cross/st1.codex.meta" 2>/dev/null)"
has "$meta" "status=ok" "codex: meta records status"
has "$meta" "mcp=inherit" "codex: meta records MCP mode"
[ -s "$TASK/reviews/cross/st1.codex.prompt.md" ] && ok "codex: prompt persisted" || bad "codex: prompt not persisted"

# --- codex MCP isolation + plugin-server fallback ---------------------------
reset_logs
out="$(run_xr "$BOTH" claude FAKE_CODEX_MODE=mcpbad -- run --task-dir "$TASK" --kind design --brief "$TASK/brief.md" --cwd "$REPO" --label mcp)"
has "$(cat "$FAKE_LOG/codex.args.0" 2>/dev/null)" "mcp_servers.plugsrv.enabled=false" "codex: default isolation disables enabled MCP servers"
lacks "$(cat "$FAKE_LOG/codex.args.0" 2>/dev/null)" "offsrv" "codex: already-disabled server untouched"
lacks "$(cat "$FAKE_LOG/codex.args.1" 2>/dev/null)" "mcp_servers" "codex: config-load failure retried without overrides"
has "$out" "status=ok" "codex: fallback run succeeds"
has "$(cat "$TASK/reviews/cross/mcp.codex.meta")" "mcp=inherit-fallback" "codex: meta records the MCP fallback"
[ -s "$TASK/reviews/cross/mcp.codex.mcp-isolation.stderr" ] && ok "codex: first-attempt stderr kept" || bad "codex: first-attempt stderr lost"

# --- codex failure classes ----------------------------------------------------
reset_logs
out="$(run_xr "$BOTH" claude FAKE_CODEX_MODE=fail ZYZ_CROSS_REVIEW_MCP=inherit -- run --task-dir "$TASK" --kind design --brief "$TASK/brief.md" --cwd "$REPO" --label f)"; rc=$?
[ "$rc" -eq 0 ] && ok "failed: reviewer failure never fails the script" || bad "failed: rc=$rc"
has "$out" "status=failed rc=3" "failed: classified with the reviewer rc"
[ ! -e "$FAKE_LOG/codex.args.1" ] && ok "failed: a non-config failure is not retried" || bad "failed: unexpected retry"
reset_logs
out="$(run_xr "$BOTH" claude FAKE_CODEX_MODE=empty ZYZ_CROSS_REVIEW_MCP=inherit -- run --task-dir "$TASK" --kind design --brief "$TASK/brief.md" --cwd "$REPO" --label e)"
has "$out" "status=empty" "empty: rc 0 with no report is not ok"
reset_logs
start=$(date +%s)
out="$(run_xr "$BOTH" claude FAKE_CODEX_MODE=sleep ZYZ_CROSS_REVIEW_TIMEOUT=2 ZYZ_CROSS_REVIEW_MCP=inherit -- run --task-dir "$TASK" --kind design --brief "$TASK/brief.md" --cwd "$REPO" --label t)"
elapsed=$(( $(date +%s) - start ))
has "$out" "status=timeout" "timeout: classified"
[ "$elapsed" -lt 40 ] && ok "timeout: reviewer killed (${elapsed}s)" || bad "timeout: took ${elapsed}s"
reset_logs
out="$(run_xr "$BOTH" claude FAKE_CODEX_MODE=mutate ZYZ_CROSS_REVIEW_MCP=inherit -- run --task-dir "$TASK" --kind implementation --brief "$TASK/brief.md" --cwd "$REPO" --label m)"
has "$out" "tree-stable=no" "fingerprint: a tree change during review is flagged"
reset_logs
printf 'status noise\n' > "$TASK/status-noise.md"
out="$(run_xr "$BOTH" claude ZYZ_CROSS_REVIEW_MCP=inherit -- run --task-dir "$TASK" --kind implementation --brief "$TASK/brief.md" --cwd "$REPO" --label s)"
has "$out" "tree-stable=yes" "fingerprint: .zyz-worker/ artifacts (incl. the reviews it writes) excluded"
rm -f "$TASK/status-noise.md"

# --- claude path (host = codex) ----------------------------------------------
reset_logs
out="$(run_xr "$BOTH" codex -- run --task-dir "$TASK" --kind aggregate --brief "$TASK/brief.md" --cwd "$REPO" --label agg)"
has "$out" "cross-review harness=claude status=ok" "claude: summary line ok"
lacks "$out" "harness=codex" "claude: host codex is not re-launched"
args="$(cat "$FAKE_LOG/claude.args" 2>/dev/null)"
has "$args" "-p" "claude: print mode"
has "$args" $'--permission-mode\ndontAsk' "claude: dontAsk permission mode"
has "$args" "--disallowedTools" "claude: editing tools disallowed"
has "$args" "Edit,Write" "claude: Edit/Write in the disallow list"
lacks "$(printf '%s\n' "$args" | grep -A1 -- '--allowedTools' | tail -1)" "Bash," "claude: no unrestricted Bash in the allowlist"
has "$args" "--strict-mcp-config" "claude: MCP isolated by default"
has "$args" $'--add-dir\n'"$TASK" "claude: task dir readable"
has "$(cat "$FAKE_LOG/claude.env")" "ZYZ_HOOKS_DISABLE=1" "claude: plugin hooks disabled"
lacks "$(cat "$FAKE_LOG/claude.env")" "ZYZ_TASK_DIR" "claude: ZYZ_* scrubbed"
has "$(cat "$FAKE_LOG/claude.stdin")" "cross-harness:claude" "claude: prompt names the harness"
rep="$(cat "$TASK/reviews/cross/agg.claude.md" 2>/dev/null)"
has "$rep" "Reviewer: cross-harness:claude" "claude: final result extracted from stream-json"
lacks "$rep" "partial" "claude: result event preferred over partial text"
reset_logs
out="$(run_xr "$BOTH" codex FAKE_CLAUDE_MODE=fail -- run --task-dir "$TASK" --kind design --brief "$TASK/brief.md" --cwd "$REPO" --label cf)"
has "$out" "status=failed rc=4" "claude: failure classified"

# --- the live tree is never written by the script ----------------------------
[ -z "$(git -C "$REPO" status --porcelain -- . ':(exclude).zyz-worker')" ] && ok "script leaves the work tree untouched outside .zyz-worker/" || bad "work tree modified"

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
