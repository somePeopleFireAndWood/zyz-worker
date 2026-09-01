#!/usr/bin/env bash
#
# Observation boundary: ordinary checks cover adapter rendering and static
# manifest wiring.  --real additionally reinstalls from the controlled personal
# marketplace, records the installed version/root, byte-compares the installed
# hooks manifest with this candidate, then starts fresh Codex processes.  That
# proves the observed smoke used this candidate installation; it does not prove
# every Codex/Claude release injects the same variables, nor does it simulate
# historical hosts.  Main-hook liveness is observed through the authenticated
# fixed observer; the resulting epoch proves at least one main hook committed,
# not which exact event produced it or how many hooks ran.  Do not read a green
# --real run as those broader claims.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zyz-codex-test.XXXXXX")"
TEST_SESSION="zyz-codex-adapter-$$"
trap 'tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
pass=0
fail=0
skipped=0
EXPECTED_VERSION="0.18.2"
# Release-specific mutation sentinel: a base-version bump alone also changes
# the cache path, but the approved candidate-install procedure explicitly
# requires a fresh cachebuster so a stale same-base cache can never be reused.
PREVIOUS_CODEX_CACHEBUSTER="20260901195125"

ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1" >&2; }
skip() { skipped=$((skipped + 1)); printf 'SKIP  %s%s\n' "$1" "${2:+ — $2}"; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)" ;; esac; }

# main_epoch_from_observer <observer-cli> <task-dir> <stdout-file> <stderr-file>
# Reads the authenticated fixed observer.  Empty stdout is a valid pre-hook
# baseline (main_heartbeat_epoch=null); a decimal epoch is a committed main
# heartbeat.  Requiring instances=[] prevents a subagent heartbeat from being
# mistaken for the main-agent signal this helper claims to observe. Raw command
# stdout/stderr and JSON-parser diagnostics remain in caller-owned files.
main_epoch_from_observer() {
    local observer="$1" task_dir="$2" stdout_file="$3" stderr_file="$4" observer_rc
    bash "$observer" hook-observe "$task_dir" false >"$stdout_file" 2>"$stderr_file"
    observer_rc=$?
    [ "$observer_rc" -eq 0 ] || return "$observer_rc"
    python3 -c 'import json,sys
try:x=json.load(sys.stdin)
except Exception:raise SystemExit(1)
v=x.get("main_heartbeat_epoch")
ok=(x.get("ok") is True and x.get("state")=="observed" and
    (v is None or type(v) is int) and x.get("instances")==[])
if not ok:raise SystemExit(1)
if v is not None:print(v)' <"$stdout_file" 2>>"$stderr_file"
}

# Exact established degraded-capability predicate shared with
# test-watchdog-hooks.sh. No generic rc=4, Darwin name check, or substring is
# enough to skip an assertion: the full public error envelope must match.
fixed_observer_genesis_unavailable() { # rc json task-dir include-no-output
    [ "$1" -eq 4 ] || return 1
    printf '%s' "$2" | python3 -c 'import json,sys
try:x=json.load(sys.stdin)
except Exception:raise SystemExit(1)
err=x.get("error");expected=["hook-observe",sys.argv[1],sys.argv[2]]
ok=(x.get("schema_version")==1 and x.get("command")=="hook-observe" and
 x.get("ok") is False and x.get("state")=="error" and x.get("argv")==expected and
 isinstance(err,dict) and set(err)=={"code","message","retryable"} and
 err.get("code")=="genesis-capability-unavailable" and err.get("retryable") is True and
 isinstance(err.get("message"),str) and bool(err["message"]))
raise SystemExit(0 if ok else 1)' "$3" "$4"
}

main_epoch_advanced() { # before after
    case "$2" in ''|*[!0-9]*) return 1 ;; esac
    case "$1" in
        '') return 0 ;;
        *[!0-9]*) return 1 ;;
        *) [ "$2" -gt "$1" ] ;;
    esac
}

codex_trust_accept_selected() {
    printf '%s\n' "$1" | tail -15 \
        | grep -qiE '^[[:space:]]*[›❯>●].*(Yes|trust|continue|proceed)'
}

