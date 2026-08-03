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
# - zyz_scan_stale <dir> <stale-sec> <horizon-sec>
#                               one "key<TAB>age" line per not-done agent
#                               whose last liveness is older than <stale-sec>
#                               but younger than <horizon-sec>.
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
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
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

zyz_task_root() {
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

zyz_scope_cap_hit() {
    # $1 = dispatch prompt text. Prints the first scope-capping phrase found
    # (so the deny reason can quote it), or nothing. Input is lowercased, so
    # English patterns need no case folding; the CJK ones are unaffected.
    local p pat m
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

zyz_scan_stale() {
    # $1 agents dir, $2 stale-sec, $3 horizon-sec.
    # A subagent counts as stale when it has a .start stamp, no .done mark,
    # and its last liveness (newest of .start/.heartbeat) is older than
    # stale-sec. Entries older than horizon-sec are orphans from finished
    # work and are skipped instead of nagging forever.
    local dir stale horizon now f key last hb age
    dir="${1:-}"; stale="${2:-900}"; horizon="${3:-21600}"
    [ -d "$dir" ] || return 0
    now="$(zyz_now)"
    for f in "$dir"/*.start; do
        [ -e "$f" ] || continue
        key="$(basename "$f" .start)"
        [ "$key" = "main" ] && continue
        [ -f "$dir/$key.done" ] && continue
        last="$(zyz_mtime "$f")"
        hb="$(zyz_mtime "$dir/$key.heartbeat")"
        [ -n "$hb" ] && [ "$hb" -gt "$last" ] && last="$hb"
        [ -n "$last" ] || continue
        age=$((now - last))
        [ "$age" -gt "$stale" ] || continue
        [ "$age" -lt "$horizon" ] || continue
        printf '%s\t%s\n' "$key" "$age"
    done
    return 0
}
