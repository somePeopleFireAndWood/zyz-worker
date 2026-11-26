#!/usr/bin/env python3
"""Review-round bookkeeping for the execute-task tiers (design §10.4, §10.5,
§10.7 items 1, 2 and 9).

How many rounds a review point may run, when a strict-tier point owes a
convergence check, and whether a point is closed are mechanical rules: this
module is the one place that reads, validates and edits them. The main agent
calls the ``review-round.sh`` wrapper (open / start / result / grant / check /
close / tier / status); the PreToolUse gate (``review-gate.sh``) and the L5
scope guard call ``gate`` and ``incremental``.

Rows live in the single ``## 评审收口`` section of ``status.md``:

    - Review: point=<id>; stage=<s>; kind=<main|aux>[; tier=<t>]; round=<n>; started=<unix>; blocking=<n|->; behavior=<n|->[; mode=full; reason=<text>]
    - Review-Grant: point=<id>; round=<n>; at=<unix>; reason=<text>
    - Review-Check: point=<id>; round=<n>; outcome=<o>; at=<unix>; reason=<text>
    - Review-Close: point=<id>; round=<n>; outcome=<passed|residual|split>; at=<unix>; reason=<text>

One ``Review`` row per round; ``open`` writes ``round=0`` (registered, not yet
started). ``tier=`` is the point's own tier (only ever stricter than the
task's); ``mode=full`` marks a round forced to a full review after a
structural fix. A ``Review-Grant`` names the round it authorizes, so it covers
that one round only. A ``Review-Check`` / ``Review-Close`` names the round it
was made after. Rows are appended in time order, so file order is history: a
``round=0`` row after a ``Review-Close`` starts a new set of records for that
point (``open`` after ``close``), and only the newest set counts.

The task tier is the first non-comment ``- Tier:`` line (``## 元数据``, right
under ``- Current Phase:``). No valid tier = a task from before the tiers:
``start`` records without a cap and the gate fails open.

Each row stands alone: a malformed or out-of-order row is reported and
ignored, never invalidates the others, and is never rewritten. Writers hold
the same ``runtime/expect.lock`` as expect.sh — both edit status.md
read-modify-write.
"""
from __future__ import annotations

import datetime as _dt
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from expect_state import _Lock, one_line, read_text, split_fields, write_atomic  # noqa: E402

HEADING = "## 评审收口"
POINT_RE = r"[a-z0-9][a-z0-9-]{0,63}"
EPOCH_RE = r"[1-9][0-9]{0,9}"
COUNT_RE = r"0|[1-9][0-9]{0,3}"
TIERS = ("fast", "standard", "strict")
RANK = {"fast": 0, "standard": 1, "strict": 2}
STAGES = ("design", "impl", "aggregate")
KINDS = ("main", "aux")
OUTCOMES = ("continue", "class-fix", "reorder", "escalate")
CLOSES = ("passed", "residual", "split")
# Total rounds per review point, first round included. None = no cap.
CAPS = {
    "fast": {"design": 0, "impl": 2, "aggregate": 1},
    "standard": {"design": 2, "impl": 3, "aggregate": 3},
    "strict": {"design": None, "impl": None, "aggregate": None},
}
ROW_RE = re.compile(r"^- (Review|Review-Grant|Review-Check|Review-Close): (.*)$")
TIER_RE = re.compile(r"^- Tier:(.*)$")
PHASE_RE = re.compile(r"^\s*[-*]?\s*current phase\s*:", re.I)
# Loose on purpose: a marker with a typo must be reported, not overlooked.
MARKER_RE = re.compile(r"review-point=(\S*)\s+round=(\S*)\s+mode=([A-Za-z]*)")
# The dispatch's tier line: `Tier: <t>` on a line of its own (not the
# `- Tier:` status row, which may be quoted in a brief and name the task tier).
DISPATCH_TIER_RE = re.compile(r"^[ \t>]*`?Tier:[ \t]*([^`\s]*)`?[ \t]*$", re.M)
FIELDS = {
    "Review": ({"point", "stage", "kind", "round", "started", "blocking", "behavior"}, {"tier", "mode", "reason"}),
    "Review-Grant": ({"point", "round", "at", "reason"}, set()),
    "Review-Check": ({"point", "round", "outcome", "at", "reason"}, set()),
    "Review-Close": ({"point", "round", "outcome", "at", "reason"}, set()),
}

EXIT_USAGE, EXIT_REFUSED = 2, 3


class Refused(Exception):
    """A policy refusal (exit 3): the message says what to do next."""


def die(msg):
    sys.stderr.write("review-round: %s\n" % msg)
    raise SystemExit(EXIT_USAGE)


def cli():
    return os.environ.get("ZYZ_REVIEW_ROUND_CLI") or "review-round.sh"


# ---------------------------------------------------------------- parsing ---

