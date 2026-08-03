# Final Report

## Completed

## Not Completed

## Assumptions

## Key Decisions

## Changes

<!-- Multi-repo tasks: split this section by repo — one subsection per repo listing repo / branch / commits / push result. Single-repo tasks: a flat list is fine. -->

## Tests

<!-- Enumerate every aggregate category actually executed; each ran-with-result or skipped-with-reason (matches status ## Final Aggregate Testing). The category list derives from the design ## Testing Plan — add lines for user-named categories; the four below are standing examples, not a closed enumeration. Each `ran:` line carries mutation evidence: a coverage claim without a killed mutation is "ran", not "tested". -->

- Unit: (ran: <result> | skipped: <reason>) — Mutation evidence: (killed/survived tally | none: <reason>)
- E2E: (ran: <result> | skipped: <reason>) — Mutation evidence: (…)
- Regression: (ran: <result> | skipped: <reason>) — Mutation evidence: (…)
- Pressure: (ran: <result> | skipped: <reason> | n/a) — Mutation evidence: (…)
- <design-Testing-Plan category>: (one line per additional category the design names)

## Weakest Link

<!-- Required. Where is a no-op assertion most likely hiding in this delivery: why that spot is suspected, what currently guards it, whether a more direct observation point exists. If something sits at the observation-granularity ceiling, say why — otherwise the next reader assumes laziness rather than limits. The author knows the argument's thinnest point better than any reviewer; leaving this section empty withholds that information, and a role that reports its own tooling failures RAISES the credibility of its other conclusions. -->

## Review Result

<!-- Register every aggregate-review coverage dimension, covered or not-covered-with-reason (matches status ## Final Aggregate Review). When SubTasks were used, record the aggregate verdict separately from the per-SubTask verdicts. -->

- Coverage — Design Conformance: (covered | not-covered: <reason>)
- Coverage — Correctness: (covered | not-covered: <reason>)
- Coverage — Test Quality: (covered | not-covered: <reason>)
- Coverage — Regression Risk: (covered | not-covered: <reason>)
- Coverage — Risk-Specific: (one line per dimension the design `## Risks` calls out | n/a)
- Aggregate Verdict:
- Per-SubTask Verdicts:

## Optional Capabilities Used

## Known Risks

## Follow-Up

## Task Status Files

- Keep or delete:
