#!/usr/bin/env bash
#
# lib.sh — shared helpers for zyz-worker hook and monitor scripts.
#
# ## Trigger point
#
# Never executed directly; sourced by every script in this directory.
#
# ## Inputs
#
# - Callers set ZYZ_HOOK_INPUT to the raw hook JSON read from stdin before
#   calling zyz_get.
#
# ## Provided functions
#
# - zyz_json_ok                 0 when a JSON parser (jq or python3) exists.
# - zyz_get <dot.path>          string value at a dot path of ZYZ_HOOK_INPUT,
#                               or empty.
# - zyz_mtime <file>            mtime as epoch seconds (BSD or GNU stat).
# - zyz_now / zyz_iso           current epoch seconds / ISO 8601 timestamp.
# - zyz_sanitize <s>            s with chars outside [A-Za-z0-9._-] -> '_'.
# - zyz_session_id              this session's id: hook-input `session_id`
#                               (the PARENT session's id inside subagent hooks,
#                               verified on Claude Code and Codex), else
#                               $ZYZ_SESSION_ID, $CLAUDE_CODE_SESSION_ID,
#                               $CODEX_THREAD_ID; or empty.
# - zyz_session_ids             zyz_session_id plus, outside a hook (watchdog)
#                               and without $ZYZ_SESSION_ID, the live id from
#                               Claude's ~/.claude/sessions/$CLAUDE_PID.json;
#                               one per line, deduplicated.
# - zyz_task_roots <base>       every task directory of THIS session, one per
#                               line: the lines of the per-session pointer
#                               `.zyz-worker/sessions/<session-id>` (#23), else
#                               the first line of the legacy shared
#                               `.zyz-worker/current-task`, else $ZYZ_TASK_DIR.
#                               Each pointer is read under <base>, then under
#                               the session project dir ($CODEX_PROJECT_DIR /
#                               $CLAUDE_PROJECT_DIR). A pointer line is a
#                               task-id, a path relative to the pointer's base,
#                               or an absolute path; dangling lines are skipped.
#                               Deliberately NO search beyond these (#18).
# - zyz_task_root <base>        the first line of zyz_task_roots (the primary
#                               task), or empty.
# - zyz_roots_count / zyz_roots_any_active / zyz_roots_latest_status_mtime /
#   zyz_roots_label <roots>     over a zyz_task_roots list: task count; 0 when
#                               any task is in an active phase; newest
#                               status.md mtime (0 if none); comma-joined ids.
# - zyz_subagent_scope_note <roots> <record-root>
#                               empty for a one-task session, else the note
#                               that a subagent finding names no owning task.
# - zyz_write_atomic <f> <line> tmpfile+rename single-line write.
# - zyz_emit_context <ev> <msg> print hookSpecificOutput additionalContext
#                               JSON for event <ev>.
# - zyz_emit_block <reason>     print top-level {"decision":"block",...}
#                               (Stop / SubagentStop decision format).
# - zyz_emit_deny <ev> <reason> print hookSpecificOutput permissionDecision
#                               deny for <ev> (PreToolUse format; the reason
#                               IS shown to the model, unlike allow/ask).
# - zyz_scope_cap_hit <text>    first scope-capping phrase in <text> ("only
#                               the top 3", "只要总结论", …), or empty.
# - zyz_scope_continuation <text>
#                               0 when <text> commits to delivering the
#                               remainder ("then continue", "分步", "step 1
#                               of 4"), making a capped installment legit.
# - zyz_role_of <agent_type>    agent_type with plugin scope prefix stripped.
# - zyz_phase_of <status.md>    lowercased "Current Phase" value, or empty.
# - zyz_phase_terminal <phase>  0 when phase is a terminal spelling (done/
#                               delivered/completed/closed/... prefix match).
# - zyz_phase_active <phase>    0 when phase is implementation/testing/
#                               review/delivery (an active execution phase);
#                               terminal and design phases are never active.
# - zyz_epoch_in <file>         first line of <file> as an epoch int.
# - zyz_cooldown_ok <marker> <sec>
#                               0 when <sec> has elapsed since the marker's
#                               stored epoch (stamps the marker); 1 inside
#                               the cooldown window. Rate-limits nagging.
# - zyz_bg_running_types        agent_type of every background subagent task
#                               in ZYZ_HOOK_INPUT that is not completed or
#                               failed, one per line (Stop-event input).
# - zyz_runtime_observe <task-dir> <true|false>
#                               authenticated fixed-pack observer JSON; the
#                               boolean selects bounded no-output comparison.
# - zyz_main_state_set <task-dir> <state>
#                               atomically write `<state> <epoch>` to
#                               <task-dir>/runtime/main-state; <state> must be
#                               one of working/awaiting-user/idle/ended, else
#                               silent no-op (fail-open).
# - zyz_main_state_get <task-dir>
#                               print the current main-state string (first
#                               field), or empty when missing/corrupt/non-
#                               whitelisted (fail-open).
# - zyz_main_state_awaiting <task-dir>
#                               0 when the state is exactly awaiting-user, else
#                               1. Pure string compare (no epoch/TTL). Used only
#                               by main-state.sh Stop overwrite immunity.
# - zyz_main_state_suppresses <task-dir>
#                               0 when the state is awaiting-user OR idle, else
#                               1. Pure string compare (no epoch/TTL). The sole
#                               main-agent-attributed suppression gate for
#                               L3/L4/notify.
# - zyz_status_waits_due <status.md>
#                               `<key>\t<next>\t<reason>` per Waiting On row
#                               whose next-check-epoch has arrived (#24).
# - zyz_status_awaiting_user <status.md> <task-dir>
#                               0 for one valid `- Awaiting-User:` row written
#                               since the last user prompt (#24).
# - zyz_status_uncommitted <status.md>
#                               `<parsed>\t<ids>` of uncommitted SubTasks.
# - zyz_task_has_pending_work <phase> <ids>
#                               0 when the task still has executor work.
# - zyz_bg_executor_count       in-flight executors in the Stop input (plugin
#                               monitors excluded), or `unknown`.
# - zyz_live_role_count <horizon>
#                               non-terminal roles in observer JSON on stdin.
# - zyz_no_executor_msg <root> <phase> <ids> <stop|watchdog>
#                               the shared L3/L4 no-executor finding text.
#
# ## Failure behavior
#
# Every helper prints nothing and returns success on missing input. Callers
# treat empty output as "not available" and exit 0 — hooks fail open and
# must never break the agent loop.
#
# ## Supported agents
#
# All. Compatible with macOS bash 3.2 and Linux bash; no associative arrays.

zyz_json_ok() {
    command -v jq >/dev/null 2>&1 && return 0
    command -v python3 >/dev/null 2>&1 && return 0
    return 1
}

# NOTE on caching: memoizing this function in a shell variable does NOT work and
# has been tried. Every call site reads it as `x="$(zyz_get foo)"`, and command
# substitution runs in a SUBSHELL — any cache the function writes dies with that
# subshell and never reaches the next call. Measured A/B showed no improvement,
# only noise. To actually cut the per-tool-call jq cost, a caller must extract
# all the fields it needs in ONE pass (a single jq/python3 emitting several
# values) rather than calling zyz_get repeatedly; do that in the hook script, not
# behind this interface.
zyz_get() {
    [ -n "${ZYZ_HOOK_INPUT:-}" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$ZYZ_HOOK_INPUT" | jq -r ".${1} // empty" 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$ZYZ_HOOK_INPUT" | python3 -c '
import json, sys
path = sys.argv[1].split(".")
try:
    node = json.load(sys.stdin)
    for key in path:
        node = node[key]
    if node is None:
        sys.exit(0)
    if isinstance(node, bool):
        print("true" if node else "false")
    elif isinstance(node, (dict, list)):
        print(json.dumps(node))
    else:
        print(node)
except Exception:
    pass
' "$1" 2>/dev/null
        return 0
    fi
    return 0
}

zyz_mtime() {
    [ -e "${1:-}" ] || return 0
    local value
    value="$(stat -f %m "$1" 2>/dev/null || true)"
    case "$value" in
        ''|*[!0-9]*) value="$(stat -c %Y "$1" 2>/dev/null || true)" ;;
    esac
    case "$value" in
        ''|*[!0-9]*) return 0 ;;
        *) printf '%s\n' "$value" ;;
    esac
}

zyz_now() {
    date +%s
}

zyz_iso() {
    date +%Y-%m-%dT%H:%M:%S%z
}

zyz_sanitize() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Canonicalize the only role values that are valid in persisted runtime state.
# Returns 1 for every spelling outside the documented closed set.
zyz_canonical_role() {
    case "${1:-}" in
        implementation-agent|zyz-worker:implementation-agent) printf '%s' implementation-agent ;;
        test-agent|zyz-worker:test-agent) printf '%s' test-agent ;;
        review-agent|zyz-worker:review-agent) printf '%s' review-agent ;;
        *) return 1 ;;
    esac
}

zyz_sha256_text() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "${1:-}" | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "${1:-}" | sha256sum | awk '{print $1}'
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "${1:-}" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null
    fi
}

# A human-readable prefix is never an identity.  The complete raw-id digest is.
zyz_instance_key() {
    local prefix digest
    prefix="$(zyz_sanitize "${1:-}")"
    prefix="$(printf '%.32s' "$prefix")"
    [ -n "$prefix" ] || prefix=agent
    digest="$(zyz_sha256_text "${1:-}")"
    [ "${#digest}" -eq 64 ] || return 1
    printf '%s.%s' "$prefix" "$digest"
}

# Validate a public numeric setting before shell arithmetic. Invalid values use
# the default and emit one bounded diagnostic. Arguments: name default min max
# allow-zero. The validated decimal is printed.
zyz_env_uint() {
    local name def min max zero value
    name="$1"; def="$2"; min="$3"; max="$4"; zero="$5"
    eval 'value=${'"$name"'-__ZYZ_UNSET__}'
    case "$value" in
        __ZYZ_UNSET__) value="$def" ;;
        ''|*[!0-9]*) value="$def"; printf 'zyz-worker: invalid %s; using %s\n' "$name" "$def" >&2 ;;
        0[0-9]*) value="$def"; printf 'zyz-worker: non-canonical %s; using %s\n' "$name" "$def" >&2 ;;
        *)
            if [ "$zero" = 1 ] && [ "$value" = 0 ]; then printf '0'; return 0; fi
            if [ "${#value}" -gt "${#max}" ] \
                || { [ "${#value}" -eq "${#max}" ] && [ "$value" \> "$max" ]; } \
                || [ "${#value}" -lt "${#min}" ] \
                || { [ "${#value}" -eq "${#min}" ] && [ "$value" \< "$min" ]; }; then
                printf 'zyz-worker: invalid %s=%s; using %s\n' "$name" "$value" "$def" >&2
                value="$def"
            fi
            ;;
    esac
    printf '%s' "$value"
}

# Return 0 only when status.md has exactly one Agent State section and at least
# one strictly valid, unexpired Waiting On row. Any malformed candidate makes
# the complete collection fail open (freshness remains enabled).
zyz_status_waiting() {
    [ -f "${1:-}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    local max now
    max="$(zyz_env_uint ZYZ_WAIT_MAX_SEC 3600 1 86400 0)"
    now="$(zyz_now)"
    python3 - "$1" "$now" "$max" <<'PY'
import re, sys
p, now, horizon = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
heading = b"## Agent State"
row = re.compile(br"^- Waiting On: instance-key=([A-Za-z0-9._-]+); since-epoch=(0|[1-9][0-9]*); next-check-epoch=(0|[1-9][0-9]*); reason=(.*)$")
sections = 0; inside = False; candidates = []; bad = False; in_c = False
try:
    with open(p, "rb", buffering=0) as f:
        for raw in f:
            if len(raw) > 4096: bad = True; continue
            line = raw.rstrip(b"\n")
            if line.endswith(b"\r"): bad = True; continue
            # Skip HTML comments: the status template documents the row formats
            # inside a <!-- --> block in this very section, and an example row
            # must not count as a (malformed) declaration (#24).
            if in_c:
                if b"-->" in line: in_c = False
                continue
            if line.lstrip().startswith(b"<!--"):
                in_c = b"-->" not in line.lstrip()[4:]
                continue
            if line == heading: sections += 1; inside = True; continue
            if inside and line.startswith(b"## "): inside = False
            if inside and line.startswith(b"- Waiting On:"):
                m = row.fullmatch(line)
                if not m: bad = True; continue
                candidates.append(m.groups())
except OSError:
    sys.exit(1)
if sections != 1 or bad or not candidates: sys.exit(1)
seen = set()
for key, since_b, nxt_b, reason in candidates:
    try: reason.decode("utf-8")
    except UnicodeDecodeError: sys.exit(1)
    if len(reason) > 1024 or key in seen: sys.exit(1)
    seen.add(key)
    if len(since_b) > 10 or len(nxt_b) > 10: sys.exit(1)
    if (len(since_b)==10 and since_b>b"2147483647") or (len(nxt_b)==10 and nxt_b>b"2147483647"): sys.exit(1)
    since, nxt = int(since_b), int(nxt_b)
    if since < 1 or nxt < 1 or since > now or now >= nxt: sys.exit(1)
    if since > 2147483647-horizon or nxt > since+horizon: sys.exit(1)
sys.exit(0)
PY
}

# Print one `<key>\t<next-check-epoch>\t<reason>` line for every well-formed
# Waiting On row (same row grammar as zyz_status_waiting, in the single
# `## Agent State` section) whose next-check-epoch has arrived. Malformed rows
# are skipped individually: a due reminder for the valid ones is still useful.
zyz_status_waits_due() {
    [ -f "${1:-}" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$1" "$(zyz_now)" <<'PY' 2>/dev/null || true
import re, sys
p, now = sys.argv[1], int(sys.argv[2])
row = re.compile(r"^- Waiting On: instance-key=([A-Za-z0-9._-]+); since-epoch=(0|[1-9][0-9]{0,9}); next-check-epoch=(0|[1-9][0-9]{0,9}); reason=(.*)$")
sections = 0; inside = False; due = []; in_c = False
try:
    with open(p, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if in_c:
                if "-->" in line: in_c = False
                continue
            if line.lstrip().startswith("<!--"):
                in_c = "-->" not in line.lstrip()[4:]
                continue
            if line == "## Agent State": sections += 1; inside = True; continue
            if inside and line.startswith("## "): inside = False
            if inside:
                m = row.fullmatch(line)
                if m and 0 < int(m.group(3)) <= now:
                    due.append((m.group(1), m.group(3), m.group(4).strip()[:200].replace("\t", " ")))
except OSError:
    sys.exit(0)
if sections == 1:
    for key, nxt, reason in due: print(f"{key}\t{nxt}\t{reason}")
PY
}

# Return 0 when status.md declares that the main agent is waiting on the USER
# (#24): exactly one `## Agent State` section holding exactly one row
#   - Awaiting-User: since-epoch=<unix>; reason=<single-line text>
# with 0 < since-epoch <= now and a non-blank reason. The declaration lapses on
# its own the next time the user speaks: it is valid only while since-epoch is
# not older than the last UserPromptSubmit (<task-dir>/runtime/user-prompt-epoch,
# written by main-state.sh). So a forgotten row can never mute the no-executor
# check for good — after the user answers, the main agent must re-declare if it
# is still waiting. Anything malformed fails toward alerting (returns 1).
zyz_status_awaiting_user() {
    [ -f "${1:-}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    local prompt_epoch
    prompt_epoch="$(zyz_epoch_in "${2:-}/runtime/user-prompt-epoch")"
    python3 - "$1" "$(zyz_now)" "${prompt_epoch:-0}" <<'PY' 2>/dev/null
import re, sys
p, now, prompt = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
row = re.compile(r"^- Awaiting-User: since-epoch=([1-9][0-9]{0,9}); reason=(.*)$")
sections = 0; inside = False; rows = []; bad = False; in_c = False
try:
    with open(p, encoding="utf-8", errors="strict") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if in_c:
                if "-->" in line: in_c = False
                continue
            if line.lstrip().startswith("<!--"):
                in_c = "-->" not in line.lstrip()[4:]
                continue
            if line == "## Agent State": sections += 1; inside = True; continue
            if inside and line.startswith("## "): inside = False
            if inside and line.startswith("- Awaiting-User:"):
                m = row.fullmatch(line)
                if not m: bad = True; continue
                rows.append(m.groups())
except (OSError, UnicodeDecodeError):
    sys.exit(1)
if sections != 1 or bad or len(rows) != 1: sys.exit(1)
since, reason = int(rows[0][0]), rows[0][1].strip()
if not reason or len(reason) > 1024 or since > now or since < prompt: sys.exit(1)
sys.exit(0)
PY
}

# Print `<parsed-count>\t<comma-joined uncommitted ids>` for the `## SubTasks`
# scoreboard of status.md: either the template's list form (`- SubTask ID: X`
# followed by `- Committed: <sha|reason>`) or a Markdown table whose header has a
# SubTask/ID column and a Committed column. A row counts as uncommitted when its
# Committed value is empty, a placeholder, or a negative word. Best effort and
# only used to make the no-executor finding specific: `0\t` means "no scoreboard
# parsed", never "nothing left to do".
zyz_status_uncommitted() {
    [ -f "${1:-}" ] || { printf '0\t'; return 0; }
    command -v python3 >/dev/null 2>&1 || { printf '0\t'; return 0; }
    python3 - "$1" <<'PY' 2>/dev/null || printf '0\t'
import re, sys
SHA = re.compile(r"(?<![0-9A-Za-z])[0-9a-f]{7,40}(?![0-9A-Za-z])")
def pending(v):
    # A commit sha anywhere (`<repo>:<sha>` lines, a Markdown link, "local
    # commit abc1234, push failed") means committed. Otherwise an empty value,
    # a placeholder or a negative word is pending; any other text (a recorded
    # commit failure) is not — the template says a failure does not block.
    if SHA.search(v): return False
    v = v.strip().strip("`*").strip()
    low = v.lower()
    if not v or v[0] in "（(<[": return True
    if low in {"false", "no", "none", "pending", "todo", "tbd", "-", "—", "n/a", "无", "否"}: return True
    return low.startswith(("未", "待", "false", "no ", "pending", "not "))
rows = []; inside = False; cur = None; cols = None; in_c = False
committed = None  # [id, indent, collected values] while reading a Committed field
def flush():
    global committed
    if committed: rows.append((committed[0], pending(" ".join(committed[2]))))
    committed = None
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if in_c:
            if "-->" in line: in_c = False
            continue
        if line.lstrip().startswith("<!--"):
            in_c = "-->" not in line.lstrip()[4:]
            continue
        if line.startswith("## "):
            flush()
            inside = line.strip().lower().startswith("## subtasks"); cur = None; cols = None; continue
        if not inside: continue
        if committed is not None:
            # Multi-repo values continue on deeper-indented lines (`  - api:<sha>`).
            if not line.strip(): continue
            if len(line) - len(line.lstrip()) > committed[1]:
                committed[2].append(line.strip().lstrip("-*").strip()); continue
            flush()
        m = re.match(r"^\s*[-*]\s*SubTask ID\s*[:：]\s*(.*)$", line)
        if m:
            sid = m.group(1).strip()
            cur = sid if sid and sid[0] not in "（(<" else None
            continue
        m = re.match(r"^(\s*)[-*]\s*Committed\s*[:：]\s*(.*)$", line)
        if m and cur:
            committed = [cur, len(m.group(1)), [m.group(2)]]; cur = None; continue
        if line.lstrip().startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if cols is None:
                low = [c.lower() for c in cells]
                ci = next((i for i, c in enumerate(low) if "committed" in c), None)
                ii = next((i for i, c in enumerate(low) if "subtask" in c or c in ("id", "st")), None)
                if ci is not None and ii is not None: cols = (ii, ci)
                continue
            if all(re.fullmatch(r":?-{2,}:?", c or "--") for c in cells): continue
            ii, ci = cols
            if max(ii, ci) < len(cells) and cells[ii]:
                rows.append((cells[ii], pending(cells[ci])))
flush()
print(f"{len(rows)}\t" + ",".join(sid for sid, p in rows if p), end="")
PY
}

# 0 when the task still has work for an executor (#24): an active phase other
# than delivery, or a delivery phase with an uncommitted SubTask. $1 phase,
# $2 the zyz_status_uncommitted ids field.
zyz_task_has_pending_work() {
    zyz_phase_active "${1:-}" || return 1
    case "${1:-}" in
        *deliver*) [ -n "${2:-}" ] ;;
        *) return 0 ;;
    esac
}

# Number of in-flight executors in a Stop/SubagentStop ZYZ_HOOK_INPUT, or
# `unknown` when the host sent no background_tasks array (Codex, an unreachable
# task registry) — callers must then fail open. Counts every background task
# that is not finished (shell incl. Monitor watchers, subagent, teammate,
# workflow, MCP task, ...) plus every session cron/wakeup (it will wake the
# session). Plugin monitors are excluded: they live forever under
# `<plugin>/monitors/` — this very watchdog shows up as a `running` shell task
# (verified on Claude Code 2.1.251) and would otherwise mask every stall.
zyz_bg_executor_count() {
    [ -n "${ZYZ_HOOK_INPUT:-}" ] || { printf 'unknown'; return 0; }
    command -v python3 >/dev/null 2>&1 || { printf 'unknown'; return 0; }
    printf '%s' "$ZYZ_HOOK_INPUT" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown", end=""); sys.exit(0)
tasks = d.get("background_tasks") if isinstance(d, dict) else None
if not isinstance(tasks, list):
    print("unknown", end=""); sys.exit(0)
n = 0
for t in tasks:
    if not isinstance(t, dict):
        n += 1; continue
    st = str(t.get("status") or "").lower()
    if re.search(r"complet|fail|kill|stop|cancel|idle|done|error|exit|finish", st):
        continue
    cmd = str(t.get("command") or "")
    if "/monitors/watchdog.sh" in cmd or ("/plugins/" in cmd and "/monitors/" in cmd):
        continue
    n += 1
crons = d.get("session_crons")
if isinstance(crons, list):
    n += len(crons)
print(n, end="")
' 2>/dev/null || printf 'unknown'
}

# Number of non-terminal role instances younger than <horizon> in a
# zyz_runtime_observe JSON on stdin — dispatched roles that have not ended. A
# role older than the horizon is ignored, like every other role check. Prints
# nothing when the observer could not observe (macOS genesis-unavailable); the
# callers then leave the term out and rely on the harness's own task list.
zyz_live_role_count() {
    python3 -c '
import json, sys
try:
    horizon, now = int(sys.argv[1]), int(sys.argv[2]); data = json.load(sys.stdin)
    if data.get("ok") is not True or data.get("state") != "observed": raise ValueError()
    n = 0
    for item in data.get("instances", []):
        if item.get("terminal"): continue
        last = item.get("last_liveness_epoch")
        if not isinstance(last, int): last = item.get("start_epoch")
        if isinstance(last, int) and now - last >= horizon: continue
        n += 1
    print(n, end="")
except Exception:
    pass
' "${1:-21600}" "$(zyz_now)" 2>/dev/null || true
}

# The no-executor finding (#24), shared by L4 and L3 so both say the same
# thing. $1 task root, $2 phase, $3 uncommitted SubTask ids (may be empty),
# $4 `stop` (L4 block) or `watchdog` (L3 line).
zyz_no_executor_msg() {
    local root phase pending where task lead
    root="$1"; phase="$2"; pending="$3"; where="$4"
    task="$(basename "$root")"
    lead="任务 ${task} 仍在 ${phase} 阶段"
    [ -z "$pending" ] || lead="${lead}，SubTask ${pending} 尚未提交"
    if [ "$where" = stop ]; then
        lead="${lead}，但你要停下时没有任何执行者：没有在跑的 subagent 或后台任务（插件 monitor 不算），没有排定的唤醒，状态文件里也没有声明在等用户——你一停，就没有任何东西会再推动这个任务。"
    else
        lead="${lead}，但主 agent 停下已有一段时间，期间没有任何执行者：停下时没有在跑的 subagent 或后台任务（插件 monitor 不算）、没有排定的唤醒，此后也没有新的工具调用，状态文件里也没有声明在等用户——任务正在静默搁置。"
    fi
    printf '%s现在三选一：(1) 派发下一步（或自己接着做）；(2) 如果你认为某条通道还在跑，先核实再说（ps / ListAgents / 后台任务的输出文件）——"以为还在跑、其实早已结束"正是任务被静默搁置的常见原因，以"等待通知"收尾的 subagent 不会再被唤醒；(3) 如果确实在等用户，就在 %s 的 `## Agent State` 里写一行 `- Awaiting-User: since-epoch=<当前 unix 时间>; reason=<在等用户什么>`（用户下次发言后自动失效）。' \
        "$lead" "$root/status.md"
}

# Resolve one pointer line against the base dir the pointer lives under: an
# absolute path, a path relative to <base>, or a bare task-id under
# <base>/.zyz-worker/tasks/. Prints the task dir, or nothing when it is absent.
zyz_resolve_ref_at() {
    [ -n "${1:-}" ] || return 0
    local target
    target="$(printf '%s' "${2:-}" | tr -d '[:space:]')"
    [ -n "$target" ] || return 0
    case "$target" in
        /*) ;;
        */*) target="$1/$target" ;;
        *) target="$1/.zyz-worker/tasks/$(zyz_sanitize "$target")" ;;
    esac
    [ -d "$target" ] || return 0
    printf '%s' "$target"
}

# Resolve the legacy shared pointer that lives under exactly one base directory.
# Only its first line counts. Returns the task dir on stdout, or nothing (rc 0)
# on any miss — fail-open.
zyz_resolve_pointer_at() {
    [ -n "${1:-}" ] || return 0
    local pointer
    pointer="$1/.zyz-worker/current-task"
    [ -f "$pointer" ] || return 0
    zyz_resolve_ref_at "$1" "$(head -n1 "$pointer" 2>/dev/null)"
}

# Resolve the per-session pointer `<base>/.zyz-worker/sessions/<sid>` (#23).
# Every line is one task of that session; prints each existing task dir on its
# own line and skips blank or dangling lines.
zyz_resolve_session_pointer_at() {
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
    local pointer line dir
    pointer="$1/.zyz-worker/sessions/$(zyz_sanitize "$2")"
    [ -f "$pointer" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        dir="$(zyz_resolve_ref_at "$1" "$line")"
        [ -n "$dir" ] && printf '%s\n' "$dir"
    done < "$pointer"
    return 0
}

# The live session id Claude Code keeps in its per-process registry
# (~/.claude/sessions/<pid>.json). A monitor's environment is frozen when it is
# spawned, while the registry follows the running process.
zyz_claude_registry_sid() {
    case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
    local file
    file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$1.json"
    [ -f "$file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r '.sessionId // empty' "$file" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("sessionId") or "")
except Exception: pass' "$file" 2>/dev/null
    fi
    return 0
}

zyz_session_id() {
    local sid=""
    # Hook input first. Inside a subagent hook it is still the PARENT session's
    # id (verified on Claude Code and Codex), while a Codex subagent's own
    # $CODEX_THREAD_ID is the child thread — so the environment only backs up a
    # payload that lacks the field, and the watchdog, which has no payload.
    [ -n "${ZYZ_HOOK_INPUT:-}" ] && sid="$(zyz_get session_id)"
    [ -n "$sid" ] || sid="${ZYZ_SESSION_ID:-}"
    [ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
    [ -n "$sid" ] || sid="${CODEX_THREAD_ID:-}"
    printf '%s' "$sid"
}

zyz_session_ids() {
    {
        zyz_session_id
        printf '\n'
        if [ -z "${ZYZ_HOOK_INPUT:-}" ] && [ -z "${ZYZ_SESSION_ID:-}" ]; then
            zyz_claude_registry_sid "${CLAUDE_PID:-}"
            printf '\n'
        fi
    } | awk 'NF && !seen[$0]++'
}

# True when the task dir's status.md reports a terminal phase (see
# zyz_phase_terminal for the accepted spellings). Used by the watchdog's
# unarmed-suspicion gate: completed tasks legitimately leave their directories
# behind forever, so a terminal task dir is not evidence that a live task lost
# its pointer.
zyz_task_is_done() {
    local st="${1:-}/status.md" ph
    [ -f "$st" ] || return 1
    ph="$(zyz_phase_of "$st")"
    zyz_phase_terminal "$ph"
}

zyz_task_roots() {
    [ -n "${1:-}" ] || return 0
    local base found project_dir sids sid
    base="$1"
    # The session's own project dir. Hooks pass the payload cwd, which drifts
    # wherever the agent last `cd`-ed (the task dir, apps/api, ...) and then has
    # no pointer, while the watchdog resolves from the project dir. The mismatch
    # silently no-op'd every hook (heartbeat, Stop, Notification) so main-state
    # froze at `working` and the watchdog, still resolving the task, nagged
    # through hours of awaiting-user/idle. This is not a search (#18): it is the
    # one dir this session was launched in — the same one the watchdog trusts.
    project_dir="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
    [ "$project_dir" != "$base" ] || project_dir=""

    # (s) This session's own pointer (#23). The legacy `current-task` is one
    # file per directory, so two sessions running execute-task in the same
    # directory had to overwrite each other's pointer or run unarmed. Keying the
    # pointer by session id makes "which task is mine" a matter of identity, not
    # inference. Every line is one task; all of them are this session's.
    sids="$(zyz_session_ids)"
    if [ -n "$sids" ]; then
        found="$(while IFS= read -r sid; do
            [ -n "$sid" ] || continue
            zyz_resolve_session_pointer_at "$base" "$sid"
            [ -z "$project_dir" ] || zyz_resolve_session_pointer_at "$project_dir" "$sid"
        done <<EOF
$sids
EOF
)"
        if [ -n "$found" ]; then
            printf '%s\n' "$found" | awk 'NF && !seen[$0]++'
            return 0
        fi
    fi

    # (a) The legacy shared pointer directly under the given base, then (a')
    # under the session project dir. Reached only when this session has no
    # session pointer, so sessions that predate #23 (or run where no session id
    # is available) behave exactly as before.
    found="$(zyz_resolve_pointer_at "$base")"
    [ -n "$found" ] || [ -z "$project_dir" ] || found="$(zyz_resolve_pointer_at "$project_dir")"
    if [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 0
    fi

    # (b) Explicit override. Only usable where something exported it into the
    # environment before `claude` started (orchestrated spawn/reuse do this); a
    # skill cannot set it for itself, since each skill Bash call is a new shell.
    if [ -n "${ZYZ_TASK_DIR:-}" ] && [ -d "${ZYZ_TASK_DIR}" ]; then
        printf '%s\n' "$ZYZ_TASK_DIR"
        return 0
    fi

    # Deliberately NOTHING else. There used to be a (c) that enumerated sibling
    # git worktrees of the same repo and attached to the newest non-done task.
    # Removed (issue #18, real incident): with two concurrent execute-task runs
    # in one repo, a session whose own pointer went missing silently attached to
    # the OTHER session's task, and the watchdog then pushed this session's main
    # agent — with authoritative-looking, imperative staleness alerts backed by
    # the Stop gate — to write into a task dir it did not own. A searching
    # fallback trades a deterministic failure (no pointer -> layer silent, which
    # the §1 armed check already surfaces) for a probabilistic wrong answer that
    # is indistinguishable from a correct one. The scenario it covered (task in
    # a worktree the session cwd is not inside) is handled by the contract that
    # such pointers hold an ABSOLUTE path, plus $ZYZ_TASK_DIR for orchestrated
    # spawns. The same reasoning rules out "several pointers, pick the newest or
    # unfinished one": only the session id may decide ownership (#23).
    return 0
}

zyz_task_root() {
    [ -n "${1:-}" ] || return 0
    local roots
    roots="$(zyz_task_roots "$1")"
    printf '%s' "${roots%%
*}"
}

# ---- session-scoped subagent findings (#23) ---------------------------------
#
# Subagent runtime records live under exactly one task dir (the primary task,
# where subagent-track registered them), but no hook input says which of the
# session's tasks a subagent was dispatched FOR. Subagent findings are
# therefore session-scoped: they are reported whenever ANY task of the session
# is active, judged against the newest status write of ANY task, and, when the
# session has several tasks, worded so they never claim an owner — the main
# agent, which holds the dispatch record, decides. Each helper takes the
# newline-separated root list printed by zyz_task_roots.

zyz_roots_count() {
    printf '%s\n' "${1:-}" | awk 'NF' | wc -l | tr -d '[:space:]'
}

zyz_roots_any_active() {
    local r
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        zyz_phase_active "$(zyz_phase_of "$r/status.md")" && return 0
    done <<ZYZ_ROOTS
${1:-}
ZYZ_ROOTS
    return 1
}

zyz_roots_latest_status_mtime() {
    local r m best=0
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        m="$(zyz_mtime "$r/status.md")"
        [ -n "$m" ] && [ "$m" -gt "$best" ] && best="$m"
    done <<ZYZ_ROOTS
${1:-}
ZYZ_ROOTS
    printf '%s' "$best"
}

zyz_roots_label() {
    printf '%s\n' "${1:-}" | awk 'NF' | while IFS= read -r r; do basename "$r"; done \
        | awk 'NR > 1 { printf "," } { printf "%s", $0 }'
}

zyz_subagent_scope_note() {
    # $1 roots, $2 the task dir holding the runtime records. Prints nothing for a
    # single-task session (no ambiguity), else the attribution disclaimer.
    [ "$(zyz_roots_count "${1:-}")" -gt 1 ] || return 0
    printf '（本会话有多个任务：%s；watchdog 无法判断这个角色是为哪一个派发的——请按你的派发记录判断归属。它的运行时记录在 %s 下，finalize 等 runtime 命令的 <task-dir> 用这个目录；这不代表它属于该任务。）' \
        "$(printf '%s\n' "$1" | awk 'NF { printf "%s%s", (n++ ? "、" : ""), $0 }')" "${2:-}"
}

zyz_phase_of() {
    # $1 = status.md path. Prints the lowercased text after the first
    # "Current Phase" LABEL line (list item or field, not arbitrary prose).
    [ -f "${1:-}" ] || return 0
    grep -iE '^[[:space:]]*[-*]?[[:space:]]*current phase[[:space:]]*:' "$1" 2>/dev/null | head -n1 \
        | sed 's/^[^:]*:*//' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

zyz_phase_terminal() {
    # $1 = phase string (already lowercased and space-stripped by zyz_phase_of).
    # 0 when the phase is a TERMINAL spelling. The documented contract says
    # `done`, but real sessions write synonyms — the #18 incident's task wrote
    # `delivered` — and a finished task that is not recognized as terminal keeps
    # collecting staleness alerts forever (which is what pushed that session to
    # delete its pointer). Prefix match tolerates annotated forms such as
    # `done(delivered)` or `completed-awaiting-merge` (zyz_phase_of has already
    # stripped whitespace).
    case "${1:-}" in
        done*|delivered*|complete*|closed*|finished*|cancel*|abandon*) return 0 ;;
    esac
    return 1
}

zyz_phase_active() {
    # $1 = phase string (already lowercased and space-stripped by zyz_phase_of).
    # Returns 0 only for a genuine active EXECUTION phase.
    #
    # Terminal spellings are excluded FIRST: `*deliver*` alone would match
    # `delivered`, making every layer treat a finished task as active — the L1/
    # L3/L4 staleness machinery then nags a task that will never write status
    # again (the #18 incident).
    zyz_phase_terminal "${1:-}" && return 1
    # Any phase naming `design` is quiet, and this exclusion must come before
    # the active match: `*review*` alone would match `design review` /
    # `designreview`, making the watchdog nag and — worse — making the L4 stop
    # gate block the main agent from idling at §2 step 8, the one gate the
    # workflow mandates waiting at indefinitely for human approval. The gate
    # would push for action exactly where the prompts promise silence. Both
    # SKILL.md `## Watchdog 强制层` and the main-agent prompt promise the
    # watchdog stays quiet during design.
    case "${1:-}" in
        *design*) return 1 ;;
    esac
    case "${1:-}" in
        *implement*|*testing*|*review*|*deliver*) return 0 ;;
    esac
    return 1
}

zyz_epoch_in() {
    # $1 = file whose first line holds an epoch integer.
    [ -f "${1:-}" ] || return 0
    local v
    v="$(head -n1 "$1" 2>/dev/null | tr -d '[:space:]')"
    case "$v" in
        ''|*[!0-9]*) return 0 ;;
    esac
    printf '%s' "$v"
}

zyz_write_atomic() {
    local tmp
    tmp="$1.tmp.$$"
    printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    return 0
}

zyz_emit_context() {
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg e "$1" --arg m "$2" \
            '{hookSpecificOutput:{hookEventName:$e,additionalContext:$m}}' 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": sys.argv[1], "additionalContext": sys.argv[2]}}))
' "$1" "$2" 2>/dev/null
        return 0
    fi
    return 0
}

zyz_emit_block() {
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg r "$1" '{decision:"block",reason:$r}' 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
print(json.dumps({"decision": "block", "reason": sys.argv[1]}))
' "$1" 2>/dev/null
        return 0
    fi
    return 0
}

zyz_role_of() {
    printf '%s' "${1##*:}"
}

zyz_emit_deny() {
    # $1 = hook event name, $2 = reason shown to the model.
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg e "$1" --arg r "$2" \
            '{hookSpecificOutput:{hookEventName:$e,permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": sys.argv[1], "permissionDecision": "deny", "permissionDecisionReason": sys.argv[2]}}))
' "$1" "$2" 2>/dev/null
        return 0
    fi
    return 0
}

