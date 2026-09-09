# Loop State — <name>

Single source of truth shared by the in-session loop and the cron watchdog.
Both sides read this file; the loop writes a row when it finishes a task, and the
watchdog's idempotency check is "does this task's row contain today's date".

**Do not hand-edit while the loop is running** unless you know what you are doing —
the watchdog reads it every 20 minutes and the loop reads it on every wake-up.

## Tasks

| task | schedule | last run | notes |
|---|---|---|---|
| T1 | <e.g. daily 16:05> | <YYYY-MM-DD HH:MM> | <status / result pointer> |
| T2 | <e.g. weekdays 07:35> | <YYYY-MM-DD HH:MM> | <status / result pointer> |

Row format is load-bearing: the watchdog matches `^| <task-id> ` and looks for
today's `YYYY-MM-DD` in that row. Keep the leading `| T1 ` shape stable.

## Run log

- <YYYY-MM-DD HH:MM> — <task> — <ok / back-filled by loop / headless back-fill> — <detail>