def noncomment(text):
    """(index, line) of every line outside an HTML comment (the templates
    document the row formats inside comments)."""
    in_c = False
    for i, raw in enumerate(text.split("\n")):
        line = raw.rstrip("\r")
        if in_c:
            if "-->" in line:
                in_c = False
            continue
        if line.lstrip().startswith("<!--"):
            in_c = "-->" not in line.lstrip()[4:]
            continue
        yield i, line


def scan(text):
    """(sections, [(index, line)] inside the single section, heading index,
    index of the section's last non-blank non-comment line) — where a new row
    is appended, so writer and parser agree on what is inside."""
    sections, inside, out = 0, False, []
    head = last = None
    for i, line in noncomment(text):
        if line.rstrip() == HEADING:
            sections += 1
            inside = True
            if head is None:
                head = last = i
            continue
        if inside and line.startswith("## "):
            inside = False
        if inside:
            out.append((i, line))
            if line.strip() and sections == 1:
                last = i
    return sections, out, head, last


def need(f, name, pattern, what):
    v = f.get(name, "")
    if not re.fullmatch(pattern, v):
        raise ValueError("%s must be %s" % (name, what))
    return v


def parse_row(kind, body):
    f = split_fields(body)
    required, optional = FIELDS[kind]
    if not required <= set(f) or set(f) - required - optional:
        raise ValueError("fields must be %s%s" % (",".join(sorted(required)),
                                                  " [+ %s]" % ",".join(sorted(optional)) if optional else ""))
    row = {"type": kind, "point": need(f, "point", POINT_RE, "[a-z0-9-]+")}
    if kind == "Review":
        row["stage"] = need(f, "stage", "|".join(STAGES), "/".join(STAGES))
        row["kind"] = need(f, "kind", "|".join(KINDS), "/".join(KINDS))
        row["tier"] = need(f, "tier", "|".join(TIERS), "/".join(TIERS)) if "tier" in f else None
        row["round"] = int(need(f, "round", r"0|[1-9][0-9]{0,3}", "a round number"))
        row["started"] = int(need(f, "started", EPOCH_RE, "an epoch"))
        b, m = f["blocking"], f["behavior"]
        row["blocking"] = None if b == "-" else int(need(f, "blocking", COUNT_RE, "a count or -"))
        row["behavior"] = None if m == "-" else int(need(f, "behavior", COUNT_RE, "a count or -"))
        if row["behavior"] is not None and (row["blocking"] is None or row["behavior"] > row["blocking"]):
            raise ValueError("behavior must not exceed blocking")
        if ("mode" in f) != ("reason" in f) or ("mode" in f and (f["mode"] != "full" or not f["reason"])):
            raise ValueError("mode=full comes with a non-empty reason")
        row["forced"] = "mode" in f
        row["reason"] = f.get("reason")
    else:
        row["round"] = int(need(f, "round", r"0|[1-9][0-9]{0,3}" if kind == "Review-Close"
                                else r"[1-9][0-9]{0,3}", "a round number"))
        row["at"] = int(need(f, "at", EPOCH_RE, "an epoch"))
        if kind == "Review-Check":
            row["outcome"] = need(f, "outcome", "|".join(OUTCOMES), "/".join(OUTCOMES))
        elif kind == "Review-Close":
            row["outcome"] = need(f, "outcome", "|".join(CLOSES), "/".join(CLOSES))
        row["reason"] = f["reason"]
        if not row["reason"]:
            raise ValueError("reason must be non-empty")
    return row


def new_point(row, gen):
    return {"stage": row["stage"], "kind": row["kind"], "rounds": {}, "index": {},
            "grants": {}, "checks": [], "closed": None, "gen": gen}


def read_state(text):
    """Parse every row of the section, in file (= time) order. Returns
    {"points": {point: {"stage", "kind", "rounds": {n: row}, "index": {n: line},
                        "grants": {n: row}, "checks": [row], "closed": row|None,
                        "gen": n}},
     "errors": [text]}; each point holds its newest set of records."""
    sections, lines, _, _ = scan(text)
    st = {"points": {}, "errors": [], "sections": sections}
    if sections > 1:
        st["errors"].append("status.md has %d '%s' sections; rows ignored" % (sections, HEADING))
        return st

    def err(line, why):
        st["errors"].append("%s  <- %s" % (line[:160], why))

    for i, line in lines:
        m = ROW_RE.match(line)
        if not m:
            if line.startswith("- Review"):
                err(line, "malformed")
            continue
        try:
            row = parse_row(m.group(1), m.group(2))
        except ValueError as e:
            err(line, e)
            continue
        p = row["point"]
        pt = st["points"].get(p)
        if row["type"] == "Review":
            if pt is not None and pt["closed"] is not None:
                if row["round"] != 0:
                    err(line, "point is closed; reopen it with open first")
                    continue
                pt = st["points"][p] = new_point(row, pt["gen"] + 1)
            elif pt is None:
                pt = st["points"][p] = new_point(row, 1)
            elif (pt["stage"], pt["kind"]) != (row["stage"], row["kind"]):
                err(line, "stage/kind differ from the point's first row")
                continue
            if row["round"] in pt["rounds"]:
                err(line, "duplicate round")
                continue
            pt["rounds"][row["round"]] = row
            pt["index"][row["round"]] = i
            continue
        if pt is None:
            err(line, "no such review point")
            continue
        if pt["closed"] is not None:
            err(line, "point is already closed")
            continue
        if row["type"] == "Review-Grant":
            pt["grants"].setdefault(row["round"], row)
        elif row["type"] == "Review-Check":
            pt["checks"].append(row)
        else:
            pt["closed"] = row
    return st