codex_trust_reject_selected() {
    printf '%s\n' "$1" | tail -15 \
        | grep -qiE '^[[:space:]]*[›❯>●].*(No|exit|cancel|decline)'
}

# advance_codex_trust_page <tmux-target> <captured-content>
# Codex trust screens are interactive menus, so their heading alone never
# authorizes Enter. Move off a visibly selected rejecting row, recapture, and
# confirm only when the accepting row is positively selected.
advance_codex_trust_page() {
    local target="$1" selected="$2"
    if codex_trust_reject_selected "$selected"; then
        tmux send-keys -t "$target" Up
        sleep 1
        selected="$(tmux capture-pane -p -t "$target" 2>/dev/null || true)"
    fi
    codex_trust_accept_selected "$selected" || return 1
    tmux send-keys -t "$target" Enter
}

# Real-host provenance mutation manifest (implementationAgent executes):
# - skip `codex plugin add` -> candidate install version/hash cases turn red;
# - point personal source at another checkout -> source realpath case turns red;
# - copy an older hooks.json into the cache -> installed hook SHA case turns red;
# - remove PLUGIN_ROOT from the production chain -> standalone installed-root
#   smoke turns red while the source-level T2R matrix also identifies the arm;
# - reuse PREVIOUS_CODEX_CACHEBUSTER -> fresh candidate cachebuster case turns red.
# - replace fixed `hook-observe` main_heartbeat_epoch reads with a search for
#   runtime/agents/*.heartbeat -> both real main-heartbeat cases turn red,
#   because standalone main heartbeat inodes are forbidden by the current
#   authenticated PACK_HEADER contract.
# - omit either task runtime mkdir -> observer returns invalid-request, which is
#   not the exact degraded GENESIS envelope and therefore turns that claim red;
# - loosen fixed_observer_genesis_unavailable to rc/substrings -> malformed
#   platform errors can incorrectly skip the supported-platform release gate.
# Kills here establish candidate provenance at the real Codex boundary, not
# compatibility with host versions that were not executed.
real_provenance_ready=true
if [ "${1:-}" = "--real" ]; then
    real_provenance_ready=false
    candidate_source_ok=false
    candidate_version_ok=false
    candidate_cachebuster_ok=false
    plugin_record_ok=false
    candidate_source="${ZYZ_TEST_PERSONAL_PLUGIN_SOURCE:-/Users/yu/plugins/zyz-worker}"
    candidate_source_real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$candidate_source" 2>/dev/null || true)"
    candidate_root_real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$ROOT" 2>/dev/null || true)"
    if [ -n "$candidate_source_real" ] && [ "$candidate_source_real" = "$candidate_root_real" ]; then
        ok "real Codex personal-marketplace source resolves to candidate workspace"
        candidate_source_ok=true
    else
        bad "real Codex personal-marketplace source resolves to candidate workspace: source=$candidate_source real=$candidate_source_real candidate=$candidate_root_real"
    fi

    candidate_version="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["version"])' "$ROOT/.codex-plugin/plugin.json" 2>/dev/null || true)"
    case "$candidate_version" in
        "$EXPECTED_VERSION"+codex.*)
            ok "real Codex candidate manifest has $EXPECTED_VERSION base version"
            candidate_version_ok=true ;;
        *) bad "real Codex candidate manifest has $EXPECTED_VERSION base version: got [$candidate_version]" ;;
    esac
    candidate_cachebuster="${candidate_version#*+codex.}"
    case "$candidate_cachebuster" in
        ""|*[!0-9]*|"$PREVIOUS_CODEX_CACHEBUSTER")
            bad "real Codex candidate uses a fresh numeric cachebuster: got [$candidate_cachebuster]" ;;
        *)
            ok "real Codex candidate uses a fresh cachebuster"
            candidate_cachebuster_ok=true ;;
    esac

    if command -v codex >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
        && [ "$candidate_source_ok" = true ] && [ "$candidate_version_ok" = true ] \
        && [ "$candidate_cachebuster_ok" = true ]; then
        codex plugin add zyz-worker@personal --json >"$TMP/plugin-add.json" 2>"$TMP/plugin-add.err"
        plugin_add_rc=$?
        if [ "$plugin_add_rc" -eq 0 ]; then
            ok "real Codex reinstalls candidate from personal marketplace"
        else
            bad "real Codex reinstalls candidate from personal marketplace: rc=$plugin_add_rc stderr=$(tr '\n' ' ' < "$TMP/plugin-add.err")"
        fi
        codex plugin list --marketplace personal --json >"$TMP/plugin-list.json" 2>"$TMP/plugin-list.err"
        plugin_list_rc=$?
        if [ "$plugin_list_rc" -eq 0 ] && python3 - "$TMP/plugin-list.json" "$candidate_version" "$candidate_source" "$ROOT" <<'PY'
