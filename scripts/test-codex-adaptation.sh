#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zyz-codex-test.XXXXXX")"
TEST_SESSION="zyz-codex-adapter-$$"
trap 'tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1" >&2; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)" ;; esac; }

R="$ROOT/scripts/orch-agent-runtime.sh"

[ "$(ZYZ_AGENT_RUNTIME=codex "$R" detect)" = codex ] && ok "explicit Codex selection" || bad "explicit Codex selection"
[ "$(ZYZ_AGENT_RUNTIME=claude "$R" detect)" = claude ] && ok "explicit Claude selection" || bad "explicit Claude selection"
[ "$(CODEX_THREAD_ID=t ZYZ_AGENT_RUNTIME=auto "$R" detect)" = codex ] && ok "Codex host auto-detection" || bad "Codex host auto-detection"

launch="$("$R" launch-command codex "$ROOT" "$TMP/work" codex-task "-c 'mcp_servers.example.enabled=false'" "$TMP/work:$TMP/extra")"
has "$launch" "codex -C $TMP/work" "Codex launch uses -C"
has "$launch" "--add-dir $TMP/extra" "Codex launch carries extra worktree"
has "$launch" "mcp_servers.example.enabled=false" "Codex launch preserves isolation args"
has "$launch" "$ROOT/skills/execute-task/SKILL.md" "Codex launch has absolute Skill fallback"
case "$launch" in *"--plugin-dir"*) bad "Codex launch must not use --plugin-dir" ;; *) ok "Codex launch omits Claude --plugin-dir" ;; esac

resume="$("$R" resume-command codex "$ROOT" "$TMP/work" sid-123 "-c 'mcp_servers.example.enabled=false'" "$TMP/work:$TMP/extra")"
has "$resume" "codex resume sid-123 -C $TMP/work" "Codex resume syntax"
case "$resume" in *"--plugin-dir"*) bad "Codex resume must not use --plugin-dir" ;; *) ok "Codex resume omits Claude --plugin-dir" ;; esac

if command -v tmux >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v codex >/dev/null 2>&1; then
    mkdir -p "$TMP/source" "$TMP/spawn-list/tasks"
    git -C "$TMP/source" init -q
    git -C "$TMP/source" config user.email codex-test@example.invalid
    git -C "$TMP/source" config user.name codex-test
    printf 'fixture\n' > "$TMP/source/fixture.txt"
    git -C "$TMP/source" add fixture.txt
    git -C "$TMP/source" commit -qm fixture
    source_base="$(git -C "$TMP/source" branch --show-current)"
    cat > "$TMP/spawn-list/tasks/spawn-codex.md" <<EOF
---
task-id: spawn-codex
source-repo: $TMP/source
worktree: $TMP/spawn-worktree
tmux-session: $TEST_SESSION
agent-runtime: codex
base: $source_base
state: ready
---
EOF
    spawn_out="$(ZYZ_AGENT_RUNTIME=claude ZYZ_GO_BUILD_OPT=0 ZYZ_HOOK_DEBUG_FILE="$TMP/hook-input.jsonl" "$ROOT/scripts/orch-spawn-worker.sh" spawn-codex "$TMP/spawn-list" 2>&1)"
    spawn_rc=$?
    [ "$spawn_rc" -eq 0 ] && ok "spawn accepts per-task Codex override" || bad "spawn accepts per-task Codex override: $spawn_out"
    spawn_dispatch="$(cat "$TMP/spawn-list/runtime/spawn-codex/dispatch.md" 2>/dev/null || true)"
    has "$spawn_dispatch" "agent-runtime: codex" "spawn persists generic runtime"
    has "$spawn_dispatch" "worker-runtime-args: -c 'mcp_servers." "spawn persists Codex isolation args"
    has "$spawn_dispatch" "agent-pid:" "spawn emits generic Phase-2 fields"

    if [ "${1:-}" = "--real" ] && [ "$spawn_rc" -eq 0 ]; then
        mkdir -p "$TMP/spawn-worktree/.zyz-worker/tasks/spawn-codex/runtime/agents"
        printf 'spawn-codex\n' > "$TMP/spawn-worktree/.zyz-worker/current-task"
        cat > "$TMP/spawn-worktree/.zyz-worker/tasks/spawn-codex/status.md" <<'EOF'