def read_tier(text):
    """(tier or None, line index or None). The first non-comment `- Tier:`
    line; an empty or unknown value is no tier (fail open)."""
    for i, line in noncomment(text):
        m = TIER_RE.match(line)
        if m:
            v = m.group(1).strip()
            return (v if v in TIERS else None), i
    return None, None


def latest(pt):
    return max(pt["rounds"]) if pt["rounds"] else None


def point_tier(pt):
    """The point's own tier field (on its newest row), or None."""
    last = latest(pt)
    return None if last is None else pt["rounds"][last]["tier"]


def effective(task_tier, pt):
    """The tier the point runs under: the stricter of the task's and its own."""
    ts = [t for t in (task_tier, point_tier(pt)) if t]
    return max(ts, key=RANK.get) if ts else None


# ------------------------------------------------------------------ rules ---

def cap_of(tier, stage):
    return None if tier is None else CAPS[tier][stage]


def round_mode(n, forced):
    return "full" if n == 1 or forced else "incremental"


def cross_harness(tier, stage, mode):
    if os.environ.get("ZYZ_CROSS_REVIEW", "auto") in ("off", "OFF", "0", "false", "no", "none"):
        return "no"
    if stage == "design":
        return "no" if tier == "fast" else "yes"
    return "yes" if mode == "full" else "no"


def decide(st, task_tier, point):
    """Whether round latest+1 of <point> may start: (code, message).
    code: ok | closed | needs-result | needs-grant | needs-check | escalated."""
    pt = st["points"][point]
    last = latest(pt) or 0
    n = last + 1
    if pt["closed"] is not None:
        return "closed", (
            "评审点 %s 已在第 %d 轮关闭（%s）。要重开，先运行 `%s open %s --stage %s`（生成新的一组记录），再 start。"
            % (point, pt["closed"]["round"], pt["closed"]["outcome"], cli(), point, pt["stage"]))
    if last >= 1 and pt["rounds"][last]["blocking"] is None:
        return "needs-result", (
            "评审点 %s 第 %d 轮还没有记录结果。先运行 `%s result %s --blocking <N> [--behavior <M>]`，再开第 %d 轮。"
            % (point, last, cli(), point, n))
    tier = effective(task_tier, pt)
    if tier is None:
        return "ok", ""
    stage = pt["stage"]
    cap = cap_of(tier, stage)
    if cap is not None and n > cap and n not in pt["grants"]:
        if cap == 0:
            return "needs-grant", (
                "快速档不派设计评审（评审点 %s 的上限是 0 轮）。确实需要设计评审时，先向用户提议升档"
                "（用户确认后 `%s open %s --tier standard` 只升这个评审点，或 `%s tier standard --reason <理由>` 升整个任务），"
                "或者经用户批准后运行 `%s grant %s --reason <用户批准的原话要点>` 再 start。"
                % (point, cli(), point, cli(), cli(), point))
        prev = pt["rounds"].get(last) or {}
        b, m = prev.get("blocking"), prev.get("behavior")
        return "needs-grant", (
            "评审点 %s（%s，Tier: %s）已用满上限 %d 轮，第 %d 轮没有用户授权。不要自行继续，也不要悄悄关闭："
            "用一条消息交给用户——列出剩余 blocking（第 %d 轮 blocking=%s，其中改变产品行为的 %s 条），每条写明可达性和影响，"
            "给出你的建议，请用户三选一：(1) 再开一轮（剩余问题涉及安全或数据、真实路径的缺陷还在减少时建议这一项）——"
            "用户批准后运行 `%s grant %s --reason <用户批准的原话要点>`，再 `%s start %s`；"
            "(2) 接受为遗留风险（写进 residual-risks.md，然后 `%s close %s --outcome residual --by user --reason …`）；"
            "(3) 拆成加固任务（`close %s --outcome split --by user --reason …`）。"
            % (point, stage, tier, cap, n, last, "-" if b is None else b, "-" if m is None else m,
               cli(), point, cli(), point, cli(), point, point))
    if tier == "strict" and n >= 4 and (n - 1) % 3 == 0:
        window = range(n - 3, n)
        done = [c for c in pt["checks"] if c["round"] in window]
        if not done:
            return "needs-check", (
                "严格档开第 %d 轮之前，要先对第 %d–%d 轮做一次收口检查（§4.5）：看 blocking 是否在收敛、"
                "反复出现的类是否该做类级修复、剩下的是否属于极端构造（进遗留清单），然后运行 "
                "`%s check %s --outcome continue|class-fix|reorder|escalate --reason <依据>`，再 start。"
                % (n, n - 3, n - 1, cli(), point))
        if done[-1]["outcome"] == "escalate" and n not in pt["grants"]:
            return "escalated", (
                "评审点 %s 上一次收口检查的结论是 escalate：先把情况交给用户决定。用户批准继续后运行 "
                "`%s grant %s --reason <用户批准的原话要点>`，再 start；或者按用户的决定 close。"
                % (point, cli(), point))
    return "ok", ""


