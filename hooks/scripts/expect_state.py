#!/usr/bin/env python3
"""Agent-declared expectations for the execute-task watchdog (#24).

The watchdog does not try to guess every legitimate reason a task may be quiet.
The main agent DECLARES them in its status file, and this module is the one
place that reads, validates and edits those declarations. Hooks call ``eval``;
the agent calls the ``expect.sh`` wrapper (set / clear / list / tune).

Rows live in the single ``## Agent State`` section of ``status.md``:

    - Expect: key=<k>; kind=wait; at=<epoch>; ref=<id|->; reason=<text>
    - Expect: key=<k>; kind=user; since=<epoch>; reason=<text>
    - Expect: key=<k>; kind=resident; ref=<id>; reason=<text>
    - Tune: status-stale-sec=<n>; no-executor-sec=<n>; remind-sec=<n>

``wait``     something will move the task by ``at`` (a role or background run,
             an outside batch job, a scheduled re-check). Before ``at`` it
             mutes the status-stale and no-executor findings; at ``at`` the
             watchdog wakes the main agent, then re-reminds every remind-sec
             while the row is unchanged. With ``ref`` (a background task id)
             the row is only honoured while that task is still running —
             observed facts beat declarations.
``user``     the main agent waits on the user. Valid only until the user next
             speaks (``runtime/user-prompt-epoch``), so it can never mute the
             checks for good.
``resident`` a long-lived background task (dev server, ``tail -f`` Monitor,
             unrelated cron) that never ends and never moves the task; it is
             not counted as an executor.
``Tune``     per-task thresholds. Every layer uses max(Tune, its default), so a
             Tune row can only relax a check, and the caps (4h for
             status-stale and no-executor) keep it from switching one off.

The plugin keeps three invariants the agent cannot override: an active task
with nothing declared and no executor is reported; every declaration lapses
(a deadline, the next user prompt, or the task it names ending); and a fact the
host reports (the background task list) wins over a declaration.

Legacy rows are still honoured: ``- Waiting On:`` (strict grammar, read by
lib.sh zyz_status_waiting for muting; its due reminders come from here) and
the 0.29.0 ``- Awaiting-User:`` row (= kind user).
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import re
import sys
import tempfile
import time

HEADING = "## Agent State"
KEY_RE = r"[A-Za-z0-9._-]{1,64}"
ID_RE = r"[A-Za-z0-9._:-]{1,128}"
EPOCH_RE = r"[1-9][0-9]{0,9}"

EXPECT_RE = re.compile(r"^- Expect: (.*)$")
TUNE_RE = re.compile(r"^- Tune: (.*)$")
LEGACY_WAIT_RE = re.compile(
    r"^- Waiting On: instance-key=([A-Za-z0-9._-]+); since-epoch=(0|[1-9][0-9]{0,9}); "
    r"next-check-epoch=(0|[1-9][0-9]{0,9}); reason=(.*)$")
LEGACY_USER_RE = re.compile(r"^- Awaiting-User: since-epoch=(" + EPOCH_RE + r"); reason=(.*)$")

KINDS = ("wait", "user", "resident")
FIELDS = {"wait": ("at", "ref"), "user": ("since",), "resident": ("ref",)}
TUNE_BOUNDS = {
    # status-stale-sec never goes below L1's 600s default, so L1 can keep its
    # cheap "older than the default?" pre-check before parsing anything. Every
    # caller takes max(Tune, its own default): a Tune row only ever relaxes.
    "status-stale-sec": (600, 14400),
    "no-executor-sec": (60, 14400),
    "remind-sec": (300, 86400),
}


def env_int(name, default, lo, hi):
    raw = os.environ.get(name, "")
    if re.fullmatch(r"[1-9][0-9]{0,9}", raw or ""):
        v = int(raw)
        if lo <= v <= hi:
            return v
    return default


def max_horizon():
    return env_int("ZYZ_EXPECT_MAX_SEC", 604800, 60, 31536000)


# ---------------------------------------------------------------- parsing ---

def scan(text):
    """Walk status.md once, HTML comments skipped (the template documents the
    row formats inside a comment in this very section). Returns
    (sections, lines, head, last): the number of `## Agent State` headings, the
    (index, line) pairs inside the single section, the heading's index, and
    the index of the last non-blank NON-comment line of the section (the
    heading if there is none) — where a new row is appended, so a writer and
    the parser always agree on what is inside the section."""
    sections, inside, in_c, out = 0, False, False, []
    head = last = None
    for i, raw in enumerate(text.split("\n")):
        line = raw.rstrip("\r")
        if in_c:
            if "-->" in line:
                in_c = False
            continue
        if line.lstrip().startswith("<!--"):
            in_c = "-->" not in line.lstrip()[4:]
            continue
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


def agent_state_lines(text):
    """(sections, [(index, line)]) of the single ## Agent State section."""
    sections, out, _, _ = scan(text)
    return sections, out


