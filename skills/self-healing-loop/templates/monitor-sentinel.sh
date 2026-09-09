#!/bin/bash
# =============================================================================
# self-healing-loop persistent sentinel Monitor  (template)
# -----------------------------------------------------------------------------
# Arm this as the command of a Monitor started with persistent: true, from the
# MAIN session, when the skill installs (and re-arm it from the loop whenever the
# self-check finds it dead — Monitors do not self-heal).
#
# Each line this prints to stdout becomes one <task-notification> = one new turn,
# which is what wakes a slept session (push-style; unlike SendMessage which is
# pull-style and cannot wake a session that produces no more tool rounds).
#
# Replace <SIGNAL> with the instance's sentinel path (default /tmp/<name>-wake-signal).
# =============================================================================
SIGNAL="/tmp/<name>-wake-signal"   # = <SIGNAL>

while true; do
  if [ -f "$SIGNAL" ]; then
    echo "WATCHDOG-WAKE $(cat "$SIGNAL" 2>/dev/null)"
    rm -f "$SIGNAL"
  fi
  sleep 10
done