# ---------------------------------------------------------------- editing ---

def now():
    raw = os.environ.get("ZYZ_REVIEW_NOW", "")
    return int(raw) if re.fullmatch(EPOCH_RE, raw) else int(time.time())


def review_line(point, stage, kind, n, started, blocking=None, behavior=None, tier=None, reason=None):
    dash = lambda v: "-" if v is None else str(v)
    return "- Review: point=%s; stage=%s; kind=%s%s; round=%d; started=%d; blocking=%s; behavior=%s%s" % (
        point, stage, kind, "; tier=" + tier if tier else "", n, started, dash(blocking), dash(behavior),
        "; mode=full; reason=" + reason if reason else "")


def rewrite(pt, n, **change):
    """The Review row of round n with some fields changed."""
    r = dict(pt["rounds"][n])
    r.update(change)
    return review_line(r["point"], r["stage"], r["kind"], r["round"], r["started"], r["blocking"],
                       r["behavior"], r["tier"], r["reason"] if r["forced"] else None)


def edit(path, change):
    """Under the lock: read status.md, let change(text, state, tier) return
    (new_text, result), write atomically keeping the newline style. change may
    raise Refused / SystemExit; nothing is written then."""
    with _Lock(path):
        if not os.path.exists(path):
            die("%s does not exist" % path)
        text, nl = read_text(path)
        st = read_state(text)
        tier, _ = read_tier(text)
        new, result = change(text, st, tier)
        if new is not None and new != text:
            write_atomic(path, new.replace("\n", nl) if nl != "\n" else new)
        return result


def append_rows(text, rows):
    sections, _, head, last = scan(text)
    if sections > 1:
        die("status.md has %d '%s' sections; fix it by hand first" % (sections, HEADING))
    lines = text.split("\n")
    if sections == 0:
        while lines and lines[-1] == "":
            lines.pop()
        return "\n".join(lines + ["", HEADING, ""] + rows + [""])
    out = []
    for i, l in enumerate(lines):
        out.append(l)
        if i == last:
            if last == head:
                out.append("")
            out.extend(rows)
    return "\n".join(out)


def replace_line(text, index, line):
    lines = text.split("\n")
    lines[index] = line
    return "\n".join(lines)


def verify(text, check):
    if not check(read_state(text)):
        die("refusing to write — the row would not take effect (unusual comment or heading layout?)")
    return text


def valid_point(p):
    if not re.fullmatch(POINT_RE, p or ""):
        die("bad point %r (use [a-z0-9-]+, e.g. design-main, impl-st2, aggregate)" % p)
    return p


def opts_of(args, flags, bools=()):
    out, rest = {}, list(args)
    while rest:
        a = rest.pop(0)
        if a in bools:
            out[a[2:]] = True
            continue
        if a not in flags or not rest:
            die("unexpected argument %r" % a)
        out[a[2:]] = rest.pop(0)
    return out


def reason_of(o):
    r = one_line(o.get("reason", ""))
    if not r or len(r.encode()) > 1024:
        die("--reason must be non-empty and <= 1024 bytes")
    return r


def by_of(o):
    by = o.get("by", "agent")
    if by not in ("user", "agent"):
        die("--by must be user or agent")
    return by


def open_point(st, point):
    pt = st["points"].get(point)
    if pt is None:
        die("point %s is not open — run `%s open %s --stage design|impl|aggregate` first" % (point, cli(), point))
    if pt["closed"] is not None:
        die("point %s is closed (%s at round %d) — `%s open %s` starts a new set of records"
            % (point, pt["closed"]["outcome"], pt["closed"]["round"], cli(), point))
    return pt


