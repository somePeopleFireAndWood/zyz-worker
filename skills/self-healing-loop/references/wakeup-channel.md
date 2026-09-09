# Wake-up channel: why sentinel + Monitor, not SendMessage

The single most important — and most counter-intuitive — lesson of this pattern
is **how you wake a session whose ScheduleWakeup chain has broken**. Get this
wrong and the whole "self-healing" claim is hollow.

## The failure state: a "slept" session

Define **slept** = the session's process is alive, but the model is not being
invoked. This is exactly what a broken `ScheduleWakeup` chain produces: nothing is
scheduled to re-enter the model, so the session just sits there. It is not dead
(the process still exists), but it is not doing anything and will not on its own.

Waking a slept session requires **three conditions at once**:

1. a **push-style** event source (something external causes a turn),
2. the event can **create a turn** (not merely queue data), and
3. the **process is not dead** (if it is, no in-session mechanism can help — only
   headless `claude -p`).

## Why cross-session `SendMessage` does NOT work

`SendMessage` is **pull-style**. It drops a message into the receiver's inbox,
which is drained on the receiver's **next tool round**. A slept session produces
**no more tool rounds**, so the message is never drained — it piles up forever.

> Field data: the watchdog sent **9** wake-up messages to the main session over a
> broken-chain incident. The main session activated **zero** times. Every message
> was still sitting unread.

So `SendMessage` satisfies neither (1) nor (2) for a slept target. It is fine for
coordinating *live* agents; it is useless as a resurrection channel.

## Why sentinel file + persistent Monitor DOES work

A Monitor started with `persistent: true` watches something (here, a file) and
**each line it prints to stdout becomes a `<task-notification>`** delivered to the
session — which **creates a turn**. That is push-style (condition 1) and
turn-creating (condition 2). As long as the process is alive (condition 3), the
session wakes.

> Field data: this succeeded repeatedly, including once when the main session had
> **no `ScheduleWakeup` pending at all** — a genuinely slept state — and it was
> still woken on time by a sentinel write.

The watchdog therefore **writes the sentinel unconditionally** — it does not try to
detect whether the session is alive first (an early version keyed off the unstable
`cwd` field of `claude agents --json` and misjudged). A live session responds to
the sentinel; a dead one is covered by the headless fallback after the grace
period. No liveness pre-check.

## The Monitor is the weak point

A Monitor can be killed by a session restart, `/clear`, context compaction, or
harness reclaim, and it **does not self-heal**. If it dies, the sentinel channel
goes silent: the watchdog writes the file, but nobody reads it, and the file just
accumulates until headless eventually fires.

Mitigation, baked into the loop turn logic: **on every wake-up, self-check the
Monitor is still alive and re-arm it immediately if not.** Keep headless as the
last-resort backstop for the window where the Monitor was dead.

## Honest boundary

"Self-healing" covers **broken-chain / slept sessions** — process alive, model
idle. It does **not** cover a **process death** (`kill -9`, OOM, terminal closed,
SSH/network dropped): no in-session event source exists to wake a process that is
gone. For that case the headless `claude -p` fallback protects **business
continuity** (the day's task still runs) but does **not** restore the resident
loop — that takes one manual re-launch of the skill (or `--resume`). Say this
plainly to the user; do not imply the loop resurrects itself after a hard kill.
