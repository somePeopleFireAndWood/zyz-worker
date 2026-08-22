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
# - zyz_task_root <base>        the current task directory resolved via the
#                               `<base>/.zyz-worker/current-task` pointer
#                               (first line = task-id, or a path relative to
#                               <base>, or an absolute path), or empty when
#                               missing/dangling.
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
# - zyz_phase_active <phase>    0 when phase is implementation/testing/
#                               review/delivery (an active execution phase).
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
sections = 0; inside = False; candidates = []; bad = False
try:
    with open(p, "rb", buffering=0) as f:
        for raw in f:
            if len(raw) > 4096: bad = True; continue
            line = raw.rstrip(b"\n")
            if line.endswith(b"\r"): bad = True; continue
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

# Resolve a pointer file that lives under exactly one base directory.
# Returns the task dir on stdout, or nothing (rc 0) on any miss — fail-open.
zyz_resolve_pointer_at() {
    [ -n "${1:-}" ] || return 0
    local pointer target
    pointer="$1/.zyz-worker/current-task"
    [ -f "$pointer" ] || return 0
    target="$(head -n1 "$pointer" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$target" ] || return 0
    case "$target" in
        /*) ;;
        */*) target="$1/$target" ;;
        *) target="$1/.zyz-worker/tasks/$(zyz_sanitize "$target")" ;;
    esac
    [ -d "$target" ] || return 0
    printf '%s' "$target"
}

# True when the task dir's status.md reports a terminal phase. A finished task's
# leftover pointer must never win the worktree fallback below: pointers are never
# deleted anywhere in this plugin (cleanup removes worktrees, not the pointer
# inside them), so stale ones accumulate with worktree count and are exactly the
# wrong-attach candidates a searching resolver would hit. Phase-gating beats a
# cleanup step because it does not depend on anybody remembering to clean up.
zyz_task_is_done() {
    local st="${1:-}/status.md" ph
    [ -f "$st" ] || return 1
    ph="$(zyz_phase_of "$st")"
    case "$ph" in
        done) return 0 ;;
        *) return 1 ;;
    esac
}