def describe(st, task_tier, point):
    pt = st["points"][point]
    last = latest(pt) or 0
    row = pt["rounds"][last]
    tier = effective(task_tier, pt)
    cap = cap_of(tier, pt["stage"])
    code, _ = decide(st, task_tier, point)
    hist = "→".join("-" if pt["rounds"][k]["blocking"] is None else str(pt["rounds"][k]["blocking"])
                    for k in sorted(pt["rounds"]) if k >= 1) or "-"
    n = last + 1
    mode = round_mode(n, False)
    closed = "%s@%d" % (pt["closed"]["outcome"], pt["closed"]["round"]) if pt["closed"] else "no"
    return ("%s stage=%s kind=%s tier=%s round=%d blocking=%s behavior=%s history=%s cap=%s closed=%s "
            "next=%d mode=%s cross-harness=%s gate=%s"
            % (point, pt["stage"], pt["kind"], tier or "none", last,
               "-" if row["blocking"] is None else row["blocking"],
               "-" if row["behavior"] is None else row["behavior"], hist,
               "none" if cap is None else cap, closed, n, mode,
               cross_harness(tier, pt["stage"], mode), code))


def cmd_open(path, args):
    if not args:
        die("usage: review-round.sh open <point> --stage design|impl|aggregate [--kind main|aux] [--tier standard|strict [--by user]]")
    point = valid_point(args[0])
    o = opts_of(args[1:], ("--stage", "--kind", "--tier", "--by"))
    by = by_of(o)
    for k, allowed in (("stage", STAGES), ("kind", KINDS), ("tier", TIERS)):
        if k in o and o[k] not in allowed:
            die("--%s must be one of %s" % (k, "/".join(allowed)))
    want = o.get("tier")

    def change(text, st, task_tier):
        pt = st["points"].get(point)
        if want and task_tier is None:
            die("this task has no valid `- Tier:` yet — set it with `%s tier …` before a per-point tier" % cli())
        if want and RANK[want] < RANK[task_tier]:
            die("a point's tier cannot be below the task's (Tier: %s)" % task_tier)
        own = want if want and want != task_tier else None
        if pt is None or pt["closed"] is not None:
            stage = o.get("stage") or (pt["stage"] if pt else "")
            if not stage:
                die("--stage design|impl|aggregate is required to open %s" % point)
            kind = o.get("kind") or (pt["kind"] if pt else "main")
            new = append_rows(text, [review_line(point, stage, kind, 0, now(), tier=own)])
            verify(new, lambda s: point in s["points"] and s["points"][point]["closed"] is None)
            return new, (read_state(new), task_tier, [])
        if ("stage" in o and o["stage"] != pt["stage"]) or ("kind" in o and o["kind"] != pt["kind"]):
            die("point %s is already open as stage=%s kind=%s" % (point, pt["stage"], pt["kind"]))
        if not want:
            return None, (st, task_tier, [])
        cur = effective(task_tier, pt)
        if want == cur:
            return None, (st, task_tier, ["note: 评审点 %s 的档位已是 %s" % (point, cur)])
        if RANK[want] < RANK[cur] and by != "user":
            raise Refused("评审点 %s 降档（%s → %s）只能由用户决定。用户明确同意后再运行 `%s open %s --tier %s --by user`。"
                          % (point, cur, want, cli(), point, want))
        last = latest(pt)
        new = replace_line(text, pt["index"][last], rewrite(pt, last, tier=own))
        verify(new, lambda s: effective(task_tier, s["points"][point]) == want)
        return new, (read_state(new), task_tier, ["note: 评审点 %s 的档位 %s → %s" % (point, cur, want)])

    st, task_tier, notes = edit(path, change)
    print(describe(st, task_tier, point))
    for n in notes:
        print(n)
    pt = st["points"][point]
    if effective(task_tier, pt) == "fast" and pt["stage"] == "design":
        print("note: 快速档不派设计评审（上限 0 轮）")


def cmd_start(path, args):
    if not args:
        die("usage: review-round.sh start <point> [--full --reason <text>]")
    point = valid_point(args[0])
    o = opts_of(args[1:], ("--reason",), ("--full",))
    full = bool(o.get("full"))
    if full:
        reason = reason_of(o)
    elif "reason" in o:
        die("--reason goes with --full")

    def change(text, st, task_tier):
        pt = st["points"].get(point)
        if pt is None:
            die("point %s is not open — run `%s open %s --stage design|impl|aggregate [--kind main|aux]` first"
                % (point, cli(), point))
        code, msg = decide(st, task_tier, point)
        if code != "ok":
            raise Refused(msg)
        n = (latest(pt) or 0) + 1
        forced = full and n >= 2
        new = append_rows(text, [review_line(point, pt["stage"], pt["kind"], n, now(), tier=point_tier(pt),
                                             reason=reason if forced else None)])
        verify(new, lambda s: point in s["points"] and latest(s["points"][point]) == n)
        mode = round_mode(n, forced)
        return new, (n, mode, cross_harness(effective(task_tier, pt), pt["stage"], mode))

    n, mode, xh = edit(path, change)
    print("round=%d mode=%s cross-harness=%s" % (n, mode, xh))


