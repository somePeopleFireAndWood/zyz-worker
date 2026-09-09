---
name: self-healing-loop
description: Use when the user wants a long-running, on-schedule agent that runs tasks at fixed times inside a Claude Code session AND heals itself when the wake-up chain breaks — a session `/loop` (ScheduleWakeup self-timer) hardened by a cron watchdog that writes a sentinel file a persistent Monitor turns into a fresh turn, with a headless `claude -p` fallback. Installs the watchdog script + crontab line, arms the sentinel Monitor, and starts the loop in ONE turn; also uninstalls cleanly. Triggers like "定时 agent"、"每天定点跑"、"长期定时任务"、"scheduled agent"、"self-healing loop"、"断链自愈"、"唤醒沉睡 session"、"cron watchdog"、"哨兵唤醒"、"loop 断了自己回来".
---

# Self-Healing Scheduled Loop

## What this is

A reliable pattern for a **long-running, on-schedule agent** that lives inside a
Claude Code session. A bare session `/loop` (self-scheduled via `ScheduleWakeup`)
has one repeated failure mode: **one network blip or LLM API interruption fails
the current turn, the ScheduleWakeup chain snaps, and the session silently
"sleeps" — scheduled work never fires again and it does not recover on its own.**
(Field data from a real personal scheduled agent: 4 missed runs in ~a week from
broken/jumped wake-up chains.)

This skill installs a **two-layer "loop + watchdog"** architecture that closes
that gap:

- **loop (the living half)** — runs in the **main session**, self-timed with
  `ScheduleWakeup`. Each wake-up reads a shared state file, decides whether a task
  is "due", executes the due task (the part that needs LLM judgement), then renews
  the timer.
- **watchdog (the dead half)** — a `crontab` shell script running every 20 minutes.
  It reads the **same** state file to decide whether today's due tasks have run.
  On a miss it **first writes a sentinel file to wake the main session so it
  back-fills the task itself** (keeping full context); only if the grace period
  passes with no completion does it fall back to a headless `claude -p` run.

Division of labour: **deterministic scheduling/criteria live in the script;
work that needs judgement stays in the session.**

## The one-line entry

The user runs this skill in the **main session** they want the loop to live in:

```
/zyz-worker:self-healing-loop <task description, including "what to do at which time each day">
```

In a single turn the skill does three things:

1. **Install the watchdog** — copy `templates/watchdog.sh` into the project's
   `scripts/` (or another user-chosen dir), fill in the parameters (task
   definitions / miss-criteria / back-fill prompts / notify channel / sentinel &
   lock paths), `chmod +x`, and add one `*/20 * * * *` line to `crontab`.
2. **Arm the persistent sentinel Monitor** — in the current session start a
   `persistent: true` Monitor that polls the sentinel file; when it appears, emit
   one line (which becomes a `<task-notification>` = one new turn) and delete the
   file.
3. **Start the loop** — attach the first `ScheduleWakeup`, entering the self-timed
   loop.

After that the user does nothing; a broken chain is healed by the watchdog.

### Why the entry MUST be a skill (not a subagent, not a plain CLI)

| form | usable? | why |
|---|---|---|
| **Skill / slash command** | ✅ recommended | the only entry that can *both* write the script *and*, in the current session, arm the Monitor + start the loop |
| subagent type | ❌ | a subagent is a short-lived child process — it cannot hold a persistent Monitor; the loop must live in the main-loop session that `ScheduleWakeup` can re-wake |
| plain CLI script | ⚠️ | covers only the watchdog half; loses "let the agent parameterize the prompt / start the loop in-session" |

## Trigger semantics (the part most easily misread — read it carefully)

| stage | who triggers | needs a human? |
|---|---|---|
| **First install** | user runs the skill once | ✅ one manual action, always |
| **Daily on-time execution** | the loop's own `ScheduleWakeup` | ❌ none |
| **Recover from a broken/slept chain** | watchdog (cron) writes sentinel → persistent Monitor makes a turn | ❌ none |
| **After the main-session process is killed** | watchdog headless `claude -p` back-fills today's task once | ❌ business not missed; but the resident loop is **not** auto-restored — restoring it needs a human to run the skill again (or `--resume`) |

**Key points:**

- If the user never runs the skill, no loop or cron line ever appears on its own.
  **Nothing auto-triggers, and that is by design** — cron is a system-level side
  effect, a loop burns tokens continuously, and only the user can supply the task
  definition; none of that should switch on silently.
- **"self-healing" means: it covers "session chain broke and slept", NOT "the
  process was killed outright."** The latter is covered for *business continuity*
  by the headless fallback, but restoring the resident loop still takes one manual
  re-launch. This boundary is stated honestly here and in every generated artifact
  — do not let a user believe the loop resurrects itself after a `kill -9`.

## Hard-won design lessons (bake these into every install)

### 1. Wake-up channel: pull vs push — this decides success or failure

- ❌ **Cross-session `SendMessage` cannot wake a slept session.** It is a *pull*:
  it only drops into an inbox drained on the receiver's *next tool round*; a
  chain-broken session produces no more tool rounds → messages pile up forever.
  (Field data: the watchdog sent **9** wake messages; the main session activated
  **zero** times.)
- ✅ **A sentinel file + a persistent Monitor on the main-session side can wake
  it.** Monitor events are *push*: a file appearing directly creates a turn.
  (Field data: succeeded repeatedly, including once when the main session had **no
  ScheduleWakeup pending at all** — a truly slept state — and was still woken on
  time.)

> "Slept" = process alive but the model is not being invoked. Waking it needs
> three conditions at once: **a push-style event source + the event can create a
> turn + the process is not dead.** If the process is dead, only headless works.

See `references/wakeup-channel.md` for the full analysis.