zyz_task_root() {
    [ -n "${1:-}" ] || return 0
    local base found
    base="$1"

    # (a) Hot path, unchanged: the pointer directly under the given base. No
    # fork, no git, byte-identical to the historical behavior on a hit.
    found="$(zyz_resolve_pointer_at "$base")"
    if [ -n "$found" ]; then
        printf '%s' "$found"
        return 0
    fi

    # (b) Explicit override. Only usable where something exported it into the
    # environment before `claude` started (orchestrated spawn/reuse do this); a
    # skill cannot set it for itself, since each skill Bash call is a new shell.
    if [ -n "${ZYZ_TASK_DIR:-}" ] && [ -d "${ZYZ_TASK_DIR}" ]; then
        printf '%s' "$ZYZ_TASK_DIR"
        return 0
    fi

    # (c) Sibling git worktrees of the same repository.
    #
    # Why this direction: the plugin's own git-worktree skill puts new worktrees
    # OUTSIDE the main checkout (~/.zyz-worker/worktrees/...), so a task can run
    # — pointer and all — in a tree that the session cwd is not inside. Reducing
    # a linked worktree to its main checkout (`--show-toplevel` /
    # `--git-common-dir`) is the direction that already worked; the direction
    # that was unreachable is main checkout -> sibling worktree, which is what
    # this enumerates.
    #
    # NOT an unbounded upward walk: under the default layout the ancestor chain
    # climbs through $HOME/.zyz-worker, where a stray pointer would capture every
    # session under $HOME.
    #
    # Newest-first by status.md mtime, because `git worktree list` is ordered by
    # PATH — with two worktrees holding pointers, first-hit-wins would pick by
    # alphabetical accident rather than by which task is actually live. Terminal
    # (`phase: done`) tasks are skipped outright. Residual risk, stated plainly:
    # two genuinely concurrent execute-task runs in one repo can still attach to
    # the wrong one, so every fallback hit is logged (a wrong reminder is more
    # confusing than silence — it must at least be diagnosable).
    command -v git >/dev/null 2>&1 || return 0
    local common wt_dir cand best best_mt mt
    common="$(git -C "$base" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
    [ -n "$common" ] || return 0
    best=""; best_mt=""
    # The main checkout (parent of the common dir) plus each linked worktree.
    for wt_dir in "$(dirname "$common")" "$common"/worktrees/*/; do
        [ -d "$wt_dir" ] || continue
        cand="$wt_dir"
        # For a linked worktree, <common>/worktrees/<name>/gitdir holds the path
        # of its .git FILE; the worktree root is that file's parent.
        if [ -f "${wt_dir%/}/gitdir" ]; then
            cand="$(head -n1 "${wt_dir%/}/gitdir" 2>/dev/null)"
            [ -n "$cand" ] || continue
            cand="$(dirname "$cand")"
        fi
        [ -d "$cand" ] || continue
        [ "$cand" = "$base" ] && continue   # already tried in (a)
        found="$(zyz_resolve_pointer_at "$cand")"
        [ -n "$found" ] || continue
        zyz_task_is_done "$found" && continue
        mt="$(zyz_mtime "$found/status.md")"
        [ -n "$mt" ] || mt=0
        if [ -z "$best_mt" ] || [ "$mt" -gt "$best_mt" ]; then
            best="$found"; best_mt="$mt"
        fi
    done
    [ -n "$best" ] || return 0
    # Log the fallback hit so a wrong attach is diagnosable. Rate-limited by the
    # caller's own cooldowns is not enough here (this runs before any of them),
    # so keep it to one line appended per resolution; failures are ignored.
    if [ -d "$best/runtime" ] || mkdir -p "$best/runtime" 2>/dev/null; then
        printf '%s\tresolved via worktree fallback from base=%s\n' \
            "$(zyz_iso)" "$base" >> "$best/runtime/task-root-fallback.log" 2>/dev/null || true
    fi
    printf '%s' "$best"
}

zyz_phase_of() {
    # $1 = status.md path. Prints the lowercased text after the first
    # "Current Phase" LABEL line (list item or field, not arbitrary prose).
    [ -f "${1:-}" ] || return 0
    grep -iE '^[[:space:]]*[-*]?[[:space:]]*current phase[[:space:]]*:' "$1" 2>/dev/null | head -n1 \
        | sed 's/^[^:]*:*//' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

zyz_phase_active() {
    # $1 = phase string (already lowercased and space-stripped by zyz_phase_of).
    # Returns 0 only for a genuine active EXECUTION phase.
    #
    # Any phase naming `design` is quiet, and this exclusion must come FIRST:
    # `*review*` alone would match `design review` / `designreview`, making the
    # watchdog nag and — worse — making the L4 stop gate block the main agent
    # from idling at §2 step 8, the one gate the workflow mandates waiting at
    # indefinitely for human approval. The gate would push for action exactly
    # where the prompts promise silence. Both SKILL.md `## Watchdog Enforcement`
    # and the main-agent prompt promise the watchdog stays quiet during design.
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
    printf '%s' "$p" | grep -qE "(do|does|did|is|are|was|were|must|should|can|will) ?n.?o?t[^.;]{0,60}(blocker|critical|high.severity|high.priority|p[01]|severe)[a-z]*( (issue|finding|one|item)s?)? only" && return 0
    printf '%s' "$p" | grep -qE "^not [^.;]{0,60}(blocker|critical|high.severity|high.priority|p[01]|severe)[a-z]*( (issue|finding|one|item)s?)? only" && return 0
    printf '%s' "$p" | grep -qE "(more than|beyond) (just|only) (the )?(verdict|conclusion|summary)" && return 0
    printf '%s' "$p" | grep -qE "(不是|不只是|不能只|别只|不要只|不止)(要|给|报|写|看)?" && return 0
    # Careful: bare 不行 also appears in the DEGRADATION idiom "实在不行就先
    # 给一句话结论" (a fallback condition, not a negation), so require the
    # negation to attach to the truncation itself.
    printf '%s' "$p" | grep -qE "(总?结论|摘要|概要|几条|最严重)[^。；]{0,8}(不够|不足|不行|不可以|不允许)" && return 0
    printf '%s' "$p" | grep -qE "(不可以|不允许|禁止|不得)[^。；]{0,8}(只|仅|省略|忽略|截断|降级)" && return 0
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
    local p pat m scope_locale
    scope_locale="$(zyz_scope_utf8_locale 2>/dev/null || true)"
    if [ -n "$scope_locale" ]; then
        local LC_ALL="$scope_locale"
        export LC_ALL
    fi
    p="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' 2>/dev/null | tr '\n' ' ' 2>/dev/null)"
    [ -n "$p" ] || return 0
    # A prompt that explicitly forbids truncation is never a cap. Negation is
    # checked on the FULL text (before quote-stripping) so a quoted negation
    # keeps its veto.
    zyz_scope_negated "$p" && return 0
    # Caps are matched against the quote-stripped copy. Known tradeoff: a prompt
    # that is ENTIRELY a quoted cap now passes — acceptable, since a dispatch
    # whose whole body is one quoted string is not a plausible instruction,
    # whereas writing docs/tests about this guard is routine here.
    p="$(zyz_scope_strip_quotes "$p")"
    [ -n "$p" ] || return 0
    while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        m="$(printf '%s' "$p" | grep -oE "$pat" 2>/dev/null | head -n1)"
        if [ -n "$m" ]; then
            printf '%s' "$m"
            return 0
        fi
    done <<'ZYZ_CAP_PATTERNS'
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
(high.severity|high.priority|blocker|critical|p0|p1)(s| issues| findings| ones)? only
(focus |look )?only on (blockers|criticals?|the (worst|top|main|key|important))
(只要|只需|只给|仅给|仅需|只报|只写|只列|只看)[^。；,，]{0,12}(总?结论|结果|摘要|概要|几条|几个|几项|重点|关键|最严重|最重要)
(重点|关键|主要|重要)(问题|的?几条|的?几个)?(就行|即可|就好|足矣|即够)
(挑|选|列|给)[^。；,，]{0,4}(最|前)?(重要|严重|关键)的?(几|[0-9一二三四五六七八九十]+)(条|个|项)
最严重(的)?[0-9一二三四五六七八九十]+ ?(条|个|项)
一句话(总?结论|说明|交代|交待|结果)
(细节|其它|其他)[^。；,，]{0,4}(可以)?(省|省略|略过|忽略|不用|不必|不写)
(实在不行|不行的话|至少|最少)[^。；,，]{0,10}(一句话|总?结论)
(降级|放宽|放低)[^。；,，]{0,8}(要求|标准|目标)
ZYZ_CAP_PATTERNS
    return 0
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
    printf '%s' "$p" | grep -qE '第[0-9一二三四五六七八九十]+步' && return 0
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