import json
import os
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
matches = [p for p in data.get("installed", []) if p.get("pluginId") == "zyz-worker@personal"]
ok = (
    len(matches) == 1
    and matches[0].get("installed") is True
    and matches[0].get("enabled") is True
    and matches[0].get("version") == sys.argv[2]
    and matches[0].get("source", {}).get("source") == "local"
    and matches[0].get("source", {}).get("path") == sys.argv[3]
    and os.path.realpath(matches[0]["source"]["path"]) == os.path.realpath(sys.argv[4])
)
raise SystemExit(0 if ok else 1)
PY
        then
            ok "real Codex plugin list records exact candidate version and source"
            plugin_record_ok=true
        else
            bad "real Codex plugin list records exact candidate version and source: rc=$plugin_list_rc json=$(tr '\n' ' ' < "$TMP/plugin-list.json" 2>/dev/null || true)"
        fi

        codex_home="${CODEX_HOME:-$HOME/.codex}"
        installed_root="$codex_home/plugins/cache/personal/zyz-worker/$candidate_version"
        if [ -d "$installed_root" ]; then
            ok "real Codex candidate cache directory exists"
        else
            bad "real Codex candidate cache directory exists: missing [$installed_root]"
        fi
        candidate_hook_sha="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$ROOT/hooks/hooks.json" 2>/dev/null || true)"
        installed_hook_sha="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$installed_root/hooks/hooks.json" 2>/dev/null || true)"
        if [ -n "$candidate_hook_sha" ] && [ "$installed_hook_sha" = "$candidate_hook_sha" ]; then
            ok "real Codex installed hooks.json SHA-256 matches candidate"
        else
            bad "real Codex installed hooks.json SHA-256 matches candidate: candidate=$candidate_hook_sha installed=$installed_hook_sha"
        fi

        if [ "$candidate_source_ok" = true ] && [ "$candidate_version_ok" = true ] \
            && [ "$candidate_cachebuster_ok" = true ] && [ "$plugin_add_rc" -eq 0 ] \
            && [ "$plugin_record_ok" = true ] \
            && [ -d "$installed_root" ] && [ -n "$candidate_hook_sha" ] \
            && [ "$installed_hook_sha" = "$candidate_hook_sha" ]; then
            real_provenance_ready=true
        fi
    else
        bad "real Codex candidate provenance prerequisites are available"
    fi
fi

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

    if [ "${1:-}" = "--real" ] && [ "$real_provenance_ready" = true ] && [ "$spawn_rc" -eq 0 ]; then
        real_task_dir="$TMP/spawn-worktree/.zyz-worker/tasks/spawn-codex"
        mkdir -p "$real_task_dir/runtime"
        printf 'spawn-codex\n' > "$TMP/spawn-worktree/.zyz-worker/current-task"
        cat > "$real_task_dir/status.md" <<'EOF'
# Task Status

## Current Phase

