# Async Question / Answer Templates

The worker and the user exchange asynchronous questions through two files in
`<list-dir>/runtime/<task-id>/`:

- `question.md` — written by the worker, read by the user
- `answer.md` — written by the user, read by the worker; after consumption the
  worker renames it to `answer.md.consumed.<question-id>` for audit.

The orchestrator does not write either file. Its only role is to surface
"task X is waiting on the user" in the per-tick conversation summary and in
`<list-dir>/SUMMARY.md`.

This document is two templates in one. Copy whichever applies.

---

## `question.md` template (writer: worker)

```markdown
---
task-id: <task-id>
question-id: 1                    # monotonically increasing; first question is 1
asked-at: <iso>
---

## Question

<!-- Free-text question. State exactly what the worker needs to proceed. -->

## Options

<!--
  Optional. If the question admits a small structured set of choices, list
  them here as a bulleted list, one option per line. Omit this section when
  the question is open-ended.
-->
```

Before writing `question.md`, the worker flushes `worker-status.md` with
`wait-state: waiting-user`, a non-empty `waiting-reason`, and an
`expected-resume-by` timestamp. The orchestrator then knows this task is
paused on the user and applies the `waiting-user` heartbeat threshold
(default 900 seconds).

---

## `answer.md` template (writer: user)

```markdown
---
task-id: <task-id>
question-id: 1                    # must match the question-id the worker asked
answered-at: <iso>
---

## Answer

<!-- Free-text answer. -->
```

When the worker detects `answer.md`:

1. Read it.
2. Update `worker-status.md` with `wait-state: none` and an empty
   `waiting-reason` / `expected-resume-by`.
3. Rename `answer.md` to `answer.md.consumed.<question-id>` so it is not
   re-consumed by mistake and so the audit trail survives cleanup.
