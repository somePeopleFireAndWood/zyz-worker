---
task-id: <task-id>
phase: design                     # design | implementation | testing | review | delivery | awaiting-confirmation | error
                                  # `phase` may roll back among design/implementation/testing/review/delivery to
                                  # reflect real iteration (e.g. review→implementation rework). The ONLY exception is
                                  # `awaiting-confirmation`: once written, never roll back — it is the absorbing
                                  # final state a worker self-reaches (self-declared finished, awaiting confirmation).
phase-since: <iso>                # ISO timestamp of when the current `phase` was entered
wait-state: none                  # none | waiting-user | waiting-subagent | waiting-resource
                                  # `wait-state` is orthogonal to `phase`.
waiting-reason:                   # free text; non-empty ONLY when `wait-state != none`
expected-resume-by:               # ISO timestamp; non-empty ONLY when `wait-state != none`;
                                  # the orchestrator uses this as a soft timeout heuristic
last-flush: <iso>                 # ISO timestamp of this flush
---

# Worker Status

<!--
  worker-status.md template
  =========================

  Writer: the worker (the `claude` process running `execute-task` in this task's tmux session).
  Reader: the orchestrator.

  Write atomically (tmpfile + rename). Never edit in place.

  Flush triggers (per the design spec §A.5):
    1. Entering a new `phase` (including `phase=awaiting-confirmation` and `phase=error`).
    2. Setting `wait-state` from `none` to a non-`none` value (suspension).
    3. Setting `wait-state` back to `none` (resume).
    4. Before dispatching a SubAgent.
    5. After receiving a SubAgent result (success or failure).

  The orchestrator only sees what this file says. In-context memory does not
  count. See `docs/conventions/long-running-state.md`.
-->

## Current Activity

<!--
  One to three sentences describing what the worker is doing right now.
-->

## Last Output Summary

<!--
  Five to ten lines summarizing the most recent tool round / SubAgent report.
  When `phase=error`, copy the failure summary here — the orchestrator will
  excerpt this section into the master entry `## Notes` when transitioning the
  task to `blocked`.
-->

## Next Action

<!--
  One sentence: what the worker will do next when not waiting.
-->
