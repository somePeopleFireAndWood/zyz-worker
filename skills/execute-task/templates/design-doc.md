<!-- SCAFFOLDING — DELETE THIS COMMENT once read; it is not part of the spec.
     This document records only the FINAL design. Fix a wrong statement by
     editing or deleting it, never by appending an annotation beside it; add a
     missing spec freely. Review history lives in the sibling
     `<this-doc-basename>.review-history.md`, never here.
     See SKILL.md `## Design Document Edit Discipline`. -->

# <Task Name> Design

> **The user is the designer of this document; the agent only organizes it.**
> Everything below records the design the USER described — the agent's job was to
> structure it and fill in executable detail, never to introduce a module, flow,
> interface, data structure, key algorithm, or architectural choice the user did not choose.
> Implement this document exactly: nothing dropped, nothing contradicted. Any
> role that believes something here must change says so and waits for the user's
> agreement — no role changes the design on its own initiative, in any phase.
> See SKILL.md `## User Design Authority`.

## Quick Review

<!-- FOR THE USER: read this section alone and you should be able to judge whether the overall direction is right, without reading the rest. Keep it SHORT — it is a map, not a second copy of the design. Update it by REWRITING what changed, never by appending a note beside a sentence that is now wrong — that is what turns a summary into a log. The sections below are authoritative: if this summary and the body ever disagree, the body wins — the summary is the defect, and it is fixed by RE-DERIVING the affected part from the body as it now stands, not by patching the one wrong sentence and not by editing the body to match. -->

### Design Summary

<!-- The whole design in a page or less: which modules/components exist and what each is responsible for, how the work is divided between them, the key algorithms, and the main flow end to end (a numbered flow or a small diagram is fine). Name things as the body names them — same module and interface names, so the user can navigate from here. -->

### Details Needing Your Attention

<!-- Implementation details the user specifically should look at before approving, one per line, each saying WHY it needs attention (an irreversible or hard-to-change decision; a trade-off with a real alternative; a performance/security/data-shape consequence; a place where the design deviates from local convention; an assumption made in the absence of a user decision). May be EMPTY when there is genuinely nothing of the kind — write "none" rather than manufacturing entries. Do NOT use this as a second home for open questions (`## Open Questions`) or for review history. -->

## Background

## Goals

<!-- The user's full, final target. The task must end fully meeting it — no narrowing, deferring, or placeholders at the overall-task level. -->

## Non-Goals

## User Requirements

## Current State

## Proposed Design

## Implementation Plan

## Important Details

## Files To Change

## Testing Plan

<!-- MANDATORY — this is a HARD requirement, not a suggestion. Practice has shown tasks delivered with NO e2e test at all, which badly hurts delivery quality; that must not recur.

     This design MUST plan ALL THREE of the following layers, each with CONCRETE, scenario-specific test cases and flows designed for THIS task (not a generic checklist — enumerate the actual cases, inputs, and end-to-end paths this task needs):
       - Unit tests — the smallest-unit correctness cases (normal + boundary + error paths).
       - Regression tests — protect existing behavior the change touches or could disturb.
       - End-to-end (e2e) tests — exercise the full real path a user/caller actually takes, across real boundaries; NEVER skip this because "unit tests cover it" — the two layers have opposite structural limits and are not substitutes.
     Omitting any of these three requires an EXPLICIT, written reason here (and the user's agreement) — silence is not a valid skip.

     Pressure / stress tests — DECIDE from the requirement scenario whether they are needed (high throughput, concurrency, large data volume, latency/capacity SLOs, or a `## Risks` entry calling out performance/capacity). If needed, plan them here with concrete load/targets; if not, state briefly why they are not needed for this scenario.

     The categories named here are AUTHORITATIVE for the delivery gate: the status file's `## Final Aggregate Testing` registers exactly these, one line each. unit/e2e/regression/pressure are the standing floor, not a ceiling — a further category named here (frontend tests, per-SDK e2e, …) gets its own registration line and is never absorbed into another slot.
     For a fix / repair / backfill / migration or other data-mutating script, specify how it is validated on fabricated representative data BEFORE it touches real data: what to fabricate (normal + boundary + error), how the repaired result is verified, and idempotency / rollback. -->

## Acceptance Criteria

## Risks

## Open Questions

## User Decisions