### 2. The Monitor's lifecycle is this mechanism's weak point — handle it actively

A Monitor can be killed (session restart / `/clear` / context compaction / harness
reclaim) and **does not self-heal**. Once it dies the sentinel channel is dead
(the watchdog writes the file but nobody reads it). So: **on every loop wake-up,
self-check whether the Monitor is still alive and immediately re-arm it if not**;
keep headless as the ultimate fallback.

### 3. Do not judge session liveness from unstable fields

An early version used the `cwd` field of `claude agents --json` to decide whether
the main session was alive before waking it — that field is unstable and caused
misjudgements. Final rule: **write the sentinel unconditionally** (a live session
responds; a dead one is covered by headless after the grace period). No liveness
pre-check.

### 4. Idempotency + mutual exclusion

- **Idempotent:** the watchdog's "already ran" criterion is "does this task's row
  in the state file contain today's date"; the back-fill writes that row, so
  repeats are naturally prevented.
- **Mutex:** an `mkdir` lock with a stale-lock timeout auto-clean prevents cron
  cycles from re-entering.

## Files this skill installs

| file | role | source template |
|---|---|---|
| `<REPO>/scripts/<name>-watchdog.sh` | cron every-20-min watchdog | `templates/watchdog.sh` |
| `<REPO>/data/loop_state.md` | the single source of truth shared by loop + watchdog | `templates/loop_state.md` |
| a `crontab` line `*/20 * * * * …` | schedules the watchdog | (added by the skill) |
| (in-session) persistent Monitor | sentinel → turn | `templates/monitor-sentinel.sh` |
| `<REPO>/scripts/<name>-uninstall.sh` | clean removal | `templates/uninstall.sh` |

Conventions used across the templates:

- `<REPO>` project root; `<STATE>` = `<REPO>/data/loop_state.md`
- `<SIGNAL>` = `/tmp/<name>-wake-signal` (sentinel file)
- `<LOCK>` = `/tmp/<name>-watchdog.lock`
- `<NOTIFY>` notify channel — **default to reusing the plugin's existing IM layer**
  (`command` in `~/.zyz-worker/notify.json`, see `docs/notify.md`) so the user
  configures notifications once; otherwise a user-supplied shell command.
- tasks are named `T1`, `T2`, … for any "due-at-a-time" task (daily, trading-day,
  weekday-only, …).

## Install procedure (what the skill does in-turn)

1. **Parse the task description** the user passed as `$ARGUMENTS` into one or more
   tasks, each with: an id (`T1`…), a due time (and day filter, e.g. weekdays /
   trading days), the work to do, a back-fill prompt (for headless), and where to
   notify. If any of these is ambiguous, ask the user before touching `crontab`.
2. **Pick a `<name>`** (kebab-case, derived from the task) and resolve `<REPO>`,
   `<STATE>`, `<SIGNAL>`, `<LOCK>` paths. Confirm `<REPO>/scripts/` and
   `<REPO>/data/` exist (create if needed).
3. **Render `templates/watchdog.sh`** with the parameters, write it to
   `<REPO>/scripts/<name>-watchdog.sh`, `chmod +x`.
4. **Render `templates/loop_state.md`** to `<STATE>` if it does not already exist.
5. **Render `templates/uninstall.sh`** to `<REPO>/scripts/<name>-uninstall.sh`,
   `chmod +x`.
6. **Add the crontab line** — read the current crontab, append (idempotently — do
   not duplicate an existing identical line)
   `*/20 * * * * <REPO>/scripts/<name>-watchdog.sh` with a `# zyz-worker
   self-healing-loop:<name>` tag comment so uninstall can find it, and install it.
   **This is a system-level change — show the exact line and get explicit user
   confirmation before writing crontab.**
7. **Arm the persistent Monitor** using `templates/monitor-sentinel.sh` (Monitor
   with `persistent: true`).
8. **Attach the first `ScheduleWakeup`** and report to the user: the installed
   paths, the crontab line, the trigger-semantics table, and the self-healing
   boundary.

## Loop turn logic (each ScheduleWakeup / each WATCHDOG-WAKE)

```
1. Read <STATE>, get current time, decide per task whether it is due today and not yet run.
2. If due: execute the task (the LLM-judgement part) → notify → write <STATE>
   (insert today's record for that task row, so the watchdog is idempotent).
3. Self-check the persistent Monitor is still alive; if not, immediately re-arm it
   (otherwise the sentinel channel is dead).
4. Attach the next ScheduleWakeup: a short delay to land precisely just before the
   next task time; a long heartbeat when idle to save tokens.
```

Pick `delaySeconds` the same way the ScheduleWakeup tool guidance says: stay under
270s only when actively converging on the next task time; otherwise use a long
(1200s+) idle heartbeat so you are not burning cache every few minutes.

## Uninstall

`<REPO>/scripts/<name>-uninstall.sh` removes the tagged crontab line, deletes the
sentinel/lock, and prints a reminder that the user must also stop the in-session
loop + Monitor (Ctrl-C the loop, or `/tasks` to stop the Monitor) since those live
in a session this script cannot reach. The skill may also be invoked with
`uninstall <name>` to do this from the session (it can stop the Monitor and the
loop directly, then run the script for the crontab/file cleanup).

## Long-Running State

The loop's durable state is `<STATE>` (`<REPO>/data/loop_state.md`) — the single
source of truth shared with the watchdog. In-context memory does not survive a
chain break or process death, so every task execution MUST be written through to
`<STATE>` as part of the same turn; a task the loop "did" but did not record will
be re-run by the watchdog (correct, if wasteful) or, worse, read as done when it
was not. See [docs/conventions/long-running-state.md](../../docs/conventions/long-running-state.md).