implementation
EOF
        real_observer="$installed_root/hooks/scripts/agent-runtime-state.sh"
        real_main_before_out="$TMP/real-main-before.json"
        real_main_before_err="$TMP/real-main-before.err"
        real_main_before="$(main_epoch_from_observer "$real_observer" "$real_task_dir" "$real_main_before_out" "$real_main_before_err")"
        real_main_before_rc=$?
        real_main_before_raw="$(cat "$real_main_before_out" 2>/dev/null || true)"
        real_main_before_error="$(cat "$real_main_before_err" 2>/dev/null || true)"
        real_fixed_genesis_unavailable=false
        if fixed_observer_genesis_unavailable "$real_main_before_rc" "$real_main_before_raw" "$real_task_dir" false; then
            real_fixed_genesis_unavailable=true
        fi
        real_args="$(printf '%s\n' "$spawn_dispatch" | awk '/^worker-runtime-args:/{sub(/^worker-runtime-args:[[:space:]]*/, ""); print; exit}')"
        real_cmd="$("$R" launch-command codex "$ROOT" "$TMP/spawn-worktree" spawn-codex "$real_args" "$TMP/spawn-worktree")"
        tmux send-keys -t "$TEST_SESSION" "$real_cmd" Enter
        real_bound="false"
        real_report=""
        trust_sent="false"
        for _real_try in 1 2 3 4 5 6 7 8 9 10 11 12; do
            sleep 2
            if [ "$trust_sent" = "false" ]; then
                real_trust_pane="$(tmux capture-pane -p -t "$TEST_SESSION" 2>/dev/null || true)"
                if printf '%s\n' "$real_trust_pane" | grep -q "Do you trust the contents" \
                    && advance_codex_trust_page "$TEST_SESSION" "$real_trust_pane"; then
                    trust_sent="true"
                fi
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
        real_main_after=""
        real_main_observed=false
        real_main_after_out="$TMP/real-main-after.json"
        real_main_after_err="$TMP/real-main-after.err"
        if [ "$real_fixed_genesis_unavailable" = true ]; then
            skip "real Codex hook main_heartbeat_epoch requires supported durable GENESIS capability" \
                "rc=$real_main_before_rc out=$real_main_before_raw stderr=$real_main_before_error"
        else
            _main_try=0
            while [ "$_main_try" -lt 40 ]; do
                real_main_after="$(main_epoch_from_observer "$real_observer" "$real_task_dir" "$real_main_after_out" "$real_main_after_err")"
                real_main_after_rc=$?
                if [ "$real_main_before_rc" -eq 0 ] && [ "$real_main_after_rc" -eq 0 ] \
                    && main_epoch_advanced "$real_main_before" "$real_main_after"; then
                    real_main_observed=true
                    break
                fi
                sleep 1
                _main_try=$((_main_try + 1))
            done
        fi
        if [ "$real_fixed_genesis_unavailable" = true ]; then
            :
        elif [ "$real_main_observed" = true ]; then
            ok "real Codex hook advances authenticated main_heartbeat_epoch"
        else
            real_main_after_raw="$(cat "$real_main_after_out" 2>/dev/null || true)"
            real_main_after_error="$(cat "$real_main_after_err" 2>/dev/null || true)"
            bad "real Codex hook advances authenticated main_heartbeat_epoch: before-rc=$real_main_before_rc before=[$real_main_before] before-raw=[$real_main_before_raw] before-stderr=[$real_main_before_error] after-rc=${real_main_after_rc:-unset} after=[$real_main_after] after-raw=[$real_main_after_raw] after-stderr=[$real_main_after_error] pane=$(tmux capture-pane -p -t "$TEST_SESSION" 2>/dev/null | tail -12); hook-input=$(tail -1 "$TMP/hook-input.jsonl" 2>/dev/null || true)"
        fi
    fi
    tmux kill-session -t "$TEST_SESSION" >/dev/null 2>&1 || true

    if [ "${1:-}" = "--real" ] && [ "$real_provenance_ready" = true ] && [ "$spawn_rc" -eq 0 ]; then
        standalone_task_dir="$TMP/standalone/.zyz-worker/tasks/hook-smoke"
        mkdir -p "$standalone_task_dir/runtime"
        printf 'hook-smoke\n' > "$TMP/standalone/.zyz-worker/current-task"
        cat > "$standalone_task_dir/status.md" <<'EOF'
# Task Status

## Current Phase