def split_fields(body):
    """`a=1; b=2; reason=free; text` -> dict; `reason` swallows the rest."""
    fields, rest = {}, body
    while rest:
        m = re.match(r"\s*([a-z][a-z-]*)=", rest)
        if not m:
            raise ValueError("expected name=value")
        name = m.group(1)
        rest = rest[m.end():]
        if name == "reason":
            fields[name] = rest.strip()
            break
        val, sep, rest = rest.partition(";")
        if name in fields:
            raise ValueError("duplicate field " + name)
        fields[name] = val.strip()
        if not sep:
            break
    return fields


def parse_expect(body):
    f = split_fields(body)
    key, kind = f.get("key", ""), f.get("kind", "")
    if not re.fullmatch(KEY_RE, key):
        raise ValueError("bad key")
    if kind not in KINDS:
        raise ValueError("kind must be one of " + "/".join(KINDS))
    allowed = {"key", "kind", "reason"} | set(FIELDS[kind])
    extra = set(f) - allowed
    if extra:
        raise ValueError("unknown field(s) for kind %s: %s" % (kind, ",".join(sorted(extra))))
    reason = f.get("reason", "")
    if not reason or len(reason.encode()) > 1024:
        raise ValueError("reason must be non-empty and <= 1024 bytes")
    row = {"key": key, "kind": kind, "reason": reason}
    if kind == "wait":
        if not re.fullmatch(EPOCH_RE, f.get("at", "")):
            raise ValueError("wait needs at=<epoch>")
        row["at"] = int(f["at"])
        ref = f.get("ref", "-") or "-"
        if ref != "-" and not re.fullmatch(ID_RE, ref):
            raise ValueError("bad ref")
        row["ref"] = None if ref == "-" else ref
    elif kind == "user":
        if not re.fullmatch(EPOCH_RE, f.get("since", "")):
            raise ValueError("user needs since=<epoch>")
        row["since"] = int(f["since"])
    else:
        if not re.fullmatch(ID_RE, f.get("ref", "")):
            raise ValueError("resident needs ref=<background task id>")
        row["ref"] = f["ref"]
    return row


def parse_tune(body):
    out = {}
    for part in body.split(";"):
        part = part.strip()
        if not part:
            continue
        name, eq, val = part.partition("=")
        name, val = name.strip(), val.strip()
        if not eq or name not in TUNE_BOUNDS or not re.fullmatch(r"[1-9][0-9]{0,9}", val):
            raise ValueError("bad tune field " + part)
        lo, hi = TUNE_BOUNDS[name]
        v = int(val)
        if not lo <= v <= hi:
            raise ValueError("%s must be within %d..%d" % (name, lo, hi))
        out[name] = v
    return out