def cmd_result(path, args):
    if not args:
        die("usage: review-round.sh result <point> --blocking N [--behavior M]")
    point = valid_point(args[0])
    o = opts_of(args[1:], ("--blocking", "--behavior"))
    if not re.fullmatch(COUNT_RE, o.get("blocking", "")):
        die("--blocking must be a count (0..9999)")
    b = int(o["blocking"])
    m = None
    if "behavior" in o:
        if not re.fullmatch(COUNT_RE, o["behavior"]) or int(o["behavior"]) > b:
            die("--behavior must be a count no larger than --blocking")
        m = int(o["behavior"])

    def change(text, st, task_tier):
        pt = open_point(st, point)
        n = latest(pt) or 0
        if n < 1:
            die("point %s has not started a round — run `%s start %s` first" % (point, cli(), point))
        line = rewrite(pt, n, blocking=b, behavior=m)
        new = replace_line(text, pt["index"][n], line)
        verify(new, lambda s: s["points"][point]["rounds"].get(n, {}).get("blocking") == b)
        return new, (line, n, read_state(new), task_tier)

    line, n, st, task_tier = edit(path, change)
    print(line)
    if b == 0:
        print("note: 第 %d 轮没有 blocking——没有未处置的跨 harness 发现和待定用户决定时，用 `%s close %s --outcome passed --reason …` 关闭这个评审点"
              % (n, cli(), point))
    else:
        code, msg = decide(st, task_tier, point)
        if code != "ok":
            print("note: 下一轮现在还不能开——" + msg)


def cmd_grant(path, args):
    if not args:
        die("usage: review-round.sh grant <point> --reason <text>")
    point = valid_point(args[0])
    reason = reason_of(opts_of(args[1:], ("--reason",)))

    def change(text, st, task_tier):
        pt = open_point(st, point)
        n = (latest(pt) or 0) + 1
        if n in pt["grants"]:
            return None, "already granted: point=%s round=%d" % (point, n)
        line = "- Review-Grant: point=%s; round=%d; at=%d; reason=%s" % (point, n, now(), reason)
        new = append_rows(text, [line])
        verify(new, lambda s: n in s["points"][point]["grants"])
        return new, line

    print(edit(path, change))


def cmd_check(path, args):
    if not args:
        die("usage: review-round.sh check <point> --outcome continue|class-fix|reorder|escalate --reason <text>")
    point = valid_point(args[0])
    o = opts_of(args[1:], ("--outcome", "--reason"))
    outcome = o.get("outcome", "")
    if outcome not in OUTCOMES:
        die("--outcome must be one of " + "/".join(OUTCOMES))
    reason = reason_of(o)

    def change(text, st, task_tier):
        pt = open_point(st, point)
        n = latest(pt) or 0
        if n < 1:
            die("point %s has not run a round yet; nothing to check" % point)
        line = "- Review-Check: point=%s; round=%d; outcome=%s; at=%d; reason=%s" % (point, n, outcome, now(), reason)
        before = len(pt["checks"])
        new = append_rows(text, [line])
        verify(new, lambda s: len(s["points"][point]["checks"]) == before + 1)
        return new, line

    print(edit(path, change))


def cmd_close(path, args):
    if not args:
        die("usage: review-round.sh close <point> --outcome passed|residual|split [--by user] --reason <text>")
    point = valid_point(args[0])
    o = opts_of(args[1:], ("--outcome", "--reason", "--by"))
    outcome = o.get("outcome", "")
    if outcome not in CLOSES:
        die("--outcome must be one of " + "/".join(CLOSES))
    reason = reason_of(o)
    by = by_of(o)

    def change(text, st, task_tier):
        pt = open_point(st, point)
        n = latest(pt) or 0
        if outcome == "passed":
            if n < 1 or pt["rounds"][n]["blocking"] is None:
                raise Refused("评审点 %s 要以 passed 关闭，最近一轮要先 `result`，并且 blocking=0。" % point)
            if pt["rounds"][n]["blocking"] != 0:
                raise Refused("评审点 %s 第 %d 轮还有 %d 条 blocking，不能以 passed 关闭。修复后再开一轮；到上限时交用户三选一。"
                              % (point, n, pt["rounds"][n]["blocking"]))
        elif by != "user":
            raise Refused("以 %s 关闭评审点 %s 是用户在三选一里做的决定（§4.4）。用户明确选择后再运行 "
                          "`%s close %s --outcome %s --by user --reason <用户的原话要点>`。" % (outcome, point, cli(), point, outcome))
        line = "- Review-Close: point=%s; round=%d; outcome=%s; at=%d; reason=%s" % (point, n, outcome, now(), reason)
        new = append_rows(text, [line])
        verify(new, lambda s: s["points"][point]["closed"] is not None)
        return new, line

    print(edit(path, change))


