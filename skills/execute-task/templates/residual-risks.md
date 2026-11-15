# Residual Risks

<!-- Behavior-level residuals this task's review loops left behind — see SKILL.md `## Review Convergence`. One entry per `non-blocking:contrived` CLASS (not per variant), and one per behavior- or test-level `non-blocking:normal` finding that did not land. Findings about the design DOCUMENT go to its review-history file, not here.

     This file is the input of any later hardening task. Write each entry so that task can act on it without re-deriving it; an entry missing a field is an open item at delivery. Later reviewers get this file's path and answer a registered item by its id instead of re-raising it. That holds only while every producer of what they found falls inside the call sites the entry's `Impact` already cleared. A variant with a new producer, or new evidence that something in the declared domain reaches it, is a new finding with its own tier. -->

## RR-1: <class, one line>

- Origin: <review point label> #<finding number> (<reviewAgent | cross-harness:<harness> | role>)
- Tier: <non-blocking:contrived | non-blocking:normal>
- Reproduction: <the minimal concrete construction — code, input, or state — that triggers it; for a class, every variant seen>
- Impact: <why nothing in the declared domain reaches it today — the enumerated call sites (file:line) — and what change would make it reachable>
- Hardening Plan: <what, where, and how it was verified (probe / throwaway mutation / test), or `none proposed`>
- Status: <open | folded into <follow-up task> | fixed in <commit>>