def read_rows(text):
    """Parse every declaration. Each row stands alone: a malformed row is
    reported in `errors` and simply does nothing (it never invalidates the
    others, and never mutes anything)."""
    sections, lines = agent_state_lines(text)
    rows, errors, tune, seen = [], [], {}, set()
    if sections != 1:
        if sections > 1:
            errors.append("status.md has %d '## Agent State' sections; declarations ignored" % sections)
        return rows, errors, tune
    for _, line in lines:
        try:
            m = EXPECT_RE.match(line)
            if m:
                row = parse_expect(m.group(1))
                row["source"] = "expect"
            elif TUNE_RE.match(line):
                tune.update(parse_tune(TUNE_RE.match(line).group(1)))
                continue
            elif LEGACY_WAIT_RE.match(line):
                g = LEGACY_WAIT_RE.match(line).groups()
                if int(g[2]) <= 0 or int(g[1]) <= 0:
                    raise ValueError("Waiting On epochs must be positive")
                row = {"key": g[0], "kind": "wait", "at": int(g[2]), "ref": None,
                       "reason": g[3].strip(), "source": "waiting-on"}
            elif LEGACY_USER_RE.match(line):
                g = LEGACY_USER_RE.match(line).groups()
                if not g[1].strip():
                    raise ValueError("Awaiting-User needs a reason")
                row = {"key": "awaiting-user", "kind": "user", "since": int(g[0]),
                       "reason": g[1].strip(), "source": "awaiting-user"}
            elif line.startswith(("- Expect:", "- Tune:", "- Awaiting-User:")):
                raise ValueError("malformed")
            else:
                continue
        except ValueError as e:
            errors.append("%s  <- %s" % (line[:160], e))
            continue
        if (row["kind"], row["key"]) in seen:
            errors.append("%s  <- duplicate key" % line[:160])
            continue
        seen.add((row["kind"], row["key"]))
        rows.append(row)
    return rows, errors, tune


# ------------------------------------------------------------- evaluation ---

def evaluate(text, now, prompt_epoch, running):
    """`running` is the list of running background task ids, or None when
    unknown (the host sent no list / the watchdog has no Stop snapshot)."""
    rows, errors, tune = read_rows(text)
    horizon = max_horizon()
    users_ok, waits_ok, waits_due, dead_refs, residents, notes = [], [], [], [], [], []
    for r in rows:
        if r["kind"] == "user":
            if r["since"] > now:
                notes.append("%s: since is in the future" % r["key"])
            elif r["since"] < prompt_epoch:
                notes.append("%s: lapsed — the user has spoken since it was written" % r["key"])
            else:
                users_ok.append(r)
        elif r["kind"] == "resident":
            residents.append(r["ref"])
        else:
            if r["at"] > now + horizon:
                notes.append("%s: at is more than %ds ahead (ZYZ_EXPECT_MAX_SEC)" % (r["key"], horizon))
                continue
            if r["at"] <= now:
                waits_due.append(r)
                continue
            if r["ref"] and running is not None and r["ref"] not in running:
                dead_refs.append(r)
                continue
            # Legacy Waiting On rows mute through their own strict validator
            # (lib.sh zyz_status_waiting, 1h horizon); here they only get due
            # reminders, so the two grammars never disagree about muting.
            if r["source"] != "waiting-on":
                waits_ok.append(r)
    return {
        "rows": rows,
        "errors": errors,
        "notes": notes,
        "tune": tune,
        "users_valid": [r["key"] for r in users_ok],
        "waits_valid": [r["key"] for r in waits_ok],
        "waits_due": [{"key": r["key"], "at": r["at"], "reason": r["reason"], "ref": r["ref"]} for r in waits_due],
        "dead_refs": [{"key": r["key"], "ref": r["ref"], "reason": r["reason"]} for r in dead_refs],
        # Something will bring the main agent back: a wait (future or due), a
        # legacy Waiting On row not yet due, or a user declaration (the user's
        # reply wakes the session).
        "has_next_check": bool(waits_ok or waits_due or users_ok) or any(
            r["kind"] == "wait" and r["source"] == "waiting-on" and r["at"] > now for r in rows),
        "residents": residents,
        # A wait mutes status-stale AND no-executor until it is due. A user
        # declaration only mutes no-executor: if the main agent keeps working
        # after declaring it, it must still keep the status file fresh.
        "mutes": bool(waits_ok),
        "mutes_noexec": bool(users_ok or waits_ok),
    }