def cmd_tier(path, args):
    if not args:
        die("usage: review-round.sh tier fast|standard|strict --reason <text> [--by user|agent]")
    new_tier = args[0]
    if new_tier not in TIERS:
        die("tier must be fast, standard or strict")
    o = opts_of(args[1:], ("--reason", "--by"))
    reason = reason_of(o)
    by = by_of(o)

    def change(text, st, tier):
        old, idx = read_tier(text)
        if old == new_tier:
            return None, "Tier unchanged: " + new_tier
        if old is not None and RANK[new_tier] < RANK[old] and by != "user":
            raise Refused(
                "降档（%s → %s）只能由用户决定。用户明确同意后再运行 `%s tier %s --by user --reason <用户的原话要点>`。"
                % (old, new_tier, cli(), new_tier))
        line = "- Tier: " + new_tier
        if idx is not None:
            new = replace_line(text, idx, line)
        else:
            anchor = next((i for i, l in noncomment(text) if PHASE_RE.match(l)), None)
            if anchor is None:
                die("status.md has no `- Current Phase:` line to put `- Tier:` under")
            lines = text.split("\n")
            lines.insert(anchor + 1, line)
            new = "\n".join(lines)
        if read_tier(new)[0] != new_tier:
            die("refusing to write — the Tier line would not take effect")
        # Still under the lock: the log entry and the status change land together.
        log = os.path.join(os.path.dirname(os.path.abspath(path)), "log", "tier.md")
        os.makedirs(os.path.dirname(log), exist_ok=True)
        prev = read_text(log)[0] if os.path.exists(log) else "# 档位变更记录\n\n"
        if not prev.endswith("\n"):
            prev += "\n"
        stamp = _dt.datetime.fromtimestamp(now()).astimezone().isoformat(timespec="seconds")
        write_atomic(log, prev + "- %s %s -> %s; by=%s; reason=%s\n" % (stamp, old or "-", new_tier, by, reason))
        return new, "%s (was %s)" % (line, old or "none")

    print(edit(path, change))


def cmd_status(path, args):
    text = read_text(path)[0]
    st = read_state(text)
    tier, _ = read_tier(text)
    print("Tier: " + (tier or "none（无档位：不设上限，闸门放行）"))
    points = sorted(st["points"])
    if args:
        point = valid_point(args[0])
        if point not in st["points"]:
            die("point %s is not open" % point)
        points = [point]
    if not points and not args:
        print("(no review points)")
    for p in points:
        print(describe(st, tier, p))
        code, msg = decide(st, tier, p)
        if code not in ("ok", "closed"):
            print("  " + msg)
    if not args and points:
        unclosed = [p for p in points if st["points"][p]["closed"] is None]
        print("unclosed: " + ", ".join(unclosed) if unclosed else "all review points closed")
    for e in st["errors"]:
        print("INVALID  " + e)


# ------------------------------------------------------------------ hooks ---

def load(paths):
    out = []
    for p in paths:
        try:
            text = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        out.append((p, read_state(text), read_tier(text)[0]))
    return out


def check_marker(tasks, point, rnd, mode):
    """None when the marker equals the latest started round of <point> (and
    that round's recorded mode) in one of the tasks, else the reason why not."""
    return match_marker(tasks, point, rnd, mode)[0]


def match_marker(tasks, point, rnd, mode):
    """(None, effective tier of the matched point) on a match, else
    (reason, None)."""
    why = _match(tasks, point, rnd, mode)
    if isinstance(why, tuple):
        return None, why[1]
    return why, None


