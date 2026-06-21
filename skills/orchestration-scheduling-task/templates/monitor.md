---
task-id: <task-id>                 # immutable; the worker this driver state belongs to
last-driver-iso: <iso>             # ISO timestamp of the L2 driver's last run
driver-intent: first-dispatch      # first-dispatch | intervene
                                   # NOTE: the persisted frontmatter key here is `driver-intent`;
                                   # the L1->L2 dispatch INPUT field carrying the same two values
                                   # is named `intent` (e.g. intent=first-dispatch). The two-name
                                   # split (input `intent` vs persisted `driver-intent`) is
                                   # intentional — do NOT rename either to match the other.
claude-started: false              # true | false; set true IMMEDIATELY after the
                                   # readiness probe passes (do not wait for end-of-tick)
needs-user: false                  # true | false; set true ONLY when this worker's
                                   # worker-status.md wait-state=waiting-user. NOT for
                                   # waiting-subagent / waiting-resource (those are normal
                                   # internal waits — no needs-user, no notify).
needs-user-window:                 # tmux session name; non-empty ONLY when needs-user=true
needs-attention: false             # true | false; L2 detected stuck/abnormal worker
                                   # (incl. `/execute-task` rejected as Unknown command)
attention-reason:                  # free text; non-empty ONLY when needs-attention=true
last-summary:                      # the one-line summary L2 returned to L1 (persisted copy)
---

# Driver State

<!--
  monitor.md template
  ===================

  Writer: the L2 orch-driver-agent (a short-lived, on-demand subagent the L1
  orchestrator dispatches to drive ONE worker's tmux pane — first-dispatch or
  intervene). It writes this file with a Bash atomic write (`cat > tmp && mv -f`,
  same as the other helpers — no Edit/Write needed) and flushes incrementally:
  after a successful launch, after any send-keys intervention, and at the end of
  observation. Not just once at end-of-tick.

  Reader: the L1 orchestrator. L1 reads monitor.md to project each worker's
  overall state into its master entry.

  FILENAME stays `monitor.md` deliberately. The agent is named "driver"
  (orch-driver-agent) because in the hybrid architecture L2 only does the heavy
  pane-driving work, not pure monitoring — but the FILE keeps the `monitor.md`
  name on purpose, to avoid churn in test/template path references. Do NOT
  rename it to driver.md.

  L2 writes ONLY this file. It NEVER writes worker-status.md (that file is owned
  by L3 — the execute-task worker — and L3 re-renders it atomically on every
  flush, so any L2 write there would be clobbered). L2 also never writes the
  master entry (L1-owned).

  L1 NEVER writes monitor.md. L1 only reads it. In particular, the notify
  decision keys off the LIVE poll wait-state (from orch-check-worker.sh), NOT
  off this file's possibly-stale `needs-user` flag — so a stale `needs-user=true`
  left here after a user has already answered is harmless (it is only L2's
  scratch record; the next L2 dispatch re-derives it from a fresh poll). This
  one-writer rule (L2 writes, L1 reads) keeps the ownership boundary clean and
  free of write races.

  Write atomically (tmpfile + rename). Never edit in place.

  Lifecycle: archived (not deleted) alongside the rest of runtime/<task-id>/
  by orch-cleanup-worker.sh / orch-merge-and-cleanup.sh, which move
  runtime/<task-id>/ wholesale into runtime/.archive/<task-id>-<ts>/.

  See `docs/conventions/long-running-state.md` and the orchestration SKILL.md
  for the L1/L2/L3 layered-architecture boundaries.
-->

## Last Action

<!--
  What L2 did THIS run: started claude / passed the startup confirmation pages
  (trust folder, bypass risk) / send-keys intervention / observed only.
  Overall driver-level actions only — NOT any L3 internal execution details.
-->

## Notes

<!--
  Short observations L2 appends. Overall state only — NOT L3 internals
  (no design doc / subtask / implementation / test / review / question.md body).
-->