zyz_scope_negated() {
    # $1 = dispatch prompt text (already lowercased and flattened).
    # 0 when the text NEGATES a cap — i.e. it is telling the role NOT to
    # truncate. Without this veto the guard denies the very instruction the
    # anti-degradation rule teaches ("do not just report the verdict —
    # list every finding").
    local p
    p="${1:-}"
    printf '%s' "$p" | grep -qE "(do|does|did) ?n.?o?t (just|only|merely|simply)" && return 0
    printf '%s' "$p" | grep -qE "not (just|only|merely|simply) (the |a )?[a-z0-9]" && return 0
    printf '%s' "$p" | grep -qE "(more|rather) than (just|only) " && return 0
    printf '%s' "$p" | grep -qE "(is|are|would be) ?n.?o?t (enough|sufficient|fine|ok|acceptable)" && return 0
    # SEVERITY-FILTER caps ("blockers only", "p0 only", "critical ones only")
    # put the truncation word AFTER the noun, so the adjacency patterns above
    # never fire on their negations. Without this, the guard denies exactly the
    # anti-cap instruction the coverage-registration rules teach the main agent
    # to send ("do not run this as a blockers only review"). Match a negation
    # anywhere ahead of such a trailing `only` in the same clause.
    printf '%s' "$p" | grep -qE "(do|does|did|is|are|was|were|must|should|can|will) ?n.?o?t[^.;]{0,60}(blocker|blocking|critical|high.severity|high.priority|p[01]|severe)[a-z]*( (issue|finding|one|item)s?)? only" && return 0
    printf '%s' "$p" | grep -qE "^not [^.;]{0,60}(blocker|blocking|critical|high.severity|high.priority|p[01]|severe)[a-z]*( (issue|finding|one|item)s?)? only" && return 0
    # Same shape for the "report only blocking findings" / "skip the
    # non-blocking ones" family added with the #20 non-blocking vocabulary:
    # the anti-cap instruction ("do not report only blocking findings",
    # "never skip the non-blocking ones") must keep its veto.
    # A negated REPORT verb is only a veto when it negates "only" ("do not
    # report only blocking findings"); "do not report non-blocking:contrived
    # findings" IS a cap (#22). Negated skip-family verbs veto for every tier.
    printf '%s' "$p" | grep -qE "((do|does|did|is|are|was|were|must|should|can|will) ?n.?o?t|never)[^.;]{0,40}(report|give|return|send|list) ([a-z]+ )?only [^.;]{0,20}(blocking|non.blocking)" && return 0
    printf '%s' "$p" | grep -qE "((do|does|did|is|are|was|were|must|should|can|will) ?n.?o?t|never)[^.;]{0,40}(skip|drop|omit|ignore|leave out)[^.;]{0,30}(blocking|non.blocking|contrived)" && return 0
    printf '%s' "$p" | grep -qE "(more than|beyond) (just|only) (the )?(verdict|conclusion|summary)" && return 0
    printf '%s' "$p" | grep -qE "(不是|不只是|不能只|别只|不要只|不止)(要|给|报|写|看)?" && return 0
    # Careful: bare 不行 also appears in the DEGRADATION idiom "实在不行就先
    # 给一句话结论" (a fallback condition, not a negation), so require the
    # negation to attach to the truncation itself.
    printf '%s' "$p" | grep -qE "(总?结论|摘要|概要|几条|最严重)[^。；]{0,8}(不够|不足|不行|不可以|不允许)" && return 0
    printf '%s' "$p" | grep -qE "(不可以|不允许|禁止|不得)[^。；]{0,8}(只|仅|省略|忽略|截断|降级)" && return 0
    # "不要跳过边角情形" / "刁钻情形也不能忽略" negate the skip verb itself (#22).
    printf '%s' "$p" | grep -qE "(不要|不能|别|不得|不可|不准)[^。；，,]{0,4}(跳过|忽略|略过|不报)" && return 0
    return 1
}

zyz_scope_strip_quotes() {
    # $1 = prompt text. Blanks out quoted spans so a prompt that QUOTES a
    # capping phrase (docs, tests, changelog entries about this very guard —
    # routine work in this repo) is not read as issuing one. Single quotes are
    # only treated as quoting when the opener follows whitespace/punctuation, so
    # contractions ("don't") cannot pair up and swallow real instruction text.
    printf '%s' "${1:-}" \
        | sed -E -e 's/"[^"]*"/ /g' -e 's/`[^`]*`/ /g' \
                 -e "s/(^|[[:space:]([{:,])'[^']*'/\1 /g" 2>/dev/null
}

zyz_scope_unwrap_tiers() {
    # $1 = clause text. The #22 prompts spell finding tiers in backticks
    # (`blocking`, `non-blocking:contrived`), and quote-stripping would blank
    # exactly the noun a cap like "report only `blocking` findings" turns on.
    # Unwrap bare tier tokens first so the cap patterns still see them.
    printf '%s' "${1:-}" \
        | sed -E 's/`((non.)?blocking(:normal|:contrived)?|contrived)`/\1/g' 2>/dev/null
}

