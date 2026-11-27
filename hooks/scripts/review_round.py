#!/usr/bin/env python3
"""Review-round bookkeeping for the execute-task tiers (design §10.4, §10.5,
§10.7 items 1, 2 and 9, §10.8, §11.4, §11.7 items 2, 4 and 7).

How many rounds a review point may run, when a strict-tier point owes a
convergence check, and whether a point is closed are mechanical rules: this
module is the one place that reads, validates and edits them. The main agent
calls the ``review-round.sh`` wrapper (open / start / result / grant / check /
close / tier / status); the PreToolUse gate (``review-gate.sh``) and the L5
scope guard call ``gate`` and ``incremental``.

Rows live in the single ``## 评审收口`` section of ``status.md``:

    - Review: point=<id>; stage=<s>; kind=<main|aux>[; tier=<t>]; round=<n>; started=<unix>; blocking=<n|->; rejected=<n|->; behavior=<n|->; induced=<n|->; pending=<n|->[; delta=+<a>/-<b>][; mode=full; reason=<text>]
    - Review-Grant: point=<id>; round=<n>; at=<unix>; reason=<text>
    - Review-Check: point=<id>; round=<n>; outcome=<o>; at=<unix>; reason=<text>
    - Review-Close: point=<id>; round=<n>; outcome=<passed|carried|residual|split>; at=<unix>; reason=<text>

One ``Review`` row per round; ``open`` writes ``round=0`` (registered, not yet
started). ``blocking`` counts the accepted blocking findings of the round,
``rejected`` the ones the reviewer reported as blocking but the adjudicator
rejected or downgraded (§10.8-1). ``induced`` counts the round's blockings
(accepted + rejected) that the previous round's revision brought in.
``pending`` is a state, not a part of the round's blockings: how many
blockings of the point are still waiting on a user answer when the round's
result is written, earlier rounds' included (the reviewer is told not to
report them again, so they are in no later ``blocking``) (§11.4). Both are
the main agent's own count. ``delta`` is the size of the revision a design
round reviews: lines added / removed against the previous round's snapshot of
the design documents (``<task-dir>/reviews/snap/<point>/r<n>/``), over the
documents both rounds captured (§11.7-2). Fields are read by name, so rows from before a field existed still parse. ``tier=`` is the
point's own tier (only ever stricter than the task's); ``mode=full`` marks a
round forced to a full review after a structural fix. A ``Review-Grant``
names the round it authorizes, so it covers that one round only. A
``Review-Check`` / ``Review-Close`` names the round it was made after. Rows
are appended in time order, so file order is history: a
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
import json
import os
import re
import shutil
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
CLOSES = ("passed", "carried", "residual", "split")
# Total rounds per review point, first round included. None = no cap.
CAPS = {
    "fast": {"design": 0, "impl": 2, "aggregate": 1},
    "standard": {"design": 3, "impl": 3, "aggregate": 3},
    "strict": {"design": None, "impl": None, "aggregate": None},
}
# §11.3-7: a standard point whose round 2 did not shrink stops before round 3.
EARLY_STOP_TIER, EARLY_STOP_ROUND = "standard", 3
DELTA_RE = re.compile(r"\+(0|[1-9][0-9]{0,8})/-(0|[1-9][0-9]{0,8})")
# The design documents of the task: the metadata line of status.md.
DOCS_RE = re.compile(r"^- (?:设计文档|Design Document)\s*[:：](.*)$")
# One document per item of a nested list right under that line (§11.7-7).
DOCS_ITEM_RE = re.compile(r"^[ \t]+[-*+][ \t]+(.*)$")
SNAP_MAX_BYTES = 4 * 1024 * 1024
# Next to a snapshot dir r<n>/: r<n>.sources.json — where its documents came
# from, and which documents the round listed or inherited but did not capture.
SNAP_SOURCES = ".sources.json"
ROW_RE = re.compile(r"^- (Review|Review-Grant|Review-Check|Review-Close): (.*)$")
TIER_RE = re.compile(r"^- Tier:(.*)$")
PHASE_RE = re.compile(r"^\s*[-*]?\s*current phase\s*:", re.I)
# Loose on purpose: a marker with a typo must be reported, not overlooked.
MARKER_RE = re.compile(r"review-point=(\S*)\s+round=(\S*)\s+mode=([A-Za-z]*)")
# The dispatch's tier line: `Tier: <t>` on a line of its own (not the
# `- Tier:` status row, which may be quoted in a brief and name the task tier).
DISPATCH_TIER_RE = re.compile(r"^[ \t>]*`?Tier:[ \t]*([^`\s]*)`?[ \t]*$", re.M)
FIELDS = {
    "Review": ({"point", "stage", "kind", "round", "started", "blocking", "behavior"},
               {"tier", "rejected", "induced", "pending", "delta", "mode", "reason"}),
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
        r = f.get("rejected", "-")
        row["rejected"] = None if r == "-" else int(need(f, "rejected", COUNT_RE, "a count or -"))
        if row["rejected"] is not None and row["blocking"] is None:
            raise ValueError("rejected comes with a result")
        for k in ("induced", "pending"):
            v = f.get(k, "-")
            row[k] = None if v == "-" else int(need(f, k, COUNT_RE, "a count or -"))
            if row[k] is not None and row["blocking"] is None:
                raise ValueError("%s comes with a result" % k)
        d = DELTA_RE.fullmatch(f["delta"]) if "delta" in f else None
        if "delta" in f and not d:
            raise ValueError("delta must be +<added>/-<removed>")
        row["delta"] = (int(d.group(1)), int(d.group(2))) if d else None
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


def cross_harness(tier, stage, mode, n):
    """design: every round (none on fast); impl: full rounds (round 1 and
    `start --full`); aggregate: round 1 only, a forced full round too
    (§10.8-7)."""
    if os.environ.get("ZYZ_CROSS_REVIEW", "auto") in ("off", "OFF", "0", "false", "no", "none"):
        return "no"
    if stage == "design":
        return "no" if tier == "fast" else "yes"
    if stage == "aggregate":
        return "yes" if n == 1 else "no"
    return "yes" if mode == "full" else "no"


def dash(v):
    return "-" if v is None else str(v)


def delta_text(d):
    return "-" if d is None else "+%d/-%d" % d


def reported(row):
    """What the reviewer reported as blocking in a round: accepted + rejected
    (§11.3-7)."""
    return (row.get("blocking") or 0) + (row.get("rejected") or 0)


def trend(pt):
    """One line per started round: `r<n> blocking=… rejected=… induced=…
    pending=… delta=…`."""
    return ["r%d blocking=%s rejected=%s induced=%s pending=%s delta=%s"
            % (k, dash(r["blocking"]), dash(r["rejected"]), dash(r["induced"]), dash(r["pending"]),
               delta_text(r["delta"]))
            for k, r in sorted(pt["rounds"].items()) if k >= 1]


def result_usage(point, n, tier):
    """The `result` command for round n: --induced and --pending are required
    from round 2 on a point that runs under a tier."""
    return "%s result %s --blocking <N> --rejected <R> %s [--behavior <M>]" % (
        cli(), point, "--induced <I> --pending <P>" if tier and n >= 2 else "[--induced <I>] [--pending <P>]")


def ask_user(point, pt, head, with_trend=True):
    """A refusal that hands the point to the user (§11.3-8): what happened,
    the trend of the rounds, the diagnosis to give, the four choices with the
    exact command of each."""
    lines = [head]
    if with_trend:
        lines.append("各轮走势（blocking = 被接受，rejected = 被拒绝或降级，induced = 上一轮修订带出，pending = 当时仍在等用户回答，"
                     "delta = 本轮评审的修订量 +增行/-删行）：")
        lines.extend("  " + t for t in trend(pt))
    lines += [
        "下一步：用一条消息把诊断交给用户（§11.3 第 8 条），给出你的建议，请用户四选一。",
        "诊断：(a) 各轮 blocking 走势和各轮修订量（上面的数字）；(b) 本轮 blocking 的来源——原有漏报、上一轮修订带出"
        "（含只落地一半的）、等用户决定各几条；(c) 剩余 blocking 分成结构类（要改模块划分、接口或数据模型）和细节类"
        "（某个模块内部的规则），每条写明可达性和影响。只剩细节类时推荐「带着进实现」。",
        "选项：",
        "  (1) 再开一轮（剩余问题涉及安全或数据、真实路径的缺陷还在减少时建议这一项）：用户批准后 "
        "`%s grant %s --reason <用户批准的原话要点>`，再 `%s start %s`" % (cli(), point, cli(), point),
        "  (2) 带着进实现：每条写成 impl-notes.md「带进实现的 blocking」里必须通过的测试项，交付前逐条核对，然后 "
        "`%s close %s --outcome carried --by user --reason <用户的原话要点>`" % (cli(), point),
        "  (3) 接受为遗留风险：写进 residual-risks.md，然后 "
        "`%s close %s --outcome residual --by user --reason <用户的原话要点>`" % (cli(), point),
        "  (4) 拆成加固任务：`%s close %s --outcome split --by user --reason <用户的原话要点>`" % (cli(), point),
    ]
    return "\n".join(lines)


def decide(st, task_tier, point, with_trend=True):
    """Whether round latest+1 of <point> may start: (code, message).
    code: ok | closed | needs-result | needs-grant | not-converging |
    needs-check | escalated."""
    pt = st["points"][point]
    last = latest(pt) or 0
    n = last + 1
    if pt["closed"] is not None:
        return "closed", (
            "评审点 %s 已在第 %d 轮关闭（%s）。要重开，先运行 `%s open %s --stage %s`（生成新的一组记录），再 start。"
            % (point, pt["closed"]["round"], pt["closed"]["outcome"], cli(), point, pt["stage"]))
    if last >= 1 and pt["rounds"][last]["blocking"] is None:
        return "needs-result", (
            "评审点 %s 第 %d 轮还没有记录结果。先运行 `%s`，再开第 %d 轮。"
            % (point, last, result_usage(point, last, effective(task_tier, pt)), n))
    # An escalate check holds the next round at any round, on any tier, until
    # the user grants it (§10.8-5). Only the newest check counts, and only
    # until a round after it has started.
    if pt["checks"] and pt["checks"][-1]["outcome"] == "escalate" and pt["checks"][-1]["round"] == last \
            and n not in pt["grants"]:
        return "escalated", ask_user(point, pt, (
            "评审点 %s 第 %d 轮之后的收口检查结论是 escalate：先把情况交给用户决定，第 %d 轮没有用户授权。"
            "不要自行继续，也不要悄悄关闭。" % (point, last, n)), with_trend)
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
        return "needs-grant", ask_user(point, pt, (
            "评审点 %s（%s，Tier: %s）已用满上限 %d 轮，第 %d 轮没有用户授权。不要自行继续，也不要悄悄关闭。"
            "第 %d 轮 blocking=%s，其中改变产品行为的 %s 条；被裁决者拒绝或降级、仍有争议的 %s 条。"
            % (point, stage, tier, cap, n, last, dash(prev.get("blocking")), dash(prev.get("behavior")),
               dash(prev.get("rejected")))), with_trend)
    # §11.3-7: round 2 reported no fewer blockings than round 1 — more rounds
    # of the same kind will not converge, so the user decides before round 3.
    # (A round 2 that reported none has converged, whatever round 1 said.)
    r1, r2 = pt["rounds"].get(1), pt["rounds"].get(2)
    if tier == EARLY_STOP_TIER and n == EARLY_STOP_ROUND and n not in pt["grants"] and r1 and r2 \
            and r1["blocking"] is not None and reported(r2) >= max(reported(r1), 1):
        return "not-converging", ask_user(point, pt, (
            "评审点 %s（%s，Tier: %s）第 2 轮没有收敛：blocking + rejected 第 1 轮 %d 条、第 2 轮 %d 条（不少于第 1 轮），"
            "第 3 轮没有用户授权。不要自行继续，也不要悄悄关闭。"
            % (point, stage, tier, reported(r1), reported(r2))), with_trend)
    # Only a check made after the group of three just finished counts
    # (§10.8-5): an early check in the window does not cover it.
    if tier == "strict" and n >= 4 and (n - 1) % 3 == 0 \
            and not any(c["round"] == n - 1 for c in pt["checks"]):
        return "needs-check", (
            "严格档开第 %d 轮之前，要在第 %d 轮之后对第 %d–%d 轮做一次收口检查（§4.5；更早做的检查不算）："
            "看 blocking 是否在收敛、反复出现的类是否该做类级修复、剩下的是否属于极端构造（进遗留清单），然后运行 "
            "`%s check %s --outcome continue|class-fix|reorder|escalate --reason <依据>`，再 start。"
            % (n, n - 1, n - 3, n - 1, cli(), point))
    return "ok", ""


# ---------------------------------------------------------------- editing ---

def now():
    raw = os.environ.get("ZYZ_REVIEW_NOW", "")
    return int(raw) if re.fullmatch(EPOCH_RE, raw) else int(time.time())


def review_line(point, stage, kind, n, started, blocking=None, behavior=None, tier=None, reason=None,
                rejected=None, induced=None, pending=None, delta=None):
    return ("- Review: point=%s; stage=%s; kind=%s%s; round=%d; started=%d; blocking=%s; rejected=%s; behavior=%s; "
            "induced=%s; pending=%s%s%s") % (
        point, stage, kind, "; tier=" + tier if tier else "", n, started, dash(blocking), dash(rejected),
        dash(behavior), dash(induced), dash(pending), "; delta=" + delta_text(delta) if delta else "",
        "; mode=full; reason=" + reason if reason else "")


def rewrite(pt, n, **change):
    """The Review row of round n with some fields changed."""
    r = dict(pt["rounds"][n])
    r.update(change)
    return review_line(r["point"], r["stage"], r["kind"], r["round"], r["started"], r["blocking"],
                       r["behavior"], r["tier"], r["reason"] if r["forced"] else None, r["rejected"],
                       r["induced"], r["pending"], r["delta"])


# -------------------------------------------------------------- snapshots ---

def doc_values(text):
    """What the `- 设计文档:` metadata line of status.md names: [(value,
    nested)] — the text after the colon, then one value per item of a nested
    list right under the line (`  - <path>`, no blank line in between)."""
    lines = [l for _, l in noncomment(text)]
    for k, line in enumerate(lines):
        m = DOCS_RE.match(line)
        if not m:
            continue
        out = [(m.group(1), False)]
        for nxt in lines[k + 1:]:
            item = DOCS_ITEM_RE.match(nxt)
            if not item:
                break
            out.append((item.group(1), True))
        return out
    return []


def resolve_doc(name, bases):
    """(real path of the readable file <name>, or None; whether <name> is a
    directory instead). Relative names are tried against each base in turn."""
    path = os.path.expanduser(name)
    cands = [path] if os.path.isabs(path) else [os.path.join(b, path) for b in bases]
    for c in cands:
        if os.path.isfile(c) and os.access(c, os.R_OK):
            return os.path.realpath(c), False
    return None, any(os.path.isdir(c) for c in cands)


def in_existing_dir(name, bases):
    """Whether <name> names something inside a directory that exists: a path
    with a directory part, and that directory is there."""
    parent = os.path.dirname(os.path.expanduser(name))
    if not parent:
        return False
    return any(os.path.isdir(c) for c in ([parent] if os.path.isabs(parent) else [os.path.join(b, parent) for b in bases]))


def find_docs(text, task_dir, given):
    """The design documents a round reviews: (readable files, names that are
    not one, paths inside the snapshot dir). `given` = the --docs paths
    (relative: cwd, then the task dir); every one of them is either taken or
    reported. None = the `- 设计文档:` line of status.md and the nested list
    under it (relative: the task dir, then cwd). That line is free text: full-width parenthesised notes are
    dropped; a value that is one path as a whole (blanks allowed) is taken as
    such; otherwise it is split on commas / 、 / ； / blanks. A piece that is
    not a readable file is reported when the disk or the markup says it is a
    path: it is a directory; it lies in a directory that exists (`design/`
    is there, `design/typo.md` is not); it stands in backticks or as a
    Markdown link target; or it is a nested-list item nothing was read from.
    Any other piece is prose and is skipped without a word — the shape of a
    word is never taken for a path (§11.7-7)."""
    snap_root = os.path.realpath(os.path.join(task_dir, "reviews", "snap")) + os.sep
    found, seen, missing, inside = [], set(), [], []

    def take(real, name):
        # A copy inside the snapshot dir is never a document under review
        # (`--docs <task-dir>/**/*.md` lists them): snapshotting it would
        # nest every earlier round inside the new one.
        if real.startswith(snap_root):
            inside.append(name)
        elif real not in seen:
            seen.add(real)
            found.append(real)

    def miss(name):
        if name not in missing:
            missing.append(name)

    if given is not None:
        for name in given:
            real, _ = resolve_doc(name, (os.getcwd(), task_dir))
            if real:
                take(real, name)
            else:
                miss(name)
        return found, missing, inside
    bases = (task_dir, os.getcwd())
    for value, nested in doc_values(text):
        value = re.sub(r"（[^（）]*）", " ", value)
        whole = value.strip().strip("`'\"")
        if not whole:
            continue
        real, _ = resolve_doc(whole, bases)
        if real:
            take(real, whole)
            continue
        marked = re.findall(r"\]\(([^()\s]+)\)", value) + re.findall(r"`([^`]+)`", value)
        pieces = marked + [t.strip("`'\"<>。") for t in re.split(r"[,，、;；\s]+", value)]
        hit, before = False, len(missing)
        for name in dict.fromkeys(x for x in pieces if x):
            real, is_dir = resolve_doc(name, bases)
            if real:
                take(real, name)
                hit = True
            elif name in marked:
                miss(name)
            elif name.strip("./~") and (is_dir or in_existing_dir(name, bases)):
                miss(name)  # not a bare `/`, `.` or `..` standing in the prose
        if nested and not hit and len(missing) == before:
            miss(whole)
    return found, missing, inside


def snap_name(real, task_dir):
    """Where a document sits inside a snapshot: its path relative to the task
    dir, or — outside the task dir — its absolute path without the leading
    slash. Stable from round to round, so the rounds pair up file by file."""
    rel = os.path.relpath(real, os.path.realpath(task_dir))
    return real.lstrip(os.sep) if rel == os.pardir or rel.startswith(os.pardir + os.sep) else rel


def snap_files(root):
    out = {}
    for d, _, names in os.walk(root):
        for name in names:
            full = os.path.join(d, name)
            out[os.path.relpath(full, root)] = full
    return out


def read_sources(root):
    """The record of snapshot dir <root>: ({name: source path} of its
    documents, {name: source path} of the documents it did not capture), or
    (None, {}) when it has none that can be read."""
    try:
        with open(root + SNAP_SOURCES, encoding="utf-8") as f:
            data = json.load(f)
        docs, absent = data["docs"], data["absent"]
        for d in (docs, absent):
            if not isinstance(d, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in d.items()):
                return None, {}
        return docs, absent
    except Exception:  # noqa: BLE001 — a snapshot without a record is compared as far as it can be
        return None, {}


def snap_diff(pairs, old_label, new_label):
    """(added, removed, unified diff text) over [(name, old file or None,
    new file or None)]; a missing side counts as an empty document."""
    import difflib
    added = removed = 0
    chunks = []
    for name, old, new in pairs:
        la = open(old, encoding="utf-8", errors="replace").read().splitlines() if old else []
        lb = open(new, encoding="utf-8", errors="replace").read().splitlines() if new else []
        lines = list(difflib.unified_diff(la, lb, "%s/%s" % (old_label, name), "%s/%s" % (new_label, name),
                                          lineterm=""))
        for line in lines[2:]:
            added += line.startswith("+")
            removed += line.startswith("-")
        chunks.extend(lines)
    return added, removed, "\n".join(chunks) + ("\n" if chunks else "")


def compare_plan(prev, cur, absent):
    """What round n's snapshot <cur> is compared with in round n-1's <prev>
    (§11.7-2): only a document both rounds captured is diffed. Returns
    ([(name, old file or None, new file or None)], notes); <absent> — the
    documents this round could not capture — grows by the ones carried over.

    A document only <prev> has: its source is gone -> a deletion; its source
    is still there (over the size limit now, or not listed this round) -> not
    compared; no record of its source -> not compared, it cannot be told.
    A document only <cur> has: the round before could not capture it -> not
    compared; otherwise it is new -> an addition."""
    p_docs, p_absent = read_sources(prev)
    pf, cf = snap_files(prev), snap_files(cur)
    pairs, kept, gone, unknown, fresh, back = [], [], [], [], [], []
    for name in sorted(set(pf) | set(cf)):
        if name in pf and name in cf:
            pairs.append((name, pf[name], cf[name]))
        elif name in pf:
            src = None if p_docs is None else p_docs.get(name)
            if src is None:
                unknown.append(name)
            elif os.path.exists(src):
                kept.append(name)
                absent.setdefault(name, src)
            else:
                gone.append(name)
                pairs.append((name, pf[name], None))
        elif name in p_absent:
            back.append(name)
        else:
            fresh.append(name)
            pairs.append((name, None, cf[name]))
    # A document that stays uncaptured stays known as such, so the round it
    # comes back in does not count it as new.
    for name, src in p_absent.items():
        if name not in cf and os.path.exists(src):
            absent.setdefault(name, src)
    notes = []
    for names, text in (
            (kept, "note: 这些文档上一轮有快照、这一轮没有采集（超过大小上限，或这一轮没有列出），源文件还在，不参与修订量比较：%s。"
                   "同一评审点每一轮给同一组文档。"),
            (unknown, "note: 上一轮的快照没有来源记录，判断不了这些文档的源文件是否还在，不参与修订量比较：%s"),
            (back, "note: 这些文档上一轮没有采集到（超过大小上限，或没有列出），这一轮不参与修订量比较，下一轮起照常比较：%s"),
            (gone, "note: 这些文档的源文件已经不存在，按整份删除计入修订量：%s"),
            (fresh, "note: 这些文档是这一轮新出现的，按整份新增计入修订量：%s")):
        if names:
            notes.append(text % "、".join(names))
    return pairs, notes


def take_snapshot(task_dir, point, n, docs, notes, prev_delta):
    """Copy the documents round n reviews to reviews/snap/<point>/r<n>/ and,
    from round 2 on, measure the revision against round n-1's snapshot.
    <notes>: lines the caller already has for stdout. Returns (delta or None,
    stdout lines: the `delta=` line first, then `snapshot=`, `diff=`, then
    notes). Never raises: measuring the revision is a warning aid and must
    not keep a round from starting."""
    info, notes = [], list(notes)
    root = os.path.join(os.path.abspath(task_dir), "reviews", "snap", point)
    cur, prev = os.path.join(root, "r%d" % n), os.path.join(root, "r%d" % (n - 1))
    diff_path = os.path.join(root, "r%d-r%d.diff" % (n - 1, n))
    try:
        # Leftovers of an earlier set of records or of a failed attempt must
        # not pass for this round's snapshot.
        if os.path.lexists(cur):
            shutil.rmtree(cur)
        for stale in (diff_path, cur + SNAP_SOURCES):
            if os.path.lexists(stale):
                os.unlink(stale)
        big = [d for d in docs if os.path.getsize(d) > SNAP_MAX_BYTES]
        if big:
            notes.append("note: 超过 %d MB 的文档不进快照：%s" % (SNAP_MAX_BYTES >> 20, "、".join(big)))
        docs = [d for d in docs if d not in big]
        if not docs:
            return None, notes + ["note: 这一轮没有进快照的文档，不计修订量" if big else
                                  "note: 没有找到可读的设计文档，这一轮不计修订量（在 status.md 的 `- 设计文档:` 写上路径，"
                                  "或 start 时用 --docs <path>... 指定）"]
        sources = {snap_name(d, task_dir): d for d in docs}
        absent = {snap_name(d, task_dir): d for d in big}
        for name, src in sources.items():
            dst = os.path.join(cur, name)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
        measured = n >= 2 and os.path.isdir(prev)
        pairs, plan_notes = compare_plan(prev, cur, absent) if measured else ([], [])
        with open(cur + SNAP_SOURCES, "w", encoding="utf-8") as f:
            json.dump({"docs": sources, "absent": absent}, f, ensure_ascii=False, indent=1, sort_keys=True)
        info.append("snapshot=%s docs=%d" % (cur, len(docs)))
        if n < 2:
            return None, info + notes
        if not measured:
            return None, info + notes + ["note: 第 %d 轮没有快照，这一轮不计修订量（下一轮起照常计量）" % (n - 1)]
        notes += plan_notes
        if not pairs:
            return None, info + notes + ["note: 这一轮没有能和上一轮比较的文档，不计修订量"]
        added, removed, text = snap_diff(pairs, "r%d" % (n - 1), "r%d" % n)
        with open(diff_path, "w", encoding="utf-8") as f:
            f.write(text)
        growing = prev_delta is not None and added > prev_delta[0]
        info.insert(0, "delta=+%d/-%d prev=%s growing=%s"
                    % (added, removed, delta_text(prev_delta), "yes" if growing else "no"))
        info.append("diff=" + diff_path)
        if growing:
            notes.append("note: 第 %d 轮评审的修订新增 %d 行，多于上一轮的 %d 行——修订量在变大。设计评审要收敛，每轮新写的量"
                         "要逐轮变小（§11.1）：修复优先做减法，非阻断发现不进设计正文。这是告警，不拦截。"
                         % (n, added, prev_delta[0]))
        return (added, removed), info + notes
    except Exception as e:  # noqa: BLE001 — fail open, see the docstring
        shutil.rmtree(cur, ignore_errors=True)
        return None, notes + ["note: 设计文档快照失败（%s: %s），这一轮不计修订量；评审照常进行"
                              % (type(e).__name__, one_line(str(e))[:200])]


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
    return ("%s stage=%s kind=%s tier=%s round=%d blocking=%s rejected=%s behavior=%s history=%s cap=%s closed=%s "
            "next=%d mode=%s cross-harness=%s gate=%s"
            % (point, pt["stage"], pt["kind"], tier or "none", last,
               "-" if row["blocking"] is None else row["blocking"],
               "-" if row["rejected"] is None else row["rejected"],
               "-" if row["behavior"] is None else row["behavior"], hist,
               "none" if cap is None else cap, closed, n, mode,
               cross_harness(tier, pt["stage"], mode, n), code))


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
            if pt is not None:
                # Reopening keeps the point's own tier (§10.8-6); lowering it
                # here is a downgrade like any other.
                if not want:
                    own = point_tier(pt)
                was, will = effective(task_tier, pt), max([t for t in (task_tier, own) if t] or [None],
                                                          key=lambda t: RANK.get(t, -1))
                if was and will and RANK[will] < RANK[was] and by != "user":
                    raise Refused("重开评审点 %s 会把它的档位从 %s 降到 %s，降档只能由用户决定。用户明确同意后再运行 "
                                  "`%s open %s --tier %s --by user`；不想降档就不写 --tier（重开时保留原档位）。"
                                  % (point, was, will, cli(), point, will))
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
        die("usage: review-round.sh start <point> [--full --reason <text>] [--docs <path>...]")
    point = valid_point(args[0])
    rest, docs, i = [], None, 1
    while i < len(args):
        if args[i] != "--docs":
            rest.append(args[i])
            i += 1
            continue
        docs = docs or []
        i += 1
        while i < len(args) and not args[i].startswith("--"):
            docs.append(args[i])
            i += 1
    if docs is not None and not docs:
        die("--docs needs at least one path")
    o = opts_of(rest, ("--reason",), ("--full",))
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
        # The revision is measured on design points only (§11.6): prose has
        # no compiler or tests to settle it, implementation has.
        delta, lines = None, []
        if pt["stage"] == "design":
            task_dir = os.path.dirname(os.path.abspath(path))
            found, missing, inside = find_docs(text, task_dir, docs)
            where = "--docs" if docs is not None else "`- 设计文档:`"
            notes = ["note: %s 里这些路径不是可读文件，已跳过：%s" % (where, "、".join(missing))] if missing else []
            if inside:
                notes.append("note: %s 里这些路径在快照目录 reviews/snap/ 里，不是被评审的文档，已跳过：%s"
                             % (where, "、".join(inside)))
            delta, lines = take_snapshot(task_dir, point, n, found, notes,
                                         (pt["rounds"].get(n - 1) or {}).get("delta"))
        elif docs is not None:
            lines = ["note: 修订量只在 design 评审点计量，--docs 已忽略"]
        new = append_rows(text, [review_line(point, pt["stage"], pt["kind"], n, now(), tier=point_tier(pt),
                                             reason=reason if forced else None, delta=delta)])
        verify(new, lambda s: point in s["points"] and latest(s["points"][point]) == n)
        mode = round_mode(n, forced)
        return new, (n, mode, cross_harness(effective(task_tier, pt), pt["stage"], mode, n), lines)

    n, mode, xh, lines = edit(path, change)
    print("round=%d mode=%s cross-harness=%s" % (n, mode, xh))
    for line in lines:
        print(line)


def cmd_result(path, args):
    usage = ("usage: review-round.sh result <point> --blocking N [--rejected R] [--induced I] [--pending P] "
             "[--behavior M]  (--rejected, --induced and --pending are required from round 2 on a task with a Tier; "
             "0 when none)")
    if not args:
        die(usage)
    point = valid_point(args[0])
    o = opts_of(args[1:], ("--blocking", "--rejected", "--behavior", "--induced", "--pending"))
    if not re.fullmatch(COUNT_RE, o.get("blocking", "")):
        die("--blocking must be a count (0..9999)")
    b = int(o["blocking"])
    m = None
    if "behavior" in o:
        if not re.fullmatch(COUNT_RE, o["behavior"]) or int(o["behavior"]) > b:
            die("--behavior must be a count no larger than --blocking")
        m = int(o["behavior"])
    rj = None
    if "rejected" in o:
        if not re.fullmatch(COUNT_RE, o["rejected"]):
            die("--rejected must be a count (0..9999)")
        rj = int(o["rejected"])
    # induced is a part of what the reviewer reported this round, accepted or
    # not; pending is the point's state and is not bounded by the round.
    part = {"induced": None, "pending": None}
    if "induced" in o:
        if not re.fullmatch(COUNT_RE, o["induced"]) or int(o["induced"]) > b + (rj or 0):
            die("--induced must be a count no larger than --blocking + --rejected")
        part["induced"] = int(o["induced"])
    if "pending" in o:
        if not re.fullmatch(COUNT_RE, o["pending"]):
            die("--pending must be a count (0..9999)")
        part["pending"] = int(o["pending"])

    def change(text, st, task_tier):
        pt = open_point(st, point)
        n = latest(pt) or 0
        if n < 1:
            die("point %s has not started a round — run `%s start %s` first" % (point, cli(), point))
        # `result` refills the whole row: a count left out would read as 0 in
        # the early stop's comparison and in the trend (§11.7-4).
        given = {"rejected": rj, "induced": part["induced"], "pending": part["pending"]}
        missing = [k for k in ("rejected", "induced", "pending") if given[k] is None]
        if missing and n >= 2 and effective(task_tier, pt) is not None:
            die("round %d of %s needs %s. --rejected R: how many blockings the reviewer reported this round that "
                "you rejected or downgraded. --induced I: how many of this round's blockings (accepted + rejected) "
                "the previous round's revision brought in, half-landed fixes included. --pending P: how many "
                "blockings of this point still wait on a user answer, earlier rounds' included. 0 when none. %s"
                % (n, point, " and ".join(filter(None, [", ".join("--" + k for k in missing[:-1]), "--" + missing[-1]])),
                   usage))
        line = rewrite(pt, n, blocking=b, behavior=m, rejected=rj, induced=part["induced"], pending=part["pending"])
        new = replace_line(text, pt["index"][n], line)
        verify(new, lambda s: s["points"][point]["rounds"].get(n, {}).get("blocking") == b)
        return new, (line, n, read_state(new), task_tier)

    line, n, st, task_tier = edit(path, change)
    print(line)
    if b == 0 and rj == 0 and (part["pending"] or 0) > 0:
        print("note: 第 %d 轮评审者报告的 blocking 为零，但这个评审点还有 %d 条 blocking 在等用户回答（pending），不能以 passed 关闭。"
              "用户回答后改掉依赖回答的部分，改动进下一轮增量复审：`%s start %s`。" % (n, part["pending"], cli(), point))
        code, msg = decide(st, task_tier, point)
        if code != "ok":
            print("note: 下一轮现在还不能开——" + msg)
    elif b == 0 and rj == 0:
        print("note: 第 %d 轮评审者报告的 blocking 全部为零（被接受 0 条、被拒绝 0 条）——没有未处置的跨 harness 发现和待定用户决定时，"
              "用 `%s close %s --outcome passed --reason …` 关闭这个评审点" % (n, cli(), point))
    elif b == 0 and rj is None:
        print("note: 没有记录被拒绝的 blocking 条数。评审者报告的 blocking 里有被你拒绝或降级的，用 `--rejected <R>` 重填；"
              "没有就写 `--rejected 0`。不写时这个评审点不能以 passed 关闭。")
    elif b == 0:
        print("note: 第 %d 轮有 %d 条 blocking 被拒绝或降级，不能以 passed 关闭：下一轮（增量）把这些被拒绝的 blocking 及理由交给评审者复核，"
              "评审者认可拒绝或重新提出（§10.8-1）。开下一轮：`%s start %s`。" % (n, rj, cli(), point))
        code, msg = decide(st, task_tier, point)
        if code != "ok":
            print("note: 下一轮现在还不能开——" + msg)
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
        die("usage: review-round.sh close <point> --outcome passed|carried|residual|split [--by user] --reason <text>")
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
            row = pt["rounds"].get(n) or {}
            if n < 1 or row.get("blocking") is None:
                raise Refused("评审点 %s 要以 passed 关闭，最近一轮要先 `result`，并且 blocking=0、rejected=0、没有在等用户决定的 blocking。"
                              % point)
            if (row.get("pending") or 0) > 0:
                raise Refused("评审点 %s 还有 %d 条 blocking 在等用户回答（第 %d 轮记录的 pending），不能以 passed 关闭（§11.2 第 5 条）。"
                              "用户回答后改掉依赖回答的部分，改动进下一轮增量复审：`%s start %s`；"
                              "用户的回答不需要改动设计时，用 `result` 重填这一轮的结果，--pending 写 0。"
                              % (point, row["pending"], n, cli(), point))
            if row["blocking"] != 0:
                raise Refused("评审点 %s 第 %d 轮还有 %d 条 blocking，不能以 passed 关闭。修复后再开一轮；到上限时交用户四选一。"
                              % (point, n, row["blocking"]))
            if row.get("rejected") is None:
                raise Refused("评审点 %s 第 %d 轮没有记录被拒绝的 blocking 条数：先 `%s result %s --blocking 0 --rejected <R>`"
                              "（没有被拒绝的就写 0），再 close。" % (point, n, cli(), point))
            if row["rejected"] != 0:
                raise Refused("评审点 %s 第 %d 轮有 %d 条 blocking 被拒绝或降级，还没有独立方复核，不能以 passed 关闭（§10.8-1）。"
                              "开下一轮，把被拒绝的 blocking 及理由交给评审者复核；僵持到上限时交用户四选一。"
                              % (point, n, row["rejected"]))
        elif by != "user":
            raise Refused("以 %s 关闭评审点 %s 是用户在四选一里做的决定（§4.4、§11.3 第 8 条）。用户明确选择后再运行 "
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
        for t in trend(st["points"][p]):
            print("  " + t)
        code, msg = decide(st, tier, p, with_trend=False)
        if code not in ("ok", "closed"):
            print("  " + msg.replace("\n", "\n  "))
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
        if pt["closed"] is None and last == n and round_mode(n, pt["rounds"][n]["forced"]) == mode \
                and pt["rounds"][n]["blocking"] is None:
            return ("ok", effective(t, pt))
    pt = found[0][0]
    last = latest(pt) or 0
    if pt["closed"] is None and last == n and n >= 1 and pt["rounds"][n]["blocking"] is not None:
        return ("评审点 %s 第 %d 轮已经记录了结果（result），不能再用这一轮的标记派发评审（§10.8-2）。"
                "需要再评审就先 `%s start %s` 开新的一轮（它会检查轮次上限），再用它输出的标记派发"
                % (point, n, cli(), point))
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