# ---------------------------------------------------------------- editing ---

def parse_when(s, now):
    s = s.strip()
    m = re.fullmatch(r"\+([0-9]+)([smhd])", s)
    if m:
        return now + int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
    if re.fullmatch(EPOCH_RE, s):
        return int(s)
    iso = s.replace(" ", "T")
    if iso.endswith("Z"):
        iso = iso[:-1] + "+00:00"
    try:
        d = _dt.datetime.fromisoformat(iso)
    except ValueError:
        raise SystemExit("expect: cannot parse time %r (use +30m / +2h / +1d, an epoch, or ISO 2026-11-19T02:30[+08:00])" % s)
    if d.tzinfo is None:
        return int(time.mktime(d.timetuple()))
    return int(d.timestamp())


def write_atomic(path, text):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".status.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        try:
            os.chmod(tmp, os.stat(path).st_mode & 0o777)
        except OSError:
            pass
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_text(path):
    if not os.path.exists(path):
        return "", "\n"
    try:
        with open(path, encoding="utf-8", newline="") as f:
            raw = f.read()
    except UnicodeDecodeError:
        raise SystemExit("expect: %s is not valid UTF-8; fix the file first" % path)
    nl = "\r\n" if "\r\n" in raw else "\n"
    return raw.replace("\r\n", "\n"), nl


class _Lock:
    """Exclusive lock on <task-dir>/runtime/expect.lock around read-modify-
    write, so parallel expect.sh calls (several Bash calls in one message)
    never drop each other's rows."""

    def __init__(self, path):
        d = os.path.join(os.path.dirname(os.path.abspath(path)), "runtime")
        os.makedirs(d, exist_ok=True)
        self.f = open(os.path.join(d, "expect.lock"), "a")

    def __enter__(self):
        import fcntl
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        import fcntl
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def edit_rows(path, drop, add, verify=None):
    """Under the lock: remove Agent State rows for which drop(line) is true,
    append `add` after the section's last non-comment line (creating the
    section if needed), write atomically keeping the file's newline style,
    then re-parse and check verify(text) — a row that would not take effect
    is an error, never a silent success."""
    with _Lock(path):
        text, nl = read_text(path)
        sections, lines, head, last = scan(text)
        if sections > 1:
            raise SystemExit("expect: %s has %d '## Agent State' sections; fix it by hand first" % (path, sections))
        all_lines = text.split("\n")
        kill = {i for i, line in lines if drop(line)}
        if sections == 0:
            kept = [l for i, l in enumerate(all_lines) if i not in kill]
            while kept and kept[-1] == "":
                kept.pop()
            out = kept + ["", HEADING, ""] + add + [""]
        else:
            while last in kill:  # the anchor itself is being removed
                last = max([i for i, _ in lines if i < last and i not in kill and _.strip()] or [head])
            out = []
            for i, l in enumerate(all_lines):
                if i in kill:
                    continue
                out.append(l)
                if i == last:
                    if last == head:
                        out.append("")
                    out.extend(add)
        new = "\n".join(out)
        if verify is not None and not verify(new):
            raise SystemExit("expect: refusing to write — the change would not take effect in %s (unusual comment or heading layout?)" % path)
        write_atomic(path, new.replace("\n", nl) if nl != "\n" else new)


def row_key(line):
    """Key of an Expect row, or of a legacy row (Waiting On: its instance-key;
    Awaiting-User: `awaiting-user`), so `clear` removes either."""
    m = EXPECT_RE.match(line)
    if m:
        try:
            return split_fields(m.group(1)).get("key")
        except ValueError:
            return None
    m = re.match(r"^- Waiting On: instance-key=([A-Za-z0-9._-]+);", line)
    if m:
        return m.group(1)
    if line.startswith("- Awaiting-User:"):
        return "awaiting-user"
    return None