zyz_scope_clauses() {
    # $1 = flattened prompt text. One clause per line, split at sentence or
    # clause punctuation followed by a space (so "e.g." inside a word, "v1.2"
    # and "high.severity" stay whole) and at CJK terminators. Vetoes are then
    # judged per clause: a negation in one sentence must not license a cap in
    # another ("never skip contrived findings. report only the blocking ones").
    printf '%s\n' "${1:-}" | awk '{
        gsub(/[.;!?]+ /, "\n")
        sub(/[.;!?]+ *$/, "")
        gsub(/。|；|！|？/, "\n")
        print
    }' 2>/dev/null
}

zyz_scope_utf8_locale() {
    # Scope-cap regexes use bounded CJK character spans.  GNU grep interprets
    # those bounds bytewise in the POSIX/C locale, so select a known UTF-8
    # locale explicitly instead of inheriting the hook caller's locale.
    local candidate charmap
    for candidate in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 UTF-8; do
        charmap="$(LC_ALL="$candidate" locale charmap 2>/dev/null)" || continue
        case "$charmap" in
            UTF-8|UTF8|utf-8|utf8)
                printf '%s' "$candidate"
                return 0
                ;;
        esac
    done
    return 1
}

zyz_scope_cap_hit() {
    # $1 = dispatch prompt text. Prints the first scope-capping phrase found
    # (so the deny reason can quote it), or nothing. Input is lowercased, so
    # English patterns need no case folding; the CJK ones are unaffected.
    local p pat m scope_locale clause c pats
    scope_locale="$(zyz_scope_utf8_locale 2>/dev/null || true)"
    if [ -n "$scope_locale" ]; then
        local LC_ALL="$scope_locale"
        export LC_ALL
    fi
    p="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' 2>/dev/null | tr '\n' ' ' 2>/dev/null)"
    [ -n "$p" ] || return 0
    pats="$(zyz_scope_cap_patterns)"
    # Judged clause by clause (#22). A clause that explicitly forbids
    # truncation is never a cap; negation is checked on the clause BEFORE
    # quote-stripping so a quoted negation keeps its veto — but it vetoes only
    # its own clause, never a cap stated in a different sentence of the prompt.
    # Caps are matched against the quote-stripped clause. Known tradeoff: a
    # prompt that is ENTIRELY a quoted cap passes — acceptable, since a dispatch
    # whose whole body is one quoted string is not a plausible instruction,
    # whereas writing docs/tests about this guard is routine here.
    while IFS= read -r clause; do
        [ -n "$clause" ] || continue
        zyz_scope_negated "$clause" && continue
        c="$(zyz_scope_strip_quotes "$(zyz_scope_unwrap_tiers "$clause")")"
        [ -n "$c" ] || continue
        while IFS= read -r pat; do
            [ -n "$pat" ] || continue
            m="$(printf '%s' "$c" | grep -oE "$pat" 2>/dev/null | head -n1)"
            if [ -n "$m" ]; then
                printf '%s' "$m"
                return 0
            fi
        done <<ZYZ_CAP_PATTERN_LIST
$pats
ZYZ_CAP_PATTERN_LIST
    done <<ZYZ_CAP_CLAUSES
$(zyz_scope_clauses "$p")
ZYZ_CAP_CLAUSES
    return 0
}

zyz_scope_cap_patterns() {
    # One ERE per line, matched against a lowercased, quote-stripped clause.
    cat <<'ZYZ_CAP_PATTERNS'
(only|just) (the )?(top|most severe|worst) [a-z0-9]+ ?(findings|issues|problems)
(top|most severe|worst) [0-9]+ ?(findings|issues|problems) ?(is|are|would be)? ?(enough|fine|ok|okay|sufficient)
(limit(ed)?|cap(ped)?|restrict(ed)?|hold|keep|stop) (it |yourself |them |the (report|review|findings|list) )?(to|at|after) (just |only )?[0-9]+ ?(findings|issues|problems)
(no more than|at most|up to) [0-9]+ ?(findings|issues|problems)
(just|only) (give (me )?|report |return |send |the )*(overall |final |high.level |top.level )?(verdict|conclusion|summary|result)( is (enough|fine|ok))?
(verdict|conclusion|summary)(-| )only
one.(line|sentence) (verdict|conclusion|summary|answer|result)
(skip|drop|omit|forget|leave out) (the )?(details|specifics|rest|remainder|remaining|minor|less severe)
do ?n.?t (bother with|need) (the )?(details|specifics|rest)
do ?n.?t be (exhaustive|thorough|comprehensive)
a (short |brief |quick )?(summary|verdict|conclusion) (is|will be|would be) (enough|fine|ok|okay|sufficient)
(enough|fine|ok) (to )?(just )?(give|report) (the )?(verdict|conclusion|summary)
(high.severity|high.priority|blocker|blocking|critical|p0|p1)(s| issues| findings| ones)? only
(focus |look )?only on (blockers|blocking|criticals?|the (worst|top|main|key|important))
(report|give|return|send|list) (me )?only (the )?(blocking|blocker|critical|high.severity|high.priority|p[01])[a-z]*( (issue|finding|one|item)s?)?
(skip|drop|omit|ignore|leave out) (the )?non.blocking( (issue|finding|one|item)s?)?
(skip|drop|omit|ignore|leave out|exclude) (the |any )?(non.blocking:)?contrived( (issue|finding|one|item|case)s?)?
(skip|drop|omit|ignore|exclude) (anything|everything|whatever is) contrived
(do ?n.?t|never) (report|list|mention) (the |any )?(non.blocking:)?contrived( (issue|finding|one|item|case)s?)? *$
(do ?n.?t|never) (report|list|mention) (the |any )?non.blocking(:normal|:contrived)?( (issue|finding|one|item|case)s?)? *$
(no need to|need not|needn.?t) (report|list|mention|include) (the |any )?(non.blocking:)?contrived
do ?n.?t bother (with|reporting|listing) (the |any )?(non.blocking:)?contrived
leave (the |any )?(non.blocking:)?contrived[a-z ]{0,20} out
(non.blocking:)?contrived( (issue|finding|one|item|case)s?)? (can|may|should) be (left out|skipped|dropped|omitted|ignored)
(non.blocking:)?contrived( (issue|finding|one|item|case)s?)? (are|is) (not needed|unnecessary|not required) *$
(report|list) only (the )?non.contrived|only (report|list) (the )?non.contrived
(只要|只需|只给|仅给|仅需|只报|只写|只列|只看)[^。；,，]{0,12}(总?结论|结果|摘要|概要|几条|几个|几项|重点|关键|最严重|最重要)
(只报|只写|只列|只看|只处理|仅报|仅看)[^。；,，]{0,6}(阻塞|阻断|blocking)
(跳过|忽略|不用管|不必管|略过|不用报|不必报|不报)[^。；,，]{0,6}(非阻塞|非阻断|non.blocking)
(限|限制在|不超过|至多|最多) ?[0-9一二三四五六七八九十]+ ?(条|项) ?(的)?(发现|问题|意见|finding)
(限|限制在|不超过|至多|最多) ?[0-9一二三四五六七八九十]+ ?(条|项)(就行|即可|就好)?( *$|[,，])
(最严重|最重要)的? ?[0-9n一二三四五六七八九十几]+ ?(条|个|项)[^。；,，]{0,4}(就够|即可|就行|足够|足矣)
(跳过|忽略|不用管|不必管|略过|不用报|不必报|不报)[^。；,，]{0,6}(刁钻|边角)
(刁钻|边角)[^。；,，]{0,6}(不用报|不必报|不报|不用管|不必管|跳过|忽略|略过)
(跳过|忽略|略过|不用报|不必报|无需报|不报)[^。；,，]{0,6}(contrived|对抗)
(contrived|对抗)[^。；,，]{0,8}(不用|不必|无需)(报|列|管)
(重点|关键|主要|重要)(问题|的?几条|的?几个)?(就行|即可|就好|足矣|即够)
(挑|选|列|给)[^。；,，]{0,4}(最|前)?(重要|严重|关键)的?(几|[0-9一二三四五六七八九十]+)(条|个|项)
最严重(的)?[0-9一二三四五六七八九十]+ ?(条|个|项)
(只要|只给|只报|只列|只看)(前|头) ?[0-9一二三四五六七八九十几]+ ?(条|个|项)
一句话(总?结论|说明|交代|交待|结果)
一行(总?结论|说明|结果)
(细节|其它|其他)[^。；,，]{0,4}(可以)?(省|省略|略过|忽略|不用|不必|不写)
(实在不行|不行的话|至少|最少)[^。；,，]{0,10}(一句话|总?结论)
(降级|放宽|放低)[^。；,，]{0,8}(要求|标准|目标)
ZYZ_CAP_PATTERNS
}

