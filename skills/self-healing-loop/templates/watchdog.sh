#!/bin/bash
# =============================================================================
# self-healing-loop watchdog  (template — the skill fills in the <...> params)
# -----------------------------------------------------------------------------
# Runs from cron every 20 minutes:  */20 * * * * <REPO>/scripts/<name>-watchdog.sh
#
# It reads the SAME state file the in-session loop writes, and for each task that
# is due today but not yet recorded, it heals in two escalating steps:
#   1. write a sentinel file  -> the main session's persistent Monitor turns it
#      into a fresh turn, and the live loop back-fills the task WITH FULL CONTEXT.
#   2. if the grace period passes with no completion (i.e. the session process is
#      dead, not merely slept) -> headless `claude -p` back-fills once so the
#      business is not missed. This does NOT restore the resident loop.
#
# Placeholders to replace at install time:
#   <REPO>    project root (absolute)
#   <name>    kebab-case instance name (used in lock/signal/log/crontab tag)
#   <STATE>   state file, default <REPO>/data/loop_state.md
#   <SIGNAL>  sentinel file, default /tmp/<name>-wake-signal
#   <LOCK>    lock dir, default /tmp/<name>-watchdog.lock
#   the per-task due-time / day-filter / criteria block near the bottom
#   the notify() body (default: reuse ~/.zyz-worker/notify.json 'command')
# =============================================================================
set -u
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

REPO="<REPO>"
STATE="$REPO/data/loop_state.md"      # = <STATE>
LOG="$REPO/data/<name>-watchdog.log"
LOCK="/tmp/<name>-watchdog.lock"      # = <LOCK>
SIGNAL="/tmp/<name>-wake-signal"      # = <SIGNAL>
GRACE=420                             # seconds to wait for the live session before headless

TODAY=$(date +%F); NOW_HM=$(date +%H%M); WEEKDAY=$(date +%u)
log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# ---- mutual exclusion: mkdir lock, auto-clear a >30-min stale lock -----------
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rmdir "$LOCK"; mkdir "$LOCK" || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ---- notify channel (default: reuse the plugin IM layer, see docs/notify.md) -
# Replace this body with your own if you are not using ~/.zyz-worker/notify.json.
notify(){  # $1 = message
  local cfg="$HOME/.zyz-worker/notify.json" cmd
  [ -f "$cfg" ] || { log "notify: no $cfg, skipped: $1"; return 0; }
  cmd=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("command",""))' "$cfg" 2>/dev/null) || cmd=""
  [ -n "$cmd" ] || { log "notify: no command in $cfg"; return 0; }
  ZYZ_NOTIFY_CATEGORY="self_healing_loop" ZYZ_NOTIFY_MESSAGE="$1" \
    sh -c "$cmd" >> "$LOG" 2>&1 || log "notify: command failed"
}

# ---- idempotency criterion: today's date present in this task's state row ----
done_today(){ grep -E "^\| $1 " "$STATE" 2>/dev/null | head -3 | grep -q "$TODAY"; }

# ---- heal one missing task ---------------------------------------------------
handle_missing(){  # $1=task id  $2=headless back-fill prompt  $3=state-row task id
  log "sentinel wake attempt: $1"
  echo "watchdog: $1 missed. Back-fill this task now, notify, update $STATE, and re-attach ScheduleWakeup." > "$SIGNAL"
  local waited=0
  while [ "$waited" -lt "$GRACE" ]; do
    sleep 30; waited=$((waited+30))
    if done_today "$3"; then
      log "main session back-filled $1 by itself (${waited}s)"
      return 0
    fi
  done
  log "grace ${GRACE}s elapsed with no completion -> headless back-fill $1"
  ( cd "$REPO" && claude -p "$2" --dangerously-skip-permissions --max-turns 60 >> "$LOG" 2>&1 )
  notify "headless back-filled $1 (session was down)"
}

# ---- per-task schedule + criteria (parameterized by the skill) ---------------
# Example shapes — replace with the user's real tasks:
#   daily at 16:05
[ "$NOW_HM" -ge 1605 ] 2>/dev/null && ! done_today "T1" && \
  handle_missing "T1" "<T1 back-fill prompt>" "T1"
#   weekdays only, at 07:35
[ "$WEEKDAY" -le 5 ] && [ "$NOW_HM" -ge 0735 ] 2>/dev/null && ! done_today "T2" && \
  handle_missing "T2" "<T2 back-fill prompt>" "T2"

exit 0