def one_line(s):
    return " ".join((s or "").split())


def cmd_set(path, args, now):
    if len(args) < 2:
        raise SystemExit("usage: expect.sh set <key> wait|user|resident [--at T] [--ref ID] --reason TEXT")
    key, kind, opts = args[0], args[1], {}
    rest = args[2:]
    while rest:
        flag = rest.pop(0)
        if flag not in ("--at", "--ref", "--reason") or not rest:
            raise SystemExit("expect: unexpected argument %r" % flag)
        opts[flag[2:]] = rest.pop(0)
    reason = one_line(opts.get("reason", ""))
    if kind == "wait":
        if "at" not in opts:
            raise SystemExit("expect: wait needs --at (+30m, +2h, +1d, epoch or ISO time)")
        at = parse_when(opts["at"], now)
        if at <= now:
            raise SystemExit("expect: --at is not in the future")
        if at > now + max_horizon():
            raise SystemExit("expect: --at is more than %ds ahead (ZYZ_EXPECT_MAX_SEC); schedule an earlier check and re-set it then" % max_horizon())
        line = "- Expect: key=%s; kind=wait; at=%d; ref=%s; reason=%s" % (key, at, opts.get("ref") or "-", reason)
    elif kind == "user":
        line = "- Expect: key=%s; kind=user; since=%d; reason=%s" % (key, now, reason)
    elif kind == "resident":
        line = "- Expect: key=%s; kind=resident; ref=%s; reason=%s" % (key, opts.get("ref", ""), reason)
    else:
        raise SystemExit("expect: kind must be wait, user or resident")
    m = EXPECT_RE.match(line)
    try:
        parse_expect(m.group(1))
    except ValueError as e:
        raise SystemExit("expect: invalid declaration: %s" % e)
    def took_effect(text):
        rows = read_rows(text)[0]
        return any(r["source"] == "expect" and r["key"] == key and r["kind"] == kind for r in rows)
    edit_rows(path, lambda l: row_key(l) == key, [line], took_effect)
    print(line)


def cmd_clear(path, args):
    if args == ["--all"]:
        drop = lambda l: EXPECT_RE.match(l) is not None
    elif len(args) == 1:
        if not row_key_exists(path, args[0]):
            raise SystemExit("expect: no declaration with key=%s" % args[0])
        drop = lambda l: row_key(l) == args[0]
    else:
        raise SystemExit("usage: expect.sh clear <key> | --all")
    edit_rows(path, drop, [], lambda text: not any(drop(l) for _, l in agent_state_lines(text)[1]))
    print("cleared")


def row_key_exists(path, key):
    if not os.path.exists(path):
        return False
    _, lines = agent_state_lines(read_text(path)[0])
    return any(row_key(l) == key for _, l in lines)


def cmd_tune(path, args):
    if args == ["--clear"]:
        edit_rows(path, lambda l: TUNE_RE.match(l) is not None, [])
        print("tune cleared")
        return
    body = "; ".join(args)
    try:
        values = parse_tune(body)
    except ValueError as e:
        raise SystemExit("expect: %s (allowed: %s)" % (e, ", ".join(
            "%s=%d..%d" % (k, lo, hi) for k, (lo, hi) in TUNE_BOUNDS.items())))
    if not values:
        raise SystemExit("usage: expect.sh tune name=value ... | --clear")
    current = read_rows(read_text(path)[0])[2]
    current.update(values)
    line = "- Tune: " + "; ".join("%s=%d" % kv for kv in sorted(current.items()))
    edit_rows(path, lambda l: TUNE_RE.match(l) is not None, [line],
              lambda text: read_rows(text)[2] == current)
    print(line)