zyz_scope_continuation() {
    # $1 = dispatch prompt text. 0 when the prompt commits to delivering the
    # remainder (so a capped first installment is legitimate staging, not a
    # scope reduction).
    local p
    p="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
    printf '%s' "$p" | grep -qE 'then (continue|the rest|cover|deliver|proceed|list|report|do)' && return 0
    printf '%s' "$p" | grep -qE '(the |, |plus (the )?|and (the )?)?(rest|remainder|remaining) (findings? )?(in|will|then|comes?|follow|later|second|next|afterwards?)' && return 0
    printf '%s' "$p" | grep -qE '(remaining|rest|others?) (in|as) (a |the )?(later|second|next|subsequent|follow)' && return 0
    printf '%s' "$p" | grep -qE 'in (a |the )?(later|subsequent|following|second|next) (message|response|pass|step|installment|batch)' && return 0
    printf '%s' "$p" | grep -qE '(step|part|installment|pass|batch) [0-9]+ ?(of|/) ?[0-9]+' && return 0
    printf '%s' "$p" | grep -qE 'all (four |4 )?(coverage )?dimensions' && return 0
    printf '%s' "$p" | grep -qE 'register (every|all) (dimension|categor)' && return 0
    printf '%s' "$p" | grep -qE '(分步|逐步|分批|分几步|分维度|分\s*[0-9一二三四五六七八九十]+\s*步|后续(再|继续)?|再继续|随后(再)?(列|给|补)|之后(再|补)|剩(下|余)的?(部分|内容|发现)?(再|后续|随后|列|给))' && return 0
    printf '%s' "$p" | grep -qE '其余[^。；,，]{0,6}(随后|之后|后续|再|稍后|接着|接下来|另)(列|给|报|补|发|说)' && return 0
    printf '%s' "$p" | grep -qE '第 ?[0-9一二三四五六七八九十]+ ?步' && return 0
    printf '%s' "$p" | grep -qE '然后(再)?继续|共 ?[0-9一二三四五六七八九十]+ ?步' && return 0
    return 1
}

zyz_cooldown_ok() {
    # $1 marker file, $2 cooldown seconds.
    local last now cd
    cd="$2"
    case "$cd" in
        ''|*[!0-9]*) cd=300 ;;
    esac
    last="$(zyz_epoch_in "$1")"
    now="$(zyz_now)"
    if [ -n "$last" ] && [ $((now - last)) -lt "$cd" ]; then
        return 1
    fi
    mkdir -p "$(dirname "$1")" 2>/dev/null
    zyz_write_atomic "$1" "$now"
    return 0
}

zyz_bg_running_types() {
    [ -n "${ZYZ_HOOK_INPUT:-}" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$ZYZ_HOOK_INPUT" | jq -r '
            (.background_tasks // [])[]
            | select(.type == "subagent")
            | select((.status // "") | test("complet|fail") | not)
            | .agent_type // empty' 2>/dev/null
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$ZYZ_HOOK_INPUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    for t in data.get("background_tasks") or []:
        if t.get("type") != "subagent":
            continue
        status = (t.get("status") or "").lower()
        if "complet" in status or "fail" in status:
            continue
        at = t.get("agent_type")
        if at:
            print(at)
except Exception:
    pass
' 2>/dev/null
        return 0
    fi
    return 0
}

zyz_runtime_observe() {
    # $1 task root, $2 whether to perform bounded no-output comparisons.
    # The Python observer enumerates only authenticated catalog owners and
    # reads logical records from fixed packs. Shell must never reconstruct
    # new-format identity/liveness/terminal state from directory membership.
    local root include lib_dir
    root="${1:-}"; include="${2:-false}"
    [ -d "$root" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 0
    python3 "$lib_dir/runtime_state.py" hook-observe "$root" "$include" 2>/dev/null || true
}

# ---- main-agent state machine (pure signal driven, NO TTL) ------------------
#
# A single-line file `<task-dir>/runtime/main-state` holding `<state> <epoch>`.
# <state> is one of working/awaiting-user/idle/ended. The epoch is written for
# diagnostics ONLY — the gates below compare the state STRING and never read
# the epoch, so there is no time-based expiry anywhere (the no-TTL guarantee).

zyz_main_state_set() {
    # $1 = task dir, $2 = state (working|awaiting-user|idle|ended).
    # Illegal state or unwritable runtime dir -> silent no-op (fail-open).
    local dir state
    dir="${1:-}"; state="${2:-}"
    [ -n "$dir" ] || return 0
    case "$state" in
        working|awaiting-user|idle|ended) ;;
        *) return 0 ;;
    esac
    mkdir -p "$dir/runtime" 2>/dev/null || return 0
    zyz_write_atomic "$dir/runtime/main-state" "$state $(zyz_now)"
}

zyz_main_state_get() {
    # $1 = task dir. Print the current state (first field) when it is in the
    # whitelist, else empty (missing/corrupt/non-whitelisted -> no state).
    local file first
    file="${1:-}/runtime/main-state"
    [ -f "$file" ] || return 0
    first="$(head -n1 "$file" 2>/dev/null | awk '{print $1}')"
    case "$first" in
        working|awaiting-user|idle|ended) printf '%s' "$first" ;;
    esac
}

zyz_main_state_awaiting() {
    # 0 when the state is exactly awaiting-user. Pure string compare, no epoch.
    # Used only by main-state.sh Stop overwrite immunity — NOT a suppression gate.
    [ "$(zyz_main_state_get "${1:-}")" = "awaiting-user" ]
}

zyz_main_state_suppresses() {
    # 0 when the state suppresses main-agent-attributed events (awaiting-user or
    # idle), else 1. Pure string compare, no epoch — the no-TTL guarantee.
    local s
    s="$(zyz_main_state_get "${1:-}")"
    [ "$s" = "awaiting-user" ] || [ "$s" = "idle" ]
}