# Task Status

## Current Phase

implementation
EOF
        real_args="$(printf '%s\n' "$spawn_dispatch" | awk '/^worker-runtime-args:/{sub(/^worker-runtime-args:[[:space:]]*/, ""); print; exit}')"
        real_cmd="$("$R" launch-command codex "$ROOT" "$TMP/spawn-worktree" spawn-codex "$real_args" "$TMP/spawn-worktree")"
        tmux send-keys -t "$TEST_SESSION" "$real_cmd" Enter
        real_bound="false"
        real_report=""
        trust_sent="false"
        for _real_try in 1 2 3 4 5 6 7 8 9 10 11 12; do
            sleep 2
            if [ "$trust_sent" = "false" ] && tmux capture-pane -p -t "$TEST_SESSION" 2>/dev/null | grep -q "Do you trust the contents"; then
                tmux send-keys -t "$TEST_SESSION" Enter
                trust_sent="true"
            fi
            real_report="$("$ROOT/scripts/orch-check-worker.sh" spawn-codex "$TMP/spawn-list" 2>/dev/null || true)"
            case "$real_report" in *"dispatch-bound=true"*) real_bound="true"; break ;; esac
        done
        if [ "$real_bound" = "true" ]; then
            ok "real Codex tmux worker binds persisted session"
        else
            real_shell_pid="$(printf '%s\n' "$spawn_dispatch" | awk '/^shell-pid:/{print $2; exit}')"
            real_pane="$(tmux capture-pane -p -t "$TEST_SESSION" 2>/dev/null | tail -30)"
            real_children="$(pgrep -P "$real_shell_pid" -la 2>/dev/null || true)"
            bad "real Codex tmux worker binds persisted session: $real_report; children=$real_children; pane=$real_pane"
        fi
        real_dispatch="$(cat "$TMP/spawn-list/runtime/spawn-codex/dispatch.md" 2>/dev/null || true)"
        has "$real_dispatch" "agent-session-id:" "real Codex worker records generic session id"
        real_sid="$(printf '%s\n' "$real_dispatch" | awk '/^agent-session-id:/{sub(/^agent-session-id:[[:space:]]*/, ""); print; exit}')"
        [ -n "$real_sid" ] && ok "real Codex session id is non-empty" || bad "real Codex session id is non-empty"
        heartbeat_seen="false"
        _heartbeat_try=0
        while [ "$_heartbeat_try" -lt 40 ]; do
            if find "$TMP/spawn-worktree/.zyz-worker/tasks/spawn-codex/runtime/agents" -name '*.heartbeat' -type f -print -quit 2>/dev/null | grep -q .; then
                heartbeat_seen="true"
                break
            fi
            sleep 1
            _heartbeat_try=$((_heartbeat_try + 1))
        done
        if [ "$heartbeat_seen" = "true" ]; then
            ok "real Codex hook stamps task heartbeat"
        else
            bad "real Codex hook stamps task heartbeat: pane=$(tmux capture-pane -p -t "$TEST_SESSION" 2>/dev/null | tail -12); hook-input=$(tail -1 "$TMP/hook-input.jsonl" 2>/dev/null || true)"
        fi
    fi
    tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true

    if [ "${1:-}" = "--real" ] && [ "$spawn_rc" -eq 0 ]; then
        mkdir -p "$TMP/standalone/.zyz-worker/tasks/hook-smoke/runtime/agents"
        printf 'hook-smoke\n' > "$TMP/standalone/.zyz-worker/current-task"
        cat > "$TMP/standalone/.zyz-worker/tasks/hook-smoke/status.md" <<'EOF'
# Task Status

## Current Phase

implementation
EOF
        standalone_out="$(env -u ZYZ_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT \
            ZYZ_HOOK_DEBUG_FILE="$TMP/standalone-hook-input.jsonl" \
            codex exec -C "$TMP/standalone" --skip-git-repo-check -s read-only \
            --dangerously-bypass-hook-trust --color never \
            'Use the shell tool to run pwd once, then reply exactly OK.' 2>&1)"
        standalone_rc=$?
        standalone_heartbeat="$(find "$TMP/standalone/.zyz-worker/tasks/hook-smoke/runtime/agents" -name '*.heartbeat' -type f -print -quit 2>/dev/null)"
        [ "$standalone_rc" -eq 0 ] && [ -n "$standalone_heartbeat" ] \
            && ok "standalone Codex resolves installed hook root" \
            || bad "standalone Codex resolves installed hook root: $standalone_out"
        [ -s "$TMP/standalone-hook-input.jsonl" ] \
            && ok "standalone Codex delivers hook JSON" \
            || bad "standalone Codex delivers hook JSON"
    fi
