---
argument-hint: [task description incl. "what to do at which time each day"] | uninstall <name>
description: Install a self-healing scheduled loop (session loop + cron watchdog + sentinel wake-up) in this session, or uninstall one.
---

Set up (or tear down) a self-healing scheduled loop in THIS session:

```text
$ARGUMENTS
```

Load and follow the skill instructions at
`skills/self-healing-loop/SKILL.md` (in the installed zyz-worker plugin).

- With a task description: parse the tasks and their due times, then perform the
  three install steps in one turn — install the watchdog script + crontab line
  (show the exact crontab line and get explicit confirmation first; it is a
  system-level change), arm the persistent sentinel Monitor, and start the loop
  with the first `ScheduleWakeup`. Then report the installed paths, the
  trigger-semantics table, and the self-healing boundary (covers a broken/slept
  chain, NOT a killed process).
- With `uninstall <name>`: stop the in-session loop and Monitor, then run the
  generated `<name>-uninstall.sh` to remove the crontab line and sentinel/lock.