implementation
EOF
        standalone_main_before_out="$TMP/standalone-main-before.json"
        standalone_main_before_err="$TMP/standalone-main-before.err"
        standalone_main_before="$(main_epoch_from_observer "$real_observer" "$standalone_task_dir" "$standalone_main_before_out" "$standalone_main_before_err")"
        standalone_main_before_rc=$?
        standalone_main_before_raw="$(cat "$standalone_main_before_out" 2>/dev/null || true)"
        standalone_main_before_error="$(cat "$standalone_main_before_err" 2>/dev/null || true)"
        standalone_fixed_genesis_unavailable=false
        if fixed_observer_genesis_unavailable "$standalone_main_before_rc" "$standalone_main_before_raw" "$standalone_task_dir" false; then
            standalone_fixed_genesis_unavailable=true
        fi
        standalone_out="$(env -u PLUGIN_ROOT -u ZYZ_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT -u CODEX_PLUGIN_ROOT \
            ZYZ_HOOK_DEBUG_FILE="$TMP/standalone-hook-input.jsonl" \
            codex exec -C "$TMP/standalone" --skip-git-repo-check -s read-only \
            --dangerously-bypass-hook-trust --color never \
            'Use the shell tool to run pwd once, then reply exactly OK.' 2>&1)"
        standalone_rc=$?
        if [ "$standalone_rc" -eq 0 ] && [ -s "$TMP/standalone-hook-input.jsonl" ]; then
            ok "standalone Codex resolves installed hook root"
        else
            bad "standalone Codex resolves installed hook root: rc=$standalone_rc output=$standalone_out hook-input=$(tail -1 "$TMP/standalone-hook-input.jsonl" 2>/dev/null || true)"
        fi
        if [ -s "$TMP/standalone-hook-input.jsonl" ]; then
            ok "standalone Codex delivers hook JSON"
        else
            bad "standalone Codex delivers hook JSON"
        fi
        if [ "$standalone_fixed_genesis_unavailable" = true ]; then
            skip "standalone Codex hook main_heartbeat_epoch requires supported durable GENESIS capability" \
                "rc=$standalone_main_before_rc out=$standalone_main_before_raw stderr=$standalone_main_before_error"
        else
            standalone_main_after_out="$TMP/standalone-main-after.json"
            standalone_main_after_err="$TMP/standalone-main-after.err"
            standalone_main_after="$(main_epoch_from_observer "$real_observer" "$standalone_task_dir" "$standalone_main_after_out" "$standalone_main_after_err")"
            standalone_main_after_rc=$?
            if [ "$standalone_main_before_rc" -eq 0 ] && [ "$standalone_main_after_rc" -eq 0 ] \
                && main_epoch_advanced "$standalone_main_before" "$standalone_main_after"; then
                ok "standalone Codex hook advances authenticated main_heartbeat_epoch"
            else
                standalone_main_after_raw="$(cat "$standalone_main_after_out" 2>/dev/null || true)"
                standalone_main_after_error="$(cat "$standalone_main_after_err" 2>/dev/null || true)"
                bad "standalone Codex hook advances authenticated main_heartbeat_epoch: before-rc=$standalone_main_before_rc before=[$standalone_main_before] before-raw=[$standalone_main_before_raw] before-stderr=[$standalone_main_before_error] after-rc=$standalone_main_after_rc after=[$standalone_main_after] after-raw=[$standalone_main_after_raw] after-stderr=[$standalone_main_after_error] output=$standalone_out"
            fi
        fi
    fi
else
    skip "spawn integration (tmux/git/codex unavailable)"
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
has "$hook_manifest" 'PLUGIN_ROOT' "hooks commands include canonical installed plugin root"
has "$hook_manifest" 'ZYZ_PLUGIN_ROOT' "hooks commands resolve orchestrated plugin root"
has "$hook_manifest" 'CLAUDE_PLUGIN_ROOT' "hooks retain Claude plugin root"
has "$hook_manifest" 'CODEX_PLUGIN_ROOT' "hooks retain legacy Codex plugin root"
has "$hook_manifest" "/hooks/scripts/start-watchdog.sh" "Codex SessionStart watchdog registered"

printf '\nRESULT: %s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