else
    printf 'SKIP  spawn integration (tmux/git/codex unavailable)\n'
fi

mkdir -p "$TMP/home/.codex/sessions/2026/08/10" "$TMP/work" "$TMP/list/tasks/codex-task" "$TMP/list/runtime/codex-task" "$TMP/bin"
cat > "$TMP/home/.codex/sessions/2026/08/10/rollout-test.jsonl" <<EOF
{"type":"session_meta","payload":{"id":"codex-session-123","cwd":"$TMP/work"}}
{"type":"event_msg","payload":{"type":"task_started"}}
EOF
touch -t 202608101200 "$TMP/home/.codex/sessions/2026/08/10/rollout-test.jsonl"
found="$(HOME="$TMP/home" "$R" discover-session codex 4242 "$TMP/work" 2020-01-01T00:00:00+0000)"
has "$found" "codex-session-123" "Codex session_meta id discovery"
has "$found" "rollout-test.jsonl" "Codex transcript path discovery"

cat > "$TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = has-session ] && exit 0
exit 0
EOF
cat > "$TMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
printf '4242\n'
EOF
chmod +x "$TMP/bin/tmux" "$TMP/bin/pgrep"
cat > "$TMP/list/tasks/codex-task.md" <<EOF
---
task-id: codex-task
state: in-progress
tmux-session: zyz-task-codex-task
---
EOF
cat > "$TMP/list/runtime/codex-task/worker-status.md" <<EOF
---
phase: implementation
phase-since: 2026-08-10T11:59:00+0000
wait-state: none
waiting-reason:
expected-resume-by:
---
EOF
touch "$TMP/list/runtime/codex-task/heartbeat"
cat > "$TMP/list/runtime/codex-task/dispatch.md" <<EOF
---
task-id: codex-task
spawn-iso: 2020-01-01T00:00:00+0000
tmux-session: zyz-task-codex-task
tmux-window-id: @1
tmux-pane-id: %1
shell-pid: 4000
worktree: $TMP/work
source-repo: $TMP/work
branch: task/codex-task
base: main
plugin-root: $ROOT
encoded-cwd:
agent-runtime: codex
worker-runtime-args: -c 'mcp_servers.example.enabled=false'
worker-mcp-args: -c 'mcp_servers.example.enabled=false'
reuse-from:
reuse-scope:
reuse-agent-effective:
reuse-claude-effective:
heartbeat-window-id:
agent-pid:
agent-session-id:
claude-pid:
claude-session-id:
transcript-path:
first-seen-iso:
---
EOF
check="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" "$ROOT/scripts/orch-check-worker.sh" codex-task "$TMP/list")"
has "$check" "dispatch-bound=true" "Codex dispatch binds"
has "$check" "agent-runtime=codex" "check reports Codex runtime"
has "$(cat "$TMP/list/runtime/codex-task/dispatch.md")" "agent-session-id: codex-session-123" "generic Codex session field persisted"
has "$(cat "$TMP/list/runtime/codex-task/dispatch.md")" "codex resume codex-session-123" "Codex recovery command rendered"

python3 -m json.tool "$ROOT/hooks/hooks.json" >/dev/null 2>&1 && ok "hooks.json is valid JSON" || bad "hooks.json is valid JSON"
hook_manifest="$(cat "$ROOT/hooks/hooks.json")"
has "$hook_manifest" 'CODEX_PLUGIN_ROOT' "hooks commands resolve Codex plugin root"
has "$hook_manifest" 'ZYZ_PLUGIN_ROOT' "hooks commands resolve orchestrated plugin root"
has "$hook_manifest" 'CLAUDE_PLUGIN_ROOT' "hooks retain Claude plugin root"
has "$hook_manifest" "/hooks/scripts/start-watchdog.sh" "Codex SessionStart watchdog registered"

printf '\nRESULT: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