def cmd_list(path, now, prompt_epoch):
    ev = evaluate(read_text(path)[0], now, prompt_epoch, None)
    if not ev["rows"] and not ev["tune"] and not ev["errors"]:
        print("(no declarations)")
    for r in ev["rows"]:
        if r["kind"] == "wait":
            state = "due" if r["at"] <= now else ("valid" if r["key"] in ev["waits_valid"] else "invalid")
            when = _dt.datetime.fromtimestamp(r["at"]).strftime("%Y-%m-%d %H:%M")
            extra = "at %s (%+dm)%s" % (when, (r["at"] - now) // 60, " ref=" + r["ref"] if r["ref"] else "")
        elif r["kind"] == "user":
            state = "valid" if r["key"] in ev["users_valid"] else "lapsed"
            extra = "since %s" % _dt.datetime.fromtimestamp(r["since"]).strftime("%Y-%m-%d %H:%M")
        else:
            state, extra = "active", "ref=" + r["ref"]
        src = "" if r["source"] == "expect" else " [legacy %s row]" % r["source"]
        print("%-8s %-9s %-24s %s — %s%s" % (state, r["kind"], r["key"], extra, r["reason"], src))
    if ev["tune"]:
        print("tune     " + ", ".join("%s=%d" % kv for kv in sorted(ev["tune"].items())))
    for n in ev["notes"]:
        print("note     " + n)
    for e in ev["errors"]:
        print("INVALID  " + e)


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    op = argv[1]
    now = int(os.environ.get("ZYZ_EXPECT_NOW") or time.time())
    if op == "evalsh":
        # evalsh <status.md> <prompt-epoch> <running-ids|unknown>: the same
        # evaluation as tab-separated lines for shell callers.
        path, prompt, running = argv[2], argv[3], argv[4]
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            text = ""
        ids = None if running == "unknown" else [i for i in running.split(",") if i and i != "-"]
        ev = evaluate(text, now, int(prompt) if prompt.isdigit() else 0, ids)
        # Never emit an empty field: shell `read` with a tab IFS merges
        # consecutive tabs, which would shift every later field left.
        clean = lambda v: (one_line(str(v)).replace("\t", " ")[:300] or "-")
        print("mutes\t%d" % (1 if ev["mutes"] else 0))
        print("mutes_noexec\t%d" % (1 if ev["mutes_noexec"] else 0))
        print("next\t%d" % (1 if ev["has_next_check"] else 0))
        print("residents\t" + ",".join(ev["residents"]))
        for k, v in sorted(ev["tune"].items()):
            print("tune\t%s\t%d" % (k, v))
        for d in ev["waits_due"]:
            when = _dt.datetime.fromtimestamp(d["at"]).strftime("%m-%d %H:%M")
            print("due\t%s\t%d\t%s\t%s" % (d["key"], d["at"], clean(d["reason"]), when))
        for d in ev["dead_refs"]:
            print("dead\t%s\t%s\t%s" % (d["key"], d["ref"], clean(d["reason"])))
        for e in ev["errors"]:
            print("error\t" + clean(e))
        return
    if op == "eval":
        # eval <status.md> <prompt-epoch> <running-ids|unknown>
        path, prompt, running = argv[2], argv[3], argv[4]
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            text = ""
        ids = None if running == "unknown" else [i for i in running.split(",") if i and i != "-"]
        out = evaluate(text, now, int(prompt) if prompt.isdigit() else 0, ids)
        out.pop("rows")
        print(json.dumps(out, ensure_ascii=False))
        return
    if len(argv) < 3:
        raise SystemExit("expect: missing status file")
    path, args = argv[2], argv[3:]
    if op == "set":
        cmd_set(path, args, now)
    elif op == "clear":
        cmd_clear(path, args)
    elif op == "tune":
        cmd_tune(path, args)
    elif op == "list":
        prompt = os.environ.get("ZYZ_EXPECT_PROMPT_EPOCH", "0")
        cmd_list(path, now, int(prompt) if prompt.isdigit() else 0)
    else:
        raise SystemExit("expect: unknown command %r" % op)


if __name__ == "__main__":
    main(sys.argv)
