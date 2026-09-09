#!/bin/bash
# =============================================================================
# self-healing-loop uninstaller  (template)
# -----------------------------------------------------------------------------
# Removes the SYSTEM-LEVEL side effects this instance created:
#   - the tagged crontab line
#   - the sentinel file and the lock dir
# It CANNOT stop the in-session loop or the persistent Monitor — those live in a
# Claude Code session this script cannot reach. Stop them from that session:
# Ctrl-C the loop, and stop the Monitor from /tasks (or re-run the skill as
# `self-healing-loop uninstall <name>`, which stops both, then runs this script).
#
# Replace <name>, <SIGNAL>, <LOCK> at install time.
# =============================================================================
set -u
NAME="<name>"
SIGNAL="/tmp/<name>-wake-signal"   # = <SIGNAL>
LOCK="/tmp/<name>-watchdog.lock"   # = <LOCK>
TAG="# zyz-worker self-healing-loop:$NAME"

echo "Removing crontab line tagged '$TAG' ..."
current=$(crontab -l 2>/dev/null) || current=""
if [ -n "$current" ]; then
  # drop the tagged comment line and the watchdog line that follows it
  printf '%s\n' "$current" | grep -vF "$TAG" | grep -vF "$NAME-watchdog.sh" | crontab -
  echo "  crontab updated."
else
  echo "  no crontab for this user; nothing to remove."
fi

rm -f "$SIGNAL" && echo "Removed sentinel $SIGNAL"
rmdir "$LOCK" 2>/dev/null && echo "Removed lock $LOCK" || true

cat <<EOF

Done removing system-level side effects.

STILL TO DO (only you / the session can): stop the in-session loop and the
persistent Monitor — Ctrl-C the loop, and stop the Monitor from /tasks. Until you
do, the loop keeps self-scheduling (but with the watchdog gone it is no longer
self-healing).
EOF