def _match(tasks, point, rnd, mode):
    if not re.fullmatch(POINT_RE, point) or not re.fullmatch(r"[1-9][0-9]{0,3}", rnd) \
            or mode not in ("full", "incremental"):
        return ("标记 `review-point=%s round=%s mode=%s` 格式不对（要求 review-point=<[a-z0-9-]+> round=<正整数> mode=<full|incremental>）"
                % (point, rnd, mode))
    n = int(rnd)
    found = [(st["points"][point], t) for _, st, t in tasks if point in st["points"]]
    if not found:
        return "评审点 %s 还没有登记：先 `%s open %s --stage design|impl|aggregate`，再 `%s start %s`" % (
            point, cli(), point, cli(), point)
    for pt, t in found:
        last = latest(pt) or 0
        if pt["closed"] is None and last == n and round_mode(n, pt["rounds"][n]["forced"]) == mode:
            return ("ok", effective(t, pt))
    pt = found[0][0]
    last = latest(pt) or 0
    if pt["closed"] is not None:
        return "评审点 %s 已经关闭（%s）：要重开先 `%s open %s`，再 start" % (point, pt["closed"]["outcome"], cli(), point)
    if last < 1:
        return "评审点 %s 已登记但还没有开始任何一轮：先运行 `%s start %s`，把它输出的轮次写进派发 prompt" % (
            point, cli(), point)
    if n > last:
        return ("prompt 写的是评审点 %s 第 %d 轮，但 review-round.sh 记录的最新一轮是第 %d 轮：先运行 `%s start %s`"
                "（它会检查轮次上限），再用它输出的轮次和模式派发" % (point, n, last, cli(), point))
    want = round_mode(last, pt["rounds"][last]["forced"])
    if n < last:
        return "prompt 写的是评审点 %s 第 %d 轮，但最新一轮已经是第 %d 轮：把标记改成 `review-point=%s round=%d mode=%s`" % (
            point, n, last, point, last, want)
    if want == "full":
        return "评审点 %s 第 %d 轮记录的是全量评审：标记写 `mode=full`" % (point, n)
    return ("评审点 %s 第 %d 轮记录的是增量复审：标记写 `mode=incremental`；结构性修复后要全量复审，"
            "下一轮用 `%s start %s --full --reason <理由>` 开" % (point, n, cli(), point))


def cmd_gate(paths):
    """review-gate.sh: prompt on stdin. Prints `skip`, `ok`, or
    `deny<TAB><reason>`."""
    prompt = sys.stdin.read()
    tasks = load(paths)
    tiered = [(p, st, t) for p, st, t in tasks if t is not None]
    if not tiered:
        print("skip")
        return
    markers = MARKER_RE.findall(prompt)
    if not markers:
        pts = []
        for p, st, t in tiered:
            for name, pt in sorted(st["points"].items()):
                if pt["closed"] is not None:
                    continue
                last = latest(pt) or 0
                pts.append("%s（第 %d 轮）" % (name, last) if last else "%s（未开始）" % name)
        print("deny\t这个任务按档位（Tier: %s）限制评审轮次：派发 review-agent 的 prompt 里要有一行 "
              "`review-point=<id> round=<n> mode=<full|incremental>`，并且与 review-round.sh 记录的最新一轮一致，"
              "另起一行写评审点的生效档位 `Tier: <fast|standard|strict>`（`status <point>` 的 tier=）。"
              "先运行 `%s start <point>`（评审点还没登记就先 `open <point> --stage design|impl|aggregate`），"
              "把它输出的 round 和 mode 按这个格式写进 prompt，再重新派发。未关闭的评审点：%s。"
              % (tiered[0][2], cli(), "、".join(pts) or "无"))
        return
    tiers = DISPATCH_TIER_RE.findall(prompt)
    bad = [t for t in tiers if t not in TIERS]
    if bad:
        print("deny\t派发里的档位行 `Tier: %s` 不是 fast|standard|strict 之一。" % bad[0])
        return
    for point, rnd, mode in markers:
        why, tier = match_marker(tasks, point, rnd, mode)
        if why:
            print("deny\t" + why + "。")
            return
        if tier is not None and tier not in tiers:
            print("deny\t评审点 %s 的生效档位是 %s，派发里要单独一行写 `Tier: %s`%s——评审者按这一行选评审清单。"
                  "生效档位见 `%s status %s` 的 tier=。"
                  % (point, tier, tier, "（现在写的是 %s）" % "、".join(tiers) if tiers else "（现在没有这一行）",
                     cli(), point))
            return
    print("ok")


def cmd_incremental(paths):
    """L5: exit 0 when the prompt on stdin carries a mode=incremental marker
    that matches a started incremental round (n >= 2) of the task — a
    recorded incremental re-review, not a free-text claim."""
    prompt = sys.stdin.read()
    tasks = load(paths)
    for point, rnd, mode in MARKER_RE.findall(prompt):
        if mode == "incremental" and check_marker(tasks, point, rnd, mode) is None:
            raise SystemExit(0)
    raise SystemExit(1)


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    op = argv[1]
    if op == "gate":
        cmd_gate(argv[2:])
        return
    if op == "incremental":
        cmd_incremental(argv[2:])
        return
    if len(argv) < 3:
        die("missing status file")
    path, args = argv[2], argv[3:]
    cmds = {"open": cmd_open, "start": cmd_start, "result": cmd_result, "grant": cmd_grant,
            "check": cmd_check, "close": cmd_close, "tier": cmd_tier, "status": cmd_status}
    if op not in cmds:
        die("unknown command %r (open/start/result/grant/check/close/tier/status)" % op)
    try:
        cmds[op](path, args)
    except Refused as r:
        print("review-round: 拒绝——" + str(r))
        raise SystemExit(EXIT_REFUSED)


if __name__ == "__main__":
    main(sys.argv)
